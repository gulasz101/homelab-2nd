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

## Recovery plan (this session)

1. Create the six missing dashboards in the repo using the improved generator or hand-crafted JSON.
2. Add each dashboard ConfigMap to the relevant `kustomization.yaml` so Flux reconciles it.
3. Run `kubectl kustomize` locally to validate.
4. Commit, push, reconcile Flux from `homelab-2nd`.
5. Force Grafana provisioning reload and verify `/api/search` returns every dashboard.

## Commands used

Check existing dashboard ConfigMaps:

```bash
ssh homelab-2nd "sudo kubectl -n observability get configmap -l grafana_dashboard=1"
```

Check Grafana's database view of dashboards:

```bash
pod=$(sudo kubectl -n observability get pod -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')
sudo kubectl -n observability cp "$pod":/var/lib/grafana/grafana.db /tmp/grafana.db
python3 - <<'PY'
import sqlite3
c = sqlite3.connect('/tmp/grafana.db')
for r in c.execute("SELECT id,title,slug,uid,folder_id,version FROM dashboard WHERE is_folder=0;").fetchall():
    print(r)
PY
```

Force provisioning reload:

```bash
pass=$(sudo kubectl -n observability get secret grafana-admin-credentials -o jsonpath='{.data.admin-password}' | base64 -d)
sudo kubectl -n observability exec deploy/grafana -c grafana -- \
  curl -sS -u admin:"$pass" http://127.0.0.1:3000/api/admin/provisioning/dashboards/reload -X POST
```

Verify dashboards visible:

```bash
sudo kubectl -n observability exec deploy/grafana -c grafana -- \
  curl -sS -u admin:"$pass" http://127.0.0.1:3000/api/search?type=dash-db
```

## References

- Skill `homelab-namespace-dashboard` for the generator and unified-storage collision fix.
- Skill `homelab-gitops` for repo layout and conventions.
