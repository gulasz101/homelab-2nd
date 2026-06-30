#!/bin/bash
# Nightly security scan for the gulasz101/homelab-2nd GitOps repo.
# Runs on the Hermes host, pulls main, scans with gitleaks/trivy/kubeconform/kube-score/pluto,
# then prints a verbose, emoji-laden markdown report to stdout.
set -u

REPO="${REPO:-$HOME/Projects/homelab-2nd}"
TASK_DIR="${TASK_DIR:-$HOME/wojtek.second.brain.obsidian.vault/homelab/tasks}"
TMPDIR="$(mktemp -d -t homelab-security-scan-XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

cd "$REPO" || { echo "Cannot cd to $REPO"; exit 1; }

EXCLUSIONS_FILE="$REPO/.security-scan-exclusions.json"

# Helper: read counts from the JSON exclusions file using only stdlib json.
read_exclusion_counts() {
  python3 - "$EXCLUSIONS_FILE" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f) or {}
custom = d.get("custom", {})
print(
    len(custom.get("hostpath_accepted", [])),
    len(custom.get("privileged_accepted", [])),
    len(custom.get("root_accepted", []))
)
PY
}

exclusion_counts=$(read_exclusion_counts)
ACCEPTED_HOSTPATH=$(echo "$exclusion_counts" | awk '{print $1}')
ACCEPTED_PRIVILEGED=$(echo "$exclusion_counts" | awk '{print $2}')
ACCEPTED_ROOT=$(echo "$exclusion_counts" | awk '{print $3}')

echo "# Nightly homelab-2nd Security Scan"
echo ""
echo "Date: $(date -Iseconds)"
echo "Repo: $REPO"
echo "Branch: main"
echo ""

# --- 1. Refresh repo ---
echo "Pulling main branch..."
GIT_OUT="$(git checkout main 2>&1 && git pull --ff-only 2>&1)" || {
  echo "Git pull failed:"
  echo "$GIT_OUT"
  exit 1
}
GIT_SHA="$(git rev-parse --short HEAD)"
echo "On main @ $GIT_SHA"
echo ""

# --- 2. Gitleaks secret detection ---
echo "## Gitleaks: secret detection in git history"
echo ""
echo "What it does: Gitleaks scans every commit for strings that look like API keys, tokens, passwords, or other secrets. It uses entropy and regex rules. A high-entropy string inside a Kubernetes Secret is a classic false positive, but we still investigate every hit because the repo is public."
echo ""
gitleaks detect --redact --verbose --report-format json --report-path "$TMPDIR/gitleaks.json" . > "$TMPDIR/gitleaks.out" 2>&1 || true
GLEAKS_FINDINGS=$(jq 'length' "$TMPDIR/gitleaks.json" 2>/dev/null || echo 0)
echo "Findings: $GLEAKS_FINDINGS"
if [[ $GLEAKS_FINDINGS -gt 0 ]]; then
  echo ""
  echo "### Gitleaks hits"
  jq -r '.[] | "  - " + .File + " (rule: " + .RuleID + ", entropy: " + (.Entropy | tostring) + ")"' "$TMPDIR/gitleaks.json" | head -20
  echo ""
  echo "What this means: A rule fired. If the file is a Kubernetes Secret, check whether the data is actually sensitive. If it is a generated CRD manifest, consider encrypting it with SOPS or generating it at reconcile time."
else
  echo "No secret-like strings detected."
fi
echo ""

