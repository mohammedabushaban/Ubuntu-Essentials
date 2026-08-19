#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# PPTP Server for Ubuntu 26.04
# Backend: Accel-PPP
#
# WARNING:
# PPTP/MS-CHAPv2 is legacy and cryptographically weak.
# Use only when PPTP compatibility is required.
###############################################################################

export DEBIAN_FRONTEND=noninteractive

APP="pptp-server"
CONF_DIR="/etc/pptp-server"
ENV_FILE="$CONF_DIR/server.env"
ACCEL_CONF="/etc/accel-ppp.conf"
CHAP_SECRETS="/etc/accel-ppp/chap-secrets"
NAT_SCRIPT="/usr/local/sbin/pptp-server-nat"
SYSTEMD_UNIT="/etc/systemd/system/accel-ppp.service"

ACCEL_PREFIX="/usr/local"
ACCEL_BIN="$ACCEL_PREFIX/sbin/accel-pppd"

log()  { echo "[$APP] $*"; }
ok()   { echo "[OK] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Run this script with sudo."
}

cleanup_on_error() {
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo
        echo "[ERROR] Installation/configuration failed."
        echo "[ERROR] Existing configuration was not intentionally removed."
    fi
}
trap cleanup_on_error EXIT

###############################################################################
# Detect Ubuntu
###############################################################################

check_os() {
    [ -r /etc/os-release ] || die "/etc/os-release not found."

    . /etc/os-release

    if [ "${ID:-}" != "ubuntu" ]; then
        die "This script supports Ubuntu only."
    fi

    if [ "${VERSION_ID:-}" != "26.04" ]; then
        warn "This script is intended for Ubuntu 26.04."
        warn "Detected Ubuntu ${VERSION_ID:-unknown}."
        read -rp "Continue anyway? [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] || exit 1
    fi

    ok "Ubuntu ${VERSION_ID:-unknown} detected."
}

###############################################################################
# Dependencies
###############################################################################

install_dependencies() {
    log "Installing build/runtime dependencies..."

    apt-get update

    apt-get install -y \
        build-essential \
        cmake \
        git \
        pkg-config \
        libpcre2-dev \
        libssl-dev \
        liblua5.4-dev \
        libcap-dev \
        libnl-3-dev \
        libnl-route-3-dev \
        libnetfilter-conntrack-dev \
        iproute2 \
        iptables \
        ppp \
        ca-certificates \
        curl \
        awk

    ok "Dependencies installed."
}

###############################################################################
# Build Accel-PPP
###############################################################################

install_accel_ppp() {

    if [ -x "$ACCEL_BIN" ]; then
        log "Accel-PPP already installed: $ACCEL_BIN"
        return
    fi

    local BUILD
    BUILD="$(mktemp -d)"

    log "Downloading Accel-PPP source..."

    git clone --depth 1 \
        https://github.com/accel-ppp/accel-ppp.git \
        "$BUILD/accel-ppp"

    cd "$BUILD/accel-ppp"

    mkdir -p build
    cd build

    log "Configuring Accel-PPP..."

    cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$ACCEL_PREFIX" \
        -DBUILD_DRIVER=TRUE \
        -DRADIUS=TRUE \
        -DSHAPER=TRUE \
        -DNETSNMP=FALSE \
        ..

    log "Building Accel-PPP..."

    make -j"$(nproc)"

    log "Installing Accel-PPP..."

    make install

    ldconfig

    cd /
    rm -rf "$BUILD"

    [ -x "$ACCEL_BIN" ] || die "Accel-PPP installation failed."

    ok "Accel-PPP installed."
}

###############################################################################
# Network input
###############################################################################

get_default_interface() {
    ip -o -4 route show default 2>/dev/null |
        awk '{print $5; exit}'
}

validate_ipv4_cidr() {
    local value="$1"

    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] ||
        return 1

    return 0
}

validate_ipv4() {
    local value="$1"

    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
        return 1

    return 0
}

###############################################################################
# Server configuration
###############################################################################

