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
# Default to the fork that carries the OpenWrt port: upstream UserJoo9/Netrex
# has no openwrt-mips-port, so defaulting there broke every bare run.
REPO=${NETREX_GIT_URL:-https://github.com/joyusufx/Netrex-OpenWRT.git}
#: Branch/tag to clone. get.sh passes the ref it downloaded this installer
#: from; the default is the port branch, not the remote's default branch
#: (which is upstream code without the port).
REF=${NETREX_REF:-openwrt-mips-port}
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

have_port_tree() { [ -f "$APP_DIR/run.py" ] && [ -f "$APP_DIR/requirements-openwrt.txt" ]; }

if [ -d "$APP_DIR/.git" ] && ! have_port_tree; then
    # A pre-fix install cloned the remote's default branch (main = upstream
    # code), which has no requirements-openwrt.txt; reusing it made the app
    # die at startup with FileNotFoundError. Switch that checkout to the port
    # branch instead of reusing it.
    WANT_REF=${REF:-openwrt-mips-port}
    # Fetch from the repo we are installing, not from `origin`: a pre-fix
    # install has origin = UserJoo9/Netrex (upstream), which has no
    # openwrt-mips-port ref, so "fetch origin $WANT_REF" dies with
    # "couldn't find remote ref". Repoint origin afterwards so --upgrade's
    # `git pull --ff-only` keeps tracking the port branch.
    #
    # Only tracked modifications count as local changes: every finished
    # install puts pip's `pylib/` (and __pycache__) inside $APP_DIR, so a
    # plain `git status --porcelain` is never empty and the heal refused
    # forever. git itself still aborts the checkout rather than overwrite an
    # untracked file it would clobber.
    if [ -z "$(git -C "$APP_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ] &&
       { git -C "$APP_DIR" remote set-url origin "$REPO" 2>/dev/null ||
         git -C "$APP_DIR" remote add origin "$REPO"; } &&
       git -C "$APP_DIR" fetch --depth 1 origin "$WANT_REF" &&
       git -C "$APP_DIR" checkout -B "$WANT_REF" FETCH_HEAD &&
       git -C "$APP_DIR" branch --set-upstream-to="origin/$WANT_REF"; then
        log "switched $APP_DIR to $WANT_REF (it was cloned without the port files)"
    else
        # Nothing here is worth keeping: it is upstream code that cannot run
        # this port, plus runtime files. Move it aside (never delete) so the
        # install can go on instead of stopping on a manual `mv` the user has
        # to repeat on the router.
        ASIDE="$APP_DIR.old.$(date +%Y%m%d%H%M%S 2>/dev/null || echo $$)"
        mv "$APP_DIR" "$ASIDE" ||
            die "cannot move $APP_DIR aside to $ASIDE - check free space and permissions"
        log "moved the unusable checkout (no port files, or local changes) to $ASIDE - safe to delete"
        log "cloning a fresh copy into $APP_DIR"
    fi
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
    log "cloning into $APP_DIR (bin/ and docs/ excluded)"
    # The tip tree carries ~188 MB of vendored binaries (bin/sing-box,
    # bin/sing-box.exe, geoip/geosite) that a router never executes: the app
    # skips a sing-box ELF built for another CPU and uses the router's own
    # sing-box package (quota/vpn_parser.py find_sing_box_binary). A plain
    # --depth 1 clone still transfers the whole tree (68.6 MiB pack) and stalls
    # mid-pack on a router. A blob-filtered sparse clone fetches only the code.
    #
    # The sparse patterns go into .git/info/sparse-checkout rather than through
    # `git sparse-checkout set --no-cone`: that flag only exists in git >= 2.37,
    # and older OpenWrt (22.03 ships 2.35) failed it, silently falling back to
    # the very full clone this avoids. The file form works on every git.
    BRANCH_ARG=
    [ -n "$REF" ] && BRANCH_ARG="--branch $REF"
    if git clone --depth 1 --filter=blob:none --no-checkout $BRANCH_ARG \
           "$REPO" "$APP_DIR" &&
       git -C "$APP_DIR" config core.sparseCheckout true &&
       printf '%s\n' '/*' '!/bin' '!/docs' > "$APP_DIR/.git/info/sparse-checkout" &&
       git -C "$APP_DIR" checkout; then
        :
    else
        # partial clone needs a git >= 2.19 on both ends; fall back to a full
        # shallow clone rather than leave the user with nothing.
        log "sparse clone unsupported here - falling back to a full shallow clone"
        rm -rf "$APP_DIR"
        git clone --depth 1 $BRANCH_ARG "$REPO" "$APP_DIR"
    fi
fi

have_port_tree || die "$APP_DIR has no requirements-openwrt.txt: that is the non-port branch (main), so the app would fail at startup with FileNotFoundError. Re-run with NETREX_REF=openwrt-mips-port, or remove $APP_DIR so the installer clones the right branch"

# MIPS routers have no Rust/C toolchain: requirements-openwrt.txt is pinned to
# pure-Python wheels (fastapi 0.115 + pydantic 1.10, plain uvicorn). Dev-only
# packages (pytest, httpx, pyflakes, aiohttp, webauthn) are never installed
# here; passkeys degrade to an honest "server-missing" answer without webauthn.
# pip --target installs the router deps beside the code; no venv (no
# ensurepip) and never requirements-linux.txt (needs compiled wheels).
mkdir -p "$PYLIB"
# pydantic 1.10 is the only fastapi line with pure-Python wheels for MIPS, and
# it does not run on Python 3.14 ("Core Pydantic V1 functionality isn't
# compatible with Python 3.14 or greater" -> ConfigError at import). OpenWrt
# master ships 3.14, so pick an interpreter <=3.13 and use it for pip AND for
# the service; otherwise run.py dies at import and procd respawns it forever
# while the dashboard never answers. Override with NETREX_PYTHON=/usr/bin/...
pick_python() {
    for cand in ${NETREX_PYTHON:-} python3.13 python3.12 python3.11 python3.10 python3.9 python3; do
        [ -n "$cand" ] || continue
        found=$(command -v "$cand" 2>/dev/null) || continue
        if "$found" -c 'import sys; raise SystemExit(0 if (3, 9) <= sys.version_info < (3, 14) else 1)' 2>/dev/null; then
            echo "$found"
            return 0
        fi
    done
    return 1
}
PYTHON=$(pick_python) || die "no pydantic-v1 compatible Python: pydantic 1.10 (the only version with MIPS wheels) needs Python 3.9-3.13, but none was found (system python3: $(command -v python3 >/dev/null 2>&1 && python3 -V 2>&1 || echo missing)). Install a 3.13 interpreter (python3 package from the OpenWrt 25.12 feed) or set NETREX_PYTHON=/path/to/python3.x and re-run"
log "python: $PYTHON ($("$PYTHON" -V 2>&1))"
mkdir -p "$CONF_DIR"
printf '%s\n' "$PYTHON" > "$CONF_DIR/python"
# A re-run used to reinstall everything: pip resolves the whole dependency
# graph in pure Python, which is the slowest step on a router. Skip it when
# pylib already holds every pin at its exact version. pip writes dist-info
# last, so a half-finished install fails this check and is repaired below;
# --upgrade with new pins changes the file and also reinstalls.
deps_ready() {
    [ -f "$APP_DIR/requirements-openwrt.txt" ] || return 1
    PYTHONPATH="$PYLIB" "$PYTHON" - "$APP_DIR/requirements-openwrt.txt" <<'PY'
import sys
try:
    from importlib import metadata
except ImportError:
    sys.exit(1)
want = []
for raw in open(sys.argv[1], encoding="utf-8"):
    line = raw.split("#", 1)[0].strip()
    if "==" not in line:
        continue
    name, ver = (p.strip() for p in line.split("==", 1))
    want.append((name, ver))
if not want:
    sys.exit(1)
for name, ver in want:
    try:
        have = metadata.version(name)
    except metadata.PackageNotFoundError:
        sys.exit(1)
    if have != ver:
        sys.exit(1)
PY
}
if deps_ready; then
    log "python deps already installed in $PYLIB - skipping pip"
else
    "$PYTHON" -m pip install --no-input --no-compile --target "$PYLIB" \
        -r "$APP_DIR/requirements-openwrt.txt"
fi

# Seed the config once; an existing admin config always wins.
#
# config.yaml ships the Debian laptop gateway's values: clients on a separate
# 192.168.2.0/24 and /var/lib/misc/dnsmasq.leases. On a router the box IS the
# LAN gateway, dnsmasq writes /tmp/dhcp.leases, and the client subnet, pool and
# netmask must be the real LAN. With the Debian values nothing is ever learned
# from the lease file, so no device is charged and no quota can cut it.
LAN_IP=$(uci -q get network.lan.ipaddr 2>/dev/null || true)
LAN_MASK=$(uci -q get network.lan.netmask 2>/dev/null || true)
# uci can return a list ("a.b.c.d/24 e.f.g.h/24", several addresses or a second
# bridge) and may store CIDR instead of a bare address. Keep the first token,
# drop any /prefix, and only accept a real dotted quad — this value goes into
# the config (dhcp.gateway_ip) and the printed dashboard URL.
LAN_IP=${LAN_IP%% *}
LAN_IP=${LAN_IP%%/*}
case "$LAN_IP" in
    *[!0-9.]*|*..*|[0-9]*.*.*.*.[!0-9]*|*[!0-9].*.*.*|[!0-9]*|*.[!0-9])
        LAN_IP=192.168.1.1 ;;
    *.*.*.*) ;;
    *) LAN_IP=192.168.1.1 ;;
esac
case "$LAN_MASK" in
    *.*.*) ;;
    */*) : ;;  # CIDR netmask handled below
    *) LAN_MASK=255.255.255.0 ;;
