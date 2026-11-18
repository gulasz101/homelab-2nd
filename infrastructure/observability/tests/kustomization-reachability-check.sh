#!/usr/bin/env bash
# Red/green check for the kustomization reachability fix (GUL-1738, GUL-1597 gap).
#
# WO3 (GUL-1597, PR #249) added infrastructure/observability/otel-pipeline-prometheus-rules.yaml
# and .../otel-pipeline-alertmanager-config.yaml but never listed them in
# infrastructure/kustomization.yaml, so kustomize never emits them and Flux reports success
# without them (live finding on GUL-1603). This check asserts the two entries exist and, more
# usefully, guards the whole class: every top-level infrastructure/observability/*.yaml must be
# referenced exactly once as a `- observability/<name>.yaml` entry, and every such entry must
# point at something that exists. The next work order that forgets the entry fails here.
#
# Strictly offline, like the WO3 check: it reads two text files, so no kubectl, no kustomize,
# no network, no cluster. Modeled on tests/otel-pipeline-alerts-check.sh.
#
# One `AC-n: PASS|FAIL` line per AC on stdout (agents/factory/CONTRACT.md point 2); the
# per-assertion detail goes to stderr so stdout stays parseable. Exit 0 only when every AC
# passes.
#
#   bash infrastructure/observability/tests/kustomization-reachability-check.sh        # all ACs
#   bash infrastructure/observability/tests/kustomization-reachability-check.sh --ac 2 # one AC
#
# AC-1 is the one AC about the check itself: it exists, compiles, is discovered by
# scripts/check.sh, names no network tool, and (contract of "--ac N" / no argument) a
# no-argument run covers every AC and exits 0 only when they all pass - which on a tree with
# an unregistered manifest legitimately exits 1. The child runs carry REACH_CHECK_INNER so the
# self-inspection stops after one level instead of recursing.
#
# REACH_CHECK_ROOT points the check at another tree (self-test only). The spec's check
# commands set nothing, so it always reads this repo.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="${REACH_CHECK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
OBS="infrastructure/observability"
KUST="$ROOT/infrastructure/kustomization.yaml"
OBS_DIR="$ROOT/$OBS"
# resources entries are relative to infrastructure/, i.e. `- observability/<name>.yaml`.
ENTRY_RE="^[[:space:]]*-[[:space:]]*observability/"
# The two files WO3 forgot. Kept explicit so AC-2 fails by name, not by inference.
OTEL_FILES=(otel-pipeline-prometheus-rules.yaml otel-pipeline-alertmanager-config.yaml)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# What this check treats as "the network": the binaries and URL schemes an offline check must
# never need. Matched against the script's own non-comment lines, so the list has to sit in a
# variable that the scan skips by name.
OFFLINE_RE='kubectl|kustomize|helm|flux|curl|wget|ssh|scp|socat|nc|https?:'

AC_FAIL=(0 0 0 0)
AC_WHY=("" "" "" "")

ok() { printf '  ok    %s\n' "$1" >&2; }

fail_ac() {
  local n="$1"; shift
  if [ "${AC_FAIL[$n]}" -eq 0 ]; then AC_WHY[$n]="$*"; fi
  AC_FAIL[$n]=1
  printf '  FAIL  %s\n' "$*" >&2
}

# count_entry <path after observability/ (a basename, or a nested path)> - entry lines in
# kustomization.yaml. Prints the count, 0 when the file is missing.
count_entry() {
  [ -f "$KUST" ] || { printf '0\n'; return 0; }
  grep -cE "$ENTRY_RE$1([[:space:]]|\$)" "$KUST" || true
}

# --- AC-1: the check itself -------------------------------------------------

