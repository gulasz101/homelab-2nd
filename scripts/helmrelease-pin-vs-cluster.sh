#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-552 (ADR-097): a chart pin is never below the version the cluster runs.
#
# Work order 1 (GUL-479) pinned open-webui to 17.0.0 while the cluster was
# already running 17.3.0. The pin check passed - 17.0.0 is one exact version,
# which is all it looked at - Flux dutifully downgraded, and Open WebUI died on
# its alembic migration ("Can't locate revision identified by '0bd252b206fb'").
# ADR-097 says a pin is a floor as well as a ceiling. This script enforces the
# floor.
#
# For every HelmRelease changed between two refs, compare the head
# spec.chart.spec.version with the chart version the cluster is running right
# now (the live release's status.history[0].chartVersion). A pin below the
# deployed version is a downgrade and FAILS, whatever else the PR looks like.
#
# PASS with a note when nothing can be compared:
#   - the release is not in the cluster yet (a new HelmRelease);
#   - its chart is not a versioned artifact (a GitRepository/ConfigMap source,
#     i.e. no spec.chart.spec.version) - the pin there is the source ref;
#   - the live status carries no history (never reconciled);
#   - one of the two versions is not semver-shaped and cannot be compared.
#
# Parsing rules are the ones from scripts/tests/helmrelease-pin-check.sh: a
# HelmRelease is a document with a column-0 `kind: HelmRelease` (an indented one
# inside a values block is a value, not a document - prometheus-stack has one),
# test paths are skipped, and only the path spec.chart.spec.version is
# authoritative (grafana's values carry a `version: Flux` of their own).
#
# This needs kubectl and a reachable cluster, so it cannot run inside
# scripts/check.sh (CI has no cluster). It is called by the factory gate
# (agents/factory/factory.py, cmd_check_gate) and can be run by hand for any PR:
#
#   bash scripts/helmrelease-pin-vs-cluster.sh origin/main my-branch
#   bash scripts/helmrelease-pin-vs-cluster.sh origin/main 4f2d1c9
#
# The diff is three-dot (`git diff base...head`): the merge base, so the script
# judges what the PR itself changed, not what main moved underneath it. Fetch
# the head into your checkout first (`git fetch origin pull/<n>/head`) - an
# unknown ref is a setup error, never a pass.
#
# Output: one PASS/NOTE/FAIL line per HelmRelease, then a RESULT line. The
# factory gate turns every FAIL line into a gate reason.
#
# Exit: 0 = every changed HelmRelease pins what the cluster runs or newer
#       1 = at least one pin is below the deployed version
#       2 = setup error: usage, unreadable YAML, unknown ref, no yq, or kubectl
#           cannot reach the cluster. Never a PASS.
# ---------------------------------------------------------------------------
set -uo pipefail

say() { printf 'helmrelease-pin-vs-cluster: %s\n' "$*" >&2; }

usage() {
  say "usage: bash scripts/helmrelease-pin-vs-cluster.sh <base-ref> <head-ref>"
  say "  e.g. bash scripts/helmrelease-pin-vs-cluster.sh origin/main my-branch"
  exit 2
}

[ "$#" -eq 2 ] || usage
BASE=$1
HEAD=$2
[ -n "$BASE" ] && [ -n "$HEAD" ] || usage

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  say "not inside a git checkout - run this from the repo root"
  exit 2
}
cd "$ROOT" || exit 2

command -v yq >/dev/null 2>&1 || { say "yq is not on PATH - cannot parse YAML"; exit 2; }
command -v kubectl >/dev/null 2>&1 || { say "kubectl is not on PATH - cannot read the deployed versions"; exit 2; }

for ref in "$BASE" "$HEAD"; do
  git rev-parse --verify --quiet "$ref^{commit}" >/dev/null || {
    say "ref '$ref' is not in this checkout - fetch it first (git fetch origin <ref>)"
    exit 2
  }
done

# looksLikeTestPath from agents/factory-guard/policy.ts (CONTRACT.md point 6):
# a `tests`/`test` segment that is not the last segment, or a test-looking
# basename. Fixtures next to a check must not be read as production manifests.
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

# ---- semver comparison (bash 3.2: no assoc arrays, no sort -V) -------------
# semver_cmp A B -> prints -1 / 0 / 1. Leading `v` and build metadata (`+…`)
# are ignored; a prerelease sorts BELOW the release it belongs to, per semver.

