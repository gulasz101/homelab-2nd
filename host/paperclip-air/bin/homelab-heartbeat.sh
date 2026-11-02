#!/bin/bash
# ---------------------------------------------------------------------------
# homelab-heartbeat.sh — beats every 60 s so an off-host receiver can tell
# "the host is gone" from "a component on the host is gone" (H2-336, GUL-732).
#
# Runs as a SYSTEM LaunchDaemon (UserName=paperclip, ADR-113). It used to be a
# user LaunchAgent that deliberately died with the GUI session (ADR-098); on a
# headless appliance that meant it never ran at all, so the outage signal was a
# permanent alert nobody read and the leak counter never reached the cluster.
# The sender now survives the session and REPORTS it instead:
#
#   console_user   who owns /dev/console (root == nobody logged in)
#   gui_session    1 when an Aqua session exists at all (gui/<uid> printable)
#   gui_expected   1 when THIS host is supposed to have a session (host config)
#
# The receiver turns one beat into two alerts: silence = host gone
# (HostWatchHeartbeatMissing), a beat with gui_session 0 on a host that expects
# one = session gone (HostWatchSessionGone).
#
# Every 60 s it probes the local services, counts leaked `kubectl port-forward`
# children, then POSTs one JSON heartbeat to the in-cluster receiver
# (apps/host-watch, LAN NodePort). This is also how the Hermes API gets watched:
# the gateway binds 127.0.0.1:8642 on the Air and no public hostname fronts it,
# so only a process *on the Air* can see it. That is this script.
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

# GUL-732 / ADR-113: report the session, do not die with it. `console_user` is
# the device owner, not `who` — a logged-out Mac keeps a stale utmp entry, and
# /dev/console owned by root is the reliable "nobody is logged in" answer.
# `gui_session` is 1 when an Aqua session exists at all; gui/<uid> is not
# printable when there is none. `gui_expected` comes from the host's own config
# (HOMELAB_GUI_EXPECTED in heartbeat.env): the Air is a headless appliance and
# expects 0, a Mac that is supposed to have somebody in front of it expects 1.
console=$(console_owner)
uid=$(appliance_uid)
gui_session=0
if [ -n "$console" ] && [ "$console" != "root" ] && [ "$console" != "unknown" ]; then
  gui_session=1
elif [ -n "$uid" ] && launchctl print "gui/$uid" >/dev/null 2>&1; then
  # Console owner is nobody but the Aqua domain exists (screen locked, fast user
  # switching). Either signal alone is enough: a session is a session.
  gui_session=1
fi
gui_expected=${HOMELAB_GUI_EXPECTED:-0}
case "$gui_expected" in
  1|true|TRUE|yes) gui_expected=1 ;;
  *) gui_expected=0 ;;
esac

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

payload=$(printf '{"host":"paperclip-air","ts":%s,"console_user":"%s","gui_session":%s,"gui_expected":%s,"components":{%s},"leaks":{"kubectl_port_forward":%s}}' \
  "$(now_s)" "$console" "$gui_session" "$gui_expected" "$components" "$forwards")
[ "$forwards" -gt 0 ] && log "leak: $forwards kubectl port-forward process(es) older than 15 min — see GUL-680"
[ "$gui_expected" -eq 1 ] && [ "$gui_session" -eq 0 ] \
  && log "session gone: nobody owns /dev/console and gui/$uid does not exist, on a host that expects a session"


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
