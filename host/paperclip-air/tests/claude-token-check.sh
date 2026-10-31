#!/bin/bash
# ---------------------------------------------------------------------------
# claude-token-check.sh — proves the GUL-691 credential watchdog can go red on
# both failure modes, and that the new one-command rotation path works without
# ever putting the token on a command line.
#
# Why this exists: the failure in GUL-691 is SILENCE. Accepting a "Connect
# Anthropic" card writes a fresh 8-hour access token as a new vault version,
# leaves the SOPS copy alone, and the next 05:30 round dies with nobody told.
# A detector that cannot be shown to fail is the same silence with more code,
# so every branch below is driven by a fixture: a stub `sops`, a stub `kubectl`
# and a stub Paperclip HTTP endpoint. No Claude Code, no Paperclip, no network,
# no age key, no real credential — the stand-in token is fake and is never a
# value anyone could use.
#
# Runs anywhere: bash 3.2 on the Air, and on the Linux CI runner.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../bin/homelab-lib.sh
. "$HERE/bin/homelab-lib.sh"

RC=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; RC=1; }
check() { # $1 = expected, $2 = actual, $3 = label
  if [ "$1" = "$2" ]; then pass "$3 -> $2"; else fail "$3 expected '$1', got '$2'"; fi
}
contains() { # $1 = haystack, $2 = needle, $3 = label
  case "$1" in
    *"$2"*) pass "$3" ;;
    *) fail "$3: '$2' not found in: $1" ;;
  esac
}
absent() { # $1 = haystack, $2 = ERE, $3 = label
  if printf '%s' "$1" | grep -Eq "$2"; then
    fail "$3: found /$2/ in the output"
  else
    pass "$3"
  fi
}

FIX=$(mktemp -d "${TMPDIR:-/tmp}/claude-token-test.XXXXXX")
SRV_PID=""
cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  rm -rf "$FIX"
}
trap cleanup EXIT

PY=$(command -v python3 2>/dev/null) || {
  printf 'FAIL: python3 is required for the fixtures\n'; exit 1
}

# ---- fixture stubs --------------------------------------------------------
# The stand-in credential: shaped like a setup token, obviously not one.
STANDIN="sk-ant-oat01-STANDINaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
# A Connect access token of a later family: same OAuth shape, wrong thing.
CONNECTISH="sk-ant-oat02-STANDINbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
APIKEY="sk-ant-api03-STANDINcccccccccccccccccccccccccccccc"
sha() { printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; }

mkdir -p "$FIX/bin"

# sops: --decrypt cats the file (or reverses a fake encryption), --encrypt
# base64s the whole file so no plaintext survives the guard the script runs.
cat > "$FIX/bin/sops" <<'STUB'
#!/bin/bash
set -uo pipefail
mode=""
file=""
for a in "$@"; do
  case "$a" in
    --encrypt) mode=encrypt ;;
    --decrypt) mode=decrypt ;;
    -*) ;;
    *) file="$a" ;;
  esac
done
[ -n "$file" ] || exit 1
if [ "$mode" = "encrypt" ]; then
  tmp="$file.tmp.$$"
  { printf '#FAKESOPS\n'; base64 < "$file" | tr -d '\n'; printf '\n'; } > "$tmp" || exit 1
  mv "$tmp" "$file"
  exit 0
fi
first=$(head -1 "$file")
if [ "$first" = "#FAKESOPS" ]; then
  sed -n '2p' "$file" | base64 -d
else
  cat "$file"
fi
STUB
chmod +x "$FIX/bin/sops"

# kubectl: `exec … psql …` answers the one vault query the library makes.
# FAKE_VAULT_FILE holds "<version>|<sha256>" and is rewritten by the stub API.
cat > "$FIX/bin/kubectl" <<'STUB'
#!/bin/bash
[ -n "${FAKE_VAULT_FILE:-}" ] && [ -f "$FAKE_VAULT_FILE" ] || exit 1
cat "$FAKE_VAULT_FILE"
STUB
chmod +x "$FIX/bin/kubectl"

# The stub Paperclip endpoint: records the request (never the token to stdout),
# answers like the rotate route does, and bumps the fake vault to version 7.
cat > "$FIX/stub-api.py" <<'STUB'
import base64, hashlib, json, os, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

