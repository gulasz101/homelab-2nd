#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# H2-242 validation gate: Hindsight observability (rules + routing + dashboards
# + the two wiring gaps). HAND-RUN ONLY - deliberately NOT listed in
# apps/hindsight/kustomization.yaml, so Flux never reconciles it (same ruling as
# apps/hindsight/tests/render-check.sh).
#
# What it proves, in order:
#   0. the three deliverables exist (RED before they are written)
#   1. the group renders at all            -> kubectl kustomize apps/hindsight
#   2. the whole apps tree still renders   -> regression check on the wiring
#   3. every rendered object validates     -> kubeconform -strict (core schemas
#      + the datreeio CRDs catalog for PrometheusRule / AlertmanagerConfig)
#   4. the PrometheusRule has NO DUPLICATE KEYS and every expr parses
#      -> promtool check rules on the extracted spec. yaml.v3 rejects a duplicate
#      mapping key ("mapping key X already defined at line N"), which is the
#      pitfall the ticket calls out; PromQL parse errors surface as parse errors.
#      AC1 is proven here, by a renderer, not by eye.
#   5. the ROUTING CONTRACT (AC3): prometheus-operator's namespaceEnforcer
#      appends `namespace=<the AlertmanagerConfig's own namespace>` to the route
#      it generates, so every alert the config must route has to carry that exact
#      namespace label. Asserted as an equality between the two files.
#   6. the rule families the ticket names all exist, and every hindsight_* series
#      they reference is in METRIC_TABLE - the exposition reproduced locally from
#      hindsight-api-slim/hindsight_api/metrics.py @ v0.10.3 with
#      opentelemetry-exporter-prometheus 0.65b0 (the exporter folds the OTel unit
#      into the series name, so the docs' example queries are partly wrong).
#   7. the dashboard ConfigMap is a Grafana-sidecar ConfigMap in `observability`
#      holding the 3 upstream dashboards, each valid JSON with panels.
#   8. the HelmRelease exports OTLP traces to the collector and enables the
#      backlog gauges (the only queue-depth signal with worker.enabled=false).
#   9. wiring + secrets: every *.yaml in the group is listed in the
#      kustomization, tests/ is not, no ServiceMonitor is duplicated, no
#      plaintext credential material, and no SOPS file was touched.
#
# Usage:  bash apps/hindsight/tests/observability-check.sh
# Env:    PROMTOOL=/path/to/promtool   (default: promtool on PATH)
#         PROMTOOL_SKIP=1             downgrade a missing promtool to a note
# Exit:   0 = all checks passed, 1 = at least one check failed
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
DIR="$ROOT/apps/hindsight"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

K8S_VERSION=1.31.0
CRD_SCHEMA='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
# -skip Secret: the repo's Secrets are SOPS-encrypted and carry a `sops:` block
# that the strict Secret schema rejects (known, intentional shape).
KUBECONFORM=(kubeconform -strict -summary -kubernetes-version "$K8S_VERSION"
  -skip Secret
  -schema-location default -schema-location "$CRD_SCHEMA")

RULES_FILE="$DIR/hindsight-prometheus-rules.yaml"
AM_FILE="$DIR/hindsight-alertmanager-config.yaml"
DASH_FILE="$DIR/hindsight-dashboard-configmap.yaml"
RELEASE_FILE="$DIR/hindsight-helm-release.yaml"

PROMTOOL=${PROMTOOL:-promtool}
PROMTOOL_SKIP=${PROMTOOL_SKIP:-0}

