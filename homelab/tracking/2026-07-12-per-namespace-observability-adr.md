# 2026-07-12 — Per-namespace observability: ADR companion + wrap-up

Companion tracking note to [ADR-005: Per-namespace observability](../docs/adr/adr-005-per-namespace-observability.md).

## Goal

Finish the per-namespace observability work started in `2026-07-11-gpu-embedding-observability-dashboard-alerts.md`. Specifically:

1. Fix `honcho` alert routing.
2. Regenerate `gpu-embedding` dashboard with human-readable units and a working logs panel.
3. Apply the same dashboard pattern to `honcho`.
4. Write a reusable dashboard generator and commit it to the repo.
5. Record the pattern in an ADR so a future blog post can reference it.

## What changed

### Honcho alert routing

The `honcho` `AlertmanagerConfig` used `urlSecret` to reference `honcho-mattermost-webhook-url`, but that secret was in the `observability` namespace. The Prometheus Operator resolves `urlSecret` only within the same namespace as the `AlertmanagerConfig` CRD, so it logged:

```
unable to get secret "honcho-mattermost-webhook-url": secrets "honcho-mattermost-webhook-url" not found
```

**Fix:**
- Moved `apps/honcho/honcho-mattermost-webhook-url.sops.yaml` from `namespace: observability` to `namespace: honcho`.
- Removed `honcho-mattermost-webhook-url` from `alertmanagerSpec.secrets` in `infrastructure/observability/prometheus-stack-helm-release.yaml` — that field is for mounting secrets as files into the Alertmanager pod, not for `urlSecret` lookup.
- Restarted the Prometheus Operator pod so its secret informer picked up the moved secret.

**Verification:**

```bash
export KUBECONFIG=/Users/wojciechgula/.kube/config-homelab-2nd
kubectl -n honcho get secret honcho-mattermost-webhook-url
kubectl -n observability get secret honcho-mattermost-webhook-url  # NotFound, expected
kubectl -n observability exec pod/alertmanager-prometheus-stack-kube-prom-alertmanager-0 -- \
  sh -c "zcat /etc/alertmanager/config/alertmanager.yaml.gz" | grep -B2 -A8 honcho
```

Rendered config now contains both routes:

```yaml
- receiver: gpu-embedding/gpu-embedding-mattermost-alerts/gpu-embedding-mattermost
  matchers:
  - namespace="gpu-embedding"
- receiver: honcho/honcho-mattermost-alerts/honcho-mattermost
  matchers:
  - namespace="honcho"
```

A test alert posted to `http://localhost:9093/api/v2/alerts` with label `namespace=honcho` returned HTTP 200.

### Dashboard template

Created `infrastructure/observability/dashboards/render_namespace_dashboard.py`. It takes three arguments:

```bash
python3 render_namespace_dashboard.py <namespace> <uid> "<title>"
```

It emits a ConfigMap in `observability` with label `grafana_dashboard: "1"` and annotation `grafana.folder: <namespace>`. The dashboard contains:

| Panel | Unit | Query highlights |
|---|---|---|
| CPU usage vs request vs limit | `cores` | `rate(container_cpu_usage_seconds_total{namespace="..."}[5m])` |
| CPU utilisation % of limit | `percent` | 0-100 scale, 80/90 thresholds |
| Memory usage vs request vs limit | `bytes` | Grafana auto-formats MB/GB |
| Memory utilisation % of limit | `percent` | 0-100 scale, 80/90 thresholds |
| PVC utilisation | `percent` | `kubelet_volume_stats_used_bytes / capacity_bytes` |
| Node disk utilisation | `percent` | `node_filesystem_*` for `host="homelab-2nd"` |
| Logs | logs panel | `{k8s_namespace_name="..."}` — **not** `namespace` |

### Regenerated dashboards

```bash
cd /Users/wojciechgula/Projects/homelab-2nd
python3 infrastructure/observability/dashboards/render_namespace_dashboard.py \
  gpu-embedding gpu-embedding-ollama "gpu-embedding — Ollama Embedding Service" \
  > apps/gpu-embedding/gpu-embedding-dashboard-configmap.yaml

python3 infrastructure/observability/dashboards/render_namespace_dashboard.py \
  honcho honcho "honcho — AI Companion Service" \
  > apps/honcho/honcho-dashboard-configmap.yaml
```

