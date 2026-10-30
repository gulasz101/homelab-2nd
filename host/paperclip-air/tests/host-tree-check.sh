#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# H2-336 / AC2: the host/paperclip-air tree must be installable, single-owner
# and secret-free. This check is portable on purpose: it runs in CI on Linux
# and on the Air (bash 3.2), so it validates the *shape* of every plist with
# python3's plistlib and never needs launchctl, plutil or a booted macOS.
#
# What it proves, and why each assertion exists:
#   * every headless service has a system-domain plist (ADR-098 model A) with
#     RunAtLoad + KeepAlive + ThrottleInterval, so launchd is the only owner;
#   * those plists run the shared launcher, not a hand-written command, so the
#     host keeps its own commands in ~/.config/homelab/services.env;
#   * no daemon carries a UserName other than the appliance user, and no daemon
#     has a companion LaunchAgent shipped in this tree (two owners is the
#     defect ADR-098 forbids);
#   * the heartbeat is a *user* agent on purpose (session loss must look like
#     host loss to the off-host receiver);
#   * every script parses (bash -n) and the installer's plan can be rendered
#     without root (--dry-run), which is the only way CI can run it;
#   * the tree carries no credential material.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOMAIN="dev.voitech.homelab"
APPLIANCE_USER="paperclip"
APPLIANCE_HOME="/Users/paperclip"
SERVICES="hermes-gateway paperclip minio-lan-proxy gemini-tunnel syncthing"
LAUNCHER="/usr/local/libexec/homelab/homelab-service-run.sh"

RC=0
fail() { printf 'FAIL: %s\n' "$*"; RC=1; }
ok()   { printf 'ok:   %s\n' "$*"; }

# ---- 1. the two documents a human needs --------------------------------
for f in README.md RUNBOOK.md; do
  [ -s "$HERE/$f" ] && ok "$f present" || fail "$f missing or empty"
done

# ---- 2. one system-domain plist per headless service -------------------
for svc in $SERVICES; do
  plist="$HERE/launchd/daemons/$DOMAIN.$svc.plist"
  if [ ! -f "$plist" ]; then fail "missing daemon plist launchd/daemons/$DOMAIN.$svc.plist"; continue; fi
  python3 - "$plist" "$svc" "$DOMAIN" "$APPLIANCE_USER" "$APPLIANCE_HOME" "$LAUNCHER" <<'PY' || RC=1
import plistlib, sys, os
path, svc, domain, user, home, launcher = sys.argv[1:7]
problems = []
def bad(msg): problems.append(msg)
try:
    with open(path, 'rb') as fh:
        p = plistlib.load(fh)
except Exception as exc:                       # unparseable is a hard fail
    print('FAIL: %s is not a valid plist: %s' % (path, exc)); sys.exit(1)
if p.get('Label') != '%s.%s' % (domain, svc):
    bad('Label is %r, expected %r' % (p.get('Label'), '%s.%s' % (domain, svc)))
if os.path.basename(path) != '%s.plist' % p.get('Label'):
    bad('filename must equal <Label>.plist (launchd bootstrap is label-driven)')
if p.get('UserName') != user:
    bad('UserName is %r, expected %r - model A runs in the system domain as the appliance user' % (p.get('UserName'), user))
if p.get('RunAtLoad') is not True:
    bad('RunAtLoad must be true: the service has to come up before anyone logs in')
if p.get('KeepAlive') is not True:
    bad('KeepAlive must be true: a crash must be restarted by launchd, not by a script we own')
if not isinstance(p.get('ThrottleInterval'), int) or p.get('ThrottleInterval') < 10:
    bad('ThrottleInterval must be an integer >= 10 to stop a crash-loop from burning the host')
args = p.get('ProgramArguments') or []
if len(args) != 3 or args[1] != launcher or args[2] != svc:
    bad('ProgramArguments must be ["/bin/sh", %r, %r], got %r' % (launcher, svc, args))
if args and args[0] != '/bin/sh':
    bad('ProgramArguments[0] must be /bin/sh (the launcher is a shell script)')
