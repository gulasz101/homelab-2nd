#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-2096 / AC-1.
#
# "sh host/paperclip-air/factory-probe-d/greet.sh prints exactly `hello factory`
#  on stdout and exits 0."
#
# The check runs the program the way the AC names it — through `sh`, from this
# directory — and compares stdout *byte for byte* with `hello factory` plus a
# single trailing newline (14 bytes). Byte comparison on purpose: `Hello,
# factory!`, `Hello, Factory!`, `hello  factory`, a missing newline or a stray
# banner are all different programs, and a human reading the AC would notice.
#
# No arguments: scripts/check.sh discovers every */tests/*-check.sh and runs it
# bare, so a check that needs a flag would make the green stage unwinnable.
#
# Fixture self-test (GUL-2103): this check shipped once with the expected
# fixture written as `Hello, Factory!`, which no correct program could ever
# match. So before judging the real program the check proves its own
# fixture/comparison works both ways: a stand-in that prints the AC's literal
# must be accepted, and one that prints the old wrong fixture must be rejected.
# A broken check is a setup error, not an AC failure.
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

# --- fixture: built here, not committed ------------------------------------
printf 'hello factory\n' > "$TMP/expected" || { printf 'ENV: cannot write fixture\n' >&2; exit 2; }

# The AC's literal, spelled once. Everything below is checked against this
# file, so the self-test cannot drift from the real comparison.
exp_bytes=$(wc -c < "$TMP/expected" | tr -d '[:space:]')
if [ "$exp_bytes" != "14" ]; then
  printf 'ENV: expected fixture is %s bytes, the AC requires 14\n' "$exp_bytes" >&2
  exit 2
fi

# --- verdict helper: empty output means the run satisfies AC-1 -------------
# $1 = stdout file, $2 = stderr file, $3 = exit code
verdict() {
  local out=$1 errf=$2 rc=$3 problems="" err got_bytes got
  if [ "$rc" -ne 0 ]; then
    err=$(tr '\n' ' ' < "$errf" | cut -c1-200)
    problems="expected exit 0, got $rc"
    [ -n "${err// /}" ] && problems="$problems; stderr: $err"
  fi
  if ! cmp -s "$TMP/expected" "$out"; then
    got_bytes=$(wc -c < "$out" | tr -d '[:space:]')
    got=$(sed -n 'l' "$out" | tr '\n' '|' | cut -c1-200)
    [ -n "$got" ] || got='<empty>'
    problems="${problems}${problems:+; }stdout must be exactly the 14 bytes 'hello factory\\n' (no extra text, no missing newline), got ${got_bytes} bytes: ${got}"
  fi
  printf '%s' "$problems"
}

# --- fixture self-test: a correct stand-in must PASS ------------------------
printf '#!/bin/sh\nprintf "hello factory\\n"\n' > "$TMP/standin-good.sh" \
  || { printf 'ENV: cannot write self-test stand-in\n' >&2; exit 2; }
sh "$TMP/standin-good.sh" > "$TMP/self-good.out" 2> "$TMP/self-good.err"
if [ -n "$(verdict "$TMP/self-good.out" "$TMP/self-good.err" $?)" ]; then
  printf 'ENV: this check rejects a program that prints exactly "hello factory"; fixture or comparison is broken\n' >&2
  exit 2
fi

# --- fixture self-test: the old wrong fixture must FAIL --------------------
printf '#!/bin/sh\nprintf "Hello, Factory!\\n"\n' > "$TMP/standin-wrong.sh" \
  || { printf 'ENV: cannot write self-test stand-in\n' >&2; exit 2; }
sh "$TMP/standin-wrong.sh" > "$TMP/self-wrong.out" 2> "$TMP/self-wrong.err"
if [ -z "$(verdict "$TMP/self-wrong.out" "$TMP/self-wrong.err" $?)" ]; then
  printf 'ENV: this check accepts "Hello, Factory!"; the expected fixture does not match AC-1\n' >&2
  exit 2
fi

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

problems=$(verdict "$TMP/stdout" "$TMP/stderr" "$rc")

if [ -n "$problems" ]; then
  printf 'AC-1: FAIL %s\n' "$problems"
  exit 1
fi

printf 'AC-1: PASS\n'
exit 0