# The exposition of hindsight 0.10.3, reproduced locally (see the H2-242 tracking
# note for the script). Counter names carry the OTel unit folded in, gauges with a
# UCUM annotation unit ({connections}) keep their plain name, histograms gain the
# mapped unit ("s" -> _seconds). Anything not in this list does not exist.
METRIC_TABLE="
hindsight_operation_operations_total
hindsight_operation_duration_seconds_bucket
hindsight_operation_duration_seconds_sum
hindsight_operation_duration_seconds_count
hindsight_retain_documents_total
hindsight_retain_phase_calls_total
hindsight_retain_phase_duration_seconds_bucket
hindsight_retain_phase_duration_seconds_sum
hindsight_retain_phase_duration_seconds_count
hindsight_llm_calls_total
hindsight_llm_tokens_input_tokens_total
hindsight_llm_tokens_output_tokens_total
hindsight_llm_tokens_cached_input_tokens_total
hindsight_llm_tokens_thoughts_tokens_total
hindsight_llm_duration_seconds_bucket
hindsight_llm_duration_seconds_sum
hindsight_llm_duration_seconds_count
hindsight_consolidation_batch_failures_calls_total
hindsight_event_loop_stalls_total
hindsight_event_loop_lag_seconds_bucket
hindsight_event_loop_lag_seconds_sum
hindsight_event_loop_lag_seconds_count
hindsight_http_requests_total
hindsight_http_requests_in_progress_requests
hindsight_http_duration_seconds_bucket
hindsight_http_duration_seconds_sum
hindsight_http_duration_seconds_count
hindsight_db_pool_size
hindsight_db_pool_idle
hindsight_db_pool_min
hindsight_db_pool_max
hindsight_db_pool_waiting
hindsight_db_pool_acquire_wait_seconds_bucket
hindsight_db_pool_acquire_wait_seconds_sum
hindsight_db_pool_acquire_wait_seconds_count
hindsight_async_operations
hindsight_consolidation_backlog
hindsight_consolidation_failed
hindsight_process_cpu_seconds
hindsight_process_memory_bytes
hindsight_process_open_fds
hindsight_process_threads
"

fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
note() { printf '  note  %s\n' "$1"; }
head1() { printf '\n== %s\n' "$1"; }

has() { grep -q -- "$2" "$1"; }

# Print every `- alert: <name>` block of a rules file, one block per call, so
# label sets can be read without a YAML parser (none is available in this
# workspace; the render-check.sh precedent does the same).
alert_blocks() {
  awk '
    /^        - alert:/ { if (buf != "") printf "%s\x1e", buf; buf = "" }
    { if (buf != "" || /^        - alert:/) buf = buf $0 "\n" }
    END { if (buf != "") printf "%s\x1e", buf }
  ' "$1"
}

# All hindsight_* series names referenced anywhere in a file. Comment lines are
# stripped first: the header comments quote metric names on purpose (including the
# docs' non-existent `hindsight_operation_total` and the source path
# `hindsight_api/metrics.py`), and those must not count as usage.
series_names() {
  grep -v '^[[:space:]]*#' "$1" | grep -oE 'hindsight_[a-z0-9_]+' | sort -u
}

head1 "0. deliverables"
for f in "$RULES_FILE" "$AM_FILE" "$DASH_FILE"; do
  if [ -f "$f" ]; then ok "$(basename "$f") exists"; else bad "$(basename "$f") missing (this is what the ticket delivers)"; fi
done
if [ ! -f "$RULES_FILE" ] || [ ! -f "$AM_FILE" ] || [ ! -f "$DASH_FILE" ]; then
  printf '\n== result: FAIL (deliverables absent - expected before they are written)\n'
  exit 1
fi

head1 "1. render the group"
if kubectl kustomize "$DIR" > "$WORK/group.yaml" 2> "$WORK/kustomize.err"; then
  ok "kubectl kustomize apps/hindsight -> $(grep -c '^kind:' "$WORK/group.yaml") objects"
else
  bad "kubectl kustomize apps/hindsight failed:"; sed 's/^/        /' "$WORK/kustomize.err"; exit 1
fi
G="$WORK/group.yaml"

head1 "2. render the whole apps tree (wiring regression check)"
if kubectl kustomize "$ROOT/apps" > "$WORK/apps.yaml" 2> "$WORK/apps.err"; then
  ok "kubectl kustomize apps -> $(grep -c '^kind:' "$WORK/apps.yaml") objects"
