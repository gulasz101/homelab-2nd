#!/bin/bash
# ---------------------------------------------------------------------------
# homelab-install-scheduled-jobs.sh — install the Air's SCHEDULED jobs as
# system LaunchDaemons (ADR-107), with the scripts deployed from this repo.
#
#   sudo ./homelab-install-scheduled-jobs.sh            # install / repair
#   sudo ./homelab-install-scheduled-jobs.sh --status   # what is loaded where
#           ./homelab-install-scheduled-jobs.sh --dry-run
#
# Why this is separate from homelab-install-daemons.sh: that one converts
# long-running SERVICES (KeepAlive + a health port + a command file). These are
# calendar/interval jobs with no port and no process to keep alive — different
# shape, different check, same rule: launchd in the system domain owns them.
#
# What it does, in order, and why that order:
#   1. deploy the job scripts to /usr/local/libexec/homelab (root-owned, from
#      this tree). They no longer live in ~/.hermes/scripts: a script that only
#      exists in one host's home directory cannot be reviewed, restored onto a
#      replacement host, or fixed through GitOps.
#   2. retire the gui/<uid> LaunchAgent of the same label, keeping a backup.
#      Doing this BEFORE the daemon is bootstrapped means the job is briefly
#      unsupervised rather than doubly supervised; a double-supervised backup
#      job is a duplicate S3 write, a double-supervised watchdog is two alerts.
#   3. install the plist, bootstrap it into system/, kickstart it once so a
#      broken install fails now rather than at 03:30 in silence.
#   4. move the old ~/.hermes/scripts copies aside (superseded), so nobody
#      edits a file that is no longer the one launchd runs.
#
# Safe to re-run: a loaded job is booted out and brought back from this tree.
#
# CAREFUL: re-running this while a job is mid-flight RESTARTS it (bootout +
# kickstart -k). Harmless for the watchdog; for the state backup it throws away
# a snapshot in progress and starts again — on 2026-10-30 two installs from
# parallel agent runs each restarted a running backup. Nothing was lost (a
# completed run overwrote the same S3 keys), but do not deploy this between
# 03:30 and ~04:00 unless you mean to redo the night's backup.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TREE_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=homelab-lib.sh
. "$SCRIPT_DIR/homelab-lib.sh"

SCHEDULED_JOBS="hermes-state-backup hermes-memory-watchdog"
TS=$(date '+%Y%m%d-%H%M%S')
BACKUP_DIR="$HOMELAB_HOME/Library/LaunchAgents.h2-336-backup-$TS"
SCRIPTS_BACKUP_DIR="$HOMELAB_HOME/.hermes/scripts.superseded-$TS"

MODE="apply"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE="dry-run" ;;
    --status)  MODE="status" ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# Labels are the historical com.gulasz101.* ones on purpose: the label is a
# contract with ADR-071/ADR-080, the watchdog's own check 5b, and every past
# tracking note. Moving the domain does not require renaming the job; renaming
# it during a recovery is churn with a new failure mode (a half-renamed job is
# scheduled twice under two names).
sched_label()  { printf 'com.gulasz101.%s' "$1"; }
sched_plist()  { printf '%s/%s.plist' "$TREE_DIR/launchd/daemons" "$(sched_label "$1")"; }
sched_script() { printf '%s/%s.sh' "$HOMELAB_LIBEXEC" "$1"; }

print_plan() {
  say "plan: install the Air's scheduled jobs as system LaunchDaemons (ADR-107)"
  say "host user:   $HOMELAB_USER (home $HOMELAB_HOME)"
  say "deploy to:   $HOMELAB_LIBEXEC/<job>.sh and $HOMELAB_DAEMON_DIR/<label>.plist"
  say ""
  say "job                     label                                    schedule"
  say "hermes-state-backup     $(sched_label hermes-state-backup)       daily 03:30 (StartCalendarInterval)"
  say "hermes-memory-watchdog  $(sched_label hermes-memory-watchdog)    hourly (StartInterval 3600)"
  say ""
  say "steps: deploy scripts -> retire gui agent (backup kept) -> install plist ->"
  say "       bootstrap system/<label> -> kickstart -k -> assert username = $HOMELAB_USER"
  say "then:  the host-local ~/.hermes/scripts copies are moved to"
  say "       $HOMELAB_HOME/.hermes/scripts.superseded-<ts>/"
  say "host check: skipped under --dry-run; the real run requires Darwin/macOS and root (CI is Linux)"
}

preflight() {
  local job missing=0
  for job in $SCHEDULED_JOBS; do
    [ -f "$(sched_plist "$job")" ] || { warn "missing launchd/daemons/$(sched_label "$job").plist"; missing=1; }
    [ -f "$SCRIPT_DIR/$job.sh" ] || { warn "missing bin/$job.sh"; missing=1; }
  done
  [ "$missing" -eq 0 ] || die "the repo tree is incomplete; refusing to touch the host"
}

daemon_loaded() { launchctl print "system/$1" >/dev/null 2>&1; }

