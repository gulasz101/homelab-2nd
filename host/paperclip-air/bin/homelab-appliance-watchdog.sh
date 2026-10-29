#!/bin/bash
# ---------------------------------------------------------------------------
# homelab-appliance-watchdog.sh — LEGACY. Kept as the record of the
# 2026-10-29 recovery, not as a service.
#
# This is the interim watchdog that was installed at 11:53 on 2026-10-29 as a
# root LaunchDaemon (dev.voitech.homelab-watchdog, StartInterval 120). It
# restarted detached children whenever `/dev/console` was not owned by the
# appliance user. It proved the model works — Syncthing came back on the next
# tick — but ADR-098 retired it: launchd in the system domain is the supervisor
# now, and a script that also restarts things is a second owner.
#
# It refuses to run when the model-A daemons are installed, so it cannot come
# back to life by accident and fight launchd. If it is still loaded on the host,
# remove it:
#   sudo launchctl bootout system/dev.voitech.homelab-watchdog
#   sudo rm /Library/LaunchDaemons/dev.voitech.homelab-watchdog.plist
#   sudo rm /usr/local/sbin/homelab-appliance-watchdog.sh
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=homelab-lib.sh
. "$SCRIPT_DIR/homelab-lib.sh"

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

if [ -f "$HOMELAB_DAEMON_DIR/$(svc_label paperclip).plist" ]; then
  say "legacy watchdog: superseded by ADR-098 (launchd owns the services); doing nothing."
  exit 0
fi

say "legacy watchdog tick at $(now_h)"

# No GUI session (console owned by root) means the user session's agents are
# gone. With a GUI session, launchd supervises them and we must not interfere.
owner=$(console_owner)
if [ "$owner" != "root" ]; then
  say "GUI session owned by '$owner': leaving it to launchd"
  exit 0
fi

restarted=""
for svc in $HOMELAB_SERVICES; do
  svc_up "$svc" && continue
  var=$(svc_var "$svc")
  [ -f "$HOMELAB_SERVICES_ENV" ] && . "$HOMELAB_SERVICES_ENV"
  eval "cmd=\${$var:-}"
  if [ -z "${cmd:-}" ]; then
    warn "no command for $svc; skipping"
    continue
  fi
  mkdir -p "$HOMELAB_LOG_DIR"
  /bin/sh -c "nohup sh -c 'exec $cmd' >> '$HOMELAB_LOG_DIR/$svc.log' 2>&1 &" || { warn "start failed for $svc"; continue; }
  restarted="$restarted $svc"
done

if [ -n "$restarted" ]; then
  say "restarted:$restarted"
  if command -v hermes >/dev/null 2>&1; then
    # Bot-token path: works with the gateway down, which is why the watchdog
    # could still shout on 2026-10-29.
    hermes send -t mattermost "homelab watchdog: no GUI session, restarted:$restarted at $(now_h)" >/dev/null 2>&1 \
      || warn "could not post to Mattermost (hermes send failed)"
  fi
else
  say "nothing to restart"
fi
