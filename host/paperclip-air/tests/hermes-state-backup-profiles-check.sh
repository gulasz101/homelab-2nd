#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-1573: the nightly state.db backup must cover EVERY Hermes profile on disk,
# and the memory watchdog must expect exactly that set.
#
# The bug: hermes-state-backup.sh and watchdog check 5 shared a hard-coded list
# (default andrzej florian szarik zdzislaw). billcipher (Bill Cipher's home since
# the default -> billcipher move) and matejko (885 MB) were added later, were
# never backed up, and nothing alerted, because the watchdog checked the same stale list.
#
# What this proves, against a fake HERMES_HOME with stub mc and sqlite3 (no
# network, no MinIO, runs on Linux CI and on the Air's bash 3.2):
#   1. hermes_profiles lists the root as "default" plus every profiles/<p>/ with
#      a config.yaml, sorted; an empty profiles/<p>/ dir (careerpa) is ignored;
#   2. the backup uploads one object per profile, including a profile that is
#      NOT in the old list, and its SUCCESS line names them all;
#   3. a real profile (config.yaml) with no state.db is a failure: SKIP + exit 1;
#   4. hermes_backup_missing: empty when the last SUCCESS line covers every
#      profile; names the missing profile when it does not (the exact GUL-1573
#      state: an old five-profile SUCCESS line on a seven-profile host); exact
#      word match, so "andrzej2" does not satisfy "andrzej";
#   5. neither script carries the hard-coded list on its main path any more.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN="$HERE/bin"
RC=0
fail() { printf 'FAIL: %s\n' "$*"; RC=1; }
ok()   { printf 'ok:   %s\n' "$*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/gul1573.XXXXXX") || { printf 'FAIL: mktemp failed\n'; exit 1; }
# macOS sets TMPDIR WITH a trailing slash ("/var/folders/…/T/"), so the template
# above yields "…/T//gul1573.XXXX". hermes-state-backup.sh canonicalises HERMES_HOME
# with `cd … && pwd`, which collapses the "//", so its SKIP line names the
# single-slash path while an assertion built from an uncanonicalised "$H" keeps the
# double slash: the check went red on the Air and green on Linux CI, where TMPDIR is
# /tmp (GUL-1640). Canonicalise once here, so every path in this test has the shape
# the scripts themselves print.
WORK=$(cd "$WORK" && pwd)
trap 'rm -rf "${WORK:?}"' EXIT

# ---- fixture: a Hermes home --------------------------------------------------
H="$WORK/hermes"
mkdir -p "$H/profiles"/{andrzej,billcipher,matejko,careerpa} "$H/logs"
for d in "$H" "$H/profiles/andrzej" "$H/profiles/billcipher" "$H/profiles/matejko"; do
  : >"$d/config.yaml"
  printf 'db-%s\n' "$(basename "$d")" >"$d/state.db"
done
# careerpa: empty dir, exactly like the Air (not a profile)

# ---- stubs: mc records uploads, sqlite3 copies the file ------------------------
STUB="$WORK/stub"; mkdir -p "$STUB"
UPLOADS="$WORK/uploads.txt"; : >"$UPLOADS"
cat >"$STUB/mc" <<EOF
#!/usr/bin/env bash
case "\$1" in
  alias) exit 0 ;;
  cp)    printf '%s\n' "\$3" >>"$UPLOADS"; exit 0 ;;
