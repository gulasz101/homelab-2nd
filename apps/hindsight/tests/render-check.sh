#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# H2-238 validation gate for the Hindsight HelmRelease.
# HAND-RUN ONLY - this file is deliberately NOT listed in
# apps/hindsight/kustomization.yaml, so Flux never reconciles it (same ruling
# as apps/zigbee/tests/ and apps/mail-archiver/drill/).
#
# What it proves, in order:
#   1. the group renders at all           -> kubectl kustomize apps/hindsight
#   2. the whole apps tree still renders  -> regression check on the wiring
#   3. every rendered object validates    -> kubeconform -strict (core schemas
#      + the datreeio CRDs catalog for HelmRepository / HelmRelease /
#      ServiceMonitor)
#   4. the pinned chart really renders with OUR values -> helm template against
#      the OCI registry, values extracted from the HelmRelease itself
#   5. the ticket's acceptance criteria are visible in the render: the rendered
#      HINDSIGHT_API_DATABASE_URL, POSTGRES_PASSWORD defined *before* it,
#      liveness /health/live vs readiness /health, slim pinned images, no
#      chart-managed Secret/PVC, worker off, CPU TEI on, ServiceMonitor with
#      the prometheus-stack label
#   6. every manifest on disk is wired into the kustomization (the classic
#      "wrote the file, forgot the wiring" bug) and nothing plaintext leaked in
#
# Usage:  bash apps/hindsight/tests/render-check.sh
# Exit:   0 = all checks passed, 1 = at least one check failed
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
DIR="$ROOT/apps/hindsight"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

K8S_VERSION=1.31.0
CRD_SCHEMA='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
# -skip Secret: this repo's Secrets are SOPS-encrypted and carry a `sops:`
# metadata block that the strict Secret schema rejects. That is a known,
# intentional shape, so Secrets are skipped and asserted directly instead
# (section 6b).
KUBECONFORM=(kubeconform -strict -summary -kubernetes-version "$K8S_VERSION"
  -skip Secret
  -schema-location default -schema-location "$CRD_SCHEMA")

# The chart source. Asserted against the HelmRepository manifest in section 5a
# so the two can never silently drift.
OCI_REPO_URL='oci://ghcr.io/vectorize-io/charts'
CHART_NAME='hindsight'

fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
note() { printf '  note  %s\n' "$1"; }
head1() { printf '\n== %s\n' "$1"; }

# Pull the `values:` block out of a HelmRelease and dedent it by 4 spaces.
extract_values() {
  awk '
    /^  values:/ { invalues = 1; next }
    invalues {
      if ($0 ~ /^[^ ]/ || $0 ~ /^  [^ ]/) exit
      sub(/^    /, ""); print
    }
  ' "$1"
}

