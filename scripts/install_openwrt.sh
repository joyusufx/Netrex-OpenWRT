#!/bin/sh
# Netrex (Quota Manager) - OpenWrt installer (BusyBox ash, POSIX sh only).
#   sh install_openwrt.sh [--upgrade]
# OpenWrt 25.12+ replaced opkg with apk; 22.03-24.10 still use opkg. This
# detects which one the router has, installs the dependencies, fetches the
# code into /opt/quota-manager (the on-disk path is deliberately unchanged),
# installs the Python deps with `pip --target` (a router has no compiler and
# OpenWrt's python3 has no ensurepip, so a venv is NOT an option) and
# registers the procd service.
set -eu

APP_DIR=/opt/quota-manager
PYLIB=$APP_DIR/pylib
CONF_DIR=/etc/quota-gateway
# scripts/get.sh sets NETREX_GIT_URL so a fork's one-liner clones that fork.
REPO=${NETREX_GIT_URL:-https://github.com/UserJoo9/Netrex.git}
# python3-yaml / python3-websockets come from the router's package feed, not
# pip: PyYAML builds C on pip and the feed build is already compiled for the
# router's MIPS CPU. kmod-tun/kmod-ifb/tc are needed for shaping + VPN share,
# conntrack for Live traffic destinations.
PKGS="python3 python3-pip nftables kmod-nft-core kmod-tun kmod-ifb tc ip-full dnsmasq-full git-http ca-bundle python3-yaml python3-websockets conntrack"
UPGRADE=0
for arg in "$@"; do
    case $arg in
        --upgrade) UPGRADE=1 ;;
        *) echo "[netrex] unknown option: $arg" >&2; exit 1 ;;
    esac
done

log() { echo "[netrex] $*"; }
die() { echo "[netrex] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"

if command -v apk >/dev/null 2>&1; then
    log "package manager: apk (OpenWrt 25.12+)"
    apk update
    # shellcheck disable=SC2086
    apk add $PKGS
elif command -v opkg >/dev/null 2>&1; then
    log "package manager: opkg"
    opkg update
    # shellcheck disable=SC2086
    opkg install $PKGS
else
    die "neither apk nor opkg found - is this OpenWrt?"
fi

if [ -d "$APP_DIR/.git" ] || [ -f "$APP_DIR/run.py" ]; then
    # The code is already on disk - a git checkout, or a tree copied over by
    # hand / from a tarball: keep it and skip the download so a re-run works
    # offline. Only --upgrade updates, and only a git checkout can be pulled.
    if [ "$UPGRADE" -eq 1 ] && [ -d "$APP_DIR/.git" ]; then
        log "updating $APP_DIR"
        git -C "$APP_DIR" pull --ff-only
    elif [ "$UPGRADE" -eq 1 ]; then
        log "$APP_DIR is not a git checkout - keeping the local code as is"
    else
        log "existing installation at $APP_DIR - skipping download"
    fi
else
    log "cloning into $APP_DIR"
    git clone --depth 1 "$REPO" "$APP_DIR"
fi

# MIPS routers have no Rust/C toolchain: requirements-openwrt.txt is pinned to
# pure-Python wheels (fastapi 0.115 + pydantic 1.10, plain uvicorn). Dev-only
# packages (pytest, httpx, pyflakes, aiohttp, webauthn) are never installed
# here; passkeys degrade to an honest "server-missing" answer without webauthn.
# pip --target installs the router deps beside the code; no venv (no
# ensurepip) and never requirements-linux.txt (needs compiled wheels).
mkdir -p "$PYLIB"
python3 -m pip install --no-input --no-compile --target "$PYLIB" \
    -r "$APP_DIR/requirements-openwrt.txt"

# Seed the config once; an existing admin config always wins.
#
# config.yaml ships the Debian laptop gateway's values: clients on a separate
# 192.168.2.0/24 and /var/lib/misc/dnsmasq.leases. On a router the box IS the
# LAN gateway, dnsmasq writes /tmp/dhcp.leases, and the client subnet, pool and
# netmask must be the real LAN. With the Debian values nothing is ever learned
# from the lease file, so no device is charged and no quota can cut it.
LAN_IP=$(uci -q get network.lan.ipaddr 2>/dev/null || true)
LAN_MASK=$(uci -q get network.lan.netmask 2>/dev/null || true)
LAN_IP=${LAN_IP:-192.168.1.1}
LAN_MASK=${LAN_MASK:-255.255.255.0}
case "$LAN_IP" in
    *.*.*.*) LAN_PREFIX=$(echo "$LAN_IP" | cut -d. -f1-3)
             ;;
    *)       LAN_PREFIX=192.168.1
             ;;
