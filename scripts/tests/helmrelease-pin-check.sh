#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-479 (work order 1): no HelmRelease floats on a chart version range.
#
# A range such as ">=0.23.0" or ">=0.5.0" hands the chart version to Flux: the
# next reconcile upgrades the workload without anybody having read the release
# notes. Every release therefore has to name one exact chart version, and the
# four that floated have to be pinned to the versions that were actually
# running on 2026-10-28.
#
# AC-1: every HelmRelease document under apps/ or infrastructure/ (column-0
#       `kind: HelmRelease`, test paths skipped) sets spec.chart.spec.version
#       to one exact version (1.2.3 / v1.2.3, prerelease and build suffixes
#       allowed). The check also refuses to report PASS when it read fewer
#       than 20 HelmRelease documents, so a scan that silently stops matching
#       fails loudly instead of reporting green over an empty set.
# AC-2: cloudnative-pg 0.29.1 (infrastructure/cnpg/helm-release.yaml),
#       open-webui 17.3.0 (apps/llm-hub/openwebui-helm-release.yaml),
#       opentelemetry-collector 0.178.0
#       (infrastructure/observability/opentelemetry-collector-helm-release.yaml)
#       and kube-prometheus-stack 92.14.1
#       (infrastructure/observability/prometheus-stack-helm-release.yaml) are
#       pinned to those exact versions.
#
# A pin is a floor as well as a ceiling: never pin below the chart version the
# cluster is already running. open-webui was pinned to 17.0.0 while 17.3.0 was
# deployed, Flux downgraded it, and the container died on
# "alembic.util.exc.CommandError: Can't locate revision identified by
# '0bd252b206fb'" - its SQLite schema was already at 17.3.0's alembic head.
# Downgrade the app and the database together or not at all.
#
# Parsing is yq, not grep: the values blocks of these releases carry `version:`
# keys of their own (grafana's values hold `version: Flux`, prometheus-stack's
# hold `version: v1`), so only the path spec.chart.spec.version is
# authoritative. yq v4.54.1 is the version pinned in
# .github/workflows/check.yaml.
#
# HELMRELEASE_PIN_ROOTS (default: "apps infrastructure") narrows the scan so
# the fewer-than-20 guard can be exercised without touching a manifest - e.g.
# `HELMRELEASE_PIN_ROOTS=docs/adr` reads 0 releases and fails. A smaller root
# can only ever lower the count, so the probe can produce a FAIL but never a
# PASS.
#
# Discovered and run by scripts/check.sh (it globs */tests/*-check.sh); listed
# in no Kustomization, so Flux never sees it.
#
# Usage: bash scripts/tests/helmrelease-pin-check.sh
# Exit:  0 = AC-1 and AC-2 pass, 1 = at least one of them fails, 2 = the check
#         could not run at all (yq missing)
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT" || exit 2

if [ -z "$(command -v yq)" ]; then
  printf 'helmrelease-pin-check: yq is not on PATH - the check cannot run\n' >&2
  exit 2
fi

# One exact semver: 1.2.3, v1.2.3, 1.2.3-rc.1, 1.2.3+build.7. Anything with an
# operator (>=, ~, ^), a wildcard (1.2.x, *), a bare major.minor, or nothing at
# all does not match.
EXACT_VERSION='^v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'
MIN_RELEASES=20
ROOTS=${HELMRELEASE_PIN_ROOTS:-apps infrastructure}

# The four charts that floated on a range, pinned to the versions running on
# 2026-10-28. Shape: file|chart|version
TARGETS='infrastructure/cnpg/helm-release.yaml|cloudnative-pg|0.29.1
apps/llm-hub/openwebui-helm-release.yaml|open-webui|17.3.0
infrastructure/observability/opentelemetry-collector-helm-release.yaml|opentelemetry-collector|0.178.0
infrastructure/observability/prometheus-stack-helm-release.yaml|kube-prometheus-stack|92.14.1'

join_by() { # separator item...
  local sep=$1 out="" x
  shift
  for x in "$@"; do
    out=${out:+$out$sep}$x
  done
  printf '%s' "$out"
}

