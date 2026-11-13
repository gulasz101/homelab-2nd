#!/bin/bash
# ---------------------------------------------------------------------------
# gpu-slot.sh — one GPU slot on the M1 Max, shared by the local LLM and the local
# image engines (GUL-1431).
#
# The M1 Max has 32 GB. Qwen3.6-35B-A3B (GGUF UD-IQ4_XS) in LM Studio wires
# about 22-23 GB at 128k context (measured 2026-11-13). One Ideogram 4 job
# needs about 17-18 GB. Both
# together would push the box past the GPU limit, so they take turns, and the
# owner ruled that images win:
#
#   begin <engine>  called by the ideogram4-local worker before a LOCAL job
#                   (ideogram4, flux2-klein). Writes the marker, waits for
#                   running LLM requests to finish (max GPU_SLOT_DRAIN_SECS),
#                   then unloads the model. Exit 0 even if the drain timed out:
#                   the image job runs anyway.
#   end             called by the worker after the job, success or not.
#                   Removes the marker and loads the model again.
#   keep            run by launchd every 2 minutes. Loads the model when no image
#                   job holds the slot and it is not loaded (after a reboot, a
#                   crashed worker, a failed `end`). Clears a stale marker
#                   whose worker PID is dead or older than GPU_SLOT_MAX_SECS.
#   status          one line: loaded or not, marker or not.
#
# While the model is unloaded, LM Studio answers every request with a fast
# HTTP 400 "No models loaded" (measured: 14 ms), and LiteLLM's fallback chain
# for qwen3.6-35b-a3b-local moves the call to the cloud routes. JIT auto-load MUST be
# off in LM Studio (http-server-config.json justInTimeModelLoading=false), or
# the first request during an image job would load the model straight back.
#
# Loads are serialised with a mkdir lock: two `lms load` calls at once create a
# second instance (qwen3.6-35b-a3b:2) and double the RAM, which is the exact failure
# this script exists to prevent.
#
# Written for bash 3.2 (macOS /bin/bash): no associative arrays, no mapfile.
# ---------------------------------------------------------------------------
set -uo pipefail

LMS="${LMS:-$HOME/.lmstudio/bin/lms}"
MODEL_KEY="${GPU_SLOT_MODEL_KEY:-qwen3.6-35b-a3b}"
IDENTIFIER="${GPU_SLOT_IDENTIFIER:-qwen3.6-35b-a3b}"
CONTEXT="${GPU_SLOT_CONTEXT:-131072}"
PARALLEL="${GPU_SLOT_PARALLEL:-2}"
STATE_DIR="${GPU_SLOT_STATE_DIR:-$HOME/Library/Application Support/gpu-slot}"
LOG_FILE="${GPU_SLOT_LOG:-$HOME/Library/Logs/homelab/gpu-slot.log}"
DRAIN_SECS="${GPU_SLOT_DRAIN_SECS:-90}"
MAX_SECS="${GPU_SLOT_MAX_SECS:-3600}"
POLL_SECS="${GPU_SLOT_POLL_SECS:-3}"

MARKER="$STATE_DIR/image-job"
LOAD_LOCK="$STATE_DIR/load.lock"

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"
log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG_FILE"; }

# Prints the status of our identifier ("idle", "generating", ...) or nothing.
# `lms ps --json` is a list of loaded models with identifier and status.
model_status() {
  "$LMS" ps --json 2>/dev/null | python3 -c '
import json, sys
want = sys.argv[1]
try:
    models = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in models:
    if m.get("identifier") == want:
        print(m.get("status", "unknown"))
        break
' "$IDENTIFIER"
}

is_loaded() { [ -n "$(model_status)" ]; }

marker_pid() { [ -f "$MARKER" ] && awk '{print $1}' "$MARKER"; }
marker_age() {
  local started
  started=$(awk '{print $3}' "$MARKER" 2>/dev/null)
  [ -n "$started" ] || { echo 0; return; }
  echo $(( $(date +%s) - started ))
}

