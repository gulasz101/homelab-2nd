---
title: "Fix empty Mattermost alerts from Alertmanager"
status: done
priority: high
created: 2026-09-02
labels:
  - alerting
  - mattermost
  - alertmanager
  - prometheus
  - flux
assigned: andrzej
source: user-report
---

## Context

Supreme Leader reported receiving many empty messages from the `akadmin` bot in Mattermost at 8:20, 8:25, 8:30, 8:35, 8:55, 9:00, 9:05, 9:10, 9:15, 9:25 and 10:05. The messages had no title or body, so it was impossible to know what they were about.

## Root cause

The per-namespace `AlertmanagerConfig` CRDs were using `.CommonAnnotations.summary` and `.CommonAnnotations.description` in the Slack/Mattermost receiver templates. When Alertmanager groups multiple alerts together (the top-level route groups by `job`), `CommonAnnotations` only contains annotations that are **identical across every alert in the group**. If the grouped alerts have different summaries or descriptions, those fields become empty strings.

Mattermost accepts the Slack-compatible webhook payload but renders an empty post when the attachment `title` and `text` are both empty. The `fallback` field is only used for push/notification previews, not the channel message body.

A second issue found during the fix: several per-namespace `PrometheusRule` resources had the label `release: kube-prometheus-stack`, while the live Prometheus CR's `ruleSelector` only matches `release: prometheus-stack`. That meant those rules were not being loaded by Prometheus at all, so they could never alert. The `opengist` and `shlink` rules also lacked `description` annotations.

## Fix

### 1. Make Mattermost message templates independent of common annotations

Updated every `AlertmanagerConfig` that routes to Mattermost:

- `apps/firecrawl/firecrawl-alertmanager-config.yaml`
- `apps/gpu-embedding/gpu-embedding-alertmanager-config.yaml`
- `apps/honcho/honcho-alertmanager-config.yaml`
- `apps/llm-hub/llm-hub-alertmanager-config.yaml`
- `apps/opengist/opengist-alertmanager-config.yaml`
- `apps/openviking/openviking-alertmanager-config.yaml`
- `apps/shlink/shlink-alertmanager-config.yaml`
- `apps/voice/voice-alertmanager-config.yaml`
- `infrastructure/observability/homelab-node-alertmanager-config.yaml`

New templates (YAML literal block scalars):

```yaml
title: |-
  [{{ .Status | toUpper }}] {{ .CommonLabels.namespace | default "homelab" }}: {{ len .Alerts.Firing }} firing{{ if .Alerts.Resolved }}, {{ len .Alerts.Resolved }} resolved{{ end }}
text: |-
  {{ range .Alerts.Firing }}- {{ .Labels.alertname }}: {{ .Annotations.summary }}{{ if .Annotations.description }} — {{ .Annotations.description }}{{ end }}
  {{ end }}{{ range .Alerts.Resolved }}- {{ .Labels.alertname }}: {{ .Annotations.summary }} (resolved)
  {{ end }}
fallback: |-
  {{ .CommonLabels.namespace | default "homelab" }} alert: {{ len .Alerts.Firing }} firing{{ if .Alerts.Resolved }}, {{ len .Alerts.Resolved }} resolved{{ end }}
```

The title now always contains the namespace and alert count, and the body lists every firing/resolved alert with its summary and description. Grouped alerts no longer collapse into empty strings.

### 2. Fix PrometheusRule labels so rules are actually loaded

Changed the `release` label from `kube-prometheus-stack` to `prometheus-stack` in:

- `apps/firecrawl/firecrawl-prometheus-rules.yaml`
- `apps/gpu-embedding/gpu-embedding-prometheus-rules.yaml`
- `apps/honcho/honcho-prometheus-rules.yaml`
- `apps/llm-hub/llm-hub-prometheus-rules.yaml`
- `apps/opengist/opengist-prometheus-rules.yaml`
- `apps/shlink/shlink-prometheus-rules.yaml`

This matches the live Prometheus CR `ruleSelector: release=prometheus-stack`.

### 3. Add missing descriptions

Added `description` annotations to the `opengist` and `shlink` resource alerts so the new per-alert body has useful text.

## Verification

- Reconciled Flux `infrastructure` and `apps` Kustomizations to `main@sha1:d569b08626ff9bff601a6603f84f879b5b8ad31a`.
- Alertmanager reloaded config at `2026-09-02T08:12:45Z` without errors.
- Confirmed the generated `/etc/alertmanager/config_out/alertmanager.env.yaml` contains the new templates.
- Verified Prometheus now loads 290 rules, including firecrawl/gpu-embedding/honcho/llm-hub/opengist/shlink rules.
- Created a temporary `TestMattermostTemplate` PrometheusRule in `honcho` (`expr: vector(1)`) to force a real notification. The alert became `active` with receiver `honcho/honcho-mattermost-alerts/honcho-mattermost` and `alertmanager_notifications_failed_total{integration="slack"}` remained 0. The temporary rule was then deleted.

