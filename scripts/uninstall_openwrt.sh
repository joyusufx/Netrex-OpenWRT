#!/bin/sh
# Netrex (Quota Manager) - complete uninstall for OpenWrt (BusyBox ash, POSIX sh).
#   sh uninstall_openwrt.sh              # remove the app, its data and every
#                                        # kernel object it programmed
#   NETREX_KEEP_DATA=1 sh uninstall_openwrt.sh
#                                        # same, but keep the database/config in
#                                        # /etc/quota-gateway (moved to /root)
#
# Everything the installer and the running app touched is reverted: the procd
# service, the nftables tables, the tc shaping, the VPN policy routing, the
# dnsmasq/sysctl fragments, the odhcpd RA switch, and the files under
# /opt/quota-manager and /etc/quota-gateway. Every step is guarded, so running
# it twice (or on a box where Netrex was only half installed) is safe.
#
# Packages Netrex installed (python3, py3-pip, kmod-ifb, tc, ip-full, ...) are
# left in place: other software on the router may use them. Remove them by
# hand if you really want them gone.

set -u

APP_DIR=${APP_DIR:-/opt/quota-manager}
CONF_DIR=${CONF_DIR:-/etc/quota-gateway}
KEEP_DATA=${NETREX_KEEP_DATA:-0}
NFT_TABLES="quota_gateway quota_nat quota_firewall quota_schedule"
RESTORE_DIR=/root/netrex-uninstall-$(date +%Y%m%d-%H%M%S)

