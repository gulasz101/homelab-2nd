#!/usr/bin/env bash
# pvmove-group.sh <namespace> "<kind/name> ..." "<cronjob> ..." "<pvc>:<dest-node> ..."
#
#   scripts/pvmove-group.sh fitness "deploy/opengym" "fitness-data-backup" \
#     "opengym-data:mimir opengym-media:mimir"
#
# Stops a workload's owners, moves each claim with scripts/pvmove.sh, then restores everything,
# even when a move fails (the owner comes back on the old volume). Order matters (learned
# 2026-11-12, openchamber-backup runs at :20 and slipped in between steps):
#   1. suspend the CronJobs   2. delete their unfinished Jobs   3. scale owners to 0
#   4. wait until no live pod mounts the claims   5. move   6. restore replicas, unsuspend
#
# Suspend Flux for the namespace's Kustomization first if its manifests set `replicas:` (Flux
# would scale back up mid-copy). Operator-owned StatefulSets (Prometheus) are scaled through
# their CR instead: see docs/runbooks/move-local-path-volume.md. Bash 3.2 compatible.
set -uo pipefail
NS=${1:?usage: see header}; OWNERS=${2-}; CRONS=${3-}; MOVES=${4:?usage: see header}
HERE=$(cd "$(dirname "$0")" && pwd)
log(){ echo "[group $NS] $*"; }

REPLICAS=""
for o in $OWNERS; do
  r=$(kubectl -n "$NS" get "$o" -o jsonpath='{.spec.replicas}') || { log "no $o"; exit 1; }
  REPLICAS="$REPLICAS $o=$r"
done

restore() {
  for pair in $REPLICAS; do kubectl -n "$NS" scale "${pair%=*}" --replicas="${pair##*=}" >/dev/null; done
  for c in $CRONS; do kubectl -n "$NS" patch cronjob "$c" -p '{"spec":{"suspend":false}}' >/dev/null; done
  log "restored:$REPLICAS; cronjobs resumed: ${CRONS:-none}"
}
trap restore EXIT

for c in $CRONS; do
  kubectl -n "$NS" patch cronjob "$c" -p '{"spec":{"suspend":true}}' >/dev/null
  for j in $(kubectl -n "$NS" get jobs -o json | jq -r --arg c "$c" '.items[]
      | select(any(.metadata.ownerReferences[]?; .name==$c)) | select((.status.succeeded // 0)==0 and (.status.failed // 0)==0)
      | .metadata.name'); do
    kubectl -n "$NS" delete job "$j" --wait=true --timeout=60s >/dev/null && log "deleted unfinished job $j"
  done
done
for o in $OWNERS; do kubectl -n "$NS" scale "$o" --replicas=0 >/dev/null; done

claims=""; for m in $MOVES; do claims="$claims ${m%%:*}"; done
for _ in $(seq 1 36); do
  n=$(kubectl -n "$NS" get pods -o json | jq --arg cl "$claims" '[.items[]
      | select(.status.phase!="Succeeded" and .status.phase!="Failed")
      | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName as $c | ($cl | split(" ") | index($c)) != null))] | length')
  [ "$n" = 0 ] && break; sleep 5
done
[ "$n" = 0 ] || { log "pods still mount the claims after 3 min: aborting (owners restored)"; exit 1; }

rc=0
for m in $MOVES; do
  "$HERE/pvmove.sh" "$NS" "${m%%:*}" "${m##*:}" || { rc=1; log "move of ${m%%:*} FAILED: stopping"; break; }
done
exit $rc
