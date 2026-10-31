#!/bin/bash
# ---------------------------------------------------------------------------
# claude-auth-check-test.sh — proves the Claude Code auth detector can go red,
# go green, and stay honest when it cannot tell.
#
# Why this exists: the defect in GUL-641 was silence, not the login loss. A
# detector that cannot be shown to fail is the same silence with more code, so
# every branch is exercised here with a fixture instead of a live credential.
#
# GUL-661 replaced the signal. The detector now reads the newest FINISHED run
# from the Paperclip API, because `claude auth status` reads ~/.claude, which no
# managed run ever touches. The fixtures below are the real run rows from
# 2026-10-30 (status, errorCode, error text, order) with timestamps relative to
# now, so the 26 h window stays meaningful however long this file lives.
#
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

# Fixtures. Built with python3 because the detector needs it anyway and because
# hand-written ISO timestamps would silently age out of the 26 h window.
PY=$(command -v python3 2>/dev/null) || {
  printf 'FAIL: python3 is required to build the fixtures\n'; exit 1;
}
"$PY" - "$FIX" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone

out = sys.argv[1]
now = datetime.now(timezone.utc)


def iso(hours_ago):
    return (now - timedelta(hours=hours_ago)).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def row(status, hours_ago, error_code=None, error=None, ident="00000000"):
    return {
        "id": ident, "companyId": "0e2eb054", "agentId": "97efeb2d",
        "status": status, "errorCode": error_code, "error": error,
        "startedAt": iso(hours_ago + 0.1), "finishedAt": iso(hours_ago),
        "createdAt": iso(hours_ago + 0.2), "exitCode": 0 if status == "succeeded" else 1,
    }


def running(hours_ago, ident="run-in-flight"):
    r = row("running", hours_ago, ident=ident)
    r["finishedAt"] = None
    return r


AUTH_ERROR = "Claude run failed: subtype=success: Failed to authenticate: OAuth session expired and could not be refreshed"

fixtures = {
    # The state on 2026-10-30 18:28Z: the 18:18Z PM round finished clean.
    "alive.json": [row("succeeded", 0.2, ident="377cf7f2")],
    # The 16:13Z failure, exactly as the API returned it.
    "dead.json": [row("failed", 2.3, error_code="claude_auth_required", error=AUTH_ERROR, ident="7d7f8a68")],
    # Same failure, recorded without an errorCode (older adapter rows).
    "dead-message-only.json": [row("failed", 1.0, error=AUTH_ERROR, ident="dead-message")],
    # An auth failure that is FINISHED, with the live row above it. This is the
    # de-flap case: the agent row was idle/running mid-check and the run still
    # says the credential is gone.
    "dead-behind-running.json": [running(0.05), row("failed", 0.6, error_code="claude_auth_required", error=AUTH_ERROR, ident="7d7f8a68")],
    # A live row above a clean finish is still alive.
    "alive-behind-running.json": [running(0.05), row("succeeded", 0.6, ident="377cf7f2")],
    # Only in-flight rows: nothing has finished, so nothing is proven.
    "all-running.json": [running(0.1, ident="r1"), running(0.4, ident="r2")],
    # An auth failure older than the window is not evidence about now.
    "stale-failure.json": [row("failed", 72, error_code="claude_auth_required", error=AUTH_ERROR, ident="old")],
    # A quota refusal is an answer from the provider: the credential got in.
    "failed-quota.json": [row("failed", 1.0, error_code="provider_quota", error="usage limit reached", ident="quota")],
    # A failure that says nothing about the login.
    "failed-other.json": [row("failed", 1.0, error_code="workspace_restore_failed", error="restore hook failed", ident="other")],
    # A cancelled run above an auth failure: cancelled speaks about the issue,
    # not the credential, so the alarm must survive it.
    "cancelled-above-dead.json": [row("cancelled", 0.3, error_code="issue_reassigned", ident="c1"),
                                  row("failed", 0.9, error_code="claude_auth_required", error=AUTH_ERROR, ident="7d7f8a68")],
    "all-cancelled.json": [row("cancelled", 0.3, error_code="issue_reassigned", ident="c1")],
    "empty.json": [],
}

for name, body in fixtures.items():
    with open(f"{out}/{name}", "w") as fh:
        json.dump(body, fh)

with open(f"{out}/garbage.txt", "w") as fh:
    fh.write("not json at all\n")
PY

v() { # $1 = fixture file -> verdict line
  CLAUDE_AUTH_RUNS_JSON_FILE="$1" claude_auth_state
}

