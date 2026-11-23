#!/usr/bin/env bash
# GUL-2080 regression: the factory self-tests must never write into a real
# checkout, even when the caller leaks GIT_DIR (a git hook, a parent tool).
# On 2026-11-23 an inherited GIT_DIR made factory-check.sh commit fixture data
# on a live work-order branch and set the clone's user.name to "factory test".
#
# This builds a scratch clone + worktree, points GIT_DIR at the worktree's git
# dir, runs factory-check.sh from inside the worktree, and checks that refs,
# local config and the worktree list did not change. bash 3.2-safe.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/git-isolation-XXXXXX")" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fail=0
ok()  { printf '  ok  %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

( unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  git init -q -b main "$TMP/outer"
  git -C "$TMP/outer" config user.name outer
  git -C "$TMP/outer" config user.email outer@example.invalid
  printf 'outer\n' > "$TMP/outer/f"
  git -C "$TMP/outer" add f
  git -C "$TMP/outer" commit -qm outer
  git -C "$TMP/outer" worktree add -q -b wo-branch "$TMP/wt" )

snapshot() {
  ( unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    git -C "$TMP/outer" for-each-ref --format='%(refname) %(objectname)'
    git -C "$TMP/outer" config --local --list
    git -C "$TMP/outer" worktree list --porcelain )
}
before="$(snapshot)"

# The worktree must hold the test scripts the suite expects to find at ROOT,
# so run the real suite from ROOT but with cwd and GIT_DIR in the scratch worktree.
gitdir="$(cd "$TMP/wt" && git rev-parse --absolute-git-dir)"
( cd "$TMP/wt" && GIT_DIR="$gitdir" GIT_WORK_TREE="$TMP/wt" \
    bash "$ROOT/agents/factory/tests/factory-check.sh" > "$TMP/run.out" 2>&1 )
rc=$?

after="$(snapshot)"
[ "$rc" = 0 ] && ok "factory-check passes with a leaked GIT_DIR" \
  || { bad "factory-check failed with a leaked GIT_DIR (rc=$rc)"; tail -20 "$TMP/run.out"; }
[ "$before" = "$after" ] && ok "outer repo refs, config and worktrees unchanged" \
  || { bad "outer repo changed:"; diff <(printf '%s\n' "$before") <(printf '%s\n' "$after"); }
[ -d "$TMP/wt" ] && ok "worktree still exists" || bad "worktree was removed"

[ "$fail" = 0 ] && echo "git-isolation-check: ALL PASS" || echo "git-isolation-check: FAIL"
exit "$fail"
