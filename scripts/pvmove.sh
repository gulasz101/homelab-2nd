#!/usr/bin/env bash
# pvmove.sh <namespace> <pvc> <dest-node>
#
# Move a local-path volume to another node, data included. kubectl-only: works from anywhere with a
# kubeconfig (no SSH to the nodes). Runbook: docs/runbooks/move-local-path-volume.md.
#
# Precondition: nothing *running* mounts the claim (scale the owner to 0 and suspend its CronJobs
# first; scripts/pvmove-group.sh does that). The source directory is left untouched on the old
# node: set the PV to Retain beforehand and it's a cold copy for free.
#
# Every guard here fired at least once during the 2026-11-12 node move:
#   - a live pod still uses the claim                  -> refuse
#   - destination directory not empty                  -> refuse (a half-copy from a failed run)
#   - kubectl exec truncates a stream when the consumer is slow (tar: Unexpected EOF)
#                                                       -> stage to a local file, compare sha1 with
#                                                          an in-pod checksum before extracting
#   - entry count differs after extraction             -> refuse to swap
#   - finished Job pods hold kubernetes.io/pvc-protection -> delete them before deleting the PVC
#   - Flux fights a hand-recreated PVC ("spec is immutable") -> co-own volumeName/volumeMode/
#     storageClassName under a separate field manager (Flux then just drops its own claim)
#
# Env: STAGE_DIR (default: a temp dir; needs room for the whole volume), MOVER_IMAGE (busybox),
#      PVMOVE_LINGER (seconds the remote shell waits after tar so the stream drains; default 20).
set -euo pipefail
NS=${1:?usage: pvmove.sh <namespace> <pvc> <dest-node>}; PVC=${2:?}; DEST=${3:?}
IMAGE=${MOVER_IMAGE:-busybox:1.37.0}
STAGE_DIR=${STAGE_DIR:-$(mktemp -d)}
TAG="pvmove-$(date +%s)"
log(){ echo "[$(date +%H:%M:%S)] $NS/$PVC: $*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
k(){ kubectl "$@"; }

PV=$(k -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.volumeName}')
[ -n "$PV" ] || die "claim not bound"
PVJ=$(k get pv "$PV" -o json)
SRC=$(jq -r '.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]' <<<"$PVJ")
DIR=$(jq -r '.spec.local.path // .spec.hostPath.path' <<<"$PVJ")
[ "$(jq -r '.spec.storageClassName' <<<"$PVJ")" = local-path ] || die "not a local-path volume"
[ "$SRC" != "$DEST" ] || { log "already on $DEST"; exit 0; }
k get node "$DEST" >/dev/null || die "no node $DEST"

live=$(k -n "$NS" get pods -o json | jq -r --arg c "$PVC" '.items[]
  | select(.status.phase!="Succeeded" and .status.phase!="Failed")
  | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName==$c)) | .metadata.name')
[ -z "$live" ] || die "still used by: $live (scale the owner to 0, suspend its CronJobs)"

mover() { # name node readonly
  k -n kube-system apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: kube-system, labels: {app: pvmove, pvmove/run: "$TAG"}}
spec:
  nodeName: $2
  restartPolicy: Never
  tolerations: [{operator: Exists}]
  containers:
  - name: m
    image: $IMAGE
    command: ["sleep", "7200"]
    securityContext: {privileged: true}
    volumeMounts: [{name: s, mountPath: /host, readOnly: $3}]
  volumes:
  - name: s
    hostPath: {path: /var/lib/rancher/k3s/storage, type: DirectoryOrCreate}