## Commits

1. `fix(alerting): ensure Mattermost alerts always have content`
2. `fix(alerting): align PrometheusRule labels and add missing descriptions`

## Commands used

```bash
# Inspect current Alertmanager config
POD=$(kubectl -n observability get pods -l app.kubernetes.io/name=alertmanager -o jsonpath='{.items[0].metadata.name}')
kubectl -n observability exec "$POD" -c alertmanager -- cat /etc/alertmanager/config_out/alertmanager.env.yaml

# Reconcile Flux
sudo flux reconcile kustomization infrastructure --with-source
sudo flux reconcile kustomization apps --with-source

# List loaded Prometheus rules
PROM=$(kubectl -n observability get svc prometheus-stack-kube-prom-prometheus -o jsonpath='{.spec.clusterIP}')
curl -s "http://${PROM}:9090/api/v1/rules"

# Manual test alert (applied and then removed)
kubectl -n honcho apply -f /tmp/test-alertmanager-template.yaml
kubectl -n honcho delete prometheusrule test-alertmanager-template
```

## Lessons

- Using `.CommonAnnotations.summary/description` in Slack/Mattermost templates is unsafe when Alertmanager groups alerts by `job` (or any label) because annotations usually differ across alerts. The result is an empty Mattermost post.
- Always verify the Prometheus CR `ruleSelector` label matches the labels on `PrometheusRule` resources. A mismatched label silently disables the entire rule group.
- The `AlertmanagerConfig` selector label (`release=kube-prometheus-stack`) is independent of the Prometheus rule selector; keep them straight to avoid confusion.
- A real end-to-end test with a temporary `vector(1)` alert is the fastest way to prove notifications render correctly without waiting for production failures.

## Follow-up: empty alerts continued after the first fix

After the first commit, the Supreme Leader reported he was still receiving empty alerts. Investigation revealed two additional problems:

### 1. Manual test payloads left in the channel
While debugging, I sent three direct webhook test payloads to reproduce the empty-post behavior. One had content ("Test title / Test text"), but the other two intentionally had empty `title`/`text`. These appeared as empty `akadmin` posts in `#gulaszteam` around 10:10. This was sloppy — test traffic should never go to a production channel.

### 2. The new template used an unsupported function
The templates introduced in the first fix used `{{ .CommonLabels.namespace | default "homelab" }}`. Alertmanager's Go template engine does **not** include the Sprig/Helm `default` function. When the template failed to render, the output was empty, producing the exact empty posts the fix was meant to prevent.

All alerts routed by these `AlertmanagerConfig` CRDs already carry a `namespace` label because the route matcher requires it, so the `default` guard was unnecessary.

### Final template

```yaml
title: |-
  [{{ .Status | toUpper }}] {{ .CommonLabels.namespace }}: {{ len .Alerts.Firing }} firing{{ if .Alerts.Resolved }}, {{ len .Alerts.Resolved }} resolved{{ end }}
text: |-
  {{ range .Alerts.Firing }}- {{ .Labels.alertname }}: {{ .Annotations.summary }}{{ if .Annotations.description }} — {{ .Annotations.description }}{{ end }}
  {{ end }}{{ range .Alerts.Resolved }}- {{ .Labels.alertname }}: {{ .Annotations.summary }} (resolved)
  {{ end }}
fallback: |-
  {{ .CommonLabels.namespace }} alert: {{ len .Alerts.Firing }} firing{{ if .Alerts.Resolved }}, {{ len .Alerts.Resolved }} resolved{{ end }}
```

### Verification after second fix

- Committed `fix(alerting): remove unsupported default() template function`.
- Flux reconciled; Alertmanager reloaded config at `2026-09-02T10:04:19Z` without errors.
- Created a temporary `TestMattermostTemplate` warning alert in `honcho` (`expr: vector(1)`).
- `alertmanager_notifications_total{integration="slack"}` increased from 65 to 79 and `alertmanager_notifications_failed_total{integration="slack"}` stayed at 0.
- The temporary rule was deleted.

## Updated commits

1. `fix(alerting): ensure Mattermost alerts always have content`
2. `fix(alerting): align PrometheusRule labels and add missing descriptions`
3. `fix(alerting): remove unsupported default() template function`
4. `docs(tracking): empty Mattermost alert fix`
