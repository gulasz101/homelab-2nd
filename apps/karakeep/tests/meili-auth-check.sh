#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-1182 (AC-3): the Meilisearch auth in the Karakeep release carries no
# value the chart does not define.
#
# Why: chart 0.32.0 let us point Meilisearch at an existing key with a PAIR of
# values, `existingMasterKeySecret` + `existingMasterKeySecretKey`. Chart
# 0.34.1 no longer defines the second one: it reads the master key straight out
# of the referenced Secret at a key it names itself, so leaving
# `existingMasterKeySecretKey` in our values silently does nothing - the worst
# kind of leftover, because it looks like it still works. The Secret named
# karakeep-app-secrets must keep an MEILI_MASTER_KEY key, which is the one the
# chart now expects.
#
# AC-3: for the `kind: HelmRelease` document(s) under apps/karakeep (test paths
#       skipped):
#         - spec.values.meilisearch.auth.existingMasterKeySecret is exactly
#           "karakeep-app-secrets", and
#         - spec.values.meilisearch.auth.existingMasterKeySecretKey is absent
#           (a null, an empty string or any leftover value fails), and
#         - a Secret named karakeep-app-secrets under apps/karakeep still has an
#           MEILI_MASTER_KEY key in stringData or data.
#       A scan that finds no HelmRelease or no such Secret fails loudly instead
#       of reporting PASS over an empty set.
#
# This check never decrypts and never prints a value: SOPS keeps the keys of a
# Secret in plaintext, so yq can answer "does this key exist" on the encrypted
# file. `sops -d` is forbidden in checks (CI has no age key) and printing a
# master key would be a leak.
#
# Discovered and run by scripts/check.sh (it globs */tests/*-check.sh); listed
# in no Kustomization, so Flux never sees it.
#
# Usage: bash apps/karakeep/tests/meili-auth-check.sh
# Exit:  0 = AC-3 passes, 1 = AC-3 fails, 2 = the check could not run (yq
#         missing)
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$ROOT" || exit 2

if [ -z "$(command -v yq)" ]; then
  printf 'meili-auth-check: yq is not on PATH - the check cannot run\n' >&2
  exit 2
fi

SCAN_ROOT=apps/karakeep
WANT_SECRET=karakeep-app-secrets
WANT_KEY=MEILI_MASTER_KEY
# yq v4 takes no --arg; strenv() reads these from the environment.
export WANT_SECRET WANT_KEY

# looksLikeTestPath from agents/factory-guard/policy.ts (CONTRACT.md point 6):
# fixtures living next to a check must never be read as production manifests.
is_test_path() {
  local lower base
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  base=${lower##*/}
  case "/$lower" in
    */tests/*|*/test/*) return 0 ;;
  esac
  case "$base" in
    *.test.*|*_test.*|test_*.py) return 0 ;;
  esac
  return 1
}

# One line per HelmRelease document:
# "<name>|<existingMasterKeySecret>|<type of existingMasterKeySecretKey>|<its value>".
# The type is "!!null" when the key does not exist at all.
auth_in() {
  yq -r 'select(.kind == "HelmRelease")
         | [(.metadata.name // ""),
            (.spec.values.meilisearch.auth.existingMasterKeySecret // "" | tostring),
            (.spec.values.meilisearch.auth.existingMasterKeySecretKey | type),
            (.spec.values.meilisearch.auth.existingMasterKeySecretKey // "" | tostring)]
         | join("|")' "$1"
}

# "true" when this file holds a Secret named $WANT_SECRET carrying $WANT_KEY in
# either stringData or data. Key names only - the values stay encrypted and are
# never read out.
secret_has_key() {
  yq -r '
      select(.kind == "Secret")
      | select((.metadata.name // "") == strenv(WANT_SECRET))
      | (((.stringData // {}) | has(strenv(WANT_KEY))) or ((.data // {}) | has(strenv(WANT_KEY))))' "$1"
}

releases=0
secret_found=0
secret_ok=0
broken=""
bad=""

while IFS= read -r f; do
  [ -n "$f" ] || continue
  is_test_path "$f" && continue
  grep -Eq '^kind: (HelmRelease|Secret)' "$f" || continue

  if grep -q '^kind: HelmRelease' "$f"; then
    rows=$(auth_in "$f" 2>&1) || {
      broken="$broken; $f: $(printf '%s' "$rows" | head -1)"
      continue
    }
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      IFS='|' read -r name secret stype svalue <<< "$row"
      releases=$((releases + 1))
      if [ "$secret" != "$WANT_SECRET" ]; then
        bad="$bad; $f ($name): meilisearch.auth.existingMasterKeySecret is '${secret:-<unset>}', want '$WANT_SECRET'"
      fi
      case "$stype" in
        '!!null')
          : # gone, as chart 0.34.1 requires
          ;;
        '!!str')
          if [ -n "$svalue" ]; then
            bad="$bad; $f ($name): meilisearch.auth.existingMasterKeySecretKey is still set ('$svalue') - chart 0.34.1 does not define it, delete the value"
          fi
          ;;
        *)
          bad="$bad; $f ($name): meilisearch.auth.existingMasterKeySecretKey is still set (yq type $stype) - chart 0.34.1 does not define it, delete the value"
          ;;
      esac
    done <<< "$rows"
  fi

  if grep -q '^kind: Secret' "$f"; then
    hits=$(secret_has_key "$f" 2>&1) || {
      broken="$broken; $f: $(printf '%s' "$hits" | head -1)"
      continue
    }
    while IFS= read -r hit; do
      [ "$hit" = "true" ] || continue
      secret_found=1
      secret_ok=1
    done <<< "$hits"
    # A Secret with the right name but no $WANT_KEY still counts as found.
    named=$(yq -r '
        select(.kind == "Secret")
        | select((.metadata.name // "") == strenv(WANT_SECRET))
        | "hit"' "$f")
    case "$named" in
      *hit*) secret_found=1 ;;
    esac
  fi
done < <(find "$SCAN_ROOT" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)

printf 'meili-auth-check: read %s HelmRelease document(s) and Secret %s under %s\n' \
  "$releases" "$WANT_SECRET" "$SCAN_ROOT" >&2

if [ -n "$broken" ]; then
  ac3="FAIL unreadable YAML${broken}"
  failed=1
elif [ "$releases" -eq 0 ]; then
  ac3="FAIL found no HelmRelease under $SCAN_ROOT - a scan that matches nothing cannot report PASS"
  failed=1
elif [ "$secret_found" -eq 0 ]; then
  ac3="FAIL found no Secret named $WANT_SECRET under $SCAN_ROOT"
  failed=1
elif [ "$secret_ok" -eq 0 ]; then
  ac3="FAIL Secret $WANT_SECRET has no $WANT_KEY key in stringData or data - the chart reads the master key from exactly that key"
  failed=1
elif [ -n "$bad" ]; then
  ac3="FAIL ${bad#; }"
  failed=1
else
  ac3="PASS"
  failed=0
fi

printf 'AC-3: %s\n' "$ac3"
exit "$failed"
