#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Self-test for bin/kubectl-forward-probe.sh (GUL-728).
#
# The defect this guards: a port-forward that outlives the job that opened it.
# The test replaces kubectl with a fake that listens on the local port and
# blocks — the exact behaviour of the real thing — and then asserts the socket
# is gone after the probe exits in each of the ways that matter:
#
#   * the command succeeded          (exit 0, tunnel closed)
#   * the command failed             (its exit code kept, tunnel still closed)
#   * the script was SIGTERMed       (trap fires, tunnel closed)
#   * the local port was already busy (clear message, exit 2, nothing started)
#
# Runs on macOS (Air, bash 3.2) and on Linux CI: only bash, nc and python3.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROBE="$HERE/bin/kubectl-forward-probe.sh"

PASS=0
FAIL=0
ok() { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/probe-test.XXXXXX")
cleanup() {
  # Belt and braces: nothing this test started may survive it.
  pkill -f "$WORK/kubectl" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

[ -x "$PROBE" ] || { echo "FAIL probe script missing or not executable: $PROBE"; exit 1; }

# Fake kubectl: parses the <local>:<remote> argument and listens on it for ever,
# accepting any number of connections, like a real port-forward.
cat >"$WORK/kubectl" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in *:*) spec=$a ;; esac
done
exec python3 -c '
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(16)
while True:
    try:
        c, _ = s.accept()
        c.close()
    except OSError:
        break
' "${spec%%:*}"
FAKE
chmod +x "$WORK/kubectl"
export PATH="$WORK:$PATH"

listening() { nc -z 127.0.0.1 "$1" 2>/dev/null; }
free_port() {
  local p
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    p=$((20000 + RANDOM % 20000))
    listening "$p" || { echo "$p"; return 0; }
  done
  return 1
}
wait_free() { # $1 port — give the OS a moment to unwrap the socket
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    listening "$1" || return 0
    sleep 0.2
  done
  return 1
}

# --- 1. success: tunnel up, command ran, tunnel gone -----------------------
p=$(free_port)
"$PROBE" observability demo "$p:9090" -- sh -c "nc -z 127.0.0.1 $p" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "success: probe exits 0" || bad "success: probe exits 0 (got $rc)"
wait_free "$p" && ok "success: port $p released" || bad "success: port $p released"

# --- 2. failing command: exit code kept, tunnel gone ----------------------
p=$(free_port)
"$PROBE" observability demo "$p:9090" -- sh -c 'exit 7' >/dev/null 2>&1
rc=$?
[ "$rc" -eq 7 ] && ok "failure: command exit code 7 propagates" || bad "failure: command exit code 7 propagates (got $rc)"
wait_free "$p" && ok "failure: port $p released" || bad "failure: port $p released"

# --- 3. SIGTERM mid-run: trap cleans up -----------------------------------
p=$(free_port)
"$PROBE" observability demo "$p:9090" -- sleep 30 >/dev/null 2>&1 &
probe_pid=$!
sleep 1.5
wait_listening=0
listening "$p" && wait_listening=1
[ "$wait_listening" -eq 1 ] && ok "sigterm: tunnel is up before the signal" \
  || bad "sigterm: tunnel is up before the signal"

kill -TERM "$probe_pid" 2>/dev/null
wait "$probe_pid" 2>/dev/null
sleep 0.3
wait_free "$p" && ok "sigterm: port $p released after SIGTERM" || bad "sigterm: port $p released after SIGTERM"
if ps -axo command | grep -F "$WORK/kubectl" | grep -v grep >/dev/null; then
  bad "sigterm: no kubectl left behind"
else
  ok "sigterm: no kubectl left behind"
fi

# --- 4. busy port: refuse with a clear message, start nothing --------------
p=$(free_port)
python3 -c '
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(1)
time.sleep(10)
' "$p" &
squatter=$!
sleep 0.5
out=$("$PROBE" observability demo "$p:9090" -- true 2>&1)
rc=$?
kill -TERM "$squatter" 2>/dev/null
wait "$squatter" 2>/dev/null
[ "$rc" -eq 2 ] && ok "busy port: exits 2" || bad "busy port: exits 2 (got $rc)"
case "$out" in
  *"already in use"*) ok "busy port: message names the problem" ;;
  *) bad "busy port: message names the problem (got: $out)" ;;
esac

# --- 5. no leak survived the whole run ------------------------------------
if ps -axo command | grep -F "$WORK/kubectl" | grep -v grep >/dev/null; then
  bad "no fake kubectl survived the test run"
else
  ok "no fake kubectl survived the test run"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
