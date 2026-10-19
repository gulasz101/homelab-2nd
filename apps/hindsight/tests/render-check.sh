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
#      the prometheus-stack label, (H2-271) NO DUPLICATE env KEY NAME in
#      any rendered container - the defect that kept the api Deployment from
#      ever being created, and that neither helm nor kubeconform catches - and
#      (H2-313) the H2-306/H2-307 LLM, timeout, fan-out, pool and worker
#      settings, read out of the rendered api container with quotes stripped,
#      including the knobs that must stay ABSENT: the reverted
#      *_REASONING_EFFORT pair and CONSOLIDATION_LLM_BATCH_SIZE
#   5m. (H2-275) the api STARTUP GATE: the HelmRelease's postRenderer is read
#      out of the manifest and replayed through `kubectl kustomize` over the
#      chart render - the same two-step render helm-controller performs - and
#      the resulting api container is asserted to carry a startupProbe on
#      :8888 while liveness (/health/live) and readiness (/health) come through
#      untouched, parameter for parameter. (H2-313) the documents helm emits for
#      templates that render nothing are dropped before kustomize is handed the
#      render (that is what used to break this replay with "missing Resource
#      metadata"), the drop is asserted to lose no rendered object, and the
#      post-rendered api Deployment is asserted to be strategy Recreate with no
#      rolling parameters - the shape that stops an api restart from orphaning
#      in-flight consolidation work (H2-306)
#   6. every manifest on disk is wired into the kustomization (the classic
#      "wrote the file, forgot the wiring" bug) and nothing plaintext leaked in
#
# Needs: kubectl, helm, and kubeconform. kubeconform is a hard dependency -
#        sections 3, 4 and 5m validate the render with it - so a missing binary
#        is a FAIL, and section 0 prints the one-line install command (H2-313:
#        it used to surface only as `kubeconform: command not found` inside a
#        section that then read as if the MANIFEST had been rejected).
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

# Read one scalar field by its exact key, whatever the indentation:
#   field <file> <key>   e.g. field svc.yaml nodePort  ->  30239
field() {
  awk -v k="$2:" '$1 == k { v = $2; gsub(/"/, "", v); print v; exit }' "$1"
}

# Print the spec.selector of an already-extracted Service document, sorted, so
# two selectors can be compared as sets rather than as text.
svc_selector() {
  awk '
    /^  selector:$/ { f = 1; next }
    f && /^  [^ ]/   { exit }
    f { sub(/^    /, ""); if ($0 != "") print }
  ' "$1" | sort
}

