#!/usr/bin/env bash
# AC-5 — waiting_human, agent_zombie and impersonation are reported in items
# and in brief_md, but on their own they never make the board actionable.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# MAJSTER_SWEEP lets the checks be rehearsed against a stub; unset it and
# they judge the real script.
SWEEP="${MAJSTER_SWEEP:-$HERE/../sweep.py}"

fail() { printf 'AC-5: FAIL %s\n' "$1"; exit 1; }

[ -f "$SWEEP" ] || fail "agents/majster-sweep/sweep.py does not exist yet, so there is nothing to judge"

TMP="$(mktemp -d)" || fail "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

python3 "$HERE/fixtures.py" no-model-kinds "$TMP/fx" || fail "fixture generator failed for case 'no-model-kinds'"

python3 -I "$SWEEP" --fixtures "$TMP/fx" --now "2026-11-09T18:00:00Z" \
  --stop-file "$TMP/no-such-stop" --tick-cmd "bash $HERE/tick-quiet.sh" \
  --ps-file "$TMP/fx/ps.txt" >"$TMP/out.json" 2>"$TMP/err.txt"
RC=$?

[ "$RC" -eq 0 ] || fail "exit $RC, wanted 0: none of these three kinds needs a model (stderr: $(tr '\n' ' ' <"$TMP/err.txt" | cut -c1-200))"

if ! REASON=$(python3 -I - "$TMP/out.json" <<'PY'
import json, sys
try:
    report = json.loads(open(sys.argv[1]).read())
except Exception as exc:
    print("stdout is not one JSON object: %s" % exc); sys.exit(1)
items = [i for i in (report.get("items") or []) if isinstance(i, dict)]
kinds = sorted(i.get("kind") for i in items)
wanted = ["agent_zombie", "impersonation", "waiting_human"]
if kinds != wanted:
    print("kinds are %r, wanted %r" % (kinds, wanted)); sys.exit(1)
issues = sorted(i.get("issue") for i in items)
if issues != ["GUL-501", "GUL-502", "GUL-503"]:
    print("item issues are %r, wanted GUL-501, GUL-502, GUL-503" % (issues,)); sys.exit(1)
if report.get("actionable") is not False:
    print("actionable is %r, wanted false: these kinds do not need a model" % (report.get("actionable"),)); sys.exit(1)
brief = report.get("brief_md")
if not isinstance(brief, str):
    print("brief_md is not a string"); sys.exit(1)
for identifier in ("GUL-501", "GUL-502", "GUL-503"):
    if identifier not in brief:
        print("brief_md does not carry %s" % identifier); sys.exit(1)
sys.exit(0)
PY
); then fail "$REASON"; fi

printf 'AC-5: PASS\n'
exit 0