EOF
}
cleanup(){ k -n kube-system delete pod -l "pvmove/run=$TAG" --wait=false >/dev/null 2>&1 || true; rm -f "$STAGE_DIR/$TAG.tar"; }
trap cleanup EXIT
mover "$TAG-src" "$SRC" true; mover "$TAG-dst" "$DEST" false
k -n kube-system wait --for=condition=Ready pod -l "pvmove/run=$TAG" --timeout=180s >/dev/null
SUB=${DIR#/var/lib/rancher/k3s/storage/}
[ "$SUB" != "$DIR" ] || die "unexpected path $DIR (expected under /var/lib/rancher/k3s/storage)"
exs(){ k -n kube-system exec "$TAG-$1" -- sh -c "$2"; }

[ -z "$(exs dst "mkdir -p '/host/$SUB' && chmod 0777 '/host/$SUB' && ls -A '/host/$SUB'")" ] \
  || die "destination /host/$SUB on $DEST is not empty (leftover from a failed run? inspect, then clear it)"

log "copy $SRC -> $DEST ($DIR)"
# kubectl exec drops the tail of stdout when the remote process exits before the stream drains
# (seen at 75% delivered over a phone hotspot, websocket AND spdy). Keeping the remote shell alive
# after tar fixes it; the checksum loop makes a slow link cost time, never correctness.
IN=$(exs src "tar -C '/host/$SUB' -cf - . | sha1sum" | cut -d' ' -f1)
for attempt in 1 2 3 4; do
  k -n kube-system exec "$TAG-src" -- sh -c "tar -C '/host/$SUB' -cf - .; sleep ${PVMOVE_LINGER:-20}" > "$STAGE_DIR/$TAG.tar"
  OUT=$( (sha1sum "$STAGE_DIR/$TAG.tar" 2>/dev/null || shasum "$STAGE_DIR/$TAG.tar") | cut -d' ' -f1)
  [ "$IN" = "$OUT" ] && break
  log "attempt $attempt: staged tar checksum mismatch ($(wc -c < "$STAGE_DIR/$TAG.tar") bytes), retrying"
  [ "$attempt" = 4 ] && die "staged tar never matched the in-pod checksum: nothing changed"
done
k -n kube-system exec -i "$TAG-dst" -- tar -C "/host/$SUB" -xpf - < "$STAGE_DIR/$TAG.tar"
SC=$(exs src "find '/host/$SUB' | wc -l" | tr -d ' '); DC=$(exs dst "find '/host/$SUB' | wc -l" | tr -d ' ')
SK=$(exs src "du -sk '/host/$SUB' | cut -f1"); DK=$(exs dst "du -sk '/host/$SUB' | cut -f1")
log "verify entries src=$SC dst=$DC  kB src=$SK dst=$DK"
[ "$SC" = "$DC" ] || die "entry count mismatch: nothing swapped; destination left for inspection"

BASE=${PV%-"$SRC"}; NEWPV="$BASE-$DEST"        # pvc-x-loki moving to mimir -> pvc-x-mimir
jq --arg n "$NEWPV" --arg d "$DEST" --arg ns "$NS" --arg c "$PVC" --arg old "$PV" '
  {apiVersion:"v1",kind:"PersistentVolume",
   metadata:{name:$n, annotations:{"local.path.provisioner/selected-node":$d,
     "pv.kubernetes.io/provisioned-by":"rancher.io/local-path","homelab/moved-from":$old}},
   spec:(.spec | .claimRef={apiVersion:"v1",kind:"PersistentVolumeClaim",namespace:$ns,name:$c}
               | .nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values=[$d]
               | .persistentVolumeReclaimPolicy="Delete")}' <<<"$PVJ" > "$STAGE_DIR/$TAG.pv.json"
PVCJ=$(k -n "$NS" get pvc "$PVC" -o json)
SC_NAME=$(jq -r '.spec.storageClassName' <<<"$PVCJ")

log "swap PV $PV -> $NEWPV (pre-bound by claimRef, so any recreated PVC binds to it)"
k apply -f "$STAGE_DIR/$TAG.pv.json" >/dev/null
done_pods=$(k -n "$NS" get pods -o json | jq -r --arg c "$PVC" '.items[]
  | select(.status.phase=="Succeeded" or .status.phase=="Failed")
  | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName==$c)) | .metadata.name')
[ -z "$done_pods" ] || k -n "$NS" delete pod $done_pods --wait=true --timeout=60s >/dev/null
# Retain first: with Delete, removing the claim makes local-path wipe the source directory.
k patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null
k -n "$NS" delete pvc "$PVC" --wait=true --timeout=90s >/dev/null
k delete pv "$PV" --wait=true --timeout=60s >/dev/null || true
if ! k -n "$NS" get pvc "$PVC" >/dev/null 2>&1; then
  jq --arg v "$NEWPV" --arg d "$DEST" '{apiVersion:"v1",kind:"PersistentVolumeClaim",
    metadata:(.metadata | {name,namespace,labels,ownerReferences} | with_entries(select(.value!=null))
              | .annotations={"volume.kubernetes.io/selected-node":$d}),
    spec:(.spec | {accessModes,resources,storageClassName,volumeMode} | .volumeName=$v)}' <<<"$PVCJ" \
    | k apply --server-side --field-manager=pvmove -f - >/dev/null
fi
# co-own the fields Flux's manifest may omit, under a manager Flux does not adopt
printf 'apiVersion: v1\nkind: PersistentVolumeClaim\nmetadata:\n  name: %s\n  namespace: %s\nspec:\n  volumeName: %s\n  volumeMode: Filesystem\n  storageClassName: %s\n' \
  "$PVC" "$NS" "$NEWPV" "$SC_NAME" | k apply --server-side --force-conflicts --field-manager=node-move-pv-binding -f - >/dev/null 2>&1 || true
for _ in $(seq 1 12); do
  [ "$(k -n "$NS" get pvc "$PVC" -o jsonpath='{.status.phase}/{.spec.volumeName}')" = "Bound/$NEWPV" ] \
    && { log "bound to $NEWPV on $DEST — scale the owner back up"; exit 0; }
  sleep 5
done
log "PVC not Bound yet (it binds when the pod starts if the class is WaitForFirstConsumer): check"
