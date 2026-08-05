# Plan: Self-host Firecrawl v2 on homelab-2nd and wire it to Open WebUI web search

**Date:** 2026-08-05  
**Author:** Andrzej (homelab builder)  
**Status:** Draft plan — pending Supreme Leader approval before execution  
**Goal:** Deploy a self-hosted Firecrawl instance inside the homelab k3s cluster so Open WebUI can use it as a web search engine, fully in-house, with no paid API key and no data leaving the LAN.

---

## 1. Why we are doing this

Open WebUI already supports web search out of the box, but until now it has only been available through third-party providers (DuckDuckGo, Brave, Tavily, Exa, Perplexity, Firecrawl cloud). The default DuckDuckGo provider works without configuration, but for a real homelab platform we want:

- **No metered SaaS bill** for a capability the box can provide itself.
- **No search queries or scraped page content sent to a third party**.
- **Search results with full page markdown** so the LLM can cite and reason over live web content.

Firecrawl is open source and exposes a `/v1/search` endpoint that combines web search with scraping. Running it locally gives Open WebUI a first-class, self-hosted web search engine.

This plan is written as a tutorial-style blog draft. Every step, decision, and gotcha is captured so a future blog post can be built from it without asking follow-up questions.

---

## 2. What the docs say (homelab docs-mcp-server + upstream)

### 2.1 Open WebUI side

From the indexed Open WebUI Firecrawl provider docs (`openwebui-firecrawl` library in the homelab docs-mcp-server):

- Firecrawl is a built-in web search engine.
- Configuration path: **Settings → Admin → Tools → Web Search**.
- Required env vars:
  - `ENABLE_WEB_SEARCH=true`
  - `WEB_SEARCH_ENGINE=firecrawl`
  - `FIRECRAWL_API_KEY=<any-value-or-self-hosted-key>`
  - `FIRECRAWL_API_BASE_URL=https://api.firecrawl.dev` (default) or `http://firecrawl.firecrawl.svc.cluster.local:3002` for self-hosted.
  - `FIRECRAWL_TIMEOUT=<ms>` (optional).
- The docs explicitly note that self-hosted Firecrawl is supported by pointing `FIRECRAWL_API_BASE_URL` at the local instance.

### 2.2 Firecrawl API side

From the indexed Firecrawl v1 search endpoint docs (`firecrawl` library in the homelab docs-mcp-server):

- `POST /v1/search`
- Request body: `{ "query": "...", "limit": 5, "scrapeOptions": { "formats": ["markdown"] } }`
- Response: `{ "success": true, "data": [ { "title", "description", "url", "markdown", "metadata" } ] }`
- Authentication: `Authorization: Bearer <token>`.
- A v2 search API is mentioned but the v1 endpoint is stable and what Open WebUI's provider targets today.

### 2.3 Firecrawl self-hosting side

From the official `SELF_HOST.md` and `docker-compose.yaml` on GitHub (also indexed in context-mode):

- Firecrawl's default self-hosting stack is Docker Compose with these services:
  - `api` — main API server + worker harness (`ghcr.io/firecrawl/firecrawl`)
  - `playwright-service` — headless browser for JS rendering (`ghcr.io/firecrawl/playwright-service:latest`)
  - `redis` — job queue / rate limit
  - `rabbitmq` — message broker used by the harness
  - `nuq-postgres` — queue backend + metadata store (`ghcr.io/firecrawl/nuq-postgres:latest`)
  - optional `foundationdb` / `foundationdb-init` (experimental queue backend, not needed for a minimal deployment)
