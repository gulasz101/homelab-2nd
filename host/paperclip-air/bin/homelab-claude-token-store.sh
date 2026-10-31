#!/bin/bash
# ---------------------------------------------------------------------------
# homelab-claude-token-store.sh — put the Claude Code setup token in SOPS, put
# it into Paperclip's vault, and prove the two copies are the same value.
#
# Why this exists (GUL-642, GUL-691, ADR-110): a Paperclip *Anthropic
# subscription* connection exports exactly one credential to the adapter —
# CLAUDE_CODE_OAUTH_TOKEN — and keeps no refresh token and no write-back path.
# An access token from `claude auth login` therefore dies after ~8 h and every
# run after that fails `claude_auth_required`. A `claude setup-token` value is
# a drop-in for the same env var and lives about a year.
#
# This script never prints, echoes or logs the token, and never puts it on a
# command line where `ps` could see it. It writes the SOPS copy, then compares
# SHA-256 digests (Paperclip stores sha256(utf8 value) in
# company_secret_versions.value_sha256) so a mismatch is visible without the
# value ever leaving the vault.
#
# Usage:
#   claude setup-token | bin/homelab-claude-token-store.sh            # store + compare
#   claude setup-token | bin/homelab-claude-token-store.sh --rotate   # store + rotate vault + prove
#   bin/homelab-claude-token-store.sh --rotate                        # rotate the stored SOPS value only
#   bin/homelab-claude-token-store.sh --verify                        # compare only
#   bin/homelab-claude-token-store.sh --store-board-key               # store the board API key (stdin)
#   bin/homelab-claude-token-store.sh --record-mint [YYYY-MM-DD]      # age the credential (metadata only)
#
# `--record-mint` exists for the manual fallback in RUNBOOK §5b: when the vault
# is rotated by hand (no board key, or another machine), nothing on this host
# sees the new value, so the watchdog's 30-day expiry warning has nothing to
# age. It writes the date only, never the token, and defaults to today, UTC.
#
# `--rotate` needs an owner-scoped Paperclip board API key in SOPS. Create one
# in the Paperclip UI (your user -> API keys), then
#   printf '%s' '<key>' | bin/homelab-claude-token-store.sh --store-board-key
# It rotates the *user-scoped* `ai.credential` secret — the value the Anthropic
# connection hands to `claude`. An agent key cannot do it (the route calls
# assertBoard); a board key belonging to the owner can. Code evidence:
# @paperclipai/server dist/routes/secrets.js:678-683,
# dist/routes/authz.js:23-27 and dist/middleware/auth.js:239-253.
#
# Exit codes: 0 stored/verified and matching, 1 mismatch or error,
#             2 not the expected token shape.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=./homelab-lib.sh
. "$HERE/bin/homelab-lib.sh"