# Value of one env key in an already-extracted container document, with the
# surrounding quotes removed (H2-313). The two renders this file reads quote
# strings differently: `helm template` emits the chart's own template output,
# where the chart quotes every value (`value: "60"`), while a kustomize rebuild
# re-serialises the object and drops quotes that are not needed (`value: 60`).
# Comparing raw text would make an expectation depend on which render it was read
# from; comparing the value makes it depend on nothing.
#   env_value <container file> <ENV_KEY_NAME>
env_value() {
  awk -v want="$2" '
    $0 ~ /^[[:space:]]*- name:[[:space:]]*/ {
      v = $0; sub(/^[[:space:]]*- name:[[:space:]]*/, "", v); gsub(/"/, "", v)
      inenv = (v == want); next
    }
    inenv && $1 == "value:" { v = $2; gsub(/^"|"$/, "", v); print v; exit }
    inenv && $0 ~ /^[[:space:]]*- name:/ { inenv = 0 }
  ' "$1"
}

# 1 if the env key NAME appears at all in an extracted container document (or in
# a whole render). Used for the keys that must NOT be set (H2-313).
env_key_present() {
  grep -qE "^[[:space:]]*- name:[[:space:]]*\"?$2\"?[[:space:]]*$" "$1"
}

# Drop the YAML documents that carry no resource identity, and report them
# (H2-313).
#   strip_nonresources <input> [report file]  ->  stdout
#
# `helm template` emits one document per TEMPLATE FILE, so a template that
# renders nothing while its value is disabled still lands in the render as a bare
# separator plus its `# Source:` comment - chart 0.10.3 does exactly that with
# templates/pdb.yaml while podDisruptionBudget is off. kustomize refuses a
# document it cannot name:
#   accumulating resources from 'render.yaml': missing Resource metadata
# (reproduced with kustomize v4.5.7 .. v5.8.0 by feeding it a document that has
# content but no apiVersion/kind/metadata). Section 5m replays the postRenderer
# through `kubectl kustomize`, so whether that replay dies depended on how
# tolerant the installed loader happens to be - not something a validation gate
# should inherit. Identity-less documents are dropped here, and ONLY those: a
# document declaring a non-empty apiVersion/kind, or a metadata map with at least
# one field that is not an empty value ({} / [] / null / ~ / ""), is passed
# through unchanged. The bias is deliberate - a document that is kept but still
# unacceptable to kustomize fails loudly in 5m with kustomize's own message,
# while a document that is dropped by mistake would quietly remove a manifest
# from the replay, which is why 5m also asserts that no `kind:` line was lost,
# that the filter is idempotent, and that the filter's own contract holds on a
# synthetic input.
# The report file gets `dropped <n>` followed by the `# Source:` line of every
# dropped document, so a silent drop is impossible to miss.
strip_nonresources() {
  awk -v report="${2:-}" '
    function hasval(line,   v) {
      v = line
      sub(/^[[:space:]]+("[A-Za-z0-9_.\/-]+"|[A-Za-z0-9_.\/-]+):[[:space:]]*/, "", v)
      if (v == line) return 0
      return !(v == "" || v == "{}" || v == "[]" || v == "null" || v == "~" || v == "\"\"")
    }
    function flush() {
      if (buf == "") return
      if (identity) {
        if (kept++) printf "---\n"
        printf "%s", buf
      } else {
        dropped++
        detail = detail sprintf("    - %s\n", (src == "" ? "(no # Source: comment)" : src))
      }
      buf = ""; identity = 0; inmeta = 0; src = ""
    }
    /^---[[:space:]]*$/ { flush(); next }
    /^\.\.\.[[:space:]]*$/ { flush(); next }
    {
      buf = buf $0 "\n"
      if (src == "" && $0 ~ /^# Source:/) src = $0
      if (inmeta && hasval($0)) identity = 1
      if ($0 ~ /^metadata:[[:space:]]*$/) inmeta = 1
      else if ($0 ~ /^[^[:space:]]/) inmeta = 0
      if ($0 ~ /^(apiVersion|kind):[[:space:]]*[^[:space:]]/) identity = 1
    }
    END {
      flush()
      if (report != "") printf "dropped %d\n%s", dropped + 0, detail > report
    }
  ' "$1"
}

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

# kubeconform is a hard dependency of sections 3, 4 and 5m. H2-313: a missing
# binary used to show up only as `kubeconform: command not found` inside those
# sections, where the surrounding message reads as if the MANIFEST had been
# rejected. It stays a FAIL - without it nothing is validated - but it says what
# to install, in one line, and the sections below say they could not run.
HAVE_KUBECONFORM=1
if ! command -v kubeconform >/dev/null 2>&1; then
  HAVE_KUBECONFORM=0
  bad "kubeconform is not on PATH - install the pinned release: curl -sSfL https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-amd64.tar.gz | tar xz -C /usr/local/bin kubeconform"
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

head1 "3. kubeconform -strict on the group render"
if [ "$HAVE_KUBECONFORM" -eq 0 ]; then
  bad "kubeconform missing - the group render was not validated (section 0 prints the one-line install command)"
elif "${KUBECONFORM[@]}" "$G" > "$WORK/kc-group.txt" 2>&1; then
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
  if [ "$HAVE_KUBECONFORM" -eq 0 ]; then
    bad "kubeconform missing - the chart render was not validated (section 0 prints the one-line install command)"
  elif "${KUBECONFORM[@]}" "$WORK/render.yaml" > "$WORK/kc-render.txt" 2>&1; then
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

# 5h. LLM and consolidation wiring: the local LiteLLM *proxy*, plus the
# throughput / timeout / pool / worker rulings of H2-306 and H2-307 (H2-313
# replaced the stale nemotron expectation with this table).
# The proxy speaks the OpenAI Chat Completions API, so the provider must be
# `openai` and the base URL must end in /v1. `provider: litellm` means "use the
# LiteLLM library against a real upstream vendor" and fails at the first retain
# with `LLM Provider NOT provided ... You passed model=...` (H2-279).
# Values are read out of the RENDERED api container by name with env_value(),
# which strips quotes - so an expectation here is the value the app sees, not the
# punctuation of whichever render it was read from.
for kv in \
  'HINDSIGHT_API_LLM_PROVIDER: openai' \
  'HINDSIGHT_API_LLM_MODEL: gpt-oss-120b-hindsight' \
  'HINDSIGHT_API_CONSOLIDATION_LLM_MODEL: gpt-oss-120b-openrouter' \
  'HINDSIGHT_API_LLM_BASE_URL: http://litellm.llm-hub.svc.cluster.local:4000/v1' \
  'HINDSIGHT_API_TENANT_EXTENSION: hindsight_api.extensions.builtin.tenant:ApiKeyTenantExtension' \
  'HINDSIGHT_API_DB_STATEMENT_TIMEOUT: 60' \
  'HINDSIGHT_API_LINK_EXPANSION_PER_ENTITY_LIMIT: 50' \
  'HINDSIGHT_API_CONSOLIDATION_LLM_PARALLELISM: 6' \
  'HINDSIGHT_API_DB_POOL_MAX_SIZE: 30' \
  'HINDSIGHT_API_WORKER_ID: hindsight-api'
do
  key=${kv%%: *}; want=${kv#*: }
  got=$(env_value "$API" "$key")
  if [ "$got" = "$want" ]; then
    ok "$key = $got"
  else
    bad "$key is '${got:-unset}', expected $want"
  fi
done

# The knobs that must stay ABSENT - absence is a behaviour here, so it is
# asserted positively, in the api container and then over the whole render:
#   - *_LLM_REASONING_EFFORT: LiteLLM answers the dedicated :nitro route with
#       400 UnsupportedParamsError: openrouter does not support parameters:
#       ['reasoning_effort']
#     and every retain failed from 08:37 until the revert (H2-306). Reasoning
#     control, if wanted, belongs in the LiteLLM model entry, not here.
#   - CONSOLIDATION_LLM_BATCH_SIZE: at 16 about 10% of consolidation calls failed
#     validation (gpt-oss dropped required fields such as source_fact_ids in the
#     longer structured answers). The app default is 8, so the key must be gone
#     and not merely set back to 8 - an explicit 8 would hide the next person's
#     attempt to raise it (H2-306).
for kv in \
  'HINDSIGHT_API_RETAIN_LLM_REASONING_EFFORT: reasoning_effort is unsupported on the :nitro route - LiteLLM answers 400 UnsupportedParamsError and every retain fails (H2-306)' \
  'HINDSIGHT_API_CONSOLIDATION_LLM_REASONING_EFFORT: reasoning_effort is unsupported on the :nitro route - LiteLLM answers 400 UnsupportedParamsError and every retain fails (H2-306)' \
  'HINDSIGHT_API_LLM_REASONING_EFFORT: same revert - reasoning control belongs in the LiteLLM model entry, not in this env block (H2-306)' \
  'HINDSIGHT_API_CONSOLIDATION_LLM_BATCH_SIZE: at 16 about 10% of consolidation calls failed validation - gpt-oss dropped required fields such as source_fact_ids in the longer structured answers, so the app default of 8 is the corrected state (H2-306)'
do
  key=${kv%%: *}; why=${kv#*: }
  if env_key_present "$API" "$key"; then
    bad "$key is set in the api container again, but $why"
  elif env_key_present "$R" "$key"; then
    bad "$key appears elsewhere in the chart render, but $why"
  else
    ok "$key is not set anywhere in the render"
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

# 5k. H2-239 - LAN/Netbird reachability for the Hermes hosts (which run OUTSIDE
# the cluster, on the M1 Max). The chart's own Services stay ClusterIP and the
# chart exposes no nodePort value, so the exposure is one extra, explicitly
# named Service per component that selects the chart's pods directly - the same
# shape as apps/honcho/honcho-service.yaml. Never a public hostname for the API.
SVCFILE="$DIR/hindsight-service.yaml"
NP_API=30239
NP_CP=30240
head1 "5k. H2-239: LAN/Netbird NodePort exposure (api $NP_API, control plane $NP_CP)"
if [ -f "$SVCFILE" ]; then
  ok "$(basename "$SVCFILE") exists"
else
  bad "$(basename "$SVCFILE") missing - the Hermes hosts cannot reach Hindsight over LAN/Netbird"
fi

# The chosen ports are only meaningful against the ports this cluster already
# uses, so they are read from the whole apps render (source of truth: the repo).
grep -oE 'nodePort: [0-9]+' "$WORK/apps.yaml" | awk '{print $2}' | sort > "$WORK/ports.txt"
for np in "$NP_API" "$NP_CP"; do
  n=$(grep -cx "$np" "$WORK/ports.txt")
  if [ "$n" -eq 1 ]; then
    ok "nodePort $np is used exactly once in the whole apps render"
  else
    bad "nodePort $np appears $n time(s) in the apps render (expected exactly 1; a duplicate fails at apply time)"
  fi
done
dups=$(uniq -d "$WORK/ports.txt" | tr '\n' ' ')
[ -z "$dups" ] \
  && ok "no duplicate nodePort anywhere in the apps render ($(wc -l < "$WORK/ports.txt") in use)" \
  || bad "duplicate nodePort(s) in the apps render: $dups"

# The manifest must name the neighbours it avoids, so the next person picking a
# port does not have to re-derive the list.
if [ -f "$SVCFILE" ]; then
  for neighbour in 30193 30800; do
    grep -q "$neighbour" "$SVCFILE" \
      && ok "the manifest comments name nodePort $neighbour as a neighbour to avoid" \
      || bad "the manifest does not comment nodePort $neighbour ($([ "$neighbour" = 30193 ] && echo OpenViking || echo Honcho))"
  done
fi

# One exposure Service per component: existence, type, ports, and - the part
# that rots silently - selector equality against the CHART's own Service. The
# expected selector is never hardcoded here; it is read from the helm render.
for spec in \
  "api:${release}-api-lan:${release}-api:8888:${NP_API}" \
  "control-plane:${release}-control-plane-lan:${release}-control-plane:3000:${NP_CP}"
do
  comp=${spec%%:*}; rest=${spec#*:}
  myname=${rest%%:*}; rest=${rest#*:}
  chartname=${rest%%:*}; rest=${rest#*:}
  port=${rest%%:*}; nodeport=${rest##*:}

  doc_by_name Service "$myname" "$G"   > "$WORK/np-$comp.yaml"
  doc_by_name Service "$chartname" "$R" > "$WORK/chartsvc-$comp.yaml"

  if [ ! -s "$WORK/np-$comp.yaml" ]; then
    bad "no NodePort Service $myname for the $comp in the group render"
    continue
  fi
  ok "$comp exposure Service $myname is in the group render"

  [ "$(field "$WORK/np-$comp.yaml" type)" = "NodePort" ] \
    && ok "$myname is type: NodePort" \
    || bad "$myname is type '$(field "$WORK/np-$comp.yaml" type)', expected NodePort"
  [ "$(field "$WORK/np-$comp.yaml" port)" = "$port" ] \
    && ok "$myname serves port $port (the chart's own Service port)" \
    || bad "$myname serves port '$(field "$WORK/np-$comp.yaml" port)', expected $port"
  [ "$(field "$WORK/np-$comp.yaml" targetPort)" = "$port" ] \
    && ok "$myname targetPort $port (the chart's container port behind targetPort: http)" \
    || bad "$myname targetPort is '$(field "$WORK/np-$comp.yaml" targetPort)', expected $port"
  [ "$(field "$WORK/np-$comp.yaml" nodePort)" = "$nodeport" ] \
    && ok "$myname nodePort $nodeport" \
    || bad "$myname nodePort is '$(field "$WORK/np-$comp.yaml" nodePort)', expected $nodeport"

  sel_mine=$(svc_selector "$WORK/np-$comp.yaml")
  sel_chart=$(svc_selector "$WORK/chartsvc-$comp.yaml")
  if [ -n "$sel_mine" ] && [ "$sel_mine" = "$sel_chart" ]; then
    ok "$myname selects the chart's $comp pods (selector identical to the chart render: $(tr '\n' ' ' <<<"$sel_mine"))"
  else
    bad "$myname selector differs from the chart's $chartname selector:"
    printf '        ours : %s\n' "$(tr '\n' ' ' <<<"${sel_mine:-<empty>}")"
    printf '        chart: %s\n' "$(tr '\n' ' ' <<<"${sel_chart:-<empty>}")"
  fi

  # The chart's own Service must stay ClusterIP: the NodePort is an addition,
  # not a mutation of the chart's object (that is why no nodePort value exists).
  [ "$(field "$WORK/chartsvc-$comp.yaml" type)" = "ClusterIP" ] \
    && ok "the chart's own $chartname Service is still ClusterIP" \
    || bad "the chart's $chartname Service is no longer ClusterIP"
done

grep -q '^kind: Ingress' "$G" \
  && bad "an Ingress appeared in the hindsight group - the API must not be published" \
  || ok "no Ingress in the group (LAN/Netbird only; the API is never a public hostname)"

# 5l. H2-271: NO DUPLICATE env KEY NAMES in the rendered containers.
# Kubernetes server-side apply REJECTS a container whose env list carries the
# same key name twice:
#   .spec.template.spec.containers[name="api"].env: duplicate entries for key
#   [name="HINDSIGHT_API_EMBEDDINGS_PROVIDER"]
# Neither `helm template` nor kubeconform -strict looks at that, so this class of
# defect sailed through this gate until it took the api Deployment down: the
# HelmRelease declared HINDSIGHT_API_EMBEDDINGS_PROVIDER / _RERANKER_PROVIDER
# itself while tei.embedding.enabled / tei.reranker.enabled made the chart emit
# the same two names, the apply was refused, and the release stalled with no api
# pod at all.
#
# Two checks, both POSITIVE uniqueness over the rendered names: the api
# container by name (the container this ticket is about) and every env block in
# the render (so a duplicate of any other key, in any container, fails too). A
# grep for the two historical strings would rot the moment the chart renames a
# key, and simply deleting those strings from this gate would hide the bug again.
head1 "5l. H2-271: no duplicate env key names in the rendered containers"

# Print every `- name:` inside an `env:` block, prefixed with that block's
# sequence number, so duplicates are `uniq -d` on "<block>\t<key>". The chart's
# YAML puts a sequence item at the SAME indentation as the `env:` key it belongs
# to, so a block ends either at a shallower line or at a sibling key (`ind ==
# envind` and not a list item); deeper lines are values and are ignored.
env_key_names() {
  awk '
    function indent(s,   i) { i = 0; while (substr(s, i+1, 1) == " ") i++; return i }
    /^[[:space:]]*env:[[:space:]]*$/ { inenv = 1; envind = indent($0); seq++; next }
    inenv {
      if ($0 ~ /^[[:space:]]*$/) next
      ind = indent($0)
      if (ind < envind) { inenv = 0; next }
      if (ind == envind) {
        if ($0 ~ /^[[:space:]]*- name:[[:space:]]*/) {
          v = $0; sub(/^[[:space:]]*- name:[[:space:]]*/, "", v); gsub(/"/, "", v)
          print seq "\t" v
          next
        }
        inenv = 0
      }
    }
  ' "$1"
}

# (a) the api container itself - the one this ticket exists for. The extraction
# is guarded against a silent zero-key parse: an empty list would make the
# uniqueness test pass vacuously, which is exactly the failure mode the H2-238
# gate had.
env_key_names "$API" | awk -F'\t' '$1 == 1 { print $2 }' | sort > "$WORK/api-env-keys.txt"
api_env_n=$(grep -c . "$WORK/api-env-keys.txt")
if [ "$api_env_n" -lt 5 ]; then
  bad "only $api_env_n env key name(s) parsed out of the api container - the uniqueness check below would be vacuous"
else
  ok "parsed $api_env_n env key names out of the rendered api container"
fi
uniq -d < "$WORK/api-env-keys.txt" > "$WORK/api-env-dups.txt"
if [ -s "$WORK/api-env-dups.txt" ]; then
  bad "the rendered api container repeats these env key name(s) - server-side apply refuses to create the Deployment:"
  sed 's/^/        /' "$WORK/api-env-dups.txt"
else
  ok "every env key name in the rendered api container appears exactly once"
fi

# (b) every env block in the whole chart render - the same defect anywhere else
# fails too, so the gate does not depend on anyone remembering this ticket.
env_key_names "$R" > "$WORK/env-keys.txt"
all_env_n=$(grep -c . "$WORK/env-keys.txt")
if [ "$all_env_n" -lt 10 ]; then
  bad "only $all_env_n env key names parsed out of the whole render - the sweep below would be vacuous"
else
  ok "swept $all_env_n env key names over $(cut -f1 "$WORK/env-keys.txt" | uniq | wc -l) env block(s) in the chart render"
fi
sort "$WORK/env-keys.txt" | uniq -d > "$WORK/env-dups.txt"
if [ -s "$WORK/env-dups.txt" ]; then
  bad "duplicate env key name(s) inside a rendered env block - such a container can never be created:"
  sed 's/^/        /' "$WORK/env-dups.txt"
else
  ok "no env block in the chart render repeats a key name"
fi

# 5m. H2-275: the api startup gate.
# Live evidence (2026-10-13 05:35 CEST, pod hindsight-api-55b6d8c954-bcwmh on
# zigbee-node): config + extension loading took 23 s, the container was SIGTERMed
# 58 s in with exit code 0 (graceful - a probe-budget kill, not a crash), and it
# never logged "Uvicorn running on ...". The liveness budget was initialDelay 30 s
# + 3 x period 10 s = 60 s to the first success, so liveness reaped a process that
# was merely slow to bind :8888.
#
# The fix is a startupProbe, and it CANNOT be a chart value: chart 0.10.3 exposes
# api.livenessProbe / api.readinessProbe but renders no startupProbe at all
# (asserted below on the unpatched render). Helm rejects overwriting a template's
# keys from outside, so the gate goes in through spec.postRenderers - kustomize on
# the rendered manifests, the same extension point apps/shlink, apps/itsaplan and
# apps/zigbee/node-red already use, and the one helm-controller runs on every
# reconcile. Which is why this section does not just grep the YAML: it replays the
# patch out of the HelmRelease through `kubectl kustomize` over the chart render,
# so what is asserted is the object that actually reaches the cluster.
#
# H2-313 - the replay used to be at the mercy of `helm template`'s empty
# documents. helm emits one document per TEMPLATE FILE, so a template that
# renders nothing (chart 0.10.3's pdb.yaml while podDisruptionBudget is off)
# still lands in the render as a separator plus its `# Source:` comment, and
# kustomize cannot name a document like that:
#   accumulating resources from 'render.yaml': missing Resource metadata
# and this whole section then reported `none` for every probe it asserts. The
# render now goes through strip_nonresources() first. The drop is printed, never
# silent, and it is asserted to lose no rendered object, to be idempotent, and to
# behave correctly on a synthetic input (the self-test below), so the fix cannot
# hide a failure of its own.
head1 "5m. H2-275: the api startup gate (postRenderer)"

# Print the postRenderers' kustomize `patches:` list out of a HelmRelease,
# dedented so it can be dropped into a kustomization verbatim. Empty output means
# there is no postRenderers block (or a shape this extractor does not understand -
# the caller fails loudly in that case rather than testing nothing).
postrender_patches() {
  awk '
    /^  postRenderers:/ { inpr = 1; next }
    inpr {
      if ($0 ~ /^[^ ]/ || $0 ~ /^  [^ ]/) exit
      if (!seen) { if ($0 ~ /^[[:space:]]*- kustomize:/) seen = 1; next }
      sub(/^ {8}/, "")
      print
    }
  ' "$1"
}

# Print one container out of an extracted Deployment document, identified by its
# name. It cannot look for a literal `- name: <want>`: the two renders this
# section compares put the container's keys in different orders - `helm template`
# emits the chart's template order (name first), while kustomize rebuilds each
# object from a map and emits keys alphabetically, so the post-rendered item
# starts with `- env:` and carries `name: api` further down. So the block is
# delimited by indentation instead: `containers:` marks the list, its items share
# that indentation, a sibling key at the same indentation ends the list, and the
# item's own `name:` is either on the item line or one level deeper.
container_block() {
  awk -v want="$2" '
    function indent(s,   i) { i = 0; while (substr(s, i+1, 1) == " ") i++; return i }
    function item_name(s, cind,   n, l, i, ind, v) {
      n = split(s, l, "\n")
      for (i = 1; i <= n; i++) {
        if (l[i] == "") continue
        ind = indent(l[i])
        if (ind == cind && l[i] ~ /^[ ]*-[ ]*name:/) { v = l[i]; sub(/^[ ]*-[ ]*name:[ ]*/, "", v); return v }
        if (ind == cind + 2 && l[i] ~ /^[ ]*name:/)  { v = l[i]; sub(/^[ ]*name:[ ]*/, "", v); return v }
      }
      return ""
    }
    function flush(   nm) {
      if (start) {
        nm = item_name(buf, cind); gsub(/"/, "", nm)
        if (nm == want) printf "%s", buf
      }
      buf = ""; start = 0
    }
    /^[ ]*containers:[ ]*$/ { inc = 1; cind = indent($0); next }
    !inc { next }
    {
      ind = indent($0)
      if ($0 !~ /^[ ]*$/) {
        if (ind < cind) { flush(); inc = 0; next }
        if (ind == cind) {
          if ($0 ~ /^[ ]*- /) { flush(); start = 1 }   # a new container item
          else                { flush(); inc = 0; next } # a sibling key: volumes, nodeSelector, ...
        }
      }
      if (start) buf = buf $0 "\n"
    }
    END { flush() }
  ' "$1"
}

# One scalar out of a probe block inside an already-extracted container block:
# probe_field <container file> <livenessProbe|readinessProbe|startupProbe> <key>
# The block ends at the next key at the probe's own indentation (8 spaces in this
# chart's render); deeper keys belong to the probe.
probe_field() {
  awk -v p="$2:" -v k="$3:" '
    $1 == p { inx = 1; next }
    inx && /^        [A-Za-z]/ { exit }
    inx && $1 == k { v = $2; gsub(/"/, "", v); print v; exit }
  ' "$1"
}

PRP="$WORK/postrender-patches.yaml"
postrender_patches "$RELEASE_FILE" > "$PRP"
if grep -q '^patches:' "$PRP"; then
  ok "read a kustomize patch list out of the HelmRelease's spec.postRenderers ($(grep -c '^ *- op:' "$PRP") JSON6902 operation(s))"
else
  bad "no kustomize patch list under spec.postRenderers in $(basename "$RELEASE_FILE") - the pinned chart renders no startupProbe from values, so nothing re-arms the liveness timer during a slow first boot"
fi
grep -q "name: ${release}-api" "$PRP" \
  && ok "the postRenderer targets Deployment ${release}-api" \
  || bad "the postRenderer does not name Deployment ${release}-api as its target (a bare kind target would hit the TEI and control-plane Deployments too)"

# Replay the chart render through the patch, exactly as helm-controller does -
# with the identity-less documents helm emits for templates that render nothing
# removed first (H2-313, see strip_nonresources above).
mkdir -p "$WORK/gate"
strip_nonresources "$R" "$WORK/gate/filter.txt" > "$WORK/gate/render.yaml"
dropped=$(sed -n 's/^dropped //p' "$WORK/gate/filter.txt")
kinds_before=$(grep -c '^kind:' "$R")
kinds_after=$(grep -c '^kind:' "$WORK/gate/render.yaml")
if [ "${dropped:-0}" -gt 0 ]; then
  ok "dropped $dropped identity-less document(s) before handing the render to kustomize (helm emits one for every template that renders nothing):"
  sed -n '2,$p' "$WORK/gate/filter.txt" | sed 's/^/        /'
else
  note "the chart render carries no identity-less document - nothing for the filter to drop"
fi
if [ "$kinds_before" = "$kinds_after" ]; then
  ok "the filter lost nothing renderable: $kinds_before rendered object(s) before it, $kinds_after after"
else
  bad "the document filter dropped a rendered object ($kinds_before -> $kinds_after '^kind:' lines) - the replay below would be validating fewer manifests than the chart renders"
fi
# The filter is TESTED here, not trusted. An identity-less document must go, and
# real objects must stay: a filter that dropped everything would make every
# assertion below pass vacuously, which is the same class of defect as the gate
# that let H2-271 through. The first document below is the shape that kills the
# replay outright ("missing Resource metadata"), the second is what helm emits
# for a template that renders nothing.
cat > "$WORK/filter-selftest.yaml" <<'SELFTEST'
---
# Source: chart/templates/empty.yaml
foo: bar
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: before-the-junk
---
# Source: chart/templates/empty2.yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: after-the-junk
SELFTEST
strip_nonresources "$WORK/filter-selftest.yaml" "$WORK/filter-selftest.txt" > "$WORK/filter-selftest.out"
st_dropped=$(sed -n 's/^dropped //p' "$WORK/filter-selftest.txt")
st_kept=$(grep -c '^kind:' "$WORK/filter-selftest.out")
if [ "${st_dropped:-x}" = "2" ] && [ "$st_kept" = "2" ] \
   && grep -q 'name: before-the-junk' "$WORK/filter-selftest.out" \
   && grep -q 'name: after-the-junk' "$WORK/filter-selftest.out"; then
  ok "filter self-test: the identity-less document ('foo: bar') and the empty template document were both dropped, and the real objects on either side of them were kept"
else
  bad "filter self-test failed: dropped=${st_dropped:-none} (expected 2), kept=$st_kept object(s) (expected 2)"
fi
strip_nonresources "$WORK/gate/render.yaml" "$WORK/gate/filter2.txt" > /dev/null
st_again=$(sed -n 's/^dropped //p' "$WORK/gate/filter2.txt")
[ "${st_again:-x}" = "0" ] \
  && ok "the filter is idempotent: a second pass over the filtered render drops 0 documents" \
  || bad "the filter is not idempotent: a second pass dropped ${st_again:-none} document(s)"

{
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n'
  printf 'resources:\n  - render.yaml\n'
  cat "$PRP"
} > "$WORK/gate/kustomization.yaml"
if kubectl kustomize "$WORK/gate" > "$WORK/gated.yaml" 2> "$WORK/gate.err"; then
  ok "replayed the chart render through the HelmRelease's postRenderer -> $(grep -c '^kind:' "$WORK/gated.yaml") objects (the object Flux applies, not the raw chart output)"
else
  bad "the postRenderer does not apply to the chart render:"
  sed 's/^/        /' "$WORK/gate.err"
  cp "$R" "$WORK/gated.yaml"   # keep going so the probe checks below still report what is missing
fi
if [ "$HAVE_KUBECONFORM" -eq 0 ]; then
  bad "kubeconform missing - the post-rendered output was not validated (section 0 prints the one-line install command)"
elif "${KUBECONFORM[@]}" "$WORK/gated.yaml" > "$WORK/kc-gated.txt" 2>&1; then
  ok "kubeconform on the post-rendered output: $(tail -1 "$WORK/kc-gated.txt")"
else
  bad "kubeconform rejected the post-rendered output:"
  grep -v '^Summary:' "$WORK/kc-gated.txt" | sed 's/^/        /'
fi

GATED_API="$WORK/api-doc-gated.yaml"
doc_by_name Deployment "$release-api" "$WORK/gated.yaml" > "$GATED_API"
container_block "$API" api                                    > "$WORK/api-container-chart.yaml"
container_block "$GATED_API" api                              > "$WORK/api-container-gated.yaml"
CHART_API_CONTAINER="$WORK/api-container-chart.yaml"
GATED_API_CONTAINER="$WORK/api-container-gated.yaml"
if [ -s "$CHART_API_CONTAINER" ] && [ -s "$GATED_API_CONTAINER" ]; then
  ok "extracted the api container from both the chart render and the post-rendered render"
else
  bad "could not extract the api container (chart: $(wc -l < "$CHART_API_CONTAINER") line(s), post-rendered: $(wc -l < "$GATED_API_CONTAINER") line(s)) - every check below would be vacuous"
fi

# (a) the gap: the chart itself has no startup probe for the api.
grep -q 'startupProbe' "$CHART_API_CONTAINER" \
  && note "the pinned chart already renders a startupProbe for the api container - re-check whether the postRenderer is still needed" \
  || ok "the pinned chart 0.10.3 renders NO startupProbe for the api container (there is no api.startupProbe value; liveness starts counting from its own initialDelaySeconds)"

# (b) after the postRenderer the api container is gated on the app answering.
if grep -q '^        startupProbe:' "$GATED_API_CONTAINER"; then
  ok "the post-rendered api container has a startupProbe:"
  awk '/^        startupProbe:/{f=1; print; next} f && /^        [A-Za-z]/{exit} f{print}' "$GATED_API_CONTAINER" \
    | sed 's/^/        | /'
else
  bad "the post-rendered api container has NO startupProbe - kubelet still reaps a slow first boot 60 s in"
fi
for kv in 'path:/health/live' 'port:8888' 'periodSeconds:10' 'timeoutSeconds:5' 'failureThreshold:30'; do
  key=${kv%%:*}; want=${kv#*:}
  got=$(probe_field "$GATED_API_CONTAINER" startupProbe "$key")
  [ "$got" = "$want" ] \
    && ok "startupProbe $key = $got" \
    || bad "startupProbe $key is '${got:-none}', expected $want"
done

sp_period=$(probe_field "$GATED_API_CONTAINER" startupProbe periodSeconds)
sp_thresh=$(probe_field "$GATED_API_CONTAINER" startupProbe failureThreshold)
sp_timeout=$(probe_field "$GATED_API_CONTAINER" startupProbe timeoutSeconds)
case "$sp_period$sp_thresh$sp_timeout" in
  ''|*[!0-9]*)
    bad "startupProbe budget not computable (periodSeconds='${sp_period:-none}', failureThreshold='${sp_thresh:-none}', timeoutSeconds='${sp_timeout:-none}')" ;;
  *)
    budget=$(( sp_period * sp_thresh ))
    if [ "$budget" -ge 300 ]; then
      ok "total startup budget = failureThreshold ${sp_thresh} x periodSeconds ${sp_period}s = ${budget}s (plus a ${sp_timeout}s per-attempt timeout) before the first liveness-driven restart; the old liveness-only budget was 30s + 3 x 10s = 60s, and the container was SIGTERMed 58s in"
    else
      bad "total startup budget is only ${budget}s - under the 58s+ this app already spent before binding :8888 on zigbee-node"
    fi ;;
esac

# (c) liveness and readiness come through the patch untouched, parameter for
# parameter - liveness /health/live (no DB I/O), readiness /health (queries the
# DB, so a slow database gates traffic instead of restarting the pod). Compared
# against the CHART's own render rather than against constants, so a silent
# overwrite of either probe fails here whatever the chart's values become.
for probe in livenessProbe readinessProbe; do
  detail=""; differs=""
  for key in path port initialDelaySeconds periodSeconds timeoutSeconds failureThreshold; do
    got=$(probe_field "$GATED_API_CONTAINER" "$probe" "$key")
    want=$(probe_field "$CHART_API_CONTAINER" "$probe" "$key")
    detail="$detail $key=$got"
    if [ -z "$want" ] || [ "$got" != "$want" ]; then differs="$differs $key"; fi
  done
  if [ -z "$differs" ]; then
    ok "post-render $probe is unchanged from the chart render:$detail"
  else
    bad "post-render $probe differs from the chart render in:$differs (post-render:$detail)"
  fi
done
lpath=$(probe_field "$GATED_API_CONTAINER" livenessProbe path)
lport=$(probe_field "$GATED_API_CONTAINER" livenessProbe port)
rpath=$(probe_field "$GATED_API_CONTAINER" readinessProbe path)
rport=$(probe_field "$GATED_API_CONTAINER" readinessProbe port)
[ "$lpath" = "/health/live" ] && [ "$lport" = "8888" ] \
  && ok "liveness still $lpath on :$lport and still enabled (a process that hangs AFTER startup must still be restarted)" \
  || bad "liveness is $lpath on :$lport, expected /health/live on :8888"
[ "$rpath" = "/health" ] && [ "$rport" = "8888" ] \
  && ok "readiness still $rpath on :$rport (database-backed, deliberately different from liveness)" \
  || bad "readiness is $rpath on :$rport, expected /health on :8888"

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
