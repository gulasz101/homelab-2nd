#!/usr/bin/env bash
# GUL-1267 red check: one gate per round.
#
# Runs the four new cases one at a time (a case at a time, so one failure does
# not hide the next) and reads CONTRACT.md point 9 for the fix-round chain.
# Prints one AC line per acceptance criterion; exit 1 if any line says FAIL.
# bash 3.2-safe (runs on the Air and in CI).
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TESTS="$ROOT/agents/factory/tests/test_factory_paperclip.py"
CONTRACT="$ROOT/agents/factory/CONTRACT.md"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/fix-round-gate-check-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FAIL_N=0

# run_case AC CASE — one case on its own, one AC line out.
run_case() {
  ac="$1"
  name="$2"
  out="$TMP/$name.out"
  python3 -I "$TESTS" --case "$name" > "$out" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] && ! grep -q '^FAIL ' "$out"; then
    printf '%s: PASS\n' "$ac"
    return 0
  fi
  FAIL_N=$((FAIL_N + 1))
  why="$(grep -m1 '^FAIL ' "$out")"
  if [ -n "$why" ]; then
    why="${why#FAIL }"
  else
    why="case $name exited $rc with no failing assertion: $(tail -n 1 "$out")"
  fi
  printf '%s: FAIL %s\n' "$ac" "$why"
}

run_case AC-1 case_gate_refuses_on_an_open_fix_round
run_case AC-2 case_fix_round_plans_a_gate
run_case AC-3 case_fix_round_supersedes_the_old_gate
run_case AC-4 case_tick_settles_on_the_latest_gate_round

# AC-5: point 9 is the last section of the contract, so it runs to EOF.
POINT9="$TMP/point9.md"
awk '/^## 9\./ { on = 1 } on { print }' "$CONTRACT" > "$POINT9"
missing=""
for needle in "gate r2" "superseded" "latest gate round"; do
  grep -Fq "$needle" "$POINT9" || missing="$missing \`$needle\`"
done
if [ -z "$missing" ]; then
  printf 'AC-5: PASS\n'
else
  FAIL_N=$((FAIL_N + 1))
  printf 'AC-5: FAIL CONTRACT.md point 9 does not name:%s\n' "$missing"
fi

if [ "$FAIL_N" -ne 0 ]; then
  exit 1
fi
exit 0
