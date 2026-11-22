#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/factory-probe/a/greet.sh — AC-1 (GUL-2050):
#   sh scripts/factory-probe/a/greet.sh Wojtek  -> exactly "Hello, Wojtek!", exit 0
#   sh scripts/factory-probe/a/greet.sh        -> exactly "Hello, world!",  exit 0
#
# Hermetic: no network, no cluster, no secrets — safe for CI. Takes no
# arguments and runs from the repo root, like every */tests/*-check.sh
# discovered by scripts/check.sh.
#
# stdout is exactly one line (`AC-1: PASS` or `AC-1: FAIL <reason>`);
# diagnostics go to stderr. Exit: 0 = AC-1 passed, 1 = AC-1 failed, so a
# missing script is a plain FAIL and never a setup error.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
REL="scripts/factory-probe/a/greet.sh"
SCRIPT="$ROOT/$REL"

FAILED=0
REASONS=""
note() { printf 'greet-check: %s\n' "$*" >&2; }
add_reason() {
  FAILED=1
  if [ -z "$REASONS" ]; then REASONS="$1"; else REASONS="$REASONS; $1"; fi
}

# Compare captured stdout byte-for-byte (trailing newline included) with the
# expected line + newline; report the actual bytes on stderr on a mismatch.
expect_stdout() { # $1=case label, $2=expected text, $3=file holding stdout
  local label=$1 want=$2 got_file=$3 actual
  printf '%s\n' "$want" > "$WORK/want"
  if cmp -s "$WORK/want" "$got_file"; then
    note "ok: $label prints exactly '$want'"
    return 0
  fi
  actual=$(sed -e 's/^/[/' -e 's/$/]/' "$got_file" | tr '\n' ' ')
  note "FAIL: $label expected exactly '$want', got: $actual"
  add_reason "$label printed $actual instead of [$want]"
  return 1
}

if [ ! -f "$SCRIPT" ]; then
  printf 'AC-1: FAIL %s does not exist\n' "$REL"
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---- case 1: the first argument is used -----------------------------------
(cd "$ROOT" && sh "$REL" Wojtek) > "$WORK/arg.out" 2> "$WORK/arg.err"
arg_rc=$?
if [ "$arg_rc" -ne 0 ]; then
  note "FAIL: 'sh $REL Wojtek' exited $arg_rc (expected 0); stderr: $(tr '\n' ' ' < "$WORK/arg.err")"
  add_reason "'sh $REL Wojtek' exited $arg_rc, expected 0"
fi
expect_stdout "'sh $REL Wojtek'" "Hello, Wojtek!" "$WORK/arg.out"

# ---- case 2: no argument falls back to world ------------------------------
(cd "$ROOT" && sh "$REL") > "$WORK/noarg.out" 2> "$WORK/noarg.err"
noarg_rc=$?
if [ "$noarg_rc" -ne 0 ]; then
  note "FAIL: 'sh $REL' with no argument exited $noarg_rc (expected 0); stderr: $(tr '\n' ' ' < "$WORK/noarg.err")"
  add_reason "'sh $REL' with no argument exited $noarg_rc, expected 0"
fi
expect_stdout "'sh $REL' (no argument)" "Hello, world!" "$WORK/noarg.out"

# ---- verdict --------------------------------------------------------------
if [ "$FAILED" -eq 0 ]; then
  printf 'AC-1: PASS\n'
  exit 0
fi
printf 'AC-1: FAIL %s\n' "$REASONS"
exit 1