### Commits

- `44e96ae` — `fix(honcho): move Mattermost webhook secret into honcho namespace for urlSecret resolution`
- `0bfc6c9` — `feat(observability): reusable namespace dashboard template + regenerate gpu-embedding and honcho dashboards`
- ADR-005 + README update (separate commit).

### Flux reconciliation

Annotated `gitrepository/flux-system` and `kustomization/apps`. Apps kustomization reached revision `main@sha1:0bfc6c9...`.

### Grafana verification

Port-forwarded Grafana and confirmed both dashboards are loaded:

```bash
PASS=$(kubectl -n observability get secret grafana-admin-credentials -o jsonpath='{.data.admin-password}' | base64 -d)
curl -s "http://admin:$PASS@localhost:3000/api/search?query=gpu-embedding"
curl -s "http://admin:$PASS@localhost:3000/api/search?query=honcho"
```

Result:

```
gpu-embedding-ollama gpu-embedding — Ollama Embedding Service
honcho               honcho — AI Companion Service
```

API inspection confirmed:
- CPU panels use `custom.unit: "cores"`.
- Memory panels use `custom.unit: "bytes"`.
- Utilisation panels use `custom.unit: "percent"` with thresholds.
- Logs panel queries `{k8s_namespace_name="gpu-embedding"}` and `{k8s_namespace_name="honcho"}`.

## Key lesson for the blog post

The big trap: `AlertmanagerConfig.urlSecret` is **namespace-scoped to the CRD**, not to the Alertmanager pod. A secret mounted into the Alertmanager pod via `alertmanagerSpec.secrets` cannot be referenced by `urlSecret` from another namespace. Two valid patterns:

1. Put the secret in the same namespace as the `AlertmanagerConfig` (what we do).
2. Put the secret in the Alertmanager namespace and use `url_file` pointing to `/etc/alertmanager/secrets/...` — but this is only supported in raw Alertmanager config, **not** in the `AlertmanagerConfig` CRD schema (we tested it; the operator rejects it).

Also: Loki pod logs are indexed under `k8s_namespace_name`, not `namespace`, because the OpenTelemetry collector agent relabels them. Dashboard log panels must use that label or they show nothing.

## Files added / changed

- `docs/adr/adr-005-per-namespace-observability.md`
- `docs/adr/README.md`
- `infrastructure/observability/dashboards/render_namespace_dashboard.py`
- `apps/gpu-embedding/gpu-embedding-dashboard-configmap.yaml`
- `apps/honcho/honcho-dashboard-configmap.yaml`
- `apps/honcho/honcho-mattermost-webhook-url.sops.yaml`
- `apps/honcho/honcho-alertmanager-config.yaml`
- `infrastructure/observability/prometheus-stack-helm-release.yaml`

## What's still open

- TEI deployment still exists in `apps/gpu-embedding/tei-deployment.yaml` but is commented out of `apps/kustomization.yaml`. Remove it properly later.
- Apply the same observability package to remaining namespaces: `llm-hub`, `nextcloud`, `mattermost`, `tldraw`, `docs-mcp`.
- Verify a real alert actually lands in Mattermost channel `irxxnog453r58js7ktjcpwdqwh`. The routing and webhook HTTP 200 are confirmed; the final delivery depends on the webhook URL being correct, which it is (same URL used by `gpu-embedding`).

## References

- ADR-005: `docs/adr/adr-005-per-namespace-observability.md`
- Previous tracking note: `homelab/tracking/2026-07-11-gpu-embedding-observability-dashboard-alerts.md`
- Dashboard generator: `infrastructure/observability/dashboards/render_namespace_dashboard.py`
- Grafana URL: `https://grafana.voitech.dev`
- Honcho dashboard: `https://grafana.voitech.dev/d/honcho/honcho`
- GPU embedding dashboard: `https://grafana.voitech.dev/d/gpu-embedding-ollama/gpu-embedding-ollama-embedding-service`
