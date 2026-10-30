#!/bin/bash
# ---------------------------------------------------------------------------
# claude-auth-check-test.sh — proves the GUL-641 detector can go red, go green,
# and stay honest when it cannot tell.
#
# Why this exists: the defect in GUL-641 was silence, not the login loss. A
# detector that cannot be shown to fail is the same silence with more code, so
# every branch is exercised here with a fixture instead of a live credential.
# Runs anywhere: no Claude Code, no Paperclip, no network.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../bin/homelab-lib.sh
. "$HERE/bin/homelab-lib.sh"

RC=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; RC=1; }
check() { # $1 = expected verdict, $2 = actual, $3 = label
  if [ "$1" = "$2" ]; then pass "$3 -> $2"; else fail "$3 expected '$1', got '$2'"; fi
}

FIX=$(mktemp -d "${TMPDIR:-/tmp}/claude-auth-test.XXXXXX")
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/bin" "$FIX/projects/some-project"

stub() { # $1 = name, $2 = body printed verbatim
  printf '#!/bin/sh\ncat <<%s\n%s\n%s\n' "'EOF'" "$2" 'EOF' > "$FIX/bin/$1"
  chmod +x "$FIX/bin/$1"
}

# ---- signal 1: the CLI's own JSON -----------------------------------------
stub claude-alive '{
  "loggedIn": true,
  "authMethod": "oauth",
  "analyticsDisabled": false
}'
stub claude-dead '{
  "loggedIn": false,
  "authMethod": "none",
  "analyticsDisabled": true
}'
stub claude-garbage 'not json at all'

check "alive" "alive" "cli loggedIn true"
CLAUDE_BIN="$FIX/bin/claude-alive" claude_auth_cli_state > "$FIX/v"
check "alive" "$(cat "$FIX/v")" "cli loggedIn true (function)"

CLAUDE_BIN="$FIX/bin/claude-dead" claude_auth_cli_state > "$FIX/v"
check "dead:claude-auth-status-loggedIn-false" "$(cat "$FIX/v")" \
  "cli loggedIn false even though analyticsDisabled is true"

# AC3: only an explicit true clears it. Whitespace and a stray true elsewhere
# must not be read as a login.
stub claude-minified '{"loggedIn":true}'
CLAUDE_BIN="$FIX/bin/claude-minified" claude_auth_cli_state > "$FIX/v"
check "alive" "$(cat "$FIX/v")" "cli minified json"

CLAUDE_BIN="$FIX/bin/claude-garbage" claude_auth_cli_state > "$FIX/v"
check "unknown:claude-auth-status-unparseable" "$(cat "$FIX/v")" "cli unparseable"

CLAUDE_BIN="$FIX/bin/does-not-exist" claude_auth_cli_state > "$FIX/v"
check "unknown:no-claude-binary" "$(cat "$FIX/v")" "cli missing"

# ---- signal 2: the agent row ----------------------------------------------
printf '%s' '{"id":"97efeb2d","status":"error","errorReason":"Claude run failed: subtype=success: Failed to authenticate: OAuth session expired and could not be refreshed"}' \
  | claude_agent_verdict > "$FIX/v"
check "dead:paperclip-agent-error-auth" "$(cat "$FIX/v")" "agent in auth error"

printf '%s' '{"id":"97efeb2d","status":"error","errorReason":"Claude run failed: subtype=success"}' \
  | claude_agent_verdict > "$FIX/v"
check "unknown:paperclip-agent-error-other" "$(cat "$FIX/v")" "agent in a non-auth error"

printf '%s' '{"id":"97efeb2d","status":"idle","errorReason":null,"membership":{"status":"active"},"orgChainHealth":{"status":"healthy"}}' \
  | claude_agent_verdict > "$FIX/v"
check "unknown:paperclip-agent-not-in-error" "$(cat "$FIX/v")" "agent recovered (stale error must not override)"