setup_server() {

    local DEFAULT_WAN
    DEFAULT_WAN="$(get_default_interface)"

    [ -n "$DEFAULT_WAN" ] ||
        die "Could not detect default WAN interface."

    echo
    echo "PPTP Server configuration"
    echo "─────────────────────────"
    echo

    read -rp "WAN interface [$DEFAULT_WAN]: " WAN_IF
    WAN_IF="${WAN_IF:-$DEFAULT_WAN}"

    ip link show "$WAN_IF" >/dev/null 2>&1 ||
        die "Interface '$WAN_IF' does not exist."

    read -rp "VPN subnet [10.8.0.0/24]: " VPN_SUBNET
    VPN_SUBNET="${VPN_SUBNET:-10.8.0.0/24}"

    validate_ipv4_cidr "$VPN_SUBNET" ||
        die "Invalid VPN subnet: $VPN_SUBNET"

    read -rp "VPN gateway [10.8.0.1]: " VPN_GATEWAY
    VPN_GATEWAY="${VPN_GATEWAY:-10.8.0.1}"

    validate_ipv4 "$VPN_GATEWAY" ||
        die "Invalid VPN gateway."

    read -rp "VPN pool [10.8.0.10-10.8.0.200]: " VPN_POOL
    VPN_POOL="${VPN_POOL:-10.8.0.10-10.8.0.200}"

    read -rp "Primary DNS [1.1.1.1]: " DNS1
    DNS1="${DNS1:-1.1.1.1}"

    read -rp "Secondary DNS [8.8.8.8]: " DNS2
    DNS2="${DNS2:-8.8.8.8}"

    validate_ipv4 "$DNS1" || die "Invalid DNS1."
    validate_ipv4 "$DNS2" || die "Invalid DNS2."

    mkdir -p "$CONF_DIR"
    mkdir -p "$(dirname "$CHAP_SECRETS")"
    mkdir -p /var/log/accel-ppp
    mkdir -p /run/accel-ppp

    chmod 700 "$CONF_DIR"
    chmod 700 "$(dirname "$CHAP_SECRETS")"

    ###########################################################################
    # Environment
    ###########################################################################

    cat > "$ENV_FILE" <<EOF
WAN_IF=$WAN_IF
VPN_SUBNET=$VPN_SUBNET
VPN_GATEWAY=$VPN_GATEWAY
VPN_POOL=$VPN_POOL
DNS1=$DNS1
DNS2=$DNS2
EOF

    chmod 600 "$ENV_FILE"

    ###########################################################################
    # chap-secrets
    ###########################################################################

    touch "$CHAP_SECRETS"
    chmod 600 "$CHAP_SECRETS"

    ###########################################################################
    # Accel-PPP configuration
    ###########################################################################

    cat > "$ACCEL_CONF" <<EOF
[modules]
log_file
connlimit
pptp
auth_mschap_v2
chap-secrets
ippool

[core]
thread-count=$(nproc)
log-error=/var/log/accel-ppp/core.log

[common]
max-sessions=500
session-timeout=0
check-ip=1

[ppp]
verbose=0
min-mtu=1280
mtu=1400
mru=1400
accomp=deny
pcomp=deny
ccp=1
mppe=require
ipv4=require
ipv6=deny
lcp-echo-interval=30
lcp-echo-failure=4

[auth]
timeout=5
interval=0
max-failure=3
any-login=0

[pptp]
verbose=0
port=1723
echo-interval=30
echo-failure=3
timeout=5
mppe=require
ppp-max-mtu=1400
ip-pool=pptp
ifname=pptp%d

[ip-pool]
gw-ip-address=$VPN_GATEWAY
192.0.2.1/32
pptp=$VPN_POOL

[dns]
dns1=$DNS1
dns2=$DNS2

[log]
log-file=/var/log/accel-ppp/accel-ppp.log
log-emerg=/var/log/accel-ppp/emerg.log
log-failure=/var/log/accel-ppp/failure.log
copy=1
color=0

[connlimit]
limit=20
burst=5
timeout=300
EOF

    chmod 600 "$ACCEL_CONF"

    ###########################################################################
    # Sysctl
    ###########################################################################

    cat > /etc/sysctl.d/99-pptp-server.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
EOF

    sysctl --system >/dev/null

    ###########################################################################
    # NAT
    ###########################################################################

    cat > "$NAT_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

. /etc/pptp-server/server.env

sysctl -q -w net.ipv4.ip_forward=1

iptables -t nat -C POSTROUTING \
    -s "$VPN_SUBNET" \
    -o "$WAN_IF" \
    -j MASQUERADE 2>/dev/null ||
iptables -t nat -A POSTROUTING \
    -s "$VPN_SUBNET" \
    -o "$WAN_IF" \
    -j MASQUERADE

iptables -C FORWARD \
    -s "$VPN_SUBNET" \
    -o "$WAN_IF" \
    -j ACCEPT 2>/dev/null ||
iptables -A FORWARD \
    -s "$VPN_SUBNET" \
    -o "$WAN_IF" \
    -j ACCEPT

iptables -C FORWARD \
    -d "$VPN_SUBNET" \
    -i "$WAN_IF" \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT 2>/dev/null ||
iptables -A FORWARD \
    -d "$VPN_SUBNET" \
    -i "$WAN_IF" \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT

iptables -C FORWARD \
    -s "$VPN_SUBNET" \
    -o "$WAN_IF" \
    -p tcp \
    --tcp-flags SYN,RST SYN \
    -j TCPMSS \
    --clamp-mss-to-pmtu 2>/dev/null ||
iptables -A FORWARD \
    -s "$VPN_SUBNET" \
    -o "$WAN_IF" \
    -p tcp \
    --tcp-flags SYN,RST SYN \
    -j TCPMSS \
    --clamp-mss-to-pmtu

# PPTP control channel
iptables -C INPUT -p tcp --dport 1723 -j ACCEPT 2>/dev/null ||
iptables -A INPUT -p tcp --dport 1723 -j ACCEPT

# PPTP GRE
iptables -C INPUT -p gre -j ACCEPT 2>/dev/null ||
iptables -A INPUT -p gre -j ACCEPT

iptables -C FORWARD -p gre -j ACCEPT 2>/dev/null ||
iptables -A FORWARD -p gre -j ACCEPT
EOF

    chmod 700 "$NAT_SCRIPT"

    ###########################################################################
    # systemd NAT service
    ###########################################################################

    cat > /etc/systemd/system/pptp-server-nat.service <<EOF
[Unit]
Description=PPTP Server NAT
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$NAT_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    ###########################################################################
    # systemd Accel-PPP
    ###########################################################################

    cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Accel-PPP PPTP Server
After=network-online.target pptp-server-nat.service
Wants=network-online.target
Requires=pptp-server-nat.service

[Service]
Type=simple
ExecStart=$ACCEL_BIN -c $ACCEL_CONF -p /run/accel-ppp/accel-ppp.pid
Restart=always
RestartSec=3

LimitNOFILE=1048576
TasksMax=4096

PrivateTmp=true
ProtectSystem=full
ProtectHome=true

NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    systemctl enable --now pptp-server-nat.service

    systemctl enable accel-ppp.service

    systemctl restart accel-ppp.service

    sleep 2

    if systemctl is-active --quiet accel-ppp.service; then
        ok "Accel-PPP is running."
    else
        systemctl status accel-ppp.service --no-pager || true
        journalctl -u accel-ppp.service -n 80 --no-pager || true
        die "Accel-PPP failed to start."
    fi

    ###########################################################################
    # UFW
    ###########################################################################

    if command -v ufw >/dev/null 2>&1 &&
       ufw status 2>/dev/null | grep -q "^Status: active"; then

        warn "UFW is active."

        ufw allow 1723/tcp comment 'PPTP control' >/dev/null || true

        # UFW does not provide a simple 'allow protocol 47' syntax
        # compatible with every version. Warn instead of modifying
        # /etc/ufw/before.rules blindly.
        warn "GRE protocol 47 must also be permitted by your firewall."
    fi

    echo
    echo "════════════════════════════════════════════════════════════"
    echo " PPTP SERVER READY"
    echo "════════════════════════════════════════════════════════════"
    echo
    echo "WAN:       $WAN_IF"
    echo "VPN:       $VPN_SUBNET"
    echo "Pool:      $VPN_POOL"
    echo "Gateway:   $VPN_GATEWAY"
    echo "DNS:       $DNS1 / $DNS2"
    echo
    echo "Control:   TCP/1723"
    echo "Payload:   GRE / protocol 47"
    echo
    echo "Service:"
    echo "  systemctl status accel-ppp"
    echo
    echo "Logs:"
    echo "  journalctl -u accel-ppp -f"
    echo "  tail -f /var/log/accel-ppp/accel-ppp.log"
    echo
    echo "Security:"
    echo "  PPTP/MS-CHAPv2 is legacy and weak."
    echo "  Use only for compatibility."
    echo "════════════════════════════════════════════════════════════"
}

