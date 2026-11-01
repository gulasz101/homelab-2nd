#!/bin/bash
# ---------------------------------------------------------------------------
# homelab-make-headless.sh — make this Mac survive without a display and
# without a human at the keyboard: no lid-close sleep, no idle sleep on AC,
# restart after a power cut, and auto-login so the GUI-domain LaunchAgents
# (Hermes gateway, Syncthing, proxies) come back after a reboot.
#
# The m1max is a MacBookPro18,4 sitting lid-shut on a shelf with a dummy HDMI
# plug. The plug is load-bearing: it is what keeps clamshell mode alive, so
# pulling it out sleeps the machine. `pmset disablesleep 1` removes that
# dependency — lid shut, no display, still running.
#
# Auto-login and FileVault cannot coexist. macOS refuses to log a user in
# automatically while the volume is encrypted, so `--apply` will offer to turn
# FileVault off and says plainly what that costs. See
# docs/adr/pending/headless-mac-runs-filevault-off.md.
#
#   sudo ./homelab-make-headless.sh --check              read-only report
#   sudo ./homelab-make-headless.sh --apply              make it so
#   sudo ./homelab-make-headless.sh --apply --yes        no prompts except the
#                                                        password one
#
# The auto-login password is never an argument and never a file: sysadminctl
# reads it from a prompt (`-password -`). Nothing secret is written by this
# script besides /etc/kcpassword, which the OS itself requires (root:wheel 0600).
#
# A reboot is the only proof. Do it with the owner present, then check
# `stat -f%Su /dev/console` prints the account, not root.
#
# macOS ships bash 3.2: no associative arrays, no ${var,,}.
# ---------------------------------------------------------------------------
set -uo pipefail

ACCOUNT="${SUDO_USER:-}"
REPORT_ROOT=0
MODE=""
ASSUME_YES=0
FILEVAULT_WAIT=900

say() { printf '%s\n' "$*"; }
ok() { printf 'ok:   %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; REPORT_ROOT=1; }

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check ;;
    --apply) MODE=apply ;;
    --yes) ASSUME_YES=1 ;;
    --user) shift; ACCOUNT="${1:-}" ;;
    --filevault-wait) shift; FILEVAULT_WAIT="${1:-900}" ;;
    -h|--help) usage 0 ;;
    *) say "unknown argument: $1"; usage 2 ;;
  esac
  shift
done

[ -n "$MODE" ] || { say "pick --check or --apply"; usage 2; }

if [ "$(id -u)" -ne 0 ]; then
  say "run me with sudo: sudo $0 --$MODE"
  exit 2
fi

# The account that owns the GUI-domain services. Under sudo this is SUDO_USER;
# an SSH session with no console user gives 'root' from /dev/console, so refuse
# rather than guess and repoint auto-login at the wrong person.
if [ -z "$ACCOUNT" ]; then
  ACCOUNT=$(stat -f%Su /dev/console)
  [ "$ACCOUNT" = "root" ] && ACCOUNT=""
fi
if [ -z "$ACCOUNT" ]; then
  say "cannot tell which account should auto-login (no console user)."
  say "pass it: sudo $0 $MODE --user <shortname>"
  exit 2
fi
if ! dscl . -list /Users | grep -qx "$ACCOUNT"; then
  say "account '$ACCOUNT' does not exist on this Mac (dscl . -list /Users)"
  exit 2
fi

pm() { # pm <key> -> value from `pmset -g` (active profile)
  pmset -g | awk -v k="$1" '$1==k {print $2; exit}'
}
fv_state() { # off | on | decrypting | unknown
  local s
  s=$(fdesetup status 2>&1)
  case "$s" in
    "FileVault is Off"*) echo off ;;
    *"Decryption in progress"*|*"decryption in progress"*) echo decrypting ;;
    "FileVault is On"*) echo on ;;
    *) echo unknown ;;
  esac
}
autologin_user() {
  sysadminctl -autologin status 2>&1 | sed -n 's/.*Automatic login user: *//p' | head -1
}

say "host:    $(hostname)  ($(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Identifier/{print $2; exit}'))"
say "account: $ACCOUNT"
say "mode:    $MODE"
say ""

if [ "$MODE" = "check" ]; then
  FV=$(fv_state)
  say "filevault:      $FV"
  say "autoLoginUser:  $(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || echo '<unset>')"
  say "sysadminctl:    $(autologin_user)"
  if [ -f /etc/kcpassword ]; then
    say "kcpassword:     $(ls -l /etc/kcpassword | awk '{print $1, $3":"$4}')"
  else
    say "kcpassword:     <missing>"
  fi
  say "console user:   $(stat -f%Su /dev/console)   (root == nobody logged in graphically)"
  say "power:          $(pmset -g batt | sed -n 's/^Now drawing from //p')"
  for k in sleep displaysleep standby hibernatemode powernap autorestart SleepDisabled; do
    V=$(pm "$k"); [ -n "$V" ] || V="<unset>"
    say "$(printf '%-15s %s' "$k:" "$V")"
  done
  say ""
fi

