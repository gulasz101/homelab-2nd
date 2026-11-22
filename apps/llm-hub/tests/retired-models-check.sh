#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-2009: a route the hub has retired must not come back unnoticed, and the
# ledger must stay useful.
#
# Why this exists: the weekly sync now archives any route the upstream refuses
# permanently (400/403/404/410) instead of keeping a name nobody can call in
# /v1/models. That is only worth anything if two things hold afterwards:
#
#   1. no route in litellm-helm-release.yaml is listed as retired in the ledger
#      (a hand-edit or a bad rebase could silently resurrect a dead name, and the
#      next caller eats the 403 again);
#   2. every retired entry carries a reason and a date, because the whole point
#      of the ledger is answering "why isn't this model here any more?" months
#      later, and a row without a reason answers nothing.
#
# Hermetic: reads two files, no network, no cluster, no sops, no git writes.
# bash 3.2 compatible (macOS) - no associative arrays, no mapfile.
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
LEDGER="${REPO_ROOT}/apps/llm-hub/retired-models.yaml"
RELEASE="${REPO_ROOT}/apps/llm-hub/litellm-helm-release.yaml"
DOCS="${REPO_ROOT}/docs/llm-hub-retired-models.md"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

for f in "$LEDGER" "$RELEASE" "$DOCS"; do
  [ -f "$f" ] || bad "missing file: $f"
done
[ "$fail" -ne 0 ] && exit 1

# model_name + state + reason + last_seen, one record per line, from the ledger.
RECORDS=$(awk '
  /^- model_name:/ {
    if (name != "") printf "%s\t%s\t%s\t%s\n", name, state, reason, seen
    name = $0; sub(/^- model_name:[[:space:]]*/, "", name)
    state = ""; reason = ""; seen = ""
    next
  }
  /^  state:/ { state = $2 }
  /^  reason:/ { reason = "set" }
  /^  last_seen:/ { seen = $2 }
  END { if (name != "") printf "%s\t%s\t%s\t%s\n", name, state, reason, seen }
' "$LEDGER")

if [ -z "$RECORDS" ]; then
  bad "ledger has no entries - it should carry at least the first retirement"
  exit 1
fi

retired_count=0
resurrected=0
while IFS="$(printf '\t')" read -r name state reason seen; do
  [ -n "$name" ] || continue
  [ "$state" = "retired" ] || continue
  retired_count=$((retired_count + 1))
  if [ -z "$reason" ]; then
    bad "retired entry '${name}' has no reason - the ledger must explain itself"
  fi
  if [ -z "$seen" ]; then
    bad "retired entry '${name}' has no last_seen date"
  fi
  if grep -qE "^[[:space:]]*-?[[:space:]]*model_name:[[:space:]]*\"?${name}\"?[[:space:]]*$" "$RELEASE"; then
    bad "route '${name}' is marked retired in the ledger but advertised again in litellm-helm-release.yaml"
    resurrected=$((resurrected + 1))
  fi
done <<EOF
$RECORDS
EOF

if [ "$retired_count" -eq 0 ]; then
  bad "no retired entries found - the ledger or its format changed"
else
  pass "${retired_count} retired route(s) recorded, none of them advertised by the hub"
fi

# The generated docs must know about every retired route: if they lag behind,
# the human-readable record is lying, which is worse than having none.
missing_docs=0
while IFS="$(printf '\t')" read -r name state reason seen; do
  [ -n "$name" ] || continue
  [ "$state" = "retired" ] || continue
  if ! grep -qF "\`${name}\`" "$DOCS"; then
    bad "docs/llm-hub-retired-models.md does not mention retired route '${name}' - regenerate it"
    missing_docs=$((missing_docs + 1))
  fi
done <<EOF
$RECORDS
EOF
[ "$missing_docs" -eq 0 ] && pass "docs table lists every retired route"

if [ "$fail" -ne 0 ]; then
  printf '\nThe retirement ledger and the hub disagree. See docs/llm-hub-retired-models.md\n'
  exit 1
fi
printf '\nLedger and hub agree: nothing retired is being advertised.\n'
