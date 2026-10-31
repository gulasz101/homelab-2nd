#!/bin/bash
# ---------------------------------------------------------------------------
# homelab-lib.sh — the single place that knows what the Air runs (H2-336).
#
# Sourced by the other scripts in this tree, never executed directly. Written
# for bash 3.2 (the Air's /bin/bash) and for Linux, because CI reads these
# files too: no associative arrays, no mapfile, no ${var,,}.
#
# ADR-098 is the contract this file encodes: the five headless services live in
# the system launchd domain under dev.voitech.homelab.<service>, and the
# heartbeat sender is the only user agent we own on purpose.
# ---------------------------------------------------------------------------

HOMELAB_DOMAIN="dev.voitech.homelab"
HOMELAB_USER="paperclip"
HOMELAB_HOME="/Users/paperclip"
HOMELAB_STATE_DIR="$HOMELAB_HOME/.config/homelab"
HOMELAB_SERVICES_ENV="$HOMELAB_STATE_DIR/services.env"
HOMELAB_HEARTBEAT_ENV="$HOMELAB_STATE_DIR/heartbeat.env"
HOMELAB_HEARTBEAT_TOKEN_FILE="$HOMELAB_STATE_DIR/heartbeat-token"
HOMELAB_LOG_DIR="$HOMELAB_HOME/Library/Logs/homelab"
HOMELAB_DRILL_LOG="$HOMELAB_LOG_DIR/drills.jsonl"
HOMELAB_LIBEXEC="/usr/local/libexec/homelab"
HOMELAB_DAEMON_DIR="/Library/LaunchDaemons"
HOMELAB_AGENT_DIR="$HOMELAB_HOME/Library/LaunchAgents"
# Port the k3s host-watch receiver publishes for heartbeat ingest. LAN/Netbird
# only (NodePort), never through Cloudflare: the ingest path carries a token but
# it has no business being on the public internet.
HOMELAB_HEARTBEAT_URL_DEFAULT="http://192.168.1.179:30270/heartbeat"

# The five headless services, in start order. Keep this list and the plists in
# launchd/daemons/ in step: tests/host-tree-check.sh fails otherwise.
HOMELAB_SERVICES="hermes-gateway paperclip minio-lan-proxy gemini-tunnel syncthing"

svc_label() { printf '%s.%s' "$HOMELAB_DOMAIN" "$1"; }

# The variable that carries the service's command line inside services.env.
svc_var() { printf 'SVC_%s_CMD' "$(printf '%s' "$1" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"; }

svc_port() {
  case "$1" in
    hermes-gateway)  echo 8642 ;;
    paperclip)       echo 3100 ;;
    minio-lan-proxy) echo 9000 ;;
    gemini-tunnel)   echo 8083 ;;
    syncthing)       echo 8384 ;;
    *) return 1 ;;
  esac
}

# Path probed for a liveness answer. gemini-tunnel is an ssh port-forward, so a
# TCP connect is the only honest check (http there would reach the far end).
svc_health_path() {
  case "$1" in
    hermes-gateway)  echo "/v1/models" ;;
    paperclip)       echo "/" ;;
    minio-lan-proxy) echo "/minio/health/live" ;;
    gemini-tunnel)   echo "" ;;
    syncthing)       echo "/rest/noauth/health" ;;
  esac
}

# launchd restarts a crashed job no faster than this. The gateway and Paperclip
# both run migrations / drain on start, so they get a longer leash.
svc_throttle() {
  case "$1" in
    hermes-gateway|paperclip) echo 30 ;;
    *) echo 10 ;;
  esac
}

# Recovery-time objective per service, seconds. These are *targets*: the
# measured numbers live in RUNBOOK.md and are only filled in by a drill.
svc_rto() {
  case "$1" in
    hermes-gateway)  echo 90 ;;
    paperclip)       echo 120 ;;
    minio-lan-proxy) echo 30 ;;
    gemini-tunnel)   echo 30 ;;
    syncthing)       echo 30 ;;
  esac
}

now_s() { date +%s; }
now_h() { date '+%Y-%m-%d %H:%M:%S'; }