marker_is_live() {
  [ -f "$MARKER" ] || return 1
  local pid age
  pid=$(marker_pid)
  age=$(marker_age)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$age" -lt "$MAX_SECS" ]; then
    return 0
  fi
  return 1
}

take_load_lock() {
  local waited=0
  while ! mkdir "$LOAD_LOCK" 2>/dev/null; do
    # A lock older than 5 minutes belongs to a dead caller: `lms load` takes
    # 10-20 s for the model.
    if [ -n "$(find "$LOAD_LOCK" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
      log "load lock is stale, removing"
      rmdir "$LOAD_LOCK" 2>/dev/null
      continue
    fi
    [ "$waited" -ge 300 ] && return 1
    sleep 1
    waited=$((waited + 1))
  done
  return 0
}
drop_load_lock() { rmdir "$LOAD_LOCK" 2>/dev/null; return 0; }

load_model() {
  take_load_lock || { log "FAIL could not take the load lock"; return 1; }
  if is_loaded; then
    drop_load_lock
    return 0
  fi
  log "loading $MODEL_KEY as $IDENTIFIER (ctx $CONTEXT, parallel $PARALLEL)"
  "$LMS" load "$MODEL_KEY" -c "$CONTEXT" --parallel "$PARALLEL" --gpu max \
    --identifier "$IDENTIFIER" -y >/dev/null 2>&1
  local rc=$?
  drop_load_lock
  if [ "$rc" -ne 0 ] || ! is_loaded; then
    log "FAIL lms load exited $rc and $IDENTIFIER is not loaded"
    return 1
  fi
  log "ok   $IDENTIFIER loaded"
  return 0
}

unload_model() {
  take_load_lock || { log "FAIL could not take the load lock"; return 1; }
  if is_loaded; then
    "$LMS" unload "$IDENTIFIER" >/dev/null 2>&1
  fi
  drop_load_lock
  if is_loaded; then
    log "FAIL $IDENTIFIER is still loaded after unload"
    return 1
  fi
  log "ok   $IDENTIFIER unloaded"
  return 0
}

cmd_begin() {
  local engine="${1:-unknown}" owner="${GPU_SLOT_OWNER_PID:-$PPID}" waited=0 st
  printf '%s %s %s\n' "$owner" "$engine" "$(date +%s)" >"$MARKER"
  log "begin engine=$engine owner_pid=$owner"
  # Drain: let requests that are already running finish, up to DRAIN_SECS.
  # New requests keep coming, so this is a best effort; images win at the end.
  while :; do
    st=$(model_status)
    [ -z "$st" ] && break
    [ "$st" = "idle" ] && break
    if [ "$waited" -ge "$DRAIN_SECS" ]; then
      log "drain timed out after ${waited}s (status $st); unloading anyway"
      break
    fi
    sleep "$POLL_SECS"
    waited=$((waited + POLL_SECS))
  done
  unload_model
  return 0
}

cmd_end() {
  rm -f "$MARKER"
  log "end"
  load_model
}

cmd_keep() {
  if [ -f "$MARKER" ]; then
    if marker_is_live; then
      return 0
    fi
    log "stale marker (pid $(marker_pid), age $(marker_age)s), removing"
    rm -f "$MARKER"
  fi
  if is_loaded; then
    return 0
  fi
  log "keeper: $IDENTIFIER is not loaded and no image job holds the slot"
  load_model
}

cmd_status() {
  local st
  st=$(model_status)
  if [ -f "$MARKER" ]; then
    printf 'model=%s marker=%s\n' "${st:-not-loaded}" "$(cat "$MARKER")"
  else
    printf 'model=%s marker=none\n' "${st:-not-loaded}"
  fi
}

case "${1:-}" in
  begin)  shift; cmd_begin "$@" ;;
  end)    cmd_end ;;
  keep)   cmd_keep ;;
  status) cmd_status ;;
  *) echo "usage: gpu-slot.sh begin <engine> | end | keep | status" >&2; exit 64 ;;
esac