else
  bad "kubectl kustomize apps failed:"; sed 's/^/        /' "$WORK/apps.err"
fi

head1 "3. kubeconform -strict"
if "${KUBECONFORM[@]}" "$G" > "$WORK/kc-group.txt" 2>&1; then
  ok "group render: $(tail -1 "$WORK/kc-group.txt")"
else
  bad "kubeconform rejected the group render:"
  grep -v '^Summary:' "$WORK/kc-group.txt" | sed 's/^/        /'
fi
if "${KUBECONFORM[@]}" "$WORK/apps.yaml" > "$WORK/kc-apps.txt" 2>&1; then
  ok "apps render: $(tail -1 "$WORK/kc-apps.txt")"
else
  bad "kubeconform rejected the apps render:"
  grep -v '^Summary:' "$WORK/kc-apps.txt" | sed 's/^/        /'
fi
# The rendered group must actually contain the two observability CRs.
grep -q '^kind: PrometheusRule' "$G" && ok "PrometheusRule is in the group render" \
  || bad "no PrometheusRule in the group render"
grep -q '^kind: AlertmanagerConfig' "$G" && ok "AlertmanagerConfig is in the group render" \
  || bad "no AlertmanagerConfig in the group render"

head1 "4. AC1: no duplicate keys, every expr parses (promtool)"
# Extract the CR's spec as a plain rule file: `groups:` at column 0, body dedented
# by 2. yaml.v3 (what promtool uses) fails on a duplicate mapping key, which is
# the silent Kustomization-freezer the ticket warns about.
sed -n '/^spec:$/,$p' "$RULES_FILE" | tail -n +2 | sed 's/^  //' > "$WORK/rules.yaml"
if [ ! -s "$WORK/rules.yaml" ]; then
  bad "could not extract spec: from $(basename "$RULES_FILE")"
elif [ "$PROMTOOL_SKIP" = "1" ]; then
  note "PROMTOOL_SKIP=1 - duplicate-key + PromQL parse check SKIPPED (AC1 unproven)"
elif command -v "$PROMTOOL" >/dev/null 2>&1; then
  if "$PROMTOOL" check rules "$WORK/rules.yaml" > "$WORK/promtool.txt" 2>&1; then
    ok "promtool check rules: $(grep -c '^        - alert:' "$WORK/rules.yaml") rules parsed, no duplicate keys"
  else
    bad "promtool rejected the rules (duplicate key or bad PromQL):"
    sed 's/^/        /' "$WORK/promtool.txt"
  fi
  # A duplicate key is also caught by comparing the alert count of the extracted
  # spec against the raw file (belt and braces for the AC's wording).
  raw=$(grep -c '^        - alert:' "$RULES_FILE")
  parsed=$(grep -c '^        - alert:' "$WORK/rules.yaml")
  [ "$raw" = "$parsed" ] && ok "alert count survives the render ($raw == $parsed)" \
    || bad "alert count differs between file ($raw) and extracted spec ($parsed)"
else
  bad "promtool not found - AC1 (duplicate keys + PromQL parse) is NOT proven. Install it (brew install prometheus) or set PROMTOOL=/path/to/promtool; PROMTOOL_SKIP=1 downgrades this to a note."
fi

head1 "5. AC3: routing contract (rule namespace label == AlertmanagerConfig namespace)"
am_ns=$(awk '/^metadata:$/{m=1;next} m&&/^  namespace:/{print $2;exit}' "$AM_FILE")
if [ -z "$am_ns" ]; then
  bad "no metadata.namespace in $(basename "$AM_FILE")"
