#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-302: THE one entry point for every check in this repo. The factory's
# agents and the CI job trust only this command's exit code.
#
#   Exit 0 = every check passed.  Exit 1 = at least one failed.  SKIP is
#   neither — it is printed and counted, and every SKIP entry carries a
#   one-line reason below.
#
#   Usage:  scripts/check.sh          run everything
#           scripts/check.sh --list   print the checks, run nothing
#
#   Adding a check: drop an executable-ish `*/tests/*-check.sh` under apps/,
#   infrastructure/, docs/, agents/, scripts/ or host/ — it is discovered and run
#   with no edit to this file. Checks that need the live cluster, SSH, the OMV
#   host or decrypted secrets cannot run in CI: put them on the SKIP list with
#   a reason instead of deleting or weakening them.
#
#   Runs on the Air (macOS, bash 3.2!) and on ubuntu-latest. That rules out
#   `declare -A` and friends — apps/zigbee/tests/render-check.sh used bash-4
#   syntax and silently exited 0 untested on 3.2 (fixed in this PR).
#
#   NEVER call `sops` from here: decrypting is forbidden, CI has no age key,
#   and `sops` with a bad argument opens an editor and hangs the run.
#   `yq` reads the encrypted shape without decrypting.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Same tool versions as the Air (see .github/workflows/check.yaml).
K8S_VERSION=1.31.0
CRD_SCHEMA='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
# Copied from apps/zigbee/tests/render-check.sh: skip Secret because SOPS
# metadata blocks break the strict Secret schema; the sops check below covers
# Secrets directly. CustomResourceDefinition: no public schema source carries
# the CRD kind's own schema (verified: 404 in yannh/kubernetes-json-schema AND
# datreeio CRDs-catalog), so kubeconform can only ever error on CRD manifests.
# The CRDs here are vendored upstream operator bundles; this is the documented
# community workaround, not a weakening - no existing gate ever rendered the
# infrastructure tree. NB: -skip is ONE comma-separated flag; a second -skip
# replaces the first (kubeconform 0.8.0), which silently un-skips Secrets.
KUBECONFORM=(kubeconform -strict -summary -kubernetes-version "$K8S_VERSION"
  -skip Secret,CustomResourceDefinition
  -schema-location default -schema-location "$CRD_SCHEMA")

# A SOPS-encrypted doc whose apiVersion/kind are themselves ciphertext cannot
# be schema-validated without decrypting - and check.sh never decrypts. Such
# docs are filtered from the kubeconform input (counted and printed) and the
# sops check asserts their encrypted shape instead.
CIPHERTEST='((.apiVersion // "" | tostring) | test("^ENC\\[")) or ((.kind // "" | tostring) | test("^ENC\\["))'

# ---- check registry (parallel arrays; bash 3.2 has no assoc arrays) ----
NAMES=() CMDS=() KINDS=() PATHS=() REASONS=()

