#!/bin/bash
# ---------------------------------------------------------------------------
# homelab-install-daemons.sh — convert the Air's headless LaunchAgents into
# root LaunchDaemons, exactly once, with a rollback (ADR-098 model A).
#
#   sudo ./homelab-install-daemons.sh              # install / repair
#   sudo ./homelab-install-daemons.sh --status     # what owns what, right now
#   sudo ./homelab-install-daemons.sh --rollback   # back to user agents
#        ./homelab-install-daemons.sh --dry-run    # plan only, no root, no macOS
#
# The one rule this enforces: after it runs, each service has ONE supervisor.
# It does not invent the commands it supervises — it reads them out of the
# LaunchAgent it replaces and stores them in
# /Users/paperclip/.config/homelab/services.env (0600, host-only, not in git).
# A service whose command cannot be derived is skipped, loudly: installing a
# KeepAlive daemon with an unknown command is a crash loop, not a fix.
#
# Safe to re-run: it repairs a missing daemon, re-bootstraps one that is
# unloaded, and skips anything already healthy.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TREE_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=homelab-lib.sh
. "$SCRIPT_DIR/homelab-lib.sh"
# shellcheck source=homelab-find-agent.sh
. "$SCRIPT_DIR/homelab-find-agent.sh"

MODE="apply"
FORCE=0
TS=$(date '+%Y%m%d-%H%M%S')
BACKUP_DIR="$HOMELAB_HOME/Library/LaunchAgents.h2-336-backup-$TS"

usage() {
  cat <<'USAGE'
homelab-install-daemons.sh [--dry-run|--status|--rollback] [--force]

  (no flag)   install or repair the five root LaunchDaemons, retire their
              LaunchAgents, write services.env from the agent commands
  --dry-run   print the plan; needs neither root nor macOS (CI runs this)
  --status    print who supervises each service and whether its port answers
  --rollback  boot the daemons out, restore the backed-up LaunchAgents
  --force     overwrite existing CMD entries in services.env from the agents
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  MODE="dry-run" ;;
    --status)   MODE="status" ;;
    --rollback) MODE="rollback" ;;
    --force)    FORCE=1 ;;
    -h|--help)  usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# --- the plan, shared by --dry-run and the real run -------------------------
print_plan() {
  say "plan: install the headless host services as root LaunchDaemons (ADR-098 model A)"
  say "host user:      $HOMELAB_USER (home $HOMELAB_HOME)"
  say "launcher:       $HOMELAB_LIBEXEC/homelab-service-run.sh"
  say "commands file:  $HOMELAB_SERVICES_ENV (0600, host state, never in git)"
  say "logs:           $HOMELAB_LOG_DIR/<service>.log"
  say ""
  say "daemon (system domain)                       port  RTO   restart"
  for svc in $HOMELAB_SERVICES; do
    printf 'daemon  %-22s %-30s %-5s %-5ss KeepAlive(%ss throttle)\n' \
      "$svc" "$(svc_label "$svc")" "$(svc_port "$svc")" "$(svc_rto "$svc")" "$(svc_throttle "$svc")"
  done
  say "daemon  (retired)      dev.voitech.homelab-watchdog  -    -   superseded: launchd is the supervisor now"
  say ""
  say "agent (user session)                         why it stays an agent"
  say "        (none today: GUL-732 moved the heartbeat sender to system/ as well, ADR-113)"
  say "heartbeat              $(printf '%s.heartbeat' "$HOMELAB_DOMAIN")   system daemon, installed by homelab-install-scheduled-jobs.sh"
  say ""
  say "steps: back up + boot out each LaunchAgent -> derive its command ->"
  say "       write services.env -> install launcher -> bootstrap the daemon ->"
  say "       enable + kickstart -> assert exactly one owner per label"
  say "host check: skipped under --dry-run; the real run requires Darwin/macOS and root (CI is Linux)"
}

# --- preflight --------------------------------------------------------------
preflight() {
  local svc missing=0
  for svc in $HOMELAB_SERVICES; do
    [ -f "$TREE_DIR/launchd/daemons/$(svc_label "$svc").plist" ] || { warn "missing launchd/daemons/$(svc_label "$svc").plist"; missing=1; }
  done
  [ -f "$SCRIPT_DIR/homelab-service-run.sh" ] || { warn "missing bin/homelab-service-run.sh"; missing=1; }
  [ -f "$TREE_DIR/launchd/daemons/$HOMELAB_DOMAIN.heartbeat.plist" ] || { warn "missing heartbeat daemon plist (ADR-113: the sender must run headless)"; missing=1; }
  [ "$missing" -eq 0 ] || die "the repo tree is incomplete; refusing to touch the host"
}

ensure_dirs() {
  mkdir -p "$HOMELAB_STATE_DIR" "$HOMELAB_LOG_DIR" "$HOMELAB_LIBEXEC"
  chown "$HOMELAB_USER":staff "$HOMELAB_STATE_DIR" "$HOMELAB_LOG_DIR" 2>/dev/null || true
  chmod 700 "$HOMELAB_STATE_DIR"
  chmod 750 "$HOMELAB_LOG_DIR"
}

