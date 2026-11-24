#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-2147 - factory intake runbook (GUL-2037 phase 5, 2-click test).
#
# One acceptance criterion:
#   AC-1  docs/factory-intake.md has the six spec sections in order, states the
#         facts the runbook cannot lose, is at most 120 lines, and contains no
#         em dash (U+2014). Every pinned fact must still match main's
#         agents/factory/engine.py, engine.json and the launchd plist, so a
#         stale runbook fails instead of quietly teaching the wrong paths.
#
# Lives in docs/tests/, so scripts/check.sh discovers and runs it unchanged.
# Takes no arguments. Prints exactly one line for AC-1
# (agents/factory/CONTRACT.md point 2: `AC-<n>: PASS` / `AC-<n>: FAIL <reason>`,
# no colon after FAIL).
#
# Exit: 0 = AC-1 PASS, 1 = AC-1 FAIL. A missing runbook is a FAIL of AC-1, not a
# setup error: it is the thing under test.
#
# FACTORY_INTAKE_DOC overrides the target path so this check can be self-tested
# against a fixture; scripts/check.sh never sets it.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || exit 1
cd "$ROOT" || exit 1

DOC=${FACTORY_INTAKE_DOC:-docs/factory-intake.md}
ENGINE_PY=agents/factory/engine.py
ENGINE_JSON=agents/factory/engine.json
PLIST=agents/factory/launchd/dev.voitech.factory-engine.plist

fail() {
  printf 'AC-1: FAIL %s\n' "$(printf '%s' "$1" | tr '\n\t' '  ')"
  exit 1
}

# ---- the sources the facts come from must still say what we pin ----------
[ -f "$ENGINE_PY" ] || fail "$ENGINE_PY is missing; cannot ground the runbook facts"
[ -f "$ENGINE_JSON" ] || fail "$ENGINE_JSON is missing; cannot ground the runbook facts"
[ -f "$PLIST" ] || fail "$PLIST is missing; cannot read the tick interval"

# expanduser("~/...") may wrap onto a second line in engine.py: join, then read.
HOMES=$(tr '\n' ' ' < "$ENGINE_PY" | grep -o 'expanduser( *"~/[^"]*"' | sed 's/^expanduser( *"//; s/"$//')
STATE_DIR=$(printf '%s\n' "$HOMES" | grep -F 'engine-state' | head -n 1)
[ -n "$STATE_DIR" ] || fail "engine.py no longer names the engine-state directory; update this check with the source"
STOP_PATH=$(printf '%s\n' "$HOMES" | grep -F 'STOP' | head -n 1)
[ -n "$STOP_PATH" ] || fail "engine.py no longer names the STOP file; update this check with the source"