for key in ('StandardOutPath', 'StandardErrorPath'):
    val = p.get(key) or ''
    if not val.startswith(home + '/Library/Logs/homelab/'):
        bad('%s must live under %s/Library/Logs/homelab/ (launchd appends forever, one place to rotate)' % (key, home))
env = p.get('EnvironmentVariables') or {}
if 'PATH' not in env:
    bad('EnvironmentVariables.PATH missing: launchd daemons get a minimal PATH, homebrew lives at /opt/homebrew/bin')
if env.get('HOME') != home:
    bad('EnvironmentVariables.HOME must be %r: the launcher reads its config from the home directory' % home)
for msg in problems:
    print('FAIL: %s: %s' % (os.path.basename(path), msg))
sys.exit(1 if problems else 0)
PY
  [ "$RC" -eq 0 ] && ok "daemon plist $svc"
done

# ---- 3. no daemon may also ship a LaunchAgent (two owners) -------------
for svc in $SERVICES; do
  if [ -e "$HERE/launchd/agents/$DOMAIN.$svc.plist" ]; then
    fail "launchd/agents/$DOMAIN.$svc.plist exists: $svc would have two supervisors (ADR-098)"
  fi
done

# ---- 3b. the scheduled jobs: system domain, appliance user, a real schedule ----
# ADR-107/108. These are the jobs that went silent on 2026-10-29 because they
# lived in gui/501: assert the shape that would have caught it.
SCHEDULED="hermes-state-backup hermes-memory-watchdog"
for job in $SCHEDULED; do
  plist="$HERE/launchd/daemons/com.gulasz101.$job.plist"
  if [ ! -f "$plist" ]; then fail "missing scheduled-job plist launchd/daemons/com.gulasz101.$job.plist"; continue; fi
  python3 - "$plist" "$job" "$APPLIANCE_USER" "$APPLIANCE_HOME" "$HERE" <<'PY' || RC=1
import os, plistlib, sys
path, job, user, home, tree = sys.argv[1:6]
label = "com.gulasz101." + job
problems = []
def bad(m): problems.append(m)
try:
    with open(path, 'rb') as fh:
        p = plistlib.load(fh)
except Exception as exc:
    print('FAIL: %s is not a valid plist: %s' % (path, exc)); sys.exit(1)
if p.get('Label') != label:
    bad('Label is %r, expected %r' % (p.get('Label'), label))
if os.path.basename(path) != label + '.plist':
    bad('filename must equal <Label>.plist')
if p.get('UserName') != user:
    bad('UserName is %r, expected %r — a LaunchDaemon defaults to root (ADR-107)' % (p.get('UserName'), user))
if p.get('KeepAlive'):
    bad('KeepAlive must be absent: a scheduled job is not a service to keep running')
if not (p.get('StartCalendarInterval') or p.get('StartInterval')):
    bad('no StartCalendarInterval/StartInterval: nothing would ever schedule it')
env = p.get('EnvironmentVariables') or {}
if 'PATH' not in env:
    bad('EnvironmentVariables.PATH missing')
if env.get('HOME') != home:
    bad('EnvironmentVariables.HOME must be %r: launchd does not guarantee HOME for system daemons' % home)
if env.get('HERMES_HOME') != home + '/.hermes':
    bad('EnvironmentVariables.HERMES_HOME must be %r: the installed script is outside the Hermes tree' % (home + '/.hermes'))
args = p.get('ProgramArguments') or []
want = '/usr/local/libexec/homelab/%s.sh' % job
if len(args) != 2 or args[0] != '/bin/bash' or args[1] != want:
    bad('ProgramArguments must be ["/bin/bash", %r], got %r' % (want, args))
if not os.path.isfile(os.path.join(tree, 'bin', job + '.sh')):
    bad('bin/%s.sh is missing from the tree (the installed copy has no source)' % job)
if os.path.exists(os.path.join(tree, 'launchd', 'agents', label + '.plist')):
    bad('launchd/agents/%s.plist exists: the job would be scheduled twice' % label)
for m in problems:
    print('FAIL: %s: %s' % (os.path.basename(path), m))
