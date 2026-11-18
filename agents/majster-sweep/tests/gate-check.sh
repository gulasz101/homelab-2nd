#!/usr/bin/env bash
# AC-6 (GUL-1761) — the wake gate: a parked flag stops starting the routine.
# One stalled issue, four clocks on the same fixture:
#   age 120 min  -> fresh, exit 10
#   age 300 min  -> unchanged, exit 0, and the brief still lists the item
#   age 360 min  -> the 6 h reminder, exit 10
#   age 810 min  -> unchanged, but 05:xx UTC is the morning brief: exit 10
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SWEEP="${MAJSTER_SWEEP:-$HERE/../sweep.py}"

fail() { printf 'AC-6: FAIL %s\n' "$1"; exit 1; }

[ -f "$SWEEP" ] || fail "agents/majster-sweep/sweep.py does not exist yet"

TMP="$(mktemp -d)" || fail "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

python3 "$HERE/fixtures.py" stalled "$TMP/fx" || fail "fixture generator failed"

run() {   # run <now> <exit we want> <label>
  local now="$1" want="$2" label="$3" rc
  python3 -I "$SWEEP" --fixtures "$TMP/fx" --now "$now" \
      --stop-file "" --tick-cmd "" --ps-file /dev/null \
      >"$TMP/out" 2>"$TMP/err"
  rc=$?
  [ "$rc" -eq "$want" ] || fail "$label: exit $rc, wanted $want ($(tr '\n' ' ' <"$TMP/err" | cut -c1-180))"
  echo "$now $want" >"$TMP/expect"
}

readback() {   # readback <label> <python expr over d>
  python3 - "$TMP/out" "$1" "$2" <<'PY' || exit 1
import json, sys
path, label, expr = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    d = json.load(fh)
if not eval(expr):
    sys.exit("%s: %r failed for %s" % (label, expr, json.dumps(d)[:400]))
PY
}

# 1. fresh: a stalled flag 120 min old is news.
run "2026-11-09T18:00:00Z" 10 "fresh"
readback fresh 'd["actionable"] is True'

# 2. unchanged: 300 min old, outside the window and outside a reminder slot.
run "2026-11-09T21:00:00Z" 0 "unchanged"
readback unchanged 'd["actionable"] is False' \
    || fail "unchanged: the routine would still start"
readback unchanged 'any(i["kind"] == "stalled" for i in d["items"])' \
    || fail "unchanged: the item vanished from the brief"
readback unchanged '"no decision this hour" in d["brief_md"]' \
    || fail "unchanged: the brief does not say why nobody was called"
readback unchanged '"[stalled] GUL-202" in d["brief_md"]' \
    || fail "unchanged: the brief lost the item line"

# 3. the 6 h reminder: same flag, now 360 min old.
run "2026-11-09T22:00:00Z" 10 "reminder"
readback reminder 'd["actionable"] is True' \
    || fail "reminder: a 6 h old flag never comes round"

# 4. the morning brief wakes him even when nothing changed.
run "2026-11-10T05:30:00Z" 10 "morning"
readback morning 'd["morning_brief"] is True' \
    || fail "morning: the 05:00Z slot did not force a written brief"

printf 'AC-6: PASS the gate sleeps on unchanged flags and still reminds\n'
