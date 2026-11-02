#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Probe one or more URLs with curl and a DESCRIPTIVE User-Agent.
#
# Why this exists (GUL-785): Cloudflare's Browser Integrity Check — a zone
# setting, on by default — refuses the default Python `urllib` User-Agent
# (`Python-urllib/<ver>`) with `HTTP 403` and the body `error code: 1010`.
# curl, `requests` and `httpx` all pass against the same host at the same
# second. So a 403 from urllib is a CLIENT problem until curl agrees, and one
# wrong issue (GUL-726) was filed on that misreading.
#
# Full measurements, verdict and the Cloudflare-side finding:
#   docs/cloudflare-urllib-403.md
#
# Usage:
#   scripts/probe-url.sh https://chat.voitech.dev/ [more urls ...]
#   UA='my-app/1.0' scripts/probe-url.sh https://host/
#
# Exit: 0 when every URL answered below 400, 1 when one did not, 2 on bad usage.
# ---------------------------------------------------------------------------
set -uo pipefail

UA=${UA:-homelab-probe/1.0 (+homelab-2nd http probe)}
TIMEOUT=${TIMEOUT:-15}

if [ $# -eq 0 ]; then
  echo "usage: $0 <url> [url ...]" >&2
  exit 2
fi

rc=0
for url in "$@"; do
  # curl's own failure (DNS, refused, timeout) prints 000 and a message on stderr.
  out=$(curl -sS -o /dev/null -m "$TIMEOUT" -A "$UA" \
    -w '%{http_code} %{time_total}' "$url" 2>&1) || true
  code=${out%% *}
  secs=${out#* }
  case "$code" in
    2??|3??) ;;
    *) rc=1 ;;
  esac
  case "$code" in
    [0-9][0-9][0-9]) ;;
    000) ;;
    *) code=000 ;;   # curl's own failure text, not a status line
  esac
  printf '%s  %6ss  %s\n' "$code" "$secs" "$url"
done
exit $rc