else
  ok "AlertmanagerConfig lives in namespace '$am_ns'"
  # prometheus-operator (pkg/alertmanager/amcfg.go, namespaceEnforcer.processRoute)
  # appends namespace=<config namespace> to the generated route, so a rule whose
  # alert label says anything else can never reach the receiver.
  mismatch=0
  total=0
  while IFS= read -r -d $'\x1e' block; do
    [ -z "$block" ] && continue
    name=$(printf '%s' "$block" | sed -n 's/^        - alert: *//p' | head -1)
    ns=$(printf '%s' "$block" | sed -n 's/^            namespace: *//p' | head -1)
    total=$((total + 1))
    if [ "$ns" != "$am_ns" ]; then
      bad "alert $name carries namespace='${ns:-<none>}' but the AlertmanagerConfig is in '$am_ns' - it will never route"
      mismatch=$((mismatch + 1))
    fi
  done < <(alert_blocks "$RULES_FILE")
  [ "$mismatch" -eq 0 ] && ok "all $total alerts carry namespace: $am_ns"
fi
# Every alert must also be labelled with the route matcher and a severity, or the
# route matches nothing / Alertmanager cannot group it.
missing_label=0
while IFS= read -r -d $'\x1e' block; do
  [ -z "$block" ] && continue
  name=$(printf '%s' "$block" | sed -n 's/^        - alert: *//p' | head -1)
  for key in severity alertgroup namespace; do
    printf '%s' "$block" | grep -q "^            $key: " || { bad "alert $name has no '$key' label"; missing_label=1; }
  done
  printf '%s' "$block" | grep -q '^            alertgroup: hindsight$' || { bad "alert $name alertgroup is not 'hindsight' (the route matcher)"; missing_label=1; }
done < <(alert_blocks "$RULES_FILE")
[ "$missing_label" -eq 0 ] && ok "every alert carries severity + alertgroup: hindsight + the routing namespace"

head1 "6. rule families + the metric-name table"
for pair in \
  "HindsightApiTargetMissing:hindsight-api" \
  "HindsightApiNoAvailableReplica:hindsight-api" \
  "HindsightControlPlaneNoAvailableReplica:hindsight-control-plane" \
  "HindsightOperationFailures:hindsight_operation_operations_total" \
  "HindsightNoFactsShareHigh:hindsight_retain_documents_total" \
  "HindsightNoFactsShareCritical:hindsight_retain_documents_total" \
  "HindsightLlmCallFailureRateHigh:hindsight_llm_calls_total" \
  "HindsightLlmTokenBurnHigh:hindsight_llm_tokens_input_tokens_total" \
  "HindsightLlmTokenBurnHigh:hindsight_llm_tokens_output_tokens_total" \
  "HindsightConsolidationSchemaRejections:hindsight_consolidation_batch_failures_calls_total" \
  "HindsightDbPoolWaiting:hindsight_db_pool_waiting" \
  "HindsightDbPoolNearlyFull:hindsight_db_pool_max" \
  "HindsightApiLatencyHigh:hindsight_http_duration_seconds_bucket" \
  "HindsightPostgresDown:cnpg_collector_up" \
  "HindsightDatabaseInstanceNotReady:kube_pod_status_ready" \
  "HindsightDbPvcAbove80Percent:kubelet_volume_stats_used_bytes" \
  "HindsightAsyncOperationsStranded:hindsight_async_operations" \
  "HindsightConsolidationBacklogHigh:hindsight_consolidation_backlog"