# --- 3. Trivy filesystem scan ---
echo "## Trivy: filesystem secret + misconfiguration scan"
echo ""
echo "What it does: Trivy looks at files on disk (not git history). It detects hardcoded secrets and Kubernetes/Docker misconfigurations. We run severity HIGH and CRITICAL only to keep the report actionable."
echo ""
trivy filesystem --scanners secret,misconfig --severity HIGH,CRITICAL --format json --output "$TMPDIR/trivy.json" . > "$TMPDIR/trivy.out" 2>&1 || true
TRIVY_SECRETS=$(jq '[.Results? // [] | .[] | select(.Class == "secret") | .Vulnerabilities? // []] | add | length' "$TMPDIR/trivy.json" 2>/dev/null || echo 0)
TRIVY_MISCONFIG=$(jq '[.Results? // [] | .[] | select(.Class == "config") | .Misconfigurations? // []] | add | length' "$TMPDIR/trivy.json" 2>/dev/null || echo 0)
TRIVY_FILTERED=$(python3 "$REPO/scripts/homelab-security-scan-filter.py" trivy < "$TMPDIR/trivy.json")
TRIVY_KEPT=$(echo "$TRIVY_FILTERED" | jq '.kept | length')
TRIVY_SUPPRESSED=$(echo "$TRIVY_FILTERED" | jq '.suppressed | length')
echo "Secrets: $TRIVY_SECRETS"
echo "Misconfigs (HIGH/CRITICAL): $TRIVY_MISCONFIG"
echo "  - actionable (after exclusions): $TRIVY_KEPT"
echo "  - suppressed (upstream defaults): $TRIVY_SUPPRESSED"
if [[ $TRIVY_KEPT -gt 0 ]]; then
  echo ""
  echo "### Sample actionable Trivy misconfigs"
  echo "$TRIVY_FILTERED" | jq -r '.kept[:20] | .[] | "  - " + .id + ": " + .title + " in " + .provider + "/" + .service'
  echo ""
  echo "What this means: These are misconfigurations not covered by the exclusion list. Review them and either fix the HelmRelease values or add a justified exclusion."
fi
if [[ $TRIVY_SUPPRESSED -gt 0 ]]; then
  echo ""
  echo "### Suppressed Trivy misconfigs (upstream defaults)"
  echo "$TRIVY_FILTERED" | jq -r '.suppressed | group_by(.id) | .[] | "  - " + .[0].id + ": " + (length | tostring) + " hits"' | head -20
fi
echo ""

# --- 4. Render Kustomizations and validate with kubeconform ---
echo "## Kubeconform: validate rendered Kubernetes manifests"
echo ""
echo "What it does: We render the Flux Kustomizations with kubectl kustomize and then run kubeconform against JSON schemas. It catches typos, wrong API versions, and invalid fields. Custom CRDs (HelmRelease, Cluster, etc.) need extra schema locations, so some failures are expected when the CRD catalog does not have a schema yet."
echo ""
for dir in infrastructure apps clusters/homelab-2nd; do
  if [[ -f "$dir/kustomization.yaml" ]] || [[ -f "$dir/kustomization.yml" ]]; then
    out="$TMPDIR/rendered-$dir.yaml"
    if kubectl kustomize "$dir" > "$out" 2>"$TMPDIR/kustomize-$dir.err"; then
      echo "* Rendered $dir"
    else
      echo "* Failed to render $dir:"
      cat "$TMPDIR/kustomize-$dir.err" | head -5
      > "$out"
    fi
  fi
done

KUBECONFORM_FAILS=0
KUBECONFORM_SUPPRESSED=0
for f in "$TMPDIR"/rendered-*.yaml; do
  [[ -f "$f" ]] || continue
  name=$(basename "$f" .yaml)
  kubeconform -strict -summary -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
      -output json "$f" > "$TMPDIR/kubeconform-$name.json" 2>"$TMPDIR/kubeconform-$name.err" || true
  filtered=$(python3 "$REPO/scripts/homelab-security-scan-filter.py" kubeconform < "$TMPDIR/kubeconform-$name.json")
  fails=$(echo "$filtered" | jq -r '.kept_count')
  suppressed=$(echo "$filtered" | jq -r '.suppressed_count')
  KUBECONFORM_FAILS=$((KUBECONFORM_FAILS + fails))
  KUBECONFORM_SUPPRESSED=$((KUBECONFORM_SUPPRESSED + suppressed))
done
echo "Invalid resources: $KUBECONFORM_FAILS"
echo "  - suppressed (schema gaps / expected): $KUBECONFORM_SUPPRESSED"
echo ""
echo "What this means: A high number usually means CRD schemas are missing from the catalog, not that our YAML is wrong. Look at the raw kubeconform output to separate real errors from schema gaps."
echo ""