SOPS_FILE=${SOPS_FILE:-$HOME/claude-code-oauth.sops.yaml}
BOARD_TOKEN_SOPS_FILE=${BOARD_TOKEN_SOPS_FILE:-$HOME/paperclip-board-token.sops.yaml}
AGE_RECIPIENT=${AGE_RECIPIENT:-age195fednlfd8q35tvyvf7umlseu4ez37k2m2d0wjawmje6nr9kzgyquhau9s}
KUBE_NS=${KUBE_NS:-paperclip}
KUBE_DB_POD=${KUBE_DB_POD:-paperclip-db-1}
SECRET_ID=${SECRET_ID:-}          # pin it if the lookup is ever ambiguous
COMPANY_ID=${COMPANY_ID:-$CLAUDE_TOKEN_COMPANY_ID}
API_URL=${PAPERCLIP_API_URL:-http://127.0.0.1:3100/api}
API_URL=${API_URL%/}
BOARD_URL=${PAPERCLIP_BOARD_URL:-https://paperclip.voitech.dev}
MINT_FILE=${MINT_FILE:-$CLAUDE_TOKEN_MINT_FILE}
VAULT_VERSION=

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

psql_q() {
  local kc
  kc=$(claude_token_kubectl) || die "kubectl not found (set KUBECTL_BIN)"
  "$kc" exec -n "$KUBE_NS" "$KUBE_DB_POD" -c postgres -- \
    psql -U postgres -d paperclip -At -F'|' -c "$1" 2>/dev/null
}

# Resolve the user-scoped ai.credential secret of the Claude subscription
# connection, unless the caller pinned one.
resolve_secret() {
  if [ -n "$SECRET_ID" ]; then printf '%s' "$SECRET_ID"; return 0; fi
  psql_q "select s.id from company_secrets s
            where s.scope = 'user' and s.company_id = '$COMPANY_ID'
              and s.name ilike '%claude%'
            order by s.updated_at desc limit 1;" | head -1
}

vault_digest() { # $1 = secret id -> "<version>|<sha256>"
  psql_q "select v.version, v.value_sha256 from company_secret_versions v
            where v.secret_id = '$1' and v.revoked_at is null
            order by v.version desc limit 1;"
}

verify() { # $1 = expected sha256 of the local SOPS value
  local id vdigest version stored
  id=$(resolve_secret)
  [ -n "$id" ] || die "could not resolve the Claude ai.credential secret in Paperclip"
  vdigest=$(vault_digest "$id")
  [ -n "$vdigest" ] || die "no live version for secret $id"
  version=${vdigest%%|*}
  stored=${vdigest##*|}
  VAULT_VERSION=$version
  if [ "$stored" = "$1" ]; then
    say "MATCH  vault secret $id version $version has the same sha256 as the SOPS copy"
    return 0
  fi
  printf 'MISMATCH  vault secret %s version %s (sha256 %s…)\n' \
    "$id" "$version" "${stored:0:12}"
  printf '          SOPS copy sha256 %s…\n' "${1:0:12}"
  return 1
}

local_value() { # reads the SOPS file, prints the token on stdout only
  [ -f "$SOPS_FILE" ] || die "$SOPS_FILE does not exist yet"
  command -v sops >/dev/null || die "sops is not installed"
  local plain
  plain=$(sops --decrypt "$SOPS_FILE" 2>/dev/null) || die "sops could not decrypt $SOPS_FILE"
  printf '%s\n' "$plain" \
    | awk -F': *' '/CLAUDE_CODE_OAUTH_TOKEN:/ {print $2; exit}' \
    | tr -d '"'"'"'\r\n'
}

local_digest() { # reads the SOPS file, writes nothing
  local val
  val=$(local_value)
  [ -n "$val" ] || die "the SOPS file has no CLAUDE_CODE_OAUTH_TOKEN entry"
  printf '%s' "$val" | shasum -a 256 | awk '{print $1}'
}

board_key() { # reads the board key out of SOPS; prints it on stdout only
  [ -f "$BOARD_TOKEN_SOPS_FILE" ] || return 0
  command -v sops >/dev/null || die "sops is not installed"
  sops --decrypt "$BOARD_TOKEN_SOPS_FILE" 2>/dev/null \
    | awk -F': *' '/^board_token:/ {print $2; exit}' \
    | tr -d '"'"'"''"'"' \r\n'
}

# A real calendar day, not just a YYYY-MM-DD shape: 2026-02-30 is refused.
mint_date_valid() { # $1 = YYYY-MM-DD
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  local py
  if py=$(command -v python3 2>/dev/null); then
    "$py" - "$1" >/dev/null 2>&1 <<'PY'
import sys
from datetime import date
date.fromisoformat(sys.argv[1])
PY
    return $?
  fi
  return 0
}

# THE writer of the mint file — one path, so the store/--rotate flow and the
# manual fallback cannot disagree about the shape. $1 = YYYY-MM-DD; empty means
# today, UTC. Metadata only: never the token.
write_mint() {
  local d=${1:-$(date -u +%Y-%m-%d)}
  if ! mint_date_valid "$d"; then
    printf 'ERROR: %s is not a date (expected YYYY-MM-DD)\n' "$d" >&2
    return 1
  fi
  mkdir -p "$(dirname "$MINT_FILE")" 2>/dev/null
  if ! printf 'minted=%s\n' "$d" > "$MINT_FILE"; then
    printf 'ERROR: could not write %s\n' "$MINT_FILE" >&2
    return 1
  fi
  chmod 644 "$MINT_FILE" 2>/dev/null
  say "minted  $MINT_FILE records $d (metadata only, no token)"
}

# The store/--rotate path: the token was minted now. A failed write is a
# warning, not a failure — the credential itself is already stored and proven.
record_mint() {
  write_mint "$(date -u +%Y-%m-%d)" \
    || say "WARNING: could not record the mint date in $MINT_FILE"
}

# Store $1 (already shape-checked) in SOPS. Plaintext never survives: the file
# is written 0600, encrypted in place, then grepped for the token prefix.
store_sops() {
  local token="$1"
  umask 077
  {
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n'
    printf '    name: claude-code-oauth\n    namespace: paperclip\ntype: Opaque\nstringData:\n'
    printf '    CLAUDE_CODE_OAUTH_TOKEN: %s\n' "$token"
  } > "$SOPS_FILE" || die "could not write $SOPS_FILE"

  if ! sops --encrypt --in-place --age "$AGE_RECIPIENT" \
        --encrypted-regex '^(data|stringData)$' "$SOPS_FILE" >/dev/null 2>&1; then
    rm -f "$SOPS_FILE"
    die "sops encryption failed; the plaintext file was removed"
  fi

  if grep -q 'sk-ant-oat' "$SOPS_FILE"; then
    rm -f "$SOPS_FILE"
    die "encryption left plaintext behind; file removed"
  fi
  say "wrote $SOPS_FILE (encrypted, $(wc -c <"$SOPS_FILE" | tr -d ' ') bytes)"
}

# Rotate the vault value without the value ever reaching argv: the bearer goes
# in through a curl config on a file descriptor, the JSON body through stdin.
rotate_vault() { # $1 = sha256 of the token (only used for the final compare)
  local id key body resp version
  id=$(resolve_secret)
  if [ -z "$id" ]; then
    die "could not resolve the Claude ai.credential secret in Paperclip
     fix: set SECRET_ID=<secret id> from $BOARD_URL/company/settings/secrets"
  fi
  key=$(board_key)
  if [ -z "$key" ]; then
    say ""
    say "NOT ROTATED: no board API key in $BOARD_TOKEN_SOPS_FILE."
    say "One-time setup: create a board API key in the Paperclip UI"
    say "  $BOARD_URL/company/settings/secrets   (your user -> API keys -> Create)"
    say "then store it: printf '%s' '<key>' | $0 --store-board-key"
    say ""
    say "Or rotate by hand: open $BOARD_URL/company/settings/secrets, rotate the"
    say "Claude subscription secret, and check the value's sha256 starts ${1:0:12}"
    return 1
  fi
  case "$key" in
    pcp_board_*) ;;
    *) die "the value in $BOARD_TOKEN_SOPS_FILE is not a Paperclip board API key (pcp_board_…)" ;;
  esac

  command -v curl >/dev/null || die "curl is not installed"
  body=$(printf '{"value":"%s"}' "$(local_value)")
  [ -n "$body" ] || die "no token to rotate"

  resp=$(printf '%s' "$body" \
    | curl -sS --max-time 30 \
        -K <(printf 'header = "Authorization: Bearer %s"\n' "$key") \
        -H 'Content-Type: application/json' \
        --data @- \
        "$API_URL/companies/$COMPANY_ID/me/user-secrets/$id/rotate" 2>&1)
  unset body key

  case "$resp" in
    *latestVersion*)
      version=$(printf '%s' "$resp" | python3 -c \
        'import json,sys; d=json.load(sys.stdin); print(d.get("latestVersion",""))' 2>/dev/null)
      [ -n "$version" ] || die "Paperclip answered without a version number; nothing proven"
      say "rotated  vault secret $id to version $version via $API_URL"
      ;;
    *)
      printf 'ERROR: rotation failed. Response: %s\n' "${resp:0:300}" >&2
      return 1
      ;;
  esac

  verify "$1" || return 1
  if [ -n "${version:-}" ] && [ -n "${VAULT_VERSION:-}" ] && [ "${VAULT_VERSION}" -lt "$version" ] 2>/dev/null; then
    die "the vault still reads version ${VAULT_VERSION} after rotating to $version"
  fi
  return 0
}