esac
case "$LAN_MASK" in
    */8)  LAN_MASK=255.0.0.0 ;;
    */16) LAN_MASK=255.255.0.0 ;;
    */24) LAN_MASK=255.255.255.0 ;;
    */25) LAN_MASK=255.255.255.128 ;;
    */26) LAN_MASK=255.255.255.192 ;;
    */27) LAN_MASK=255.255.255.224 ;;
    */28) LAN_MASK=255.255.255.240 ;;
    */29) LAN_MASK=255.255.255.248 ;;
    */30) LAN_MASK=255.255.255.252 ;;
esac
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
    # An older run of this installer could have written a mangled address
    # (a uci list like "192.168.2.1/24 192.168.1.110/24") into gateway_ip.
    # Repair only a value that is not a plain dotted quad.
    CUR_GW=$(awk '/^  gateway_ip:/{print $2; exit}' "$CONF_DIR/config.yaml")
    case "$CUR_GW" in
        [0-9]*.*.*.[0-9]) ;;
        *) set_dhcp gateway_ip "$LAN_IP"
           set_dhcp router_ip "$LAN_IP"
           log "repaired dhcp.gateway_ip -> $LAN_IP (was: ${CUR_GW:-empty})" ;;
    esac
fi

cp "$APP_DIR/scripts/quota-manager.openwrt" /etc/init.d/quota-manager
chmod +x /etc/init.d/quota-manager
/etc/init.d/quota-manager enable

# Netrex must be the only Router Advertisement / DHCPv6 source on the LAN.
# odhcpd keeps advertising the upstream router as the v6 gateway, so dual-stack
# clients prefer IPv6 for AAAA sites: that traffic either bypasses the box
# (uncounted, never blockable) or rides a broken upstream v6 path and hangs.
# IPv4 quota keeps working either way; on v6-only hangs only some sites open.
if command -v uci >/dev/null 2>&1; then
    if [ "$(uci -q get dhcp.lan.ra 2>/dev/null)" != "" ] ||
       [ "$(uci -q get dhcp.lan.dhcpv6 2>/dev/null)" != "" ] ||
       [ "$(uci -q get dhcp.lan.ra_management 2>/dev/null)" != "" ]; then
        uci set dhcp.lan.ra='0'
        uci set dhcp.lan.dhcpv6='0'
        uci set dhcp.lan.ra_management='0'
        uci commit dhcp
        /etc/init.d/odhcpd restart 2>/dev/null || true
        log "odhcpd RA/DHCPv6 disabled on LAN (Netrex is the only RA source)"
    fi
fi

/etc/init.d/quota-manager restart || /etc/init.d/quota-manager start
log "done. Dashboard: http://$LAN_IP:8080"
