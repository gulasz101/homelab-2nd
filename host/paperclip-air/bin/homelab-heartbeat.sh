#!/bin/bash
# ---------------------------------------------------------------------------
# homelab-heartbeat.sh — the only check that survives the Mac being logged out,
# asleep or off (H2-336).
#
# Runs as a USER LaunchAgent (deliberately: a lost session must look like a lost
# host to the off-host receiver, ADR-098). Every 60 s it probes the local
# services, then POSTs one JSON heartbeat to the in-cluster receiver
# (apps/host-watch, LAN NodePort). The receiver alerts when beats stop arriving
# for 7 minutes, or when a component says it is down.
#
# This is also how the Hermes API gets watched: the gateway binds 127.0.0.1:8642
# on the Air and no public hostname fronts it, so only a process *on the Air*
# can see it. That is this script.
#
# Token: /Users/paperclip/.config/homelab/heartbeat-token (0600, generated once,
# same value as the SOPS secret the receiver mounts). Never inline it here — this
# repo is public.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=homelab-lib.sh
. "$SCRIPT_DIR/homelab-lib.sh"

log() { printf '%s %s\n' "$(now_h)" "$*" >&2; }

URL="$HOMELAB_HEARTBEAT_URL_DEFAULT"
TOKEN_FILE="$HOMELAB_HEARTBEAT_TOKEN_FILE"
if [ -r "$HOMELAB_HEARTBEAT_ENV" ]; then
  # shellcheck disable=SC1090
  . "$HOMELAB_HEARTBEAT_ENV"
  URL="${HOMELAB_HEARTBEAT_URL:-$URL}"
  TOKEN_FILE="${HOMELAB_HEARTBEAT_TOKEN_FILE:-$TOKEN_FILE}"
fi

if [ ! -r "$TOKEN_FILE" ]; then
  # Fail closed and loudly: a heartbeat the receiver cannot trust is worse than
  # no heartbeat, because it would mask a real outage.
  log "no heartbeat token at $TOKEN_FILE — refusing to send (see RUNBOOK.md, 'seeding the heartbeat')"
  exit 1
fi
TOKEN=$(tr -d '\r\n' < "$TOKEN_FILE")
if [ -z "$TOKEN" ]; then
  log "heartbeat token file is empty — refusing to send"
  exit 1
fi

components=""
down=""
for svc in $HOMELAB_SERVICES; do
  if svc_up "$svc"; then
    value=1
  else
    value=0
    down="$down $svc"
  fi
  components="${components}\"$svc\":$value,"
done
# Trim the trailing comma; an empty object is valid JSON too.
components="${components%,}"

# GUL-680: leaked `kubectl ... port-forward` processes. Hermes runs them as
# `bash -lic set +m; kubectl …`; when the run ends (or the 180 s tool timeout
# fires) the kubectl child survives, gets reparented to launchd, and the crash
# recovery checkpoint re-adopts it on every gateway start — so it lives forever.
# Nothing legitimate needs a forward older than 15 minutes (durable access is a
# NodePort or a LAN service), so age is the whole test. Report only, never kill.
forwards=$(ps -axo etime=,command= 2>/dev/null | awk '
function secs(t,  d,a,p,n){ d=0; if (index(t,"-")>0){ split(t,a,"-"); d=a[1]+0; t=a[2] } n=split(t,p,":"); if (n==3) return d*86400+p[1]*3600+p[2]*60+p[3]; if (n==2) return d*86400+p[1]*60+p[2]; return d*86400+p[1] }
/kubectl/ && /port-forward/ && !/bash/ && !/awk/ { if (secs($1) > 900) n++ }
END { print n+0 }')

payload=$(printf '{"host":"paperclip-air","ts":%s,"console_user":"%s","components":{%s},"leaks":{"kubectl_port_forward":%s}}' \
  "$(now_s)" "$(console_owner)" "$components" "$forwards")
[ "$forwards" -gt 0 ] && log "leak: $forwards kubectl port-forward process(es) older than 15 min — see GUL-680"


code=$(curl -s -o /tmp/homelab-heartbeat.out -m 10 -w '%{http_code}' \
  -X POST "$URL" \
  -H 'Content-Type: application/json' \
  -H "X-Heartbeat-Token: $TOKEN" \
  --data "$payload" 2>/dev/null || echo 000)

case "$code" in
  2??) [ -n "$down" ] && log "heartbeat accepted, components down:$down" ;;
  401|403) log "heartbeat REJECTED ($code): the token here and the receiver's SOPS secret disagree" ;;
  000) log "heartbeat could not reach $URL (LAN/Netbird down?)" ;;
  *) log "heartbeat got HTTP $code from $URL" ;;
esac
[ "$code" = "200" ] || [ "$code" = "202" ] || [ "$code" = "204" ]
