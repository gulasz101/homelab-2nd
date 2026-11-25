#!/usr/bin/env bash
# GUL-2228: an acceptance check that already passes on the base tree proves nothing.
# `factory.py check-baseline` refuses it, and the engine stalls such a work order as
# SPEC-WRONG before it opens a single stage issue.
#
#   AC-1  check-baseline refuses only an AC that reports PASS on the tree, names it,
#         and treats a check that cannot run yet as not passing
#   AC-2  the engine stalls a queued order as SPEC-WRONG before any stage issue when
#         an AC already passes on the base, and starts a clean order as today
#
# Both cases live in agents/factory/tests/test_ac_baseline.py and run in throw-away
# repos under TMPDIR. bash 3.2-safe; reads nothing outside the repository.
# Usage: bash agents/factory/tests/ac-baseline-check.sh [--ac AC-n]
set -u
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX GIT_CONFIG GIT_CONFIG_GLOBAL
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TEST="$ROOT/agents/factory/tests/test_ac_baseline.py"
[ -f "$TEST" ] || { echo "ENV: missing $TEST" >&2; exit 2; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ac-baseline-check-XXXXXX")" \
  || { echo "ENV: mktemp -d failed (TMPDIR=${TMPDIR:-unset})" >&2; exit 2; }
[ -d "$TMP" ] || { echo "ENV: mktemp -d gave no directory (TMPDIR=${TMPDIR:-unset})" >&2; exit 2; }
TMP="$(cd "$TMP" && pwd -P)" || exit 2
trap 'rm -rf "$TMP"' EXIT

ONLY=""
case "${1:-}" in
  "") ;;
  --ac) ONLY="${2:-}"; [ -n "$ONLY" ] || { echo "usage: $0 [--ac AC-n]" >&2; exit 2; } ;;
  *) echo "usage: $0 [--ac AC-n]" >&2; exit 2 ;;
esac
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

FAILED=0
run_case() { # AC-n TestClass
  local ac="$1" cls="$2" out="$TMP/$1.out" why
  if TMPDIR="$TMP" python3 -I "$TEST" "$cls" >"$out" 2>&1; then
    echo "$ac: PASS"
  else
    why="$(grep -E '^(FAIL|ERROR):|AssertionError|Error:' "$out" | head -3 | tr '\n' ' ')"
    [ -n "$why" ] || why="$(tail -3 "$out" | tr '\n' ' ')"
    echo "$ac: FAIL $(printf '%s' "$why" | cut -c1-400)"
    FAILED=1
  fi
}

if want AC-1; then run_case AC-1 BaselineCheck; fi
if want AC-2; then run_case AC-2 EngineBaseline; fi
[ "$FAILED" -eq 0 ] && exit 0
exit 1
