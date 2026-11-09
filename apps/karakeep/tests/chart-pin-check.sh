#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-1182 (AC-1): the Karakeep HelmRelease pins ONE explicit chart version at
# or above 0.34.1 - never a range, never a floating tag.
#
# Why: a range such as ">=0.32.0" hands the chart version to Flux, and the next
# reconcile upgrades karakeep (and its Meilisearch engine) without anybody
# having read the release notes. The upgrade to 0.34.1 ships Meilisearch
# v1.55.0 against an on-disk v1.13.0 database, so the version that lands is a
# decision, not a side effect.
#
# AC-1: every `kind: HelmRelease` document under apps/karakeep (test paths
#       skipped) sets spec.chart.spec.version to one exact
#       major.minor.patch (a leading `v` is tolerated) that is numerically at
#       or above 0.34.1. A pre-release such as 0.34.1-rc.1 is refused: it
#       sorts BELOW the release it pretends to be. A scan that finds no
#       HelmRelease at all fails loudly instead of reporting PASS over an
#       empty set.
#
# Parsing is yq, not grep: the values block carries other `version:`-looking
# keys, so only the path spec.chart.spec.version is authoritative. yq
# v4.54.1 is the version pinned in .github/workflows/check.yaml.
#
# Discovered and run by scripts/check.sh (it globs */tests/*-check.sh); listed
# in no Kustomization, so Flux never sees it.
#
# Usage: bash apps/karakeep/tests/chart-pin-check.sh
# Exit:  0 = AC-1 passes, 1 = AC-1 fails, 2 = the check could not run (yq
#         missing)
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$ROOT" || exit 2

if [ -z "$(command -v yq)" ]; then
  printf 'chart-pin-check: yq is not on PATH - the check cannot run\n' >&2
  exit 2
fi

# One exact release version. No operator, no wildcard, no bare major.minor, no
# pre-release or build suffix - those either float or sort below the release.
EXACT_VERSION='^v?[0-9]+\.[0-9]+\.[0-9]+$'
FLOOR=0.34.1
SCAN_ROOT=apps/karakeep

ver_at_least() { # candidate floor -> 0 when candidate >= floor
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<< "${1#v}"
  IFS=. read -r b1 b2 b3 <<< "${2#v}"
  a1=$((10#$a1)); a2=$((10#$a2)); a3=$((10#$a3))
  b1=$((10#$b1)); b2=$((10#$b2)); b3=$((10#$b3))
  if [ "$a1" -ne "$b1" ]; then [ "$a1" -gt "$b1" ]; return $?; fi
  if [ "$a2" -ne "$b2" ]; then [ "$a2" -gt "$b2" ]; return $?; fi
  [ "$a3" -ge "$b3" ]
}

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

# One line per HelmRelease document: "<name>|<chart>|<version>", empty version
# when the key is absent. An empty row means the document is not a
# HelmRelease. A yq failure means the YAML itself is unreadable.
releases_in() {
  yq -r 'select(.kind == "HelmRelease")
         | [(.metadata.name // ""), (.spec.chart.spec.chart // ""), (.spec.chart.spec.version // "" | tostring)]
         | join("|")' "$1"
}

releases=0
broken=""
bad=""

while IFS= read -r f; do
  [ -n "$f" ] || continue
  is_test_path "$f" && continue
  grep -q '^kind: HelmRelease' "$f" || continue
  rows=$(releases_in "$f" 2>&1) || {
    broken="$broken; $f: $(printf '%s' "$rows" | head -1)"
    continue
  }
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS='|' read -r name chart version <<< "$row"
    releases=$((releases + 1))
    if [ -z "$version" ]; then
      bad="$bad; $f ($name/$chart): no spec.chart.spec.version - the chart floats"
      continue
    fi
    if ! printf '%s' "$version" | grep -Eq "$EXACT_VERSION"; then
      bad="$bad; $f ($name/$chart): '$version' is not one exact major.minor.patch version"
      continue
    fi
    if ! ver_at_least "$version" "$FLOOR"; then
      bad="$bad; $f ($name/$chart): '$version' is below the required chart version $FLOOR"
    fi
  done <<< "$rows"
done < <(find "$SCAN_ROOT" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)

printf 'chart-pin-check: read %s HelmRelease document(s) under %s\n' \
  "$releases" "$SCAN_ROOT" >&2

if [ -n "$broken" ]; then
  ac1="FAIL unreadable HelmRelease YAML${broken}"
  failed=1
elif [ "$releases" -eq 0 ]; then
  ac1="FAIL found no HelmRelease under $SCAN_ROOT - a scan that matches nothing cannot report PASS"
  failed=1
elif [ -n "$bad" ]; then
  ac1="FAIL ${bad#; }"
  failed=1
else
  ac1="PASS"
  failed=0
fi

printf 'AC-1: %s\n' "$ac1"
exit "$failed"
