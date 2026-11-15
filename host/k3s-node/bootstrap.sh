#!/bin/bash
# bootstrap.sh — make a fresh Debian 13 box a k3s node the way this cluster expects. Idempotent.
#
# Runs ON the node as root, fed over ssh. The join token is prepended to the script stream, so it is
# never in a command line, a log or this repo:
#
#   ROLE=agent  NODE_IP=192.168.1.x                                   # or ROLE=server
#   { printf 'K3S_TOKEN=%q\n' "$(ssh mimir@192.168.1.145 sudo cat /var/lib/rancher/k3s/server/token)"
#     cat host/k3s-node/bootstrap.sh; } \
#     | ssh <user>@<node-ip> "sudo ROLE=$ROLE NODE_IP=$NODE_IP bash -s"
#
# Then: host/k3s-node/verify.sh (same way, no token) must be green, then add the node's IP to the
# OMV exports (host/openmediavault/README.md).
#
# Every requirement here was learned on a live node (see host/k3s-node/README.md for why each exists).
set -euo pipefail
: "${ROLE:?ROLE=server|agent}" "${NODE_IP:?NODE_IP=<lan ip>}" "${K3S_TOKEN:?prepend K3S_TOKEN=... to the stream}"
K3S_VERSION=${K3S_VERSION:-v1.35.5+k3s1}        # = the cluster's servers; never "stable"
SERVER_URL=${SERVER_URL:-https://192.168.1.179:6443}   # the front door; in the servers' tls-san
NB_IP=${NB_IP:-}                                # NetBird IP, added to tls-san on servers
log(){ echo "[bootstrap $(hostname)] $*"; }

log "packages"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  nfs-common rsync avahi-daemon libnss-mdns iputils-arping dnsutils jq >/dev/null

log "/etc/hosts: OMV by name, without mDNS"
grep -qE '^192\.168\.1\.180[[:space:]].*openmediavault\.local' /etc/hosts ||
  echo "192.168.1.180   openmediavault.local openmediavault   # NFS/MinIO: kubelet mounts must not depend on mDNS" >> /etc/hosts

log "swap off"
swapoff -a || true
sed -i -E '/^[^#].*[[:space:]]swap[[:space:]]/s/^/# disabled for kubelet: /' /etc/fstab

if command -v netbird >/dev/null; then
  if grep -q '"DisableFirewall": *true' /var/lib/netbird/default.json 2>/dev/null; then
    log "netbird: DisableFirewall already true"
  else
    log "netbird: DisableFirewall -> true (ADR-013; otherwise k3s crash-loops on the next netbird restart)"
    netbird down >/dev/null 2>&1 || true
    timeout 60 netbird up --disable-firewall
  fi
fi

log "k3s $ROLE config"
mkdir -p /etc/rancher/k3s
umask 077
if [ "$ROLE" = server ]; then
  {
    printf 'server: %s\ntoken: %s\nnode-ip: %s\n' "$SERVER_URL" "$K3S_TOKEN" "$NODE_IP"
    printf 'disable:\n  - traefik\n  - servicelb\nflannel-backend: vxlan\n'   # MUST match every server
    printf 'tls-san:\n  - %s\n  - 192.168.1.179\n  - %s\n  - %s.local\n' "$NODE_IP" "$(hostname)" "$(hostname)"
    [ -n "$NB_IP" ] && printf '  - %s\n' "$NB_IP"
  } > /etc/rancher/k3s/config.yaml
else
  printf 'server: %s\ntoken: %s\nnode-ip: %s\n' "$SERVER_URL" "$K3S_TOKEN" "$NODE_IP" > /etc/rancher/k3s/config.yaml
fi
chmod 600 /etc/rancher/k3s/config.yaml

have=$(k3s --version 2>/dev/null | awk 'NR==1{print $3}')
if [ "$have" = "$K3S_VERSION" ]; then
  log "k3s $K3S_VERSION already installed"
else
  log "install k3s $K3S_VERSION ($ROLE)"
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - "$ROLE"
fi
log "done; run verify.sh"
