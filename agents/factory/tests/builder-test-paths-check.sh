#!/usr/bin/env bash
# GUL-2204: a check script under scripts/tests/ can be product code. The spec field
# `builderTestPaths` names the test files green may change; every other test path stays
# frozen after red, and so do the files the AC checks run.
#
#   AC-1  lint-spec refuses a spec whose allowedPaths are all test paths and that has no
#         builderTestPaths, and refuses a bad builderTestPaths entry (glob, not a test path,
#         outside allowedPaths, named in an AC check); it accepts a good one
#   AC-2  check-green and commit --stage green accept a change to a builderTestPaths file
#         and still refuse a change to any other test path
#   AC-3  check-red and commit --stage red refuse a change to a builderTestPaths file
#   AC-4  the engine writes the list to <worktree git dir>/factory-builder-test-paths.json,
#         outside the worktree and never in `git status`
#
# Every case runs in a scratch git repo under TMPDIR. bash 3.2-safe.
# Usage: bash agents/factory/tests/builder-test-paths-check.sh [--ac AC-n]
set -u
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX GIT_CONFIG GIT_CONFIG_GLOBAL
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
FACTORY="$ROOT/agents/factory/factory.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/builder-test-paths-check-XXXXXX")" \
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
report() { # report AC-n "list of problems"
  if [ -z "$2" ]; then echo "$1: PASS"; else echo "$1: FAIL $2"; FAILED=1; fi
}