# --- 5. kube-score best-practice checks ---
echo "## kube-score: Kubernetes manifest best practices"
echo ""
echo "What it does: kube-score reads rendered manifests and checks security and reliability best practices: resource limits, security contexts, probes, network policies, etc. It is opinionated and flags many upstream chart defaults."
echo ""
KSCORE_WARN=0
KSCORE_SUPPRESSED=0
for f in "$TMPDIR"/rendered-*.yaml; do
  [[ -f "$f" ]] || continue
  name=$(basename "$f" .yaml)
  kube-score score --output-format json "$f" > "$TMPDIR/kscore-$name.json" 2>&1 || true
  filtered=$(python3 "$REPO/scripts/homelab-security-scan-filter.py" kscore-json < "$TMPDIR/kscore-$name.json")
  kept=$(echo "$filtered" | jq -r '.kept_count')
  suppressed=$(echo "$filtered" | jq -r '.suppressed_count')
  KSCORE_WARN=$((KSCORE_WARN + kept))
  KSCORE_SUPPRESSED=$((KSCORE_SUPPRESSED + suppressed))
done
echo "Warnings / criticals: $KSCORE_WARN"
echo "  - suppressed (upstream defaults): $KSCORE_SUPPRESSED"
echo ""
echo "What this means: Many warnings come from upstream Helm charts that do not set resource limits, run as root, or lack network policies. The long-term fix is to tune Helm values or accept the risk and document it."
echo ""

# --- 6. Pluto deprecated API scan ---
echo "## Pluto: deprecated Kubernetes APIs"
echo ""
echo "What it does: Pluto scans the repo for Kubernetes API versions that are deprecated or removed in newer Kubernetes releases. This helps us upgrade k3s safely."
echo ""
pluto detect-files -d "$REPO" -o json > "$TMPDIR/pluto.json" 2>"$TMPDIR/pluto.err" || true
PLUTO_DEPR=$(jq '.items? | length' "$TMPDIR/pluto.json" 2>/dev/null || echo 0)
echo "Deprecated API usages: $PLUTO_DEPR"
if [[ $PLUTO_DEPR -gt 0 ]]; then
  echo ""
  echo "### Pluto hits"
  jq -r '.items[] | "  - " + .name + " (" + .apiGroup + "/" + .apiVersion + " kind=" + .kind + ")"' "$TMPDIR/pluto.json" 2>/dev/null | head -20
  echo ""
  echo "What this means: These APIs will break on a future Kubernetes upgrade. Update the manifest to the current API version."
else
  echo "No deprecated APIs found — k3s upgrade window is safe for now."
fi
echo ""

# --- 7. Custom GitOps / SOPS checks ---
echo "## Custom GitOps checks"
echo ""
echo "What this does: Because the repo is public, we manually verify SOPS usage, plaintext secrets, hostPath volumes, privileged containers, and root users. These checks are not built into the scanners above."
echo ""
SOPS_FILES=0
AGE_KEY_SET=0
PLAIN_SECRET=0
HOSTPATH=0
HOSTPATH_FILES=""
PRIVILEGED=0
PRIVILEGED_FILES=""
ROOT_USER=0
ROOT_USER_FILES=""

if [[ -f "$REPO/.sops.yaml" ]]; then
  SOPS_FILES=1
  if grep -qE 'age[0-9a-z]+' "$REPO/.sops.yaml"; then
    AGE_KEY_SET=1
  fi
fi