pre_cmp() { # semver_cmp for the dot-separated prerelease identifiers
  local a=$1 b=$2 ia ib a_num b_num
  while [ -n "$a" ] || [ -n "$b" ]; do
    case $a in
      *.*) ia=${a%%.*}; a=${a#*.} ;;
      *)   ia=$a; a="" ;;
    esac
    case $b in
      *.*) ib=${b%%.*}; b=${b#*.} ;;
      *)   ib=$b; b="" ;;
    esac
    # a shorter identifier list sorts first (1.2.3-rc < 1.2.3-rc.1)
    if [ -z "$ia" ] && [ -n "$ib" ]; then printf '%s\n' -1; return; fi
    if [ -n "$ia" ] && [ -z "$ib" ]; then printf '%s\n' 1; return; fi
    a_num=0; b_num=0
    case $ia in ''|*[!0-9]*) ;; *) a_num=1 ;; esac
    case $ib in ''|*[!0-9]*) ;; *) b_num=1 ;; esac
    if [ "$a_num" = 1 ] && [ "$b_num" = 1 ]; then
      if [ "$ia" -lt "$ib" ]; then printf '%s\n' -1; return; fi
      if [ "$ia" -gt "$ib" ]; then printf '%s\n' 1; return; fi
    elif [ "$a_num" = 1 ]; then
      printf '%s\n' -1; return   # numeric identifiers rank below alphanumeric
    elif [ "$b_num" = 1 ]; then
      printf '%s\n' 1; return
    elif [ "$ia" != "$ib" ]; then
      if [ "$ia" \< "$ib" ]; then printf '%s\n' -1; return; else printf '%s\n' 1; return; fi
    fi
  done
  printf '%s\n' 0
}

semver_cmp() {
  local a b acore bcore apre bpre am aj as bm bj bs
  a=${1#v}; b=${2#v}
  acore=${a%%+*}; bcore=${b%%+*}
  apre=""; bpre=""
  case $acore in *-*) apre=${acore#*-}; acore=${acore%%-*} ;; esac
  case $bcore in *-*) bpre=${bcore#*-}; bcore=${bcore%%-*} ;; esac
  IFS=. read -r am aj as <<< "$acore"
  IFS=. read -r bm bj bs <<< "$bcore"
  am=${am:-0}; aj=${aj:-0}; as=${as:-0}
  bm=${bm:-0}; bj=${bj:-0}; bs=${bs:-0}
  if [ "$am" -ne "$bm" ]; then [ "$am" -lt "$bm" ] && printf '%s\n' -1 || printf '%s\n' 1; return; fi
  if [ "$aj" -ne "$bj" ]; then [ "$aj" -lt "$bj" ] && printf '%s\n' -1 || printf '%s\n' 1; return; fi
  if [ "$as" -ne "$bs" ]; then [ "$as" -lt "$bs" ] && printf '%s\n' -1 || printf '%s\n' 1; return; fi
  if [ -z "$apre" ] && [ -z "$bpre" ]; then printf '%s\n' 0; return; fi
  if [ -z "$apre" ]; then printf '%s\n' 1; return; fi   # release > prerelease
  if [ -z "$bpre" ]; then printf '%s\n' -1; return; fi
  pre_cmp "$apre" "$bpre"
}

# One exact semver: 1.2.3, v1.2.3, 1.2.3-rc.1, 1.2.3+build.7. A range, a
# wildcard or a bare major.minor is not comparable.
EXACT_VERSION='^v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'

# ---- live cluster: namespace index and the deployed chart version ----------
# INDEX holds "<namespace>|<name>" for every HelmRelease in the cluster. One
# call builds it; it also proves the cluster is reachable before any verdict.
INDEX=""
INDEX_LOADED=0

load_index() {
  [ "$INDEX_LOADED" = 1 ] && return 0
  local out rc
  out=$(kubectl get hr -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"\n"}{end}' 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    say "kubectl cannot reach the cluster (exit $rc): $(printf '%s' "$out" | head -1)"
    exit 2
  fi
  INDEX=$out
  INDEX_LOADED=1
}

namespace_of() { # name -> namespace, empty when not in the cluster
  printf '%s\n' "$INDEX" | awk -F'|' -v n="$1" '$2 == n { print $1; exit }'
}

# deployed_version NS NAME -> sets DEPLOYED (the version) and DEPLOYED_STATE
# (ok | notfound | nohistory). Exits 2 when kubectl answers with anything but
# NotFound, so a broken cluster can never be read as "nothing to compare".
DEPLOYED=""
DEPLOYED_STATE=""
deployed_version() {
  local ns=$1 name=$2 out rc
  DEPLOYED=""
  DEPLOYED_STATE=""
  out=$(kubectl get hr -n "$ns" "$name" -o jsonpath='{.status.history[0].chartVersion}' 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    case $out in
      *NotFound*) DEPLOYED_STATE=notfound; return 0 ;;
      *)
        say "kubectl get hr -n $ns $name failed (exit $rc): $(printf '%s' "$out" | head -1)"
        exit 2
        ;;
    esac
  fi
  if [ -z "$out" ]; then
    DEPLOYED_STATE=nohistory
  else
    DEPLOYED=$out
    DEPLOYED_STATE=ok
  fi
}