register() { # name command [repo-path it runs]
  NAMES+=("$1"); CMDS+=("$2"); KINDS+=("run"); PATHS+=("${3:-}"); REASONS+=("")
}
skip_check() { # repo-path reason
  NAMES+=("$1"); CMDS+=(""); KINDS+=("skip"); PATHS+=("$1"); REASONS+=("$2")
}
already_listed() { # path -> 0 if NAME/PATH already covers it
  local p="$1" i
  for ((i = 0; i < ${#PATHS[@]}; i++)); do
    [ "${PATHS[$i]}" = "$p" ] && return 0
  done
  return 1
}

# ---- 1. render: every Flux root, read from the cluster dir, not guessed ----
validate_render() { # $1 = file with the multi-doc render
  local total clean enc
  total=$(grep -c '^kind:' "$1")
  # NB the outer parens: in yq, "select(A or B | not)" binds `not` to B only
  # and lets EVERY doc through - a silent false green, verified empirically.
  enc=$(yq eval "select(($CIPHERTEST))" "$1" | grep -c '^kind:')
  # .yaml on purpose: kubeconform silently skips files without a YAML/JSON
  # extension ("0 resource found in 0 file" - a false green caught here).
  if ! yq eval "select(($CIPHERTEST) | not)" "$1" > "$WORK/clean.yaml"; then
    printf 'FAIL: yq ciphertext filter errored on %s\n' "$1"; return 1
  fi
  clean=$(grep -c '^kind:' "$WORK/clean.yaml")
  if [ "$clean" -ne $((total - enc)) ]; then
    printf 'FAIL: render filter lost objects: total %s, ciphertext %s, clean %s\n' "$total" "$enc" "$clean"
    return 1
  fi
  printf 'rendered %s objects, excluded %s sops-ciphertext docs, kubeconform on the other %s\n' \
    "$total" "$enc" "$clean"
  "${KUBECONFORM[@]}" "$WORK/clean.yaml"
}

render_root() { # $1 = flux root path, e.g. ./apps
  local root="$1" file
  if [ -e "$root/kustomization.yaml" ] || [ -e "$root/kustomization.yml" ]; then
    if ! kubectl kustomize "$root" > "$WORK/render.yaml" 2> "$WORK/build.err"; then
      printf 'FAIL: kubectl kustomize %s:\n' "$root"; sed 's/^/    /' "$WORK/build.err"; return 1
    fi
  else
    # Flux's kustomize-controller applies a spec.path WITHOUT a
    # kustomization.yaml as a plain manifest directory in filename order
    # (./infrastructure/cert-manager is wired that way and the running
    # cluster proves the semantics: "Applied revision: main@...,
    # ReconciliationSucceeded"). kubectl kustomize refuses such a dir, so
    # mirror the controller instead of inventing a kustomization file the
    # cluster does not use.
    printf 'note: %s has no kustomization.yaml - using the Flux plain-directory fallback\n' "$root"
    : > "$WORK/render.yaml"
    for file in "$root"/*.yaml "$root"/*.yml; do
      [ -e "$file" ] || continue
      printf -- '---\n' >> "$WORK/render.yaml"; cat "$file" >> "$WORK/render.yaml"
    done
  fi
  validate_render "$WORK/render.yaml"
}

run_render() {
  local rc=0 root f n=0
  # One yq per file: multi-file yq interleaves `---` separators that would
  # otherwise end up treated as roots.
  for f in clusters/production/*.yaml; do
    root=$(yq eval '.spec.path // ""' "$f" 2>"$WORK/yq.err") || {
      printf 'FAIL: yq could not read %s:\n' "$f"; sed 's/^/    /' "$WORK/yq.err"; rc=1; continue; }
    [ -n "$root" ] || continue
    n=$((n + 1))
    printf 'flux root: %s (%s)\n' "$root" "$f"
    render_root "$root" || rc=1
  done
  [ "$n" -gt 0 ] || { printf 'FAIL: no Flux roots found in clusters/production/*.yaml\n'; rc=1; }

  # The Flux Kustomization CRs themselves must validate too.
  printf 'flux roots: %s, validating the Flux Kustomization files themselves\n' "$n"
  "${KUBECONFORM[@]}" clusters/production/*.yaml || rc=1
  return "$rc"
}

# ---- 2. sops: every kind:Secret document is encrypted, nothing plaintext ----
# Allowlist: "path|one-line reason". Empty on purpose — every Secret in this
# repo is SOPS-encrypted today. Add to it only with a reason Wojtek can read.
SOPS_EXCEPTIONS=()
is_sops_exception() { # path
  local f="$1" e
  for e in ${SOPS_EXCEPTIONS[@]+"${SOPS_EXCEPTIONS[@]}"}; do
    [ "${e%%|*}" = "$f" ] && { printf 'note: exception: %s\n' "$e"; return 0; }
  done
  return 1
}

run_sops() {
  local rc=0 f docs viol
  # Every tracked YAML except the skip dirs the brief names. git ls-files
  # never looks inside .git/, so that skip comes free.
  while IFS= read -r f; do
    # Pre-filter (fast): a candidate is any YAML with a plaintext kind:Secret
    # OR a ciphertext kind (a fully sops-encrypted doc). yq then decides.
    grep -qE '^kind:[[:space:]]*(Secret|ENC\[)' "$f" || continue
    is_sops_exception "$f" && continue
    # One line per Secret document: "<has_sops> <plaintext-keys>".
    # The only clean line is "true" (encrypted shape, no plaintext values)
    # or "true (all-ciphertext)" (the whole doc is sops-encrypted, so its
    # data map is ciphertext too - nothing to check inside without decrypting;
    # its encrypted shape IS the pass). Empty-string values do not count as
    # plaintext (e.g. authentik-redis username: ""), they carry no secret.
    # The yq expression must use quoted object keys - bare ones die in the
    # 4.54.1 lexer. \\[ passes through yq's own string escaping as \[.
    docs=$(yq eval 'select(.kind == "Secret" or ((.kind // "" | tostring) | test("^ENC\\[")))
        | (has("sops") | tostring) + " "
        + (if ((.kind // "" | tostring) | test("^ENC\\[")) then "(all-ciphertext)"
           else (((.data // {}) * (.stringData // {})) | to_entries
                 | map(select(.value | tostring | test("^ENC\\[") | not)
                       | select(.value | tostring != ""))
                 | map(.key) | join(","))
           end)' "$f" 2>"$WORK/yq.err")
    if [ $? -ne 0 ]; then
      printf 'FAIL: yq cannot parse %s:\n' "$f"; sed 's/^/    /' "$WORK/yq.err"; rc=1; continue
    fi
    while IFS=' ' read -r viol; do
      case "$viol" in
        true | "true (all-ciphertext)") ;;
        "") ;;
        *) printf 'FAIL: %s: doc not clean (%s) - want sops:true and every value ENC[\n' "$f" "$viol"; rc=1 ;;
      esac
    done <<< "$docs"
  done < <(git ls-files '*.yaml' '*.yml' | grep -v -E '^(references|docs)/')
  return "$rc"
}

# ---- 3. gitleaks: the commits of THIS change only, redacted ----
run_gitleaks() {
  # CI sets GITLEAKS_RANGE to the PR base..head shas; locally it is
  # origin/main..HEAD. Scan only the commits of the change, never the
  # history that is already merged. --redact keeps a finding from printing
  # the secret it found.
  local range="${GITLEAKS_RANGE:-origin/main..HEAD}"
  local base="${range%..*}" head="${range#*..}"
  printf 'gitleaks range: %s\n' "$range"
  git rev-parse --verify --quiet "$base" >/dev/null || {
    printf 'FAIL: gitleaks base %s not found (need full fetch-depth)\n' "$base"; return 1; }
  git rev-parse --verify --quiet "$head" >/dev/null || {
    printf 'FAIL: gitleaks head %s not found\n' "$head"; return 1; }
  gitleaks git . --log-opts="$range" --redact --no-banner --no-color
  local rc=$?
  case "$rc" in
    0) return 0 ;;
    1) printf 'FAIL: gitleaks found secret material in the range (values redacted above)\n'; return 1 ;;
    *) printf 'FAIL: gitleaks exited %s\n' "$rc"; return 1 ;;
  esac
}

# ---- 4./5. named checks ----
register "render"   "run_render"
register "sops"     "run_sops"
register "gitleaks" "run_gitleaks"
register "adr" "bash docs/adr/tests/adr-check.sh" "docs/adr/tests/adr-check.sh"

# Explicit entries for existing tests that do not match */tests/*-check.sh.
register "preflight-gate-test" "bash apps/zigbee/tests/preflight-gate-test.sh" \
  "apps/zigbee/tests/preflight-gate-test.sh"
register "nodered-cred-job-test" \
  "python3 apps/zigbee/tests/test-nodered-cred-job.py apps/zigbee/nodered-mqtt-credential-job.yaml" \
  "apps/zigbee/tests/test-nodered-cred-job.py"
register "agent-session-archive-unittests" \
  "python3 -m unittest discover -s scripts/agent-session-archive/tests -v" \
  "scripts/agent-session-archive/tests"

# ---- SKIP list: checks that cannot run in CI, one line of reason each ----
skip_check "apps/hindsight/tests/observability-check.sh" \
  "red on main: needs promtool for section 4 (AC1 duplicate keys + PromQL parse); promtool is not installed on the Air and not on ubuntu-latest, and is not in the approved CI tool set. Fix: install prometheus on the Air + add promtool to check.yaml, then drop this line."

# ---- auto-discovery: every */tests/*-check.sh, picked up with no edit here ----
DISCOVER_DIRS=()
for d in apps infrastructure docs agents scripts host; do
  [ -d "$d" ] && DISCOVER_DIRS+=("$d")
done
while IFS= read -r f; do
  [ -n "$f" ] || continue
  already_listed "$f" && continue
  register "$f" "bash $f" "$f"
done < <(find "${DISCOVER_DIRS[@]}" -path '*/tests/*-check.sh' -type f 2>/dev/null | sort)

# ---- --list ----
if [ "${1:-}" = "--list" ]; then
  for ((i = 0; i < ${#NAMES[@]}; i++)); do
    if [ "${KINDS[$i]}" = "skip" ]; then
      printf 'SKIP %s — %s\n' "${NAMES[$i]}" "${REASONS[$i]}"
    else
      printf 'RUN  %s\n' "${NAMES[$i]}"
    fi
  done
  exit 0
fi
[ "${1:-}" = "" ] || { printf 'usage: scripts/check.sh [--list]\n'; exit 2; }

# ---- run ----
RESULTS=() PASSED=0 FAILED=0 SKIPPED=0
for ((i = 0; i < ${#NAMES[@]}; i++)); do
  name="${NAMES[$i]}"
  if [ "${KINDS[$i]}" = "skip" ]; then
    printf 'SKIP %s — %s\n' "$name" "${REASONS[$i]}"
    RESULTS+=("SKIP $name (0s)")
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  printf 'running: %s\n' "$name" >&2
  start=$(date +%s)
  ( eval "${CMDS[$i]}" ) > "$WORK/out" 2>&1
  rc=$?
  took=$(( $(date +%s) - start ))
  if [ "$rc" -eq 0 ]; then
    RESULTS+=("PASS $name (${took}s)")
    PASSED=$((PASSED + 1))
  else
    RESULTS+=("FAIL $name (${took}s)")
    FAILED=$((FAILED + 1))
    printf '\n==== output of failed check: %s ====\n' "$name"
    sed 's/^/    /' "$WORK/out"
  fi
done

# ---- report: failing output already printed above; now the summary ----
printf '\n'
for ((i = 0; i < ${#RESULTS[@]}; i++)); do printf '%s\n' "${RESULTS[$i]}"; done
printf 'check: %d passed, %d failed, %d skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
[ "$FAILED" -eq 0 ] && exit 0 || exit 1