ac1() {
  printf '\n== AC-1: the check exists, compiles, is discovered, is offline, reports per AC\n' >&2

  if [ ! -f "$SELF" ]; then
    fail_ac 1 "kustomization-reachability-check.sh is missing"
    return 0
  fi
  if bash -n "$SELF" 2> "$WORK/n.log"; then
    ok "bash -n"
  else
    fail_ac 1 "bash -n fails: $(head -1 "$WORK/n.log")"
  fi

  # scripts/check.sh auto-discovers every */tests/*-check.sh under apps, infrastructure, docs,
  # agents, scripts and host, so the name alone is the registration - prove it by listing.
  case "/$SELF" in
    */tests/*-check.sh) ok "filename matches */tests/*-check.sh" ;;
    *) fail_ac 1 "filename does not match */tests/*-check.sh, so scripts/check.sh will not discover it" ;;
  esac
  if [ -f "$ROOT/scripts/check.sh" ]; then
    if ( cd "$ROOT" && bash scripts/check.sh --list ) > "$WORK/list.log" 2>&1; then
      if grep -qF "$OBS/tests/kustomization-reachability-check.sh" "$WORK/list.log"; then
        ok "scripts/check.sh --list registers it"
      else
        fail_ac 1 "scripts/check.sh --list does not register $OBS/tests/kustomization-reachability-check.sh"
      fi
    else
      fail_ac 1 "scripts/check.sh --list exited non-zero, so discovery cannot be confirmed"
    fi
  else
    fail_ac 1 "scripts/check.sh is missing, so discovery cannot be confirmed"
  fi

  hits=$(grep -vE '^[[:space:]]*#' "$SELF" \
         | grep -v 'OFFLINE_RE=' \
         | grep -nE "(^|[^[:alnum:]_/-])($OFFLINE_RE)([^[:alnum:]_-]|$)")
  if [ -z "$hits" ]; then
    ok "no network or cluster tool is named outside comments"
  else
    fail_ac 1 "not offline: $(printf '%s' "$hits" | head -1)"
  fi

  # The protocol: no argument covers every AC, --ac N covers exactly one, and the exit code
  # follows. The child run carries REACH_CHECK_INNER, which is what stops the recursion:
  # an inner run does the hygiene checks but never spawns children of its own.
  if [ -z "${REACH_CHECK_INNER:-}" ]; then
    if REACH_CHECK_INNER=1 bash "$SELF" > "$WORK/all.log" 2>&1; then
      missing=""
      for n in 1 2 3; do
        grep -qE "^AC-$n: PASS\$" "$WORK/all.log" || missing="$missing AC-$n"
      done
      if [ -z "$missing" ]; then
        ok "no argument runs every AC and exits 0"
      else
        fail_ac 1 "no argument exits 0 without a PASS line for:$missing"
      fi
    else
      fail_ac 1 "no argument exits non-zero on this tree: $(grep -m1 -E '^AC-[0-9]+: FAIL' "$WORK/all.log")"
    fi
    for n in 1 2 3; do
      REACH_CHECK_INNER=1 bash "$SELF" --ac "$n" > "$WORK/one.log" 2>&1
      got=$(grep -cE '^AC-[0-9]+: (PASS|FAIL)' "$WORK/one.log" || true)
      if [ "$got" -eq 1 ] && grep -qE "^AC-$n: (PASS|FAIL)" "$WORK/one.log"; then
        ok "--ac $n prints exactly one AC-$n line"
      else
        fail_ac 1 "--ac $n printed $got AC lines, expected exactly one AC-$n line"
      fi
    done
  fi
  return 0
}

# --- AC-2: the two otel-pipeline entries ------------------------------------

ac2() {
  printf '\n== AC-2: the otel-pipeline rule and AlertmanagerConfig are resources entries\n' >&2
  if [ ! -f "$KUST" ]; then
    fail_ac 2 "$OBS/../kustomization.yaml is missing"
    return 0
  fi

  # An entry that lands before `resources:` or outside the observability block is not "next to
  # the other observability rules": kustomize would either ignore it or the file would grow a
  # second, parallel list.
  kust_res=$(grep -nE '^resources:[[:space:]]*$' "$KUST" | head -1 | cut -d: -f1)
  first_obs=$(grep -nE "$ENTRY_RE" "$KUST" | head -1 | cut -d: -f1)
  last_obs=$(grep -nE "$ENTRY_RE" "$KUST" | tail -1 | cut -d: -f1)

  for f in "${OTEL_FILES[@]}"; do
    n=$(count_entry "$f")
    case "$n" in
      0) fail_ac 2 "$OBS/$f is not listed as a resources entry in infrastructure/kustomization.yaml" ;;
      1)
        line=$(grep -nE "$ENTRY_RE$f([[:space:]]|\$)" "$KUST" | head -1 | cut -d: -f1)
        if [ -z "$kust_res" ] || [ "$line" -lt "$kust_res" ]; then
          fail_ac 2 "$OBS/$f is listed before the resources: key (line $line)"
        elif [ -n "$first_obs" ] && { [ "$line" -lt "$first_obs" ] || [ "$line" -gt "$last_obs" ]; }; then
          fail_ac 2 "$OBS/$f is listed outside the observability block (line $line)"
        else
          ok "$OBS/$f listed once, among the observability entries (line $line)"
        fi
        ;;
      *) fail_ac 2 "$OBS/$f is listed $n times in infrastructure/kustomization.yaml, expected once" ;;
    esac
  done
  return 0
}

# --- AC-3: the whole class, both directions ---------------------------------

ac3() {
  printf '\n== AC-3: every top-level observability manifest is reachable, every entry resolves\n' >&2
  if [ ! -d "$OBS_DIR" ]; then
    fail_ac 3 "$OBS_DIR is missing"
    return 0
  fi
  if [ ! -f "$KUST" ]; then
    fail_ac 3 "infrastructure/kustomization.yaml is missing"
    return 0
  fi

  # Forward: a top-level manifest with no entry is dead on arrival - it exists in git, kustomize
  # never emits it, Flux reports the Kustomization healthy.
  n_files=0
  for f in "$OBS_DIR"/*.yaml; do
    [ -f "$f" ] || continue
    n_files=$((n_files + 1))
    b=$(basename "$f")
    n=$(count_entry "$b")
    case "$n" in
      0) fail_ac 3 "missing: $OBS/$b exists but has no resources entry in infrastructure/kustomization.yaml" ;;
      1) ok "$OBS/$b" ;;
      *) fail_ac 3 "duplicate: $OBS/$b is listed $n times in infrastructure/kustomization.yaml" ;;
    esac
  done
  [ "$n_files" -eq 0 ] && fail_ac 3 "no top-level $OBS/*.yaml found - the check would pass on an empty tree"

  # Backward: an entry pointing at nothing breaks the whole kustomization build (Flux then
  # leaves the previous revision applied and the drift is invisible).
  n_entries=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    n_entries=$((n_entries + 1))
    if [ ! -e "$ROOT/infrastructure/$rel" ]; then
      fail_ac 3 "dangling: infrastructure/kustomization.yaml lists $rel, which does not exist"
    fi
  done <<EOF
$(grep -oE "$ENTRY_RE[^[:space:]]+" "$KUST" | sed -e 's/^[[:space:]]*-[[:space:]]*//' | sort)
EOF
  [ "$n_entries" -eq 0 ] && fail_ac 3 "no $OBS/... entries parsed - the check would pass on an empty list"

  # Self-test: the check must bite. A copy of the tree with one entry removed must FAIL and
  # name the file, otherwise a broken tree and a clean one look the same.
  self_test
  return 0
}