# ---------------------------------------------------------------------------
checked=0
failed=0
skipped=0
fail_lines=""

join_fail() { # appends one FAIL line to the summary
  fail_lines="${fail_lines}${1}
"
}

while IFS= read -r path; do
  [ -n "$path" ] || continue
  is_test_path "$path" && continue
  case $path in
    *.yaml|*.yml) ;;
    *) continue ;;
  esac

  content=$(git show "$HEAD:$path" 2>/dev/null) || {
    say "cannot read $path at $HEAD"
    exit 2
  }
  # column-0 kind only: an indented `kind: HelmRelease` is a values entry
  printf '%s\n' "$content" | grep -q '^kind: HelmRelease' || continue

  rows=$(printf '%s\n' "$content" | yq -r 'select(.kind == "HelmRelease")
        | [.metadata.name, (.metadata.namespace // ""), (.spec.chart.spec.chart // ""),
           (.spec.chart.spec.version // ""), (.spec.chartRef.kind // .spec.chart.spec.sourceRef.kind // "")]
        | join("|")' - 2>&1) || {
    say "yq cannot parse $path at $HEAD: $(printf '%s' "$rows" | head -1)"
    exit 2
  }

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS='|' read -r name ns chart pin source_kind <<< "$row"
    [ -n "$name" ] || { say "$path at $HEAD has a HelmRelease without metadata.name"; exit 2; }

    if [ -z "$pin" ]; then
      printf 'NOTE %s %s: chart comes from %s and carries no spec.chart.spec.version - nothing to compare\n' \
        "$path" "$name" "${source_kind:-a GitRepository/ConfigMap source}"
      skipped=$((skipped + 1))
      continue
    fi

    load_index
    [ -n "$ns" ] || ns=$(namespace_of "$name")
    if [ -z "$ns" ]; then
      printf 'NOTE %s %s: not in the cluster yet (new HelmRelease) - pin %s accepted\n' \
        "$path" "$name" "$pin"
      skipped=$((skipped + 1))
      continue
    fi

    deployed_version "$ns" "$name"
    if [ "$DEPLOYED_STATE" = notfound ]; then
      printf 'NOTE %s %s (%s): not in the cluster yet (new HelmRelease) - pin %s accepted\n' \
        "$path" "$name" "$ns" "$pin"
      skipped=$((skipped + 1))
      continue
    fi
    deployed=$DEPLOYED
    if [ "$DEPLOYED_STATE" != ok ]; then
      printf 'NOTE %s %s (%s): live release carries no status.history - cannot compare with pin %s\n' \
        "$path" "$name" "$ns" "$pin"
      skipped=$((skipped + 1))
      continue
    fi

    checked=$((checked + 1))

    if ! printf '%s' "$pin" | grep -Eq "$EXACT_VERSION" || ! printf '%s' "$deployed" | grep -Eq "$EXACT_VERSION"; then
      printf 'NOTE %s %s (%s): pin %s vs deployed %s is not semver-comparable\n' \
        "$path" "$name" "$ns" "$pin" "$deployed"
      continue
    fi

    cmp=$(semver_cmp "$pin" "$deployed")
    case $cmp in
      -1)
        printf 'FAIL %s %s (%s): pins %s but the cluster runs %s - a downgrade (ADR-097)\n' \
          "$path" "$name" "$ns" "$pin" "$deployed"
        join_fail "$path $name ($ns): pins $pin, cluster runs $deployed"
        failed=$((failed + 1))
        ;;
      0)
        printf 'PASS %s %s (%s): %s == deployed\n' "$path" "$name" "$ns" "$pin"
        ;;
      *)
        printf 'PASS %s %s (%s): %s is above the deployed %s\n' \
          "$path" "$name" "$ns" "$pin" "$deployed"
        ;;
    esac
  done <<< "$rows"
done < <(git diff --name-only -z --diff-filter=d "$BASE...$HEAD" | tr '\0' '\n')

if [ "$failed" -gt 0 ]; then
  printf 'RESULT: FAIL - %d of %d changed HelmReleases pin below the deployed version\n' \
    "$failed" "$checked"
  exit 1
fi
printf 'RESULT: PASS - %d changed HelmReleases checked, %d not comparable (see NOTE)\n' \
  "$checked" "$skipped"
exit 0
