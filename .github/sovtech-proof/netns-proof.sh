#!/bin/bash
# Runs inside a fresh, throwaway network namespace. Reproduces the policy rule and
# table that nvpn's Linux WireGuard upstream installs, next to a local 10.44.0.0/24 network.
set -eu
echo "kernel $(uname -r); $(ip -V)"
ip link set lo up
for spec in "lan0 10.44.0.1/24" "nvpn0 10.44.37.99/32" "nvwg0 10.77.0.2/32" "eth9 192.0.2.10/24"; do
  set -- $spec
  ip link add "$1" type dummy
  ip addr add "$2" dev "$1"
  ip link set "$1" up
done
ip route add default via 192.0.2.1 dev eth9
ip route add 10.44.12.34/32 dev nvpn0          # a mesh peer's /32, as nvpn installs
sysctl -qw net.ipv4.ip_forward=1
for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$f"; done
# Table 51888 exactly as replace_linux_policy_mesh_route + replace_linux_policy_default_route build it.
ip -4 route replace 10.44.0.0/16 dev nvpn0 table 51888
ip -4 route replace default dev nvwg0 table 51888

probe() {
  echo "-- host reply from its own 10.44.0.1 to a local host 10.44.0.5:"
  ip -4 route get 10.44.0.5 from 10.44.0.1
  echo "-- local host 10.44.0.5 forwarded to the internet (iif lan0):"
  ip -4 route get 1.1.1.1 from 10.44.0.5 iif lan0
  echo "-- mesh peer 10.44.12.34 forwarded to the internet (iif nvpn0):"
  ip -4 route get 1.1.1.1 from 10.44.12.34 iif nvpn0
}

echo "== BEFORE: rule as shipped (from 10.44.0.0/16)"
ip -4 rule add priority 10888 from 10.44.0.0/16 table 51888
ip -4 rule show | grep 10888
probe
ip -4 rule del priority 10888 from 10.44.0.0/16 table 51888

echo "== AFTER: rule scoped to the mesh interface (from 10.44.0.0/16 iif nvpn0)"
ip -4 rule add priority 10888 from 10.44.0.0/16 iif nvpn0 table 51888
ip -4 rule show | grep 10888
probe

echo "== the existing delete command (no iif) removes the scoped rule"
ip -4 rule del priority 10888 from 10.44.0.0/16 table 51888
echo "rules at 10888 after delete: $(ip -4 rule show | grep -c '^10888:' || true)"
