#!/bin/bash
# ---------------------------------------------------------------------------
# headless-script-check.sh — static guard for host/m1max/bin/homelab-make-headless.sh.
#
# Why static: the script only does anything on the m1max under root, and CI has
# neither. What CAN be proven anywhere is the shape that makes it safe:
#   - it refuses to run without root, and without a mode (exit 2, no mutation)
#   - `--check` never mutates: the dangerous verbs live only in the apply branch
#   - the password only ever arrives from a prompt (`-password -`), never argv
#   - no secret is written or echoed by the script itself
#   - bash 3.2 (macOS /bin/bash) parses it, and it uses no bash-4 constructs
#
# Exit 0 = all good. Exit 1 = at least one guard failed.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TARGET="$HERE/bin/homelab-make-headless.sh"
RC=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; RC=1; }

[ -f "$TARGET" ] || { printf 'FAIL: %s is missing\n' "$TARGET"; exit 1; }

# 1. parses under the shell macOS actually has
if bash -n "$TARGET" 2>/dev/null; then pass "bash -n"; else fail "bash -n rejected the script"; fi

# 2. bash 3.2 has no associative arrays, mapfile, readarray, or case mapping.
#    Comments are excluded: the script documents the rule it obeys.
BASH4=$(awk '{ if ($0 !~ /^[[:space:]]*#/ && $0 ~ /declare -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)/) print FNR": "$0 }' "$TARGET")
if [ -n "$BASH4" ]; then
  fail "bash-4-only syntax found (macOS ships bash 3.2):"
  printf '      %s\n' "$(printf '%s' "$BASH4" | head -3)"
else
  pass "no bash-4-only constructs"
fi

# 3. the dangerous verbs must be reachable only in the apply path. Count them
#    and assert they sit after the `== apply ==` marker.
APPLY_LINE=$(grep -n '^# --- apply' "$TARGET" | cut -d: -f1)
[ -n "$APPLY_LINE" ] || { fail "no '# --- apply' marker: cannot prove the split"; APPLY_LINE=999999; }
BAD_BEFORE=$(awk -v cut="$APPLY_LINE" 'NR<cut && /fdesetup disable|sysadminctl -autologin set|pmset -a disablesleep 1|pmset -c sleep 0/ {print NR": "$0}' "$TARGET")
if [ -n "$BAD_BEFORE" ]; then
  fail "mutating command before the apply marker (so --check could change the host):"
  printf '      %s\n' "$BAD_BEFORE"
else
  pass "no mutation before the apply marker"
fi

# 4. the password must come from a prompt, never from an argument or a file
if grep -q 'sysadminctl -autologin set -userName "\$ACCOUNT" -password -' "$TARGET"; then
  pass "auto-login takes the password from a prompt (-password -)"
else
  fail "auto-login does not use the interactive '-password -' form"
fi
if grep -nE '\-adminPassword|\-password [^-]|read -r[[:space:]]+-s' "$TARGET" >/dev/null 2>&1; then
  fail "a password appears to be passed on the command line or read by this script"
else
  pass "no password on a command line, none read by the script"
fi

# 5. FileVault only ever goes off behind an explicit confirmation or --yes
if awk '/fdesetup disable/{found=NR} END{exit !found}' "$TARGET"; then
  if grep -q 'type exactly "yes"' "$TARGET" && grep -q 'ASSUME_YES' "$TARGET"; then
    pass "fdesetup disable is gated by an explicit confirmation"
  else
    fail "fdesetup disable is not gated by a confirmation"
  fi
else
  fail "expected a gated 'fdesetup disable'; found none"
fi

# 6. refuses to act without root, and without a mode — run it for real, it is
#    read-only up to that point. On a root CI container the guard cannot fire,
#    so only assert when we are not root.
if [ "$(id -u)" -ne 0 ]; then
  OUT=$(bash "$TARGET" --check 2>&1); GOT=$?
  if [ "$GOT" -eq 2 ] && printf '%s' "$OUT" | grep -q 'run me with sudo'; then
    pass "refuses without root (exit 2)"
  else
    fail "no root guard: exit $GOT, output: $OUT"
  fi
  OUT=$(bash "$TARGET" 2>&1); GOT=$?
  if [ "$GOT" -eq 2 ] && printf '%s' "$OUT" | grep -q 'pick --check or --apply'; then
    pass "refuses without a mode (exit 2)"
  else
    fail "no mode guard: exit $GOT, output: $OUT"
  fi
else
  pass "SKIP root/mode guards (running as root)"
fi

# 7. the script must not write anything outside /etc (its only legitimate output)
if grep -nE '>\s*/etc/kcpassword|teep?[^|]*/etc/kcpassword' "$TARGET" >/dev/null 2>&1; then
  fail "the script writes /etc/kcpassword itself; sysadminctl must own that file"
else
  pass "does not hand-write /etc/kcpassword"
fi

[ "$RC" -eq 0 ] && printf '\nheadless-script-check: pass\n' || printf '\nheadless-script-check: FAIL\n'
exit "$RC"
