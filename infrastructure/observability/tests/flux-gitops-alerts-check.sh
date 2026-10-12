#!/usr/bin/env bash
# Render + validate check for the Flux GitOps deployment-health alerting
# (H2-223). Same shape as apps/zigbee/tests/render-check.sh: it renders the
# Kustomization that Flux actually applies, validates the objects with
# kubeconform -strict, and then asserts the properties a schema cannot express
# (rule labels, routing matchers, secret shape).
#
# Not listed in infrastructure/kustomization.yaml on purpose - Flux never sees
# this directory.
#
# Usage: infrastructure/observability/tests/flux-gitops-alerts-check.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

K8S_VERSION=1.31.0
CRD_SCHEMA='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
# -skip Secret: this repo's Secrets are SOPS-encrypted and carry a `sops:`
# metadata block that the strict Secret schema rejects - a known, intentional
# shape. Secrets are checked directly instead (section 7).
KUBECONFORM=(kubeconform -strict -summary -kubernetes-version "$K8S_VERSION"
  -skip Secret
  -schema-location default -schema-location "$CRD_SCHEMA")

fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
note() { printf '  note  %s\n' "$1"; }
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

# Non-empty output of block() means the document was found.
block_found() { [ -n "$1" ]; }

# Collect the objects this work introduces so they can be validated strictly,
# with CRD schemas, on their own.
collect_own() {
  local kind="$1" name="$2"
  if b=$(block "$kind" "$name" "$RENDER") && block_found "$b"; then
    printf '%s\n---\n' "$b" >> "$OWN"
    return 0
  fi
  return 1
}

head1 "1. wiring"
grep -q '^  - observability/flux-controller-podmonitor.yaml$' "$ROOT/infrastructure/kustomization.yaml" \
  && ok "infrastructure/kustomization.yaml wires the flux PodMonitor" \
  || bad "infrastructure/kustomization.yaml does not reference observability/flux-controller-podmonitor.yaml"
grep -q '^  - observability/flux-gitops-prometheus-rules.yaml$' "$ROOT/infrastructure/kustomization.yaml" \
  && ok "infrastructure/kustomization.yaml wires the flux PrometheusRule" \
  || bad "infrastructure/kustomization.yaml does not reference observability/flux-gitops-prometheus-rules.yaml"
grep -q '^  - observability/flux-gitops-alertmanager-config.yaml$' "$ROOT/infrastructure/kustomization.yaml" \
  && ok "infrastructure/kustomization.yaml wires the flux AlertmanagerConfig" \
  || bad "infrastructure/kustomization.yaml does not reference observability/flux-gitops-alertmanager-config.yaml"

head1 "2. render infrastructure"
if kubectl kustomize "$ROOT/infrastructure" > "$RENDER" 2> "$WORK/kustomize.err"; then
  ok "kubectl kustomize infrastructure -> $(grep -c '^kind:' "$RENDER") objects"
else
  bad "kubectl kustomize infrastructure failed:"
  sed 's/^/        /' "$WORK/kustomize.err"
fi

head1 "3. kubeconform -strict"
: > "$OWN"
collect_own PodMonitor flux-controllers        || true
collect_own PrometheusRule flux-gitops-alerts  || true
collect_own AlertmanagerConfig flux-gitops-mattermost-alerts || true
if [ -s "$OWN" ]; then
  # Strict, with the datree CRD catalog, over exactly the objects this work adds.
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
# The whole render, tolerating the two pre-existing objects that have no
# published schema: the barman-cloud CRD and the SOPS-encrypted manifest whose
# kind/name are ciphertext. Everything else must still validate.
if [ -s "$RENDER" ]; then
  if kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version "$K8S_VERSION" \
       -skip Secret -schema-location default -schema-location "$CRD_SCHEMA" \
       "$RENDER" > "$WORK/kc.txt" 2>&1; then
    ok "whole render (schema-less objects skipped): $(tail -1 "$WORK/kc.txt")"
  else
    bad "kubeconform rejected the infrastructure render:"
    grep -v '^Summary:' "$WORK/kc.txt" | sed 's/^/        /'
  fi
fi

head1 "4. PodMonitor flux-controllers (flux-system controller metrics)"
if PM=$(block PodMonitor flux-controllers "$RENDER") && block_found "$PM"; then
  ok "PodMonitor/flux-controllers renders"
  printf '%s\n' "$PM" | grep -q '^  namespace: flux-system$' \
    && ok "  lives in flux-system" || bad "  not in flux-system"
  printf '%s\n' "$PM" | grep -q '^    - flux-system$' \
    && ok "  namespaceSelector matchNames: [flux-system]" || bad "  namespaceSelector does not pin flux-system"
  printf '%s\n' "$PM" | grep -q '^      app.kubernetes.io/part-of: flux$' \
    && ok "  selects app.kubernetes.io/part-of: flux" || bad "  selector does not use part-of: flux"
  printf '%s\n' "$PM" | grep -q '^    port: http-prom$' \
    && ok "  scrapes the named port http-prom" || bad "  does not scrape http-prom"
  printf '%s\n' "$PM" | grep -q '^    path: /metrics$' \
    && ok "  path /metrics" || bad "  path is not /metrics"
