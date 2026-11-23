#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-2110 - factory auto-merge runbook (phase 4 live check).
#
# One acceptance criterion:
#   AC-1  docs/factory-auto-merge.md exists, has exactly the four `##`
#         sections of the spec in order, states the facts the runbook cannot
#         lose (App login and App ID, the key file variable and key directory
#         and its 600 mode, the protect-main ruleset, the never-paths file,
#         --match-head-commit, CODEOWNERS, the STOP switch), is at most 60
#         lines, and contains no em dash (U+2014).
#
# Lives in docs/tests/, so scripts/check.sh discovers and runs it unchanged.
# Takes no arguments. Prints exactly one line per covered AC, on one line
# (agents/factory/CONTRACT.md point 2 - the engine only accepts
# `AC-<n>: PASS` and `AC-<n>: FAIL <reason>`, so there is NO colon after FAIL).
#
# Exit: 0 = AC-1 PASS, 1 = AC-1 FAIL. A missing runbook is a FAIL of AC-1,
# not a setup error: it is the thing under test.
#
# FACTORY_AUTO_MERGE_DOC overrides the target path; it exists so this check
# can be self-tested against a fixture, and scripts/check.sh never sets it.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || exit 1
cd "$ROOT" || exit 1

DOC=${FACTORY_AUTO_MERGE_DOC:-docs/factory-auto-merge.md}

# One line, always. Newlines and tabs in a reason would split the AC line.
fail() {
  printf 'AC-1: FAIL %s\n' "$(printf '%s' "$1" | tr '\n\t' '  ')"
  exit 1
}

[ -f "$DOC" ] || fail "$DOC does not exist"
[ -r "$DOC" ] || fail "$DOC is not readable"

# ---- the four sections, exactly and in order -----------------------------
# Exactly: no extra `##` heading, none renamed, none reordered.
EXPECTED='## How auto-merge works
## Where the key lives
## What GitHub enforces
## How to stop the factory'
HEADINGS=$(grep -E '^## ' "$DOC")
if [ "$HEADINGS" != "$EXPECTED" ]; then
  fail "the '##' headings must be exactly the four spec sections in this order | got: $(printf '%s' "$HEADINGS" | tr '\n' '|') | want: $(printf '%s' "$EXPECTED" | tr '\n' '|')"
fi

# ---- the facts the spec pins --------------------------------------------
MISSING=''
for NEEDLE in \
  'gulasz101-factory' \
  '5893473' \
  '--match-head-commit' \
  'never-paths.json' \
  'FACTORY_GH_APP_KEY_FILE' \
  '/Users/paperclip/.config/factory/' \
  '600' \
  'protect-main' \
  'CODEOWNERS' \
  'STOP'
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

# ---- at most 60 lines (awk counts a final line without a newline) -------
LINES=$(awk 'END { print NR }' "$DOC")
[ "$LINES" -le 60 ] || fail "$DOC has $LINES lines, the spec allows at most 60"

printf 'AC-1: PASS\n'
exit 0
