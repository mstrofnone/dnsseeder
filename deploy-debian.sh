#!/usr/bin/env bash
#
# deploy-debian.sh — Deploy dnsseeder on a Debian/Ubuntu machine
#
# Usage:
#   sudo ./deploy-debian.sh [OPTIONS]
#
# Options:
#   --dns-port PORT       DNS listen port (default: 5353, iptables redirects 53→this)
#   --web-port PORT       Web UI port (default: 8880, 0 to disable)
#   --netfile PATH        Comma-separated config file(s) (default: /opt/dnsseeder/configs/*.json)
#   --go-version VER      Go version to install (default: 1.21.13)
#   --skip-iptables       Don't add port-53 redirect rules
#   --uninstall           Remove everything this script installed
#
# What it does:
#   1. Installs Go (if missing or wrong version)
#   2. Clones & builds dnsseeder from mstrofnone/dnsseeder
#   3. Copies config files to /opt/dnsseeder/configs/
#   4. Creates a systemd unit (dnsseeder.service)
#   5. Sets up iptables rules to redirect port 53 → dns-port
#   6. Enables & starts the service
#
set -euo pipefail

# ----- defaults -----
DNS_PORT=5353
WEB_PORT=8880
NETFILE=""
GO_VERSION="1.21.13"
SKIP_IPTABLES=false
UNINSTALL=false

INSTALL_DIR="/opt/dnsseeder"
REPO_URL="https://github.com/mstrofnone/dnsseeder.git"
SERVICE_NAME="dnsseeder"
SERVICE_USER="dnsseeder"

# ----- parse args -----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dns-port)   DNS_PORT="$2"; shift 2 ;;
        --web-port)   WEB_PORT="$2"; shift 2 ;;
        --netfile)    NETFILE="$2"; shift 2 ;;
        --go-version) GO_VERSION="$2"; shift 2 ;;
        --skip-iptables) SKIP_IPTABLES=true; shift ;;
        --uninstall)  UNINSTALL=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ----- helpers -----
info()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[!]\033[0m $*"; }
die()   { echo -e "\033[1;31m[✗]\033[0m $*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Run as root (sudo)."
}

# ----- uninstall -----
if $UNINSTALL; then
    require_root
    info "Stopping & removing ${SERVICE_NAME}..."
    systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload

    # remove iptables rules (best-effort, ignore errors)
    iptables  -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-port "${DNS_PORT}" 2>/dev/null || true
    iptables  -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to-port "${DNS_PORT}" 2>/dev/null || true
    ip6tables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-port "${DNS_PORT}" 2>/dev/null || true
    ip6tables -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to-port "${DNS_PORT}" 2>/dev/null || true

    rm -rf "${INSTALL_DIR}"
    userdel "${SERVICE_USER}" 2>/dev/null || true
    info "Uninstall complete."
    exit 0
fi

require_root

# ----- 1. install dependencies -----
info "Installing build dependencies..."
apt-get update -qq
apt-get install -y -qq git iptables ca-certificates > /dev/null

# ----- 2. install Go -----
GO_INSTALLED=$(go version 2>/dev/null | grep -oP 'go\K[0-9]+\.[0-9]+(\.[0-9]+)?' || echo "")
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
    amd64) GO_ARCH="amd64" ;;
    arm64) GO_ARCH="arm64" ;;
    armhf) GO_ARCH="armv6l" ;;
    *)     die "Unsupported arch: ${ARCH}" ;;
esac

if [[ "$GO_INSTALLED" != "$GO_VERSION" ]]; then
    info "Installing Go ${GO_VERSION} (${GO_ARCH})..."
    GO_TAR="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
    wget -q "https://go.dev/dl/${GO_TAR}" -O "/tmp/${GO_TAR}"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "/tmp/${GO_TAR}"
    rm -f "/tmp/${GO_TAR}"
else
    info "Go ${GO_VERSION} already installed."
fi

export PATH="/usr/local/go/bin:${PATH}"
export GOPATH="/tmp/go-build"
go version

# ----- 3. clone & build -----
info "Cloning dnsseeder..."
rm -rf "${INSTALL_DIR}/src"
mkdir -p "${INSTALL_DIR}/src"
git clone --depth 1 "${REPO_URL}" "${INSTALL_DIR}/src"

info "Building dnsseeder..."
cd "${INSTALL_DIR}/src"
# upstream go.mod is 1.12; bump so it actually compiles with modern Go
go mod tidy
CGO_ENABLED=0 go build -o "${INSTALL_DIR}/dnsseeder" .
info "Binary: ${INSTALL_DIR}/dnsseeder"

# ----- 4. copy configs -----
mkdir -p "${INSTALL_DIR}/configs"
if [[ -d "${INSTALL_DIR}/src/configs" ]]; then
    cp -n "${INSTALL_DIR}/src/configs/"*.json "${INSTALL_DIR}/configs/" 2>/dev/null || true
fi

# resolve NETFILE default: all json files in configs/
if [[ -z "$NETFILE" ]]; then
    NETFILE=$(find "${INSTALL_DIR}/configs" -name '*.json' -printf '%p,' | sed 's/,$//')
fi

if [[ -z "$NETFILE" ]]; then
    warn "No config files found in ${INSTALL_DIR}/configs/"
    warn "Create a JSON config (see: ${INSTALL_DIR}/dnsseeder -j) then restart the service."
    NETFILE="${INSTALL_DIR}/configs/network.json"
fi

# ----- 5. create service user -----
if ! id -u "${SERVICE_USER}" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "${SERVICE_USER}"
    info "Created user: ${SERVICE_USER}"
fi
chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}"

# ----- 6. build systemd unit -----
WEB_FLAG=""
if [[ "$WEB_PORT" -gt 0 ]]; then
    WEB_FLAG="-w ${WEB_PORT}"
fi

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=DNS Seeder for Bitcoin-based networks
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/dnsseeder -v -p ${DNS_PORT} ${WEB_FLAG} -netfile ${NETFILE}
Restart=on-failure
RestartSec=10
LimitNOFILE=65535

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${INSTALL_DIR}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
info "Created systemd unit: ${SERVICE_NAME}.service"

# ----- 7. iptables redirect 53 → dns-port -----
if ! $SKIP_IPTABLES; then
    info "Setting up iptables redirect: port 53 → ${DNS_PORT}..."

    # idempotent: delete first, then add
    for cmd in iptables ip6tables; do
        for proto in udp tcp; do
            $cmd -t nat -D PREROUTING -p "$proto" --dport 53 -j REDIRECT --to-port "${DNS_PORT}" 2>/dev/null || true
            $cmd -t nat -A PREROUTING -p "$proto" --dport 53 -j REDIRECT --to-port "${DNS_PORT}"
        done
    done

    # persist across reboots if iptables-persistent is available
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
    else
        warn "Install iptables-persistent to survive reboots: apt-get install iptables-persistent"
    fi
fi

# ----- 8. enable & start -----
systemctl enable "${SERVICE_NAME}.service"
systemctl restart "${SERVICE_NAME}.service"

info "dnsseeder is running."
echo ""
echo "  Status:  systemctl status ${SERVICE_NAME}"
echo "  Logs:    journalctl -u ${SERVICE_NAME} -f"
echo "  Config:  ${INSTALL_DIR}/configs/"
if [[ "$WEB_PORT" -gt 0 ]]; then
    echo "  Web UI:  http://localhost:${WEB_PORT}/summary"
fi
echo "  DNS:     dig @localhost -p ${DNS_PORT} <seed-domain> A"
echo ""
