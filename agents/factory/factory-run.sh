#!/bin/sh
# factory — run agents/factory/factory.py from a checkout of main (GUL-502, ADR-096).
#
# The stage checks are code, and the factory must run the code on main. The
# work order's checkout (`ledger.cwd`) stays on `gul-<N>-<slug>`, because every
# check diffs against that working tree; the script never lives there.
#
# So: the tooling checkout below is force-moved to `origin/main` before every
# call, and the script it contains is executed. A commit merged to main is the
# code that decides the next stage, with no pull and no restart.
#
# A refresh that fails is a setup error (exit 2). Running a stale copy silently
# is the bug this wrapper exists to remove (GUL-502: every stage decision after
# a stage commit ended in a 409 from a client frozen at the spec's base).
#
# stdout belongs to factory.py: exactly one JSON line. Everything here is stderr.
set -eu

TOOLING=${FACTORY_TOOLING:-/Users/paperclip/factory/tooling}
REMOTE_REF='+refs/heads/main:refs/remotes/origin/main'
CLONE_URL=${FACTORY_TOOLING_URL:-https://github.com/gulasz101/homelab-2nd.git}

fail() {
    printf 'factory: %s\n' "$*" >&2
    exit 2
}

[ -d "$TOOLING/.git" ] || fail "no tooling checkout at $TOOLING — create it once:
  git clone $CLONE_URL $TOOLING"

dirty=$(git -C "$TOOLING" status --porcelain --untracked-files=no) \
    || fail "git status failed in $TOOLING"
[ -z "$dirty" ] || fail "tooling checkout $TOOLING has local changes to tracked
files; it must stay a throwaway copy of main. Move them out with:
  git -C $TOOLING diff
$dirty"

git -C "$TOOLING" fetch --quiet --prune origin "$REMOTE_REF" \
    || fail "cannot fetch origin/main into $TOOLING — refusing to run a stale copy"

git -C "$TOOLING" -c advice.detachedHead=false checkout --quiet --detach \
    refs/remotes/origin/main || fail "cannot move $TOOLING to origin/main"

printf 'factory: tooling %s (%s)\n' \
    "$(git -C "$TOOLING" rev-parse --short=12 HEAD)" "$TOOLING" >&2

exec python3 -I "$TOOLING/agents/factory/factory.py" "$@"