sys.exit(1 if problems else 0)
PY
  [ "$RC" -eq 0 ] && ok "scheduled-job plist $job"
done

# the scheduled-job installer must render its plan without root (CI is Linux)
if [ -f "$HERE/bin/homelab-install-scheduled-jobs.sh" ]; then
  sched_plan=$(bash "$HERE/bin/homelab-install-scheduled-jobs.sh" --dry-run 2>&1)
  for job in $SCHEDULED; do
    printf '%s\n' "$sched_plan" | grep -q -- "$job" \
      && ok "scheduled installer plans $job" \
      || fail "scheduled installer's --dry-run does not mention $job"
  done
else
  fail "bin/homelab-install-scheduled-jobs.sh missing (ADR-108)"
fi

# ---- 4. the heartbeat is a user agent on purpose -----------------------
hb="$HERE/launchd/agents/$DOMAIN.heartbeat.plist"
if [ -f "$hb" ]; then
  python3 - "$hb" "$DOMAIN" "$APPLIANCE_HOME" <<'PY' || RC=1
import plistlib, sys, os
path, domain, home = sys.argv[1:4]
problems = []
def bad(m): problems.append(m)
with open(path, 'rb') as fh:
    p = plistlib.load(fh)
if p.get('Label') != domain + '.heartbeat':
    bad('Label must be %s.heartbeat' % domain)
if 'UserName' in p:
    bad('UserName must be absent: the heartbeat must die with the GUI session (that is the signal)')
if p.get('StartInterval') != 60:
    bad('StartInterval must be 60 (the off-host receiver alerts after 3 missed beats)')
if p.get('RunAtLoad') is not True:
    bad('RunAtLoad must be true so a login starts beating immediately')
args = p.get('ProgramArguments') or []
if not args or not args[-1].startswith(home + '/'):
    bad('ProgramArguments must invoke a script under %s' % home)
for key in ('StandardOutPath', 'StandardErrorPath'):
    if not (p.get(key) or '').startswith(home + '/Library/Logs/homelab/'):
        bad('%s must live under %s/Library/Logs/homelab/' % (key, home))
for m in problems:
    print('FAIL: heartbeat agent: %s' % m)
sys.exit(1 if problems else 0)
PY
  [ "$RC" -eq 0 ] && ok "heartbeat agent plist"
else
  fail "missing launchd/agents/$DOMAIN.heartbeat.plist (the off-host receiver needs a sender)"
fi

