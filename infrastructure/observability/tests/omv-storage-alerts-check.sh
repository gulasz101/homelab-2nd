#!/usr/bin/env bash
# Render + validate check for the OMV storage-health alerting (GUL-560).
#
# Same shape as flux-gitops-alerts-check.sh: it renders the Kustomization that
# Flux actually applies, validates the objects with kubeconform -strict, and
# then asserts the properties a schema cannot express - the rule names, the
# label set the routing depends on, the PromQL fragments that make each rule
# meaningful, and the AlertmanagerConfig matcher that actually delivers them.
#
# Structural greps use `^[[:space:]]*` because kubectl kustomize re-indents
# sequences; pinning exact indentation would break on an unrelated refactor.
#
# Not listed in infrastructure/kustomization.yaml on purpose - Flux never sees
# this directory.
#
# Usage: infrastructure/observability/tests/omv-storage-alerts-check.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

K8S_VERSION=1.31.0
CRD_SCHEMA='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
head1() { printf '\n== %s\n' "$1"; }

RENDER="$WORK/infrastructure.yaml"
OWN="$WORK/own-objects.yaml"

# Print the document of the given kind whose metadata.name matches, from a
# multi-document YAML render. Documents are separated by a line `---`. The
# whole document is printed, apiVersion line included.
block() {
  local kind="$1" name="$2" file="$3"
  awk -v kind="$kind" -v name="$name" '
    { lines[NR] = $0; if ($0 == "---") seps[++ns] = NR }
    END {
      s = 1
      for (i = 1; i <= ns; i++) { check(s, seps[i] - 1); s = seps[i] + 1 }
      check(s, NR)
    }
    function check(s, e,   j, hasKind, hasName) {
      if (e < s) return
      hasKind = 0; hasName = 0
      for (j = s; j <= e; j++) {
        if (lines[j] == "kind: " kind) hasKind = 1
        if (lines[j] == "  name: " name) hasName = 1
      }
      if (hasKind && hasName) { for (j = s; j <= e; j++) print lines[j]; print "---" }
    }
  ' "$file"
}

head1 "1. wiring"
grep -q '^  - observability/omv-storage-prometheus-rules.yaml$' "$ROOT/infrastructure/kustomization.yaml" \
  && ok "infrastructure/kustomization.yaml wires the omv-storage PrometheusRule" \
  || bad "infrastructure/kustomization.yaml does not reference observability/omv-storage-prometheus-rules.yaml"

head1 "2. render infrastructure"
if kubectl kustomize "$ROOT/infrastructure" > "$RENDER" 2> "$WORK/kustomize.err"; then
  ok "kubectl kustomize infrastructure -> $(grep -c '^kind:' "$RENDER") objects"
else
  bad "kubectl kustomize infrastructure failed:"
  sed 's/^/        /' "$WORK/kustomize.err"
fi

head1 "3. kubeconform -strict on the new objects"
: > "$OWN"
if PR=$(block PrometheusRule omv-storage-alerts "$RENDER") && [ -n "$PR" ]; then
  printf '%s\n' "$PR" >> "$OWN"
fi
if AC=$(block AlertmanagerConfig homelab-node-mattermost-alerts "$RENDER") && [ -n "$AC" ]; then
  printf '%s\n' "$AC" >> "$OWN"
fi
if [ -s "$OWN" ]; then
  if kubeconform -strict -summary -kubernetes-version "$K8S_VERSION" \
       -schema-location default -schema-location "$CRD_SCHEMA" \
       "$OWN" > "$WORK/own.txt" 2>&1; then
    ok "own objects: $(tail -1 "$WORK/own.txt")"
  else
    bad "kubeconform rejected the new objects:"
    grep -v '^Summary:' "$WORK/own.txt" | sed 's/^/        /'
  fi
else
  bad "none of the new objects rendered - nothing to validate"
fi

