#!/bin/sh
# Front-door address for the house: 192.168.1.179 on mimir (DHCP-advertised DNS, NodePorts).
# OPNsense lets only .179 send DNS upstream, so Pi-hole's upstreams are routed with src .179.
#
# Waits for the DHCP default route first: on 2026-11-16 the unit ran before dhcpcd had a
# gateway, `ip route replace ... via 192.168.1.1` failed with "Nexthop has invalid gateway",
# a trailing `|| true` hid it, and the house had no DNS until the routes were added by hand.
set -eu

DEV=enp1s0
VIP=192.168.1.179
GW=192.168.1.1
UPSTREAMS="1.1.1.1 1.0.0.1"

i=0
until ip -4 route show default dev "$DEV" | grep -q "via $GW"; do
  i=$((i + 1))
  if [ "$i" -gt 90 ]; then
    echo "no default route via $GW on $DEV after 90s" >&2
    exit 1
  fi
  sleep 1
done

ip addr replace "$VIP/24" dev "$DEV" label "$DEV:fd"
for u in $UPSTREAMS; do
  ip route replace "$u/32" via "$GW" dev "$DEV" src "$VIP"
done

# Verify instead of trusting exit codes.
for u in $UPSTREAMS; do
  ip -4 route show "$u/32" | grep -q "src $VIP" || { echo "route $u src $VIP missing" >&2; exit 1; }
done

arping -U -c 3 -I "$DEV" "$VIP" >/dev/null 2>&1 || echo "gratuitous ARP failed (non-fatal)" >&2
echo "front door $VIP up on $DEV, upstream routes via $GW src $VIP"
