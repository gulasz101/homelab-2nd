#!/usr/bin/env bash
# AC-7 — the render contract still holds.
#
# Why this wrapper exists (GUL-1902): AC-7 is a regression AC, so it must report
# exactly one line, `AC-7: PASS` or `AC-7: FAIL ...`, and nothing else that looks
# like an AC report. The two suites it runs print their own AC-1..AC-7 lines and
# the factory groups reports by check command, so pointing AC-7 straight at either
# suite makes it collide with the AC ids those suites own.
#
# PASS <=> the pre-existing dashboard standard suite is green (render contract,
#         byte-identical re-render) AND the liveness suite is green.
# At the red stage the liveness suite fails, so AC-7 fails for the right reason;
# after green both pass, so AC-7 passes.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || {
  echo "AC-7: FAIL cannot resolve repo root"
  exit 1
}
cd "$root" || {
  echo "AC-7: FAIL cannot enter repo root"
  exit 1
}

tmp=$(mktemp -t ac7.XXXXXX) || {
  echo "AC-7: FAIL cannot create temp file"
  exit 1
}
trap 'rm -f "$tmp"' EXIT

bash scripts/tests/dashboard-standard-check.sh >"$tmp" 2>&1
std=$?
bash scripts/tests/dashboard-liveness-check.sh >>"$tmp" 2>&1
liv=$?

if [ "$std" -eq 0 ] && [ "$liv" -eq 0 ]; then
  echo "AC-7: PASS"
  exit 0
fi

# One short reason, with any sub-suite AC report line stripped out so it cannot
# be read as an AC-7 report by the engine.
detail=$(grep -vE '^[[:space:]]*AC-[0-9]+:' "$tmp" |
  grep -E 'FAIL|fail' | tail -n 3 | tr '\n' ';' | cut -c1-240)
echo "AC-7: FAIL standard-suite rc=$std liveness-suite rc=$liv ${detail:+| $detail}"
exit 1
