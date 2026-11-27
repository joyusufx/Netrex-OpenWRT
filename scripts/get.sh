#!/bin/sh
# Netrex - one-line installer.
#
#   wget -qO- https://raw.githubusercontent.com/UserJoo9/Netrex/main/scripts/get.sh | sudo sh
#
# In an OpenWrt router's root shell there is no sudo, so drop it:
#
#   wget -qO- https://raw.githubusercontent.com/UserJoo9/Netrex/main/scripts/get.sh | sh
#
# It looks at the machine it runs on and uses that system's own install path,
# so the result is what README.md describes by hand:
#   OpenWrt router  -> scripts/install_openwrt.sh (apk or opkg, procd service)
#   Debian family   -> the signed apt repository, then `apt-get install netrex`
#   Fedora / Arch   -> the release package for that distribution
#   anything else   -> the release tarball and its install.sh
#
# Options (or the matching environment variable):
#   --repo OWNER/NAME   install from a fork (NETREX_REPO, default UserJoo9/Netrex)
#   --ref REF           branch or tag the router installer clones (NETREX_REF, default main)
#   -h, --help          show this text
#
# POSIX sh only: it runs under BusyBox ash on a router and dash on Debian.
set -eu

DEFAULT_REPO=UserJoo9/Netrex
DEFAULT_REF=main
REPO=${NETREX_REPO:-$DEFAULT_REPO}
REF=${NETREX_REF:-$DEFAULT_REF}
CHANNEL=${NETREX_APT_CHANNEL:-stable}

