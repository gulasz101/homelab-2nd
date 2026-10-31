#!/bin/bash
# ---------------------------------------------------------------------------
# homelab-claude-token-store.sh — put the Claude Code setup token in SOPS and
# prove it is the same value Paperclip's vault will hand to `claude`.
#
# Why this exists (GUL-642, ADR-110): a Paperclip *Anthropic subscription*
# connection exports exactly one credential to the adapter —
# CLAUDE_CODE_OAUTH_TOKEN — and keeps no refresh token and no write-back path.
# An access token from `claude auth login` therefore dies after ~8 h and every
# run after that fails `claude_auth_required`. A `claude setup-token` value is
# a drop-in for the same env var and lives about a year.
#
# This script never prints, echoes or logs the token. It writes the SOPS copy,
# then compares SHA-256 digests (Paperclip stores sha256(utf8 value) in
# company_secret_versions.value_sha256) so a mismatch is visible without the
# value ever leaving the vault.
#
# Usage:
#   claude setup-token | bin/homelab-claude-token-store.sh          # store + compare
#   bin/homelab-claude-token-store.sh --verify                      # compare only
#
# Exit codes: 0 stored/verified and matching, 1 mismatch or error,
#             2 not the expected token shape.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=./homelab-lib.sh
. "$HERE/bin/homelab-lib.sh"

SOPS_FILE=${SOPS_FILE:-$HOME/claude-code-oauth.sops.yaml}
AGE_RECIPIENT=${AGE_RECIPIENT:-age195fednlfd8q35tvyvf7umlseu4ez37k2m2d0wjawmje6nr9kzgyquhau9s}
KUBE_NS=${KUBE_NS:-paperclip}
KUBE_DB_POD=${KUBE_DB_POD:-paperclip-db-1}
SECRET_ID=${SECRET_ID:-}          # pin it if the lookup is ever ambiguous

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# The Claude Code setup token is a long-lived OAuth token shaped sk-ant-oat01-…
# Shape check only: no secret material is echoed on failure.
TOKEN_SHAPE='^sk-ant-oat01-[A-Za-z0-9_-]{20,}$'

psql_q() {
  kubectl exec -n "$KUBE_NS" "$KUBE_DB_POD" -c postgres -- \
    psql -U postgres -d paperclip -At -F'|' -c "$1" 2>/dev/null
}

# Resolve the user-scoped ai.credential secret of the Claude subscription
# connection, unless the caller pinned one.
resolve_secret() {
  if [ -n "$SECRET_ID" ]; then printf '%s' "$SECRET_ID"; return 0; fi
  psql_q "select id from company_secrets
            where key like 'user.ai_%' and name ilike '%claude%'
            order by latest_version desc limit 1;" | head -1
}

vault_digest() { # $1 = secret id -> "<version>|<sha256>"
  psql_q "select v.version, v.value_sha256 from company_secret_versions v
            where v.secret_id = '$1' and v.revoked_at is null
            order by v.version desc limit 1;"
}

verify() { # $1 = expected sha256 of the local SOPS value
  local id vdigest version stored rc
  id=$(resolve_secret)
  [ -n "$id" ] || die "could not resolve the Claude ai.credential secret in Paperclip"
  vdigest=$(vault_digest "$id")
  [ -n "$vdigest" ] || die "no live version for secret $id"
  version=${vdigest%%|*}
  stored=${vdigest##*|}
  if [ "$stored" = "$1" ]; then
    say "MATCH  vault secret $id version $version has the same sha256 as the SOPS copy"
    return 0
  fi
  printf 'MISMATCH  vault secret %s version %s (sha256 %s…)\n' \
    "$id" "$version" "${stored:0:12}"
  printf '          SOPS copy sha256 %s…\n' "${1:0:12}"
  return 1
}

local_digest() { # reads the SOPS file, writes nothing
  [ -f "$SOPS_FILE" ] || die "$SOPS_FILE does not exist yet"
  command -v sops >/dev/null || die "sops is not installed"
  local plain
  plain=$(sops --decrypt "$SOPS_FILE" 2>/dev/null) || die "sops could not decrypt $SOPS_FILE"
  # Extract the token without printing it.
  printf '%s\n' "$plain" \
    | awk -F': *' '/CLAUDE_CODE_OAUTH_TOKEN:/ {print $2; exit}' \
    | tr -d '"'"'"'\r\n' \
    | shasum -a 256 | awk '{print $1}'
}

case "${1:-store}" in
  --verify|verify)
    d=$(local_digest) || exit 1
    [ -n "$d" ] || die "the SOPS file has no CLAUDE_CODE_OAUTH_TOKEN entry"
    verify "$d"; exit $?
    ;;
  store|--store) ;;
  *) die "unknown argument: $1 (use --verify or pipe the token on stdin)" ;;
esac

command -v sops >/dev/null || die "sops is not installed"
[ -t 0 ] && die "pipe the token on stdin: claude setup-token | $0"

TOKEN=$(cat)
TOKEN=${TOKEN//[$'\r\n']/}
[ -n "$TOKEN" ] || die "empty input"
if ! printf '%s' "$TOKEN" | grep -Eq "$TOKEN_SHAPE"; then
  die "that is not a Claude Code setup token (expected sk-ant-oat01-…).
     'claude auth login' hands you an 8-hour access token; run 'claude setup-token' instead."
fi

umask 077
{
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n'
  printf '    name: claude-code-oauth\n    namespace: paperclip\ntype: Opaque\nstringData:\n'
  printf '    CLAUDE_CODE_OAUTH_TOKEN: %s\n' "$TOKEN"
} > "$SOPS_FILE" || die "could not write $SOPS_FILE"

if ! sops --encrypt --in-place --age "$AGE_RECIPIENT" \
      --encrypted-regex '^(data|stringData)$' "$SOPS_FILE" >/dev/null 2>&1; then
  rm -f "$SOPS_FILE"
  die "sops encryption failed; the plaintext file was removed"
fi

# The encryption must have covered the value: nothing shaped like the token may
# survive on disk.
if grep -q 'sk-ant-oat01-' "$SOPS_FILE"; then
  rm -f "$SOPS_FILE"
  die "encryption left plaintext behind; file removed"
fi

d=$(printf '%s' "$TOKEN" | shasum -a 256 | awk '{print $1}')
unset TOKEN
say "wrote $SOPS_FILE (encrypted, $(wc -c <"$SOPS_FILE" | tr -d ' ') bytes)"
verify "$d"