printf '%s' '{"error":"Unauthorized"}' | claude_agent_verdict > "$FIX/v"
check "unknown:paperclip-agent-unreadable" "$(cat "$FIX/v")" "agent api unreachable/denied"

# ---- signal 3: the session log --------------------------------------------
# A jsonl written now, carrying the synthetic assistant turn the CLI emits when
# the refresh failed.
printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"Failed to authenticate: OAuth session expired and could not be refreshed"}]}}' \
  > "$FIX/projects/some-project/failed.jsonl"
CLAUDE_PROJECTS_DIR="$FIX/projects" claude_auth_jsonl_state > "$FIX/v"
check "dead:jsonl-oauth-session-expired" "$(cat "$FIX/v")" "jsonl synthetic auth failure"

# An old failure is not evidence about now: back-date it past the 05:30 run.
if date -j -v-2d +%Y%m%d >/dev/null 2>&1; then
  OLD=$(date -j -v-2d +%Y%m%d)
else
  OLD=$(date -d '2 days ago' +%Y%m%d)
fi
touch -t "${OLD}0400" "$FIX/projects/some-project/failed.jsonl"
CLAUDE_PROJECTS_DIR="$FIX/projects" claude_auth_jsonl_state > "$FIX/v"
check "unknown:no-auth-failure-in-jsonl" "$(cat "$FIX/v")" "jsonl failure older than the last run"

mkdir -p "$FIX/empty-projects"
CLAUDE_PROJECTS_DIR="$FIX/empty-projects" claude_auth_jsonl_state > "$FIX/v"
check "unknown:no-auth-failure-in-jsonl" "$(cat "$FIX/v")" "jsonl clean"

# ---- the composite verdict -------------------------------------------------
CLAUDE_BIN="$FIX/bin/claude-alive" CLAUDE_PROJECTS_DIR="$FIX/empty-projects" \
  claude_auth_state > "$FIX/v"
check "alive" "$(cat "$FIX/v")" "verdict: readable alive wins over everything"

CLAUDE_BIN="$FIX/bin/claude-dead" CLAUDE_PROJECTS_DIR="$FIX/empty-projects" \
  claude_auth_state > "$FIX/v"
check "dead:claude-auth-status-loggedIn-false" "$(cat "$FIX/v")" "verdict: dead"

# No binary and no log: this is the HOME=/tmp/noclaude case. It must be
# unknown, never green — silence is not health.
CLAUDE_BIN="$FIX/bin/does-not-exist" CLAUDE_PROJECTS_DIR="$FIX/nope" \
  PAPERCLIP_API_KEY= claude_auth_state > "$FIX/v"
case "$(cat "$FIX/v")" in
  unknown:*) pass "verdict: no binary + no log is unknown ($(cat "$FIX/v"))" ;;
  *) fail "verdict: no binary + no log must be unknown, got '$(cat "$FIX/v")'" ;;
esac

# ---- the alert line the watchdog sends ------------------------------------
msg=$(claude_auth_alert_message "dead:claude-auth-status-loggedIn-false")
case "$msg" in
  "claude code auth dead: run claude auth login"*)
    pass "alert text starts with the required sentence" ;;
  *) fail "alert text must start with 'claude code auth dead: run claude auth login', got '$msg'" ;;
esac
case "$msg" in
  *HUMAN*|*human*) pass "alert says it is a human action" ;;
  *) fail "alert must say the fix is a human action" ;;
esac
case "$msg" in
  *"not a restart"*) pass "alert says it is not a restart" ;;
  *) fail "alert must say the fix is not a restart" ;;
esac
case "$msg" in
  *"claude login\` is not a subcommand"*) pass "alert names the wrong subcommand" ;;
  *) fail "alert must warn that 'claude login' is not a subcommand" ;;
esac

if [ "$RC" -eq 0 ]; then
  printf '\nall claude-auth checks passed\n'
else
  printf '\nclaude-auth checks FAILED\n'
fi
exit "$RC"