case "${1:-store}" in
  --verify|verify)
    d=$(local_digest) || exit 1
    verify "$d"; exit $?
    ;;
  --store-board-key|store-board-key)
    command -v sops >/dev/null || die "sops is not installed"
    [ -t 0 ] && die "pipe the board key on stdin: printf '%s' '<key>' | $0 --store-board-key"
    KEY=$(cat)
    KEY=${KEY//[$'\r\n']/}
    case "$KEY" in
      pcp_board_*) ;;
      *) die "that is not a Paperclip board API key (expected pcp_board_…)" ;;
    esac
    umask 077
    printf 'board_token: %s\n' "$KEY" > "$BOARD_TOKEN_SOPS_FILE" \
      || die "could not write $BOARD_TOKEN_SOPS_FILE"
    if ! sops --encrypt --in-place --age "$AGE_RECIPIENT" "$BOARD_TOKEN_SOPS_FILE" >/dev/null 2>&1; then
      rm -f "$BOARD_TOKEN_SOPS_FILE"
      die "sops encryption failed; the plaintext file was removed"
    fi
    if grep -q 'pcp_board_' "$BOARD_TOKEN_SOPS_FILE"; then
      rm -f "$BOARD_TOKEN_SOPS_FILE"
      die "encryption left plaintext behind; file removed"
    fi
    unset KEY
    say "wrote $BOARD_TOKEN_SOPS_FILE (encrypted)"
    exit 0
    ;;
  --record-mint|record-mint)
    write_mint "${2:-}" || exit 1
    exit 0
    ;;
  --rotate|rotate)
    if [ -t 0 ]; then
      # No stdin: rotate the value already stored in SOPS.
      d=$(local_digest) || exit 1
      rotate_vault "$d" || exit 1
      exit 0
    fi
    ROTATE=1
    ;;
  store|--store) ROTATE=0 ;;
  *) die "unknown argument: $1 (use --verify, --rotate, --record-mint or --store-board-key)" ;;
esac

command -v sops >/dev/null || die "sops is not installed"
[ -t 0 ] && die "pipe the token on stdin: claude setup-token | $0"

TOKEN=$(cat)
TOKEN=${TOKEN//[$'\r\n']/}
[ -n "$TOKEN" ] || die "empty input"
case "$(claude_token_shape "$TOKEN")" in
  setup) ;;
  api-key)
    die "that is an Anthropic API key (sk-ant-api03-…), not a Claude Code setup token.
     Rotating it in would move the agent onto per-token billing. Run 'claude setup-token'." ;;
  *)
    die "that is not a Claude Code setup token (expected sk-ant-oat01-…).
     'claude auth login' hands you an 8-hour access token; run 'claude setup-token' instead." ;;
esac

store_sops "$TOKEN"
d=$(printf '%s' "$TOKEN" | shasum -a 256 | awk '{print $1}')
unset TOKEN
record_mint

if [ "${ROTATE:-0}" = "1" ]; then
  rotate_vault "$d" || exit 1
else
  verify "$d" || exit 1
fi
