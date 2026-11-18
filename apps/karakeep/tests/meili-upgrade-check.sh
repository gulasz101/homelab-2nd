#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-1182 (AC-2): the Karakeep release sets
# meilisearch.environment.MEILI_UPGRADE_DB=true, so the existing Meilisearch
# database (v1.13.0, written by chart 0.32.0) is migrated in place by the
# v1.55.0 engine that chart 0.34.1 ships.
#
# Why: Meilisearch refuses to open a database directory written by another
# engine version - it exits with "Your database version (1.13.0) is
# incompatible with your current engine version (1.55.0)". The engine's own
# escape hatch is MEILI_UPGRADE_DB=true, which tells it to run the experimental
# in-place dump/import migration on first boot instead of bailing out.
# Without it the upgrade crash-loops and karakeep loses search.
#
# AC-2: the `kind: HelmRelease` document(s) under apps/karakeep (test paths
#       skipped) set spec.values.meilisearch.environment.MEILI_UPGRADE_DB to a
#       truthy value: boolean true, or the string "true" (the chart renders
#       values into container env, where both arrive as "true"). A missing key,
#       a null, `false`, or any other value fails. A scan that finds no
#       HelmRelease at all fails loudly instead of reporting PASS over an
#       empty set.
#
# Parsing is yq, not grep: the env var must sit under the meilisearch subchart
# values, not in the karakeep container's env list, and only the parsed path can
# tell those apart.
#
# Discovered and run by scripts/check.sh (it globs */tests/*-check.sh); listed
# in no Kustomization, so Flux never sees it.
#
# Usage: bash apps/karakeep/tests/meili-upgrade-check.sh
# Exit:  0 = AC-2 passes, 1 = AC-2 fails, 2 = the check could not run (yq
#         missing)
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$ROOT" || exit 2

if [ -z "$(command -v yq)" ]; then
  printf 'meili-upgrade-check: yq is not on PATH - the check cannot run\n' >&2
  exit 2
fi

SCAN_ROOT=apps/karakeep

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
# "<name>|<type of MEILI_UPGRADE_DB>|<its value as a string>". The type is
# "!!null" when the path does not exist, which is how a missing key is told
# apart from an explicit `false`.
upgrade_flags_in() {
  yq -r 'select(.kind == "HelmRelease")
         | [(.metadata.name // ""),
            (.spec.values.meilisearch.environment.MEILI_UPGRADE_DB | type),
            (.spec.values.meilisearch.environment.MEILI_UPGRADE_DB | tostring)]
         | join("|")' "$1"
}

releases=0
broken=""
bad=""

while IFS= read -r f; do
  [ -n "$f" ] || continue
  is_test_path "$f" && continue
  grep -q '^kind: HelmRelease' "$f" || continue
  rows=$(upgrade_flags_in "$f" 2>&1) || {
    broken="$broken; $f: $(printf '%s' "$rows" | head -1)"
    continue
  }
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS='|' read -r name type value <<< "$row"
    releases=$((releases + 1))
    case "$type" in
      '!!null')
        bad="$bad; $f ($name): spec.values.meilisearch.environment.MEILI_UPGRADE_DB is not set - the v1.13.0 database cannot be opened by the v1.55.0 engine"
        continue
        ;;
      '!!bool')
        [ "$value" = "true" ] && continue
        bad="$bad; $f ($name): MEILI_UPGRADE_DB is $value, want true"
        continue
        ;;
      '!!str')
        # The chart writes values into container env, where "true" and true are
        # the same thing; accept the quoted form.
        if [ "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" = "true" ]; then
          continue
        fi
        bad="$bad; $f ($name): MEILI_UPGRADE_DB is '$value', want true"
        continue
        ;;
      *)
        bad="$bad; $f ($name): MEILI_UPGRADE_DB is $value (yq type $type), want true"
        continue
        ;;
    esac
  done <<< "$rows"
done < <(find "$SCAN_ROOT" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)

printf 'meili-upgrade-check: read %s HelmRelease document(s) under %s\n' \
  "$releases" "$SCAN_ROOT" >&2

if [ -n "$broken" ]; then
  ac2="FAIL unreadable HelmRelease YAML${broken}"
  failed=1
elif [ "$releases" -eq 0 ]; then
  ac2="FAIL found no HelmRelease under $SCAN_ROOT - a scan that matches nothing cannot report PASS"
  failed=1
elif [ -n "$bad" ]; then
  ac2="FAIL ${bad#; }"
  failed=1
else
  ac2="PASS"
  failed=0
fi

printf 'AC-2: %s\n' "$ac2"
exit "$failed"