# spec FILE ALLOWED_JSON BTP_JSON_OR_EMPTY CHECK
spec() {
  local btp=""
  [ -n "$3" ] && btp=", \"builderTestPaths\": $3"
  cat > "$1" <<EOF
# spec

\`\`\`json
{"repo": "o/r", "base": "main", "kind": "code", "allowedPaths": $2$btp, "maxDiffLines": 100,
 "acs": [{"id": "AC-1", "text": "the selftest passes", "check": "$4"}]}
\`\`\`
EOF
}

lint() { python3 -I "$FACTORY" lint-spec --spec "$1" 2>/dev/null; }

if want AC-1; then
  P=""
  CHK="bash scripts/tests/thing-selftest.sh"
  spec "$TMP/l1.md" '["scripts/tests/**"]' "" "$CHK"
  lint "$TMP/l1.md" | grep -q "Builder can write none" || P="$P [all-test allowedPaths accepted]"
  spec "$TMP/l2.md" '["scripts/tests/**"]' '["scripts/tests/thing-check.sh"]' "$CHK"
  lint "$TMP/l2.md" | grep -q '"ok": true' || P="$P [good builderTestPaths refused: $(lint "$TMP/l2.md")]"
  spec "$TMP/l3.md" '["scripts/tests/**"]' '["scripts/tests/*.sh"]' "$CHK"
  lint "$TMP/l3.md" | grep -q "exact repo-relative" || P="$P [glob accepted]"
  spec "$TMP/l4.md" '["scripts/**"]' '["scripts/lib/thing.sh"]' "$CHK"
  lint "$TMP/l4.md" | grep -q "is not a test path" || P="$P [non-test path accepted]"
  spec "$TMP/l5.md" '["scripts/tests/**"]' '["apps/tests/x.sh"]' "$CHK"
  lint "$TMP/l5.md" | grep -q "outside allowedPaths" || P="$P [path outside allowedPaths accepted]"
  spec "$TMP/l6.md" '["scripts/tests/**"]' '["scripts/tests/thing-selftest.sh"]' "$CHK"
  lint "$TMP/l6.md" | grep -q "named in the AC check" || P="$P [AC check file accepted]"
  spec "$TMP/l7.md" '["scripts/**"]' "" "$CHK"
  lint "$TMP/l7.md" | grep -q '"ok": true' || P="$P [normal spec refused]"
  report AC-1 "$P"
fi

# repo DIR — scratch repo: base commit with two test files, then the red commit
repo() {
  mkdir -p "$1/scripts/tests" || return 1
  git init -q -b main "$1" || return 1
  git -C "$1" config user.name scratch
  git -C "$1" config user.email scratch@example.invalid
  echo old > "$1/scripts/tests/thing-check.sh"
  echo old > "$1/scripts/tests/other-check.sh"
  git -C "$1" add -A && git -C "$1" commit -q -m base || return 1
  git -C "$1" rev-parse HEAD > "$1.base"
  echo '#!/bin/sh' > "$1/scripts/tests/thing-selftest.sh"
  echo 'echo "AC-1: PASS"' >> "$1/scripts/tests/thing-selftest.sh"
  git -C "$1" add -A && git -C "$1" commit -q -m red || return 1
  git -C "$1" rev-parse HEAD > "$1.red"
}
CHK="sh scripts/tests/thing-selftest.sh"
spec "$TMP/s.md" '["scripts/tests/**"]' '["scripts/tests/thing-check.sh"]' "$CHK"

if want AC-2; then
  P=""
  G="$TMP/g"; repo "$G" || { echo "ENV: scratch repo failed" >&2; exit 2; }
  echo new > "$G/scripts/tests/thing-check.sh"
  OUT="$(python3 -I "$FACTORY" check-green --repo "$G" --red "$(cat "$G.red")" --spec "$TMP/s.md" 2>/dev/null)"
  echo "$OUT" | grep -q '"ok": true' || P="$P [check-green refused a builderTestPaths change: $OUT]"
  OUT="$(python3 -I "$FACTORY" commit --repo "$G" --stage green --issue GUL-1 --spec "$TMP/s.md" 2>/dev/null)"
  echo "$OUT" | grep -q '"ok": true' || P="$P [commit refused a builderTestPaths change: $OUT]"
  G2="$TMP/g2"; repo "$G2" || exit 2
  echo new > "$G2/scripts/tests/other-check.sh"
  OUT="$(python3 -I "$FACTORY" check-green --repo "$G2" --red "$(cat "$G2.red")" --spec "$TMP/s.md" 2>/dev/null)"
  echo "$OUT" | grep -q "test path differs from the red commit: scripts/tests/other-check.sh" \
    || P="$P [check-green accepted a frozen test path: $OUT]"
  OUT="$(python3 -I "$FACTORY" commit --repo "$G2" --stage green --issue GUL-1 --spec "$TMP/s.md" 2>/dev/null)"
  echo "$OUT" | grep -q "green commit touches a test path" || P="$P [commit accepted a frozen test path: $OUT]"
  report AC-2 "$P"
fi

if want AC-3; then
  P=""
  R="$TMP/r"; repo "$R" || exit 2
  git -C "$R" reset -q --hard "$(cat "$R.base")"
  echo '#!/bin/sh' > "$R/scripts/tests/thing-selftest.sh"
  echo 'echo "AC-1: FAIL not yet"; exit 1' >> "$R/scripts/tests/thing-selftest.sh"
  echo new > "$R/scripts/tests/thing-check.sh"
  OUT="$(python3 -I "$FACTORY" check-red --repo "$R" --base "$(cat "$R.base")" --spec "$TMP/s.md" 2>/dev/null)"
  echo "$OUT" | grep -q "red stage touched a builderTestPaths file" || P="$P [check-red accepted it: $OUT]"
  OUT="$(python3 -I "$FACTORY" commit --repo "$R" --stage red --issue GUL-1 --spec "$TMP/s.md" 2>/dev/null)"
  echo "$OUT" | grep -q "red commit touches a builderTestPaths file" || P="$P [commit accepted it: $OUT]"
  report AC-3 "$P"
fi

if want AC-4; then
  P=""
  M="$TMP/m"; repo "$M" || exit 2
  W="$TMP/wt"
  git -C "$M" worktree add -q -b wo "$W" HEAD || { echo "ENV: git worktree add failed" >&2; exit 2; }
  OUT="$(cd "$ROOT/agents/factory" && python3 -I -c '
import json, sys
sys.path.insert(0, ".")
import engine
st = {"worktree": sys.argv[1], "specFile": sys.argv[2]}
print(engine.Engine.prepare_builder_test_paths(None, st))
' "$W" "$TMP/s.md" 2>&1)"
  [ "$OUT" = "None" ] || P="$P [engine returned: $OUT]"
  GD="$(git -C "$W" rev-parse --absolute-git-dir)"
  F="$GD/factory-builder-test-paths.json"
  [ -f "$F" ] && grep -q '"scripts/tests/thing-check.sh"' "$F" || P="$P [no list in $F]"
  case "$F" in "$W"/*) P="$P [list is inside the worktree]";; esac
  [ -z "$(git -C "$W" status --porcelain)" ] || P="$P [git status not clean: $(git -C "$W" status --porcelain)]"
  report AC-4 "$P"
fi

[ "$FAILED" = 0 ] && exit 0 || exit 1