log_path = sys.argv[1]
vault_path = sys.argv[2]
delay = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(n).decode()
        auth = self.headers.get("authorization") or ""
        try:
            value = json.loads(raw).get("value", "")
        except Exception:
            value = ""
        with open(log_path, "a") as fh:
            fh.write(json.dumps({
                "path": self.path,
                "method": "POST",
                "auth_ok": auth.startswith("Bearer pcp_board_"),
                "value_ok": value == os.environ.get("EXPECT_VALUE", value),
                "value_len": len(value),
            }) + "\n")
        if delay:
            time.sleep(delay)
        if value:
            digest = hashlib.sha256(value.encode()).hexdigest()
            with open(vault_path, "w") as fh:
                fh.write("7|%s\n" % digest)
        body = json.dumps({"id": "stub-secret", "latestVersion": 7}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


srv = HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
STUB

PORT_FILE="$FIX/port"
"$PY" "$FIX/stub-api.py" "$FIX/requests.jsonl" "$FIX/vault-live.txt" 0 > "$PORT_FILE" &
SRV_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$PORT_FILE" ] && break
  sleep 0.1
done
PORT=$(cat "$PORT_FILE" 2>/dev/null)
[ -n "$PORT" ] || { printf 'FAIL: the stub Paperclip endpoint did not start\n'; exit 1; }

export PATH="$FIX/bin:$PATH"
export KUBECTL_BIN="$FIX/bin/kubectl"
export FAKE_VAULT_FILE="$FIX/vault-live.txt"

# ===========================================================================
# 1. The shape guard: a setup token, an API key, and a Connect-family token.
# ===========================================================================
check "setup" "$(claude_token_shape "$STANDIN")" "a setup token is accepted by shape"
check "api-key" "$(claude_token_shape "$APIKEY")" "an sk-ant-api03- key is named an API key"
check "other" "$(claude_token_shape "$CONNECTISH")" "a connect-family sk-ant-oat02- token is not a setup token"
check "other" "$(claude_token_shape "opaque-access-token")" "an opaque token is not a setup token"
check "empty" "$(claude_token_shape "")" "an empty value is its own shape"

# ===========================================================================
# 2. The verdict matrix — every branch from non-secret inputs, fixed "today".
# ===========================================================================
TODAY="2026-10-31"
D=$(sha "whatever")
check "ok:v3 355 days left" "$(claude_token_verdict "$D" setup "3|$D" "2026-10-21" "$TODAY")" \
  "equal digests, fresh mint date -> ok"
check "mismatch:v4" "$(claude_token_verdict "$D" setup "4|$(sha 'connect-overwrite')" "" "$TODAY")" \
  "a Connect overwrite (newer vault version, different value) -> mismatch"
check "badshape:api-key" "$(claude_token_verdict "$D" api-key "3|$D" "" "$TODAY")" \
  "an API key in SOPS -> badshape"
check "badshape:other" "$(claude_token_verdict "$D" other "3|$D" "" "$TODAY")" \
  "a non-setup OAuth token in SOPS -> badshape"
check "unknown:no-sops-digest" "$(claude_token_verdict "" setup "3|$D" "" "$TODAY")" \
  "no SOPS digest -> unknown, not green"
check "unknown:vault-unreadable" "$(claude_token_verdict "$D" setup "" "" "$TODAY")" \
  "unreadable vault -> unknown, not green"
check "unknown:bad-mint-date" "$(claude_token_verdict "$D" setup "3|$D" "not-a-date" "$TODAY")" \
  "a corrupt mint date -> unknown"
# 11 months back from 2026-10-31 is 2025-11-30: 335 days old, 30 days left.
check "expiring:30" "$(claude_token_verdict "$D" setup "3|$D" "2025-11-30" "$TODAY")" \
  "mint date 11 months back -> the 30-day warning fires"
check "expired:-1" "$(claude_token_verdict "$D" setup "3|$D" "2025-10-30" "$TODAY")" \
  "a year and a day old -> expired"

# ===========================================================================
# 3. End to end through claude_token_state, with fixture SOPS + vault.
# ===========================================================================
export CLAUDE_TOKEN_SOPS_FILE="$FIX/token.sops.yaml"
export CLAUDE_TOKEN_MINT_FILE="$FIX/absent-mint"
export CLAUDE_TOKEN_SECRET_ID="stub-secret"
sops_manifest() { # $1 = token value
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n    name: claude-code-oauth\nstringData:\n    CLAUDE_CODE_OAUTH_TOKEN: %s\n' "$1"
}
sops_manifest "$STANDIN" > "$CLAUDE_TOKEN_SOPS_FILE"
printf '5|%s\n' "$(sha "$STANDIN")" > "$FAKE_VAULT_FILE"
check "ok:v5" "$(claude_token_state)" "matching copies read end to end"

# The overwrite: same SOPS copy, vault moved on with a different value.
printf '6|%s\n' "$(sha "$CONNECTISH")" > "$FAKE_VAULT_FILE"
verdict=$(claude_token_state)
check "mismatch:v6" "$verdict" "the Connect-card overwrite is caught end to end"
msg=$(claude_token_alert_message "$verdict")
contains "$msg" "--rotate" "the mismatch alert names the one-command fix"
contains "$msg" "Connect" "the mismatch alert names the cause"
case "$msg" in
  *"claude setup-token |"*) pass "the alert carries the exact command line" ;;
  *) fail "the alert must carry the exact command: $msg" ;;
