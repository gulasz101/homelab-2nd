---
date: 2026-08-05
title: Firecrawl v2 self-hosted deployment on homelab-2nd
status: completed
namespace: firecrawl
related_adr: docs/adr/adr-010-firecrawl-v2-selfhost-openwebui-websearch.md
---

# Firecrawl v2 self-hosted deployment

## Goal

Stand up a self-hosted [Firecrawl v2](https://github.com/firecrawl/firecrawl) instance inside the homelab-2nd k3s cluster and wire Open WebUI's web-search feature to it, all delivered via Flux GitOps. Keep it LAN-only — no public ingress.

## Locked-in decisions

- **Postgres queue backend**: Try CloudNativePG first; fall back to the upstream `ghcr.io/firecrawl/nuq-postgres` container only if the NUQ schema init fails on plain PostgreSQL.
- **LAN-only**: internal endpoint `http://api.firecrawl.svc.cluster.local:3002`; no Cloudflare Tunnel.
- **Search backend**: DuckDuckGo (`SEARXNG_ENDPOINT` unset).

## Files delivered

| Path | What |
|------|------|
| `apps/firecrawl/namespace.yaml` | `firecrawl` namespace |
| `apps/firecrawl/firecrawl-api-key.sops.yaml` | `FIRECRAWL_API_KEY`, `BULL_AUTH_KEY`, `RABBITMQ_PASSWORD`, `NUQ_RABBITMQ_URL` |
| `apps/firecrawl/firecrawl-db-credentials.sops.yaml` | Postgres credentials for the queue DB |
| `apps/firecrawl/firecrawl-mattermost-webhook-url.sops.yaml` | Alert webhook (reused from homelab-node) |
| `apps/firecrawl/firecrawl-config-configmap.yaml` | Non-secret Firecrawl env (Redis, RabbitMQ, Postgres host/db) |
| `apps/firecrawl/nuq-postgres-statefulset.yaml` | Upstream NUQ Postgres StatefulSet |
| `apps/firecrawl/nuq-postgres-service.yaml` | `nuq-postgres.firecrawl.svc.cluster.local` |
| `apps/firecrawl/redis-*.yaml` | Redis queue/cache |
| `apps/firecrawl/rabbitmq-*.yaml` | RabbitMQ queue |
| `apps/firecrawl/api-deployment.yaml` / `api-service.yaml` | Firecrawl API + worker harness |
| `apps/firecrawl/playwright-deployment.yaml` / `playwright-service.yaml` | Headless browser service |
| `apps/firecrawl/service-monitor.yaml` | Prometheus scraping |
| `apps/firecrawl/firecrawl-prometheus-rules.yaml` | Resource + availability alerts |
| `apps/firecrawl/firecrawl-alertmanager-config.yaml` | Mattermost routing |
| `apps/firecrawl/firecrawl-loki-rule.yaml` | Error-log alert |
| `apps/firecrawl/firecrawl-dashboard-configmap.yaml` | Grafana dashboard (in `observability` namespace) |
| `apps/llm-hub/openwebui-firecrawl-api-key.sops.yaml` | Copy of `FIRECRAWL_API_KEY` for Open WebUI |
| `apps/llm-hub/openwebui-helm-release.yaml` | Firecrawl env vars + in-place rolling-update strategy |
| `apps/kustomization.yaml` | Includes all new resources |

## Step-by-step

### 1. Read the plan and ADR

Read `homelab/tracking/2026-08-05-firecrawl-v2-selfhost-plan.md` and `docs/adr/adr-010-firecrawl-v2-selfhost-openwebui-websearch.md` before touching anything.

### 2. Check node headroom

`homelab-2nd` has 8 CPU / ~31.2 Gi RAM. At start of work, requests were already at **7980m / 8000m CPU** (~99%) even though real usage was only ~28%. This is the classic single-node k3s scheduling trap: requests, not actual load, decide if pods fit.

### 3. Trimmed over-requested workloads to make room

With approval, reduced CPU requests on workloads that were using far less than requested:

| Workload | Before | After |
|----------|--------|-------|
| `docs-mcp-server` | 500m | 100m |
| `honcho-api` | 250m | 100m |
| `honcho-deriver` | 250m | 100m |
| `nextcloud` app | 250m | 100m |
| Firecrawl API | 500m | 250m |
| Firecrawl Playwright | 500m | 250m |
| Firecrawl Redis | 50m | 25m |
| Firecrawl RabbitMQ | 100m | 50m |
| Firecrawl CNPG | 100m | 50m |

LiteLLM and Mattermost were left untouched per standing rule.

### 4. Tried CNPG first — it failed

Created a standard CloudNativePG PostgreSQL 18 cluster (`firecrawl-db-rw`) and a `cnpg-backups/firecrawl` bucket on OMV MinIO. The Firecrawl API pod crashed immediately:

```
error: relation "nuq.queue_crawl_finished" does not exist
```

The upstream `ghcr.io/firecrawl/nuq-postgres` image is **not** plain Postgres. It ships `pg_cron`, `pgcrypto`, and the `nuq.sql` schema in `/docker-entrypoint-initdb.d/010-nuq.sql`. CNPG's minimal PostgreSQL 18 image lacks those extensions, so the schema init never runs. **Documented fallback to the upstream container per the plan.**

Deleted the CNPG cluster, ObjectStore, scheduled backup, and cleaned up the unused MinIO bucket.

### 5. Deployed upstream `nuq-postgres` StatefulSet

Wrote a small StatefulSet + Service using `ghcr.io/firecrawl/nuq-postgres:latest`, a `local-path` PVC, and the existing `firecrawl-db-credentials` secret. Set `POSTGRES_DB=postgres` because `pg_cron` must be created in the `postgres` database.

First start still failed because the previous RabbitMQ pod had a stale password. Root cause: the RabbitMQ user/password are set once at first data-dir init; changing the secret later does not update the existing RabbitMQ internal user database. Wiped the RabbitMQ PVC and pod, let it re-initialize with the current secret, and the API finally came up Ready.

### 6. Open WebUI wiring gotchas

- **Namespace-scoped secret**: Open WebUI runs in `llm-hub` and cannot read `firecrawl-api-key` from `firecrawl`. Added a SOPS-encrypted copy `apps/llm-hub/openwebui-firecrawl-api-key.sops.yaml` containing only `FIRECRAWL_API_KEY`.
- **HelmRelease upgrade timed out**: single-node + `maxSurge: 25%` tried to schedule a second Open WebUI pod with no CPU room. Flux rolled back. Fixed by setting Open WebUI Deployment strategy to `maxSurge: 0` / `maxUnavailable: 1` so it replaces in-place.
- **Secret name mismatch**: first copy was accidentally named `firecrawl-api-key` in `llm-hub`, but the HelmRelease referenced `openwebui-firecrawl-api-key`. Renamed.
- **API key rotation**: during debugging the Open WebUI env dump exposed `FIRECRAWL_API_KEY` in tool output. Rotated the key in both `firecrawl-api-key` and `openwebui-firecrawl-api-key` SOPS secrets, plus `BULL_AUTH_KEY` and `RABBITMQ_PASSWORD`.

### 7. Verified end-to-end

Firecrawl API `/v1/search` from inside the cluster returned live results:

```bash
kubectl exec -n firecrawl <api-pod> -- node -e "fetch('http://localhost:3002/v1/search', ...)"
```

Response:
```json
{"success":true,"data":[{"url":"https://github.com/firecrawl/firecrawl/blob/main/SELF_HOST.md",...}]}
```

Open WebUI pod has the correct env:
- `ENABLE_WEB_SEARCH=true`
- `WEB_SEARCH_ENGINE=firecrawl`
- `FIRECRAWL_API_BASE_URL=http://api.firecrawl.svc.cluster.local:3002`
- `FIRECRAWL_API_KEY=<rotated>`

Connectivity from the Open WebUI pod to Firecrawl works:
```bash
kubectl exec -n llm-hub <open-webui-pod> -c open-webui -- curl ... http://api.firecrawl.svc.cluster.local:3002/v1/search
```

Observability wiring is in place:
- ServiceMonitor `firecrawl-api`
- PrometheusRule `firecrawl-resource-alerts`
- AlertmanagerConfig `firecrawl-mattermost-alerts`
- Grafana dashboard ConfigMap `firecrawl-dashboard` in `observability`

I did not log into the Open WebUI web UI to click through Settings > Web Search because I don't have a browser session, but the documented env vars are exactly what Open WebUI uses to expose Firecrawl as the engine. The Supreme Leader can flip the toggle in `https://ai-chat.voitech.dev` → Admin Settings → Web Search → enable + select `firecrawl`.

## Commits

- `feat(firecrawl): deploy Firecrawl v2 self-hosted in firecrawl namespace`
- `feat(openwebui): wire web search to self-hosted Firecrawl`
- `fix(firecrawl): reduce CPU requests to fit single-node headroom`
- `fix(firecrawl): fallback to upstream nuq-postgres StatefulSet`
- `fix(firecrawl): use postgres database for NUQ backend`
- `fix(openwebui): in-place rolling update for single-node CPU headroom`
- `fix(openwebui): add Firecrawl API key secret in llm-hub namespace`
- `fix(openwebui): name Firecrawl API key secret correctly`
- `security(firecrawl): rotate API key after accidental env dump`

## Lessons

1. **Requests, not real CPU, block scheduling on a single-node cluster.** The box was 28% busy but 99% requested.
2. **Never assume a custom Postgres image is "just Postgres".** Inspect the Dockerfile and entrypoint; `nuq-postgres` carries schema init and extensions.
3. **Changing a secret does not change RabbitMQ's internal user DB.** Wipe the PVC or use explicit user management if the password changes.
4. **Cross-namespace secret references don't work for Helm values.** Put a namespace-local SOPS copy.
5. **Rolling updates on single-node clusters need `maxSurge: 0`.** Otherwise Helm/Flux times out and rolls back.

## Current status

- Firecrawl namespace: all pods Ready.
- Open WebUI: reconciled, Firecrawl env vars present, pod Ready.
- Public UI toggle remains a manual step in Open WebUI admin settings.
- Grafana dashboard ConfigMap provisioned; dashboard should appear after the next Grafana sidecar scrape.
