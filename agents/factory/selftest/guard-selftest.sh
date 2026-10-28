#!/usr/bin/env bash
# factory-guard daily self-test (GUL-437, ADR-093 decision 4).
#
# Zero model, zero tokens: git + bash + the scripted pi provider only.
#
# What it checks, in order:
#   1. the INSTALLED guard copy's role matrix:
#        bash "$FACTORY_GUARD_DIR/tests/guard-check.sh"   (all four roles)
#      A live-test SKIP is a failure — on this machine pi exists, and a
#      skipped matrix proves nothing.
#   2. drift: the installed guard copy must be byte-identical to
#      agents/factory-guard/ on origin/main (node_modules and .DS_Store
#      ignored). Drift is a failure; the fix is to re-copy (GUL-311 recipe),
#      not to edit the installed copy.
#   3. drift: the INSTALLED ENTRY SCRIPT (what launchd actually runs) must be
#      byte-identical to agents/factory/selftest/guard-selftest.sh on
#      origin/main. The entry lives outside the shared checkout on purpose: a
#      repo-path entry disappears whenever a concurrent run parks the checkout
#      on a branch without it, and launchd then fails in silence (proved by
#      GUL-437's first kickstart after merge #65).
#   4. drift: the INSTALLED PLIST in ~/Library/LaunchAgents must be
#      byte-identical to the repo one — what launchd loaded must be what Git
#      says is scheduled.
#
# On any failure it writes $FACTORY_STATE_DIR/STOP (time, role, failing
# assertion — never command text) and exits 1. It NEVER deletes or overwrites an
# existing STOP: only a person clears it, after the fix. The wiring issue makes
# `factory start` and `factory decide` refuse while STOP exists.
#
# One line per run is appended to $FACTORY_STATE_DIR/selftest.log.
#
# Env overrides (used by tests):
#   FACTORY_GUARD_DIR   installed guard dir   (default ~/paperclip-agents/pi/extensions/factory-guard)
#   FACTORY_ENTRY_DIR   installed entry dir   (default ~/paperclip-agents/factory-selftest)
#   FACTORY_PLIST_PATH  installed plist       (default ~/Library/LaunchAgents/dev.voitech.factory-guard-selftest.plist)
#   FACTORY_STATE_DIR   STOP/log dir          (default ~/paperclip-agents/majster/factory)
#   FACTORY_REPO_DIR    homelab-2nd checkout  (default ~/Projects/homelab-2nd)
#   FACTORY_SELFTEST_REEXEC=1  run this exact copy (skip the origin/main re-exec; negative tests use it)
#
# bash 3.2 (macOS system bash) — no arrays, no [[ ]], no bash-4-isms.
set -u

# launchd hands us a PATH without homebrew: pi, node and git live there.
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH

FACTORY_GUARD_DIR="${FACTORY_GUARD_DIR:-$HOME/paperclip-agents/pi/extensions/factory-guard}"
FACTORY_STATE_DIR="${FACTORY_STATE_DIR:-$HOME/paperclip-agents/majster/factory}"
FACTORY_REPO_DIR="${FACTORY_REPO_DIR:-$HOME/Projects/homelab-2nd}"
STOP="$FACTORY_STATE_DIR/STOP"
LOG="$FACTORY_STATE_DIR/selftest.log"
NOW="$(date +%Y-%m-%dT%H:%M:%S%z)"

