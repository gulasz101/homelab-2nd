#!/bin/bash
# ---------------------------------------------------------------------------
# homelab-drill-session-loss.sh — the boring drill, and the numbers it writes
# down (H2-336, ADR-098).
#
# A drill that has never been run is not a recovery plan. This script runs the
# four rehearsals, times each one, and appends a line per service to
# /Users/paperclip/Library/Logs/homelab/drills.jsonl. RUNBOOK.md quotes those
# numbers; nothing here invents one.
#
#   ./homelab-drill-session-loss.sh --list
#   sudo ./homelab-drill-session-loss.sh --session-loss --i-am-at-the-mac
#   sudo ./homelab-drill-session-loss.sh --kill paperclip
#   sudo ./homelab-drill-session-loss.sh --kill all
#   sudo ./homelab-drill-session-loss.sh --all --i-am-at-the-mac
#   sudo ./homelab-drill-session-loss.sh --reboot-attended --i-am-at-the-mac
#   ./homelab-drill-session-loss.sh --restore          # restore checklist
#   ./homelab-drill-session-loss.sh --record restore-paperclip 214 pass
#   ./homelab-drill-session-loss.sh --report
#
# --i-am-at-the-mac is a deliberate speed bump: two of these log the console
# user out or reboot the machine, and the issue that created this script says
# no unattended reboot until auto-login is proven.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=homelab-lib.sh
. "$SCRIPT_DIR/homelab-lib.sh"

ATTENDED=0
MODE=""
TARGET=""

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

list_drills() {
  cat <<'LIST'
drills (each one records real seconds to ~/Library/Logs/homelab/drills.jsonl):

  session-loss    log the console user out (launchctl bootout gui/<uid>) — the
                  closest honest simulation of the 2026-10-29 WindowServer logout —
                  then measure every service until it serves again. Needs root
                  and --i-am-at-the-mac: it kills anything unsaved in the session.
  kill            kill -9 one supervised service (or 'all') and measure the launchd
                  restart. This is the per-service RTO for a crash.
  reboot-attended reboot the host and, after it comes back, prove auto-login:
                  stat -f%Su /dev/console must say paperclip, then this script
                  measures every service. Needs --i-am-at-the-mac.
  restore         restore Paperclip from CNPG + OMV MinIO backups into a scratch
                  namespace and confirm the UI. Prints the checklist and the
                  commands; records the time with --record when the human is done.

usage: --list | --session-loss | --kill <service|all> | --reboot-attended |
       --all | --restore | --record <drill> <seconds> <pass|fail> | --report
       add --i-am-at-the-mac to any destructive drill
LIST
}

record() { # $1 drill, $2 service, $3 seconds, $4 verdict
  mkdir -p "$HOMELAB_LOG_DIR"
  chown "$HOMELAB_USER":staff "$HOMELAB_LOG_DIR" 2>/dev/null || true
  printf '{"ts":"%s","drill":"%s","service":"%s","seconds":%s,"verdict":"%s","console":"%s"}\n' \
    "$(now_h)" "$1" "$2" "$3" "$4" "$(console_owner)" >> "$HOMELAB_DRILL_LOG"
  printf '%-14s %-22s %5ss  %s\n' "$1" "$2" "$3" "$4"
}

need_attended() {
  [ "$ATTENDED" -eq 1 ] || die "destructive drill: re-run with --i-am-at-the-mac when a human is in front of the Mac"
}

measure_services() { # $1 drill name, $2 timeout per service
  local svc elapsed verdict worst=0
  for svc in $HOMELAB_SERVICES; do
    elapsed=$(wait_up "$svc" "$2")
    if [ -n "$elapsed" ]; then
      verdict="pass"
      [ "$elapsed" -gt "$(svc_rto "$svc")" ] && verdict="slow"
    else
      elapsed="$2"
      verdict="fail"
    fi
    [ "$elapsed" -gt "$worst" ] && worst=$elapsed
    record "$1" "$svc" "$elapsed" "$verdict"
  done
  say ""
  say "worst service: ${worst}s"
}

drill_session_loss() {
  local uid
  need_attended
  require_darwin || return 1
  require_root || return 1
  uid=$(appliance_uid)
  [ -n "$uid" ] || die "user $HOMELAB_USER does not exist"
  say "session-loss drill at $(now_h)"
  say "console owner before: $(console_owner)"
  say "booting out gui/$uid — this is the logout WindowServer forced on 2026-10-29"
  launchctl bootout "gui/$uid" || warn "bootout returned non-zero (a session may already be gone)"
  say "console owner after:  $(console_owner)   (root = no GUI session; the point of model A)"
  measure_services "session-loss" 300
  say ""
  say "pass condition: every service 'pass'/'slow' and console owner is root."
  say "A 'fail' means a service still depends on the session — check its plist."
}

drill_kill() { # $1 = service or all
  local svc pid port found=0
  require_darwin || return 1
  case "$1" in
    all) set -- $HOMELAB_SERVICES ;;
    *)   set -- "$1" ;;
  esac
  say "kill -9 drill at $(now_h)"
  for svc in "$@"; do
    pid=$(launchctl print "system/$(svc_label "$svc")" 2>/dev/null | awk '/^[[:space:]]*pid = /{print $3; exit}')
    if [ -z "${pid:-}" ]; then
      warn "$svc: not running under launchd (no pid) — install the daemon first"
      record "kill" "$svc" 0 "no-daemon"
      continue
    fi
    found=1
    say "killing $svc (pid $pid)"
    kill -9 "$pid" 2>/dev/null || warn "kill -9 $pid failed"
    # Time from the port being free, not from the signal: the dying process's
    # listening socket keeps accepting for a moment and the naive version
    # recorded 0 s for a service that took 10 (measured on 2026-10-30).
    port=$(svc_port "$svc")
    wait_closed "$port" 15 || warn "$svc: port $port still open 15 s after kill -9 — timing anyway"
    elapsed=$(wait_up "$svc" 180)
    if [ -n "$elapsed" ]; then
      verdict="pass"; [ "$elapsed" -gt "$(svc_rto "$svc")" ] && verdict="slow"
      record "kill" "$svc" "$elapsed" "$verdict"
    else
      record "kill" "$svc" 180 "fail"
    fi
  done
  [ "$found" -eq 1 ] || warn "nothing was killed"
}

