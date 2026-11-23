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
# GUL-2091: a dead TMPDIR left TMP empty and the fixtures below ran git in the
# caller's checkout. Stop before any git command.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/git-isolation-XXXXXX")" \
  || { echo "ENV: mktemp -d failed (TMPDIR=${TMPDIR:-unset})" >&2; exit 2; }
[ -d "$TMP" ] || { echo "ENV: mktemp -d gave no directory (TMPDIR=${TMPDIR:-unset})" >&2; exit 2; }
TMP="$(cd "$TMP" && pwd -P)" || exit 2
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

# ---- case 2 (GUL-2089/GUL-2091): a dead TMPDIR ----
# mktemp failed, TMP was empty, and the fixture subshells' failed `cd` left git
# running in the caller's worktree: a "base" commit on the branch and
# user.name=factory test in the clone's config. Same scratch setup, fresh clone.
( unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  git clone -q "$TMP/outer" "$TMP/clone"
  git -C "$TMP/clone" config user.name clone
  git -C "$TMP/clone" config user.email clone@example.invalid
  git -C "$TMP/clone" worktree add -q -b wo-dead-tmp "$TMP/wt2" )
snapshot2() {
  ( unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    git -C "$TMP/wt2" rev-parse HEAD
    git -C "$TMP/clone" for-each-ref --format='%(refname) %(objectname)'
    git -C "$TMP/clone" config --local --list
    git -C "$TMP/clone" worktree list --porcelain )
}
before2="$(snapshot2)"
( unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  cd "$TMP/wt2" || exit 1
  TMPDIR=/nonexistent/gul-2089 bash "$ROOT/agents/factory/tests/factory-check.sh" > "$TMP/run2.out" 2>&1 )
after2="$(snapshot2)"
[ "$before2" = "$after2" ] && ok "dead TMPDIR: branch head, refs, clone config and worktrees unchanged" \
  || { bad "dead TMPDIR: the run wrote into the scratch checkout:"; diff <(printf '%s\n' "$before2") <(printf '%s\n' "$after2"); }
grep -q '^ENV:' "$TMP/run2.out" && ok "dead TMPDIR: run printed an ENV: line" \
  || { bad "dead TMPDIR: no ENV: line in the output"; tail -5 "$TMP/run2.out"; }

[ "$fail" = 0 ] && echo "git-isolation-check: ALL PASS" || echo "git-isolation-check: FAIL"
exit "$fail"
