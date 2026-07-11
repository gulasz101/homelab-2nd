# ADR-005: Per-namespace observability — dashboards, Prometheus rules, and Loki alerts

Date: 2026-07-12
Status: Accepted
Supersedes: nothing
Superseded by: nothing

## Context

The homelab runs one service per Kubernetes namespace (e.g. `gpu-embedding`, `honcho`, `llm-hub`, `nextcloud`). Until now observability was ad-hoc:

- A handful of global dashboards existed (`homelab-system-load-dashboard`, `homelab-gpu-power-dashboard`) but nothing scoped to a service.
- The `gpu-embedding` dashboard, when first provisioned, showed raw byte values like `710791168` because Grafana field units were not set.
- The logs panel on that dashboard was empty because it queried `{namespace="gpu-embedding"}` while Loki actually indexes pod logs under `k8s_namespace_name` due to the OpenTelemetry collector relabeling.
- `honcho` had a namespace-scoped `AlertmanagerConfig` that failed to render because its `urlSecret` pointed to a secret in `observability` instead of `honcho`. The Prometheus Operator resolves `urlSecret` only within the same namespace as the `AlertmanagerConfig` CRD.

This ADR records the repeatable pattern we adopted for service-level observability.

## Decision

**Every namespace/service gets a standard observability package consisting of:**

1. A provisioned Grafana dashboard ConfigMap in `observability` with label `grafana_dashboard: "1"`.
2. A `PrometheusRule` in the service namespace for CPU/memory resource alerts.
3. A Loki Ruler ConfigMap in `observability` with label `loki_rule: "true"` for log-based alerts.
4. A SOPS-encrypted webhook secret in the service namespace.
5. A namespace-scoped `AlertmanagerConfig` CRD (labelled `release: kube-prometheus-stack`) routing alerts with `namespace=<service>` to the webhook.

**Dashboard standard:**
- CPU panels use unit `cores`.
- Memory panels use unit `bytes` so Grafana auto-formats to MB/GB.
- Utilisation panels use unit `percent` with 0-100 scale and 80/90 colour thresholds.
- Log panels query `{k8s_namespace_name="<namespace>"}` because the OpenTelemetry collector agent relabels `namespace` to `k8s_namespace_name`.

**Alertmanager secret rule:**
- `urlSecret` in an `AlertmanagerConfig` must reference a secret in the **same namespace** as the CRD.
- Do not put webhook secrets in `observability` unless the `AlertmanagerConfig` also lives there.
- `alertmanagerSpec.secrets` in the HelmRelease is for mounting files into the Alertmanager pod (e.g. TLS certs, templates), not for resolving `urlSecret` references.

## Consequences

### Positive
- One consistent pattern scales to every service.
- Dashboards are human-readable out of the box.
- Logs actually appear because the query uses the indexed label.
- Each service owns its alert routing secret; isolation is clean.
- Generated dashboards are code: a Python template renders the JSON ConfigMap.

### Negative / Risks
- Repeating a webhook secret per namespace means N SOPS files for N services. Acceptable for a small homelab.
- Adding a new namespace requires running the dashboard generator and copying a few manifest patterns. We may later template the entire package.
- The `AlertmanagerConfig` `urlSecret` cross-namespace trap is easy to fall into; new services must follow the rule above.

## Alternatives considered

| Option | Why rejected |
|---|---|
| Global Alertmanager receivers with webhook URL in plain text | Rejected. The repo is public and Guardrail #5 forbids plaintext credentials. |
| One shared webhook secret in `observability` referenced by all `AlertmanagerConfig`s | Rejected. The Prometheus Operator resolves `urlSecret` per CRD namespace; cross-namespace references fail silently. |
| Hand-written dashboard JSON per namespace | Rejected. Error-prone and hard to keep consistent. The Python generator guarantees identical structure. |
| Loki log queries using `namespace` label | Rejected. The OTel collector rewrites the stream label to `k8s_namespace_name`; querying `namespace` returns empty results. |
| Grafana alerting UI instead of provisioned alerts | Rejected. GitOps is law (Guardrail #1). Alerts must live in the repo and be applied by Flux. |

## When to revisit

Revisit this ADR if:
- The number of services grows large enough that duplicating manifests becomes painful (then invest in a Helm chart or Kustomize component).
- We switch from OpenTelemetry collector log relabeling to a different label schema.
- The Prometheus Operator adds `url_file` support to `AlertmanagerConfig` CRDs, allowing secret mounting from Alertmanager's own namespace instead of per-namespace secrets.
- Alert routing needs more than one webhook per service (e.g. PagerDuty, Slack, email).

## References

- `infrastructure/observability/dashboards/render_namespace_dashboard.py`
- `apps/gpu-embedding/gpu-embedding-dashboard-configmap.yaml`
- `apps/gpu-embedding/gpu-embedding-prometheus-rules.yaml`
- `apps/gpu-embedding/gpu-embedding-loki-rule.yaml`
- `apps/gpu-embedding/gpu-embedding-alertmanager-config.yaml`
- `apps/gpu-embedding/gpu-embedding-mattermost-webhook-url.sops.yaml`
- `apps/honcho/honcho-dashboard-configmap.yaml`
- `apps/honcho/honcho-prometheus-rules.yaml`
- `apps/honcho/honcho-error-loki-rule.yaml`
- `apps/honcho/honcho-alertmanager-config.yaml`
- `apps/honcho/honcho-mattermost-webhook-url.sops.yaml`
- `infrastructure/observability/prometheus-stack-helm-release.yaml`
- Tracking note: `homelab/tracking/2026-07-11-gpu-embedding-observability-dashboard-alerts.md`
- Tracking note: `homelab/tracking/2026-07-12-per-namespace-observability-adr.md` (this ADR companion)
