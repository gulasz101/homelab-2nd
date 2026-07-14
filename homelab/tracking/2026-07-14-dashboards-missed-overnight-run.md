# 2026-07-14 Dashboards — Missed Overnight Subagent Run + Recovery

## Context

The previous session on 2026-07-13 ended with a plan to create per-namespace Grafana dashboards overnight by delegating work to subagents. The intended namespaces were:

- `auth` (Authentik server/worker, CNPG Postgres, Redis, Cloudflare tunnel)
- `llm-hub` (LiteLLM, Open WebUI, two CNPG Postgres clusters, Redis, tunnels)
- `nextcloud` (Nextcloud app, metrics exporter, Redis master, CNPG Postgres, tunnels)
- `docs-mcp` (docs-mcp-server, two PVCs)
- `observability` (Loki, Tempo, Prometheus, Grafana overview)
- `kube/flux` (kube-system + flux-system operations dashboard)

The plan was never executed. No subagents were dispatched, no cron job was created, and no work landed in the repo. This tracking note documents the recovery.

## Root cause of "no dashboards visible"

On logging into Grafana, the Supreme Leader only saw `Homelab System Load`, the manually-created dashboard. The Flux-managed, sidecar-provisioned dashboards were missing from the Grafana UI.

Investigation showed:

1. The dashboard ConfigMaps existed in the `observability` namespace with label `grafana_dashboard=1`.
2. The k8s-sidecar was writing JSON files into `/tmp/dashboards/{gpu-embedding,honcho,mattermost,Homelab}` every minute.
3. The Grafana SQLite database (`/var/lib/grafana/grafana.db`) only contained one non-folder dashboard: `Homelab System Load`.
4. The Grafana 11 `unified_storage` feature is enabled via `GF_UNIFIED_STORAGE_INDEX_PATH=/var/lib/grafana-search/bleve` in the Deployment. Grafana was not indexing the provisioned sidecar files until a provisioning reload was triggered.

The fix was to call the Grafana provisioning reload API:

```bash
pass=$(sudo kubectl -n observability get secret grafana-admin-credentials -o jsonpath='{.data.admin-password}' | base64 -d)
sudo kubectl -n observability exec deploy/grafana -c grafana -- \
  curl -sS -u admin:"$pass" http://127.0.0.1:3000/api/admin/provisioning/dashboards/reload -X POST
```

Result: `"message":"Dashboards config reloaded"`.

After reload, `/api/search` returned all provisioned dashboards:

```
gpu-embedding-ollama gpu-embedding — Ollama Embedding Service
homelab-gpu-power    Homelab GPU & Power
homelab-system-load  Homelab System Load
honcho-overview-v2   honcho — Memory & Dialectic
mattermost-overview  mattermost — Team Chat
```

## Lesson

Provisioned files sitting on disk do **not** guarantee Grafana indexes them. With Grafana 11 unified storage enabled, a provisioning reload is required when dashboards are added or changed. The sidecar provider `updateIntervalSeconds: 30` only re-reads the filesystem, it does not force the unified-search index to refresh.

## Folder problem (second round)

After the dashboards became visible they were all in the default **General** folder, even though each ConfigMap carried a `grafana.folder` annotation and the sidecar was placing files under `/tmp/dashboards/<folder>/<dashboard>.json`.

The generated `sc-dashboardproviders.yaml` in the Grafana pod had:

```yaml
options:
  foldersFromFilesStructure: false
  path: /tmp/dashboards
```

With `foldersFromFilesStructure: false`, Grafana treats `/tmp/dashboards` as a flat directory and imports every dashboard into the configured provider folder (`''` → General). The annotation only controlled where the sidecar wrote the file, not where Grafana placed it in the UI.

Fix: add `foldersFromFilesStructure: true` to the Helm chart values in `infrastructure/observability/grafana-helm-release.yaml`:

```yaml
sidecar:
  dashboards:
    enabled: true
    label: grafana_dashboard
    labelValue: "1"
    folderAnnotation: grafana.folder
    reloadURL: "http://grafana.observability.svc.cluster.local:3000/api/admin/provisioning/dashboards/reload"
    provider:
      foldersFromFilesStructure: true
```

After Flux reconciled the HelmRelease, a Grafana pod restart was needed for the new provider config and unified-storage index to take effect. The restart re-indexed dashboards into their proper folders.

## Auth dashboard wiring gap

After creating `infrastructure/auth/auth-dashboard-configmap.yaml` it was added to `infrastructure/auth/kustomization.yaml`, but `infrastructure/kustomization.yaml` is what Flux reconciles. The auth dashboard did not appear in Grafana until `infrastructure/kustomization.yaml` was updated to reference `auth/auth-dashboard-configmap.yaml`.

## ADR

`docs/adr/adr-006-grafana-folders-from-files-structure.md` records the folder decision, the root cause, alternatives considered, and when to revisit.

## Commands used

Check existing dashboard ConfigMaps:

```bash
ssh homelab-2nd "sudo kubectl -n observability get configmap -l grafana_dashboard=1"
```

Check generated provider config:

```bash
sudo kubectl -n observability exec deploy/grafana -c grafana -- \
  cat /etc/grafana/provisioning/dashboards/sc-dashboardproviders.yaml
```

Check sidecar folder placement:

```bash
sudo kubectl -n observability logs -l app.kubernetes.io/name=grafana --container grafana-sc-dashboard --tail=30
```

Restart Grafana to re-index dashboards into folders:

```bash
sudo kubectl -n observability rollout restart deployment/grafana
```

Force provisioning reload:

```bash
pass=$(sudo kubectl -n observability get secret grafana-admin-credentials -o jsonpath='{.data.admin-password}' | base64 -d)
sudo kubectl -n observability exec deploy/grafana -c grafana -- \
  curl -sS -u admin:"$pass" http://127.0.0.1:3000/api/admin/provisioning/dashboards/reload -X POST
```

Verify dashboards visible and in correct folders:

```bash
sudo kubectl -n observability exec deploy/grafana -c grafana -- \
  curl -sS -u admin:"$pass" 'http://127.0.0.1:3000/api/search?type=dash-db'
```

## Final folder layout

```
folder= auth                 uid= auth-overview                title= auth — Authentik Identity
folder= docs-mcp             uid= docs-mcp-overview            title= docs-mcp — Docs Embedding Server
folder= gpu-embedding        uid= gpu-embedding-ollama         title= gpu-embedding — Ollama Embedding Service
folder= Homelab              uid= homelab-gpu-power            title= Homelab GPU & Power
folder= Homelab              uid= homelab-system-load          title= Homelab System Load
folder= honcho               uid= honcho-overview-v2           title= honcho — Memory & Dialectic
folder= Homelab              uid= kube-flux-overview           title= kube-flux — Control Plane & GitOps
folder= llm-hub              uid= llm-hub-overview             title= llm-hub — LiteLLM + Open WebUI
folder= mattermost           uid= mattermost-overview          title= mattermost — Team Chat
folder= nextcloud            uid= nextcloud-overview           title= nextcloud — Photos + Files
folder= observability        uid= observability-overview       title= observability — LGTM Stack
```

## References

- Skill `homelab-namespace-dashboard` for the generator and unified-storage collision fix.
- Skill `homelab-gitops` for repo layout and conventions.
- `docs/adr/adr-006-grafana-folders-from-files-structure.md`