###############################################################################
# Users
###############################################################################

add_user() {

    [ -f "$ENV_FILE" ] ||
        die "Run setup first."

    . "$ENV_FILE"

    echo
    read -rp "Username: " USERNAME

    [ -n "$USERNAME" ] ||
        die "Username is required."

    [[ "$USERNAME" =~ ^[a-zA-Z0-9._-]+$ ]] ||
        die "Invalid username."

    if awk -v u="$USERNAME" '$1 == u {found=1} END {exit !found}' \
        "$CHAP_SECRETS"; then

        die "User '$USERNAME' already exists."
    fi

    read -rsp "Password: " PASSWORD
    echo

    [ -n "$PASSWORD" ] ||
        die "Password is required."

    printf '%s\tPPTP\t%s\t*\n' \
        "$USERNAME" "$PASSWORD" >> "$CHAP_SECRETS"

    chmod 600 "$CHAP_SECRETS"

    ok "User '$USERNAME' added."
}

###############################################################################

list_users() {

    echo
    printf "%-24s %-12s\n" "USERNAME" "STATUS"
    printf "%-24s %-12s\n" "--------" "------"

    awk '
        $0 !~ /^[[:space:]]*#/ && NF >= 2 {
            print $1
        }
    ' "$CHAP_SECRETS" 2>/dev/null |
    while read -r U; do
        if pgrep -af "accel-pppd" 2>/dev/null |
            grep -q "$U"; then
            printf "%-24s %-12s\n" "$U" "configured"
        else
            printf "%-24s %-12s\n" "$U" "configured"
        fi
    done
}