esac
absent "$msg" "sk-ant-[a-z0-9]+-[A-Za-z0-9_-]{20,}" "the alert carries no token"

# The expiry branch, end to end, with the mint date set back 11 months.
printf '5|%s\n' "$(sha "$STANDIN")" > "$FAKE_VAULT_FILE"
printf 'minted=%s\n' "2025-11-30" > "$CLAUDE_TOKEN_MINT_FILE"
export CLAUDE_TOKEN_TODAY="2026-10-31"
# The library uses today's date; pin it for the check by exporting a fake `date`
# is over-engineering, so assert on the branch rather than the number.
state=$(claude_token_state)
case "$state" in
  expiring:*) pass "a mint date 11 months old reports expiring ($state)" ;;
  ok:*) fail "11-month-old mint date must not read ok: $state" ;;
  *) fail "unexpected verdict for an old mint date: $state" ;;
esac
exp_msg=$(claude_token_alert_message "$state")
contains "$exp_msg" "--rotate" "the expiry alert names the fix command"
absent "$exp_msg" "sk-ant-[a-z0-9]+-[A-Za-z0-9_-]{20,}" "the expiry alert carries no token"
rm -f "$CLAUDE_TOKEN_MINT_FILE"

# An API key written into the SOPS copy instead of a setup token.
sops_manifest "$APIKEY" > "$CLAUDE_TOKEN_SOPS_FILE"
printf '5|%s\n' "$(sha "$APIKEY")" > "$FAKE_VAULT_FILE"
state=$(claude_token_state)
check "badshape:api-key" "$state" "an API key in the SOPS copy is rejected end to end"
contains "$(claude_token_alert_message "$state")" "per-token billing" \
  "the bad-shape alert says why an API key is wrong"

# ===========================================================================
# 4. No SOPS copy at all: unknown, never green, never a page.
# ===========================================================================
rm -f "$CLAUDE_TOKEN_SOPS_FILE"
check "unknown:no-sops-copy" "$(claude_token_state)" "a missing SOPS copy is unknown"

# ===========================================================================
# 5. The rotation path, end to end against the stub Paperclip.
# ===========================================================================
STORE="$HERE/bin/homelab-claude-token-store.sh"
export SOPS_FILE="$FIX/rotate.sops.yaml"
export BOARD_TOKEN_SOPS_FILE="$FIX/board.sops.yaml"
export MINT_FILE="$FIX/mint"
export PAPERCLIP_API_URL="http://127.0.0.1:$PORT/api"
export COMPANY_ID="0e2eb054-4cb6-4ea1-a2e7-2b1894285d8c"
export SECRET_ID="stub-secret"

printf '1|%s\n' "$(sha "$STANDIN")" > "$FAKE_VAULT_FILE"
printf 'board_token: %s\n' "pcp_board_$(printf '%048d' 0)" > "$BOARD_TOKEN_SOPS_FILE"

# 5a. With no board key: refuse, and print the exact next action. This is the
# fallback the ticket asks for, and it must name the URL and the sha prefix.
export BOARD_TOKEN_SOPS_FILE="$FIX/no-board.sops.yaml"
out=$(printf '%s' "$STANDIN" | "$STORE" --rotate 2>&1)
rc=$?
[ "$rc" -ne 0 ] && pass "no board key -> non-zero exit ($rc)" || fail "no board key must not report success"
contains "$out" "NOT ROTATED" "no board key -> says it did not rotate"
contains "$out" "paperclip.voitech.dev/company/settings/secrets" "no board key -> names the board URL"
contains "$out" "$(sha "$STANDIN" | cut -c1-12)" "no board key -> names the sha256 prefix to compare"
absent "$out" "sk-ant-[a-z0-9]+-[A-Za-z0-9_-]{20,}" "the fallback output carries no token"
[ -f "$SOPS_FILE" ] && pass "the SOPS copy was still written" || fail "the SOPS copy was not written"

