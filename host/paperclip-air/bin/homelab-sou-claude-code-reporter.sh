#!/bin/sh
# ---------------------------------------------------------------------------
# homelab-sou-claude-code-reporter.sh — run the Lodge reporter for the
# Paperclip PM (Claude Code) as a headless system daemon on the Air.
#
# GUL-831. The reporter itself lives in the star-office-ui-fork repo
# (reporter/paperclip-claude-code-reporter/); this wrapper is the only host
# state around it:
#
#   1. decrypt the host secret (SOPS/age) to a 0600 config file the reporter
#      reads — the plaintext never sits in git and never in the repo tree;
#   2. hold still, loudly, while the two credentials are still missing, so a
#      daemon that is not yet configured does not become a crash loop;
#   3. exec the reporter in `run` mode (or pass `check` / `once` through for
#      the installer's proof).
#
# The secret is decrypted on every start, and re-read every
# WAIT_SECONDS while it is incomplete, so filling in a credential needs no
# daemon restart.
#
# Exit codes: 0 clean, 2 config/secret problem (launchd restarts it later),
# 78 EX_CONFIG — "not configured yet", the same code systemd uses.
#
# Usage (as the appliance user; launchd supplies HOME):
#   homelab-sou-claude-code-reporter.sh          # run (daemon mode)
#   homelab-sou-claude-code-reporter.sh check    # prove both credentials
#   homelab-sou-claude-code-reporter.sh once     # one tick
#   homelab-sou-claude-code-reporter.sh once --dry-run
# ---------------------------------------------------------------------------
set -u

HOMELAB_USER_DEFAULT="paperclip"
HOME_DIR=${HOME:-/Users/${HOMELAB_USER_DEFAULT}}
STATE_DIR="$HOME_DIR/.config/homelab"
DEFAULT_CONFIG="$STATE_DIR/sou-claude-code-reporter.json"
DEFAULT_SECRET="$HOME_DIR/Projects/homelab-2nd/host/paperclip-air/secrets/sou-claude-code-reporter.sops.yaml"
DEFAULT_REPORTER="$HOME_DIR/Projects/star-office-ui-fork/reporter/paperclip-claude-code-reporter/paperclip-claude-code-reporter.py"

SOPS_BIN=${SOPS_BIN:-/opt/homebrew/bin/sops}
PYTHON_BIN=${PYTHON_BIN:-/usr/bin/python3}

# How long to sit quiet between re-reads while a credential is missing.
WAIT_SECONDS=${SOU_WAIT_SECONDS:-1800}

log() { printf '%s sou-claude-code-reporter: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { log "FATAL: $*"; exit 2; }

MODE=${1:-run}
shift 2>/dev/null || true

# `check`/`once` must fail fast: the installer is waiting on the answer.
case "$MODE" in
  run|check|once) ;;
  -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
  *) printf 'usage: %s [run|check|once] [--dry-run]\n' "$0" >&2; exit 2 ;;
esac

SECRET=${SOU_SECRET:-$DEFAULT_SECRET}
CONFIG=${SOU_REPORTER_CONFIG:-$DEFAULT_CONFIG}
REPORTER=${SOU_REPORTER:-$DEFAULT_REPORTER}

# --- 1. the secret -> a 0600 config file ------------------------------------
decrypt_config() {
  [ -f "$SECRET" ] || { log "secret not found: $SECRET"; return 1; }
  [ -x "$SOPS_BIN" ] || { log "sops not found at $SOPS_BIN"; return 1; }
  mkdir -p "$STATE_DIR" || return 1
  chmod 700 "$STATE_DIR" 2>/dev/null || :
  umask 077
  if ! "$SOPS_BIN" --decrypt --extract '["stringData"]["config.json"]' "$SECRET" > "$CONFIG.new" 2>"$CONFIG.err"; then
    log "cannot decrypt $SECRET — is the age key readable by $(id -un)? ($(head -1 "$CONFIG.err"))"
    rm -f "$CONFIG.new"
    return 1
  fi
  rm -f "$CONFIG.err"
  # Both credentials present? The reporter enforces the rest itself.
  "$PYTHON_BIN" - "$CONFIG.new" <<'PY'
import json, sys
path = sys.argv[1]
try:
    cfg = json.load(open(path, "r", encoding="utf-8"))
except (OSError, ValueError) as exc:
    print("config is not valid JSON: %s" % (exc,))
    raise SystemExit(1)
missing = [k for k in ("paperclip_token", "token") if not str(cfg.get(k) or "").strip()]
if missing:
    print("incomplete: " + ", ".join(missing))
    raise SystemExit(3)
raise SystemExit(0)
PY
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$CONFIG.new"
    [ "$rc" -eq 3 ] && return 3
    return 1
  fi
  mv "$CONFIG.new" "$CONFIG" || return 1
  chmod 600 "$CONFIG"
  return 0
}

# --- 2. the reporter itself -------------------------------------------------
[ -f "$REPORTER" ] || die "reporter not found: $REPORTER (merge the GUL-827 PR and check out master)"

exec_reporter() {
  [ -f "$CONFIG" ] || die "config missing: $CONFIG"
  log "starting reporter (config $CONFIG)"
  exec "$PYTHON_BIN" "$REPORTER" "$MODE" ${1:-} ${2:-}
}

# --- 3. modes ---------------------------------------------------------------
if [ "$MODE" != "run" ]; then
  decrypt_config || die "the secret is not usable; run: sudo homelab-install-sou-reporter.sh --set-paperclip-token"
  exec_reporter "$@"
fi

# Daemon mode: wait for both credentials instead of crash-looping. launchd
# restarts us on a non-zero exit, so the wait has to happen here.
while :; do
  if decrypt_config; then
    exec_reporter "$@"
  fi
  rc=$?
  if [ "$rc" -eq 3 ]; then
    log "not configured yet: waiting for the board-minted Paperclip agent key (re-reading every ${WAIT_SECONDS}s)"
    sleep "$WAIT_SECONDS"
    continue
  fi
  # A real error (secret missing, age key unreadable): let launchd pace us.
  log "secret unusable (exit $rc); retrying in 300s"
  sleep 300
done