# The VPN-share rule prefs/table are configurable (config.yaml vpn_share.*), so
# read them from the box's own config before it is deleted; fall back to the
# shipped defaults (route_table 200, rule_pref 1000, exclusions at pref-1).
cfg_vpn_value() {
    [ -r "$CONF_DIR/config.yaml" ] || return 0
    awk -v key="$1" '
        /^vpn_share:/ { inside = 1; next }
        /^[^[:space:]#]/ { inside = 0 }
        inside && $1 == key":" { gsub(/[^0-9]/, "", $2); print $2; exit }
    ' "$CONF_DIR/config.yaml"
}
ROUTE_TABLE=${ROUTE_TABLE:-$(cfg_vpn_value route_table)}
RULE_PREF=${RULE_PREF:-$(cfg_vpn_value rule_pref)}
ROUTE_TABLE=${ROUTE_TABLE:-200}
RULE_PREF=${RULE_PREF:-1000}
EXCL_PREF=$((RULE_PREF - 1))

FAILED=""

log() { echo "[netrex-uninstall] $*"; }
warn() { echo "[netrex-uninstall] $*" >&2; }
fail() { FAILED="$FAILED
  - $*"; }

if [ "$(id -u)" != "0" ]; then
    echo "[netrex-uninstall] ERROR: run this as root (ssh root@<router>)" >&2
    exit 1
fi

# ---------------------------------------------------------------- service ---

log "stopping the service"
if [ -x /etc/init.d/quota-manager ]; then
    /etc/init.d/quota-manager stop 2>/dev/null || true
    /etc/init.d/quota-manager disable 2>/dev/null || true
else
    log "  /etc/init.d/quota-manager not present"
fi
rm -f /etc/rc.d/S*quota-manager /etc/rc.d/K*quota-manager 2>/dev/null || true
rm -f /etc/init.d/quota-manager 2>/dev/null || true

# procd respawns while the service is enabled; stop anything that survived.
for pid in $(pgrep -f "run\.py --config $CONF_DIR/config\.yaml" 2>/dev/null); do
    [ "$pid" = "$$" ] && continue
    kill "$pid" 2>/dev/null || true
done
sleep 2
for pid in $(pgrep -f "run\.py --config $CONF_DIR/config\.yaml" 2>/dev/null); do
    kill -9 "$pid" 2>/dev/null || true
done

# sing-box is the app's child; match its own binary so a VPN the admin runs by
# hand is not touched.
for pid in $(pgrep -f "$APP_DIR/bin/sing-box" 2>/dev/null); do
    kill -9 "$pid" 2>/dev/null || true
done

# --------------------------------------------------------------- nftables ---

log "deleting nftables tables"
for t in $NFT_TABLES; do
    if nft list table inet "$t" >/dev/null 2>&1; then
        if nft delete table inet "$t" 2>/dev/null; then
            log "  deleted inet $t"
        else
            fail "could not delete inet $t"
        fi
    fi
done
if nft list table arp quota_arp_lock >/dev/null 2>&1; then
    if nft delete table arp quota_arp_lock 2>/dev/null; then
        log "  deleted arp quota_arp_lock"
    else
        fail "could not delete arp quota_arp_lock"
    fi
fi

# -------------------------------------------------------------- tc shaping ---

lan_if=$(uci -q get network.lan.device 2>/dev/null || true)
[ -n "$lan_if" ] || lan_if=$(uci -q get network.lan.ifname 2>/dev/null || true)
# uci can return several devices on one line; the word split is intended - take
# the first. (shellcheck disable=SC2086: we want that split.)
# shellcheck disable=SC2086
set -- $lan_if
lan_if=${1:-br-lan}
wan_if=$(uci -q get network.wan.device 2>/dev/null || true)
[ -n "$wan_if" ] || wan_if=$(uci -q get network.wan.ifname 2>/dev/null || true)
# shellcheck disable=SC2086
set -- $wan_if
wan_if=${1:-}

log "clearing tc qdiscs"
for dev in "$lan_if" "$wan_if" ifb0; do
    [ -n "$dev" ] || continue
    [ -d "/sys/class/net/$dev" ] || continue
    tc qdisc del dev "$dev" root 2>/dev/null || true
    tc qdisc del dev "$dev" ingress 2>/dev/null || true
done
ip link set ifb0 down 2>/dev/null || true

# --------------------------------------------------------- policy routing ---

log "removing VPN-share policy routing (table $ROUTE_TABLE, pref $RULE_PREF)"
for pref in $(ip rule show 2>/dev/null | awk -v t="lookup $ROUTE_TABLE" 'index($0,t){sub(":","",$1); print $1}'); do
    ip rule del pref "$pref" 2>/dev/null || true
done
ip route flush table "$ROUTE_TABLE" 2>/dev/null || true
# per-device exclusions the share adds at pref-1 (and the share rule itself, if
# its pref was configured away from the default)
for pref in $(ip rule show 2>/dev/null | awk -v p="$EXCL_PREF" -v r="$RULE_PREF" '
        { n = $1; sub(":", "", n) }
        n == p || n == r { print n }'); do
    ip rule del pref "$pref" 2>/dev/null || true
done

# ------------------------------------------------------- dnsmasq fragments ---

log "removing dnsmasq fragments"
removed_fragment=0
for d in /tmp/dnsmasq.d /etc/dnsmasq.d; do
    for f in "$d"/quota-*.conf; do
        [ -e "$f" ] || continue
        if rm -f "$f"; then
            removed_fragment=1
        else
            fail "could not remove $f"
        fi
    done
done
[ "$removed_fragment" = "1" ] || log "  no fragments present"

# ------------------------------------------------------ host config: sysctl ---

log "removing the IPv6 sysctl fragment"
rm -f /etc/sysctl.d/99-zz-quota-ipv6.conf 2>/dev/null || fail "could not remove /etc/sysctl.d/99-zz-quota-ipv6.conf"
# conntrack accounting is a global kernel counter Netrex switched on for
# per-destination byte counting; put it back to the OpenWrt default.
if [ -w /proc/sys/net/netfilter/nf_conntrack_acct ]; then
    echo 0 >/proc/sys/net/netfilter/nf_conntrack_acct 2>/dev/null || true
fi

# --------------------------------------------------------- odhcpd handback ---

# The installer turned odhcpd's RA/DHCPv6 off on the LAN because Netrex was the
# only router-advertisement source. With Netrex gone nobody would answer RA
# any more, so dual-stack clients would hang on AAAA lookups.
log "giving IPv6 RA/DHCPv6 back to odhcpd"
if command -v uci >/dev/null 2>&1; then
    uci -q set dhcp.lan.ra='server' || true
    uci -q set dhcp.lan.dhcpv6='server' || true
    uci -q set dhcp.lan.ra_management='1' || true
    uci -q commit dhcp || fail "could not commit the dhcp config"
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || fail "dnsmasq restart failed"
    /etc/init.d/odhcpd restart >/dev/null 2>&1 || /etc/init.d/odhcpd start >/dev/null 2>&1 || true
    sleep 1
    pgrep -f "dnsmasq" >/dev/null 2>&1 || fail "dnsmasq is not running - restart it by hand"
else
    warn "uci not found - check dhcp.lan.ra/dhcpv6 by hand"
fi

# ------------------------------------------------------------------- files ---

if [ "$KEEP_DATA" = "1" ] && [ -d "$CONF_DIR" ]; then
    mkdir -p "$RESTORE_DIR" 2>/dev/null || true
    for f in quota.db config.yaml ip-owners.json firewall_config.json; do
        [ -e "$CONF_DIR/$f" ] && cp -p "$CONF_DIR/$f" "$RESTORE_DIR/" 2>/dev/null
    done
    [ -d "$CONF_DIR/firewall_snapshots" ] && \
        cp -rp "$CONF_DIR/firewall_snapshots" "$RESTORE_DIR/" 2>/dev/null
    log "kept data in $RESTORE_DIR"
fi

log "removing $APP_DIR"
rm -rf "$APP_DIR" 2>/dev/null || fail "could not remove $APP_DIR"
# stale checkouts from the installer's heal path (/opt/quota-manager.old.<ts>)
for d in "$APP_DIR".old.*; do
    [ -e "$d" ] || continue
    rm -rf "$d" 2>/dev/null || fail "could not remove $d"
done

log "removing $CONF_DIR"
rm -rf "$CONF_DIR" 2>/dev/null || fail "could not remove $CONF_DIR"

# ---------------------------------------------------------------- summary ---

echo
if [ -n "$FAILED" ]; then
    warn "finished with problems:$FAILED"
    warn "re-run this script after fixing them (it is safe to re-run)."
else
    log "Netrex is removed: service, nftables tables, tc shaping, policy routing,"
    log "dnsmasq/sysctl fragments, odhcpd RA restored, $APP_DIR and $CONF_DIR gone."
fi
log "reboot the router once so nothing cached in the kernel survives."
log "packages Netrex installed (python3, py3-pip, kmod-ifb, tc, ip-full) were kept."

[ -n "$FAILED" ] && exit 1
exit 0