esac
exit 0
EOF
cat >"$STUB/sqlite3" <<'EOF'
#!/usr/bin/env bash
# sqlite3 <db> ".backup '<dest>'"
dest=${2#.backup \'}; dest=${dest%\'}
cp "$1" "$dest"
EOF
# mktemp: the script uses the BSD form `mktemp -t <prefix>` (macOS). GNU mktemp
# (Linux CI) rejects a template without XXX, so translate; on macOS this is a pass-through.
REAL_MKTEMP=$(command -v mktemp)
cat >"$STUB/mktemp" <<EOF
#!/usr/bin/env bash
args=(); prev=""
for a in "\$@"; do
  if [ "\$prev" = "-t" ] && [[ "\$a" != *XXX* ]]; then a="\$a.XXXXXX"; fi
  args+=("\$a"); prev="\$a"
done
exec "$REAL_MKTEMP" "\${args[@]}"
EOF
chmod +x "$STUB/mc" "$STUB/sqlite3" "$STUB/mktemp"
ENVF="$WORK/minio.env"
printf 'MINIO_BUCKET=test-bucket\nMINIO_ACCESS_KEY=AKIATESTONLY\nMINIO_SECRET_KEY=not-a-secret\n' >"$ENVF"

run_backup() {
  PATH="$STUB:$PATH" HERMES_HOME="$H" ENV_FILE="$ENVF" MC_BIN="$STUB/mc" \
    MINIO_ENDPOINT="http://127.0.0.1:1" bash "$BIN/hermes-state-backup.sh" >"$WORK/out.txt" 2>&1
}

# shellcheck source=../bin/homelab-lib.sh
. "$BIN/homelab-lib.sh"

# ---- 1. discovery --------------------------------------------------------------
got=$(hermes_profiles "$H" | tr '\n' ' ')
if [ "$got" = "default andrzej billcipher matejko " ]; then
  ok "hermes_profiles = default + profiles with config.yaml, careerpa ignored"
else
  fail "hermes_profiles gave '$got', want 'default andrzej billcipher matejko '"
fi
[ "$(hermes_state_db "$H" default)" = "$H/state.db" ] && ok "default -> root state.db" || fail "default state.db path"
[ "$(hermes_state_db "$H" matejko)" = "$H/profiles/matejko/state.db" ] && ok "named -> profiles/<p>/state.db" || fail "named state.db path"

# ---- 2. the backup covers every profile ----------------------------------------
if run_backup; then ok "backup exits 0 when every profile has a state.db"; else fail "backup exited non-zero: $(tail -3 "$WORK/out.txt")"; fi
for p in default andrzej billcipher matejko; do
  grep -q "/${p}.db.gz\$" "$UPLOADS" && ok "uploaded $p" || fail "no upload for $p (uploads: $(tr '\n' ' ' <"$UPLOADS"))"
done
grep -q 'careerpa' "$UPLOADS" && fail "careerpa (empty dir) was uploaded" || ok "careerpa not uploaded"
grep -q 'SUCCESS profiles=\[default andrzej billcipher matejko\] total=4' "$H/logs/hermes-state-backup.log" \
  && ok "SUCCESS line names all 4" || fail "SUCCESS line wrong: $(grep SUCCESS "$H/logs/hermes-state-backup.log" | tail -1)"

# ---- 4a. watchdog view of that log: nothing missing ------------------------------
miss=$(hermes_backup_missing "$H/logs/hermes-state-backup.log" "$H")
[ -z "$miss" ] && ok "hermes_backup_missing empty after a full run" || fail "hermes_backup_missing gave '$miss' after a full run"

# ---- 3. a real profile without state.db fails loudly ------------------------------
rm "$H/profiles/billcipher/state.db"
if run_backup; then fail "backup exited 0 with billcipher/state.db missing"; else ok "backup exits non-zero when a profile's state.db is missing"; fi
grep -q "SKIP: $H/profiles/billcipher/state.db not found" "$H/logs/hermes-state-backup.log" \
  && ok "missing state.db logged as SKIP" || fail "no SKIP line for billcipher"
printf 'db-billcipher\n' >"$H/profiles/billcipher/state.db"

# ---- 4b. the exact GUL-1573 state: old five-profile SUCCESS line -------------------
OLDLOG="$WORK/old.log"
printf '2026-11-15T03:42:26+01:00 SUCCESS profiles=[default andrzej florian szarik zdzislaw] total=5\n' >"$OLDLOG"
miss=$(hermes_backup_missing "$OLDLOG" "$H" | tr '\n' ' ')
[ "$miss" = "billcipher matejko " ] && ok "old SUCCESS line -> missing billcipher matejko" || fail "old line gave missing='$miss'"

printf '2026-11-15T03:42:26+01:00 SUCCESS profiles=[default andrzej2 billcipher matejko] total=4\n' >"$OLDLOG"
miss=$(hermes_backup_missing "$OLDLOG" "$H" | tr '\n' ' ')
[ "$miss" = "andrzej " ] && ok "exact word match (andrzej2 is not andrzej)" || fail "substring match leaked: missing='$miss'"

: >"$OLDLOG"
miss=$(hermes_backup_missing "$OLDLOG" "$H")
[ "$miss" = "<no SUCCESS line>" ] && ok "no SUCCESS line reported as such" || fail "empty log gave '$miss'"

# ---- 5. the hard-coded list is gone from the main paths --------------------------
grep -q '^for profile in default andrzej florian szarik zdzislaw' "$BIN/hermes-state-backup.sh" \
  && fail "hermes-state-backup.sh still loops over the fixed list" || ok "backup has no fixed profile list"
grep -q 'hermes_backup_missing' "$BIN/hermes-memory-watchdog.sh" \
  && ok "watchdog check 5 uses hermes_backup_missing" || fail "watchdog check 5 does not use the shared definition"

exit $RC
