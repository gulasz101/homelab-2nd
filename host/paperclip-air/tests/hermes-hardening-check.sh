#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-1147 / red stage: two Hermes hardening fixes, one check.
#
# Why the check exists (spec: "heartbeat probes the gateway on /health; Hermes
# daemons get umask 077"):
#
#   1. svc_health_path hermes-gateway mapped to /v1/models, a route that needs
#      an API key. The heartbeat probes it every 60 s, gets a 401, and the
#      gateway log fills with `API server rejected invalid API key ...
#      user_agent='curl/8.7.1'`. svc_up() counts anything under 500 as alive, so
#      the probe never reported the noise: it "worked" while lying in the log.
#      /health on 8642 answers 200 with no key (measured on the Air 2026-11-09).
#   2. Both Hermes LaunchDaemons set no Umask, so launchd's default 022 applies
#      and Hermes writes 0644 files under ~/.hermes — some of them holding API
#      keys. 63 decimal is 077 octal: owner-only for group and other.
#
# The check is portable on purpose: it runs on the Air (bash 3.2) and in CI on
# Linux, so it sources the library in a subshell and parses the plists with
# python3's plistlib. It never needs launchctl, plutil or a booted macOS, and it
# writes nothing inside the repo.
#
# Contract (agents/factory/CONTRACT.md point 2): exactly one `AC-n: PASS` or
# `AC-n: FAIL <reason>` line per AC, exit 0 when both pass, 1 otherwise.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN="$HERE/bin"
LIB="$BIN/homelab-lib.sh"
GATEWAY_PLIST="$HERE/launchd/daemons/dev.voitech.homelab.hermes-gateway.plist"
DASHBOARD_PLIST="$HERE/launchd/daemons/dev.voitech.homelab.hermes-dashboard.plist"
# The key-bearing route the probe must no longer touch. Held in a variable so
# this assertion is the only place in the tree that still spells it out.
GATEWAY_OLD_PROBE="/v1/models"
GATEWAY_PROBE="/health"

RC=0

# ---- AC-1: the heartbeat probes the gateway on a keyless route ------------
# Sourced in a subshell: homelab-lib.sh sets globals and the caller's shell must
# not inherit them. An unreadable library is a FAIL, not a silent pass.
ac1_reason=""
if [ ! -f "$LIB" ]; then
  ac1_reason="bin/homelab-lib.sh is missing from the tree"
else
  probe=$( . "$LIB"; svc_health_path hermes-gateway )
  probe_status=$?
  if [ "$probe_status" -ne 0 ]; then
    ac1_reason="svc_health_path hermes-gateway exited $probe_status (the function is gone or broken)"
  elif [ "$probe" != "$GATEWAY_PROBE" ]; then
    ac1_reason="svc_health_path hermes-gateway prints '$probe', expected '$GATEWAY_PROBE'"
  fi
fi
# No script under bin/ may still mention the 401-ing route: a second caller
# would put the same noise back in the gateway log even with the map fixed.
if [ -z "$ac1_reason" ]; then
  offenders=$(grep -rlF -- "$GATEWAY_OLD_PROBE" "$BIN")
  if [ -n "$offenders" ]; then
    # One line only: collapse the file list and any newlines into commas.
    ac1_reason="bin/ still mentions $GATEWAY_OLD_PROBE in $(printf '%s' "$offenders" | tr '\n' ' ' | sed 's/ *$//')"
  fi
fi
if [ -z "$ac1_reason" ]; then
  printf 'AC-1: PASS\n'
else
  printf 'AC-1: FAIL %s\n' "$(printf '%s' "$ac1_reason" | tr '\n' ' ')"
  RC=1
fi

# ---- AC-2: both Hermes daemons run with umask 077 (63 decimal) ------------
# 63 is what plistlib hands back for <integer>63</integer>; a missing key, a
# string "63" or octal 077 are all wrong shapes and must fail loudly.
ac2_reason=$(python3 - "$GATEWAY_PLIST" "$DASHBOARD_PLIST" <<'PY'
import os
import plistlib
import sys

problems = []
for path in sys.argv[1:3]:
    name = os.path.basename(path)
    if not os.path.isfile(path):
        problems.append('%s is missing' % name)
        continue
    try:
        with open(path, 'rb') as fh:
            plist = plistlib.load(fh)
    except Exception as exc:                       # unparseable is a failure
        problems.append('%s is not a readable plist (%s)' % (name, exc))
        continue
    umask = plist.get('Umask')
    if umask != 63:
        problems.append('%s has Umask %r, expected the integer 63 (octal 077)' % (name, umask))
print('; '.join(problems))
PY
)
if [ -z "$ac2_reason" ]; then
  printf 'AC-2: PASS\n'
else
  printf 'AC-2: FAIL %s\n' "$(printf '%s' "$ac2_reason" | tr '\n' ' ')"
  RC=1
fi

exit "$RC"
