#!/usr/bin/env bash
# GUL-2091 (cause proven in GUL-2089): a dead TMPDIR must stop the self-tests,
# never let their fixture repos run git in the checkout they were started from.
#
#   AC-2  each repo-building self-test, and scripts/check.sh, exits 2 with a line
#         starting ENV: when TMPDIR=/nonexistent/gul-2089, and makes no commit and
#         no config change in the checkout it ran from
#   AC-3  factory.py check-red / check-green exit 2 with a reason starting
#         "ENV: TMPDIR" and run no AC check
#
# Every script under test is COPIED into a scratch git repo and run from there,
# so an unfixed script can only damage the scratch copy. bash 3.2-safe.
#
# Usage: bash agents/factory/tests/tmpdir-check.sh [--ac AC-2|AC-3]
#        (no argument runs every case, as scripts/check.sh does)
set -u
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX GIT_CONFIG GIT_CONFIG_GLOBAL
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tmpdir-check-XXXXXX")" \
  || { echo "ENV: mktemp -d failed (TMPDIR=${TMPDIR:-unset})" >&2; exit 2; }
[ -d "$TMP" ] || { echo "ENV: mktemp -d gave no directory (TMPDIR=${TMPDIR:-unset})" >&2; exit 2; }
TMP="$(cd "$TMP" && pwd -P)" || exit 2
trap 'rm -rf "$TMP"' EXIT
DEAD=/nonexistent/gul-2089

ONLY=""
case "${1:-}" in
  "") ;;
  --ac) ONLY="${2:-}"; [ -n "$ONLY" ] || { echo "usage: $0 [--ac AC-n]" >&2; exit 2; } ;;
  *) echo "usage: $0 [--ac AC-n]" >&2; exit 2 ;;
esac
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

# scratch_repo DIR — a git repo with one commit and its own local user config
scratch_repo() {
  mkdir -p "$1" || return 1
  git init -q -b main "$1" || return 1
  git -C "$1" config user.name scratch
  git -C "$1" config user.email scratch@example.invalid
  printf 'scratch\n' > "$1/README.md"
  git -C "$1" add -A && git -C "$1" commit -qm scratch
}
snapshot() { # repo — head, refs, local config, worktrees
  git -C "$1" rev-parse HEAD
  git -C "$1" for-each-ref --format='%(refname) %(objectname)'
  git -C "$1" config --local --list
  git -C "$1" worktree list --porcelain
}

FAIL_N=0

# ---------- AC-2 ----------
if want AC-2; then
  why=""
  n=0
  for rel in agents/factory/tests/factory-check.sh \
             agents/factory/tests/git-isolation-check.sh \
             agents/factory/tests/runner-check.sh \
             agents/factory-guard/tests/guard-check.sh \
             infrastructure/observability/tests/grafana-datasource-reset-check.sh \
             scripts/check.sh; do
    n=$((n + 1))
    S="$TMP/s$n"
    scratch_repo "$S" >/dev/null 2>&1 || { why="$why; $rel: scratch repo setup failed"; continue; }
    # copy the script's own tree (what it reaches through ROOT), never .git
    case "$rel" in
      agents/factory/*)         src="agents/factory" ;;
      agents/factory-guard/*)   src="agents/factory-guard" ;;
      infrastructure/*)         src="infrastructure/observability" ;;
      scripts/check.sh)         src="scripts/check.sh" ;;
    esac
    mkdir -p "$S/$(dirname "$src")"
    cp -R "$ROOT/$src" "$S/$src"
    git -C "$S" add -A >/dev/null 2>&1 && git -C "$S" commit -qm copy >/dev/null 2>&1
    before="$(snapshot "$S")"
    ( cd "$S" || exit 1; TMPDIR="$DEAD" bash "$S/$rel" ) > "$TMP/out$n" 2>&1 < /dev/null
    rc=$?
    after="$(snapshot "$S" 2>&1)"
    [ "$rc" = 2 ] || why="$why; $rel exited $rc, want 2"
    grep -q '^ENV:' "$TMP/out$n" || why="$why; $rel printed no ENV: line"
    [ "$before" = "$after" ] || why="$why; $rel changed the checkout it ran from (commit/config/refs)"
  done
  if [ -z "$why" ]; then
    printf 'AC-2: PASS\n'
  else
    FAIL_N=$((FAIL_N + 1)); printf 'AC-2: FAIL%s\n' "${why#;}"
  fi
fi

# ---------- AC-3 ----------
if want AC-3; then
  why=""
  R="$TMP/r3"
  MARK="$TMP/ac-check-ran"
  if scratch_repo "$R" >/dev/null 2>&1; then
    BASE="$(git -C "$R" rev-parse HEAD)"
    mkdir -p "$R/tests"
    printf '#!/bin/sh\ntouch "%s"\necho "AC-1: FAIL not yet"\nexit 1\n' "$MARK" > "$R/tests/ac.sh"
    printf '# spec\n\n```json\n{"repo": "gulasz101/homelab-2nd", "base": "main", "kind": "code",\n "allowedPaths": ["src/**", "tests/**"],\n "acs": [{"id": "AC-1", "text": "a works", "check": "sh tests/ac.sh"}],\n "maxDiffLines": 400}\n```\n' > "$TMP/spec.md"
    git -C "$R" add -A && git -C "$R" commit -qm red
    RED="$(git -C "$R" rev-parse HEAD)"
    for stage in check-red check-green; do
      rm -f "$MARK"
      if [ "$stage" = check-red ]; then ref="--base"; sha="$BASE"; else ref="--red"; sha="$RED"; fi
      TMPDIR="$DEAD" python3 -I "$ROOT/agents/factory/factory.py" "$stage" \
        --repo "$R" "$ref" "$sha" --spec "$TMP/spec.md" > "$TMP/$stage.out" 2> "$TMP/$stage.err"
      rc=$?
      [ "$rc" = 2 ] || why="$why; $stage exited $rc, want 2"
      python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if any(str(r).startswith("ENV: TMPDIR") for r in d.get("reasons", [])) else 1)' \
        "$TMP/$stage.out" 2>/dev/null || why="$why; $stage gave no reason starting 'ENV: TMPDIR'"
      [ ! -e "$MARK" ] || why="$why; $stage ran the AC check"
    done
  else
    why="; scratch repo setup failed"
  fi
  if [ -z "$why" ]; then
    printf 'AC-3: PASS\n'
  else
    FAIL_N=$((FAIL_N + 1)); printf 'AC-3: FAIL%s\n' "${why#;}"
  fi
fi

[ "$FAIL_N" -eq 0 ] && exit 0 || exit 1
