#!/usr/bin/env bash
# AC-6 — a STOP file reaches "stop" and the first line after the brief heading,
# and the --tick-cmd lines appear unchanged in "tick" and in "brief_md".
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# MAJSTER_SWEEP lets the checks be rehearsed against a stub; unset it and
# they judge the real script.
SWEEP="${MAJSTER_SWEEP:-$HERE/../sweep.py}"

fail() { printf 'AC-6: FAIL %s\n' "$1"; exit 1; }

[ -f "$SWEEP" ] || fail "agents/majster-sweep/sweep.py does not exist yet, so there is nothing to judge"

TMP="$(mktemp -d)" || fail "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

python3 "$HERE/fixtures.py" quiet "$TMP/fx" || fail "fixture generator failed for case 'quiet'"
printf 'freeze the board\n' > "$TMP/STOP"

python3 -I "$SWEEP" --fixtures "$TMP/fx" --now "2026-11-09T18:00:00Z" \
  --stop-file "$TMP/STOP" --tick-cmd "bash $HERE/tick-stub.sh" \
  --ps-file "$TMP/fx/ps.txt" >"$TMP/out.json" 2>"$TMP/err.txt"
RC=$?

[ "$RC" -eq 0 ] || fail "exit $RC, wanted 0: a STOP makes the factory quieter, not actionable (stderr: $(tr '\n' ' ' <"$TMP/err.txt" | cut -c1-200))"

if ! REASON=$(python3 -I - "$TMP/out.json" <<'PY'
import json, sys
try:
    report = json.loads(open(sys.argv[1]).read())
except Exception as exc:
    print("stdout is not one JSON object: %s" % exc); sys.exit(1)
stop = report.get("stop")
if not isinstance(stop, str) or stop.strip() != "freeze the board":
    print("stop is %r, wanted the STOP file's text 'freeze the board'" % (stop,)); sys.exit(1)
tick = report.get("tick")
wanted_tick = ["GUL-1200 red idle 3h runs=0", "GUL-1250 green runs-unknown"]
if tick != wanted_tick:
    print("tick is %r, wanted the stub's lines unchanged %r" % (tick, wanted_tick)); sys.exit(1)
brief = report.get("brief_md")
if not isinstance(brief, str):
    print("brief_md is not a string"); sys.exit(1)
lines = [line.rstrip() for line in brief.splitlines()]
heading = [i for i, line in enumerate(lines) if line.startswith("## Sweep")]
if not heading:
    print("brief_md has no '## Sweep' heading"); sys.exit(1)
after = lines[heading[0] + 1] if heading[0] + 1 < len(lines) else ""
if after != "factory STOPPED: freeze the board":
    print("the line after the heading is %r, wanted 'factory STOPPED: freeze the board'" % (after,)); sys.exit(1)
for line in wanted_tick:
    if line not in lines:
        print("brief_md does not carry the tick line %r unchanged" % (line,)); sys.exit(1)
sys.exit(0)
PY
); then fail "$REASON"; fi

printf 'AC-6: PASS\n'
exit 0
