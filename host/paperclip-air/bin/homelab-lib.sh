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

# One-line summary of who owns the console. Trust this, never `who` — a logged
# out Mac keeps a stale console entry in utmp, which cost us an hour on
# 2026-10-29.
console_owner() { stat -f%Su /dev/console 2>/dev/null || echo unknown; }