- Default API port: `3002`.
- Required env vars:
  - `PORT=3002`, `HOST=0.0.0.0`
  - `REDIS_URL=redis://redis:6379`
  - `REDIS_RATE_LIMIT_URL=redis://redis:6379`
  - `PLAYWRIGHT_MICROSERVICE_URL=http://playwright-service:3000/scrape`
  - `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `POSTGRES_HOST`, `POSTGRES_PORT`
  - `USE_DB_AUTHENTICATION=false` (for self-hosted without Supabase)
  - `NUM_WORKERS_PER_QUEUE=8`
  - `CRAWL_CONCURRENT_REQUESTS=10`
  - `MAX_CONCURRENT_JOBS=5`
  - `BROWSER_POOL_SIZE=5`
  - `BULL_AUTH_KEY=<strong-secret>` (protects the Bull queue admin UI)
- AI features (JSON output, `/extract`) need an OpenAI-compatible key, but basic search/scrape does not.
- The `/search` API uses Google by default; can be pointed at SearXNG via `SEARXNG_ENDPOINT`.

**Important nuance:** Firecrawl's Postgres is not a generic database — it is the NUQ queue backend with a custom schema shipped in `ghcr.io/firecrawl/nuq-postgres`. This is an internal dependency of Firecrawl, not a general-purpose application database, so it is a special case relative to the "CNPG for all Postgres" guardrail. We will either (a) run their containerised `nuq-postgres` as a StatefulSet with a `local-path` PVC, or (b) investigate whether the schema can be initialised on a CNPG cluster. The plan includes a spike to decide.

---

## 3. Architecture decisions (locked in)

| Decision | Chosen approach | Alternatives rejected |
|---|---|---|
| **Where does Firecrawl run?** | New `firecrawl` namespace on `homelab-2nd` k3s. | Docker Compose on OMV (OMV is storage, not compute). |
| **Postgres backend** | Dedicated **CloudNativePG** cluster in `firecrawl` namespace. We will verify Firecrawl's NUQ queue schema can be initialised on a plain PostgreSQL 18 cluster via `postInitSQLRefs`; if that fails, document the fallback to Firecrawl's upstream `nuq-postgres` container as a queue-backend exception. | SaaS Postgres (leaves the LAN). |
| **Queue / message broker** | In-cluster Redis + RabbitMQ StatefulSets/Services. | External managed message queues (adds dependency). |
| **Durable storage for queue state** | `local-path` on `homelab-2nd` NVMe (live, rebuildable). CNPG backups if the schema init works; otherwise rebuildable queue state. | OMV NFS (queue is I/O-heavy and ephemeral). |
| **Public ingress** | **LAN-only**. Reachable at `api.firecrawl.svc.cluster.local:3002` from inside the cluster. No Cloudflare Tunnel. | Public tunnel (not needed for Hermes/Open WebUI only). |
| **Search backend** | **Google default**. `SEARXNG_ENDPOINT` left unset; SearXNG can be added later with one env var. | SearXNG now (adds another component before the base is proven). |
| **API authentication** | Single long `FIRECRAWL_API_KEY` in SOPS; shared with Open WebUI. | Supabase/DB auth (overkill). |
| **Open WebUI integration** | Add Firecrawl env vars to the existing `open-webui` HelmRelease. | Separate config patch. |

---

## 4. Pre-flight checks

Before writing any YAML, confirm the following on the live cluster:

1. `docs-mcp-server` is reachable at `http://192.168.1.179:6280/mcp` and the `firecrawl` / `openwebui-firecrawl` libraries are indexed. ✅ Done in this session.
2. `homelab-2nd` has enough headroom for Firecrawl's services:
   - `api`: 4 CPU request / 8 Gi limit per the upstream compose (we will reduce for the homelab).
   - `playwright-service`: 2 CPU / 4 Gi.
   - `nuq-postgres`, `redis`, `rabbitmq`: small.
   - Total realistic minimum: ~1.5 CPU requests, ~3–4 Gi memory. We should verify current node utilisation.
3. **OMV MinIO bucket for Firecrawl backups** — create `cnpg-backups/firecrawl/` via MinIO console or `mc mb`, then reference it in `apps/firecrawl/firecrawl-db-objectstore.yaml`.
4. **The existing Open WebUI `FIRECRAWL_API_KEY` secret placeholder** does not exist yet; we need a new SOPS secret in `apps/firecrawl/firecrawl-api-key.sops.yaml`.