log() { echo "[netrex] $*"; }
die() { echo "[netrex] ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<'EOF'
Netrex one-line installer.

  wget -qO- https://raw.githubusercontent.com/UserJoo9/Netrex/main/scripts/get.sh | sudo sh

Options:
  --repo OWNER/NAME   install from a fork (env: NETREX_REPO), default UserJoo9/Netrex
  --ref REF           branch or tag the router installer clones (env: NETREX_REF), default main
  -h, --help          show this text
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
        --repo)   [ $# -ge 2 ] || die "--repo needs OWNER/NAME"; REPO=$2; shift 2 ;;
        --repo=*) REPO=${1#*=}; shift ;;
        --ref)    [ $# -ge 2 ] || die "--ref needs a branch or tag"; REF=$2; shift 2 ;;
        --ref=*)  REF=${1#*=}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done
case $REPO in
    */*) ;;
    *) die "--repo must look like OWNER/NAME (got: $REPO)" ;;
esac
OWNER=${REPO%%/*}
NAME=${REPO##*/}
SITE=${NETREX_SITE:-https://$OWNER.github.io/$NAME}

[ "$(id -u)" -eq 0 ] || die "run this as root:  wget -qO- https://raw.githubusercontent.com/$REPO/$REF/scripts/get.sh | sudo sh"

TMP=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' HUP INT TERM

# -f so an HTTP error is a failure, and https-only: the same script is piped
# into a root shell, so it must never be fetched over plain http.
fetch() {  # fetch URL FILE
    if have curl; then
        curl -fsSL --proto '=https' --tlsv1.2 "$1" -o "$2"
    elif have wget; then
        wget -q -O "$2" "$1"
    else
        return 127
    fi
}

# The latest release's download URL whose file name matches $1 (a grep -E
# pattern). Forks without releases simply have none.
release_asset() {
    fetch "https://api.github.com/repos/$REPO/releases/latest" "$TMP/release.json" || return 1
    tr ',' '\n' < "$TMP/release.json" \
        | sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' \
        | grep -E "$1" | head -n 1
}

download_asset() {  # PATTERN -> prints the local file
    url=$(release_asset "$1") || return 1
    [ -n "$url" ] || return 1
    file=$TMP/${url##*/}
    # stderr: this function's stdout is the file name the caller captures.
    echo "[netrex] downloading ${url##*/}" >&2
    fetch "$url" "$file" || return 1
    printf '%s\n' "$file"
}

install_tarball() {
    tgz=$(download_asset '\.tar\.gz$') \
        || die "no release package found for $REPO - see https://github.com/$REPO/releases"
    mkdir -p "$TMP/unpack"
    tar -xzf "$tgz" -C "$TMP/unpack" || die "cannot unpack $tgz"
    # The release tarball is netrex-<v>/ since 0.6.0 and quota-manager-<v>/
    # before that, so find the installer instead of trusting the name.
    script=$(find "$TMP/unpack" -maxdepth 2 -name install.sh | head -n 1)
    [ -n "$script" ] || die "the release tarball has no install.sh"
    if have bash; then
        bash "$script"
    else
        sh "$script"
    fi
}

install_debian() {
    apt-get update -qq || die "apt-get update failed - check the network"
    if ! have curl && ! have wget; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl \
            || die "cannot install curl"
    fi
    have gpg || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gnupg \
        || die "cannot install gnupg (needed to trust the apt key)"
    if fetch "$SITE/quota-manager.gpg" "$TMP/quota-manager.gpg"; then
        log "trusting the Netrex apt repository at $SITE"
        mkdir -p /etc/apt/keyrings
        gpg --batch --yes --dearmor < "$TMP/quota-manager.gpg" \
            > /etc/apt/keyrings/quota-manager.gpg \
            || die "the apt key downloaded from $SITE is not a valid key"
        chmod 644 /etc/apt/keyrings/quota-manager.gpg
        printf 'deb [signed-by=/etc/apt/keyrings/quota-manager.gpg] %s %s main\n' \
            "$SITE" "$CHANNEL" > /etc/apt/sources.list.d/quota-manager.list
        apt-get update -qq || die "apt-get update failed after adding the repository"
        # The apt repo still carries the pre-0.6 name until the first netrex
        # release is published; both install the same gateway.
        DEBIAN_FRONTEND=noninteractive apt-get install -y netrex \
            || DEBIAN_FRONTEND=noninteractive apt-get install -y quota-manager \
            || die "apt-get could not install netrex - see https://github.com/$REPO/releases"
        return 0
    fi
    log "no apt repository at $SITE - using the release package instead"
    deb=$(download_asset '_all\.deb$') \
        || die "no .deb release or apt site found for $REPO - clone the fork and run scripts/setup_gateway_kali.sh, or see https://github.com/$REPO/releases"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb"
}

install_fedora() {
    rpm=$(download_asset '\.noarch\.rpm$') || rpm=
    if [ -n "$rpm" ] && dnf install -y "$rpm"; then
        return 0
    fi
    log "no rpm release package - falling back to the release tarball"
    install_tarball
}

install_arch() {
    pkg=$(download_asset '\.pkg\.tar\.zst$') || pkg=
    if [ -n "$pkg" ] && pacman -U --noconfirm "$pkg"; then
        return 0
    fi
    log "no Arch release package - falling back to the release tarball"
    install_tarball
}

install_openwrt() {
    # The OpenWrt port lives on the Netrex-OpenWRT fork's openwrt-mips-port
    # branch; $REPO/main carries the pre-port installer (installs into
    # /opt/QuotaManager from requirements-linux). Fetch the installer from the
    # same place the code will be cloned from, so a bare run cannot execute
    # code that does not match the port. An explicit --repo/--ref wins.
    port_repo=joyusufx/Netrex-OpenWRT
    port_ref=openwrt-mips-port
    if [ "$REPO" = "$DEFAULT_REPO" ] && [ "$REF" = "$DEFAULT_REF" ]; then
        src_repo=$port_repo
        src_ref=$port_ref
    else
        src_repo=$REPO
        src_ref=$REF
    fi
    url="https://raw.githubusercontent.com/$src_repo/$src_ref/scripts/install_openwrt.sh"
    if ! fetch "$url" "$TMP/install_openwrt.sh"; then
        # A stock router may have no CA bundle yet, so https fails until it is
        # installed - which is a chicken-and-egg the installer below solves.
        log "download failed - installing the HTTPS certificates and retrying"
        if have apk; then
            apk add ca-bundle >/dev/null 2>&1 || true
        elif have opkg; then
            opkg install ca-bundle >/dev/null 2>&1 || true
        fi
        fetch "$url" "$TMP/install_openwrt.sh" \
            || die "cannot download $url - check the router's internet access, DNS and clock"
    fi
    # Hand the resolved repo/ref to the installer; its own defaults agree, so
    # this only pins them when the caller chose something else.
    NETREX_GIT_URL="https://github.com/$src_repo.git" \
    NETREX_REF=$src_ref \
        sh "$TMP/install_openwrt.sh"
}

if [ -f /etc/openwrt_release ] || have uci; then
    log "OpenWrt router detected"
    install_openwrt
elif have apt-get; then
    log "Debian family detected (apt)"
    install_debian
elif have dnf; then
    log "Fedora family detected (dnf)"
    install_fedora
elif have pacman; then
    log "Arch family detected (pacman)"
    install_arch
else
    log "no known package manager - using the generic release tarball"
    install_tarball
fi

log "done. Open the dashboard at http://<this-machine-ip>:8080"