# ---- the verdict from a run list ------------------------------------------
check "alive" "$(v "$FIX/alive.json")" "last finished run succeeded"

check "dead:run-claude_auth_required" "$(v "$FIX/dead.json")" \
  "the real 16:13Z failure (claude_auth_required)"
check "dead:run-auth-message" "$(v "$FIX/dead-message-only.json")" \
  "auth failure with no errorCode, matched on the message"
check "alive" "$(v "$FIX/failed-quota.json")" \
  "a quota refusal proves the credential authenticated"
check "unknown:no-informative-run" "$(v "$FIX/failed-other.json")" \
  "a failure that says nothing about the login is not a login alarm"
check "dead:run-claude_auth_required" "$(v "$FIX/cancelled-above-dead.json")" \
  "a cancelled run above an auth failure does not silence it"
check "unknown:no-informative-run" "$(v "$FIX/all-cancelled.json")" \
  "cancelled rows alone prove nothing"
check "unknown:no-finished-run" "$(v "$FIX/all-running.json")" \
  "only in-flight rows prove nothing"
check "unknown:last-finished-run-too-old" "$(v "$FIX/stale-failure.json")" \
  "an old auth failure is not evidence about now"
check "unknown:no-runs" "$(v "$FIX/empty.json")" "empty run list"
check "unknown:runs-unreadable" "$(v "$FIX/garbage.txt")" "unparseable body"

# ---- the de-flap: the live row has no vote --------------------------------
# GUL-641 was pushed off the run signal because the agent row flipped to idle
# mid-check. Here the newest row is in flight (status running, no finishedAt)
# and the finished row underneath it is an auth failure. The verdict must be
# dead, because a finished run is the only thing that proves anything.
check "dead:run-claude_auth_required" "$(v "$FIX/dead-behind-running.json")" \
  "an in-flight row above a failed run cannot turn it green"
check "alive" "$(v "$FIX/alive-behind-running.json")" \
  "an in-flight row above a clean run is still alive"

# Two ticks with the same finished failure and a live row that changes status in
# between (running -> idle). Nothing about the finished row moved, so the answer
# must not move either.
tick1=$(v "$FIX/dead-behind-running.json")
tick2=$(v "$FIX/dead.json")
check "dead:run-claude_auth_required" "$tick1" "tick 1: in-flight row above a failed run"
check "dead:run-claude_auth_required" "$tick2" "tick 2: the same failure after the row went idle"
if [ "$tick1" = "$tick2" ]; then
  pass "a mid-check status flip does not change the verdict"
else
  fail "the verdict moved with the live status: '$tick1' -> '$tick2'"
fi

# The idle flip in the other direction: the agent row said idle and the finished
# run failed, so a reader that trusted the row would have stayed silent.
case "$tick2" in
  dead:*) pass "an idle agent row cannot hide a failed finished run" ;;
  *) fail "a failed finished run must stay dead, got '$tick2'" ;;
esac

# ---- the dead signals stay dead -------------------------------------------
# `claude auth status` reads ~/.claude, which no managed run uses; the agent row
# mixes a live status with a sticky errorReason. Neither may come back as a
# detector: if one of them exists again, someone has re-wired the false alarm.
for gone in claude_auth_cli_state claude_agent_verdict claude_auth_jsonl_state; do
  if declare -F "$gone" >/dev/null 2>&1; then
    fail "$gone still exists: the GUL-641 signal that reads the wrong login"
  else
    pass "$gone is gone"
  fi
done

# ---- no key is unknown, never green ---------------------------------------
mkdir -p "$FIX/nohome"
check "unknown:no-paperclip-key" \
  "$(CLAUDE_AUTH_RUNS_JSON_FILE= HERMES_HOME="$FIX/nohome" PAPERCLIP_API_KEY= claude_auth_state)" \
  "no API key is unknown, not alive"

# ---- the alert line the watchdog sends ------------------------------------
# Unchanged from GUL-641: the fix is a human login, not a restart.
msg=$(claude_auth_alert_message "dead:run-claude_auth_required")
case "$msg" in
  "claude code auth dead: run claude auth login"*)
    pass "alert text starts with the required sentence" ;;
  *) fail "alert text must start with 'claude code auth dead: run claude auth login', got '$msg'" ;;
esac
case "$msg" in
  *"run-claude_auth_required"*) pass "alert names the reason" ;;
  *) fail "alert must name the reason" ;;
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