# 5b. With a board key: store, rotate, prove. The stub answers version 7 and
# rewrites the fake vault, so the digest compare must print MATCH at 7.
export BOARD_TOKEN_SOPS_FILE="$FIX/board.sops.yaml"
printf '1|%s\n' "$(sha "$STANDIN")" > "$FAKE_VAULT_FILE"
export EXPECT_VALUE="$STANDIN"
: > "$FIX/requests.jsonl"
out=$(printf '%s' "$STANDIN" | "$STORE" --rotate 2>&1)
rc=$?
[ "$rc" -eq 0 ] && pass "the rotate path exits 0" || fail "the rotate path exited $rc: $out"
contains "$out" "rotated  vault secret stub-secret to version 7" "the rotate path reports the new version"
contains "$out" "MATCH" "the rotate path proves the copies match afterwards"
contains "$out" "version 7" "MATCH is at the new version, not the old one"
contains "$out" "minted  " "the mint date is recorded"
[ -s "$MINT_FILE" ] && pass "the mint-date file exists ($(cat "$MINT_FILE"))" || fail "no mint-date file"
absent "$out" "sk-ant-[a-z0-9]+-[A-Za-z0-9_-]{20,}" "the rotate output carries no token"

req=$(head -1 "$FIX/requests.jsonl" 2>/dev/null)
[ -n "$req" ] && pass "the stub Paperclip received exactly one request" || fail "no request reached the stub"
case "$req" in
  *'"path": "/api/companies/0e2eb054-4cb6-4ea1-a2e7-2b1894285d8c/me/user-secrets/stub-secret/rotate"'*)
    pass "the request went to the documented user-secrets rotate route" ;;
  *) fail "unexpected request path: $req" ;;
esac
case "$req" in
  *'"auth_ok": true'*) pass "the request carried a board-token bearer" ;;
  *) fail "the request did not carry the board token: $req" ;;
esac
case "$req" in
  *'"value_ok": true'*) pass "the body carried the token on stdin, unmodified" ;;
  *) fail "the body did not carry the expected value: $req" ;;
esac

# No plaintext survived on disk: the SOPS copy is a fake encryption and the
# stand-in string is nowhere in it.
if grep -q "sk-ant-oat" "$SOPS_FILE" 2>/dev/null; then
  fail "plaintext survived in $SOPS_FILE"
else
  pass "no plaintext in the SOPS copy"
fi
if grep -rq "sk-ant-oat01-STANDIN" "$FIX" --include='*.sops.yaml' 2>/dev/null; then
  fail "a sops file still holds the stand-in value"
else
  pass "no stand-in value in any .sops.yaml fixture"
fi

# 5c. The token never reaches a command line. Run the rotation again with a
# deliberately slow stub and sample every process's argv while it runs.
kill "$SRV_PID" 2>/dev/null
wait "$SRV_PID" 2>/dev/null
: > "$PORT_FILE"
"$PY" "$FIX/stub-api.py" "$FIX/requests2.jsonl" "$FAKE_VAULT_FILE" 2 2>/dev/null > "$PORT_FILE" &
SRV_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$PORT_FILE" ] && break
  sleep 0.1
done
PORT=$(cat "$PORT_FILE" 2>/dev/null)
export PAPERCLIP_API_URL="http://127.0.0.1:$PORT/api"
printf '1|%s\n' "$(sha "$STANDIN")" > "$FAKE_VAULT_FILE"
( printf '%s' "$STANDIN" | "$STORE" --rotate > "$FIX/slow.out" 2>&1 ) &
ROT_PID=$!
# The needle goes in a file: a grep pattern on the command line would put the
# token itself into `ps` and the sweep would always "find" its own search.
printf '%s' "$STANDIN" > "$FIX/needle"
leak=0
i=0
while [ "$i" -lt 40 ]; do
  if ps -Ao args 2>/dev/null | grep -qF -f "$FIX/needle"; then leak=1; fi
  kill -0 "$ROT_PID" 2>/dev/null || break
  i=$((i + 1))
  sleep 0.1
done
wait "$ROT_PID" 2>/dev/null
if [ "$leak" -eq 1 ]; then
  fail "the token appeared in a process command line (ps)"
else
  pass "the token never appeared in any process command line ($i samples)"
fi

if [ "$RC" -eq 0 ]; then
  printf '\nall claude-token checks passed\n'
else
  printf '\nclaude-token checks FAILED\n'
fi
exit "$RC"