esac
POOL_START="${LAN_PREFIX}.100"
POOL_END="${LAN_PREFIX}.200"
DHCP_START=$(uci -q get dhcp.lan.start 2>/dev/null || true)
DHCP_LIMIT=$(uci -q get dhcp.lan.limit 2>/dev/null || true)
case "$DHCP_START" in ''|*[!0-9]*) DHCP_START= ;; esac
case "$DHCP_LIMIT" in ''|*[!0-9]*) DHCP_LIMIT= ;; esac
if [ -n "$DHCP_START" ] && [ -n "$DHCP_LIMIT" ]; then
    POOL_START="${LAN_PREFIX}.$((DHCP_START + 1))"
    POOL_END="${LAN_PREFIX}.$((DHCP_START + DHCP_LIMIT))"
fi
mkdir -p "$CONF_DIR"
# set_dhcp <key> <value>: rewrite the first `<key>:` line, keep comments.
set_dhcp() {
    awk -v k="$1" -v v="$2" '
        !done && index($0, "  " k ": ") == 1 {
            print "  " k ": " v; done = 1; next
        }
        { print }
    ' "$CONF_DIR/config.yaml" > "$CONF_DIR/config.yaml.tmp" &&
        mv "$CONF_DIR/config.yaml.tmp" "$CONF_DIR/config.yaml"
}
# set_top <key> <value>: the same, for a top-level (column 1) key.
set_top() {
    awk -v k="$1" -v v="$2" '
        !done && index($0, k ": ") == 1 {
            print k ": " v; done = 1; next
        }
        { print }
    ' "$CONF_DIR/config.yaml" > "$CONF_DIR/config.yaml.tmp" &&
        mv "$CONF_DIR/config.yaml.tmp" "$CONF_DIR/config.yaml"
}
# The whole database (devices, users, rules, usage) lives at db_path, and the
# firewall config + IP-owner cache are written beside it. config.yaml ships the
# Debian path /var/lib/quota-gateway/quota.db, but on OpenWrt /var is a symlink
# into /tmp (tmpfs): wiped at every reboot, which looked like "rules and
# devices do not save". The database must sit on the flash overlay instead.
DB_PATH="$CONF_DIR/quota.db"
if [ -f "$CONF_DIR/config.yaml" ] &&
   grep -qE '^db_path: */(var/lib|tmp)/' "$CONF_DIR/config.yaml"; then
    OLD_DB=$(awk '/^db_path:/{print $2; exit}' "$CONF_DIR/config.yaml")
    set_top db_path "$DB_PATH"
    if [ -f "$OLD_DB" ] && [ ! -f "$DB_PATH" ]; then
        mkdir -p "$(dirname "$DB_PATH")"
        mv "$OLD_DB" "$DB_PATH"
        for f in ip-owners.json firewall_config.json; do
            [ -f "$(dirname "$OLD_DB")/$f" ] &&
                mv "$(dirname "$OLD_DB")/$f" "$(dirname "$DB_PATH")/$f"
        done
        [ -d "$(dirname "$OLD_DB")/firewall_snapshots" ] &&
            mv "$(dirname "$OLD_DB")/firewall_snapshots" \
               "$(dirname "$DB_PATH")/firewall_snapshots"
    fi
    log "db_path moved off tmpfs: $DB_PATH (survives reboot)"
fi
if [ ! -f "$CONF_DIR/config.yaml" ]; then
    cp "$APP_DIR/config.yaml" "$CONF_DIR/config.yaml"
    set_top db_path "$DB_PATH"
    set_dhcp lease_file /tmp/dhcp.leases
    set_dhcp gateway_ip "$LAN_IP"
    set_dhcp router_ip "$LAN_IP"
    set_dhcp subnet "$LAN_MASK"
    set_dhcp pool_start "$POOL_START"
    set_dhcp pool_end "$POOL_END"
    log "config written to $CONF_DIR/config.yaml (LAN $LAN_IP/$LAN_MASK)"
else
    log "existing $CONF_DIR/config.yaml kept — check dhcp.gateway_ip,"
    log "dhcp.pool_start/pool_end and dhcp.lease_file match this router"
fi

cp "$APP_DIR/scripts/quota-manager.openwrt" /etc/init.d/quota-manager
chmod +x /etc/init.d/quota-manager
/etc/init.d/quota-manager enable
/etc/init.d/quota-manager restart || /etc/init.d/quota-manager start
log "done. Dashboard: http://$LAN_IP:8080"
