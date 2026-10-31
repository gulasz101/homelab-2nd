#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# H2-336 / AC3+AC4 evidence: run the exporter that ships in the ConfigMap, for
# real, and prove the two alert paths by deliberate failure.
#
# This is NOT part of scripts/check.sh: it needs the public internet and it takes
# about a minute. It is named "-drill" and not "-check" on purpose, so CI never
# picks it up.
#
#   ./apps/host-watch/tests/drill-live-probe.sh
#
# What it shows, in order:
#   1. three live-ish targets probed against the real URLs;
#   2. a deliberately broken target whose consecutive-failure counter reaches the
#      alert threshold of 3 (the value the PromQL rule keys on);
#   3. the heartbeat accepted with the right token, rejected with the wrong one,
#      and the metrics that the heartbeat alerts read afterwards.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APP=$(cd "$HERE/.." && pwd)
WORK=$(mktemp -d)
PORT=${DRILL_PORT:-19115}
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

ok()   { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; RC=1; }
RC=0

kubectl kustomize "$APP" > "$WORK/render.yaml" || { echo "cannot render apps/host-watch"; exit 1; }
yq eval 'select(.kind == "ConfigMap") | select(.metadata.name | test("^host-watch-server")) | .data["server.py"]' \
  "$WORK/render.yaml" > "$WORK/server.py"
[ -s "$WORK/server.py" ] || { echo "no server.py in the render"; exit 1; }
printf 'using the shipped server.py (%s lines)\n\n' "$(wc -l < "$WORK/server.py" | tr -d ' ')"

BAD_TOKEN="wrong-token"
GOOD_TOKEN="drill-token-1234567890"
printf '%s' "$GOOD_TOKEN" > "$WORK/token"
chmod 600 "$WORK/token"

HOSTWATCH_PROBE_TARGETS="paperclip=https://paperclip.voitech.dev,chat=https://chat.voitech.dev,broken=https://this-host-does-not-exist.invalid/" \
HOSTWATCH_PROBE_INTERVAL=2 \
HOSTWATCH_PROBE_TIMEOUT=5 \
HOSTWATCH_FAIL_THRESHOLD=3 \
HOSTWATCH_HEARTBEAT_GRACE_SECONDS=420 \
HOSTWATCH_TOKEN_FILE="$WORK/token" \
HOSTWATCH_LISTEN_PORT="$PORT" \
python3 "$WORK/server.py" > "$WORK/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 40); do
  curl -sf -m 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
  sleep 0.5
done
printf '%s\n' "--- server log ---"; sed 's/^/    /' "$WORK/server.log"

printf '\n--- 1. metrics after the first probe rounds ---\n'
sleep 9
curl -s "http://127.0.0.1:$PORT/metrics" | grep -E '^hostwatch_probe_(success|status_code|consecutive_failures)' | sed 's/^/    /'

live_fail=$(curl -s "http://127.0.0.1:$PORT/metrics" | awk '/^hostwatch_probe_consecutive_failures\{target="paperclip"\}/{print $2}')
live_chat=$(curl -s "http://127.0.0.1:$PORT/metrics" | awk '/^hostwatch_probe_consecutive_failures\{target="chat"\}/{print $2}')
broken=$(curl -s "http://127.0.0.1:$PORT/metrics" | awk '/^hostwatch_probe_consecutive_failures\{target="broken"\}/{print $2}')
[ "${broken:-0}" -ge 3 ] && ok "deliberately broken target reached ${broken} consecutive failures (alert expr: >= 3)" || fail "broken target only reached ${broken:-?} failures"
[ "${live_fail:-1}" -eq 0 ] && ok "paperclip.voitech.dev stays at 0 failures while the broken target fails" || fail "paperclip.voitech.dev shows ${live_fail} failures"
[ "${live_chat:-1}" -eq 0 ] && ok "chat.voitech.dev stays at 0 failures" || fail "chat.voitech.dev shows ${live_chat} failures"

printf '\n--- 2. heartbeat, wrong token (must be rejected) ---\n'
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/heartbeat" \
  -H 'Content-Type: application/json' -H "X-Heartbeat-Token: $BAD_TOKEN" \
  --data '{"host":"drill","ts":1,"components":{}}')
[ "$code" = "401" ] && ok "wrong token -> HTTP 401" || fail "wrong token -> HTTP $code (expected 401)"

printf '\n--- 3. heartbeat, right token (must be accepted) ---\n'
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/heartbeat" \
  -H 'Content-Type: application/json' -H "X-Heartbeat-Token: $GOOD_TOKEN" \
  --data "{\"host\":\"paperclip-air\",\"ts\":$(date +%s),\"console_user\":\"paperclip\",\"components\":{\"paperclip\":true,\"hermes-gateway\":false}}")
[ "$code" = "202" ] && ok "right token -> HTTP 202" || fail "right token -> HTTP $code (expected 202)"

printf '\n--- 4. metrics the heartbeat alerts read ---\n'
curl -s "http://127.0.0.1:$PORT/metrics" | grep -E '^hostwatch_(heartbeat_(configured|last_seen_timestamp_seconds|age_seconds|rejected_total|accepted_total)|component_up)' | sed 's/^/    /'
conf=$(curl -s "http://127.0.0.1:$PORT/metrics" | awk '/^hostwatch_heartbeat_configured /{print $2}')
age=$(curl -s "http://127.0.0.1:$PORT/metrics" | awk '/^hostwatch_heartbeat_age_seconds /{print $2}')
[ "$conf" = "1" ] && ok "hostwatch_heartbeat_configured == 1 (heartbeat armed)" || fail "configured = ${conf:-?}"
awk -v a="${age:-9999}" 'BEGIN{exit !(a < 420)}' && ok "heartbeat age ${age}s < 420s grace window" || fail "heartbeat age ${age:-?}s is already stale"
rejected=$(curl -s "http://127.0.0.1:$PORT/metrics" | awk '/^hostwatch_heartbeat_rejected_total /{print $2}')
[ "${rejected:-0}" -ge 1 ] && ok "rejected counter recorded the bad token (${rejected})" || fail "rejected counter did not move"
curl -s "http://127.0.0.1:$PORT/metrics" | grep -q 'hostwatch_component_up{component="hermes-gateway"} 0' \
  && ok "per-component health exported (hermes-gateway 0 from the payload)" || fail "component metric missing"

printf '\n%s\n' "$([ "$RC" -eq 0 ] && echo 'PASS: probe + heartbeat proven by deliberate failure' || echo 'FAIL: live drill')"
exit "$RC"