###############################################################################

remove_user() {

    local U

    read -rp "Username to remove: " U

    [ -n "$U" ] ||
        die "Username required."

    if ! awk -v u="$U" '$1 == u {found=1} END {exit !found}' \
        "$CHAP_SECRETS"; then

        die "User '$U' not found."
    fi

    read -rp "Remove '$U'? [y/N]: " CONFIRM

    [[ "$CONFIRM" =~ ^[Yy]$ ]] || {
        echo "Cancelled."
        return
    }

    awk -v u="$U" '$1 != u' "$CHAP_SECRETS" > "$CHAP_SECRETS.tmp"

    mv "$CHAP_SECRETS.tmp" "$CHAP_SECRETS"
    chmod 600 "$CHAP_SECRETS"

    ok "User '$U' removed."
}

###############################################################################
# Status
###############################################################################

status_server() {

    echo
    echo "PPTP / Accel-PPP status"
    echo "────────────────────────"

    systemctl is-active accel-ppp.service &&
        echo "Service: ACTIVE" ||
        echo "Service: INACTIVE"

    echo
    echo "Listening:"
    ss -lntp 2>/dev/null |
        grep ':1723' ||
        echo "TCP 1723 is not listening."

    echo
    echo "GRE:"
    cat /proc/net/gre 2>/dev/null || true

    echo
    echo "PPTP interfaces:"
    ip -o link show 2>/dev/null |
        grep -E 'pptp[0-9]+' ||
        echo "No active PPTP sessions."

    echo
    echo "Configured users:"
    awk '$0 !~ /^[[:space:]]*#/ && NF >= 2 {print "  " $1}' \
        "$CHAP_SECRETS" 2>/dev/null || true

    echo
    echo "Recent logs:"
    journalctl -u accel-ppp.service -n 20 --no-pager || true
}

###############################################################################
# Firewall diagnostics
###############################################################################

firewall_status() {

    echo
    echo "PPTP firewall rules"
    echo "───────────────────"

    echo
    echo "TCP/1723:"
    iptables -C INPUT -p tcp --dport 1723 -j ACCEPT 2>/dev/null &&
        echo "  ACCEPT" ||
        echo "  NOT explicitly allowed"

    echo
    echo "GRE:"
    iptables -C INPUT -p gre -j ACCEPT 2>/dev/null &&
        echo "  ACCEPT" ||
        echo "  NOT explicitly allowed"

    echo
    echo "NAT:"
    iptables -t nat -S POSTROUTING 2>/dev/null |
        grep "$VPN_SUBNET" || true
}

###############################################################################
# Main
###############################################################################

require_root
check_os
install_dependencies
install_accel_ppp

while true; do

    echo
    echo "PPTP Server"
    echo "────────────────────────────"
    echo "  1) Set up / reconfigure"
    echo "  2) Add user"
    echo "  3) List users"
    echo "  4) Remove user"
    echo "  5) Server status"
    echo "  6) Firewall status"
    echo "  7) Restart server"
    echo "  q) Quit"
    echo

    read -rp "Choose: " CHOICE

    case "$CHOICE" in
        1)
            setup_server
            ;;
        2)
            add_user
            ;;
        3)
            list_users
            ;;
        4)
            remove_user
            ;;
        5)
            status_server
            ;;
        6)
            firewall_status
            ;;
        7)
            systemctl restart accel-ppp.service
            systemctl is-active accel-ppp.service
            ;;
        q|Q)
            break
            ;;
        *)
            echo "Invalid choice."
            ;;
    esac
done