# ---- 5. every script parses; the legacy watchdog refuses to double-run --
for f in "$HERE"/bin/*.sh "$HERE"/tests/*.sh; do
  [ -f "$f" ] || continue
  bash -n "$f" 2>"/tmp/host-tree-check.$$" && ok "bash -n $(basename "$f")" || { fail "bash -n $(basename "$f"): $(cat "/tmp/host-tree-check.$$")"; }
done
rm -f "/tmp/host-tree-check.$$"
for tool in homelab-install-daemons.sh homelab-drill-session-loss.sh homelab-recover-appliance.sh homelab-heartbeat.sh homelab-appliance-watchdog.sh homelab-service-run.sh homelab-lib.sh; do
  [ -f "$HERE/bin/$tool" ] && ok "bin/$tool present" || fail "bin/$tool missing"
done

# ---- 6. the tree carries no credentials --------------------------------
# Tokens/keys belong in 1Password + the host, never in this public repo.
if grep -rInE '(BEGIN (AGE|OPENSSH|RSA) PRIVATE KEY|X-Heartbeat-Token: *[A-Za-z0-9]{8,}|password *= *[^$"'"'"' ]{6,}|api[_-]?key *= *[A-Za-z0-9]{16,})' \
      --include='*.sh' --include='*.plist' --include='*.md' --include='*.env' "$HERE" >"/tmp/host-secret-scan.$$" 2>/dev/null; then
  # The heartbeat script may *reference* the token file; it may never inline a value.
  if grep -vE 'heartbeat-token|TOKEN_FILE|token_file|X-Heartbeat-Token: \$|X-Heartbeat-Token: "\$' "/tmp/host-secret-scan.$$" | grep -q .; then
    sed 's/^/    /' "/tmp/host-secret-scan.$$"
    fail "possible credential material in host/paperclip-air (see lines above)"
  else
    ok "only token *paths* referenced, no inline values"
  fi
else
  ok "no credential material in the tree"
fi
rm -f "/tmp/host-secret-scan.$$"

# ---- 7. the installer can render its plan without root -----------------
if [ -x "$HERE/bin/homelab-install-daemons.sh" ] || [ -f "$HERE/bin/homelab-install-daemons.sh" ]; then
  plan=$(bash "$HERE/bin/homelab-install-daemons.sh" --dry-run 2>&1)
  if [ -n "$plan" ] && printf '%s\n' "$plan" | grep -q 'daemon'; then
    ok "--dry-run renders a plan ($(printf '%s\n' "$plan" | wc -l | tr -d ' ') lines)"
  else
    printf '%s\n' "$plan" | sed 's/^/    /'
    fail "--dry-run printed no plan"
  fi
  if printf '%s\n' "$plan" | grep -qi 'darwin\|macos'; then
    ok "--dry-run is portable (no launchctl call on this host)"
  else
    fail "--dry-run must not depend on macOS: CI is Linux"
  fi
fi

# ---- 8. the drill harness can list what it will do ---------------------
if [ -f "$HERE/bin/homelab-drill-session-loss.sh" ]; then
  drills=$(bash "$HERE/bin/homelab-drill-session-loss.sh" --list 2>&1)
  for want in session-loss kill restore; do
    printf '%s\n' "$drills" | grep -q -- "$want" && ok "drill --list mentions $want" || fail "drill --list does not mention $want"
  done
fi

# ---- 9. the installer resolves the right agent per service (GUL-619) ----
# The agents on the Air do not share the daemons' names: ai.hermes.gateway vs
# ...hermes-gateway, and io.paperclip.minio-proxy *also* matches "paperclip".
# A plain substring search therefore misses the gateway agent and retires the
# MinIO proxy's agent during the paperclip iteration - which is exactly how a
# first install would produce four daemons, no gateway, and two owners for the
# proxy. This runs against fixture filenames, needs no launchd, and is the
# regression guard for that.
fixture=$(mktemp -d "${TMPDIR:-/tmp}/host-tree-agents.XXXXXX")
for n in ai.hermes.gateway io.paperclip.server io.paperclip.minio-proxy ai.hermes.gemini-tunnel sh.brew.syncthing; do
  : >"$fixture/$n.plist"
done
# homelab-lib.sh ASSIGNS HOMELAB_AGENT_DIR, so the fixture path has to be set
# after sourcing or it is silently replaced by the real home directory.
# shellcheck source=../bin/homelab-lib.sh
. "$HERE/bin/homelab-lib.sh"
# shellcheck source=../bin/homelab-find-agent.sh
. "$HERE/bin/homelab-find-agent.sh"
HOMELAB_AGENT_DIR="$fixture"
export HOMELAB_AGENT_DIR
for pair in hermes-gateway:ai.hermes.gateway.plist \
            paperclip:io.paperclip.server.plist \
            minio-lan-proxy:io.paperclip.minio-proxy.plist \
            gemini-tunnel:ai.hermes.gemini-tunnel.plist \
            syncthing:sh.brew.syncthing.plist; do
  svc=${pair%%:*}; want=${pair#*:}
  got=$(find_agent_plists "$svc" | while IFS= read -r line; do basename "$line"; done | tr '\n' ' ')
  [ "$got" = "$want " ] && ok "agent map: $svc -> $want" \
    || fail "agent map: $svc resolved '$got', expected '$want ' (substring matching misses or cross-matches)"
done
rm -rf "$fixture"

printf '\n%s\n' "$([ "$RC" -eq 0 ] && echo 'PASS: host/paperclip-air tree is installable, single-owner and secret-free' || echo 'FAIL: host/paperclip-air tree')"
exit "$RC"