# --- derive a command line from an existing LaunchAgent ---------------------
extract_cmd() { # $1 = plist path; prints a single shell command line
  /usr/bin/plutil -convert json -o - "$1" 2>/dev/null | /usr/bin/python3 -c '
import json, shlex, sys
try:
    p = json.load(sys.stdin)
except Exception:
    sys.exit(1)
args = p.get("ProgramArguments")
if not args:
    sys.exit(1)
env = p.get("EnvironmentVariables") or {}
# PATH/HOME and friends come from the daemon plist, not from the old agent.
skip = {"PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "SHELL", "LOGNAME", "USER"}
prefix = "".join("%s=%s " % (k, shlex.quote(str(v))) for k, v in env.items() if k not in skip)
cmd = " ".join(shlex.quote(a) for a in args)
wd = p.get("WorkingDirectory")
if wd:
    cmd = "cd %s && %s" % (shlex.quote(wd), cmd)
print(prefix + cmd)
'
}

env_has_cmd() { # $1 = service
  [ -f "$HOMELAB_SERVICES_ENV" ] || return 1
  grep -qE "^$(svc_var "$1")=" "$HOMELAB_SERVICES_ENV" 2>/dev/null
}

env_put_cmd() { # $1 = service, $2 = command line
  local var line
  var=$(svc_var "$1")
  line="$var=$(printf '%q' "$2")"
  if [ -f "$HOMELAB_SERVICES_ENV" ]; then
    if env_has_cmd "$1"; then
      [ "$FORCE" -eq 1 ] || return 0
      # Rebuild the file without the old line (no sed -i portability games).
      grep -vE "^$var=" "$HOMELAB_SERVICES_ENV" > "$HOMELAB_SERVICES_ENV.tmp" 2>/dev/null || :
    else
      cp "$HOMELAB_SERVICES_ENV" "$HOMELAB_SERVICES_ENV.tmp"
    fi
  else
    {
      printf '# Generated by host/paperclip-air/bin/homelab-install-daemons.sh (H2-336).\n'
      printf '# Host state: one command line per supervised service. NOT in git.\n'
      printf '# Edit a value and run: sudo launchctl kickstart -k system/%s.<service>\n' "$HOMELAB_DOMAIN"
    } > "$HOMELAB_SERVICES_ENV.tmp"
  fi
  printf '%s\n' "$line" >> "$HOMELAB_SERVICES_ENV.tmp"
  mv "$HOMELAB_SERVICES_ENV.tmp" "$HOMELAB_SERVICES_ENV"
  chown "$HOMELAB_USER":staff "$HOMELAB_SERVICES_ENV" 2>/dev/null || true
  chmod 600 "$HOMELAB_SERVICES_ENV"
}

# --- launchd helpers --------------------------------------------------------
bootout_agent() { # $1 = plist basename, $2 = uid
  launchctl bootout "gui/$2/$1" 2>/dev/null || launchctl asuser "$2" launchctl bootout "gui/$2/$1" 2>/dev/null || :
}

daemon_loaded() { launchctl print "system/$1" >/dev/null 2>&1; }

# --- modes ------------------------------------------------------------------
do_status() {
  local uid svc label agent owner port
  uid=$(appliance_uid)
  say "console owner: $(console_owner)   (trust this, not 'who')"
  say "appliance uid: ${uid:-unknown}"
  say ""
  printf '%-22s %-38s %-6s %-9s %s\n' service label port daemon agent
  for svc in $HOMELAB_SERVICES; do
    label=$(svc_label "$svc")
    agent="no"
    find_agent_plists "$svc" | grep -q . && agent="YES"
    port=$(svc_port "$svc")
    if daemon_loaded "$label"; then owner="loaded"; else owner="absent"; fi
    printf '%-22s %-38s %-6s %-9s %s\n' "$svc" "$label" "$port" "$owner" "$agent"
  done
  say ""
  if find_agent_plists "heartbeat" | grep -q .; then
    warn "a heartbeat agent is still on disk: $(find_agent_plists heartbeat | tr '\n' ' ') — it must be a system daemon (ADR-113); run homelab-install-scheduled-jobs.sh"
  fi
  if daemon_loaded "$HOMELAB_DOMAIN.heartbeat"; then
    say "heartbeat daemon loaded in system/ (ADR-113)"
  else
    say "heartbeat daemon NOT loaded: sudo $SCRIPT_DIR/homelab-install-scheduled-jobs.sh"
  fi
}

do_apply() {
  local svc label src agent_uid port elapsed failed=0
  require_darwin || return 1
  require_root || return 1
  preflight
  print_plan
  step "writing host state"
  ensure_dirs

  # 1. derive every command BEFORE removing anything, so a failed derivation
  #    leaves the host exactly as it was.
  local cmd
  for svc in $HOMELAB_SERVICES; do
    if env_has_cmd "$svc" && [ "$FORCE" -eq 0 ]; then
      say "cmd  $svc: already in services.env (kept)"
      continue
    fi
    cmd=""
    for p in $(find_agent_plists "$svc"); do
      cmd=$(extract_cmd "$p")
      [ -n "$cmd" ] && { say "cmd  $svc: derived from $(basename "$p")"; break; }
    done
    if [ -z "$cmd" ]; then
      warn "no command for $svc: no LaunchAgent found and services.env has none."
      warn "  Add '$(svc_var "$svc")=\"<command>\"' to $HOMELAB_SERVICES_ENV and re-run."
      warn "  Its LaunchAgent is left alone and no daemon is installed for it."
      continue
    fi
    env_put_cmd "$svc" "$cmd"
  done

  step "installing the launcher"
  install -m 0755 -o root -g wheel "$SCRIPT_DIR/homelab-service-run.sh" \
    "$HOMELAB_LIBEXEC/homelab-service-run.sh" || die "could not install the launcher"
  say "installed $HOMELAB_LIBEXEC/homelab-service-run.sh"

  step "converting agents to daemons"
  agent_uid=$(appliance_uid)
  [ -n "$agent_uid" ] || die "user $HOMELAB_USER does not exist on this host"
  mkdir -p "$BACKUP_DIR"
  for svc in $HOMELAB_SERVICES; do
    label=$(svc_label "$svc")
    if ! env_has_cmd "$svc"; then
      say "skip $svc: no command (see WARN above)"
      continue
    fi
    # Retire the agent first: if the daemon fails to load, the service is down
    # for seconds and homelab-recover-appliance.sh brings it back. The other
    # order leaves two owners, which is the defect we are removing.
    for p in $(find_agent_plists "$svc"); do
      bootout_agent "$(basename "$p")" "$agent_uid"
      mv "$p" "$BACKUP_DIR/$(basename "$p")" && say "retired agent $(basename "$p") -> $BACKUP_DIR"
    done
    src="$TREE_DIR/launchd/daemons/$label.plist"
    install -m 0644 -o root -g wheel "$src" "$HOMELAB_DAEMON_DIR/$label.plist" || { warn "install failed for $label"; failed=1; continue; }
    launchctl enable "system/$label" 2>/dev/null || :
    if daemon_loaded "$label"; then
      launchctl kickstart -k "system/$label" 2>/dev/null || warn "kickstart failed for $label"
    else
      launchctl bootstrap system "$HOMELAB_DAEMON_DIR/$label.plist" || { warn "bootstrap failed for $label"; failed=1; continue; }
    fi
    say "installed daemon $label"
  done

  step "waiting for services (this is the RTO you will quote)"
  for svc in $HOMELAB_SERVICES; do
    env_has_cmd "$svc" || continue
    port=$(svc_port "$svc")
    elapsed=$(wait_up "$svc" 180)
    if [ -n "$elapsed" ]; then
      say "up    $svc on 127.0.0.1:$port after ${elapsed}s (target $(svc_rto "$svc")s)"
    else
      warn "down  $svc on 127.0.0.1:$port after 180s"
      failed=1
    fi
  done

  step "asserting one supervisor per service"
  for svc in $HOMELAB_SERVICES; do
    label=$(svc_label "$svc")
    if daemon_loaded "$label" && find_agent_plists "$svc" | grep -q .; then
      warn "TWO OWNERS: $svc has a system daemon and a user agent — fix before walking away"
      failed=1
    fi
  done

  step "next"
  say "1. log out and back in, or just leave it: the daemons do not care about the session."
  say "2. install the heartbeat sender as a system daemon (ADR-113, it must run headless):"
  say "     sudo $SCRIPT_DIR/homelab-install-scheduled-jobs.sh"
  say "3. run the drills: sudo $SCRIPT_DIR/homelab-drill-session-loss.sh --all --i-am-at-the-mac"
  [ "$failed" -eq 0 ] || die "finished with warnings: run $SCRIPT_DIR/homelab-recover-appliance.sh and read the log above"
  say "done: five services supervised by launchd in the system domain."
}

do_rollback() {
  local svc label p
  require_darwin || return 1
  require_root || return 1
  step "booting the daemons out"
  for svc in $HOMELAB_SERVICES; do
    label=$(svc_label "$svc")
    launchctl bootout "system/$label" 2>/dev/null && say "booted out $label" || say "not loaded: $label"
    rm -f "$HOMELAB_DAEMON_DIR/$label.plist"
  done
  step "restoring the LaunchAgents"
  for p in "$HOMELAB_HOME"/Library/LaunchAgents.h2-336-backup-*/*.plist; do
    [ -f "$p" ] || continue
    cp "$p" "$HOMELAB_AGENT_DIR/" && say "restored $(basename "$p")"
  done
  say ""
  say "The agents will load at the next login. To load them now, log in graphically"
  say "and run: launchctl bootstrap gui/\$(id -u $HOMELAB_USER) $HOMELAB_AGENT_DIR"
  say "Until then use $SCRIPT_DIR/homelab-recover-appliance.sh (headless, no GUI needed)."
}

case "$MODE" in
  dry-run)  print_plan ;;
  status)   do_status ;;
  apply)    do_apply ;;
  rollback) do_rollback ;;
esac