# TCP connect test that works on macOS (nc) and Linux (bash /dev/tcp).
port_open() {
  local port="$1"
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$port" >/dev/null 2>&1
    return $?
  fi
  (exec 3<>"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1
}

# "Is the service serving?" — port open, and for HTTP services any answer below
# 500 counts. A 401/403 means the process is alive and guarding, which is up,
# not down; treating auth as failure is how probes lie.
svc_up() {
  local svc="$1" port path code
  port=$(svc_port "$svc") || return 1
  port_open "$port" || return 1
  path=$(svc_health_path "$svc")
  [ -z "$path" ] && return 0
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$port$path" 2>/dev/null || echo 000)
  case "$code" in
    000|5??) return 1 ;;
    *) return 0 ;;
  esac
}

# Seconds until the service is up again, or "" on timeout. Polls every second:
# a 1 s granularity is honest for RTO numbers measured by hand.
wait_up() {
  local svc="$1" timeout="${2:-180}" start elapsed
  start=$(now_s)
  while :; do
    elapsed=$(( $(now_s) - start ))
    svc_up "$svc" && { echo "$elapsed"; return 0; }
    [ "$elapsed" -ge "$timeout" ] && { echo ""; return 1; }
    sleep 1
  done
}

# Wait until the port is genuinely free, or the timeout expires.
#
# Needed by every "kill it, time the restart" measurement: a process that has
# just been SIGKILLed keeps its listening socket accepting for a moment while the
# kernel finishes with it, so a timer started at the kill can record 0 s - a
# number that looks like a perfect result and measures nothing. Time from the
# closed port, not from the signal.
wait_closed() { # $1 = port, $2 = timeout (default 15)
  local port="$1" timeout="${2:-15}" i=0
  while [ "$i" -lt "$timeout" ]; do
    port_open "$port" || return 0
    sleep 1; i=$((i + 1))
  done
  return 1
}

require_darwin() {
  if [ "$(uname -s)" != "Darwin" ]; then
    printf 'this action only runs on the Mac (%s here); use --dry-run to see the plan\n' "$(uname -s)" >&2
    return 1
  fi
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    printf 'this action needs root (it writes %s and drives the system launchd domain)\n' "$HOMELAB_DAEMON_DIR" >&2
    return 1
  fi
}

# True (0) when this very process is running inside the service it is about to
# act on. Killing that service then kills the caller, and whatever the caller
# was doing is lost. On 2026-10-30 an agent run measured `--kill paperclip`
# from inside a Paperclip heartbeat: it killed the server hosting it and took
# two other agents' runs down with it. A drill that dies before it writes its
# own result has measured nothing.
caller_hosted_by() { # $1 = service name
  local svc="${1:-}" pid cmd pattern=""
  [ -n "$svc" ] || return 1
  case "$svc" in
    paperclip)
      # A Paperclip heartbeat always carries at least one of these.
      if [ -n "${PAPERCLIP_RUN_ID:-}${PAPERCLIP_TASK_ID:-}${PAPERCLIP_AGENT_ID:-}" ]; then
        return 0
      fi
      pattern='paperclipai'
      ;;
    hermes-gateway) pattern='gateway run' ;;
    *) return 1 ;;
  esac
  pid=$$
  while :; do
    case "${pid:-}" in ''|*[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] || return 1
    cmd=$(ps -o command= -p "$pid" 2>/dev/null) || return 1
    case "$cmd" in *"$pattern"*) return 0 ;; esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
}

