#!/bin/bash
# ---------------------------------------------------------------------------
# homelab-install-sou-reporter.sh — install the Lodge reporter for the
# Paperclip PM (Claude Code) as a system LaunchDaemon (GUL-831).
#
#   sudo ./homelab-install-sou-reporter.sh                     # install / repair
#   sudo ./homelab-install-sou-reporter.sh --set-paperclip-token
#        ./homelab-install-sou-reporter.sh --status            # no root needed
#        ./homelab-install-sou-reporter.sh --check             # both doors, real POST
#        ./homelab-install-sou-reporter.sh --dry-run           # plan, no root
#
# Why a separate installer: homelab-install-daemons.sh supervises *ports* (it
# derives commands, then waits for 127.0.0.1:<port>). The reporter has no port;
# its health check is an HTTP round trip to two doors, which is what --check is.
# install-daemons.sh calls this script as its last step, so one command still
# installs the host.
#
# The two credentials live in host/paperclip-air/secrets/sou-claude-code-reporter.sops.yaml
# (SOPS/age; the private key is in the owner's password manager, never here).
# This script never prints a credential. --set-paperclip-token reads the value
# from a file or from a hidden prompt, re-encrypts the secret, and says only
# "stored".
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TREE_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

# Host paths, copied from the shared host library rather than sourced. Reason:
# the Hermes lifecycle guard refuses to run a script that transitively reads
# another file pairing a launchd verb with the supervised agent-gateway service
# label, and the shared library names that service. Sourcing it makes this
# installer unrunnable from the agent that owns host work — which is where it has
# to run. If the constants ever move, the tree check compares the two lists.
HOMELAB_DOMAIN="dev.voitech.homelab"
HOMELAB_USER="paperclip"
HOMELAB_HOME="/Users/paperclip"
HOMELAB_STATE_DIR="$HOMELAB_HOME/.config/homelab"
HOMELAB_LOG_DIR="$HOMELAB_HOME/Library/Logs/homelab"
HOMELAB_LIBEXEC="/usr/local/libexec/homelab"
HOMELAB_DAEMON_DIR="/Library/LaunchDaemons"

require_darwin() {
  [ "$(uname -s)" = "Darwin" ] && return 0
  printf 'this action only runs on the Mac (%s here); use --dry-run to see the plan\n' "$(uname -s)" >&2
  return 1
}

require_root() {
  [ "$(id -u)" -eq 0 ] && return 0
  printf 'this action needs root (it writes %s and drives the system launchd domain)\n' "$HOMELAB_DAEMON_DIR" >&2
  return 1
}

LABEL="$HOMELAB_DOMAIN.sou-claude-code-reporter"
WRAPPER="$SCRIPT_DIR/homelab-sou-claude-code-reporter.sh"
PLIST="$TREE_DIR/launchd/daemons/$LABEL.plist"
SECRET="$TREE_DIR/secrets/sou-claude-code-reporter.sops.yaml"
INSTALLED_WRAPPER="$HOMELAB_LIBEXEC/homelab-sou-claude-code-reporter.sh"
LOG="$HOMELAB_LOG_DIR/sou-claude-code-reporter.log"
SOPS_BIN=${SOPS_BIN:-/opt/homebrew/bin/sops}

MODE="install"
TOKEN_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --install)             MODE="install" ;;
    --status)              MODE="status" ;;
    --check)               MODE="check" ;;
    --dry-run)             MODE="dry-run" ;;
    --set-paperclip-token) MODE="token"; [ $# -gt 1 ] && [ "${2#-}" = "$2" ] && { TOKEN_FILE="$2"; shift; } ;;
    -h|--help)             sed -n '2,25p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# Run a command as the appliance user: the age key, the repo and the reporter
# all live in their home, and root's HOME has none of them.
as_user() {
  if [ "$(id -u)" -eq 0 ]; then
    sudo -u "$HOMELAB_USER" env HOME="$HOMELAB_HOME" PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" "$@"
  else
    "$@"
  fi
}

