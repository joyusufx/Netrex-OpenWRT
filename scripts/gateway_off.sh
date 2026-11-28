#!/bin/sh
# ===========================================================================
#  Netrex — turn the gateway off (System > Power in the dashboard)
# ---------------------------------------------------------------------------
#  Stops AND disables everything the gateway runs, so it stays off after a
#  reboot, and removes the kernel rules the app leaves in place on a normal
#  stop (nftables tables incl. the ARP gateway-lock, tc shaping). Started by
#  the app through quota/svcmgr.py (systemd-run on a systemd host, a detached
#  child on OpenWrt), a few seconds after the API answers, so it outlives the
#  service it stops.
#
#  POSIX sh on purpose: a stock router has BusyBox ash, no bash.
#
#  Turn it back on — systemd:  sudo systemctl enable --now dnsmasq quota-gateway
#                                (WAN mode also quota-wan-ppp)
#                     OpenWrt:  /etc/init.d/quota-manager enable && /etc/init.d/quota-manager start
#
#  Usage: gateway_off.sh [poweroff]
# ===========================================================================
set -u

log() { echo "[gateway-off] $*"; logger -t quota-gateway-off "$*" 2>/dev/null || true; }

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

log "turning the gateway off"
if [ -x /etc/init.d/quota-manager ]; then
    # procd router: dnsmasq and odhcpd are the router's own services (DHCP, DNS
    # and IPv6 RAs for every device) — stopping them would leave the home with
    # no network at all. Only Netrex goes off.
    /etc/init.d/quota-manager stop 2>/dev/null && log "stopped quota-manager"
    /etc/init.d/quota-manager disable 2>/dev/null && log "disabled quota-manager (stays off after a reboot)"
    rm -f /etc/rc.d/S*quota-manager 2>/dev/null || true
    for pid in $(pgrep -f "run\.py --config /etc/quota-gateway/config\.yaml" 2>/dev/null); do
        kill "$pid" 2>/dev/null || true
    done
    for pid in $(pgrep -f "/opt/quota-manager/bin/sing-box" 2>/dev/null); do
        kill "$pid" 2>/dev/null || true
    done
else
    for unit in quota-wan-ppp dnsmasq quota-gateway; do
        systemctl disable --now "$unit" >/dev/null 2>&1 && log "stopped + disabled $unit"
    done
fi

for table in quota_gateway quota_firewall quota_nat quota_schedule; do
    nft delete table inet "$table" 2>/dev/null && log "removed nftables table $table"
done
nft delete table arp quota_arp_lock 2>/dev/null && log "removed the ARP gateway-lock"

for dev in /sys/class/net/*; do
    dev="${dev##*/}"
    [ "$dev" = lo ] && continue
    tc qdisc del dev "$dev" root 2>/dev/null || true
    tc qdisc del dev "$dev" ingress 2>/dev/null || true
done
log "speed shaping removed"

if [ "${1:-}" = poweroff ]; then
    log "powering the machine off"
    if command -v systemctl >/dev/null 2>&1 && [ ! -x /etc/init.d/quota-manager ]; then
        systemctl poweroff
    else
        poweroff
    fi
fi