drill_reboot() {
  need_attended
  require_darwin || return 1
  require_root || return 1
  say "attended reboot drill at $(now_h)"
  say "before the reboot, record the power settings (they must survive a power cut):"
  pmset -g | grep -E 'autorestart|standby|autopoweroff| sleep' || warn "pmset -g gave nothing"
  say ""
  say "rebooting. When the Mac is back, SSH in and run:"
  say "  stat -f%Su /dev/console        # must print $HOMELAB_USER, otherwise auto-login is broken"
  say "  $SCRIPT_DIR/homelab-drill-session-loss.sh --record reboot-manual <seconds> pass"
  say "  $SCRIPT_DIR/homelab-drill-session-loss.sh --restore"
  say ""
  say "If /dev/console says root, auto-login failed: fix /etc/kcpassword and"
  say "  sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser -string $HOMELAB_USER"
  shutdown -r now
}

restore_checklist() {
  cat <<'RESTORE'
Paperclip restore drill (CNPG on k3s + OMV MinIO). Run from any box with kubectl
that can reach the cluster (homelab-2nd), NOT from the Air.

  1. Pick the newest base backup:
       kubectl -n paperclip get backups.postgresql.cnpg.io --sort-by=.metadata.creationTimestamp
  2. Restore into a scratch namespace so the live app is untouched:
       kubectl create namespace paperclip-restore-drill
       kubectl -n paperclip get cluster paperclip-db -o json \
         | jq '.metadata.name="paperclip-db-drill" | .metadata.namespace="paperclip-restore-drill"' \
         | kubectl apply -f -          # then patch bootstrap.recovery.backupName to the backup above
  3. Wait for the cluster:
       kubectl -n paperclip-restore-drill get cluster paperclip-db-drill -w
  4. Point a throwaway Paperclip at it (same image tag as the live one), port-forward
     and confirm the UI loads and the issue list is non-empty:
       kubectl -n paperclip-restore-drill port-forward deploy/paperclip-drill 3100:3100
       curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3100/
  5. Record the wall-clock seconds from step 1 to a working UI:
       ./homelab-drill-session-loss.sh --record restore-paperclip <seconds> pass
  6. Tear the scratch namespace down: kubectl delete namespace paperclip-restore-drill

Second restore drill (gateway): pull the 03:30 snapshot of ~/.hermes from the
OMV MinIO bucket hermes-state-backups, unpack it next to the live tree, start a
gateway from it on a spare port with HERMES_HOME pointed at the copy, and confirm
`hermes -p andrzej config get skills.external_dirs` answers. That proves the
agent state - not just the database - is recoverable.
RESTORE
}

drill_report() {
  [ -f "$HOMELAB_DRILL_LOG" ] || { say "no drill has been recorded yet ($HOMELAB_DRILL_LOG is empty)"; return 0; }
  python3 - "$HOMELAB_DRILL_LOG" <<'PY'
import json, sys
rows = []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        rows.append(json.loads(line))
    except ValueError:
        continue
if not rows:
    print('no drill has been recorded yet'); sys.exit(0)
print('%-20s %-14s %-22s %7s  %s' % ('when', 'drill', 'service', 'seconds', 'verdict'))
for r in rows[-40:]:
    print('%-20s %-14s %-22s %7s  %s' % (r.get('ts', '?'), r.get('drill', '?'),
          r.get('service', '?'), r.get('seconds', '?'), r.get('verdict', '?')))
PY
}

while [ $# -gt 0 ]; do
  case "$1" in
    --list)            MODE="list" ;;
    --session-loss)    MODE="session-loss" ;;
    --kill)            MODE="kill"; shift; TARGET="${1:-}"; [ -n "$TARGET" ] || die "--kill needs a service or 'all'" ;;
    --reboot-attended) MODE="reboot" ;;
    --all)             MODE="all" ;;
    --restore)         MODE="restore" ;;
    --report)          MODE="report" ;;
    --record)          MODE="record"; shift; REC_DRILL="${1:-}"; shift; REC_SECS="${1:-}"; shift; REC_VERDICT="${1:-}";;
    --i-am-at-the-mac) ATTENDED=1 ;;
    -h|--help)         list_drills; exit 0 ;;
    *) die "unknown argument: $1 (try --list)" ;;
  esac
  shift
done

case "$MODE" in
  list)         list_drills ;;
  session-loss) drill_session_loss ;;
  kill)         drill_kill "$TARGET" ;;
  reboot)       drill_reboot ;;
  all)          drill_kill all; drill_session_loss ;;
  restore)      restore_checklist ;;
  record)       [ -n "${REC_DRILL:-}" ] && [ -n "${REC_SECS:-}" ] || die "--record needs <drill> <seconds> <pass|fail>"
                record "$REC_DRILL" "-" "$REC_SECS" "${REC_VERDICT:-unknown}" ;;
  report)       drill_report ;;
  "")           list_drills; exit 2 ;;
esac
