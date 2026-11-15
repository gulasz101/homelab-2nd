#!/bin/bash
# ---------------------------------------------------------------------------
# gpu-slot-check.sh — behaviour test for host/m1max/bin/gpu-slot.sh (GUL-1431).
#
# Runs the real script against a fake `lms` that keeps the loaded models in a
# file, so it works in CI with no LM Studio. What it proves:
#   1. begin unloads the model, end loads it back, exactly one instance
#   2. begin waits for a generating model to go idle (drain), and still
#      unloads when the drain times out (images win)
#   3. keep does nothing while a live image job holds the slot
#   4. keep clears a stale marker (dead PID) and reloads the model
#   5. keep reloads after a reboot (nothing loaded, no marker)
#   6. two loads at once never create a second instance
#   7. bash 3.2 parses it, no bash-4-only constructs
#
# Exit 0 = all good. Exit 1 = at least one check failed.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TARGET="$HERE/bin/gpu-slot.sh"
RC=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; RC=1; }

[ -f "$TARGET" ] || { printf 'FAIL: %s is missing\n' "$TARGET"; exit 1; }

if bash -n "$TARGET" 2>/dev/null; then pass "bash -n"; else fail "bash -n rejected the script"; fi
BASH4=$(awk '{ if ($0 !~ /^[[:space:]]*#/ && $0 ~ /declare -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)/) print FNR": "$0 }' "$TARGET")
[ -z "$BASH4" ] && pass "no bash-4-only constructs" || fail "bash-4-only syntax: $BASH4"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Fake lms. State file: one line per loaded instance, "identifier status".
# `load` appends (like the real one, a second load makes a second instance),
# and sleeps a little so a race between two loads has a window to show up.
cat >"$WORK/lms" <<'FAKE'
#!/bin/bash
S="$FAKE_LMS_STATE"
touch "$S"
case "$1" in
  ps)
    python3 - "$S" <<'PY'
import json, sys
rows = [l.split() for l in open(sys.argv[1]) if l.strip()]
print(json.dumps([{"identifier": r[0], "status": r[1]} for r in rows]))
PY
    ;;
  load)
    shift; ident=""
    while [ $# -gt 0 ]; do [ "$1" = "--identifier" ] && ident="$2"; shift; done
    sleep 1
    if grep -q "^$ident " "$S"; then echo "$ident:2 idle" >>"$S"; else echo "$ident idle" >>"$S"; fi
    echo "load" >>"$S.calls"
    ;;
  unload)
    grep -v "^$2 " "$S" >"$S.tmp"; mv "$S.tmp" "$S"
    echo "unload" >>"$S.calls"
    ;;
esac
FAKE
chmod +x "$WORK/lms"

export LMS="$WORK/lms" FAKE_LMS_STATE="$WORK/state" \
  GPU_SLOT_STATE_DIR="$WORK/slot" GPU_SLOT_LOG="$WORK/slot.log" \
  GPU_SLOT_IDENTIFIER="saluki-27b" GPU_SLOT_POLL_SECS=1 GPU_SLOT_DRAIN_SECS=3
S="$WORK/state"
slot() { bash "$TARGET" "$@"; }
instances() { grep -c . "$S" 2>/dev/null || true; }

# 1. begin/end round trip
echo "saluki-27b idle" >"$S"
GPU_SLOT_OWNER_PID=$$ slot begin ideogram4
[ "$(instances)" = "0" ] && pass "begin unloads the model" || fail "begin left $(instances) instance(s) loaded"
[ -f "$WORK/slot/image-job" ] && pass "begin writes the marker" || fail "begin wrote no marker"
slot end
[ "$(instances)" = "1" ] && pass "end loads exactly one instance" || fail "end left $(instances) instance(s)"
[ ! -f "$WORK/slot/image-job" ] && pass "end removes the marker" || fail "end left the marker"

# 2a. drain: generating -> idle within the window
echo "saluki-27b generating" >"$S"
( sleep 2; echo "saluki-27b idle" >"$S" ) &
t0=$(date +%s)
GPU_SLOT_OWNER_PID=$$ GPU_SLOT_DRAIN_SECS=20 slot begin flux2-klein
t1=$(date +%s); wait
if [ $((t1 - t0)) -ge 2 ] && [ "$(instances)" = "0" ]; then
  pass "begin waits for the running request, then unloads"
else
  fail "drain did not wait (took $((t1 - t0))s, $(instances) loaded)"
fi
slot end >/dev/null

# 2b. drain timeout: still generating, images win
echo "saluki-27b generating" >"$S"
GPU_SLOT_OWNER_PID=$$ slot begin ideogram4
[ "$(instances)" = "0" ] && pass "drain timeout still unloads (images win)" || fail "drain timeout kept the model loaded"
grep -q "drain timed out" "$WORK/slot.log" && pass "drain timeout is logged" || fail "drain timeout not logged"

# 3. keep respects a live image job
: >"$S.calls"
slot keep
[ "$(instances)" = "0" ] && [ ! -s "$S.calls" ] && pass "keep leaves the slot to a live image job" \
  || fail "keep loaded the model during a live image job"

# 4. stale marker: owner PID is dead
# A child that exits on its own: killing a forked child can run this shell's
# EXIT trap in it before exec and delete $WORK.
( trap - EXIT; exit 0 ) & dead=$!; wait "$dead" 2>/dev/null
printf '%s ideogram4 %s\n' "$dead" "$(date +%s)" >"$WORK/slot/image-job"
slot keep
[ "$(instances)" = "1" ] && [ ! -f "$WORK/slot/image-job" ] && pass "keep clears a stale marker and reloads" \
  || fail "keep did not recover from a stale marker"

# 4b. marker older than GPU_SLOT_MAX_SECS with a live PID is stale too
: >"$S"
printf '%s ideogram4 %s\n' "$$" "$(( $(date +%s) - 7200 ))" >"$WORK/slot/image-job"
GPU_SLOT_MAX_SECS=3600 slot keep
[ "$(instances)" = "1" ] && pass "keep treats a 2-hour-old marker as stale" || fail "keep trusted a 2-hour-old marker"

# 5. after a reboot: nothing loaded, no marker
: >"$S"; rm -f "$WORK/slot/image-job"
slot keep
[ "$(instances)" = "1" ] && pass "keep loads the model after a reboot" || fail "keep did not load after a reboot"

# 6. two loads at once -> still one instance
: >"$S"
slot keep & slot end & wait
[ "$(instances)" = "1" ] && pass "two concurrent loads give one instance" \
  || fail "concurrent loads gave $(instances) instances: $(cat "$S" | tr '\n' ';')"

exit "$RC"