---

## 5. Repository layout (GitOps)

Add a new `apps/firecrawl/` directory, following the established pattern from `apps/opengist/`, `apps/karakeep/`, `apps/llm-hub/`:

```text
apps/firecrawl/
├── namespace.yaml                          # firecrawl namespace
├── firecrawl-api-key.sops.yaml             # FIRECRAWL_API_KEY + BULL_AUTH_KEY
├── firecrawl-config-configmap.yaml         # Non-secret env: PORT, HOST, queue sizes, search config
├── redis-deployment.yaml                   # In-cluster Redis
├── redis-service.yaml
├── rabbitmq-deployment.yaml                # In-cluster RabbitMQ
├── rabbitmq-service.yaml
├── nuq-postgres-statefulset.yaml           # Firecrawl queue backend (or CNPG alternative)
├── nuq-postgres-service.yaml
├── nuq-postgres-pvc.yaml                   # local-path PVC for live queue state
├── api-deployment.yaml                     # ghcr.io/firecrawl/firecrawl
├── api-service.yaml
├── playwright-deployment.yaml              # ghcr.io/firecrawl/playwright-service:latest
├── playwright-service.yaml
├── service-monitor.yaml                    # Prometheus scraping if the image exposes /metrics
├── firecrawl-loki-rule.yaml                # Loki alert for errors
├── firecrawl-prometheus-rules.yaml         # Resource / health alerts
├── firecrawl-alertmanager-config.yaml      # Route alerts to Mattermost
├── firecrawl-dashboard-configmap.yaml      # Provisioned Grafana dashboard
└── cloudflared-firecrawl-deployment.yaml   # Optional: only if public access is wanted
```

Add the resources to the top-level `apps/kustomization.yaml` in the same order as the other services.

If we can use CNPG instead of `nuq-postgres`, replace the StatefulSet with:

```text
├── postgres-cluster.yaml
├── objectstore.yaml
├── scheduled-backup.yaml
├── firecrawl-db-credentials.sops.yaml
└── init-sql-configmap.yaml   # NUQ schema init script if required
```

---

## 6. Step-by-step execution plan

### Phase 0 — Spike: can we run NUQ on CNPG?

1. Inspect the `ghcr.io/firecrawl/nuq-postgres:latest` image entrypoint and init scripts to see if it is just Postgres with a schema file.
2. If yes, create a CNPG `Cluster` in the `firecrawl` namespace and mount the NUQ schema as a `postInitSQLRefs` ConfigMap.
3. Deploy only the Firecrawl `api` + `redis` + `rabbitmq` + CNPG Postgres and test `/v1/search`.
4. If the API fails because the queue backend expects a specific Postgres extension/table not present in CNPG, **document the failure and fall back** to the `nuq-postgres` StatefulSet.

**Deliverable:** A note in the tracking file explaining the CNPG attempt and the chosen path.

### Phase 1 — Create the namespace and secrets

1. Create `apps/firecrawl/namespace.yaml` with labels `app.kubernetes.io/name: firecrawl`, `app.kubernetes.io/part-of: homelab-2nd`.
2. Create `apps/firecrawl/firecrawl-api-key.sops.yaml` with:
   - `FIRECRAWL_API_KEY`: a long random token (used by both Firecrawl and Open WebUI).
   - `BULL_AUTH_KEY`: a strong admin secret for the Bull queue UI.
3. Encrypt with `sops --encrypt` using the repo's `.sops.yaml` age public key.

### Phase 2 — Deploy internal dependencies