mkdir -p "$FACTORY_STATE_DIR" || { echo "guard-selftest: cannot create $FACTORY_STATE_DIR" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/factory-selftest-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- run the ORIGIN/MAIN copy of this script ---
# The shared checkout is branch-switched by concurrent agent runs at all hours:
# whatever sits at the repo path at 04:45 may be older or newer than main. The
# fetch is best-effort (ConnectTimeout so an offline 04:45 cannot hang launchd);
# if the fetch fails the drift check compares against the last-known origin/main.
if [ -z "${FACTORY_SELFTEST_REEXEC:-}" ]; then
  GIT_SSH_COMMAND="ssh -o ConnectTimeout=10" git -C "$FACTORY_REPO_DIR" fetch -q origin main >/dev/null 2>&1 || true
  export FACTORY_SELFTEST_FETCHED=1
  mkdir -p "$WORK/extract"
  if git -C "$FACTORY_REPO_DIR" archive origin/main agents/factory/selftest/guard-selftest.sh 2>/dev/null \
      | tar -x -C "$WORK/extract" 2>/dev/null \
     && [ -s "$WORK/extract/agents/factory/selftest/guard-selftest.sh" ]; then
    export FACTORY_SELFTEST_REEXEC=1 FACTORY_SELFTEST_SRC=main
    exec /bin/bash "$WORK/extract/agents/factory/selftest/guard-selftest.sh" "$@"
  fi
  # no usable origin/main copy (fresh clone, offline + no ref, or override test):
  # run the copy at hand and say so in the log (src=local).
fi
FACTORY_SELFTEST_SRC="${FACTORY_SELFTEST_SRC:-local}"

FIRST_FAIL_ROLE=""
FIRST_FAIL_TEXT=""
DETAIL=""

add_failure() { # $1=role $2=assertion (no command text)
  [ -n "$FIRST_FAIL_ROLE" ] || { FIRST_FAIL_ROLE="$1"; FIRST_FAIL_TEXT="$2"; }
  if [ -n "$DETAIL" ]; then DETAIL="$DETAIL; $1: $2"; else DETAIL="$1: $2"; fi
}

# ---------- check 1: role matrix of the installed copy ----------
GUARD_CHECK="$FACTORY_GUARD_DIR/tests/guard-check.sh"
ROLES_LINE="none"
if [ ! -f "$GUARD_CHECK" ]; then
  add_failure install "installed guard-check.sh missing at $GUARD_CHECK"
else
  OUT="$WORK/guard-check.out"; ERRF="$WORK/guard-check.err"
  bash "$GUARD_CHECK" > "$OUT" 2> "$ERRF"
  GC_RC=$?
  # keep the last full output for post-mortems (fixture content only, no secrets)
  cp "$OUT" "$FACTORY_STATE_DIR/last-guard-check.out" 2>/dev/null || true
  MATRIX=$(grep -m1 '^-- matrix:' "$OUT" | sed 's/^-- matrix: *//')
  [ -n "$MATRIX" ] && ROLES_LINE="$MATRIX"
  if grep -q 'SKIP live: pi not installed' "$OUT"; then
    add_failure all "live tests skipped: pi not installed on this machine"
  elif echo "$ROLES_LINE" | grep -q '=FAIL'; then
    FF=$(grep -m1 'FAIL \[' "$OUT" | sed 's/^ *//')
    FR=$(echo "$FF" | sed -n 's/^FAIL \[\([^]]*\)\].*/\1/p')
    add_failure "${FR:-matrix}" "${FF:-role matrix failed (exit $GC_RC)}"
  elif [ $GC_RC -ne 0 ]; then
    FF=$(grep -m1 'FAIL' "$OUT" | sed 's/^ *//')
    add_failure guard-check "${FF:-guard-check exit $GC_RC without any FAIL line — live run died?}"
  fi
  # exit 0 but no matrix line and pi present: the matrix never ran. Fail closed.
  if [ $GC_RC -eq 0 ] && [ -z "$MATRIX" ] && ! grep -q 'SKIP live' "$OUT"; then
    add_failure guard-check "exit 0 without running the role matrix"
  fi
fi

# ---------- check 2: drift against origin/main ----------
# fetch already attempted above (or by the outer copy before re-exec — the
# exported FACTORY_SELFTEST_FETCHED proves it); never fetch twice per run.
if [ -z "${FACTORY_SELFTEST_FETCHED:-}" ]; then
  GIT_SSH_COMMAND="ssh -o ConnectTimeout=10" git -C "$FACTORY_REPO_DIR" fetch -q origin main >/dev/null 2>&1 || true
  export FACTORY_SELFTEST_FETCHED=1
fi
mkdir -p "$WORK/ref"
if git -C "$FACTORY_REPO_DIR" archive origin/main agents/factory-guard 2>/dev/null | tar -x -C "$WORK/ref" 2>/dev/null \
   && [ -d "$WORK/ref/agents/factory-guard" ]; then
  DIFFOUT="$WORK/drift.txt"
  diff -r --exclude node_modules --exclude .DS_Store "$WORK/ref/agents/factory-guard" "$FACTORY_GUARD_DIR" > "$DIFFOUT" 2>&1
  if [ -s "$DIFFOUT" ]; then
    FILES=$(sed -n '1,5p' "$DIFFOUT" | tr '\n' ';')
    add_failure install "installed copy differs from origin/main — re-copy agents/factory-guard/ from origin/main to $FACTORY_GUARD_DIR (GUL-311 recipe): ${FILES:0:400}"
  fi
else
  add_failure install "cannot extract agents/factory-guard from origin/main of $FACTORY_REPO_DIR (no repo, no ref, offline?)"
fi

# ---------- checks 3+4: the installed entry script and plist ----------
# launchd runs the installed entry, and the schedule/PATH that fires is the
# installed plist — so both are drift-checked against origin/main like the
# guard. Extracted once; missing files count as drift (diff says so).
mkdir -p "$WORK/selftest-ref"
if git -C "$FACTORY_REPO_DIR" archive origin/main agents/factory/selftest 2>/dev/null | tar -x -C "$WORK/selftest-ref" 2>/dev/null \
   && [ -f "$WORK/selftest-ref/agents/factory/selftest/guard-selftest.sh" ]; then
  ENTRY_DIR="${FACTORY_ENTRY_DIR:-$HOME/paperclip-agents/factory-selftest}"
  DIFF3="$WORK/entry-diff.txt"
  diff -q "$WORK/selftest-ref/agents/factory/selftest/guard-selftest.sh" "$ENTRY_DIR/guard-selftest.sh" > "$DIFF3" 2>&1
  if [ -s "$DIFF3" ]; then
    D3=$(head -c 200 "$DIFF3" | tr '\n' ';')
    add_failure install "installed self-test entry differs from origin/main — re-copy agents/factory/selftest/guard-selftest.sh from origin/main to $ENTRY_DIR/ (README has the commands): $D3"
  fi
  PLIST_LIVE="${FACTORY_PLIST_PATH:-$HOME/Library/LaunchAgents/dev.voitech.factory-guard-selftest.plist}"
  DIFF4="$WORK/plist-diff.txt"
  diff -q "$WORK/selftest-ref/agents/factory/selftest/dev.voitech.factory-guard-selftest.plist" "$PLIST_LIVE" > "$DIFF4" 2>&1
  if [ -s "$DIFF4" ]; then
    D4=$(head -c 200 "$DIFF4" | tr '\n' ';')
    add_failure install "installed launchd plist differs from origin/main — reinstall it from origin/main to $PLIST_LIVE and reload the job (README has the commands): $D4"
  fi
else
  add_failure install "cannot extract agents/factory/selftest from origin/main of $FACTORY_REPO_DIR (no repo, no ref, offline?)"
fi

# ---------- STOP + log ----------
if [ -n "$FIRST_FAIL_ROLE" ]; then
  RESULT=FAIL
  if [ -e "$STOP" ]; then
    STOP_NOTE="already-present"
  else
    # strip double quotes so STOP/log stay single-line and shell-safe
    ASSERT=$(echo "$FIRST_FAIL_TEXT" | tr '"' "'")
    printf '%s\n' \
      "factory-guard self-test FAILED — the factory must not start or decide until a person clears this file after the fix." \
      "time=$NOW" \
      "role=$FIRST_FAIL_ROLE" \
      "assertion=$ASSERT" > "$STOP" 2>/dev/null && STOP_NOTE="written" || STOP_NOTE="WRITE-FAILED"
  fi
  SAFEDETAIL=$(echo "$DETAIL" | tr '"' "'")
  printf '%s RESULT=FAIL SRC=%s ROLES="%s" FAILURE="%s" STOP=%s\n' \
    "$NOW" "$FACTORY_SELFTEST_SRC" "$ROLES_LINE" "${SAFEDETAIL:0:500}" "$STOP_NOTE" >> "$LOG"
  echo "guard-selftest: FAIL — $DETAIL" >&2
  echo "guard-selftest: STOP is at $STOP (never removed by this script)" >&2
  exit 1
fi

printf '%s RESULT=PASS SRC=%s ROLES="%s" STOP=%s\n' \
  "$NOW" "$FACTORY_SELFTEST_SRC" "$ROLES_LINE" "$([ -e "$STOP" ] && echo present || echo absent)" >> "$LOG"
echo "guard-selftest: PASS (roles: $ROLES_LINE)"