# --- checks that must pass before this host can look after itself -----------
verdict() {
  FV=$(fv_state)
  [ "$FV" = "off" ] || bad "FileVault is $FV: nothing auto-logs in while the volume is encrypted"
  AL=$(autologin_user)
  if [ "$AL" = "$ACCOUNT" ]; then ok "auto-login user = $ACCOUNT"
  elif [ -z "$AL" ]; then bad "no auto-login user set (sysadminctl -autologin status)"
  else bad "auto-login user is '$AL', expected '$ACCOUNT'"
  fi
  if [ -f /etc/kcpassword ]; then
    PERMS=$(ls -l /etc/kcpassword | awk '{print $1}')
    if [ "$PERMS" = "-rw-------" ]; then ok "/etc/kcpassword present, 0600"
    else bad "/etc/kcpassword has mode $PERMS, expected -rw-------"
    fi
  else
    bad "/etc/kcpassword missing: auto-login will park at the login window"
  fi
  [ "$(pm SleepDisabled)" = "1" ] && ok "disablesleep=1 (lid shut / display unplugged cannot sleep)" \
    || bad "disablesleep is not 1: the dummy HDMI plug is load-bearing"
  [ "$(pm sleep)" = "0" ] && ok "sleep=0 on AC" || bad "sleep=$(pm sleep) on AC"
  [ "$(pm standby)" = "0" ] && ok "standby=0 on AC" || bad "standby=$(pm standby) on AC"
  [ "$(pm hibernatemode)" = "0" ] && ok "hibernatemode=0 on AC" || bad "hibernatemode=$(pm hibernatemode) on AC"
  if [ "$(pm autorestart)" = "1" ]; then ok "autorestart=1 (comes back after a power cut)"
  else warn "autorestart is '$(pm autorestart)' — this Mac does not keep the setting, so a power cut needs a human at the button"
  fi
}

if [ "$MODE" = "check" ]; then
  verdict
  say ""
  [ "$REPORT_ROOT" -eq 0 ] && say "VERDICT: headless-ready" || say "VERDICT: not headless-ready"
  exit "$REPORT_ROOT"
fi

# --- apply -----------------------------------------------------------------
say "== 1/3 power =="
pmset -c sleep 0 displaysleep 0 standby 0 powernap 0 hibernatemode 0 autopoweroff 0 autorestart 1
pmset -a disablesleep 1
say "applied; readback:"
for k in sleep displaysleep standby hibernatemode powernap autorestart SleepDisabled; do
  V=$(pm "$k"); [ -n "$V" ] || V="<unset>"
  say "$(printf '  %-15s %s' "$k:" "$V")"
done
# pmset accepts keys it cannot honour and exits 0 (measured on the Air, macOS 26:
# `pmset -a autorestart 1` is accepted and never stored). Trust the readback.
if [ "$(pm autorestart)" = "1" ]; then
  ok "autorestart=1: comes back by itself after a power cut"
else
  warn "autorestart did not stick on this hardware (readback: '$(pm autorestart)')."
  warn "This Mac will stay off after a power cut until someone presses the button."
fi
say ""

say "== 2/3 FileVault =="
FV=$(fv_state)
if [ "$FV" = "off" ]; then
  ok "FileVault already off"
else
  say "FileVault is $FV. Auto-login is impossible while it is on."
  say ""
  say "  what turning it off costs: the disk is no longer encrypted at rest. Anyone who"
  say "  takes the physical machine can read it, and a stolen MacBook is exactly the"
  say "  case FileVault exists for. What it buys: the host comes back on its own after"
  say "  a power cut instead of waiting for a human to type a password."
  say ""
  if [ "$ASSUME_YES" -ne 1 ]; then
    printf 'turn FileVault off now? type exactly "yes": '
    read -r ANSWER
    [ "$ANSWER" = "yes" ] || { say "stopped before changing FileVault; nothing else was touched."; exit 1; }
  fi
  if ! fdesetup disable; then
    say ""
    say "fdesetup disable failed. If it asked for a FileVault password, re-run this"
    say "step by hand:  sudo fdesetup disable"
    say "then re-run:   sudo $0 --apply"
    exit 1
  fi
  say "decryption started; waiting up to ${FILEVAULT_WAIT}s for 'FileVault is Off.'"
  WAITED=0
  while [ "$WAITED" -lt "$FILEVAULT_WAIT" ]; do
    FV=$(fv_state)
    [ "$FV" = "off" ] && break
    sleep 15
    WAITED=$((WAITED + 15))
    printf '.'
  done
  say ""
  if [ "$FV" = "off" ]; then ok "FileVault is off"
  else
    warn "still decrypting after ${FILEVAULT_WAIT}s (state: $FV). Auto-login will not"
    warn "take effect until it finishes. Re-run --apply when it has."
  fi
fi
say ""

say "== 3/3 auto-login =="
SAVED=0
if [ -f /etc/kcpassword ]; then
  SAVED=1
  cp -p /etc/kcpassword "/etc/kcpassword.bak-$(date +%Y%m%d-%H%M%S)"
fi
say "sysadminctl will ask for the password of '$ACCOUNT' (typing is hidden, nothing"
say "is logged, nothing is passed on a command line)."
if ! sysadminctl -autologin set -userName "$ACCOUNT" -password -; then
  say ""
  say "sysadminctl failed. Nothing was changed; the previous auto-login state is intact."
  [ "$SAVED" -eq 1 ] && say "(a backup of the old /etc/kcpassword is in /etc/, timestamped)"
  exit 1
fi
AL=$(autologin_user)
say ""
say "readback:"
say "  autoLoginUser: ${AL:-<unset>}"
if [ -f /etc/kcpassword ]; then say "  kcpassword: $(ls -l /etc/kcpassword | awk '{print $1, $3":"$4}')"
else warn "  kcpassword: <missing> — auto-login will not work"; fi
say ""

verdict
say ""
if [ "$REPORT_ROOT" -eq 0 ]; then
  say "VERDICT: headless-ready. Proof is a reboot with the owner present:"
  say "  sudo shutdown -r now     # then, once it is back:"
  say "  stat -f%Su /dev/console  # must print $ACCOUNT, not root"
  say "Until that prints the account, treat auto-login as unproven."
else
  say "VERDICT: not headless-ready — see the FAIL lines above."
fi
exit "$REPORT_ROOT"