else
  bad "PodMonitor/flux-controllers not found in the render"
fi

head1 "5. PrometheusRule flux-gitops-alerts"
if PR=$(block PrometheusRule flux-gitops-alerts "$RENDER") && block_found "$PR"; then
  ok "PrometheusRule/flux-gitops-alerts renders"
  printf '%s\n' "$PR" | grep -q '^  namespace: observability$' \
    && ok "  lives in observability (the Prometheus ruleNamespaceSelector is {})" \
    || bad "  not in observability"
  # The trap this work exists to avoid: the Prometheus CR's ruleSelector is
  # {matchLabels: {release: prometheus-stack}}, so a rule without that label is
  # silently ignored.
  printf '%s\n' "$PR" | grep -q '^    release: prometheus-stack$' \
    && ok "  carries label release: prometheus-stack (ruleSelector match)" \
    || bad "  missing label release: prometheus-stack - Prometheus would ignore this rule"
  for a in FluxKustomizationNotReady FluxHelmReleaseNotReady FluxGitRepositoryNotReady FluxKustomizationRevisionLagging; do
    printf '%s\n' "$PR" | grep -q "^        - alert: ${a}$" \
      && ok "  rule ${a}" || bad "  rule ${a} missing"
  done
  # Every alert must carry the label the AlertmanagerConfig routes on, and a
  # namespace label for the Mattermost message title.
  n_alerts=$(printf '%s\n' "$PR" | grep -c '^        - alert: ')
  n_group=$(printf '%s\n' "$PR" | grep -c '^            alertgroup: flux-gitops$')
  n_ns=$(printf '%s\n' "$PR" | grep -c '^            namespace: flux-system$')
  [ "$n_alerts" -eq "$n_group" ] && [ "$n_alerts" -eq "$n_ns" ] \
    && ok "  all ${n_alerts} alerts carry alertgroup: flux-gitops and namespace: flux-system" \
    || bad "  ${n_alerts} alerts but ${n_group} alertgroup / ${n_ns} namespace labels"
else
  bad "PrometheusRule/flux-gitops-alerts not found in the render"
fi

head1 "6. AlertmanagerConfig flux-gitops-mattermost-alerts"
if AC=$(block AlertmanagerConfig flux-gitops-mattermost-alerts "$RENDER") && block_found "$AC"; then
  ok "AlertmanagerConfig/flux-gitops-mattermost-alerts renders"
  printf '%s\n' "$AC" | grep -q '^  namespace: observability$' \
    && ok "  lives in observability (next to the Alertmanager)" || bad "  not in observability"
  printf '%s\n' "$AC" | grep -q '^    release: kube-prometheus-stack$' \
    && ok "  carries label release: kube-prometheus-stack (alertmanagerConfigSelector match)" \
    || bad "  missing label release: kube-prometheus-stack - Alertmanager would ignore this config"
  printf '%s\n' "$AC" | grep -q '^        value: flux-gitops$' \
    && ok "  routes on alertgroup = flux-gitops" || bad "  route matcher does not use alertgroup"
  printf '%s\n' "$AC" | grep -q '^          sendResolved: true$' \
    && ok "  sendResolved: true (resolution is part of AC4)" || bad "  sendResolved missing"
  printf '%s\n' "$AC" | grep -q '^            name: homelab-node-mattermost-webhook-url$' \
    && ok "  reuses the existing SOPS Mattermost webhook Secret" \
    || bad "  does not reference homelab-node-mattermost-webhook-url"
else
  bad "AlertmanagerConfig/flux-gitops-mattermost-alerts not found in the render"
fi

head1 "7. secret shape"
WEBHOOK="$ROOT/infrastructure/observability/homelab-node-mattermost-webhook-url.sops.yaml"
if [ -f "$WEBHOOK" ]; then
  grep -q '^sops:$' "$WEBHOOK" \
    && grep -q '^    age:$' "$WEBHOOK" \
    && grep -q 'BEGIN AGE ENCRYPTED FILE' "$WEBHOOK" \
    && grep -q '^    encrypted_regex: \^(data|stringData)\$$' "$WEBHOOK" \
    && ok "Mattermost webhook Secret is SOPS/age encrypted (age recipient + encrypted_regex)" \
    || bad "Mattermost webhook Secret is not SOPS/age encrypted"
else
  bad "homelab-node-mattermost-webhook-url.sops.yaml missing"
