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

if [ -d "$APP_DIR/.git" ]; then
    log "updating $APP_DIR"
    git -C "$APP_DIR" pull --ff-only
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
mkdir -p "$CONF_DIR"
if [ ! -f "$CONF_DIR/config.yaml" ]; then
    cp "$APP_DIR/config.yaml" "$CONF_DIR/config.yaml"
    log "config written to $CONF_DIR/config.yaml"
fi

cp "$APP_DIR/scripts/quota-manager.openwrt" /etc/init.d/quota-manager
chmod +x /etc/init.d/quota-manager
/etc/init.d/quota-manager enable
/etc/init.d/quota-manager restart || /etc/init.d/quota-manager start
log "done. Dashboard: http://<router-ip>:8080"
