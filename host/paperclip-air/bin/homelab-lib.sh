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
# Claude Code auth (GUL-641). On 2026-10-30 the Claude Code PM agent lost its
# login at 05:30 — OAuth refresh rejected, ~/.claude/.credentials.json blanked
# — and nobody was told for nine hours. The agent sat in `error` while its
# ticket stayed parked. The silence was the defect; the login was the symptom.
#
# Three ways to see it, all without a browser, in this order:
#   1. `claude auth status` says "loggedIn": false   <- primary: local, cheap,
#      no API key, and it is the same JSON the CLI itself trusts.
#   2. the Paperclip agent row is in `error` with errorReason containing
#      "OAuth session expired" / "Failed to authenticate"  <- needs the key in
#      $HERMES_HOME/.env, so it is only a fallback.
#   3. the newest session jsonl written since the last 05:30 run carries an
#      assistant message with model "<synthetic>" and "Failed to authenticate"
#      <- last resort: it only proves a failure *happened*, never that it was
#      fixed, so it is never allowed to overrule a readable status 1.
#
# Returns one line, never a secret:
#   alive                 loggedIn is true, and only that
#   dead:<reason>         certainly logged out
#   unknown:<reason>      cannot tell (missing binary, unparseable output)
#
# AC3 of GUL-641: a bare `claude auth login` prompt attempt must NOT clear
# this. It cannot: the verdict is re-read from the JSON on every call and only
# an explicit true is alive. There is no cached "was alerted" state here.
# Defaults only: the variables themselves are read at call time, so a caller
# (the daemon, a drill, a test) can override any of them per invocation. An
# explicit CLAUDE_BIN always wins, including when it points at nothing.
#
# They anchor on HOMELAB_HOME (the appliance user), NOT on $HOME: this check
# must describe paperclip's Claude Code login, and a daemon started with a
# different HOME — `sudo` gives one /var/root — must not silently measure
# somebody else's. Anyone who wants to isolate the check overrides CLAUDE_BIN
# or CLAUDE_PROJECTS_DIR explicitly.
CLAUDE_BIN_DEFAULT="${CLAUDE_BIN_DEFAULT:-$HOMELAB_HOME/.local/bin/claude}"
CLAUDE_PROJECTS_DEFAULT="${CLAUDE_PROJECTS_DEFAULT:-$HOMELAB_HOME/.claude/projects}"
CLAUDE_AGENT_ID="${CLAUDE_AGENT_ID:-97efeb2d-5b3a-4110-b893-6cbcbb29164c}"

# The most recent 05:30 in local time, as a `touch -t` stamp (YYYYMMDDhhmm).
# The daily PM run fires at 05:30, so anything written before it belongs to
# yesterday's story. Stays portable: BSD date on the Air, GNU date in CI.
claude_since_stamp() {
  local hh mm today yest
  hh=$(date +%H); mm=$(date +%M)
  today=$(date +%Y%m%d)
  yest=$(date -j -v-1d +%Y%m%d 2>/dev/null) || yest=$(date -d 'yesterday' +%Y%m%d 2>/dev/null) \
    || yest=$(date -r $(( $(date +%s) - 86400 )) +%Y%m%d 2>/dev/null) || yest="$today"
  if [ "$hh" -gt 5 ] || { [ "$hh" -eq 5 ] && [ "$mm" -ge 30 ]; }; then
    printf '%s0530' "$today"
  else
    printf '%s0530' "$yest"
  fi
}

# Signal 1 only. Prints the raw verdict word, so callers can compose.
claude_auth_cli_state() {
  local bin out compact
  bin="${CLAUDE_BIN:-$CLAUDE_BIN_DEFAULT}"
  # PATH is only a fallback for the *default* path going missing (a moved
  # install). An explicit CLAUDE_BIN is authoritative, even when it points at
  # nothing - otherwise the HOME=/tmp/noclaude proof would quietly answer using
  # the real binary.
  if [ "$bin" = "$CLAUDE_BIN_DEFAULT" ] && [ ! -x "$bin" ]; then
    bin=$(command -v claude 2>/dev/null) || true
  fi
  [ -n "${bin:-}" ] && [ -x "$bin" ] || { echo "unknown:no-claude-binary"; return 0; }
  # `auth status` prints JSON on stdout and exits 1 when logged out. The exit
  # code is deliberately NOT the signal: a broken install exits non-zero too,
  # and "the CLI is sick" must not read as "the login is dead".
  out=$("$bin" auth status 2>/dev/null) || true
  # Whitespace comes out of pretty-printed JSON, so collapse it and match the
  # exact pair. A loose "*true*" match would read "analyticsDisabled": true as
  # a login — the one false alarm that would teach everyone to ignore this.
  compact=$(printf '%s' "$out" | tr -d ' \t\n\r')
  case "$compact" in
    *'"loggedIn":true'*)  echo "alive"; return 0 ;;
    *'"loggedIn":false'*) echo "dead:claude-auth-status-loggedIn-false"; return 0 ;;
  esac
  echo "unknown:claude-auth-status-unparseable"
}