fi
# The new files must not carry any credential material.
if grep -nEi '(password|passwd|api[_-]?key|secret[_-]?key|token|webhook[_-]?url|BEGIN [A-Z ]*PRIVATE KEY)[: ]' \
     "$ROOT"/infrastructure/observability/flux-*.yaml > "$WORK/plain.txt" 2>/dev/null; then
  bad "plaintext-looking credential material in the new manifests:"
  sed 's/^/        /' "$WORK/plain.txt"
else
  ok "no credential-shaped keys in the new manifests"
fi

head1 "8. prometheus-stack HelmRelease: kube-state-metrics custom resource state"
HR="$ROOT/infrastructure/observability/prometheus-stack-helm-release.yaml"
# The values: block of the HelmRelease, dedented by 4 spaces.
extract_values() {
  awk '
    /^  values:$/ { f = 1; next }
    f && (/^[^ ]/ || /^  [^ ]/) { f = 0 }
    f { sub(/^    /, ""); print }
  ' "$1"
}
if extract_values "$HR" > "$WORK/ps.values.yaml" && [ -s "$WORK/ps.values.yaml" ]; then
  ok "extracted $(wc -l < "$WORK/ps.values.yaml") lines of HelmRelease values"
else
  bad "could not extract the values: block from prometheus-stack-helm-release.yaml"
fi
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
if helm template flux-check prometheus-community/kube-prometheus-stack \
     --version '>=69.0.0' --skip-tests -f "$WORK/ps.values.yaml" \
     > "$WORK/ps.render.yaml" 2> "$WORK/ps.render.err"; then
  ok "helm template kube-prometheus-stack (>=69.0.0) with the live values"
  CRS=$(awk '/customresourcestate-config$/{f=1} f{print} f&&/^---$/{exit}' "$WORK/ps.render.yaml")
  printf '%s\n' "$CRS" | grep -q '^    spec:$' \
    && ok "  custom resource state ConfigMap renders" || bad "  no custom resource state ConfigMap in the render"
  for k in Kustomization GitRepository HelmRelease; do
    printf '%s\n' "$CRS" | grep -q "^          kind: ${k}$" \
      && ok "  exposes ${k}" || bad "  ${k} missing from the custom resource state config"
  done
  printf '%s\n' "$CRS" | grep -q '^        metricNamePrefix: gotk$' \
    && ok "  metric prefix gotk -> gotk_resource_info" || bad "  metric prefix is not gotk"
  # toYaml expands the flow sequences, so match the block rather than one line.
  # crs_revision_is <path> : the revision label of some resource must resolve
  # exactly to that path, e.g. "status/lastAppliedRevision".
  crs_revision_is() {
    printf '%s\n' "$CRS" | awk -v path="$1" '
      BEGIN { n = split(path, want, "/") }
      /^            revision:$/ {
        ok = 1
        for (i = 1; i <= n; i++) {
          if ((getline l) <= 0) { ok = 0; break }
          if (l != "            - " want[i]) { ok = 0; break }
        }
        if (ok) found = 1
      }
      END { exit(found ? 0 : 1) }'
  }
  crs_revision_is status/lastAppliedRevision \
    && ok "  Kustomization revision <- status.lastAppliedRevision" \
    || bad "  Kustomization revision is not status.lastAppliedRevision"
  crs_revision_is status/artifact/revision \
    && ok "  GitRepository revision <- status.artifact.revision" \
    || bad "  GitRepository revision is not status.artifact.revision"
  grep -q -- '--custom-resource-state-config-file=' "$WORK/ps.render.yaml" \
    && ok "  kube-state-metrics is pointed at the config file" || bad "  kube-state-metrics has no custom resource state config file argument"
  grep -q -- '--custom-resource-state-only' "$WORK/ps.render.yaml" \
    && bad "  --custom-resource-state-only is set: the default kube_* collectors would be dropped" \
    || ok "  default collectors kept (no --custom-resource-state-only)"
  grep -q -- '--resources=.*pods' "$WORK/ps.render.yaml" \
    && ok "  the pod/node/etc collectors are still enabled" \
    || bad "  the default collectors are gone - existing dashboards would break"
  grep -q -- '- kustomizations' "$WORK/ps.render.yaml" \
    && grep -q -- '- gitrepositories' "$WORK/ps.render.yaml" \
    && grep -q -- '- helmreleases' "$WORK/ps.render.yaml" \
    && ok "  ClusterRole grants list/watch on the three Flux kinds" \
    || bad "  ClusterRole does not grant the Flux resources"
else
  bad "helm template failed:"
  grep -v '^$' "$WORK/ps.render.err" | head -10 | sed 's/^/        /'
fi


printf '\n'
[ "$fail" -eq 0 ] && { echo "RESULT: all checks passed"; exit 0; } || { echo "RESULT: FAILURES above"; exit 1; }