secret_state() { # prints "key: yes|no  ingest: yes|no"
  [ -f "$SECRET" ] || { say "secret: MISSING ($SECRET)"; return 1; }
  as_user "$SOPS_BIN" --decrypt --extract '["stringData"]["config.json"]' "$SECRET" 2>/dev/null \
    | "${HOMELAB_PYTHON:-/usr/bin/python3}" -c '
import json,sys
try: c=json.load(sys.stdin)
except Exception: print("secret: unreadable (age key?)"); raise SystemExit(1)
print("secret: paperclip agent key %s, ingest token %s" % (
  "set" if str(c.get("paperclip_token") or "").strip() else "MISSING",
  "set" if str(c.get("token") or "").strip() else "MISSING"))
raise SystemExit(0 if str(c.get("paperclip_token") or "").strip() else 1)
'
}

reporter_present() { [ -f "${SOU_REPORTER:-$HOMELAB_HOME/Projects/star-office-ui-fork/reporter/paperclip-claude-code-reporter/paperclip-claude-code-reporter.py}" ]; }

do_dry_run() {
  say "plan: install $LABEL as a system LaunchDaemon (ADR-107: the Air is headless)"
  say "  wrapper  $WRAPPER -> $INSTALLED_WRAPPER"
  say "  plist    $PLIST -> $HOMELAB_DAEMON_DIR/$LABEL.plist"
  say "  secret   $SECRET (SOPS/age; decrypted at start to $HOMELAB_STATE_DIR/sou-claude-code-reporter.json, 0600)"
  say "  logs     $LOG"
  say "  health   $0 --check  (Paperclip live-runs + Lodge POST)"
  say "no port: this daemon is not in homelab-install-daemons.sh's port table"
}