# looksLikeTestPath from agents/factory-guard/policy.ts (CONTRACT.md point 6):
# a `tests`/`test` segment that is not the last segment, or a test-looking
# basename. Fixtures living next to a check must not be read as production
# manifests.
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

# One line per HelmRelease document: "<chart>|<version>|<name>", empty field
# when the key is absent. An empty row means the document is not a
# HelmRelease. A yq failure means the YAML itself is unreadable.
releases_in() {
  yq -r 'select(.kind == "HelmRelease")
         | [.spec.chart.spec.chart, .spec.chart.spec.version, .metadata.name]
         | join("|")' "$1"
}

failed=0
total=0
scanned_files=0
floating=()
broken=()

# ---- AC-1: every HelmRelease pins one exact chart version ------------------
while IFS= read -r f; do
  [ -n "$f" ] || continue
  is_test_path "$f" && continue
  grep -q '^kind: HelmRelease' "$f" || continue
  scanned_files=$((scanned_files + 1))
  rows=$(releases_in "$f" 2>&1) || { broken+=("$f: $(printf '%s' "$rows" | head -1)"); continue; }
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS='|' read -r chart version _name <<< "$row"
    total=$((total + 1))
    printf '%s' "$version" | grep -Eq "$EXACT_VERSION" && continue
    floating+=("$f ($chart) '${version:-<missing>}'")
  done < <(printf '%s\n' "$rows")
done < <(
  for root in $ROOTS; do
    [ -d "$root" ] || { printf 'helmrelease-pin-check: scan root %s does not exist\n' "$root" >&2; continue; }
    find "$root" -type f \( -name '*.yaml' -o -name '*.yml' \)
  done | sort
)

printf 'helmrelease-pin-check: read %s HelmRelease documents in %s files under: %s\n' \
  "$total" "$scanned_files" "$ROOTS" >&2

if [ "${#broken[@]}" -gt 0 ]; then
  ac1="FAIL unparseable HelmRelease YAML: $(join_by '; ' "${broken[@]}")"
  failed=1
elif [ "$total" -lt "$MIN_RELEASES" ]; then
  ac1="FAIL read $total HelmRelease documents under '$ROOTS', expected at least $MIN_RELEASES - the scan matched too little to trust a pass"
  failed=1
elif [ "${#floating[@]}" -gt 0 ]; then
  ac1="FAIL ${#floating[@]} of $total HelmReleases carry no single exact spec.chart.spec.version: $(join_by '; ' "${floating[@]}")"
  failed=1
else
  ac1="PASS"
fi

# ---- AC-2: the four floating charts are pinned to the running versions -----
a2=()
while IFS= read -r target; do
  [ -n "$target" ] || continue
  IFS='|' read -r tfile tchart tversion <<< "$target"
  if [ ! -f "$tfile" ]; then
    a2+=("$tfile is missing")
    continue
  fi
  rows=$(releases_in "$tfile" 2>&1) || { a2+=("$tfile is not readable YAML"); continue; }
  hits=0
  seen=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS='|' read -r chart version _name <<< "$row"
    [ "$chart" = "$tchart" ] || continue
    hits=$((hits + 1))
    seen=$version
  done < <(printf '%s\n' "$rows")
  if [ "$hits" -eq 0 ]; then
    a2+=("$tfile has no HelmRelease for chart $tchart")
  elif [ "$hits" -gt 1 ]; then
    a2+=("$tfile has $hits HelmReleases for chart $tchart, want exactly one")
  elif [ "$seen" != "$tversion" ]; then
    a2+=("$tfile: $tchart is '${seen:-<missing>}', want '$tversion'")
  fi
done <<< "$TARGETS"

if [ "${#a2[@]}" -gt 0 ]; then
  ac2="FAIL $(join_by '; ' "${a2[@]}")"
  failed=1
else
  ac2="PASS"
fi

printf 'AC-1: %s\n' "$ac1"
printf 'AC-2: %s\n' "$ac2"
exit "$failed"
