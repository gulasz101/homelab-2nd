# ADR-084: FreeLLMAPI as the homelab's free-tier LLM aggregator

- **Status**: Accepted
- **Date**: 2026-10-24
- **Issue**: GUL-123

## Context

Free inference ran out on 2026-10-24. `beam-free-go` answered 429 for every call
(ADR-083), Hindsight moved to `free-openrouter`, and the Hermes agents had no
working model at all. Each provider's free tier is small, but there are dozens of
them (Groq, Cerebras, Google AI Studio, Mistral, Cohere, NVIDIA, Cloudflare,
GitHub Models, ...). Using them one at a time in LiteLLM means a route, a key and
a rate-limit fallback chain per provider, and the free catalogue changes every week.

[FreeLLMAPI](https://github.com/tashfeenahmed/freellmapi) (MIT, v0.16.9) does that
aggregation. It gives one OpenAI-, Anthropic- and Gemini-compatible `/v1`, tracks
RPM/RPD/TPM per key, fails over on 429/5xx, and syncs its model catalogue from a
signed feed (the free tier gets the monthly snapshot).

## Decision

Run FreeLLMAPI in the `freellmapi` namespace on homelab-2nd:

- **Delivery**: raw manifests in `apps/freellmapi/` through Flux. Upstream ships
  only an image and a compose file, no Helm chart (guardrail 2). The image is
  pinned to `ghcr.io/tashfeenahmed/freellmapi:v0.16.9`, because upstream cuts
  several releases a week.
- **State**: the app keeps everything in one SQLite file: the account, the
  provider keys (AES-256-GCM with `ENCRYPTION_KEY`), the fallback chain and the
  analytics. The file sits on a 2 Gi `local-path` PVC. There is no Postgres, so
  CNPG does not apply.
- **Durability**: the built-in `FREEAPI_DB_BACKUP_PATH` snapshot. Every 5 minutes
  it runs a WAL checkpoint and writes a gzipped, encrypted copy next to the DB.
  The `freellmapi-backup` CronJob (04:15 daily) uploads that file to
  `s3://freellmapi-backups/freellmapi/` on OMV MinIO and keeps 30 days. It is
  ciphertext, so MinIO never holds a plaintext key store. The bucket has its own
  user and a bucket-scoped policy.
- **Secrets**: `ENCRYPTION_KEY` and `FREEAPI_CONFIG_JSON` (declarative config:
  admin account, provider keys, routing strategy) are in SOPS. The `admin` entry
  is applied before the listener starts, so the unauthenticated first-run setup
  window never opens.
- **Exposure**: LAN/NetBird only, NodePort `192.168.1.179:30301`, plus ClusterIP
  `freellmapi.freellmapi.svc:3001` for in-cluster clients. **No Cloudflare
  Tunnel.** Upstream says it is single-user and must not face the internet; the
  dashboard login and one unified bearer key are its only guards. When something
  public needs it, it goes through LiteLLM's virtual keys as an upstream.
- **Observability**: honest partial. Upstream has no `/metrics`, so the alerts use
  kube-state metrics (availability, restarts, memory, PVC, backup freshness).
  A Loki rule catches fatal/SQLite errors and failures of the in-app backup pump.
  There is also a provisioned namespace dashboard.

## Consequences

**Positive**

- One endpoint pools many free tiers. Adding capacity means adding a key, not
  writing LiteLLM routes.
- Restore is simple: copy the MinIO object to `/app/server/data/freellmapi.db.backup`
  on an empty PVC, start the pod, and the app restores before migrations.
- The NodePort is reachable from the Mac-side Hermes and Paperclip agents with
  no new tunnel.

**Negative**

- Provider keys that are added in the dashboard live only in SQLite and its
  backup, not in Git. Keys in `FREEAPI_CONFIG_JSON` are the GitOps path. Prefer it.
- The backup without `ENCRYPTION_KEY` is useless. Losing the SOPS secret loses
  the backups too.
- Free providers may log or train on prompts. This is the same trade-off ADR-083
  accepted.
- The app calls freellmapi.co twice a day for its catalogue. That is a
  third-party dependency, but a soft one: routing keeps working on the last
  catalogue.
- No app-level metrics in Prometheus. Upstream 429 rates are visible only in the
  dashboard's analytics.

## Alternatives considered

- **More LiteLLM routes per free provider.** Rejected. Every provider needs a
  hand-written route, a key and a fallback order, and nobody tracks the free
  catalogue. LiteLLM stays the gateway; FreeLLMAPI becomes one upstream behind it.
- **Public `freellm.voitech.dev` tunnel.** Rejected for now. A single-user app with
  one shared key should not be on the internet. LiteLLM already is, with per-agent
  virtual keys.
- **Tar the live SQLite file from the CronJob (fitness pattern).** Rejected. A
  copy of a live WAL database can be torn. The app's own snapshot is checkpointed
  first, and the job ships it only after two reads hash the same.
- **NFS on OMV for the DB.** Rejected. Guardrail 4 keeps live databases on local
  NVMe, and SQLite on NFS is a known way to corrupt it.

## When to revisit

- Upstream ships a `/metrics` endpoint: add a ServiceMonitor.
- Upstream ships multi-user auth or an SSO/OIDC front door: reconsider a public tunnel.
- The free tier's monthly catalogue lag starts to hurt: decide on the $19/yr
  Premium live feed. It is a `license` field in the same SOPS config.
- Agents depend on it for critical work: add the in-cluster route to LiteLLM with
  a paid fallback.
