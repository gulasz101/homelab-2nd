#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-2096 / AC-1.
#
# "sh host/paperclip-air/factory-probe-d/greet.sh prints exactly `hello factory`
#  on stdout and exits 0."
#
# The check runs the program the way the AC names it — through `sh`, from this
# directory — and compares stdout *byte for byte* with `hello factory` plus a
# single trailing newline. Byte comparison on purpose: `Hello, factory!`,
# `hello  factory`, a missing newline or a stray banner are all different
# programs, and a human reading the AC would notice.
#
# No arguments: scripts/check.sh discovers every */tests/*-check.sh and runs it
# bare, so a check that needs a flag would make the green stage unwinnable.
#
# Prints exactly one line: `AC-1: PASS` or `AC-1: FAIL <reason>`; exit 0/1.
# Exit 2 means the check could not trust its own fixtures (setup error, GUL-2091).
# ---------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)   # .../host/paperclip-air/factory-probe-d
PROG="$HERE/greet.sh"
RELPROG="host/paperclip-air/factory-probe-d/greet.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/probe-d-greet-XXXXXX") \
  || { printf 'ENV: mktemp -d failed (TMPDIR=%s)\n' "${TMPDIR:-unset}" >&2; exit 2; }
[ -d "$TMP" ] || { printf 'ENV: mktemp -d gave no directory\n' >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

# --- fixtures: built here, not committed -----------------------------------
printf 'Hello, Factory!\n' > "$TMP/expected"

# --- the program the AC names must exist at all ---------------------------
if [ ! -f "$PROG" ]; then
  printf 'AC-1: FAIL %s does not exist, so `sh %s` cannot print "hello factory"\n' "$RELPROG" "$RELPROG"
  exit 1
fi

if [ ! -r "$PROG" ]; then
  printf 'AC-1: FAIL %s is not readable\n' "$RELPROG"
  exit 1
fi

# --- run it exactly as the AC does ----------------------------------------
sh "$PROG" > "$TMP/stdout" 2> "$TMP/stderr"
rc=$?

problems=""
add() { problems="${problems}${problems:+; }$1"; }

if [ "$rc" -ne 0 ]; then
  err=$(tr '\n' ' ' < "$TMP/stderr" | cut -c1-200)
  add "expected exit 0, got $rc"
  [ -n "${err// /}" ] && add "stderr: $err"
fi

if ! cmp -s "$TMP/expected" "$TMP/stdout"; then
  got_bytes=$(wc -c < "$TMP/stdout" | tr -d '[:space:]')
  got=$(sed -n 'l' "$TMP/stdout" | tr '\n' '|' | cut -c1-200)
  [ -n "$got" ] || got='<empty>'
  add "stdout must be exactly the 14 bytes 'hello factory\n' (no extra text, no missing newline), got ${got_bytes} bytes: ${got}"
fi

if [ -n "$problems" ]; then
  printf 'AC-1: FAIL %s\n' "$problems"
  exit 1
fi

printf 'AC-1: PASS\n'
exit 0
