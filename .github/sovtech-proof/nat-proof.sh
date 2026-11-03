#!/bin/bash
# Exit-node NAT with a local network inside the mesh source range.
#
# Namespaces: an exit node with a mesh ingress interface (a veth standing in
# for the TUN, which only carries admitted packets), a local 10.44.0.0/24
# network, and an uplink to an "internet" namespace that counts arriving ICMP
# by source address. The host has its own SNAT for the local network, added
# after nvpn's rules, as a firewall reload would.
set -eu

NAMESPACES="nvpn-exit nvpn-lan nvpn-mesh nvpn-inet"
cleanup() { for ns in $NAMESPACES; do ip netns del "$ns" 2>/dev/null || true; done; }
trap cleanup EXIT
cleanup
for ns in $NAMESPACES; do ip netns add "$ns"; ip -n "$ns" link set lo up; done
EXIT="ip netns exec nvpn-exit"
INET="ip netns exec nvpn-inet"

ip link add name nvpn0 netns nvpn-exit type veth peer name eth0 netns nvpn-mesh
ip link add name lan0 netns nvpn-exit type veth peer name eth0 netns nvpn-lan
ip link add name wan0 netns nvpn-exit type veth peer name eth0 netns nvpn-inet

$EXIT ip addr add 10.44.37.99/32 dev nvpn0
$EXIT ip addr add 10.44.0.1/24 dev lan0
$EXIT ip addr add 192.0.2.10/24 dev wan0
for dev in nvpn0 lan0 wan0; do $EXIT ip link set "$dev" up; done
$EXIT ip route add 10.44.12.34/32 dev nvpn0
$EXIT ip route add default via 192.0.2.1 dev wan0
$EXIT sysctl -qw net.ipv4.ip_forward=1
for conf in all default nvpn0 lan0 wan0; do $EXIT sysctl -qw "net.ipv4.conf.$conf.rp_filter=0"; done

ip -n nvpn-mesh addr add 10.44.12.34/32 dev eth0
ip -n nvpn-mesh link set eth0 up
ip -n nvpn-mesh route add 10.44.37.99/32 dev eth0
ip -n nvpn-mesh route add default via 10.44.37.99 dev eth0 onlink

ip -n nvpn-lan addr add 10.44.0.5/24 dev eth0
ip -n nvpn-lan link set eth0 up
ip -n nvpn-lan route add default via 10.44.0.1

ip -n nvpn-inet addr add 192.0.2.1/24 dev eth0
ip -n nvpn-inet link set eth0 up
ip -n nvpn-inet addr add 198.51.100.1/32 dev lo
$INET iptables -N SRC
$INET iptables -A INPUT -p icmp --icmp-type echo-request -j SRC
for source in 192.0.2.10 192.0.2.99 10.44.0.5 10.44.12.34; do
  $INET iptables -A SRC -s "$source" -j RETURN
done

# Source address seen by the internet for one ping from namespace $1.
arrived_as() {
  $EXIT conntrack -F >/dev/null 2>&1 || true
  $INET iptables -Z SRC
  ip netns exec "$1" ping -c1 -W1 198.51.100.1 >/dev/null 2>&1 || true
  $INET iptables -nvxL SRC | awk 'NR > 2 && $1 > 0 { print $8 }' | paste -sd, -
}

nvpn_forward_rules() {
  $EXIT iptables -I FORWARD 1 -i nvpn0 -o wan0 -s 10.44.0.0/16 \
    -m comment --comment nvpn-exit-forward-in -j ACCEPT
  $EXIT iptables -I FORWARD 1 -i wan0 -o nvpn0 -m conntrack --ctstate RELATED,ESTABLISHED \
    -m comment --comment nvpn-exit-forward-out -j ACCEPT
}
host_snat_for_lan() {
  $EXIT iptables -t nat -A POSTROUTING -s 10.44.0.0/24 -o wan0 -j SNAT --to-source 192.0.2.99
}
reset_rules() {
  for table in filter nat mangle; do $EXIT iptables -t "$table" -F; done
}

failed=0
check() { # label actual expected
  if [ "$2" = "$3" ]; then echo "  ok   $1: $2"; else echo "  FAIL $1: $2 (expected $3)"; failed=1; fi
}

echo "kernel $(uname -r); $(iptables --version)"
echo "== rules as shipped: POSTROUTING -o wan0 -s 10.44.0.0/16 -j MASQUERADE"
nvpn_forward_rules
$EXIT iptables -t nat -A POSTROUTING -o wan0 -s 10.44.0.0/16 \
  -m comment --comment nvpn-exit-masq -j MASQUERADE
host_snat_for_lan
before_lan="$(arrived_as nvpn-lan)"
before_mesh="$(arrived_as nvpn-mesh)"
echo "  local 10.44.0.5 arrives as:  $before_lan (host SNAT wants 192.0.2.99)"
echo "  mesh 10.44.12.34 arrives as: $before_mesh"

reset_rules
echo "== this change: CONNMARK at mesh ingress, MASQUERADE only marked connections"
nvpn_forward_rules
$EXIT iptables -t mangle -I FORWARD 1 -i nvpn0 -o wan0 -s 10.44.0.0/16 \
  -m comment --comment nvpn-exit-ingress -j CONNMARK --set-xmark 0x1000000/0x1000000
$EXIT iptables -t nat -A POSTROUTING -o wan0 -s 10.44.0.0/16 \
  -m connmark --mark 0x1000000/0x1000000 -m comment --comment nvpn-exit-masq -j MASQUERADE
host_snat_for_lan
check "local network keeps the host's own SNAT" "$(arrived_as nvpn-lan)" 192.0.2.99
check "mesh traffic is still masqueraded" "$(arrived_as nvpn-mesh)" 192.0.2.10

echo "== the shipped rule reproduced the capture"
check "shipped rule masqueraded the local network" "$before_lan" 192.0.2.10
check "shipped rule masqueraded the mesh" "$before_mesh" 192.0.2.10
exit "$failed"