head1 "4. PrometheusRule omv-storage-alerts"
if [ -n "${PR:-}" ]; then
  ok "PrometheusRule/omv-storage-alerts renders"
  printf '%s\n' "$PR" | grep -qE '^[[:space:]]*namespace: observability$' \
    && ok "  lives in observability" || bad "  not in observability"
  # The trap flux-gitops-alerts-check.sh documents: the Prometheus ruleSelector
  # is {matchLabels: {release: prometheus-stack}}, so a rule without that label
  # loads nowhere and never fires.
  printf '%s\n' "$PR" | grep -qE '^[[:space:]]*release: prometheus-stack$' \
    && ok "  carries label release: prometheus-stack (ruleSelector match)" \
    || bad "  missing label release: prometheus-stack - Prometheus would ignore this rule"

  for a in OMVBtrfsDeviceReadErrors OMVBtrfsDeviceCorruptionOrGenerationErrors \
           OMVBtrfsVolumeReadOnly OMVDiskUnreachable OMVBtrfsSustainedReadErrors; do
    printf '%s\n' "$PR" | grep -qE "^[[:space:]]*- alert: ${a}$" \
      && ok "  rule ${a}" || bad "  rule ${a} missing"
  done

  n_alerts=$(printf '%s\n' "$PR" | grep -cE '^[[:space:]]*- alert: ')
  n_group=$(printf '%s\n' "$PR" | grep -cE '^[[:space:]]*alertgroup: omv-storage$')
  n_crit=$(printf '%s\n' "$PR" | grep -cE '^[[:space:]]*severity: critical$')
  n_ns=$(printf '%s\n' "$PR" | grep -cE '^[[:space:]]{4,}namespace: observability$')
  [ "$n_alerts" -eq 5 ] && [ "$n_alerts" -eq "$n_group" ] && [ "$n_alerts" -eq "$n_crit" ] && [ "$n_alerts" -eq "$n_ns" ] \
    && ok "  all ${n_alerts} alerts carry alertgroup: omv-storage, severity: critical and namespace: observability" \
    || bad "  ${n_alerts} alerts but ${n_group} alertgroup / ${n_crit} severity / ${n_ns} namespace labels"

  # 3 rules wait 5m (a burst is still critical, but let one scrape settle), the
  # unreachable rule waits 10m so a reboot does not page, and the slow-burn
  # rule waits 30m so one noisy half hour does not page.
  n_5m=$(printf '%s\n' "$PR" | grep -cE '^[[:space:]]*for: 5m$')
  n_10m=$(printf '%s\n' "$PR" | grep -cE '^[[:space:]]*for: 10m$')
  n_30m=$(printf '%s\n' "$PR" | grep -cE '^[[:space:]]*for: 30m$')
  [ "$n_5m" -eq 3 ] && [ "$n_10m" -eq 1 ] && [ "$n_30m" -eq 1 ] \
    && ok "  3 rules use for: 5m, OMVDiskUnreachable 10m, OMVBtrfsSustainedReadErrors 30m" \
    || bad "  ${n_5m}x for: 5m, ${n_10m}x for: 10m, ${n_30m}x for: 30m (want 3, 1, 1)"

  # Each rule's PromQL, read from the source with yq: kubectl kustomize wraps
  # long scalars, so grepping the render would test the line wrapping rather
  # than the expression. These strings are the semantics: the wrong job label
  # or a missing type filter silently turns a rule into a no-op.
  RULE_FILE="$ROOT/infrastructure/observability/omv-storage-prometheus-rules.yaml"
  expr_of() { yq eval ".spec.groups[].rules[] | select(.alert == \"$1\") | .expr" "$RULE_FILE"; }
  for_of()  { yq eval ".spec.groups[].rules[] | select(.alert == \"$1\") | .for" "$RULE_FILE"; }
  [ "$(expr_of OMVBtrfsDeviceReadErrors)" = 'increase(node_btrfs_device_errors_total{job="omv-node",type="read"}[10m]) > 5' ] \
    && ok "  read errors: increase(omv-node read, 10m) > 5" \
    || bad "  OMVBtrfsDeviceReadErrors expr is not the 10m read-error increase > 5"
  [ "$(expr_of OMVBtrfsSustainedReadErrors)" = 'increase(node_btrfs_device_errors_total{job="omv-node",type="read"}[6h]) > 20' ] \
    && ok "  sustained read errors: increase(omv-node read, 6h) > 20" \
    || bad "  OMVBtrfsSustainedReadErrors expr is not the 6h read-error increase > 20"
  [ "$(for_of OMVBtrfsSustainedReadErrors)" = "30m" ] \
    && ok "  OMVBtrfsSustainedReadErrors waits 30m" \
    || bad "  OMVBtrfsSustainedReadErrors for is $(for_of OMVBtrfsSustainedReadErrors), want 30m"
  [ "$(expr_of OMVBtrfsDeviceCorruptionOrGenerationErrors)" = 'increase(node_btrfs_device_errors_total{job="omv-node",type=~"corruption|generation"}[10m]) > 0' ] \
    && ok "  corruption/generation: any increase of either type (no threshold)" \
    || bad "  corruption/generation rule does not match both types with > 0"
  [ "$(expr_of OMVBtrfsVolumeReadOnly)" = 'node_filesystem_readonly{mountpoint=~"/srv/dev-disk-by-uuid-.*"} == 1' ] \
    && ok "  read-only rule targets the OMV data mountpoints" \
    || bad "  read-only rule does not match the OMV data mountpoints"
  [ "$(expr_of OMVDiskUnreachable)" = 'up{job="omv-node"} == 0' ] \
    && ok "  unreachable rule watches up{job=\"omv-node\"} == 0" \
    || bad "  unreachable rule does not watch the omv-node target"
  [ "$(for_of OMVDiskUnreachable)" = "10m" ] \
    && ok "  OMVDiskUnreachable waits 10m (a reboot does not page)" \
    || bad "  OMVDiskUnreachable for is $(for_of OMVDiskUnreachable), want 10m"

  # The summary has to name the device - "a disk is broken" is not actionable.
  printf '%s\n' "$PR" | grep -qF 'OMV btrfs device {{ $labels.device }} is returning read errors' \
    && ok "  read-error summary names {{ \$labels.device }}" \
    || bad "  read-error summary does not name the device label"