1. **Redis** — single-replica Deployment + Service on `redis.firecrawl.svc.cluster.local:6379`. Use an emptyDir or small `local-path` PVC for queue resilience across pod restarts. Resource requests: 50m CPU, 64Mi memory; limits: 200m, 256Mi.
2. **RabbitMQ** — single-replica Deployment + Service on `rabbitmq.firecrawl.svc.cluster.local:5672`. Management UI on `15672` optional. Use a `local-path` PVC for durable queues. Resource requests: 100m CPU, 256Mi memory; limits: 500m, 512Mi.
3. **NUQ Postgres** — if CNPG spike fails, deploy a StatefulSet using `ghcr.io/firecrawl/nuq-postgres:latest`, a `local-path` PVC, and a Service. Resource requests: 100m CPU, 256Mi memory; limits: 500m, 512Mi. (This is queue metadata, not precious user data.)

### Phase 3 — Deploy Firecrawl workers

1. **API / worker Deployment**:
   - Image: `ghcr.io/firecrawl/firecrawl:latest` (pin a specific digest in the final file, e.g. `ghcr.io/firecrawl/firecrawl:v1.x.y`).
   - Command: `node dist/src/harness.js --start-docker` (same as upstream compose).
   - Env from `firecrawl-config-configmap.yaml` and `firecrawl-api-key.sops.yaml`.
   - Service: `api.firecrawl.svc.cluster.local:3002`.
   - Resource requests: 500m CPU, 1Gi memory; limits: 2000m, 4Gi (tunable once we see real load).
2. **Playwright Deployment**:
   - Image: `ghcr.io/firecrawl/playwright-service:latest`.
   - Env: `PORT=3000`, `MAX_CONCURRENT_PAGES=10`.
   - Service: `playwright-service.firecrawl.svc.cluster.local:3000`.
   - Resource requests: 500m CPU, 1Gi memory; limits: 2000m, 4Gi.
3. **Liveness / readiness probes** on the API HTTP port and Playwright port.

### Phase 4 — Wire Open WebUI to self-hosted Firecrawl

1. Edit `apps/llm-hub/openwebui-helm-release.yaml` and add to `extraEnvVars`:
   ```yaml
   - name: ENABLE_WEB_SEARCH
     value: "true"
   - name: WEB_SEARCH_ENGINE
     value: "firecrawl"
   - name: FIRECRAWL_API_BASE_URL
     value: "http://api.firecrawl.svc.cluster.local:3002"
   - name: FIRECRAWL_API_KEY
     valueFrom:
       secretKeyRef:
         name: firecrawl-api-key
         key: api-key
   - name: FIRECRAWL_TIMEOUT
     value: "60000"
   ```
2. Commit and let Flux reconcile.
3. Verify in Open WebUI: **Settings → Admin → Tools → Web Search** shows Firecrawl selected and the base URL reachable.

### Phase 5 — Observability (non-negotiable per guardrail #9)

1. **Logs:** Firecrawl containers log to stdout. The OTel Collector DaemonSet already picks up container logs and ships them to Loki. Add a Loki parsing rule if the log format is JSON.
2. **Metrics:**
   - Check if `ghcr.io/firecrawl/firecrawl` exposes a `/metrics` endpoint. If yes, create a `ServiceMonitor` (`service-monitor.yaml`).
   - If not, add a Prometheus scraping annotation to the Service.
3. **Traces:** Firecrawl does not natively emit OpenTelemetry traces. Skip unless upstream adds support.
4. **Alerts:**
   - `firecrawl-prometheus-rules.yaml`: alert if API or Playwright pod is down, CPU > 80%, memory > 90%.
   - `firecrawl-loki-rule.yaml`: alert on `level=error` or `FATAL` logs.
   - `firecrawl-alertmanager-config.yaml`: route to the existing Mattermost webhook.
5. **Dashboard:**
   - `firecrawl-dashboard-configmap.yaml`: provisioned Grafana dashboard in the `firecrawl` folder showing pod health, queue depth (if Bull exposes metrics), search latency, resource usage.

### Phase 6 — Public access (optional)

1. If the Supreme Leader wants external access to the Firecrawl API (e.g. for other tools), add:
   - `apps/firecrawl/firecrawl-tunnel-token.sops.yaml`
   - `apps/firecrawl/cloudflared-firecrawl-deployment.yaml`
   - A Cloudflare Tunnel hostname rule in Zero Trust: `firecrawl.voitech.dev` → `http://api.firecrawl.svc.cluster.local:3002`.
