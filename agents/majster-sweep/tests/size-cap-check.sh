#!/usr/bin/env bash
# AC-7 — 300 open issues, 40 flagged: items holds 15, truncated counts 25, the
# needs-model kinds come first and stdout stays under 8000 bytes.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# MAJSTER_SWEEP lets the checks be rehearsed against a stub; unset it and
# they judge the real script.
SWEEP="${MAJSTER_SWEEP:-$HERE/../sweep.py}"

fail() { printf 'AC-7: FAIL %s\n' "$1"; exit 1; }

[ -f "$SWEEP" ] || fail "agents/majster-sweep/sweep.py does not exist yet, so there is nothing to judge"

TMP="$(mktemp -d)" || fail "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

# 300 rows: 10 waiting_human listed FIRST, then 30 hold, then 260 quiet rows.
# The 15 kept items must be the needs-model ones, not the ten listed first.
python3 "$HERE/fixtures.py" size-cap "$TMP/fx" || fail "fixture generator failed for case 'size-cap'"

python3 -I "$SWEEP" --fixtures "$TMP/fx" --now "2026-11-09T18:00:00Z" \
  --stop-file "$TMP/no-such-stop" --tick-cmd "bash $HERE/tick-quiet.sh" \
  --ps-file "$TMP/fx/ps.txt" >"$TMP/out.json" 2>"$TMP/err.txt"
RC=$?

[ "$RC" -eq 10 ] || fail "exit $RC, wanted 10: 40 rows are flagged (stderr: $(tr '\n' ' ' <"$TMP/err.txt" | cut -c1-200))"

BYTES=$(wc -c <"$TMP/out.json" | tr -d ' ')
[ "$BYTES" -lt 8000 ] || fail "stdout is $BYTES bytes, wanted under 8000 on a 40-item board"

if ! REASON=$(python3 -I - "$TMP/out.json" <<'PY'
import json, sys
try:
    report = json.loads(open(sys.argv[1]).read())
except Exception as exc:
    print("stdout is not one JSON object: %s" % exc); sys.exit(1)
items = [i for i in (report.get("items") or []) if isinstance(i, dict)]
if len(items) != 15:
    print("items holds %d, wanted 15 (the cap)" % len(items)); sys.exit(1)
if report.get("truncated") != 25:
    print("truncated is %r, wanted 25 (40 flagged minus the 15 kept)" % (report.get("truncated"),)); sys.exit(1)
needs_model = {"hold", "stalled", "blocker_cleared", "orphan_blocked",
               "never_started", "agent_error", "long_child"}
wrong = [i.get("kind") for i in items if i.get("kind") not in needs_model]
if wrong:
    print("items keep a no-model kind before a needs-model one: %r" % (wrong,)); sys.exit(1)
if report.get("actionable") is not True:
    print("actionable is %r, wanted true" % (report.get("actionable"),)); sys.exit(1)
sys.exit(0)
PY
); then fail "$REASON"; fi

printf 'AC-7: PASS\n'
exit 0
