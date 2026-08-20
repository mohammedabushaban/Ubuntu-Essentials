#!/usr/bin/env bash
sudo bash <<'EOF'
export DEBIAN_FRONTEND=noninteractive

# ── install pptpd, from apt if present, else built from source ────────────────
# Canonical dropped the pptpd PACKAGE from Ubuntu's repos before 24.04 (it is
# an old, weak protocol) — jammy (22.04) is the last release that ships it.
# The pptpd 1.4.0 SOURCE still builds cleanly against any current libc/ppp
# though: it only links against libc, and none of its own headers depend on
# pppd's (the /usr/include/pppd/options.h some guides mention is unrelated —
# that gap trips up people trying to reuse ppp-dev's headers, not this build).
install_pptpd() {
  command -v pptpd >/dev/null && return 0
  apt-get update
  if apt-get install -y pptpd 2>/dev/null; then
    return 0
  fi
  echo "  pptpd is not in this release's repos (removed since Ubuntu 24.04) — building 1.4.0 from source instead..."
  apt-get install -y build-essential wget ca-certificates
  local SRC="/usr/local/src/pptpd-1.4.0" TARBALL_URL="http://archive.ubuntu.com/ubuntu/pool/main/p/pptpd/pptpd_1.4.0.orig.tar.gz"
  mkdir -p /usr/local/src
  wget -qO /tmp/pptpd.tar.gz "$TARBALL_URL"
  tar xzf /tmp/pptpd.tar.gz -C /usr/local/src
  rm -f /tmp/pptpd.tar.gz
  ( cd "$SRC" && ./configure && make && make install )
  # The plugins Makefile ignores $DESTDIR and always writes straight to
  # /usr/local/lib/pptpd — harmless here since that IS the real target, but
  # worth knowing if this function is ever adapted to build into a package root.
  command -v pptpd >/dev/null || { echo "  pptpd build failed — check the output above."; exit 1; }
  echo "  built pptpd $(pptpd --version 2>&1) from source → /usr/local/sbin/pptpd"
}
install_pptpd
command -v ppp >/dev/null || apt-get install -y ppp
command -v iptables >/dev/null || apt-get install -y iptables

mkdir -p /etc/pptp-server /etc/ppp
chmod 700 /etc/pptp-server

cat > /usr/local/sbin/pptp-server <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

ENVF="/etc/pptp-server/server.env"
SECRETS="/etc/ppp/chap-secrets"
SRVNAME="pptpd"                 # must match col 2 of chap-secrets and 'name' in options file
SESSDIR="/run/pptp-sessions"

