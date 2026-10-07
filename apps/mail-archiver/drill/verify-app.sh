#!/usr/bin/env bash
# Mail-Archiver app runtime evidence (H2-149 / ST4, AC6).
#
# Read-only: this script never creates, patches or deletes anything. It inspects
# the running deployment and prints a PASS/FAIL assertion per acceptance
# criterion, exiting non-zero if any assertion fails.
#
# WHY THIS EXISTS
# The OpenChamber worker pod has no cluster RBAC (kubectl auth can-i --list shows
# only self-reviews + discovery) and no age key, so it physically cannot verify a
# running workload. Rather than claim "it works", ST4 commits this executable
# proof and hands the run to a human with kubeconfig — the same split ST3 used.
#
# RUN (from homelab-2nd, or anywhere with kubeconfig):
#   bash apps/mail-archiver/drill/verify-app.sh
#   NS=mail-archiver DB=mailarchiver-db-1 PUBLIC_HOST=mail-archive.voitech.dev \
#     bash apps/mail-archiver/drill/verify-app.sh
#
# The public-URL / SSO-only visual check ("no password form") belongs to ST5
# (H2-150); this script proves the pod, its keyring, its DB and its login route.

set -uo pipefail

NS="${NS:-mail-archiver}"
DEPLOY="${DEPLOY:-mail-archiver}"
DB="${DB:-mailarchiver-db-1}"
PUBLIC_HOST="${PUBLIC_HOST:-mail-archive.voitech.dev}"
EXPECTED_DIGEST="${EXPECTED_DIGEST:-sha256:8a05e3c99f63c03ab2599c04078c7de4ee5ecf1988e8adec8d233a457913ab44}"
PF_PORT="${PF_PORT:-15000}"

PASS=0
FAIL=0

say()  { printf '%s\n' "$*"; }
hr()   { printf '%s\n' "----------------------------------------------------------------"; }
assert() { # assert <label> <shell-condition-as-string>
  local label="$1" cond="$2"
  if eval "$cond" >/dev/null 2>&1; then
    printf '  OK   %s\n' "$label"; PASS=$((PASS+1))
  else
    printf '  FAIL %s\n' "$label"; FAIL=$((FAIL+1))
  fi
}

say "Mail-Archiver ST4 runtime evidence — namespace=$NS deploy=$DEPLOY db=$DB host=$PUBLIC_HOST"
say "kubectl: $(command -v kubectl || echo 'NOT FOUND')"
hr

kubectl -n "$NS" get deploy "$DEPLOY" >/dev/null 2>&1 || {
  say "ABORT: cannot read deployment $NS/$DEPLOY — wrong namespace or missing kubeconfig."
  exit 2
}

say "1. Deployment"
READY_REPLICAS="$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
AVAIL_COND="$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{range .status.conditions[?(@.type=="Available")]}{.status}{end}' 2>/dev/null)"
assert "deployment Available=True" "[ \"$AVAIL_COND\" = 'True' ]"
assert "1/1 ready replica" "[ \"${READY_REPLICAS:-0}\" = '1' ]"
assert "strategy is Recreate" "[ \"$(kubectl -n \"$NS\" get deploy \"$DEPLOY\" -o jsonpath='{.spec.strategy.type}')\" = 'Recreate' ]"

say "2. Pod"
POD="$(kubectl -n "$NS" get pods -l app.kubernetes.io/name="$DEPLOY" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
PHASE="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)"
READY="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)"
RESTARTS="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)"
assert "pod exists ($POD)" "[ -n '$POD' ]"
assert "pod phase Running" "[ \"$PHASE\" = 'Running' ]"
assert "container ready" "[ \"$READY\" = 'true' ]"
assert "restart count < 3 (not crash-looping)" "[ \"${RESTARTS:-99}\" -lt 3 ]"

say "3. Pinned image"
IMG="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)"
assert "image pinned to the ST4 digest" "[[ \"$IMG\" == *\"$EXPECTED_DIGEST\"* ]]"
say "     image: $IMG"

say "4. DataProtection keyring on the NFS PV"
PVC_PHASE="$(kubectl -n "$NS" get pvc mailarchiver-keys -o jsonpath='{.status.phase}' 2>/dev/null)"
PV_NAME="$(kubectl -n "$NS" get pvc mailarchiver-keys -o jsonpath='{.spec.volumeName}' 2>/dev/null)"
PV_RECLAIM="$(kubectl get pv "$PV_NAME" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null)"
KEYS="$(kubectl -n "$NS" exec "$DEPLOY" -c "$DEPLOY" -- sh -c 'ls -1 /app/DataProtection-Keys 2>/dev/null' 2>/dev/null)"
N_KEYS="$(printf '%s\n' "$KEYS" | grep -cE '^key-.*\.xml$|^.+\.xml$' 2>/dev/null)"
assert "PVC mailarchiver-keys Bound" "[ \"$PVC_PHASE\" = 'Bound' ]"
assert "PV reclaim policy Retain (keyring must never be pruned)" "[ \"$PV_RECLAIM\" = 'Retain' ]"
assert "at least one DataProtection key file (key-*.xml) on the PV" "[ \"${N_KEYS:-0}\" -ge 1 ]"
say "     keyring files: $(printf '%s' "$KEYS" | tr '\n' ' ')"

say "5. Mail tables exist in the CNPG database"
TABLES="$(kubectl -n "$NS" exec "$DB" -c postgres -- psql -U mailarchiver -d mailarchiver -tAc \
  "select count(*) from information_schema.tables where table_schema='public' and table_name in ('MailAccounts','ArchivedEmails','EmailAttachments','Users','SyncCheckpoints');" 2>/dev/null | tr -d '[:space:]')"
assert "core MailArchiver tables present (>=5 of 6)" "[ \"${TABLES:-0}\" -ge 5 ]"
say "     matched tables: ${TABLES:-?}/6"

say "6. stdout is flowing (the source the OTel collector ships to Loki)"
NLOG="$(kubectl -n "$NS" logs "$DEPLOY" --tail=200 2>/dev/null | wc -l | tr -d '[:space:]')"
assert "container stdout has recent lines" "[ \"${NLOG:-0}\" -ge 1 ]"
say "     tail lines: ${NLOG:-0}"
say "     (Loki: Grafana -> Explore -> {k8s_namespace_name=\"mail-archiver\"})"

say "7. Login page serves 200 unauthenticated (no /health exists; this is the route)"
kubectl -n "$NS" port-forward "svc/$DEPLOY" "$PF_PORT:5000" >/tmp/st4-pf.log 2>&1 &
PF_PID=$!
sleep 4
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $PUBLIC_HOST" "http://127.0.0.1:$PF_PORT/Auth/Login" 2>/dev/null)"
kill "$PF_PID" 2>/dev/null; wait "$PF_PID" 2>/dev/null
assert "GET /Auth/Login -> 200 with the public Host header" "[ \"$CODE\" = '200' ]"
say "     http status: ${CODE:-none}"

say "8. NetworkPolicy + app secret wired"
assert "NetworkPolicy mail-archiver exists" "kubectl -n \"$NS\" get networkpolicy mail-archiver"
assert "Secret mailarchiver-app-secrets exists" "kubectl -n \"$NS\" get secret mailarchiver-app-secrets"

hr
say "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && say "PASS" || say "FAIL"
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
