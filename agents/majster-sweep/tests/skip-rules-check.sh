#!/usr/bin/env bash
# AC-4 — the skip rules hold: backlog, cancelled, < 15 min old, Morning Brew,
# "Hourly board sweep", GUL-217, and parked agents produce no item.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# MAJSTER_SWEEP lets the checks be rehearsed against a stub; unset it and
# they judge the real script.
SWEEP="${MAJSTER_SWEEP:-$HERE/../sweep.py}"

fail() { printf 'AC-4: FAIL %s\n' "$1"; exit 1; }

[ -f "$SWEEP" ] || fail "agents/majster-sweep/sweep.py does not exist yet, so there is nothing to judge"

TMP="$(mktemp -d)" || fail "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

python3 "$HERE/fixtures.py" skip-rules "$TMP/fx" || fail "fixture generator failed for case 'skip-rules'"

python3 -I "$SWEEP" --fixtures "$TMP/fx" --now "2026-11-09T18:00:00Z" \
  --stop-file "$TMP/no-such-stop" --tick-cmd "bash $HERE/tick-quiet.sh" \
  --ps-file "$TMP/fx/ps.txt" >"$TMP/out.json" 2>"$TMP/err.txt"
RC=$?

[ "$RC" -eq 0 ] || fail "exit $RC, wanted 0: every row in this fixture is on a skip rule (stderr: $(tr '\n' ' ' <"$TMP/err.txt" | cut -c1-200))"

if ! REASON=$(python3 -I - "$TMP/out.json" <<'PY'
import json, sys
try:
    report = json.loads(open(sys.argv[1]).read())
except Exception as exc:
    print("stdout is not one JSON object: %s" % exc); sys.exit(1)
items = report.get("items")
if items != []:
    seen = ["%s/%s" % (i.get("kind"), i.get("issue")) for i in items if isinstance(i, dict)]
    print("items are %r, wanted []: backlog, cancelled, <15min, Morning Brew, 'Hourly board sweep', "
          "GUL-217 and parked agents are all skipped" % (seen,)); sys.exit(1)
if report.get("actionable") is not False:
    print("actionable is %r, wanted false" % (report.get("actionable"),)); sys.exit(1)
if report.get("truncated") != 0:
    print("truncated is %r, wanted 0" % (report.get("truncated"),)); sys.exit(1)
sys.exit(0)
PY
); then fail "$REASON"; fi

printf 'AC-4: PASS\n'
exit 0