2. Keep authentication enforced via `FIRECRAWL_API_KEY`; do not expose the Bull admin UI publicly.

### Phase 7 — Documentation and verification

1. **ADR:** Write `docs/adr/adr-010-firecrawl-v2-selfhost-openwebui-websearch.md` covering:
   - Context (why we want self-hosted web search).
   - Decision (deploy Firecrawl in k3s, use self-hosted endpoint, wire to Open WebUI).
   - Consequences (resource usage, no SaaS bill, no data leaves LAN, NUQ Postgres exception if applicable).
   - Alternatives (hosted Firecrawl API key, SearXNG, DuckDuckGo).
   - When to revisit (v2 API path changes, resource pressure, move to SearXNG).
2. **Tracking note:** Keep `homelab/tracking/2026-08-05-firecrawl-v2-selfhost-plan.md` updated as a living plan; create the deployment tracking note `2026-08-0X-firecrawl-v2-selfhost-deployment.md` during execution.
3. **Verify end-to-end:**
   - `curl -X POST http://api.firecrawl.svc.cluster.local:3002/v1/search -H 'Authorization: Bearer <key>' -d '{"query":"firecrawl self hosting","limit":3,"scrapeOptions":{"formats":["markdown"]}}'` returns JSON results.
   - In Open WebUI, start a new chat, enable web search, ask "What is Firecrawl?", and confirm the model receives scraped markdown.
   - Check Grafana dashboard shows Firecrawl pods and Loki has recent logs.

---

## 7. Resource budget estimate

Based on the upstream Docker Compose and homelab downsizing:

| Component | Request CPU | Limit CPU | Request RAM | Limit RAM | Notes |
|---|---|---|---|---|---|
| Firecrawl API | 500m | 2000m | 1Gi | 4Gi | Worker + API in one pod |
| Playwright | 500m | 2000m | 1Gi | 4Gi | Headless Chromium pool |
| Redis | 50m | 200m | 64Mi | 256Mi | Queue + rate limit |
| RabbitMQ | 100m | 500m | 256Mi | 512Mi | Harness broker |
| NUQ Postgres / CNPG | 100m | 500m | 256Mi | 512Mi | Queue metadata |
| **Total** | **~1.25 CPU** | **~5.2 CPU** | **~2.6 Gi** | **~9.3 Gi** | Actual peak depends on concurrency |

The Supreme Leader must confirm this fits on the single `homelab-2nd` node alongside LiteLLM, Mattermost, Open WebUI, Authentik, CNPG clusters, Ollama embeddings, etc. If the node is already saturated, we reduce `NUM_WORKERS_PER_QUEUE`, `MAX_CONCURRENT_JOBS`, and `BROWSER_POOL_SIZE` before deploying.

---

## 8. Secrets and security

- `FIRECRAWL_API_KEY` and `BULL_AUTH_KEY` live only in SOPS-encrypted `firecrawl-api-key.sops.yaml`.
- The age private key stays in the Supreme Leader's password manager; the public key is in `.sops.yaml`.
- No plaintext tokens in Helm values, ConfigMaps, or tracking notes.
- Bull admin UI path (`/admin/<BULL_AUTH_KEY>/queues`) is reachable only inside the cluster unless explicitly exposed.
- No public ingress unless Phase 6 is approved.

---

## 9. Risks and mitigations