setup_server() {
  local DEF_WAN
  DEF_WAN="$(ip -o -4 route show to default | awk '{print $5; exit}')"

  read -rp "WAN interface (the uplink to NAT out of) [$DEF_WAN]: " WAN_IF; WAN_IF="${WAN_IF:-$DEF_WAN}"
  read -rp "VPN subnet [10.8.0.0/24]: " SUBNET; SUBNET="${SUBNET:-10.8.0.0/24}"
  # Dual-stack by default: a ULA prefix the clients get NAT66'd out of (no ISP prefix
  # needed). Enter 'none' for IPv4-only.
  read -rp "IPv6 ULA prefix (Enter=fc12::/64, or 'none'): " SUBNET6; SUBNET6="${SUBNET6:-fc12::/64}"
  [ "$SUBNET6" = "none" ] && SUBNET6=""
  # Google DNS. PPTP pushes IPv4 DNS via pppd ms-dns; the IPv6 DNS (Google) is set on
  # the client by the connect snippet, since ms-dns is IPv4-only.
  read -rp "DNS to hand to clients [8.8.8.8]: " DNS; DNS="${DNS:-8.8.8.8}"

  local BASE; BASE="${SUBNET%.*}"
  LOCALIP="$BASE.1"
  IPRANGE="$BASE.10-$BASE.200"
  local PREFIX6="" SRV_IP6=""
  if [ -n "$SUBNET6" ]; then PREFIX6="${SUBNET6%%/*}"; SRV_IP6="${PREFIX6}1"; fi

  cat > "$ENVF" <<E
WAN_IF=$WAN_IF
SUBNET=$SUBNET
LOCALIP=$LOCALIP
IPRANGE=$IPRANGE
SUBNET6=$SUBNET6
PREFIX6=$PREFIX6
SRV_IP6=$SRV_IP6
DNS="$DNS"
E
  chmod 600 "$ENVF"

  # pptpd.conf: localip is the server's tunnel address, remoteip is the pool handed
  # to clients that don't have a fixed IP pinned in chap-secrets.
  cat > /etc/pptpd.conf <<CONF
option /etc/ppp/options.pptpd
logwtmp
localip $LOCALIP
remoteip $IPRANGE
CONF

  # Note for the other side: unlike xl2tpd, pptpd has no separate control-channel
  # keepalive of its own — everything rides over the single GRE+TCP session, so the
  # lcp-echo settings below are the ONLY liveness detection. Keep them the same as
  # the L2TP setup for consistency across both server types.
  cat > /etc/ppp/options.pptpd <<OPT
name $SRVNAME
require-mschap-v2
refuse-pap
refuse-chap
refuse-mschap
auth
noccp
mtu 1400
mru 1400
proxyarp
ms-dns $DNS
lcp-echo-interval 30
lcp-echo-failure 4
connect-delay 5000
$( [ -n "$SUBNET6" ] && printf '+ipv6\nipv6cp-accept-local\nipv6cp-accept-remote' )
OPT

  touch "$SECRETS"; chmod 600 "$SECRETS"

  # ── this box is the clients' router ───────────────────────────────────────────
  # Forward + NAT their traffic out of the WAN. Applied now and re-applied at boot,
  # so it survives a reboot without pulling in iptables-persistent.
  { echo "net.ipv4.ip_forward=1"; [ -n "$SUBNET6" ] && echo "net.ipv6.conf.all.forwarding=1"; } > /etc/sysctl.d/99-pptp-server.conf
  sysctl -q -w net.ipv4.ip_forward=1
  [ -n "$SUBNET6" ] && sysctl -q -w net.ipv6.conf.all.forwarding=1

  cat > /usr/local/sbin/pptp-server-nat <<'NAT'
#!/bin/bash
# Idempotent: -C tests for the rule, and we only add what is missing.
. /etc/pptp-server/server.env
sysctl -q -w net.ipv4.ip_forward=1
iptables -t nat -C POSTROUTING -s "$SUBNET" -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$WAN_IF" -j MASQUERADE
iptables -C FORWARD -s "$SUBNET" -o "$WAN_IF" -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -s "$SUBNET" -o "$WAN_IF" -j ACCEPT
iptables -C FORWARD -d "$SUBNET" -i "$WAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -d "$SUBNET" -i "$WAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
# PPP links are MTU-limited; without this, big packets over the tunnel black-hole.
iptables -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
  iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
# GRE (proto 47) carries the actual PPP payload alongside the TCP:1723 control
# channel. Without explicitly accepting it, some default-deny FORWARD/INPUT
# policies will silently blackhole every PPTP session after the TCP handshake.
iptables -C INPUT -p gre -j ACCEPT 2>/dev/null || iptables -A INPUT -p gre -j ACCEPT
iptables -C FORWARD -p gre -j ACCEPT 2>/dev/null || iptables -A FORWARD -p gre -j ACCEPT

# Dual-stack: same story over IPv6 — clients live in a ULA and are NAT66'd out (no ISP
# prefix delegation needed). Per-session client routes are added by the ppp ip-up hook.
if [ -n "$SUBNET6" ]; then
  sysctl -q -w net.ipv6.conf.all.forwarding=1
  ip6tables -t nat -C POSTROUTING -s "$SUBNET6" -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
    ip6tables -t nat -A POSTROUTING -s "$SUBNET6" -o "$WAN_IF" -j MASQUERADE
  ip6tables -C FORWARD -s "$SUBNET6" -o "$WAN_IF" -j ACCEPT 2>/dev/null || \
    ip6tables -A FORWARD -s "$SUBNET6" -o "$WAN_IF" -j ACCEPT
  ip6tables -C FORWARD -d "$SUBNET6" -i "$WAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    ip6tables -A FORWARD -d "$SUBNET6" -i "$WAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
fi
NAT
  chmod +x /usr/local/sbin/pptp-server-nat

  cat > /etc/systemd/system/pptp-server-nat.service <<UNIT
[Unit]
Description=PPTP server NAT/forwarding rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/pptp-server-nat

[Install]
WantedBy=multi-user.target
UNIT

  # Session tracking: pppd runs these on every connect/disconnect, which is the only
  # reliable way to map a ppp interface back to the username that dialled it.
  mkdir -p /etc/ppp/ip-up.d /etc/ppp/ip-down.d
  cat > /etc/ppp/ip-up.d/pptp-server <<'UP'
#!/bin/bash
# args: $1 iface  $2 tty  $3 speed  $4 local-ip  $5 remote-ip  $6 ipparam
mkdir -p /run/pptp-sessions
{ echo "USER=${PEERNAME:-unknown}"; echo "IP=$5"; echo "SINCE=$(date +%s)"; } > "/run/pptp-sessions/$1"

# Dual-stack: give the client a global ULA derived from its IPv4 host number
# (10.8.0.10 -> fc12::10) and route it back over this ppp link; NAT66 (set by
# pptp-server-nat) rewrites the source out of the WAN. The client configures the
# matching fc12::<n>/64 + default v6 route itself — see the connect snippet.
. /etc/pptp-server/server.env 2>/dev/null
if [ -n "$SUBNET6" ]; then
  octet="${5##*.}"
  ip -6 route replace "${PREFIX6}${octet}/128" dev "$1" 2>/dev/null || true
  echo "IP6=${PREFIX6}${octet}" >> "/run/pptp-sessions/$1"
fi
UP
  cat > /etc/ppp/ip-down.d/pptp-server <<'DOWN'
#!/bin/bash
rm -f "/run/pptp-sessions/$1"
DOWN
  chmod +x /etc/ppp/ip-up.d/pptp-server /etc/ppp/ip-down.d/pptp-server

  # The apt package ships pptpd.service; a from-source build (see install_pptpd
  # above) does not, so create it if it's missing rather than assume either path.
  if [ ! -f /etc/systemd/system/pptpd.service ] && [ ! -f /lib/systemd/system/pptpd.service ]; then
    cat > /etc/systemd/system/pptpd.service <<UNIT
[Unit]
Description=PPTP Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(command -v pptpd) --fg --conf /etc/pptpd.conf --option /etc/ppp/options.pptpd
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
  fi

  systemctl daemon-reload
  systemctl enable --now pptp-server-nat.service >/dev/null 2>&1 || true
  systemctl enable pptpd >/dev/null 2>&1 || true
  systemctl restart pptpd

  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
    ufw allow 1723/tcp >/dev/null 2>&1 || true
    echo "  (opened TCP 1723 in ufw — note: ufw does not filter GRE by protocol number,"
    echo "   so if you have a default-deny setup double check GRE isn't blocked elsewhere)"
  fi

  echo
  echo "PPTP server up. Clients get $IPRANGE and reach the internet through $WAN_IF."
  echo "Security note: PPTP/MS-CHAPv2 is considered weak/breakable — prefer L2TP/IPSec"
  echo "or WireGuard where the client supports it. Use PPTP only for compatibility."
  echo "Add a user with option 2."
}

