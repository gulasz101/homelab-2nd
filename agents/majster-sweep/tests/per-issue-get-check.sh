#!/usr/bin/env bash
# AC-3 — the judgement comes from the per-issue GET, never from the list.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# MAJSTER_SWEEP lets the checks be rehearsed against a stub; unset it and
# they judge the real script.
SWEEP="${MAJSTER_SWEEP:-$HERE/../sweep.py}"

fail() { printf 'AC-3: FAIL %s\n' "$1"; exit 1; }

[ -f "$SWEEP" ] || fail "agents/majster-sweep/sweep.py does not exist yet, so there is nothing to judge"

TMP="$(mktemp -d)" || fail "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

# GUL-301: the list says in_review, its own GET says done  -> not reported.
# GUL-302: no per-issue file, so the GET is a 404        -> skipped.
# GUL-303: the list says todo, its own GET says in_progress and stale -> stalled.
python3 "$HERE/fixtures.py" per-issue-get "$TMP/fx" || fail "fixture generator failed for case 'per-issue-get'"

python3 -I "$SWEEP" --fixtures "$TMP/fx" --now "2026-11-09T18:00:00Z" \
  --stop-file "$TMP/no-such-stop" --tick-cmd "bash $HERE/tick-quiet.sh" \
  --ps-file "$TMP/fx/ps.txt" >"$TMP/out.json" 2>"$TMP/err.txt"
RC=$?

[ "$RC" -eq 10 ] || fail "exit $RC, wanted 10 (GUL-303 is a stalled row its list entry hides) (stderr: $(tr '\n' ' ' <"$TMP/err.txt" | cut -c1-200))"

if ! REASON=$(python3 -I - "$TMP/out.json" <<'PY'
import json, sys
try:
    report = json.loads(open(sys.argv[1]).read())
except Exception as exc:
    print("stdout is not one JSON object: %s" % exc); sys.exit(1)
items = report.get("items") or []
identifiers = [i.get("issue") for i in items if isinstance(i, dict)]
for hidden in ("GUL-301", "GUL-302"):
    if hidden in identifiers:
        print("reported %s, which the per-issue GET excludes (items: %r)" % (hidden, identifiers)); sys.exit(1)
if identifiers != ["GUL-303"]:
    print("items are %r, wanted exactly GUL-303 as stalled" % (identifiers,)); sys.exit(1)
if items[0].get("kind") != "stalled":
    print("GUL-303 kind is %r, wanted stalled" % (items[0].get("kind"),)); sys.exit(1)
if report.get("actionable") is not True:
    print("actionable is %r, wanted true" % (report.get("actionable"),)); sys.exit(1)
sys.exit(0)
PY
); then fail "$REASON"; fi

printf 'AC-3: PASS\n'
exit 0