self_test() {
  local tmp victim out rc
  victim=""
  for f in "$OBS_DIR"/*.yaml; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    if [ "$(count_entry "$b")" -ge 1 ]; then victim="$b"; break; fi
  done
  if [ -z "$victim" ]; then
    fail_ac 3 "self-test cannot run: no registered manifest to remove"
    return 0
  fi

  tmp="$WORK/self-test"
  mkdir -p "$tmp/infrastructure/observability"
  cp "$KUST" "$tmp/infrastructure/kustomization.yaml"
  cp -R "$OBS_DIR/." "$tmp/infrastructure/observability/"
  grep -vE "$ENTRY_RE$victim([[:space:]]|\$)" \
    "$tmp/infrastructure/kustomization.yaml" > "$tmp/k.yaml"
  mv "$tmp/k.yaml" "$tmp/infrastructure/kustomization.yaml"

  out=$(REACH_CHECK_INNER=1 REACH_CHECK_ROOT="$tmp" bash "$SELF" --ac 3 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    fail_ac 3 "self-test: a copy with the $victim entry removed still reports PASS - the check does not bite"
  elif ! printf '%s\n' "$out" | grep -qE "^AC-3: FAIL .*$victim"; then
    fail_ac 3 "self-test: removing the $victim entry is detected, but the FAIL line does not name it"
  else
    ok "self-test: dropping the $victim entry FAILs and names it"
  fi
}

# --- dispatch ---------------------------------------------------------------

only=""
case "${1:-}" in
  "") ;;
  --ac)
    only="${2:-}"
    case "$only" in
      1|2|3) ;;
      *) printf 'usage: %s [--ac 1|2|3]\n' "$(basename "$SELF")" >&2; exit 2 ;;
    esac
    ;;
  *) printf 'usage: %s [--ac 1|2|3]\n' "$(basename "$SELF")" >&2; exit 2 ;;
esac

if [ -z "$only" ] || [ "$only" = "1" ]; then ac1; fi
if [ -z "$only" ] || [ "$only" = "2" ]; then ac2; fi
if [ -z "$only" ] || [ "$only" = "3" ]; then ac3; fi

printf '\n' >&2
rc=0
for n in 1 2 3; do
  if [ -n "$only" ] && [ "$only" != "$n" ]; then continue; fi
  if [ "${AC_FAIL[$n]}" -eq 1 ]; then
    printf 'AC-%s: FAIL %s\n' "$n" "${AC_WHY[$n]}"
    rc=1
  else
    printf 'AC-%s: PASS\n' "$n"
  fi
done
exit "$rc"
