# ADR-010: Self-host Firecrawl v2 and wire it to Open WebUI web search

Date: 2026-08-05
Status: Proposed
Supersedes: nothing
Superseded by: nothing

## Context

Open WebUI already has a built-in web search feature, but every supported provider except DuckDuckGo and SearXNG is a paid SaaS or sends queries off-site. DuckDuckGo is free and local in the sense that no API key is needed, but it cannot return full-page markdown for RAG-style reasoning. The goal is to give the homelab a self-hosted web search engine with full content scraping.

**Firecrawl** (https://firecrawl.dev, open source) provides a `/v1/search` endpoint that combines web search with per-result scraping (markdown, HTML, links, metadata). Open WebUI has a native Firecrawl provider that supports a custom `FIRECRAWL_API_BASE_URL`, which means we can point it at an in-cluster Firecrawl instance instead of the cloud API.

This ADR records the decision to run Firecrawl inside k3s on `homelab-2nd` and consume it from Open WebUI for web search.

## Decision

1. **Deploy Firecrawl in a new `firecrawl` namespace on `homelab-2nd`.**
   - Services: API/worker (`ghcr.io/firecrawl/firecrawl`), Playwright scraper (`ghcr.io/firecrawl/playwright-service`), Redis, RabbitMQ, and NUQ Postgres.
   - The API listens on port `3002` at `api.firecrawl.svc.cluster.local`.
2. **Use self-hosted authentication.**
   - `USE_DB_AUTHENTICATION=false` (no Supabase dependency).
   - A single SOPS-encrypted `FIRECRAWL_API_KEY` shared between Firecrawl and Open WebUI.
   - `BULL_AUTH_KEY` also SOPS-encrypted and strong, protecting the Bull queue admin UI.
3. **Queue backend decision is conditional.**
   - First, attempt to initialise Firecrawl's NUQ queue schema on a CloudNativePG cluster (consistent with the "CNPG for all Postgres" guardrail).
   - If the schema/behaviour is incompatible, fall back to Firecrawl's upstream `ghcr.io/firecrawl/nuq-postgres` container running as a k3s StatefulSet with a `local-path` PVC. This is an explicit, documented exception because NUQ Postgres is a Firecrawl-internal queue store, not a general application database.
4. **Wire Open WebUI to the internal Firecrawl service.**
   - Add `ENABLE_WEB_SEARCH=true`, `WEB_SEARCH_ENGINE=firecrawl`, `FIRECRAWL_API_BASE_URL=http://api.firecrawl.svc.cluster.local:3002`, and `FIRECRAWL_API_KEY` to the existing `open-webui` HelmRelease.
5. **No public ingress by default.**
   - Open WebUI reaches Firecrawl over the cluster network. A Cloudflare Tunnel for `firecrawl.voitech.dev` may be added later if external tools need API access, but it is not part of the initial deployment.
6. **Observability from day one.**
   - Container logs → OTel Collector → Loki.
   - Prometheus scraping via `ServiceMonitor` if the image exposes metrics; otherwise via annotations.
   - Per-namespace Grafana dashboard in the `firecrawl` folder.
   - Prometheus rules and a Loki rule for health/error alerting, routed to the existing Mattermost webhook.

## Consequences

### Positive

- Web search in Open WebUI becomes a fully self-hosted, zero-SaaS capability.
- Search results include full-page markdown, enabling better citation and reasoning in chats.
- No search queries or scraped content leave the homelab.
- Aligns with the existing GitOps/SOPS/CNPG/Cloudflare Tunnel patterns.
- Adds another concrete example of "self-hosted AI tooling" for the blog.

### Negative / Risks

- Firecrawl is resource-hungry: the upstream defaults assume 4 CPU / 8 Gi for the API alone. We will downsize for the homelab, but this may limit concurrency.
- Running a full Chromium pool via Playwright consumes significant memory and can be unstable under load.
- Firecrawl's default `/search` uses Google; if Google blocks or rate-limits the homelab IP, search stops. A future SearXNG backend can mitigate this.
- The NUQ Postgres backend is a special case. If CNPG fails, we accept a non-CNPG Postgres StatefulSet for queue metadata only.
- Adds another moving part to the already busy `homelab-2nd` node. Resource contention with LiteLLM, Ollama embeddings, and Authentik is a real risk.

## Alternatives considered

| Option | Why rejected |
|---|---|
| Hosted Firecrawl API key | Sends search queries and page content to a third party; adds a SaaS bill; contradicts the self-hosted motivation. |
| DuckDuckGo provider in Open WebUI | Free, but cannot return scraped markdown; limited for RAG-style use. |
| SearXNG as the web search backend | SearXNG is a great self-hosted search *aggregator*, but it does not scrape pages. It could be layered *under* Firecrawl later via `SEARXNG_ENDPOINT`, but not as a replacement for the full search+scrape capability. |
| Run Firecrawl Docker Compose on OMV | OMV is the durable storage layer, not compute. The architecture says workloads run on `homelab-2nd`. |
| Use a standalone Postgres StatefulSet for application data | Rejected in favour of CNPG where possible; only NUQ's internal queue store may need the upstream container. |

## When to revisit

Revisit this ADR if:

- Firecrawl releases a v2 API path that Open WebUI's provider uses by default and the base-URL approach breaks.
- The `homelab-2nd` node cannot sustain Firecrawl's resource usage even after tuning.
- Google search becomes unreliable and we switch Firecrawl's `/search` backend to SearXNG.
- Open WebUI adds native SearXNG or another self-hosted provider that removes the need for Firecrawl.
- Firecrawl's NUQ schema becomes compatible with a vanilla CNPG cluster, allowing us to eliminate the `nuq-postgres` StatefulSet exception.

## References

- `homelab/tracking/2026-08-05-firecrawl-v2-selfhost-plan.md`
- `apps/llm-hub/openwebui-helm-release.yaml`
- Firecrawl docs indexed in the homelab docs-mcp-server (`firecrawl` library)
- Open WebUI Firecrawl provider docs indexed in the homelab docs-mcp-server (`openwebui-firecrawl` library)
- Firecrawl upstream: https://github.com/firecrawl/firecrawl/blob/main/SELF_HOST.md
- Firecrawl upstream compose: https://github.com/firecrawl/firecrawl/blob/main/docker-compose.yaml