do_status() {
  local job label domain
  say "console owner: $(console_owner)   (a gui agent cannot fire while this is root)"
  say ""
  printf '%-24s %-38s %-10s %-8s %s\n' job label system gui script
  for job in $SCHEDULED_JOBS; do
    label=$(sched_label "$job")
    if daemon_loaded "$label"; then domain="loaded"; else domain="absent"; fi
    printf '%-24s %-38s %-10s %-8s %s\n' "$job" "$label" "$domain" \
      "$([ -f "$HOMELAB_AGENT_DIR/$label.plist" ] && echo PRESENT || echo gone)" \
      "$([ -f "$(sched_script "$job")" ] && echo deployed || echo MISSING)"
  done
}

do_apply() {
  require_darwin || return 1
  require_root || return 1
  preflight
  print_plan

  local uid job label
  uid=$(appliance_uid)
  [ -n "$uid" ] || die "user $HOMELAB_USER does not exist on this host"

  step "deploying the scripts to $HOMELAB_LIBEXEC"
  mkdir -p "$HOMELAB_LIBEXEC"
  for job in $SCHEDULED_JOBS; do
    install -m 0755 -o root -g wheel "$SCRIPT_DIR/$job.sh" "$(sched_script "$job")" \
      || die "could not install $(sched_script "$job")"
    say "installed $(sched_script "$job")"
  done

  mkdir -p "$BACKUP_DIR"
  for job in $SCHEDULED_JOBS; do
    label=$(sched_label "$job")
    step "converting $job"

    # 1. retire the agent: no GUI session exists right now, so bootout fails
    #    quietly and the plist file is what must go.
    if [ -f "$HOMELAB_AGENT_DIR/$label.plist" ]; then
      launchctl bootout "gui/$uid/$label" 2>/dev/null || true
      mv "$HOMELAB_AGENT_DIR/$label.plist" "$BACKUP_DIR/$label.plist" \
        && say "retired agent $label -> $BACKUP_DIR" \
        || { warn "could not move agent plist for $label"; }
    else
      say "no agent plist for $label (already converted)"
    fi

    # 2. install and load the daemon. Boot out first so a re-run reads the
    #    plist from disk instead of running last week's copy.
    install -m 0644 -o root -g wheel "$(sched_plist "$job")" "$HOMELAB_DAEMON_DIR/$label.plist" \
      || { warn "install failed for $label"; continue; }
    launchctl bootout "system/$label" 2>/dev/null || true
    launchctl enable "system/$label" 2>/dev/null || true
    if launchctl bootstrap system "$HOMELAB_DAEMON_DIR/$label.plist"; then
      say "bootstrapped system/$label"
    else
      warn "bootstrap failed for $label — job is NOT scheduled"
      continue
    fi

    # 3. fire it once, now, on purpose: a broken install must fail while a
    #    person is watching, not at 03:30 in silence.
    launchctl kickstart -k "system/$label" 2>/dev/null \
      && say "kickstarted $label (proving the install)" \
      || warn "kickstart failed for $label"
  done

  step "moving the superseded host-local copies aside"
  mkdir -p "$SCRIPTS_BACKUP_DIR"
  for job in $SCHEDULED_JOBS; do
    if [ -f "$HOMELAB_HOME/.hermes/scripts/$job.sh" ]; then
      mv "$HOMELAB_HOME/.hermes/scripts/$job.sh" "$SCRIPTS_BACKUP_DIR/$job.sh" \
        && say "superseded ~/.hermes/scripts/$job.sh -> $SCRIPTS_BACKUP_DIR/"
    fi
  done

  step "asserting the domain, the user and the schedule"
  local failed=0 printed
  for job in $SCHEDULED_JOBS; do
    label=$(sched_label "$job")
    printed=$(launchctl print "system/$label" 2>/dev/null || true)
    if [ -z "$printed" ]; then
      warn "$label is not loaded in system/"
      failed=1
      continue
    fi
    printf '%s\n' "$printed" | grep -q "username = $HOMELAB_USER" \
      || { warn "$label does not report username = $HOMELAB_USER"; failed=1; }
    if [ -f "$HOMELAB_AGENT_DIR/$label.plist" ]; then
      warn "$label still has a LaunchAgent — TWO OWNERS"
      failed=1
    fi
    say "ok   $label loaded in system/, user $HOMELAB_USER, no agent copy"
  done

  step "next"
  say "1. read the logs the kickstart just wrote:"
  say "     tail -3 ~/.hermes/logs/hermes-state-backup.log"
  say "     tail -3 ~/.hermes/logs/hermes-memory-watchdog.log"
  say "2. the 03:30 run tomorrow is the real proof; a missed run still shows as"
  say "   'backup-job-not-run' from the watchdog only if the watchdog itself runs."
  [ "$failed" -eq 0 ] || die "finished with warnings: the jobs above are not scheduled"
  say "done: scheduled jobs are system daemons; nothing here depends on a login session."
}

case "$MODE" in
  dry-run) print_plan ;;
  status)  do_status ;;
  apply)   do_apply ;;
esac