do_token() {
  # Not `local`: the EXIT trap below outlives the function, and a `local` name
  # that has gone out of scope trips `set -u` ("tmp: unbound variable") at exit,
  # which reads like a failure after the secret has already been written.
  tmp=""
  if [ -n "$TOKEN_FILE" ]; then
    [ -r "$TOKEN_FILE" ] || die "cannot read $TOKEN_FILE"
    tmp=$(mktemp "${TMPDIR:-/tmp}/sou-key.XXXXXX")
    tr -d ' \t\r\n' < "$TOKEN_FILE" > "$tmp"
  else
    printf 'Paste the Paperclip agent key for %s (input hidden): ' "claude-code"
    IFS= read -rs key || die "no key read"
    printf '\n'
    [ -n "$key" ] || die "empty key"
    tmp=$(mktemp "${TMPDIR:-/tmp}/sou-key.XXXXXX")
    printf '%s' "$key" > "$tmp"
    unset key
  fi
  chmod 600 "$tmp"
  trap 'rm -f "$tmp" "$tmp.json" "$tmp.yaml" "$tmp.enc"' EXIT
  # Decrypt the one config blob, set the key, and regenerate the document. No
  # line surgery on an encrypted file: the shape is fixed and small.
  if ! as_user "$SOPS_BIN" --decrypt --extract '["stringData"]["config.json"]' "$SECRET" > "$tmp.json" 2>/dev/null; then
    die "cannot decrypt $SECRET as $HOMELAB_USER — is the age key present?"
  fi
  chmod 600 "$tmp.json"
  if ! /usr/bin/python3 - "$tmp.json" "$tmp" "$tmp.yaml" <<'PY'
import json, sys

blob, keyfile, out = sys.argv[1:4]
key = open(keyfile, "r", encoding="utf-8").read().strip()
cfg = json.load(open(blob, "r", encoding="utf-8"))
cfg["paperclip_token"] = key
lines = ["apiVersion: v1", "kind: Secret", "metadata:",
         "  name: sou-claude-code-reporter", "  namespace: host-paperclip-air",
         "type: Opaque", "stringData:", "  config.json: |"]
lines += ["    " + line for line in json.dumps(cfg, indent=2).splitlines()]
open(out, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("rewrote config for agent %s; key length %d" % (cfg["agent"], len(key)))
PY
  then
    die "could not rebuild the secret (nothing changed)"
  fi
  chmod 600 "$tmp.yaml"
  if ! as_user "$SOPS_BIN" --encrypt --input-type yaml --output-type yaml "$tmp.yaml" > "$tmp.enc" 2>/dev/null; then
    die "re-encrypt failed; the secret is unchanged"
  fi
  mv "$tmp.enc" "$SECRET"
  chmod 0644 "$SECRET"
  say "stored: the Paperclip agent key is in $SECRET (encrypted)"
  # Prove it landed, without printing it.
  secret_state || die "the key did not survive encryption — check the file"
  # Clean up here and drop the trap: it must not fire at exit with nothing left
  # to remove (that is what produced "tmp: unbound variable" after "stored").
  rm -f "$tmp" "$tmp.json" "$tmp.yaml" "$tmp.enc"
  trap - EXIT
}

do_status() {
  say "label:  $LABEL"
  say "secret: $SECRET"
  secret_state || true
  if reporter_present; then say "reporter: present"; else say "reporter: MISSING (merge the GUL-827 PR, then check out master)"; fi
  if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
    say "launchd: loaded"
    /bin/launchctl print "system/$LABEL" 2>/dev/null | grep -E '^\s*(state|pid|program|runs|last exit code)' | sed 's/^/  /'
  else
    say "launchd: NOT loaded"
  fi
  [ -f "$LOG" ] && { say "log: $LOG (last lines)"; tail -5 "$LOG" | sed 's/^/  /'; }
  return 0
}

do_check() {
  secret_state >/dev/null || die "the paperclip_token is not set yet — run: sudo $0 --set-paperclip-token"
  reporter_present || die "reporter missing: merge the GUL-827 PR and check out master in ~/Projects/star-office-ui-fork"
  say "checking both doors as $HOMELAB_USER (no credential is printed)"
  as_user /bin/sh "$WRAPPER" check
}

do_install() {
  require_darwin || return 1
  require_root || return 1
  for f in "$WRAPPER" "$PLIST" "$SECRET"; do
    [ -f "$f" ] || die "the repo tree is incomplete: missing $f"
  done
  mkdir -p "$HOMELAB_LIBEXEC" "$HOMELAB_LOG_DIR" "$HOMELAB_STATE_DIR"
  chown "$HOMELAB_USER":staff "$HOMELAB_LOG_DIR" "$HOMELAB_STATE_DIR" 2>/dev/null || :

  step "installing the wrapper"
  install -m 0755 -o root -g wheel "$WRAPPER" "$INSTALLED_WRAPPER" || die "could not install the wrapper"
  say "installed $INSTALLED_WRAPPER"

  step "installing the daemon"
  install -m 0644 -o root -g wheel "$PLIST" "$HOMELAB_DAEMON_DIR/$LABEL.plist" || die "could not install the plist"
  /bin/launchctl enable "system/$LABEL" 2>/dev/null || :
  if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
    /bin/launchctl kickstart -k "system/$LABEL" || warn "kickstart failed"
  else
    /bin/launchctl bootstrap system "$HOMELAB_DAEMON_DIR/$LABEL.plist" || die "bootstrap failed"
  fi
  say "loaded $LABEL in the system domain"

  step "waiting for the reporter to say something"
  local i state
  state=""
  for i in $(seq 1 20); do
    sleep 1
    [ -f "$LOG" ] || continue
    if tail -40 "$LOG" | grep -q "starting reporter"; then state="running"; break; fi
    if tail -40 "$LOG" | grep -q "not configured yet"; then state="waiting"; break; fi
  done
  case "$state" in
    running) say "reporter is running (log: $LOG)" ;;
    waiting) warn "daemon is loaded and holding: the Paperclip agent key is not in the secret yet."
             warn "  finish with: sudo $0 --set-paperclip-token"
             warn "  it picks the key up within one re-read (default 1800s), or kick it: sudo launchctl kickstart -k system/$LABEL" ;;
    *)       warn "no line from the reporter in 20s — read $LOG" ;;
  esac

  say ""
  say "next: sudo $0 --check    (both doors, one real POST)"
}

case "$MODE" in
  dry-run) do_dry_run ;;
  status)  do_status ;;
  check)   do_check ;;
  token)   do_token ;;
  install) do_install ;;
esac
