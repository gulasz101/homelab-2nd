#!/usr/bin/env bash
# AC-2 — each needs-model kind, from its own fixture: right kind, right issue
# identifier, exit 10.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# MAJSTER_SWEEP lets the checks be rehearsed against a stub; unset it and
# they judge the real script.
SWEEP="${MAJSTER_SWEEP:-$HERE/../sweep.py}"

fail() { printf 'AC-2: FAIL %s\n' "$1"; exit 1; }

[ -f "$SWEEP" ] || fail "agents/majster-sweep/sweep.py does not exist yet, so there is nothing to judge"

TMP="$(mktemp -d)" || fail "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

# case:expected kind:expected issue identifier ("-" = the kind carries no issue,
# a ps row is not attached to one)
CASES="hold:hold:GUL-201
stalled:stalled:GUL-202
blocker_cleared:blocker_cleared:GUL-203
orphan_blocked:orphan_blocked:GUL-204
never_started:never_started:GUL-205
agent_error:agent_error:GUL-206
long_child:long_child:-"

while IFS=: read -r CASE KIND IDENT; do
  [ -n "$CASE" ] || continue
  python3 "$HERE/fixtures.py" "$CASE" "$TMP/fx-$CASE" || fail "fixture generator failed for case '$CASE'"
  python3 -I "$SWEEP" --fixtures "$TMP/fx-$CASE" --now "2026-11-09T18:00:00Z" \
    --stop-file "$TMP/no-such-stop" --tick-cmd "bash $HERE/tick-quiet.sh" \
    --ps-file "$TMP/fx-$CASE/ps.txt" >"$TMP/out-$CASE.json" 2>"$TMP/err-$CASE.txt"
  RC=$?
  [ "$RC" -eq 10 ] || fail "$CASE: exit $RC, wanted 10 for an actionable board (stderr: $(tr '\n' ' ' <"$TMP/err-$CASE.txt" | cut -c1-200))"

  if ! REASON=$(python3 -I - "$TMP/out-$CASE.json" "$KIND" "$IDENT" <<'PY'
import json, sys
path, kind, ident = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    report = json.loads(open(path).read())
except Exception as exc:
    print("stdout is not one JSON object: %s" % exc); sys.exit(1)
items = report.get("items")
if not isinstance(items, list) or not items:
    print("items is %r, wanted at least one item" % (items,)); sys.exit(1)
if report.get("actionable") is not True:
    print("actionable is %r, wanted true for a needs-model kind" % (report.get("actionable"),)); sys.exit(1)
matching = [i for i in items if isinstance(i, dict) and i.get("kind") == kind]
if len(matching) != 1:
    print("wanted exactly one %r item, got kinds %r" % (kind, [i.get("kind") for i in items])); sys.exit(1)
item = matching[0]
if ident != "-" and item.get("issue") != ident:
    print("item issue is %r, wanted %r" % (item.get("issue"), ident)); sys.exit(1)
if len(items) != 1:
    print("wanted exactly one item for this fixture, got %d (%r)" % (len(items), [i.get("kind") for i in items])); sys.exit(1)
if not item.get("detail"):
    print("item has no detail line"); sys.exit(1)
sys.exit(0)
PY
  ); then fail "$CASE: $REASON"; fi
done <<CASES_EOF
$CASES
CASES_EOF

# Majster's own `error` latch is never reported: the watchdog may not wake itself.
if ! REASON=$(python3 -I - "$TMP/out-agent_error.json" <<'PY'
import json, sys
report = json.loads(open(sys.argv[1]).read())
for item in report.get("items") or []:
    if item.get("agent") == "2df240b5-a5ea-4ebf-81ff-bf96758e8f80":
        print("reported Majster's own error latch as %r" % (item.get("kind"),)); sys.exit(1)
sys.exit(0)
PY
); then fail "agent_error: $REASON"; fi

printf 'AC-2: PASS\n'
exit 0
