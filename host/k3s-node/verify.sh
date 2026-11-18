#!/bin/bash
# verify.sh — read-only check that a k3s node meets this cluster's bootstrap requirements.
# Runs ON the node; prints PASS/FAIL/WARN/SKIP per requirement and exits non-zero on any FAIL.
#
#   ssh mimir@192.168.1.145 'bash -s' < host/k3s-node/verify.sh
#   for h in mimir@192.168.1.145 loki@192.168.1.190; do ssh "$h" 'bash -s' < host/k3s-node/verify.sh; done
#
# Requirements and their reasons: host/k3s-node/README.md. Without passwordless sudo, root-only
# checks report SKIP (arr-box today).
K3S_VERSION=${K3S_VERSION:-v1.35.5+k3s1}
fail=0
S=""; sudo -n true 2>/dev/null && S="sudo -n"
pass(){ printf 'PASS  %s\n' "$*"; }
bad(){  printf 'FAIL  %s\n' "$*"; fail=1; }
skip(){ printf 'SKIP  %s\n' "$*"; }
echo "== $(hostname)"

[ -n "$S" ] && pass "passwordless sudo" || skip "passwordless sudo (root-only checks skipped)"

command -v mount.nfs >/dev/null || [ -x /sbin/mount.nfs ] && pass "nfs-common (mount.nfs)" || bad "nfs-common missing: kubelet can't mount the OMV NFS PVs"

ip=$(getent hosts openmediavault.local | awk '{print $1; exit}')
[ "$ip" = 192.168.1.180 ] && pass "openmediavault.local -> 192.168.1.180" || bad "openmediavault.local resolves to '${ip:-nothing}' (all NFS PVs use this name)"

grep -qE '^192\.168\.1\.180[[:space:]].*openmediavault\.local' /etc/hosts \
  && pass "/etc/hosts pins OMV (no mDNS dependency)" || bad "/etc/hosts has no OMV line"

svc=k3s-agent; systemctl list-unit-files k3s.service >/dev/null 2>&1 && systemctl is-enabled k3s >/dev/null 2>&1 && svc=k3s
warn(){ printf 'WARN  %s\n' "$*"; }
if [ "$(awk 'NR>1' /proc/swaps | wc -l)" = 0 ]; then pass "no swap active"
elif [ "$svc" = k3s ]; then bad "swap is on a SERVER: etcd and the apiserver can be paged out (API stalls). Fix: swapoff -a + comment out the fstab swap line"
else warn "swap is on (agent; kubelet NoSwap keeps pods off it). Turning it off on a small board (zram) can OOM it: decide per node"; fi

if command -v netbird >/dev/null; then
  if [ -n "$S" ]; then
    if $S grep -q '"DisableFirewall": *true' /var/lib/netbird/default.json 2>/dev/null \
       && ! $S nft list tables 2>/dev/null | grep -q netbird; then
      pass "netbird DisableFirewall (ADR-013)"
    else
      bad "netbird firewall ENABLED: next netbird restart crash-loops k3s (ADR-013). Fix: netbird down; netbird up --disable-firewall"
    fi
  else
    skip "netbird DisableFirewall (needs root to read /var/lib/netbird/default.json)"
  fi
else
  pass "netbird not installed (nothing to check)"
fi

[ "$(systemctl is-active $svc)" = active ] && pass "$svc active" || bad "$svc not active"
have=$(k3s --version 2>/dev/null | awk 'NR==1{print $3}')
[ "$have" = "$K3S_VERSION" ] && pass "k3s $have" || bad "k3s ${have:-missing}, cluster runs $K3S_VERSION"

if [ -n "$S" ]; then
  cfg=$($S cat /etc/rancher/k3s/config.yaml 2>/dev/null)
  echo "$cfg" | grep -q '^node-ip:' && pass "node-ip pinned" || bad "node-ip not pinned (docker0/wt0 can win the IP lottery)"
  if [ "$svc" = k3s ]; then
    for want in 'traefik' 'servicelb' 'flannel-backend: vxlan' '192.168.1.179'; do
      echo "$cfg" | grep -q -- "$want" && pass "server config has '$want'" || bad "server config lacks '$want' (flags must match every server; .179 must be in tls-san)"
    done
  fi
else
  skip "k3s config (root-only)"
fi

exit $fail
