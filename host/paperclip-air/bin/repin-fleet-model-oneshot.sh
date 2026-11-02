#!/bin/bash
# ---------------------------------------------------------------------------
# repin-fleet-model-oneshot.sh — run repin-fleet-model.sh once, overnight,
# then delete its own schedule (GUL-769).
#
# This exists because the repin has to happen at a time nobody is awake for:
# the Ollama Pro weekly allowance rolls over around 00:00 UTC, and the fleet
# should move back onto the subscription it already pays for as soon as it
# does. The owner asked for it to be scheduled for that window.
#
# Why a self-deleting wrapper rather than a normal entry in
# homelab-install-scheduled-jobs.sh: a launchd StartCalendarInterval with a
# Day key recurs *monthly*. Left installed, this job would fire again on the
# 2nd of every month and silently repin a fleet that by then may be somewhere
# else on purpose. A one-shot job that does not remove itself is a landmine,
# so removal is part of the job rather than a thing to remember.
#
# The repin script itself IS durable and reusable (both directions, any time
# the quota situation changes) — that one lives in the repo and is installed
# the normal way. Only this trigger is disposable.
# ---------------------------------------------------------------------------
set -uo pipefail

LABEL="${LABEL:-com.gulasz101.repin-fleet-model-gul769}"
PLIST="${PLIST:-/Library/LaunchDaemons/$LABEL.plist}"
LIBEXEC="${LIBEXEC:-/usr/local/libexec/homelab}"
REPIN="$LIBEXEC/repin-fleet-model.sh"
SELF="$LIBEXEC/repin-fleet-model-oneshot.sh"
LOG_DIR="${LOG_DIR:-/Users/paperclip/Library/Logs/homelab}"
LOG_FILE="$LOG_DIR/repin-fleet-model.log"

# Deadline for the Ollama route to start serving, UTC. 04:00Z is 05:00 local,
# half an hour before the PM's 05:30 morning review — so whatever happens, the
# outcome is already written down by the time anyone reads the board.
WAIT_UNTIL="${WAIT_UNTIL:-04:00}"
PROBE_EVERY="${PROBE_EVERY:-1200}"

mkdir -p "$LOG_DIR"
log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG_FILE"; }

log "oneshot: starting (deadline ${WAIT_UNTIL}Z, probe every ${PROBE_EVERY}s)"

if [ ! -x "$REPIN" ] && [ ! -f "$REPIN" ]; then
  log "oneshot: FATAL $REPIN is not installed; leaving the schedule in place so this is noticed"
  exit 1
fi

/bin/bash "$REPIN" --to-ollama --wait-until "$WAIT_UNTIL" --probe-every "$PROBE_EVERY"
rc=$?
log "oneshot: repin exited $rc (0=repinned 2=route still walled, left on -ds 1=partial, NEEDS A HUMAN)"

# Tear down the schedule whatever happened. A rerun on the 2nd of next month
# would be worse than a missed repin: by then the right route is whatever the
# then-current ADR says, not what this job was written for.
#
# Not torn down on rc=1 (a partial repin): the fleet is split across two
# routes and that must not be papered over by a job that quietly disappears.
if [ "$rc" = "1" ]; then
  log "oneshot: partial repin — schedule and script LEFT INSTALLED on purpose, read the log above"
  exit 1
fi

if [ -f "$PLIST" ]; then
  launchctl bootout "system/$LABEL" 2>/dev/null
  rm -f "$PLIST" && log "oneshot: removed $PLIST"
fi
rm -f "$SELF" && log "oneshot: removed $SELF"
log "oneshot: done (rc=$rc)"
exit "$rc"