users_list() {
  mapfile -t USERS < <(awk -v s="$SRVNAME" '$2==s && $1 !~ /^#/ {print $1}' "$SECRETS" 2>/dev/null)
}

# Lowest address in the pool ($IPRANGE = BASE.10-BASE.200) not already pinned to one
# of our users. Auto-pinning a fixed v4 is what gives every client a STABLE v6
# (fc12::<v4-host>), so the connect snippet can always hand out the right address.
next_free_ip() {
  local lo hi base start end o used
  lo="${IPRANGE%-*}"; hi="${IPRANGE#*-}"
  base="${lo%.*}"; start="${lo##*.}"; end="${hi##*.}"
  used="$(awk -v s="$SRVNAME" -v b="$base" '$2==s && $4 ~ ("^" b "\\.") {n=split($4,a,"."); print a[n]}' "$SECRETS" 2>/dev/null)"
  for (( o=start; o<=end; o++ )); do
    printf '%s\n' $used | grep -qx "$o" || { echo "$base.$o"; return; }
  done
  echo ""   # pool exhausted
}

add_user() {
  [ -f "$ENVF" ] || { echo "Set the server up first (option 1)."; return 1; }
  . "$ENVF"
  read -rp "Username: " U
  [ -z "$U" ] && { echo "Username required."; return 1; }
  users_list
  printf '%s\n' "${USERS[@]}" | grep -qx "$U" && { echo "User '$U' already exists."; return 1; }
  while :; do read -rsp "Password: " P; echo; [ -n "$P" ] && break; echo "  Required."; done

  # Every user gets a STUCK (fixed) v4 by default so its v6 is stable too. Enter accepts
  # the auto-picked next-free address; or type a specific one.
  local NET="${SUBNET%.*}" DEF_IP; DEF_IP="$(next_free_ip)"
  while :; do
    if [ -n "$DEF_IP" ]; then
      read -rp "Fixed VPN IP  [Enter = $DEF_IP]: " FIXED; FIXED="${FIXED:-$DEF_IP}"
    else
      read -rp "Fixed VPN IP  (pool full — type one in $NET.0/24): " FIXED
    fi
    case "$FIXED" in "$NET."[0-9]*) ;; *) echo "  Enter an address inside $NET.0/24 (e.g. $NET.10)."; continue ;; esac
    local o="${FIXED##*.}"
    if ! [ "$o" -ge 2 ] 2>/dev/null || [ "$o" -gt 254 ]; then echo "  Host part must be 2-254."; continue; fi
    if awk -v s="$SRVNAME" -v ip="$FIXED" '$2==s && $4==ip{f=1} END{exit !f}' "$SECRETS"; then
      echo "  $FIXED is already pinned to another user — pick a different one."; continue
    fi
    break
  done

  printf '%s\t%s\t%s\t%s\n' "$U" "$SRVNAME" "$P" "$FIXED" >> "$SECRETS"
  chmod 600 "$SECRETS"
  echo
  echo "Added '$U'. Client settings:"
  echo "    Server:   $(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '<this box public IP>')"
  echo "    Username: $U"
  [ -n "$SUBNET6" ] && echo "    IPv6:     dual-stack (ULA $SUBNET6, NAT66)"
  echo "  No pptpd restart needed — pppd reads chap-secrets on each connect."
  connect_snippet "$U" "$P" "$FIXED"
}