do
  alert=${pair%%:*}; metric=${pair#*:}
  if has "$RULES_FILE" "$metric" && has "$RULES_FILE" "- alert: $alert"; then
    ok "$alert uses $metric"
  else
    bad "$alert is missing, or does not use $metric"
  fi
done
# The ticket's exact wording for the availability rule: absent(up{...}) is only
# valid where the target is genuinely scraped. The control plane exposes no
# /metrics and the chart renders no ServiceMonitor for it, so it must be alerted
# on kube-state-metrics, not on `up`.
if has "$RULES_FILE" 'absent(up{'; then
  if grep -E 'absent\(up\{' "$RULES_FILE" | grep -qv 'pod=~"hindsight-api-.*"'; then
    bad "an absent(up{...}) targets something that is not the scraped api pod:"
    grep -n 'absent(up{' "$RULES_FILE" | sed 's/^/        /'
  else
    ok "the only absent(up{...}) targets the scraped api pod (the control plane is alerted via kube_deployment_status_replicas_available)"
  fi
fi
# D2: every hindsight_* series the rules reference must exist in the exposition.
unknown=0
while IFS= read -r s; do
  grep -qx "$s" <<<"$METRIC_TABLE" || { bad "rule references $s, which is NOT in the reproduced exposition table"; unknown=1; }
done < <(series_names "$RULES_FILE")
[ "$unknown" -eq 0 ] && ok "every hindsight_* series in the rules exists in the reproduced exposition"
# And the docs' wrong name must not appear anywhere outside a comment.
if grep -v '^[[:space:]]*#' "$RULES_FILE" | grep -q 'hindsight_operation_total[^_]' 2>/dev/null; then
  bad "the rules use hindsight_operation_total - that series does not exist (the unit is folded in: hindsight_operation_operations_total)"
else
  ok "the rules do not use the docs' non-existent hindsight_operation_total"
fi

head1 "7. dashboards"
if ! command -v jq >/dev/null 2>&1; then
  note "jq not found - dashboard JSON checks skipped"
else
  # ConfigMap shape: the Grafana sidecar watches label grafana_dashboard=1 in any
  # namespace (searchNamespaces unset) and puts each dashboard in the folder named
  # by the grafana.folder annotation - every other app dashboard in this repo
  # lives in `observability` with the same shape.
  jq -e '.kind=="ConfigMap"' "$DASH_FILE" >/dev/null 2>&1 \
    && ok "the dashboard file is a ConfigMap" || bad "the dashboard file is not a ConfigMap"
  [ "$(jq -r '.metadata.labels.grafana_dashboard // ""' "$DASH_FILE")" = "1" ] \
    && ok "labelled grafana_dashboard: \"1\"" || bad "missing label grafana_dashboard: \"1\""
  [ "$(jq -r '.metadata.annotations["grafana.folder"] // ""' "$DASH_FILE")" = "hindsight" ] \
    && ok "annotated grafana.folder: hindsight" || bad "missing/incorrect grafana.folder annotation"
  [ "$(jq -r '.metadata.namespace' "$DASH_FILE")" = "observability" ] \
    && ok "lives in namespace observability (where the sidecar and every sibling dashboard are)" \
    || bad "the dashboard ConfigMap is not in observability"
  dash_count=$(jq -r '.data | keys | length' "$DASH_FILE")
  [ "$dash_count" = "3" ] && ok "3 dashboards in the ConfigMap" || bad "expected 3 dashboards, found $dash_count"
  for key in hindsight-operations.json hindsight-llm.json hindsight-api-service.json; do
    if jq -r --arg k "$key" '.data[$k]' "$DASH_FILE" > "$WORK/$key" 2>/dev/null && [ -s "$WORK/$key" ]; then
      title=$(jq -r '.title' "$WORK/$key")
      uid=$(jq -r '.uid' "$WORK/$key")
      panels=$(jq -r '.panels | length' "$WORK/$key")
      targets=$(jq -r '[.panels[]?.targets[]?] | length' "$WORK/$key")
      if [ -n "$title" ] && [ "$title" != "null" ] && [ "$panels" -gt 0 ] && [ "$targets" -gt 0 ]; then
        ok "$key: '$title' (uid $uid, $panels panels, $targets targets)"
      else
        bad "$key has no title/panels/targets"
      fi
      # Every hindsight_* series a dashboard queries must exist too (D2).
      while IFS= read -r s; do
        grep -qx "$s" <<<"$METRIC_TABLE" || bad "$key queries $s, which is NOT in the reproduced exposition table"
      done < <(series_names "$WORK/$key")
    else
      bad "$key is missing from the ConfigMap data"
    fi
  done
fi

head1 "8. HelmRelease wiring: Tempo traces + backlog gauges (D4)"
has "$RELEASE_FILE" 'HINDSIGHT_API_OTEL_TRACES_ENABLED: "true"' \
  && ok "OTLP traces enabled (otel_traces_enabled defaults to false upstream)" \
  || bad "HINDSIGHT_API_OTEL_TRACES_ENABLED is not set to \"true\""
has "$RELEASE_FILE" 'http://opentelemetry-collector.observability.svc.cluster.local:4318' \
  && ok "OTLP endpoint is the collector's HTTP port in observability (4318)" \
  || bad "OTLP endpoint is not the collector service in observability:4318"
has "$RELEASE_FILE" 'HINDSIGHT_API_OTEL_SERVICE_NAME: "hindsight-api"' \
  && ok "OTEL service name is hindsight-api" || bad "HINDSIGHT_API_OTEL_SERVICE_NAME is not set"
has "$RELEASE_FILE" 'HINDSIGHT_API_METRICS_BACKLOG_ENABLED: "true"' \
  && ok "backlog gauges enabled (the only queue-depth signal with worker.enabled=false)" \
  || bad "HINDSIGHT_API_METRICS_BACKLOG_ENABLED is not set to \"true\""
grep -q 'namespace: monitoring' "$RELEASE_FILE" \
  && bad "the OTLP endpoint points at namespace 'monitoring', which does not exist in this repo" \
  || ok "the OTLP endpoint does not point at the non-existent 'monitoring' namespace"

head1 "9. wiring and secrets"
missing=0
while IFS= read -r file; do
  name=$(basename "$file")
  [ "$name" = "kustomization.yaml" ] && continue
  grep -q -- "- $name\$" "$DIR/kustomization.yaml" || { bad "$name is not listed in apps/hindsight/kustomization.yaml"; missing=1; }
done < <(find "$DIR" -maxdepth 1 -name '*.yaml' | sort)
[ "$missing" -eq 0 ] && ok "all $(find "$DIR" -maxdepth 1 -name '*.yaml' | wc -l) manifest files are wired"
grep -q 'tests/' "$DIR/kustomization.yaml" \
  && bad "the hand-run tests/ directory is wired into the kustomization" \
  || ok "tests/ is not wired (hand-run only, Flux never reconciles it)"

# The ServiceMonitor must NOT be duplicated: it comes from the HelmRelease
# (metrics.serviceMonitor, label release: prometheus-stack).
sm=$(grep -l '^kind: ServiceMonitor' "$DIR"/*.yaml 2>/dev/null | wc -l)
[ "$sm" -eq 0 ] && ok "no hand-written ServiceMonitor in the group (the chart's one is not duplicated)" \
  || bad "a ServiceMonitor was added by hand: $(grep -l '^kind: ServiceMonitor' "$DIR"/*.yaml | tr '\n' ' ')"

# Plaintext credential material in the files this ticket adds.
if grep -nEi '(password|passwd|token|api[_-]?key|secret|webhook[_-]?url): *[^ ]' "$RULES_FILE" "$AM_FILE" "$DASH_FILE" > "$WORK/plain.txt" 2>/dev/null; then
  if grep -vEi 'secretName|existingSecret|urlSecret|name:|key:|keyRef|secretRef|secretKeyRef|namespace:|grafana_dashboard' "$WORK/plain.txt" > "$WORK/plain-real.txt" && [ -s "$WORK/plain-real.txt" ]; then
    bad "possible plaintext secret material:"; sed 's/^/        /' "$WORK/plain-real.txt"
  else
    ok "no plaintext secret values in the new manifests"
  fi
else
  ok "no plaintext secret values in the new manifests"
fi
# No SOPS file may be touched by this work.
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  touched=$(git -C "$ROOT" status --porcelain -- '*.sops.yaml' | wc -l)
  [ "$touched" -eq 0 ] && ok "no *.sops.yaml file is modified" \
    || { bad "a SOPS-encrypted file was modified:"; git -C "$ROOT" status --porcelain -- '*.sops.yaml' | sed 's/^/        /'; }
fi

printf '\n== result: %s\n' "$([ "$fail" -eq 0 ] && echo PASS || echo FAIL)"
exit "$fail"