# Signal 2. Corroboration only; needs PAPERCLIP_API_KEY in the environment.
claude_auth_agent_state() {
  local url key body
  url="${PAPERCLIP_API_URL:-http://127.0.0.1:3100}"
  case "$url" in */api) : ;; *) url="$url/api" ;; esac
  key="${PAPERCLIP_API_KEY:-}"
  if [ -z "$key" ] && [ -r "${HERMES_HOME:-$HOMELAB_HOME/.hermes}/.env" ]; then
    key=$(. "${HERMES_HOME:-$HOMELAB_HOME/.hermes}/.env" >/dev/null 2>&1; printf '%s' "${PAPERCLIP_API_KEY:-}")
  fi
  [ -n "$key" ] || { echo "unknown:no-paperclip-key"; return 0; }
  body=$(curl -s -m 8 -H "Authorization: Bearer $key" "$url/agents/$CLAUDE_AGENT_ID" 2>/dev/null) || true
  printf '%s' "$body" | claude_agent_verdict
}

# The verdict for signal 2, kept separate from the fetch so it can be tested
# against a recorded body. The agent row is large and carries
# `"status":"active"` (membership) and `"status":"healthy"` (orgChainHealth),
# so only the exact pair counts.
claude_agent_verdict() {
  local body
  body=$(cat)
  case "$body" in
    *'"status":"error"'*)
      case "$body" in
        *"OAuth session expired"*|*"Failed to authenticate"*)
          echo "dead:paperclip-agent-error-auth"; return 0 ;;
      esac
      echo "unknown:paperclip-agent-error-other"; return 0 ;;
    *'"id":"'*)
      # Readable, and not in an auth error: the row has moved on (a later run
      # succeeded). This is why signal 2 is a fallback, never an override.
      echo "unknown:paperclip-agent-not-in-error"; return 0 ;;
  esac
  echo "unknown:paperclip-agent-unreadable"
}

# Signal 3. Only proves a failure happened since the 05:30 run.
claude_auth_jsonl_state() {
  local ref f hit="" dir
  dir="${CLAUDE_PROJECTS_DIR:-$CLAUDE_PROJECTS_DEFAULT}"
  [ -d "$dir" ] || { echo "unknown:no-projects-dir"; return 0; }
  ref="${TMPDIR:-/tmp}/.claude-auth-ref.$$"
  : > "$ref" 2>/dev/null || { echo "unknown:no-temp-for-reference"; return 0; }
  # BSD find has no `-newermt @epoch`; a reference file is the portable form.
  touch -t "$(claude_since_stamp)" "$ref" 2>/dev/null || { rm -f "$ref"; echo "unknown:bad-reference-stamp"; return 0; }
  for f in $(find "$dir" -name '*.jsonl' -newer "$ref" 2>/dev/null | head -20); do
    if grep -q '"model":"<synthetic>"' "$f" 2>/dev/null \
       && grep -q 'Failed to authenticate' "$f" 2>/dev/null; then
      hit="$f"; break
    fi
  done
  rm -f "$ref"
  [ -n "$hit" ] || { echo "unknown:no-auth-failure-in-jsonl"; return 0; }
  if grep -qi 'OAuth session expired' "$hit" 2>/dev/null; then
    echo "dead:jsonl-oauth-session-expired"
  else
    echo "dead:jsonl-failed-to-authenticate"
  fi
}

# The verdict the callers act on. Primary signal wins whenever it is readable;
# a readable "alive" is never overruled by a stale error row or a log line that
# only records yesterday's failure.
claude_auth_state() {
  local state
  state=$(claude_auth_cli_state)
  case "$state" in
    alive|dead:*) echo "$state"; return 0 ;;
  esac
  state=$(claude_auth_agent_state)
  case "$state" in
    dead:*) echo "$state"; return 0 ;;
  esac
  claude_auth_jsonl_state
}

# One place for the words, so the hourly daemon and a hand-run of the legacy
# watchdog cannot drift apart. The first sentence is fixed by GUL-641 AC2; the
# rest exists because "restart it" is the wrong instinct here and the wrong
# subcommand (`claude login`) is the other one.
claude_auth_alert_message() { # $1 = verdict, e.g. dead:claude-auth-status-loggedIn-false
  printf 'claude code auth dead: run claude auth login (%s). HUMAN action, not a restart - no daemon kickstart, no agent restart and no reboot will refresh an expired OAuth session. Use `claude auth login`, or /login in an interactive session; `claude login` is not a subcommand.' "${1#dead:}"
}

# One-line summary of who owns the console. Trust this, never `who` — a logged
# out Mac keeps a stale console entry in utmp, which cost us an hour on
# 2026-10-29.
console_owner() { stat -f%Su /dev/console 2>/dev/null || echo unknown; }
