#!/bin/bash
# ---------------------------------------------------------------------------
# kubectl-forward-probe.sh — one command against a cluster Service through a
# kubectl port-forward that CANNOT outlive the script. (GUL-680, GUL-728)
#
# Why this exists. `(kubectl port-forward svc/x 19091:9090 &)` looks like the
# cheap way to reach a ClusterIP from the Air: the subshell exits, the next
# command in the same tool call does its curl, done. But `kubectl port-forward`
# never exits on its own. When the subshell dies the kubectl child is orphaned
# straight to launchd (ppid 1), keeps its local port, and is invisible to the
# Hermes process registry because nothing registered it. Two of those ran for
# 20 hours on the Air; the same shape had already happened in GUL-680.
#
# The rule this encodes: a port-forward is a child of the script that opened it,
# and the script cleans it up whatever happens — success, failure, Ctrl-C,
# SIGTERM. Same pattern as `defer close()` / `trap ... EXIT` / `finally`.
#
# Usage:
#   kubectl-forward-probe.sh <namespace> <service> <local-port>:<remote-port> \
#       -- <command> [args...]
#
# Example:
#   kubectl-forward-probe.sh observability prometheus-stack-kube-prom-prometheus \
#       19091:9090 -- sh -c 'curl -sf http://127.0.0.1:19091/api/v1/rules > rules.json'
#
# Exit status: the command's own exit code. 2 = the local port is already taken
# (usually a leaked forward from earlier — the error names the check to run);
# 3 = the tunnel never came up (kubectl's own message is printed);
# 64 = bad usage.
# ---------------------------------------------------------------------------
set -uo pipefail

usage() {
  sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
}

[ "$#" -ge 5 ] || usage

namespace=$1
service=$2
ports=$3
shift 3
[ "${1:-}" = "--" ] && shift
[ "$#" -gt 0 ] || { echo "kubectl-forward-probe: no command given after --" >&2; exit 64; }

local_port=${ports%%:*}
case "$local_port" in
  '' | *[!0-9]*)
    echo "kubectl-forward-probe: '$ports' is not <local-port>:<remote-port>" >&2
    exit 64
    ;;
esac

# A port that already answers is almost always an earlier leak. Say that out
# loud: kubectl's own "address already in use" arrives four seconds later and
# tells you nothing about who owns the port.
if nc -z 127.0.0.1 "$local_port" 2>/dev/null; then
  {
    echo "kubectl-forward-probe: 127.0.0.1:$local_port is already in use."
    echo "  find the owner before opening another forward:"
    echo "  lsof -nP -iTCP:$local_port -sTCP:LISTEN"
    echo "  ps -axo pid,ppid,etime,command | grep '[p]ort-forward'"
  } >&2
  exit 2
fi

log=$(mktemp "${TMPDIR:-/tmp}/kubectl-forward-probe.XXXXXX")
kubectl -n "$namespace" port-forward "svc/$service" "$ports" >"$log" 2>&1 &
forward_pid=$!

cleanup() {
  if [ -n "${forward_pid:-}" ] && kill -0 "$forward_pid" 2>/dev/null; then
    kill -TERM "$forward_pid" 2>/dev/null
    n=0
    while kill -0 "$forward_pid" 2>/dev/null && [ "$n" -lt 10 ]; do
      sleep 0.2
      n=$((n + 1))
    done
    kill -KILL "$forward_pid" 2>/dev/null
  fi
  wait "$forward_pid" 2>/dev/null
  rm -f "$log"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# kubectl prints "Forwarding from 127.0.0.1:PORT" and only then listens, so poll
# the socket instead of sleeping a guessed number of seconds.
ready=0
n=0
while [ "$n" -lt 40 ]; do
  if nc -z 127.0.0.1 "$local_port" 2>/dev/null; then
    ready=1
    break
  fi
  if ! kill -0 "$forward_pid" 2>/dev/null; then
    echo "kubectl-forward-probe: kubectl exited before the tunnel was up:" >&2
    sed 's/^/  /' "$log" >&2
    exit 3
  fi
  sleep 0.25
  n=$((n + 1))
done

if [ "$ready" -ne 1 ]; then
  echo "kubectl-forward-probe: 127.0.0.1:$local_port never started listening:" >&2
  sed 's/^/  /' "$log" >&2
  exit 3
fi

"$@"
rc=$?
exit "$rc"
