#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# H2-336 / AC3: the host-watch package must render, validate, and express the
# alerting contract in the issue: three targets every 60 s, Mattermost after
# three consecutive failures, plus a heartbeat that fires on silence.
#
# Structural checks here, behaviour checks in hostwatch-unit-check.sh, and a
# real run against the live URLs in the H2-336 tracking note.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APP=$(cd "$HERE/.." && pwd)
ROOT=$(cd "$APP/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

RC=0
fail() { printf 'FAIL: %s\n' "$*"; RC=1; }
ok()   { printf 'ok:   %s\n' "$*"; }

# ---- 1. render + schema ---------------------------------------------------
if ! kubectl kustomize "$APP" > "$WORK/render.yaml" 2> "$WORK/err"; then
  printf 'FAIL: kubectl kustomize apps/host-watch:\n'; sed 's/^/    /' "$WORK/err"; exit 1
fi
docs=$(grep -c '^kind:' "$WORK/render.yaml")
printf 'rendered %s objects\n' "$docs"
if ! kubeconform -strict -summary -kubernetes-version 1.31.0 \
      -skip Secret,CustomResourceDefinition \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
      "$WORK/render.yaml"; then
  fail "kubeconform rejected the render"
fi

# ---- 2. it is wired into Flux --------------------------------------------
grep -q 'host-watch' "$ROOT/apps/kustomization.yaml" \
  && ok "apps/kustomization.yaml references host-watch (Flux will apply it)" \
  || fail "apps/kustomization.yaml does not reference host-watch: it would never reach the cluster"

# ---- 3. the probe contract ----------------------------------------------
for target in paperclip.voitech.dev chat.voitech.dev status.voitech.dev; do
  grep -q "$target" "$WORK/render.yaml" && ok "probe target $target" || fail "probe target $target missing"
done
grep -q 'HOSTWATCH_PROBE_INTERVAL' "$WORK/render.yaml" \
  && grep -q '"60"' "$WORK/render.yaml" \
  && ok "probe interval 60s" || fail "probe interval must be 60s (issue deliverable 4)"
grep -q 'HOSTWATCH_FAIL_THRESHOLD' "$WORK/render.yaml" \
  && ok "failure threshold configurable" || fail "no failure threshold configured"

# ---- 4. the alerting contract -------------------------------------------
RULES="$WORK/rules.yaml"
yq eval 'select(.kind == "PrometheusRule")' "$WORK/render.yaml" > "$RULES" 2>/dev/null || true
[ -s "$RULES" ] && ok "PrometheusRule present" || fail "no PrometheusRule: nothing would alert"
grep -q 'hostwatch_probe_consecutive_failures >= 3' "$RULES" \
  && ok "alert keys on 3 consecutive probe failures" || fail "no '>= 3' probe-failure alert"
grep -qE '(>=|>) 420' "$RULES" \
  && ok "heartbeat alert keys on 420s of silence (7 missed beats)" || fail "no heartbeat-silence alert"
grep -q 'hostwatch_component_up == 0' "$RULES" \
  && ok "per-component down alert present" || fail "no per-component alert (the Hermes API rides on it)"
grep -q 'severity: critical' "$RULES" && ok "severity labels present" || fail "alerts carry no severity label"
for alarm in HostWatchProbeFailing HostWatchHeartbeatMissing HostWatchHeartbeatNotConfigured HostWatchComponentDown; do
  grep -q "alert: $alarm" "$RULES" && ok "alert $alarm" || fail "missing alert $alarm"
done

# ---- 5. routing to Mattermost, secret by reference only ------------------
AM="$WORK/am.yaml"
yq eval 'select(.kind == "AlertmanagerConfig")' "$WORK/render.yaml" > "$AM" 2>/dev/null || true
[ -s "$AM" ] && ok "AlertmanagerConfig present" || fail "no AlertmanagerConfig: alerts go nowhere"
grep -q 'slackConfigs' "$AM" && ok "Mattermost receiver uses the house slackConfigs pattern" || fail "receiver is not the Mattermost/slack shape used everywhere else"
grep -q 'host-watch-mattermost-webhook-url' "$AM" || true
grep -qE 'name: host-watch-mattermost-webhook-url' "$AM" \
  && ok "webhook secret referenced by name (never inline)" || fail "webhook secret not referenced"
grep -q 'sendResolved: true' "$AM" && ok "resolved notifications on" || fail "sendResolved missing: an outage would never close"
grep -q 'value: host-watch' "$AM" && ok "route is limited to namespace host-watch" || fail "route matcher is not scoped to host-watch"

for f in "$APP"/host-watch-mattermost-webhook-url.sops.yaml; do
  [ -f "$f" ] || continue
  grep -q 'ENC\[AES256_GCM' "$f" && ok "webhook secret is SOPS-encrypted" || fail "$f is not encrypted"
  # A `url:`/`token:` line without ENC[ on it is plaintext. Match on the ENC
  # marker, not on a character class: `\s*[^E]` backtracks and matches a space
  # (this check was wrong once — that is why the comment exists).
  if grep -E '^[[:space:]]*(url|token):' "$f" | grep -vq 'ENC\['; then
    fail "$f carries a plaintext url/token line"
  else
    ok "no plaintext url/token line in the webhook secret"
  fi
done

# ---- 6. the heartbeat path is LAN-only and fail-closed -------------------
grep -q 'host-watch-heartbeat-token' "$WORK/render.yaml" \
  && ok "heartbeat token secret is referenced" || fail "heartbeat token secret not referenced"
grep -q 'optional: true' "$WORK/render.yaml" \
  && ok "token secret mounted optional (an unseeded token must not wedge Flux)" \
  || fail "token secret must be optional: otherwise a missing Secret blocks the whole apps kustomization"
grep -q 'nodePort: 30270' "$WORK/render.yaml" && ok "heartbeat ingest on LAN NodePort 30270" || fail "no LAN NodePort for heartbeat ingest"
grep -q 'cloudflared' "$WORK/render.yaml" && fail "host-watch must not expose a Cloudflare tunnel" || ok "no public ingress (LAN/Netbird only)"
grep -qi 'kind: NetworkPolicy' "$WORK/render.yaml" && ok "NetworkPolicy present" || fail "no NetworkPolicy for the heartbeat ingest"

# ---- 7. observability of the watcher itself -----------------------------
grep -q 'kind: ServiceMonitor' "$WORK/render.yaml" && ok "ServiceMonitor present" || fail "no ServiceMonitor: hostwatch_up would never be scraped"
grep -q 'release: prometheus-stack' "$WORK/render.yaml" && ok "pickup label for kube-prometheus-stack" || fail "missing release: prometheus-stack label"
grep -q 'readOnlyRootFilesystem: true' "$WORK/render.yaml" && ok "read-only root filesystem" || fail "container should run with a read-only root fs"
grep -q 'runAsNonRoot: true' "$WORK/render.yaml" && ok "runs as non-root" || fail "runAsNonRoot not set"

# ---- 8. no plaintext secrets anywhere in the package --------------------
if grep -rInE '(password|token|api[_-]?key|secret)[[:space:]]*:[[:space:]]*[A-Za-z0-9/+]{12,}' "$APP" --include='*.yaml' \
     | grep -v 'ENC\[' | grep -v 'name:' | grep -q .; then
  grep -rInE '(password|token|api[_-]?key|secret)[[:space:]]*:[[:space:]]*[A-Za-z0-9/+]{12,}' "$APP" --include='*.yaml' | grep -v 'ENC\[' | sed 's/^/    /'
  fail "possible plaintext credential in apps/host-watch"
else
  ok "no plaintext credentials in apps/host-watch"
fi

printf '\n%s\n' "$([ "$RC" -eq 0 ] && echo 'PASS: host-watch package' || echo 'FAIL: host-watch package')"
exit "$RC"
