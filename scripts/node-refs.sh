#!/usr/bin/env bash
# node-refs.sh <hostname> <lan-ip> [netbird-ip]
#
# Read-only sweep for everything that names a node: what breaks if the box goes away, beyond its
# pods. Run it before decommissioning or replacing a node, and again after (it should print nothing
# but the headers). See docs/runbooks/decommission-node.md.
#
# Written after the 2026-11-12 Clevo retirement, where each of these was found by breaking it:
# NFS exports keyed on the node IP, the OPNsense "only .179 may do DNS" rule, a NetBird network
# route whose routing peer was the node, Hermes/Paperclip configs pinning its addresses.
#
# Sources (each best-effort, with a timeout; a source prints '(no matches)' or '(UNREACHABLE…)'):
#   repo      git grep in this checkout
#   cluster   node pins (nodeSelector / affinity), local PVs, CNPG clusters, the Node object
#   omv       /etc/exports on 192.168.1.180          (ssh root@192.168.1.180, else via the Air)
#   air       ~/.hermes, ~/.paperclip, ~/.config     (ssh ${AIR_SSH:-paperclip.local}, falls back to paperclip)
#   manual    things no tool here can read: printed as a checklist
set -uo pipefail
NAME=${1:?usage: node-refs.sh <hostname> <lan-ip> [netbird-ip]}
LAN=${2:?usage: node-refs.sh <hostname> <lan-ip> [netbird-ip]}
NB=${3:-}
ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=10 -o ServerAliveCountMax=2)

# IPs match exactly. The hostname is matched only in node-ish contexts (pins, ssh targets, .local /
# .netbird names): a bare "loki" would also match the Grafana Loki app everywhere.
ip_re() { printf '%s' "$1" | sed 's/\./\\./g'; }
IPS="$(ip_re "$LAN")"; [ -n "$NB" ] && IPS="$IPS|$(ip_re "$NB")"
IP_PAT="(^|[^0-9.])($IPS)([^0-9]|$)"
HOST_PAT="(hostname: *\"?$NAME\"?\$|values: *\[\"?$NAME\"?\]|^ *- \"?$NAME\"?\$|$NAME\.local|$NAME\.netbird|ssh +[a-z0-9]*@?$NAME([^a-z0-9-]|\$))"

hdr() { printf '\n== %s\n' "$*"; }

hdr "repo: IP references ($LAN${NB:+, $NB})"
git -C "$ROOT" grep -nIE "$IP_PAT" -- . ':!*.sops.yaml' ':!docs/adr/*' | cut -c1-200

hdr "repo: hostname '$NAME' in node pins, ssh targets, .local/.netbird names"
git -C "$ROOT" grep -nIE "$HOST_PAT" -- . ':!*.sops.yaml' ':!docs/adr/*' ':!host/'"$NAME"'/*' | cut -c1-200

if command -v kubectl >/dev/null && timeout 15 kubectl get --raw /healthz >/dev/null 2>&1; then
  hdr "cluster: Node object"
  kubectl get node "$NAME" -o wide --no-headers 2>/dev/null || echo "(no node $NAME)"
  hdr "cluster: workloads pinned to $NAME (nodeSelector / required affinity / nodeName)"
  for k in deploy sts ds cronjob; do
    kubectl get "$k" -A -o json | jq -r --arg n "$NAME" --arg k "$k" '
      .items[] | . as $o | (.spec.template.spec // .spec.jobTemplate.spec.template.spec) as $s
      | select(($s.nodeSelector // {} | to_entries | any(.value == $n))
               or ($s.nodeName == $n)
               or ([$s.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[]?.matchExpressions[]?.values[]?] | index($n)))
      | "\($o.metadata.namespace) \($k)/\($o.metadata.name)"'
  done
  kubectl get clusters.postgresql.cnpg.io -A -o json 2>/dev/null | jq -r --arg n "$NAME" \
    '.items[] | select(.spec.affinity.nodeSelector // {} | to_entries | any(.value == $n)) | "\(.metadata.namespace) cnpg/\(.metadata.name)"'
  hdr "cluster: local PVs on $NAME"
  kubectl get pv -o json | jq -r --arg n "$NAME" '.items[]
    | select([.spec.nodeAffinity.required.nodeSelectorTerms[]?.matchExpressions[]?.values[]?] | index($n))
    | "\(.metadata.name) \(.status.phase) \(.spec.claimRef.namespace // "-")/\(.spec.claimRef.name // "-")"'
  hdr "cluster: pods running there now (excluding DaemonSets)"
  kubectl get pods -A --field-selector spec.nodeName="$NAME" -o json | jq -r \
    '.items[] | select((.metadata.ownerReferences[0].kind // "") != "DaemonSet") | select(.status.phase=="Running" or .status.phase=="Pending") | "\(.metadata.namespace)/\(.metadata.name)"'
else
  hdr "cluster: UNREACHABLE (kubectl) — re-run with a working kubeconfig"
fi

hdr "omv: /etc/exports grants"
OMV_CMD="grep -nE '$IP_PAT' /etc/exports || echo '(no matches)'"
timeout 20 ssh "${SSH_OPTS[@]}" root@192.168.1.180 "$OMV_CMD" 2>/dev/null \
  || timeout 60 ssh "${SSH_OPTS[@]}" paperclip "ssh -o BatchMode=yes -o ConnectTimeout=8 openmediavault \"$OMV_CMD\"" 2>/dev/null \
  || echo "(UNREACHABLE: OMV not reachable over the LAN or via the Air)"

hdr "air: Hermes / Paperclip / homelab configs"
AIR=${AIR_SSH:-paperclip.local}
AIR_CMD="grep -rnIE '$IP_PAT|$NAME\\.local' ~/.hermes/config.yaml ~/.hermes/profiles/*/config.yaml ~/.hermes/.env ~/.hermes/profiles/*/.env ~/.paperclip/.env ~/.paperclip/instances/*/.env ~/.paperclip/instances/*/config.json ~/.config/homelab ~/.kube/config ~/.ssh/config 2>/dev/null | cut -c1-200 | grep . || echo '(no matches)'"
timeout 30 ssh "${SSH_OPTS[@]}" "$AIR" "$AIR_CMD" 2>/dev/null \
  || { [ "$AIR" != paperclip ] && timeout 60 ssh "${SSH_OPTS[@]}" paperclip "$AIR_CMD" 2>/dev/null; } \
  || echo "(UNREACHABLE: the Air — set AIR_SSH)"

hdr "manual: check these by hand (no API access from here)"
cat <<EOF
  [ ] NetBird dashboard: Networks -> routing peers. Is $NAME a routing peer for any network
      (10.43.0.0/16 "k3s ClusterIP services" was one)? Peers -> $NAME -> groups/policies.
  [ ] OPNsense: DHCP reservation for $NAME's MAC; firewall rules naming $LAN
      (port 53 egress is allowed ONLY from 192.168.1.179).
  [ ] Other k3s nodes: does any agent use https://$LAN:6443 as server: (config.yaml or
      /etc/systemd/system/k3s-agent.service.env)?
  [ ] Is $NAME an etcd member? (kubectl get node $NAME -> roles). Remove with
      'kubectl delete node' while ALL members are up.
  [ ] House devices / bookmarks pointing at $LAN (Tasmota MQTT, Node-RED, phones).
EOF