appliance_uid() { id -u "$HOMELAB_USER" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Claude Code auth (GUL-641, corrected by GUL-661). On 2026-10-30 the Claude
# Code PM agent lost its login at 05:30 and nobody was told for nine hours: the
# agent sat in `error` while its ticket stayed parked. The silence was the
# defect; the login was the symptom.
#
# GUL-641 watched `claude auth status` for it, and that was wrong. A managed run
# never touches ~/.claude: the server builds a throwaway home per run
# ($TMPDIR/paperclip-ai-<company>-<grant>-), points CLAUDE_CONFIG_DIR at its
# `provider/` subdirectory, blanks every inherited auth env var, and hands
# Claude the token from the Paperclip AI connection in the child environment
# (CLAUDE_CODE_OAUTH_TOKEN, or ANTHROPIC_API_KEY for an API-key connection).
# The stub in ~/.claude answered `loggedIn: false` for a day while every run
# authenticated fine. That is not a weak signal, it is a signal about a
# different login.
#
# The agent row is no better. `status` is live-only, so it flips to idle
# mid-check, and `errorReason` is sticky: at 18:2xZ it still carried the 16:13Z
# auth failure while the 18:18Z run was healthy. Reading either one, or both,
# pages forever.
#
# What is faithful is the run row. The process that actually failed records
# status, errorCode, error and finishedAt, so the check reads the newest
# FINISHED run for the agent and nothing else. An in-flight row is skipped, so a
# live status flip has no vote at all.
#
# Returns one line, never a secret:
#   alive                 the last finished run succeeded
#   dead:<reason>         the last finished run failed on authentication
#   unknown:<reason>      cannot tell: no key, API unreachable, no finished run
#                         in the window, or the last run failed for another
#                         reason
#
# Only a positive auth failure is `dead` and only `succeeded` is `alive`.
# Everything else is `unknown`: logged, never paged. A watchdog that cries wolf
# gets ignored inside a week, and then the real outage looks like the noise.
CLAUDE_AGENT_ID="${CLAUDE_AGENT_ID:-97efeb2d-5b3a-4110-b893-6cbcbb29164c}"
CLAUDE_COMPANY_ID="${CLAUDE_COMPANY_ID:-0e2eb054-4cb6-4ea1-a2e7-2b1894285d8c}"
# 26 h: the daily PM round fires at 05:30, so a finished run older than that
# means nobody has tried the credential since, and that is not evidence either
# way. A window beats "the newest row whatever its age" because a fixed login
# with no runs after it would otherwise page for days.
CLAUDE_RUN_WINDOW_HOURS="${CLAUDE_RUN_WINDOW_HOURS:-26}"
CLAUDE_RUN_LIMIT="${CLAUDE_RUN_LIMIT:-20}"

# The key the daemon can see. The LaunchDaemon sets HERMES_HOME, not the key
# itself, so the profile .env is the source. Read, never printed.
claude_paperclip_key() {
  local key="${PAPERCLIP_API_KEY:-}" env_file
  if [ -z "$key" ]; then
    env_file="${HERMES_HOME:-$HOMELAB_HOME/.hermes}/.env"
    if [ -r "$env_file" ]; then
      key=$(. "$env_file" >/dev/null 2>&1; printf '%s' "${PAPERCLIP_API_KEY:-}")
    fi
  fi
  printf '%s' "$key"
}

# Raw run rows for the agent, newest first. CLAUDE_AUTH_RUNS_JSON_FILE replays a
# recorded body instead of the network, which is how the test suite proves every
# branch with no server and no key.
claude_auth_runs_json() {
  local key url body
  if [ -n "${CLAUDE_AUTH_RUNS_JSON_FILE:-}" ]; then
    cat "$CLAUDE_AUTH_RUNS_JSON_FILE"
    return 0
  fi
  key=$(claude_paperclip_key)
  [ -n "$key" ] || { echo "unknown:no-paperclip-key"; return 0; }
  url="${PAPERCLIP_API_URL:-http://127.0.0.1:3100}"
  case "$url" in */api) : ;; *) url="$url/api" ;; esac
  body=$(curl -s -m 10 -H "Authorization: Bearer $key" \
    "$url/companies/$CLAUDE_COMPANY_ID/heartbeat-runs?agentId=$CLAUDE_AGENT_ID&limit=${CLAUDE_RUN_LIMIT}" 2>/dev/null) || true
  [ -n "$body" ] || { echo "unknown:paperclip-api-unreachable"; return 0; }
  printf '%s' "$body"
}