del_user() {
  users_list
  [ "${#USERS[@]}" -eq 0 ] && { echo "No users yet."; return; }
  echo "Users:"
  local i
  for i in "${!USERS[@]}"; do echo "  $((i+1))) ${USERS[$i]}"; done
  read -rp "Choose number: " C
  local T="${USERS[$((C-1))]}"
  [ -z "$T" ] && { echo "Invalid."; return; }
  read -rp "Really remove '$T'? [y/N]: " Y
  [ "$Y" != "y" ] && [ "$Y" != "Y" ] && { echo "Cancelled."; return; }

  # Only ever touch our own rows: username in col 1 AND our server name in col 2.
  awk -v u="$T" -v s="$SRVNAME" '!($1==u && $2==s)' "$SECRETS" > "$SECRETS.tmp"
  mv "$SECRETS.tmp" "$SECRETS"; chmod 600 "$SECRETS"

  # Kick them off if they are connected right now — deleting the secret alone only stops
  # the NEXT dial; the live pppd keeps the session up until it is killed.
  local f ifc pidf
  for f in "$SESSDIR"/*; do
    [ -e "$f" ] || continue
    ifc="$(basename "$f")"
    # subshell: sourcing the session file would clobber $USER in this shell
    if [ "$(. "$f"; echo "$USER")" = "$T" ]; then
      echo "  disconnecting live session on $ifc..."
      # pppd's pidfile name differs between ppp 2.4 (Ubuntu 22/24) and ppp 2.5
      # (Ubuntu 26) — try both layouts rather than assume one.
      for pidf in "/run/$ifc.pid" "/var/run/$ifc.pid" "/run/pppd-$ifc.pid" "/var/run/pppd-$ifc.pid"; do
        [ -f "$pidf" ] || continue
        kill "$(cat "$pidf")" 2>/dev/null || true
        break
      done
      rm -f "$f"
    fi
  done
  echo "Removed '$T'."
}

list_users() {
  users_list
  [ "${#USERS[@]}" -eq 0 ] && { echo "No users yet."; return; }
  declare -A ONLINE_IP ONLINE_SINCE ONLINE_IF
  local f now
  now="$(date +%s)"
  for f in "$SESSDIR"/*; do
    [ -e "$f" ] || continue
    ( . "$f"; echo "$USER|$IP|$SINCE|$(basename "$f")" )
  done > /tmp/.pptp-sess.$$ 2>/dev/null || true
  while IFS='|' read -r u ip since ifc; do
    [ -n "$u" ] && { ONLINE_IP["$u"]="$ip"; ONLINE_SINCE["$u"]="$since"; ONLINE_IF["$u"]="$ifc"; }
  done < /tmp/.pptp-sess.$$
  rm -f /tmp/.pptp-sess.$$

  printf "%-16s %-9s %-13s %-8s %s\n" "USER" "STATE" "VPN IP" "IFACE" "UPTIME"
  local u up
  for u in "${USERS[@]}"; do
    if [ -n "${ONLINE_IP[$u]:-}" ]; then
      up=$(( now - ${ONLINE_SINCE[$u]:-$now} ))
      printf "%-16s %-9s %-13s %-8s %s\n" "$u" "ONLINE" "${ONLINE_IP[$u]}" "${ONLINE_IF[$u]}" "$((up/60))m $((up%60))s"
    else
      printf "%-16s %-9s %-13s %-8s %s\n" "$u" "offline" "-" "-" "-"
    fi
  done
}

show_user() {
  users_list
  [ "${#USERS[@]}" -eq 0 ] && { echo "No users yet."; return; }
  echo "Users:"
  local i
  for i in "${!USERS[@]}"; do echo "  $((i+1))) ${USERS[$i]}"; done
  read -rp "Choose number: " C
  local T="${USERS[$((C-1))]}"
  [ -z "$T" ] && { echo "Invalid."; return; }
  . "$ENVF"
  local PW FIXED
  PW="$(awk -v u="$T" -v s="$SRVNAME" '$1==u && $2==s {print $3; exit}' "$SECRETS")"
  FIXED="$(awk -v u="$T" -v s="$SRVNAME" '$1==u && $2==s {print $4; exit}' "$SECRETS")"
  echo "───────── $T ─────────"
  echo "Server:    $(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '<this box public IP>')"
  echo "Username:  $T"
  echo "Password:  $PW"
  echo "VPN IP:    $( [ "$FIXED" = "*" ] && echo "from pool $IPRANGE" || echo "$FIXED (pinned)" )"
  echo "Gateway:   this server ($LOCALIP) — all client internet is NAT'd out of $WAN_IF"
  [ -n "$SUBNET6" ] && echo "IPv6:      dual-stack on (ULA $SUBNET6, NAT66 out $WAN_IF)"
  echo "──────────────────────"
  connect_snippet "$T" "$PW" "$FIXED"
}

# Offer a ready-to-paste snippet the CLIENT runs to dial this server — so the far side
# doesn't hand-build the PPTP config. $1 user, $2 password, $3 pinned-v4-or-'*'.
connect_snippet() {
  local U="$1" P="$2" FIXED="$3"
  . "$ENVF"
  local SRV; SRV="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '<server-public-ip>')"
  # Client v6 is derived from the pinned v4 host number; pool users get it per-session.
  local V6=""; [ -n "$SUBNET6" ] && [ "$FIXED" != "*" ] && [ -n "$FIXED" ] && V6="${PREFIX6}${FIXED##*.}"

  echo
  read -rp "Print a ready-to-paste connect snippet for the client? [1] MikroTik  [2] Ubuntu  [Enter] skip: " WANT
  case "$WANT" in
    1)
      echo
      echo "═══ MikroTik — paste into the client router's terminal ═══"
      # One line per command (no '\' continuations) so it pastes cleanly by any method.
      echo "/interface pptp-client add name=pptp-securytik connect-to=$SRV user=$U password=$P add-default-route=yes disabled=no"
      # Google DNS (v4 + v6) on the client, since PPTP's ms-dns only carries IPv4.
      echo "/ip dns set servers=8.8.8.8,2001:4860:4860::8888"
      if [ -n "$SUBNET6" ]; then
        [ -n "$V6" ] && echo "/ipv6 address add address=$V6/64 interface=pptp-securytik advertise=no" \
                     || echo "# IPv6: pin this user to a fixed IP to get a stable v6; then fc12::<host>"
        echo "/ipv6 route add dst-address=::/0 gateway=pptp-securytik"
        # Stop this router from advertising itself on the tunnel (else it can inject a
        # default route into the SERVER and cost the server its own internet).
        echo "/ipv6 nd add interface=pptp-securytik ra-lifetime=0s"
      fi
      echo "═════════════════════════════════════════════════════════"
      ;;
    2)
      # IPv6 lines, only when the server is dual-stack AND this user has a pinned v6.
      # A client ipv6-up.d hook re-adds the ULA + v6 default route on every (re)connect,
      # so IPv6 survives reboots/redials. $1 (the ppp iface) must stay literal in the
      # generated hook, hence \$1 here.
      # NOTE: this whole block ends up inside the pasted  sudo bash -c '...'  so it must
      # contain NO single quotes (they'd close the outer '...'). The hook is written with
      # a double-quoted heredoc; \$1 stays literal at paste time (the ppp iface).
      local v6opt="" v6hook=""
      if [ -n "$SUBNET6" ] && [ -n "$V6" ]; then
        v6opt=$'+ipv6\nipv6cp-accept-local\nipv6cp-accept-remote'
        v6hook="mkdir -p /etc/ppp/ipv6-up.d
cat > /etc/ppp/ipv6-up.d/securytik-v6 <<\"HEOF\"
#!/bin/bash
ip -6 addr add $V6/64 dev \"\$1\" 2>/dev/null || true
ip -6 route replace default dev \"\$1\" 2>/dev/null || true
HEOF
chmod +x /etc/ppp/ipv6-up.d/securytik-v6"
      fi
      echo
      echo "═══ Ubuntu — paste into the client's shell (installs pptp-linux if missing) ═══"
      cat <<UB
sudo bash -c '
export DEBIAN_FRONTEND=noninteractive
command -v pptp >/dev/null || { apt-get update && apt-get install -y pptp-linux; }
mkdir -p /etc/ppp/peers
cat > /etc/ppp/peers/securytik <<PP
pty "pptp $SRV --nolaunchpppd"
name "$U"
password "$P"
remotename PPTP
require-mschap-v2
refuse-eap
refuse-pap
refuse-chap
noauth
noccp
mtu 1400
mru 1400
noipdefault
defaultroute
replacedefaultroute
usepeerdns
persist
maxfail 0
holdoff 5
lcp-echo-interval 10
lcp-echo-failure 6
${v6opt}
PP
chmod 600 /etc/ppp/peers/securytik
${v6hook}
pon securytik
sleep 8; ip -4 addr show | grep ppp && ip -6 addr show | grep -i fc1 || echo "check journalctl -u pptpd or /var/log/syslog"
'
UB
      echo "════════════════════════════════════════════════════════════════════════════"
      ;;
    *) : ;;
  esac
}

echo "PPTP Server"
echo "  1) Set up / reconfigure the server"
echo "  2) Add a user"
echo "  3) List users (online status)"
echo "  4) Show a user's connection details"
echo "  5) Remove a user"
echo "  6) Server status"
read -rp "Choose: " CHOICE
case "$CHOICE" in
  1) setup_server ;;
  2) add_user ;;
  3) list_users ;;
  4) show_user ;;
  5) del_user ;;
  6) systemctl is-active pptpd >/dev/null 2>&1 && echo "pptpd: active" || echo "pptpd: inactive"
     echo; echo "Live sessions:"; ls "$SESSDIR" 2>/dev/null || echo "  none"
     echo; ip -o -4 addr show 2>/dev/null | grep ppp || true ;;
  *) echo "Invalid choice"; exit 1 ;;
esac
SCRIPT
chmod +x /usr/local/sbin/pptp-server
echo "Installed. Run:  sudo pptp-server"
EOF

sudo pptp-server
