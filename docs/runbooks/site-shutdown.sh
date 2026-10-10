#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Graceful full-site shutdown of the homelab rack.
# Reason: homelab-2nd + OMV + t460 + arr-box are physically moving to the
#         living room. MacBook Pro M1 Max (Hermes host) STAYS UP.
# Owner:  Andrzej (Hermes Agent) for Wojciech Gula
# Date:   2026-10-10
#
# Ordering rationale:
#   workloads -> workers -> control plane -> durable storage (OMV last)
#   OMV is last because it serves NFS + MinIO S3 to everything else.
#   The Mac is never touched.
# ---------------------------------------------------------------------------
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

TS="${TS:-$(date +%Y%m%d-%H%M%S)}"
SCRATCH="$HOME/.hermes/profiles/andrzej/cache/scratch"
LOG="$SCRATCH/site-shutdown-$TS.log"
exec > >(tee -a "$LOG") 2>&1

say() { printf '\n===== %s | %s =====\n' "$*" "$(date -Iseconds)"; }
K="kubectl"
BK="pre-move-$TS"
ALPINE="alpine:3.20"

say "PHASE 0: pre-flight state"
$K get nodes -o wide
$K get cluster.postgresql.cnpg.io -A

# --- PHASE 1: final consistent backup of every CNPG cluster to OMV MinIO ----
say "PHASE 1: final CNPG backups -> OMV MinIO ($BK)"
TOTAL=0
for entry in $($K get cluster.postgresql.cnpg.io -A \
        -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'); do
  ns="${entry%%/*}"; cl="${entry##*/}"
  cat <<YAML | $K apply -f - >/dev/null 2>&1 && echo "  requested backup: $ns/$cl" || echo "  FAILED to request: $ns/$cl"
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $BK
  namespace: $ns
spec:
  cluster:
    name: $cl
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
YAML
  TOTAL=$((TOTAL+1))
done
echo "  total clusters: $TOTAL"

DEADLINE=$(( $(date +%s) + 900 ))
while :; do
  DONE=$($K get backup -A -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c "^$BK|completed")
  echo "  completed: $DONE/$TOTAL"
  [ "${DONE:-0}" -ge "$TOTAL" ] && break
  [ "$(date +%s)" -gt "$DEADLINE" ] && { echo "  WARN: backup wait timed out (continuing anyway - WAL archive already covers PITR)"; break; }
  sleep 15
done
$K get backup -A 2>/dev/null | grep "$BK" || true

# --- PHASE 2: cordon everything so nothing gets rescheduled mid-teardown ----
say "PHASE 2: cordon all nodes"
$K cordon homelab-2nd t460 arr-box || true
$K get nodes -o wide

# --- helper: graceful drain ------------------------------------------------
drain_node() {
  say "DRAIN $1 (graceful pod termination)"
  $K drain "$1" --ignore-daemonsets --delete-emptydir-data --force \
      --grace-period=120 --timeout=300s || echo "  WARN: drain of $1 did not finish cleanly - continuing"
}

# --- helper: power off a node from inside its own host namespace -----------
# Works for t460 and arr-box (neither has passwordless sudo for gulasz101).
# Uses a privileged hostPID pod; the scheduler is bypassed (nodeName is set
# directly) so a cordoned node still accepts it.
poweroff_node_pod() {
  local node="$1" pod="poweroff-$1"
  say "POWEROFF $node (privileged nsenter pod)"
  $K delete pod "$pod" -n default --ignore-not-found >/dev/null 2>&1
  $K run "$pod" --restart=Never --image="$ALPINE" -n default \
    --overrides="{\"spec\":{\"nodeName\":\"$node\",\"hostPID\":true,\"hostNetwork\":true,\"containers\":[{\"name\":\"sd\",\"image\":\"$ALPINE\",\"command\":[\"nsenter\",\"-t\",\"1\",\"-m\",\"-u\",\"-i\",\"-n\",\"-p\",\"--\",\"sh\",\"-c\",\"systemctl stop k3s-agent 2>/dev/null; systemctl stop k3s 2>/dev/null; sleep 3; sync; systemctl poweroff\"],\"securityContext\":{\"privileged\":true}}]}}" >/dev/null 2>&1
  echo "  poweroff pod scheduled on $node (host goes down shortly)"
}

# --- PHASE 3: workers ------------------------------------------------------
drain_node t460
poweroff_node_pod t460

drain_node arr-box
poweroff_node_pod arr-box

say "waiting 45s for workers to go down"
sleep 45
for n in t460 arr-box; do
  if ping -c1 -W2000 192.168.1.111 >/dev/null 2>&1; then :; fi
done
timeout 20 ping -c3 192.168.1.111 >/dev/null 2>&1 && echo "  t460 still answering (may still be shutting down)" || echo "  t460 down"
timeout 20 ping -c3 192.168.1.162 >/dev/null 2>&1 && echo "  arr-box still answering (may still be shutting down)" || echo "  arr-box down"

# --- PHASE 4: control plane ------------------------------------------------
drain_node homelab-2nd
say "POWEROFF homelab-2nd (control plane, passwordless sudo over ssh)"
ssh -o ConnectTimeout=10 homelab-2nd 'sudo systemctl stop k3s; sudo sync; sudo systemctl poweroff' || true
echo "  poweroff issued to homelab-2nd"

say "waiting for homelab-2nd to go dark"
for i in $(seq 1 30); do
  timeout 5 ping -c1 192.168.1.179 >/dev/null 2>&1 || { echo "  homelab-2nd DOWN after ${i}0s"; break; }
  sleep 10
done

# --- PHASE 5: durable storage (OMV) LAST ----------------------------------
say "PHASE 5: stop MinIO + power off OMV (durable store)"
ssh -o ConnectTimeout=10 openmediavault 'docker stop -t 60 minio cadvisor 2>/dev/null; sleep 3; sync; shutdown -h now' || true
echo "  poweroff issued to openmediavault"

say "waiting for OMV to go dark"
for i in $(seq 1 30); do
  timeout 5 ping -c1 192.168.1.180 >/dev/null 2>&1 || { echo "  OMV DOWN after ${i}0s"; break; }
  sleep 10
done

say "SITE SHUTDOWN COMPLETE - Mac stays up"
echo "log: $LOG"
date -Iseconds
