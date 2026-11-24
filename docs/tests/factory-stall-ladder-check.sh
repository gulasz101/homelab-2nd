#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-2140 - factory stall-ladder runbook (phase 4 guard probe, take 2).
#
# One acceptance criterion:
#   AC-1  docs/factory-stall-ladder.md exists, has exactly the three `##`
#         sections of the spec in order, states the facts the runbook cannot
#         lose (the three-verdict ladder and its verdict strings, the
#         Investigator model, the `[stall]` issue the owner gets), is at most
#         40 lines, and contains no em dash (U+2014).
#
# The guard probe in the AC text (the GUARD-PROBE.txt writes) is the Reviewer's
# job, not this script's: this check owns the runbook only.
#
# Lives in docs/tests/, so scripts/check.sh discovers and runs it unchanged.
# Takes no arguments. Prints exactly one line for AC-1, on one line
# (agents/factory/CONTRACT.md point 2 - the engine only accepts
# `AC-<n>: PASS` and `AC-<n>: FAIL <reason>`, so there is NO colon after FAIL).
#
# Exit: 0 = AC-1 PASS, 1 = AC-1 FAIL. A missing runbook is a FAIL of AC-1,
# not a setup error: it is the thing under test.
#
# FACTORY_STALL_LADDER_DOC overrides the target path; it exists so this check
# can be self-tested against a fixture, and scripts/check.sh never sets it.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || exit 1
cd "$ROOT" || exit 1

DOC=${FACTORY_STALL_LADDER_DOC:-docs/factory-stall-ladder.md}

# One line, always. Newlines and tabs in a reason would split the AC line.
fail() {
  printf 'AC-1: FAIL %s\n' "$(printf '%s' "$1" | tr '\n\t' '  ')"
  exit 1
}

[ -f "$DOC" ] || fail "$DOC does not exist"
[ -r "$DOC" ] || fail "$DOC is not readable"

# ---- the three sections, exactly and in order ----------------------------
# Exactly: no extra `##` heading, none renamed, none reordered.
EXPECTED='## When a stage fails
## The Investigator
## When the owner is asked'
HEADINGS=$(grep -E '^## ' "$DOC")
if [ "$HEADINGS" != "$EXPECTED" ]; then
  fail "the '##' headings must be exactly the three spec sections in this order | got: $(printf '%s' "$HEADINGS" | tr '\n' '|') | want: $(printf '%s' "$EXPECTED" | tr '\n' '|')"
fi

# ---- the facts the spec pins --------------------------------------------
MISSING=''
for NEEDLE in \
  'TEST-WRONG' \
  'CODE-WRONG' \
  'SPEC-WRONG' \
  'deepseek-v4-pro-ollama' \
  '[stall]'
do
  grep -Fq -e "$NEEDLE" "$DOC" || MISSING="$MISSING [$NEEDLE]"
done
if [ -n "$MISSING" ]; then
  fail "facts missing from $DOC:$MISSING"
fi

# ---- no em dash (the repo's writing rule) --------------------------------
if grep -Fq -e "$(printf '\342\200\224')" "$DOC"; then
  LINE=$(grep -Fn -e "$(printf '\342\200\224')" "$DOC" | head -n 1 | cut -d: -f1)
  fail "em dash (U+2014) found on line $LINE; use a colon, comma or full stop"
fi

# ---- at most 40 lines (awk counts a final line without a newline) -------
LINES=$(awk 'END { print NR }' "$DOC")
[ "$LINES" -le 40 ] || fail "$DOC has $LINES lines, the spec allows at most 40"

printf 'AC-1: PASS\n'
exit 0