# The verdict for a run list, separated from the fetch so a recorded body can be
# replayed. Reads the JSON array on stdin.
claude_runs_verdict() {
  local py src
  py=$(command -v python3 2>/dev/null) || { cat >/dev/null; echo "unknown:no-python3"; return 0; }
  # The program goes in -c, so stdin stays free for the JSON body.
  src=$(cat <<'PY'
import json, sys
from datetime import datetime, timezone

# The Claude adapter emits claude_auth_required on the CLI lane and translates
# the shared acpx code into it on the ACP lane; adapter_auth_missing comes from
# the sandbox login probe. All three mean "sign in again".
AUTH_CODES = {"claude_auth_required", "acpx_auth_required", "adapter_auth_missing"}
AUTH_PHRASES = ("failed to authenticate", "oauth session expired", "sign-in failed")


def stamp(row):
    ts = row.get("finishedAt")
    if not isinstance(ts, str) or not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


try:
    window_h = float(sys.argv[1]) if len(sys.argv) > 1 else 26.0
except ValueError:
    window_h = 26.0

try:
    runs = json.load(sys.stdin)
except Exception:
    print("unknown:runs-unreadable")
    raise SystemExit(0)

if not isinstance(runs, list) or not runs:
    print("unknown:no-runs")
    raise SystemExit(0)

finished = [r for r in runs if isinstance(r, dict) and stamp(r)]
if not finished:
    # Only in-flight or queued rows: nothing has finished, so nothing is proven.
    print("unknown:no-finished-run")
    raise SystemExit(0)


def classify(row):
    """One finished row -> verdict, or None when it says nothing about the login."""
    status = str(row.get("status") or "")
    code = str(row.get("errorCode") or "").strip()
    message = str(row.get("error") or "").strip().lower()
    if status == "succeeded":
        return "alive"
    if status != "failed":
        # cancelled / timed_out / killed: the row speaks about the issue or the
        # host, not about whether the credential works.
        return None
    if code.lower() in AUTH_CODES or any(p in message for p in AUTH_PHRASES):
        return "dead:run-%s" % (code or "auth-message")
    if code.lower() == "provider_quota" or "quota" in message or "usage limit" in message:
        # A quota refusal is an answer from the provider: the credential
        # authenticated and only the allowance ran out. Not a login alarm.
        return "alive"
    return None


# Newest finished row that actually says something. A cancelled run above an
# auth failure must not silence the alarm, and an in-flight row never votes.
verdict = None
for row in sorted(finished, key=stamp, reverse=True):
    verdict = classify(row)
    if verdict is not None:
        break
if verdict is None:
    print("unknown:no-informative-run")
    raise SystemExit(0)

age_h = (datetime.now(timezone.utc) - stamp(row)).total_seconds() / 3600.0
if age_h > window_h:
    print("unknown:last-finished-run-too-old")
    raise SystemExit(0)

print(verdict)
PY
)
  "$py" -c "$src" "${CLAUDE_RUN_WINDOW_HOURS}"
}

# The verdict the callers act on.
claude_auth_state() {
  local raw
  raw=$(claude_auth_runs_json)
  case "$raw" in
    unknown:*) printf '%s\n' "$raw" ;;
    *) printf '%s' "$raw" | claude_runs_verdict ;;
  esac
}

# One place for the words, so the hourly daemon and a hand-run of the legacy
# watchdog cannot drift apart. The first sentence is fixed by GUL-641 AC2; the
# rest exists because "restart it" is the wrong instinct here and the wrong
# subcommand (`claude login`) is the other one.
claude_auth_alert_message() { # $1 = verdict, e.g. dead:run-claude_auth_required
  printf 'claude code auth dead: run claude auth login (%s). HUMAN action, not a restart - no daemon kickstart, no agent restart and no reboot will refresh an expired OAuth session. Use `claude auth login`, or /login in an interactive session; `claude login` is not a subcommand.' "${1#dead:}"
}

# One-line summary of who owns the console. Trust this, never `who` — a logged
# out Mac keeps a stale console entry in utmp, which cost us an hour on
# 2026-10-29.
console_owner() { stat -f%Su /dev/console 2>/dev/null || echo unknown; }
