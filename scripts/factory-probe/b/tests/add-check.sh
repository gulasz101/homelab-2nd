#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# AC-1 for GUL-2051 — scripts/factory-probe/b/add.sh prints the sum of its
# integer arguments.
#
# Three behaviours, one acceptance criterion:
#   1. `sh scripts/factory-probe/b/add.sh 2 3 4` prints exactly `9` on stdout;
#   2. with no argument it prints exactly `0`;
#   3. a non-integer argument prints `add: not an integer: <arg>` on stderr
#      and exits 2.
#
# Hermetic: no network, no cluster, no secrets. Prints one `AC-1:` line and
# exits 0 (PASS) or 1 (FAIL) per the factory check protocol.
# Discovered and run by scripts/check.sh, like every */tests/*-check.sh.
# ---------------------------------------------------------------------------
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd) || {
  echo "AC-1: FAIL cannot locate the repo root"
  exit 1
}
cd "$ROOT" || {
  echo "AC-1: FAIL cannot cd to $ROOT"
  exit 1
}

ADD=scripts/factory-probe/b/add.sh
WORK=$(mktemp -d) || {
  echo "AC-1: FAIL cannot create a temp dir"
  exit 1
}
trap 'rm -rf "$WORK"' EXIT

problems=""
add_problem() { problems="${problems}${problems:+; }$1"; }

if [ ! -f "$ADD" ]; then
  add_problem "missing $ADD"
else
  # --- 1. sums its arguments ---------------------------------------------
  out=$(sh "$ADD" 2 3 4 2>"$WORK/err")
  st=$?
  err=$(cat "$WORK/err")
  if [ "$st" -ne 0 ]; then
    add_problem "'sh $ADD 2 3 4' exited $st, want 0 (stderr: ${err:-<empty>})"
  elif [ "$out" != "9" ]; then
    add_problem "'sh $ADD 2 3 4' printed '${out}' on stdout, want '9'"
  fi

  # --- 2. zero arguments prints 0 ----------------------------------------
  out=$(sh "$ADD" 2>"$WORK/err")
  st=$?
  err=$(cat "$WORK/err")
  if [ "$st" -ne 0 ]; then
    add_problem "'sh $ADD' with no arguments exited $st, want 0 (stderr: ${err:-<empty>})"
  elif [ "$out" != "0" ]; then
    add_problem "'sh $ADD' with no arguments printed '${out}' on stdout, want '0'"
  fi

  # --- 3. a non-integer is rejected --------------------------------------
  out=$(sh "$ADD" 2 nine 4 2>"$WORK/err")
  st=$?
  err=$(cat "$WORK/err")
  if [ "$st" -ne 2 ]; then
    add_problem "'sh $ADD 2 nine 4' exited $st, want 2"
  fi
  case "$err" in
    *"add: not an integer: nine"*) ;;
    *) add_problem "'sh $ADD 2 nine 4' stderr '${err}' does not contain 'add: not an integer: nine'" ;;
  esac
fi

if [ -z "$problems" ]; then
  echo "AC-1: PASS"
  exit 0
fi

echo "AC-1: FAIL $problems"
exit 1