# metadata.name of a top-level manifest.
read_meta_name() {
  awk '
    /^metadata:$/ { inx = 1; next }
    inx && /^[^ ]/ { exit }
    inx && /^  name:/ { v = $2; gsub(/"/, "", v); print v; exit }
  ' "$1"
}

# One scalar under a spec-nested section: read_scalar <file> <section> <key>
# e.g. read_scalar file chart version  ->  spec.chart.version
read_scalar() {
  awk -v section="$2" -v key="$3" '
    $0 ~ "^  " section ":" { inx = 1; next }
    inx && /^  [^ ]/ { exit }
    inx && $1 == key":" { v = $2; gsub(/"/, "", v); print v; exit }
  ' "$1"
}

# Print the YAML document whose `kind:` is $1, whose metadata.name is $2, from
# file $3. Documents are separated by a line of exactly `---`.
doc_by_name() {
  awk -v want_kind="$1" -v want_name="$2" '
    function flush() { if (is_kind && is_name) printf "%s", buf }
    /^---$/ { flush(); buf = ""; is_kind = 0; is_name = 0; seen_name = 0; next }
    {
      buf = buf $0 "\n"
      if ($0 == "kind: " want_kind) is_kind = 1
      if (!seen_name && $0 == "  name: " want_name) { is_name = 1; seen_name = 1 }
    }
    END { flush() }
  ' "$3"
}

has() { grep -q -- "$2" "$1"; }

REPO_FILE="$DIR/hindsight-helm-repository.yaml"
RELEASE_FILE="$DIR/hindsight-helm-release.yaml"

head1 "0. layout"
[ -d "$DIR" ] || { bad "apps/hindsight/ does not exist"; exit 1; }
[ -f "$DIR/kustomization.yaml" ] \
  && ok "apps/hindsight/kustomization.yaml exists" \
  || bad "apps/hindsight/kustomization.yaml missing"
grep -q '^  - hindsight/$' "$ROOT/apps/kustomization.yaml" \
  && ok "apps/kustomization.yaml wires the hindsight group" \
  || bad "apps/kustomization.yaml does not reference hindsight/"
[ -f "$REPO_FILE" ] \
  && ok "$(basename "$REPO_FILE") exists" \
  || bad "$(basename "$REPO_FILE") missing (this is what the ticket delivers)"
[ -f "$RELEASE_FILE" ] \
  && ok "$(basename "$RELEASE_FILE") exists" \
  || bad "$(basename "$RELEASE_FILE") missing (this is what the ticket delivers)"
[ -f "$REPO_FILE" ] && [ -f "$RELEASE_FILE" ] \
  || { printf '\n== result: FAIL (deliverables absent - expected before they are written)\n'; exit 1; }

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

head1 "3. kubeconform -strict on the group render"
if "${KUBECONFORM[@]}" "$G" > "$WORK/kc-group.txt" 2>&1; then
  ok "$(tail -1 "$WORK/kc-group.txt")"
else
  bad "kubeconform rejected the group render:"
  grep -v '^Summary:' "$WORK/kc-group.txt" | sed 's/^/        /'
fi

head1 "4. helm template the pinned chart with the HelmRelease's own values"
chart=$(read_scalar "$RELEASE_FILE" chart chart)
version=$(read_scalar "$RELEASE_FILE" chart version)
release=$(read_meta_name "$RELEASE_FILE")
[ -n "$chart" ] && [ -n "$version" ] && [ -n "$release" ] \
  && ok "parsed from the HelmRelease: release=$release chart=$chart version=$version" \
  || bad "could not parse metadata.name / chart / chart version from $(basename "$RELEASE_FILE")"

if [ -n "$chart" ] && [ -n "$version" ] && [ -n "$release" ]; then
  extract_values "$RELEASE_FILE" > "$WORK/values.yaml"
  [ -s "$WORK/values.yaml" ] && ok "extracted $(wc -l < "$WORK/values.yaml") lines of values" \
    || bad "no values block extracted from the HelmRelease"
  if helm template "$release" "$OCI_REPO_URL/$chart" --version "$version" \
       --namespace hindsight -f "$WORK/values.yaml" > "$WORK/render.yaml" 2> "$WORK/render.err"; then
    ok "helm template $chart-$version -> $(grep -c '^kind:' "$WORK/render.yaml") objects"
  else
    bad "helm template failed:"; sed 's/^/        /' "$WORK/render.err"
    printf '\n== result: FAIL\n'; exit 1
  fi
  if "${KUBECONFORM[@]}" "$WORK/render.yaml" > "$WORK/kc-render.txt" 2>&1; then
    ok "kubeconform on the chart render: $(tail -1 "$WORK/kc-render.txt")"
  else
    bad "kubeconform rejected the chart render:"
    grep -v '^Summary:' "$WORK/kc-render.txt" | sed 's/^/        /'
  fi
else
  bad "skipping the chart render - chart coordinates unknown"
fi
R="$WORK/render.yaml"

doc_by_name Deployment "$release-api" "$R"          > "$WORK/api-doc.yaml"
doc_by_name Deployment "$release-control-plane" "$R" > "$WORK/cp-doc.yaml"
doc_by_name Deployment "$release-tei-embedding" "$R" > "$WORK/tei-emb.yaml"
doc_by_name Deployment "$release-tei-reranker" "$R"  > "$WORK/tei-rer.yaml"
doc_by_name ServiceMonitor "$release-api" "$R"       > "$WORK/sm-doc.yaml"
API="$WORK/api-doc.yaml"; CP="$WORK/cp-doc.yaml"
EMB="$WORK/tei-emb.yaml"; RER="$WORK/tei-rer.yaml"; SM="$WORK/sm-doc.yaml"

head1 "5. acceptance-criteria properties"

# 5a. the HelmRepository is an OCI source with the expected url in flux-system.
if grep -q '^kind: HelmRepository' "$G"; then
  has "$G" 'type: oci' && ok "HelmRepository type: oci" || bad "HelmRepository is not type: oci"
  has "$G" "$OCI_REPO_URL" && ok "HelmRepository url is $OCI_REPO_URL" \
    || bad "HelmRepository url is not $OCI_REPO_URL (drifted from this check's source table?)"
  awk '/^kind: HelmRepository$/{f=1} f&&/^  namespace: flux-system$/{found=1} END{exit !found}' "$G" \
    && ok "HelmRepository lives in flux-system (shared chart-source namespace)" \
    || bad "HelmRepository is not in namespace flux-system"
else
  bad "no HelmRepository in the group render"
fi
has "$RELEASE_FILE" "namespace: flux-system" \
  && ok "the HelmRelease resolves its chart cross-namespace from flux-system" \
  || bad "the HelmRelease does not point at the flux-system HelmRepository"
grep -qE '^ *version: *"?[><=~^]' "$RELEASE_FILE" \
  && bad "chart version is a range - the app version would drift" \
  || ok "chart version is an exact pin ($version)"

# 5b. the rendered DATABASE_URL, and POSTGRES_PASSWORD defined before it.
DBURL='postgresql://hindsight:$(POSTGRES_PASSWORD)@hindsight-db-rw.hindsight.svc.cluster.local:5432/hindsight'
if grep -qF -- "value: \"$DBURL\"" "$API"; then
  ok "rendered HINDSIGHT_API_DATABASE_URL -> $DBURL"
else
  bad "the rendered HINDSIGHT_API_DATABASE_URL is not the expected CNPG string:"
  grep -n 'HINDSIGHT_API_DATABASE_URL' -A1 "$API" | sed 's/^/        /'
fi
grep -qF -- '***' "$R" \
  && bad "the render contains a literal *** - that is the display, not the manifest" \
  || ok "no literal *** anywhere in the render (the token is \$(POSTGRES_PASSWORD))"
pp_line=$(grep -n 'name: POSTGRES_PASSWORD' "$API" | head -1 | cut -d: -f1)
db_line=$(grep -n 'name: HINDSIGHT_API_DATABASE_URL' "$API" | head -1 | cut -d: -f1)
if [ -n "$pp_line" ] && [ -n "$db_line" ] && [ "$pp_line" -lt "$db_line" ]; then
  ok "POSTGRES_PASSWORD (line $pp_line) precedes HINDSIGHT_API_DATABASE_URL (line $db_line) - \$(VAR) interpolation order intact"
else
  bad "POSTGRES_PASSWORD does not precede HINDSIGHT_API_DATABASE_URL (pp=${pp_line:-none} db=${db_line:-none})"
fi
has "$API" 'key: postgres-password' \
  && ok "POSTGRES_PASSWORD reads key postgres-password of the existing secret" \
  || bad "POSTGRES_PASSWORD does not reference the postgres-password key"
has "$API" 'envFrom:' && has "$API" 'name: hindsight-secrets' \
  && ok "the existingSecret hindsight-secrets is envFrom'd into the api container" \
  || bad "hindsight-secrets is not envFrom'd into the api container"

# 5c. liveness vs readiness - deliberately different, do not normalise.
lpath=$(awk '/livenessProbe:/{f=1} f&&/path:/{print $2; exit}' "$API")
rpath=$(awk '/readinessProbe:/{f=1} f&&/path:/{print $2; exit}' "$API")
[ "$lpath" = "/health/live" ] \
  && ok "api livenessProbe path is /health/live (no database access - a slow DB must not restart the pod)" \
  || bad "api livenessProbe path is '${lpath:-none}', expected /health/live"
[ "$rpath" = "/health" ] \
  && ok "api readinessProbe path is /health (queries the database)" \
  || bad "api readinessProbe path is '${rpath:-none}', expected /health"

# 5d. pinned images: slim api + worker, plain control plane, nothing on :latest.
has "$API" 'image: "ghcr.io/vectorize-io/hindsight-api:0.10.3-slim"' \
  && ok "api image is ghcr.io/vectorize-io/hindsight-api:0.10.3-slim (slim, pinned)" \
  || bad "api image is not the pinned slim 0.10.3 tag:"
grep -n 'image:' "$API" | sed 's/^/        /'
has "$CP" 'image: "ghcr.io/vectorize-io/hindsight-control-plane:0.10.3"' \
  && ok "control-plane image is ghcr.io/vectorize-io/hindsight-control-plane:0.10.3 (upstream ships no slim variant)" \
  || bad "control-plane image is not the pinned 0.10.3 tag:"
grep -n 'image:' "$CP" | sed 's/^/        /'
awk '
  match($0, /image: *"[^"]+"/) {
    ref = substr($0, RSTART, RLENGTH)
    gsub(/image: *"/, "", ref); gsub(/"/, "", ref)
    n = split(ref, parts, "/")
    if (index(parts[n], ":") == 0 || parts[n] ~ /:latest$/) print "        " $0
  }
' "$R" > "$WORK/latest.txt"
if [ -s "$WORK/latest.txt" ]; then
  bad "untagged or :latest image found:"; cat "$WORK/latest.txt"
else
  ok "every image in the render carries an explicit, non-latest tag"
fi
has "$R" 'app.kubernetes.io/version: "0.10.3"' \
  && ok "chart labels carry app.kubernetes.io/version 0.10.3 (chart pin matches the image pin)" \
  || note "chart labels carry no app.kubernetes.io/version 0.10.3 - check the chart pin"

# 5e. the chart must NOT manage a Secret, a PVC, or a worker.
grep -q '^kind: Secret' "$R" \
  && bad "the chart rendered a Secret - existingSecret is not in effect" \
  || ok "no chart-managed Secret in the render (existingSecret honoured)"
grep -q '^kind: PersistentVolumeClaim' "$R" \
  && bad "the chart rendered a PVC - api.persistence.modelCache.enabled is not false" \
  || ok "no PVC in the render (external models; nothing pins the pod to a node)"
grep -q '^kind: StatefulSet' "$R" \
  && bad "the chart rendered a StatefulSet - worker.enabled is not false" \
  || ok "no worker StatefulSet in the render (worker.enabled: false; the API's internal worker does the work)"
has "$API" 'HINDSIGHT_API_WORKER_ENABLED' \
  && bad "the API is told to disable its internal worker while no dedicated worker exists" \
  || ok "the API keeps its internal worker (no HINDSIGHT_API_WORKER_ENABLED=false)"

# 5f. api resources - modest on purpose (node CPU requests are the constraint).
awk '/^        resources:/{f=1;next} f&&/^        [a-z]/{exit} f{print}' "$API" > "$WORK/api-res.txt"
if [ "$(grep -c . "$WORK/api-res.txt")" -ge 6 ] \
   && has "$WORK/api-res.txt" 'cpu: 2000m' && has "$WORK/api-res.txt" 'memory: 3Gi' \
   && has "$WORK/api-res.txt" 'cpu: 500m'  && has "$WORK/api-res.txt" 'memory: 1Gi'; then
  ok "api resources: requests 500m/1Gi, limits 2000m/3Gi"
else
  bad "api resources are not requests 500m/1Gi + limits 2000m/3Gi:"
  sed 's/^/        /' "$WORK/api-res.txt"
fi

# 5g. CPU TEI for embeddings + reranker, and the provider envs that use them.
for pair in "embedding:$EMB:8091" "reranker:$RER:8090"; do
  comp=${pair%%:*}; rest=${pair#*:}; doc=${rest%%:*}; port=${rest##*:}
  has "$doc" "name: $release-tei-$comp" \
    && ok "TEI $comp deployment present ($release-tei-$comp)" \
    || bad "TEI $comp deployment is missing"
  has "$doc" "ghcr.io/huggingface/text-embeddings-inference:cpu-1.8.3" \
    && ok "TEI $comp runs the CPU image cpu-1.8.3 (host GPU is Maxwell sm_52; TEI needs >= 7.5)" \
    || bad "TEI $comp is not running the CPU cpu-1.8.3 image"
  has "$R" "name: $release-tei-$comp" && has "$R" "port: $port" \
    && ok "TEI $comp is reachable through its Service on port $port" \
    || bad "TEI $comp is not on port $port"
done
has "$API" 'name: HINDSIGHT_API_EMBEDDINGS_PROVIDER' && has "$API" 'value: "tei"' \
  && ok "HINDSIGHT_API_EMBEDDINGS_PROVIDER is tei" \
  || bad "HINDSIGHT_API_EMBEDDINGS_PROVIDER is not tei"
has "$API" 'name: HINDSIGHT_API_RERANKER_PROVIDER' && has "$API" 'value: "tei"' \
  && ok "HINDSIGHT_API_RERANKER_PROVIDER is tei" \
  || bad "HINDSIGHT_API_RERANKER_PROVIDER is not tei"
has "$API" 'HINDSIGHT_API_EMBEDDINGS_TEI_URL' && has "$API" 'HINDSIGHT_API_RERANKER_TEI_URL' \
  && ok "both TEI URLs are wired into the api container" \
  || bad "the TEI URLs are not wired into the api container"

# 5h. LLM wiring through the local LiteLLM gateway.
for kv in \
  'HINDSIGHT_API_LLM_PROVIDER: "litellm"' \
  'HINDSIGHT_API_LLM_MODEL: "nemotron-3-nano-30b-ollama"' \
  'HINDSIGHT_API_LLM_BASE_URL: "http://litellm.llm-hub.svc.cluster.local:4000"' \
  'HINDSIGHT_API_TENANT_EXTENSION: "hindsight_api.extensions.builtin.tenant:ApiKeyTenantExtension"'
do
  key=${kv%%: *}; want=${kv#*: }
  if has "$API" "name: $key" && has "$API" "value: $want"; then
    ok "$key = $want"
  else
    bad "$key is not set to $want"
  fi
done

# 5i. ServiceMonitor for the API, selected by the live Prometheus.
if [ -s "$SM" ]; then
  ok "ServiceMonitor $release-api rendered"
  has "$SM" 'release: prometheus-stack' \
    && ok "ServiceMonitor carries labels release: prometheus-stack (the live Prometheus selector)" \
    || bad "ServiceMonitor does not carry the release: prometheus-stack label"
  has "$SM" 'path: /metrics' && ok "ServiceMonitor scrapes /metrics" || bad "ServiceMonitor does not scrape /metrics"
  has "$SM" 'port: http' \
    && ok "ServiceMonitor scrapes the api service port http" \
    || bad "ServiceMonitor does not target the api's http port"
else
  bad "no ServiceMonitor in the render (metrics.serviceMonitor.enabled is not true)"
fi

# 5j. the api Service stays ClusterIP - LAN/Netbird exposure is H2-239's ticket.
doc_by_name Service "$release-api" "$R" > "$WORK/svc-doc.yaml"
has "$WORK/svc-doc.yaml" 'type: ClusterIP' \
  && ok "the api Service is ClusterIP only (exposure is H2-239, not this ticket)" \
  || bad "the api Service is not ClusterIP"

head1 "6. wiring and secrets"
# 6a. every manifest on disk is listed in the kustomization (tests/ is hand-run).
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

# 6b. every Secret in the group must be SOPS-encrypted with no plaintext payload.
if grep -q '^kind: Secret' "$G"; then
  secrets=$(grep -c '^kind: Secret' "$G")
  sops_secrets=$(grep -c '^sops:' "$G")
  if [ "$secrets" -eq "$sops_secrets" ] && ! grep -qE '^(data|stringData): *[^ ]' "$G"; then
    ok "all $secrets Secret(s) in the group are SOPS-encrypted with no plaintext payload"
  else
    bad "the group has a Secret that is not SOPS-encrypted ($secrets Secret docs, $sops_secrets sops blocks)"
  fi
else
  ok "no Secret objects in the group"
fi

# 6c. no plausible plaintext credential in the files this ticket adds.
if grep -nE '(password|passwd|token|api[_-]?key|secret): *[^ ]' "$REPO_FILE" "$RELEASE_FILE" > "$WORK/plaintext.txt"; then
  if grep -vE 'secretName|existingSecret|name:|secretKeyRef|key:|secretRef|postgres-password|HINDSIGHT_API_TENANT_EXTENSION|source.toolkit' "$WORK/plaintext.txt" > "$WORK/plaintext-real.txt" \
     && [ -s "$WORK/plaintext-real.txt" ]; then
    bad "possible plaintext secret material:"; sed 's/^/        /' "$WORK/plaintext-real.txt"
  else
    ok "no plaintext secret values in the manifests this ticket adds"
  fi
else
  ok "no plaintext secret values in the manifests this ticket adds"
fi

printf '\n== result: %s\n' "$([ "$fail" -eq 0 ] && echo PASS || echo FAIL)"
exit "$fail"
