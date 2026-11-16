#!/usr/bin/env bash
# AC-1 — a quiet board: exit 0, actionable false, items [], stdout < 2000 bytes.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# MAJSTER_SWEEP lets the checks be rehearsed against a stub; unset it and
# they judge the real script.
SWEEP="${MAJSTER_SWEEP:-$HERE/../sweep.py}"

fail() { printf 'AC-1: FAIL %s\n' "$1"; exit 1; }

[ -f "$SWEEP" ] || fail "agents/majster-sweep/sweep.py does not exist yet, so there is nothing to judge"

TMP="$(mktemp -d)" || fail "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

python3 "$HERE/fixtures.py" quiet "$TMP/fx" || fail "fixture generator failed for case 'quiet'"

python3 -I "$SWEEP" --fixtures "$TMP/fx" --now "2026-11-09T18:00:00Z" \
  --stop-file "$TMP/no-such-stop" --tick-cmd "bash $HERE/tick-quiet.sh" \
  --ps-file "$TMP/fx/ps.txt" >"$TMP/out.json" 2>"$TMP/err.txt"
RC=$?

[ "$RC" -eq 0 ] || fail "exit $RC, wanted 0 on a quiet board (stderr: $(tr '\n' ' ' <"$TMP/err.txt" | cut -c1-300))"

BYTES=$(wc -c <"$TMP/out.json" | tr -d ' ')
[ "$BYTES" -lt 2000 ] || fail "stdout is $BYTES bytes, wanted under 2000"

if ! REASON=$(python3 -I - "$TMP/out.json" <<'PY'
import json, sys
try:
    report = json.loads(open(sys.argv[1]).read())
except Exception as exc:
    print("stdout is not one JSON object: %s" % exc); sys.exit(1)
if not isinstance(report, dict):
    print("stdout is not a JSON object"); sys.exit(1)
if report.get("items") != []:
    print("items is %r, wanted an empty list" % (report.get("items"),)); sys.exit(1)
if report.get("actionable") is not False:
    print("actionable is %r, wanted false" % (report.get("actionable"),)); sys.exit(1)
if report.get("stop") is not None:
    print("stop is %r, wanted null (no STOP file)" % (report.get("stop"),)); sys.exit(1)
if report.get("truncated") != 0:
    print("truncated is %r, wanted 0" % (report.get("truncated"),)); sys.exit(1)
if report.get("tick") != []:
    print("tick is %r, wanted [] for a silent --tick-cmd" % (report.get("tick"),)); sys.exit(1)
brief = report.get("brief_md")
if not isinstance(brief, str) or "## Sweep 2026-11-09 18:00Z" not in brief:
    print("brief_md has no '## Sweep 2026-11-09 18:00Z' heading"); sys.exit(1)
if "quiet board, nothing needed" not in brief:
    print("brief_md does not say 'quiet board, nothing needed'"); sys.exit(1)
sys.exit(0)
PY
); then fail "$REASON"; fi

printf 'AC-1: PASS\n'
exit 0