else
  bad "PrometheusRule/omv-storage-alerts not found in the render"
fi

head1 "5. AlertmanagerConfig routing contract"
if [ -n "${AC:-}" ]; then
  ok "AlertmanagerConfig/homelab-node-mattermost-alerts renders"
  # The storage alerts use alertgroup: omv-storage, so the shared route must
  # match it or they fall through to the top-level `receiver: null` - silently.
  printf '%s\n' "$AC" | grep -qF 'value: homelab-node|omv-storage' \
    && ok "  route matches alertgroup =~ homelab-node|omv-storage" \
    || bad "  route does not match alertgroup omv-storage - storage alerts would route to null"
  printf '%s\n' "$AC" | grep -qE '^[[:space:]]*(- )?matchType: *"?=~"?' \
    && ok "  matcher is a regex (=~), needed for the two alert groups" \
    || bad "  matcher is not matchType =~ (exact match would drop one group)"
  printf '%s\n' "$AC" | grep -qE '^[[:space:]]*value: homelab-node$' \
    && bad "  a leftover exact 'homelab-node' matcher would drop omv-storage alerts" \
    || ok "  no exact homelab-node matcher left behind"
  printf '%s\n' "$AC" | grep -qE '^[[:space:]]*name: homelab-node-mattermost-webhook-url$' \
    && ok "  reuses the existing SOPS Mattermost webhook Secret" \
    || bad "  does not reference homelab-node-mattermost-webhook-url"

  # prometheus-operator's OnNamespace matcher strategy injects
  # namespace="<AlertmanagerConfig namespace>" into the generated route. An
  # alert whose namespace label disagrees never reaches Mattermost.
  if [ -n "${PR:-}" ]; then
    ac_ns=$(printf '%s\n' "$AC" | awk '/^[[:space:]]*namespace:/ {print $2; exit}')
    [ "$ac_ns" = "observability" ] \
      && ok "  AlertmanagerConfig lives in observability, same as the rules' namespace label" \
      || bad "  AlertmanagerConfig namespace is ${ac_ns}, rules label observability - routing would fail"
  fi
else
  bad "AlertmanagerConfig/homelab-node-mattermost-alerts not found in the render"
fi

head1 "6. no credential material"
# Comments are skipped - they name the Secret to reuse, they do not hold a value.
if grep -nEi '(password|passwd|api[_-]?key|secret[_-]?key|token|webhook[_-]?url|BEGIN [A-Z ]*PRIVATE KEY)[: ]' \
     "$ROOT/infrastructure/observability/omv-storage-prometheus-rules.yaml" 2>/dev/null \
   | grep -vE ':[0-9]+:[[:space:]]*#' > "$WORK/plain.txt"; then
  bad "plaintext-looking credential material in the new rule file:"
  sed 's/^/        /' "$WORK/plain.txt"
else
  ok "no credential-shaped keys in the new rule file"
fi

printf '\n'
[ "$fail" -eq 0 ] && { echo "RESULT: all checks passed"; exit 0; } || { echo "RESULT: FAILURES above"; exit 1; }
