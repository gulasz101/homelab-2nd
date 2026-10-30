#!/usr/bin/env bash
# cf-access-proof.sh — prove (or disprove) that the scoped Cloudflare API token
# in ~/cloudflare-api.sops.yaml can create Cloudflare Access applications, and
# leave nothing behind.
#
#   ./cf-access-proof.sh          # probe only: no app is created
#   ./cf-access-proof.sh --proof  # create -> verify -> delete a throwaway app
#
# Exit codes: 0 pass, 3 token lacks Access: Apps and Policies Edit, 1 other.
# The token value is never printed. See GUL-580 / ADR-032.
set -uo pipefail

CREDS="${CF_CREDS_FILE:-$HOME/cloudflare-api.sops.yaml}"
API="https://api.cloudflare.com/client/v4"
PROOF=0
[[ "${1:-}" == "--proof" ]] && PROOF=1

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v sops >/dev/null || die "sops not installed"
command -v jq   >/dev/null || die "jq not installed"
[[ -f "$CREDS" ]] || die "missing $CREDS"

getfield() { sops -d --extract "[\"stringData\"][\"$1\"]" "$CREDS" 2>/dev/null; }
TOKEN=$(getfield cf-api-token) || die "cannot decrypt $CREDS (check the age identity)"
ACC=$(getfield cf-account-id)
[[ -n "$TOKEN" && -n "$ACC" ]] || die "cf-api-token / cf-account-id empty in $CREDS"

cfa() { # cfa METHOD PATH [BODY] -> sets HTTP + BODY_OUT
  local m=$1 p=$2 b=${3:-}
  local out
  if [[ -n "$b" ]]; then
    out=$(curl -s -w '\n%{http_code}' -X "$m" \
      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d "$b" "$API$p")
  else
    out=$(curl -s -w '\n%{http_code}' -X "$m" \
      -H "Authorization: Bearer $TOKEN" "$API$p")
  fi
  HTTP=${out##*$'\n'}
  BODY_OUT=${out%$'\n'*}
}

printf '== 1. token verify ==\n'
cfa GET /user/tokens/verify
[[ "$HTTP" == 200 ]] || die "token verify answered HTTP $HTTP"
printf 'token active\n'

printf '== 2. read Access apps ==\n'
cfa GET "/accounts/$ACC/access/apps"
[[ "$HTTP" == 200 ]] || die "cannot even read Access apps (HTTP $HTTP)"
printf 'read OK, %s app(s) on the account\n' "$(jq -r '(.result // []) | length' <<<"$BODY_OUT")"

printf '== 3. write capability on Access apps ==\n'
# An empty body cannot create anything: an authorised call answers 400 (name
# required), an unauthorised one answers 403 / 1010 auth.forbidden.
cfa POST "/accounts/$ACC/access/apps" '{}'
if [[ "$HTTP" == 403 ]] && grep -q '1010' <<<"$BODY_OUT"; then
  printf 'MISSING SCOPE: 403 auth.forbidden (1010)\n'
  cat <<'EOM'

  Rotate the token in the dashboard and add ACCOUNT permissions:
    Access: Apps and Policies  -> Edit
    Access: Service Tokens     -> Edit   (only needed for non-browser clients)
  Keep: Zone DNS Edit, Zone Read, Account Cloudflare Tunnel Edit/Read,
        Access: Apps and Policies Read.
  Then: sops ~/cloudflare-api.sops.yaml   (update stringData.cf-api-token)
EOM
  exit 3
fi
[[ "$HTTP" == 400 ]] || die "unexpected answer to the write probe: HTTP $HTTP $(head -c 300 <<<"$BODY_OUT")"
printf 'write allowed (validation error as expected: %s)\n' \
  "$(jq -r '[.errors[]?.message] | join("; ")' <<<"$BODY_OUT")"

[[ "$PROOF" == 1 ]] || { printf '\nPROBE PASS — run with --proof to create, verify and delete a real app.\n'; exit 0; }

TS=$(date +%Y%m%d%H%M%S)
NAME="andrz-proof-$TS"
HOST="proof-$TS.voitech.dev"

printf '== 4. create throwaway app %s ==\n' "$NAME"
cfa POST "/accounts/$ACC/access/apps" \
  "{\"name\":\"$NAME\",\"domain\":\"$HOST\",\"type\":\"self_hosted\",\"session_duration\":\"24h\"}"
jq -e '.success == true' <<<"$BODY_OUT" >/dev/null \
  || die "create failed: $(head -c 400 <<<"$BODY_OUT")"
APP_ID=$(jq -r '.result.id' <<<"$BODY_OUT")
printf 'created %s for %s\n' "$APP_ID" "$HOST"

printf '== 5. verify it exists ==\n'
cfa GET "/accounts/$ACC/access/apps/$APP_ID"
[[ "$HTTP" == 200 ]] || die "created app not readable (HTTP $HTTP)"
[[ "$(jq -r '.result.name' <<<"$BODY_OUT")" == "$NAME" ]] || die "read back a different app"
printf 'read back OK\n'

printf '== 6. delete it ==\n'
# Cloudflare answers 202 Accepted for an async delete, so 200 is not the only
# "worked" code; the only proof is the object disappearing.
cfa DELETE "/accounts/$ACC/access/apps/$APP_ID"
[[ "$HTTP" == 200 || "$HTTP" == 202 ]] || die "delete failed (HTTP $HTTP) — DELETE IT BY HAND: $APP_ID"
printf 'delete accepted (HTTP %s)\n' "$HTTP"
gone=0
for _ in 1 2 3 4 5 6; do
  sleep 2
  cfa GET "/accounts/$ACC/access/apps/$APP_ID"
  if [[ "$HTTP" == 404 ]]; then gone=1; break; fi
done
[[ "$gone" == 1 ]] || die "app still present 12s after delete (HTTP $HTTP) — CHECK $APP_ID"
printf 'gone (404 confirmed)\n\nPROOF PASS — the token can create Access applications, nothing left behind.\n'
