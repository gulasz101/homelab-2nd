#!/usr/bin/env bash
# Mail-Archiver CNPG backup evidence generator (H2-148 / ST3, acceptance criteria 4-6).
#
# READ-ONLY. It reads Kubernetes state and (optionally) MinIO listings; it never
# applies, patches, deletes or writes anything, and it holds no credentials of its own —
# it uses whatever kube context and `mc` alias the operator already has. Run it from a
# host with cluster access:
#
#   MC_ALIAS=omv ./apps/mail-archiver/drill/verify-backups.sh
#
# Every check prints OK or FAIL, the run ends with PASS/FAIL, and the exit status is 0
# only when all assertions held. The printed lines are the evidence to paste into the
# tracking note — do not paraphrase them, paste them.
#
# Overridable: NS, CLUSTER, OBJECTSTORE, MC_ALIAS, PREFIX.
set -uo pipefail

NS="${NS:-mail-archiver}"
CLUSTER="${CLUSTER:-mailarchiver-db}"
OBJECTSTORE="${OBJECTSTORE:-mailarchiver-db-backups}"
MC_ALIAS="${MC_ALIAS:-}"
PREFIX="${PREFIX:-cnpg-backups/mail-archiver}"
fail=0

ok()   { printf 'OK   %s\n' "$*"; }
bad()  { printf 'FAIL %s\n' "$*"; fail=1; }
note() { printf '..   %s\n' "$*"; }

if ! command -v kubectl >/dev/null 2>&1; then
  printf 'FAIL kubectl not found in PATH\n'
  exit 2
fi

printf '== Mail-Archiver backup evidence (%s/%s) ==\n\n' "$NS" "$CLUSTER"

# --- AC4: the cluster is Healthy -------------------------------------------------
printf '== 1. Cluster health (expected: "Cluster in healthy state", Ready=True, all instances ready) ==\n'
phase=$(kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{.status.phase}' 2>/dev/null || true)
ready_cond=$(kubectl -n "$NS" get cluster "$CLUSTER" \
  -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)
counts=$(kubectl -n "$NS" get cluster "$CLUSTER" \
  -o jsonpath='{.status.readyInstances}/{.status.instances}' 2>/dev/null || true)
note "phase: ${phase:-<empty>}"
note "Ready condition: ${ready_cond:-<empty>}; ready/instances: ${counts:-<empty>}"
case "$phase" in
  *healthy*|*Healthy*) ok "cluster phase reports healthy" ;;
  *) bad "cluster phase is '${phase:-<empty>}' — not healthy" ;;
esac
[ "$ready_cond" = "True" ] && ok "Ready condition is True" || bad "Ready condition is '${ready_cond:-<empty>}'"
[ -n "$counts" ] && [ "$counts" != "/" ] && [ "${counts%%/*}" = "${counts##*/}" ] \
  && ok "all instances ready ($counts)" || bad "not all instances ready ($counts)"
printf '\n'

# --- AC6: at least one base backup completed -------------------------------------
printf '== 2. Base backups (expected: at least one phase=completed) ==\n'
backups=$(kubectl -n "$NS" get backups.postgresql.cnpg.io \
  -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase} {end}' 2>/dev/null || true)
note "backups: ${backups:-<none>}"
if printf '%s' "$backups" | grep -q '=completed'; then
  ok "a base backup is completed"
else
  bad "no completed base backup yet (ScheduledBackup has immediate: true, so one should appear within minutes)"
fi
recovery_window=$(kubectl -n "$NS" get objectstore "$OBJECTSTORE" \
  -o jsonpath='{.status.serverRecoveryWindow}' 2>/dev/null || true)
note "ObjectStore serverRecoveryWindow: ${recovery_window:-<empty>}"
if printf '%s' "$recovery_window" | grep -q 'lastSuccessfulBackupTime'; then
  ok "ObjectStore reports a successful backup window"
else
  bad "ObjectStore has no lastSuccessfulBackupTime — nothing is restorable from it yet"
fi
printf '\n'

# --- AC5: WAL archiving is actually shipping ------------------------------------
printf '== 3. WAL archiving (expected: archived_count > 0, failed_count = 0, marker absent) ==\n'
archiver=$(kubectl -n "$NS" exec "${CLUSTER}-1" -c postgres -- psql -U postgres -d postgres -tAc \
  "select archived_count||' archived, '||failed_count||' failed, last='||coalesce(last_archived_wal,'none')||', '||coalesce(extract(epoch from (now()-last_archived_time))::bigint::text,'?')||'s ago' from pg_stat_archiver" \
  2>/dev/null || true)
note "pg_stat_archiver: ${archiver:-<query failed>}"
archived_count=$(printf '%s' "$archiver" | awk '{print $1}')
failed_count=$(printf '%s' "$archiver" | awk '{print $3}')
if [ -n "${archived_count:-}" ] && [ "${archived_count:-0}" -gt 0 ] 2>/dev/null; then
  ok "WAL segments have been archived ($archived_count)"
else
  bad "no WAL segment archived yet (archived_count=${archived_count:-<none>})"
fi
if [ "${failed_count:-1}" = "0" ]; then
  ok "no WAL archive failures"
else
  bad "WAL archive failures recorded (failed_count=${failed_count:-<none>})"
fi
marker=$(kubectl -n "$NS" exec "${CLUSTER}-1" -c postgres -- \
  sh -c 'test -e "$PGDATA/.check-empty-wal-archive" && echo present || echo absent' 2>/dev/null || true)
note "empty-WAL-archive marker: ${marker:-<unknown>}"
[ "$marker" = "absent" ] && ok "marker file absent (first WAL archived, guards satisfied)" \
  || bad "marker file state: ${marker:-<unknown>}"
printf '\n'

# --- optional: look at the bytes in MinIO itself --------------------------------
printf '== 4. MinIO objects (optional; set MC_ALIAS to enable) ==\n'
if [ -n "$MC_ALIAS" ]; then
  if command -v mc >/dev/null 2>&1; then
    listing=$(mc ls --recursive "$MC_ALIAS/$PREFIX/" 2>/dev/null || true)
    wals=$(printf '%s\n' "$listing" | grep -c '/wals/' || true)
    bases=$(printf '%s\n' "$listing" | grep -c '/base/' || true)
    note "objects under $MC_ALIAS/$PREFIX/ : ${wals} WAL, ${bases} base-backup entries"
    [ "${wals:-0}" -gt 0 ] && ok "WAL segments are present in MinIO" || bad "no WAL segments under the prefix"
    [ "${bases:-0}" -gt 0 ] && ok "base-backup objects are present in MinIO" || bad "no base-backup objects under the prefix"
  else
    note "mc not in PATH — skipping the MinIO listing"
  fi
else
  note "MC_ALIAS unset — skipping the MinIO listing (kubectl-side evidence above still stands)"
fi
printf '\n'

if [ "$fail" -eq 0 ]; then
  printf 'PASS — cluster healthy, backups present, WAL archiving live.\n'
  exit 0
fi
printf 'FAIL — at least one assertion did not hold; do not report ST3 runtime ACs as met.\n'
exit 1
