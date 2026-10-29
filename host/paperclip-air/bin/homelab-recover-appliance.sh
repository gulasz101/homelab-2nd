#!/bin/bash
# ---------------------------------------------------------------------------
# homelab-recover-appliance.sh — THE break-glass command (H2-336).
#
# Re-runnable, headless, works with nobody logged in graphically. It brings back
# anything that is not serving, preferring launchd (the supervisor) and falling
# back to a detached nohup only when the service has no daemon installed (i.e.
# before homelab-install-daemons.sh has been run, or after a rollback).
#
#   sudo /usr/local/libexec/homelab/homelab-recover-appliance.sh
#
# It never kills a healthy service and never starts a second copy: every action
# is gated on "is the port answering?" first. That is what made the 2026-10-29
# recovery safe to run twice while the incident was still live.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=homelab-lib.sh
. "$SCRIPT_DIR/homelab-lib.sh"

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "this is the Mac's recovery script; $(uname -s) here"
[ "$(id -u)" -eq 0 ] || die "run me with sudo: I drive the system launchd domain"

say "console owner: $(console_owner)  (root = nobody logged in; the services do not care)"
say "recovering at $(now_h)"
say ""

if [ -f "$HOMELAB_SERVICES_ENV" ]; then
  # shellcheck disable=SC1090
  . "$HOMELAB_SERVICES_ENV"
else
  warn "$HOMELAB_SERVICES_ENV is missing: daemons will be kicked, but services without a"
  warn "daemon cannot be started by hand. Run homelab-install-daemons.sh --status."
fi

started=0
healthy=0
broken=0

for svc in $HOMELAB_SERVICES; do
  label=$(svc_label "$svc")
  port=$(svc_port "$svc")
  if svc_up "$svc"; then
    say "ok    $svc already serving on 127.0.0.1:$port"
    healthy=$((healthy + 1))
    continue
  fi
  if launchctl print "system/$label" >/dev/null 2>&1; then
    say "kick  $svc is not serving; kickstart -k system/$label"
    launchctl kickstart -k "system/$label" 2>/dev/null || warn "kickstart failed for $label"
  else
    var=$(svc_var "$svc")
    eval "cmd=\${$var:-}"
    if [ -n "${cmd:-}" ]; then
      say "nohup $svc has no daemon loaded; starting it detached from $HOMELAB_SERVICES_ENV"
      mkdir -p "$HOMELAB_LOG_DIR"
      # Setsid-equivalent: nohup + background survives this ssh session, which is
      # how the 2026-10-29 recovery worked with no GUI at all.
      /bin/sh -c "nohup sh -c 'exec $cmd' >> '$HOMELAB_LOG_DIR/$svc.log' 2>&1 &" || warn "start failed for $svc"
    else
      warn "cannot start $svc: no daemon and no $var"
      broken=$((broken + 1))
      continue
    fi
  fi
  started=$((started + 1))
  elapsed=$(wait_up "$svc" 120)
  if [ -n "$elapsed" ]; then
    say "up    $svc after ${elapsed}s"
  else
    warn "still down: $svc (see $HOMELAB_LOG_DIR/$svc.log)"
    broken=$((broken + 1))
  fi
done

say ""
say "summary: $healthy healthy, $started restarted, $broken broken"
say "public check from anywhere:"
say "  curl -s -o /dev/null -w '%{http_code}\\n' https://paperclip.voitech.dev"
[ "$broken" -eq 0 ] || exit 1

