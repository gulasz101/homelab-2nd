# Hindsight — agent memory platform (epic H2-232)

Self-hosted [Hindsight](https://hindsight.vectorize.io) replacing **Honcho** (profiles `default`,
`florian`) and **OpenViking** (profiles `andrzej`, `careerpa`, `szarik` + the OpenChamber agent) as
the single agent-memory platform. OpenViking is **retained** afterwards in a reduced role (MCP
endpoint + redundant store for technical projects) — do not plan its deletion.

Upstream: chart `oci://ghcr.io/vectorize-io/charts/hindsight` **0.10.3** (appVersion 0.10.3), MIT.
Docs are indexed in the homelab docs-mcp as library `hindsight@0.10.3`.

## Decided configuration (do not re-litigate; it was agreed 2026-10-12)

| Piece | Decision |
|---|---|
| Database | **CNPG** cluster `hindsight-db`, image `ghcr.io/cloudnative-pg/postgresql:16`, `instances: 1` |
| DB role/db | owner/database `hindsight`, credentials from secret `hindsight-db-credentials` |
| DB storage | `local-path`, `10Gi` (fast, NOT durable — durability is the S3 backup below) |
| pgvector | `bootstrap.initdb.postInitApplicationSQL: ["CREATE EXTENSION IF NOT EXISTS vector;"]` — Hindsight needs the extension and the app role is **not** superuser |
| Backups | barman → `s3://cnpg-backups/hindsight` at `http://openmediavault.local:9000`, `retentionPolicy: 30d`, creds secret `hindsight-minio-backup-creds` |
| Chart DB | `postgresql.enabled: false` (never the chart's bundled Postgres) |
| DB host for the chart | `hindsight-db-rw.hindsight.svc.cluster.local:5432` |
| Secrets | `existingSecret: hindsight-secrets` — **must contain `postgres-password`** (the api deployment and worker statefulset read that exact key whenever `postgresql.enabled=false`), plus `HINDSIGHT_API_LLM_API_KEY` and `HINDSIGHT_API_TENANT_API_KEY` |
| LLM | `HINDSIGHT_API_LLM_PROVIDER: litellm` → `http://litellm.llm-hub.svc.cluster.local:4000`, model `nemotron-3-nano-30b-ollama` (fallback `gpt-oss-20b-ollama`); key is the LiteLLM virtual key `memory-hindsight` |
| Image | **slim** (`-slim`), because embeddings/reranking are served externally |
| Embeddings | `HINDSIGHT_API_EMBEDDINGS_PROVIDER: tei` + the chart's `tei.embedding.enabled: true` (model `sentence-transformers/all-MiniLM-L6-v2`, 384-dim) |
| Reranker | `HINDSIGHT_API_RERANKER_PROVIDER: tei` + the chart's `tei.reranker.enabled: true` (model `cross-encoder/ms-marco-MiniLM-L6-v2`) |
| Workers | `worker.enabled: false` for the first cut (the API's internal worker is plenty for one user, and node CPU *requests* are the constraint) |
| Metrics | `metrics.serviceMonitor.enabled: true`, `labels: {release: prometheus-stack}` (the live Prometheus selector) |
| Exposure | Control Plane via its own Cloudflare tunnel later; the **API** on a LAN/Netbird NodePort (`30xxx`) because Hermes runs outside the cluster |
| MCP | auth **on**: `HINDSIGHT_API_TENANT_EXTENSION=hindsight_api.extensions.builtin.tenant:ApiKeyTenantExtension` + the tenant key from `hindsight-secrets` |

### Why CPU TEI and not the GPU (decided on evidence, 2026-10-12)

The host GPU is a **GTX 970M = Maxwell, compute capability 5.2**. TEI's published CUDA images require
compute capability ≥ 7.5 (Turing); CUDA 13 dropped everything below 7.5 entirely. So "slim + our
NVIDIA GPU" resolves to **CPU TEI for both models** for now. The GPU is *not* wasted long-term:
`gpu-embedding/ollama-embeddings` already serves `nomic-embed-text` (768-dim) on it, so moving
*embeddings* to the GPU later is a provider swap (`HINDSIGHT_API_EMBEDDINGS_PROVIDER` +
`_OPENAI_BASE_URL` pointed at the ollama OpenAI-compatible endpoint), not a rebuild. Revisit after
the pilot has latency numbers.

## File inventory

Already in the repo (written by Andrzej — **do not modify**; they are SOPS-encrypted and the
worker has no age key):

```
apps/hindsight/namespace.yaml
apps/hindsight/kustomization.yaml                      <- nested kustomization; APPEND your files here
apps/hindsight/hindsight-db-credentials.sops.yaml      <- keys: username, password
apps/hindsight/hindsight-secrets.sops.yaml             <- keys: postgres-password, HINDSIGHT_API_LLM_API_KEY, HINDSIGHT_API_TENANT_API_KEY
apps/hindsight/hindsight-minio-backup-creds.sops.yaml  <- keys: ACCESS_KEY_ID, ACCESS_SECRET_KEY
```

To be created by the delegated work (keep the `hindsight-` filename prefix):

```
apps/hindsight/hindsight-db-postgres-cluster.yaml   # CNPG Cluster
apps/hindsight/hindsight-scheduled-backup.yaml      # CNPG ScheduledBackup
apps/hindsight/hindsight-helm-repository.yaml       # HelmRepository (type: oci)
apps/hindsight/hindsight-helm-release.yaml          # HelmRelease
apps/hindsight/hindsight-service.yaml               # NodePort Services (api + control plane)
apps/hindsight/hindsight-prometheus-rules.yaml      # alerts
apps/hindsight/hindsight-alertmanager-config.yaml   # Mattermost routing
apps/hindsight/hindsight-dashboard-configmap.yaml   # the 3 upstream Grafana dashboards
```

## Rules for anyone (or anything) working in this directory

1. **Never touch a `*.sops.yaml` file here.** They are encrypted to the repo's age recipient and the
   cluster-side workers hold no private key. Secret *names* and *key names* are fixed and listed
   above; the values are not your business.
2. **Every new file must be appended to `apps/hindsight/kustomization.yaml`** in the same commit.
   A file that exists but is not listed does not deploy — this has bitten this homelab before.
3. **Validate before you commit**; the workspace has `helm`, `kubeconform` and `kubectl`:
   - `helm template hindsight oci://ghcr.io/vectorize-io/charts/hindsight --version 0.10.3 -f <values>`
     and *read* the rendered `HINDSIGHT_API_DATABASE_URL` (explicit `env` beats `envFrom`, so the
     chart's own assembly wins over ours — confirm it points at the CNPG service).
   - `kubeconform -strict` on the rendered output and on every raw manifest.
   - `kubectl kustomize apps/hindsight/` must render cleanly.
4. **Do not attempt cluster-side verification** (no kubeconfig, and the ServiceAccount is not
   cluster-admin). Repo authoring + local validation is the deliverable; Andrzej applies and verifies.
5. Follow the house style you can see in `apps/honcho/` and `apps/llm-hub/` — it is the closest
   neighbour for every one of these objects.
6. `apps/kustomization.yaml` already carries the single `- hindsight/` entry. Do not add per-file
   entries there.

## Gotchas already paid for upstream

- liveness `/health/live` (no DB I/O) vs readiness `/health` (queries the DB) — deliberately
  different; do not "fix" them to match.
- `recall_min_scores: {"reranker": 0.25}` is the fix for off-topic recall noise in the Hermes
  plugin config (a later task) — recall ranks, it does not judge relevance.
- The alert that matters most: `hindsight_retain_documents_total{outcome="no_facts"}` — documents
  stored but producing no memories are **invisible to recall** and nothing else reports them.