MAX_ORDERS=$(sed -n 's/.*"maxActiveOrders": *\([0-9][0-9]*\).*/\1/p' "$ENGINE_JSON" | head -n 1)
[ -n "$MAX_ORDERS" ] || fail "engine.json no longer has maxActiveOrders; update this check with the source"
WORKTREES=$(sed -n 's/.*"worktrees": *"\([^"]*\)".*/\1/p' "$ENGINE_JSON" | head -n 1)
[ -n "$WORKTREES" ] || fail "engine.json no longer has a worktrees root; update this check with the source"
# engine.py joins each order's worktree as worktrees/<branch>, so engine.json's
# root may be one segment below the "~/factory/worktrees/" the spec names.
case "$WORKTREES" in
  "$HOME/factory/worktrees"|"$HOME/factory/worktrees"/*) ;;
  *) fail "engine.json worktrees root is $WORKTREES, not under ~/factory/worktrees/; update this check with the source" ;;
esac

# StartInterval is seconds; the runbook speaks minutes.
TICK_SECONDS=$(awk '/<key>StartInterval<\/key>/{getline; gsub(/[^0-9]/,""); print; exit}' "$PLIST")
[ -n "$TICK_SECONDS" ] || fail "the launchd plist no longer has StartInterval; update this check with the source"
TICK_MINUTES=$((TICK_SECONDS / 60))
[ "$TICK_MINUTES" -gt 0 ] || fail "StartInterval is under a minute; the runbook's 'every N minutes' cannot be stated"

# The spec-gate rules live in engine.py; pin them so a moved rule is noticed.
grep -Fq 'SPEC_GATE_PREFIX = "spec-gate:"' "$ENGINE_PY" \
  || fail "engine.py no longer pins SPEC_GATE_PREFIX; update this check with the source"
grep -Fq 'resolvedByUserId' "$ENGINE_PY" \
  || fail "engine.py no longer requires a human to accept the spec card; update this check with the source"

# ---- the runbook itself --------------------------------------------------
[ -f "$DOC" ] || fail "$DOC does not exist"
[ -r "$DOC" ] || fail "$DOC is not readable"

# Exactly the six sections, exactly and in order: no extra `##`.
EXPECTED='## Give a direction
## The question card
## The spec card
## After the accept
## Engine internals
## Watch it and stop it'
HEADINGS=$(grep -E '^## ' "$DOC")
if [ "$HEADINGS" != "$EXPECTED" ]; then
  fail "the '##' headings must be exactly the six spec sections in this order | got: $(printf '%s' "$HEADINGS" | tr '\n' '|') | want: $(printf '%s' "$EXPECTED" | tr '\n' '|')"
fi

# No empty section: every heading owns at least one non-blank line.
EMPTY=$(awk '
  /^## / { if (seen && !body) print title; title = $0; seen = 1; body = 0; next }
  seen && NF { body = 1 }
  END { if (seen && !body) print title }
' "$DOC")
[ -z "$EMPTY" ] || fail "section(s) with no text: $(printf '%s' "$EMPTY" | tr '\n' '|')"

# ---- the facts the spec pins --------------------------------------------
MISSING=''
for NEEDLE in \
  'spec-gate:' \
  'request_confirmation' \
  'in_review' \
  'auto' \
  'engine-state' \
  'maxActiveOrders' \
  'factory-stall-ladder.md' \
  'lodge.voitech.dev' \
  'majster/factory/STOP' \
  "$STATE_DIR" \
  "$STOP_PATH" \
  '~/factory/worktrees' \
  "$TICK_MINUTES minutes"
do
  grep -Fq -e "$NEEDLE" "$DOC" || MISSING="$MISSING [$NEEDLE]"
done
if [ -n "$MISSING" ]; then
  fail "facts missing from $DOC:$MISSING"
fi

# The agent accept / stale revision rules, and the stage order after accept.
for NEEDLE in 'agent' 'revision' 'rejected' "most $MAX_ORDERS orders"; do
  grep -Fqi -e "$NEEDLE" "$DOC" || MISSING="$MISSING [$NEEDLE]"
done
if [ -n "$MISSING" ]; then
  fail "spec-gate rules missing from $DOC:$MISSING"
fi

# The stage order is a fact of the `## After the accept` section only, so read
# that section alone ("spec-gate:" and "in_review" earlier in the file would
# otherwise feed the token stream).
AFTER_ACCEPT=$(awk '/^## /{on = ($0 == "## After the accept")} on && !/^## /' "$DOC")
STAGE_ORDER=$(printf '%s\n' "$AFTER_ACCEPT" | grep -o -E 'Librarian|red|green|review|verify|gate' | tr '\n' ' ' | sed 's/  */ /g; s/ $//')
case " $STAGE_ORDER " in
  *' Librarian red green review verify gate '*) ;;
  *) fail "the after-accept stages must be named in order Librarian, red, green, review, verify, gate | got: $STAGE_ORDER" ;;
esac

# ---- no em dash (the repo's writing rule) --------------------------------
if grep -Fq -e "$(printf '\342\200\224')" "$DOC"; then
  LINE=$(grep -Fn -e "$(printf '\342\200\224')" "$DOC" | head -n 1 | cut -d: -f1)
  fail "em dash (U+2014) found on line $LINE; use a colon, comma or full stop"
fi

# ---- at most 120 lines (awk counts a final line without a newline) ------
LINES=$(awk 'END { print NR }' "$DOC")
[ "$LINES" -le 120 ] || fail "$DOC has $LINES lines, the spec allows at most 120"

printf 'AC-1: PASS\n'
exit 0