while IFS= read -r -d '' file; do
  rel=${file#$REPO/}
  if grep -qE '^kind:\s*Secret' "$file" 2>/dev/null && ! grep -qE '^sops:' "$file" 2>/dev/null; then
    PLAIN_SECRET=$((PLAIN_SECRET + 1))
    echo "  Plaintext Secret: $rel"
  fi
  if grep -qE '^[^#]*hostPath:' "$file" 2>/dev/null; then
    HOSTPATH=$((HOSTPATH + 1))
    HOSTPATH_FILES="$HOSTPATH_FILES  - $rel\n"
  fi
  if grep -qE '^[^#]*privileged:\s*true' "$file" 2>/dev/null; then
    PRIVILEGED=$((PRIVILEGED + 1))
    PRIVILEGED_FILES="$PRIVILEGED_FILES  - $rel\n"
  fi
  if grep -qE '^[^#]*runAsUser:\s*0' "$file" 2>/dev/null || grep -qE '^[^#]*runAsGroup:\s*0' "$file" 2>/dev/null; then
    ROOT_USER=$((ROOT_USER + 1))
    ROOT_USER_FILES="$ROOT_USER_FILES  - $rel\n"
  fi
done < <(find "$REPO" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)

echo ""
echo "| Check | Result |"
echo "| .sops.yaml present | $([[ $SOPS_FILES -eq 1 ]] && echo yes || echo no) |"
echo "| age recipient configured | $([[ $AGE_KEY_SET -eq 1 ]] && echo yes || echo no) |"
echo "| Plaintext Secret manifests | $PLAIN_SECRET |"
echo "| hostPath volumes | $HOSTPATH |"
echo "| Privileged containers | $PRIVILEGED |"
echo "| Root (uid/gid 0) containers | $ROOT_USER |"
echo ""

if [[ $PLAIN_SECRET -gt 0 ]]; then
  echo "Actionable: Encrypt the listed Secret with SOPS or move its data out of a Secret resource."
fi
if [[ $HOSTPATH -gt $ACCEPTED_HOSTPATH ]]; then
  echo "### hostPath mounts"
  printf "$HOSTPATH_FILES"
  echo ""
  echo "Actionable: Review each hostPath. Some are required (e.g., node-level exporters), but they should be read-only and documented."
elif [[ $HOSTPATH -gt 0 ]]; then
  echo "### hostPath mounts (accepted)"
  printf "$HOSTPATH_FILES"
  echo ""
fi
if [[ $PRIVILEGED -gt $ACCEPTED_PRIVILEGED ]]; then
  echo "### Privileged containers"
  printf "$PRIVILEGED_FILES"
  echo ""
  echo "Actionable: Replace privileged: true with fine-grained capabilities where possible."
elif [[ $PRIVILEGED -gt 0 ]]; then
  echo "### Privileged containers (accepted)"
  printf "$PRIVILEGED_FILES"
  echo ""
fi
if [[ $ROOT_USER -gt $ACCEPTED_ROOT ]]; then
  echo "### Root (uid/gid 0) containers"
  printf "$ROOT_USER_FILES"
  echo ""
  echo "Actionable: Run containers as non-root if the image supports it."
elif [[ $ROOT_USER -gt 0 ]]; then
  echo "### Root (uid/gid 0) containers (accepted)"
  printf "$ROOT_USER_FILES"
  echo ""
fi
echo ""

# --- 8. Summary ---
CUSTOM_CRITICAL=$((PRIVILEGED + HOSTPATH + ROOT_USER - ACCEPTED_PRIVILEGED - ACCEPTED_HOSTPATH - ACCEPTED_ROOT))
[[ $CUSTOM_CRITICAL -lt 0 ]] && CUSTOM_CRITICAL=0

CRITICAL=$((GLEAKS_FINDINGS + TRIVY_SECRETS + PLAIN_SECRET + CUSTOM_CRITICAL))
WARNINGS=$((TRIVY_KEPT + KUBECONFORM_FAILS + KSCORE_WARN + PLUTO_DEPR))

echo "## Summary"
echo ""
echo "| Category | Count |"
echo "| Critical issues | $CRITICAL |"
echo "| Warnings | $WARNINGS |"
echo ""

if [[ $CRITICAL -gt 0 ]]; then
  echo "Action required: critical findings detected. Check the sections above and open or update task notes in homelab/tasks/."
  echo ""
  echo "Open task notes:"
  ls -1 "$TASK_DIR"/*.md 2>/dev/null | while read -r t; do
    basename "$t"
  done
elif [[ $WARNINGS -gt 0 ]]; then
  echo "No criticals, but warnings need review."
else
  echo "Clean bill of health."
fi

echo ""
echo "Next scan: tomorrow night."