| Risk | Mitigation |
|---|---|
| NUQ Postgres does not run on CNPG | Spike in Phase 0; fallback to upstream `nuq-postgres` StatefulSet. |
| Node runs out of CPU/RAM | Start with low concurrency settings; tune up after observing load. |
| Firecrawl search returns no results | Verify outbound internet from `api` pod; check `SEARXNG_ENDPOINT` if using SearXNG; check Google rate limits. |
| Open WebUI does not call search | Confirm `ENABLE_WEB_SEARCH` and `WEB_SEARCH_ENGINE=firecrawl` in pod env; test with the `+` toggle in chat. |
| Playwright crashes under load | Lower `MAX_CONCURRENT_PAGES`; increase memory limit. |
| Container images are large / take long to pull | Pin digest; pre-pull during a maintenance window if needed. |
| v2 API path differs from v1 | Open WebUI provider uses the base URL; verify the actual path with `curl` before changing config. |

---

## 10. Open questions (all answered)

| Question | Decision |
|---|---|
| CNPG or upstream `nuq-postgres`? | **CNPG first**, with documented fallback if NUQ schema init fails. |
| Public Firecrawl API? | **No** — LAN-only, internal cluster use only. |
| Search backend? | **Google default**; SearXNG can be added later. |

If any of these assumptions change during deployment, the ADR and tracking note will be updated.

---

## 11. Files to create / modify

### New files

- `apps/firecrawl/namespace.yaml`
- `apps/firecrawl/firecrawl-api-key.sops.yaml`
- `apps/firecrawl/firecrawl-config-configmap.yaml`
- `apps/firecrawl/redis-deployment.yaml`
- `apps/firecrawl/redis-service.yaml`
- `apps/firecrawl/rabbitmq-deployment.yaml`
- `apps/firecrawl/rabbitmq-service.yaml`
- `apps/firecrawl/nuq-postgres-pvc.yaml` (or CNPG files)
- `apps/firecrawl/nuq-postgres-statefulset.yaml`
- `apps/firecrawl/nuq-postgres-service.yaml`
- `apps/firecrawl/api-deployment.yaml`
- `apps/firecrawl/api-service.yaml`
- `apps/firecrawl/playwright-deployment.yaml`
- `apps/firecrawl/playwright-service.yaml`
- `apps/firecrawl/service-monitor.yaml`
- `apps/firecrawl/firecrawl-loki-rule.yaml`
- `apps/firecrawl/firecrawl-prometheus-rules.yaml`
- `apps/firecrawl/firecrawl-alertmanager-config.yaml`
- `apps/firecrawl/firecrawl-dashboard-configmap.yaml`
- `docs/adr/adr-010-firecrawl-v2-selfhost-openwebui-websearch.md`
- `homelab/tracking/2026-08-05-firecrawl-v2-selfhost-plan.md`

### Modified files

- `apps/kustomization.yaml` — add the new firecrawl resources.
- `apps/llm-hub/openwebui-helm-release.yaml` — add Firecrawl env vars.
- `docs/adr/README.md` — add ADR-010 to the index.

---

## 12. Success criteria

- [ ] `api.firecrawl.svc.cluster.local:3002/v1/search` responds with results when called from inside the cluster.
- [ ] Open WebUI `FIRECRAWL_API_BASE_URL` points at the internal service and a chat with web search enabled returns live web results.
- [ ] All Firecrawl pods are `Ready` and have reasonable resource usage.
- [ ] Grafana shows the Firecrawl dashboard; Loki shows Firecrawl logs.
- [ ] No plaintext secrets are committed; all credentials are SOPS-encrypted.
- [ ] ADR and tracking notes are complete enough for a blog post.

---

## 13. References

- Open WebUI Firecrawl provider docs (indexed in homelab docs-mcp-server, `openwebui-firecrawl` library)
- Firecrawl `/v1/search` API docs (indexed in homelab docs-mcp-server, `firecrawl` library)
- Firecrawl `SELF_HOST.md`: https://github.com/firecrawl/firecrawl/blob/main/SELF_HOST.md
- Firecrawl `docker-compose.yaml`: https://github.com/firecrawl/firecrawl/blob/main/docker-compose.yaml
- Existing Open WebUI HelmRelease: `apps/llm-hub/openwebui-helm-release.yaml`
- Homelab ADR template: `docs/adr/adr-001-prometheus-storage-local-path.md`
