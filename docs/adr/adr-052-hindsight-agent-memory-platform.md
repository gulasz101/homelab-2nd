# ADR-052: Hindsight is the agent-memory platform — CNPG + pgvector, LiteLLM LLM, CPU TEI, tunnel + SSO, OpenViking retained as an MCP endpoint

## Status

Accepted — 2026-10-13. **Epic:** H2-232 (*Replace Honcho + OpenViking with self-hosted Hindsight:
deploy → migrate → retire*). **Tracking note:** `homelab/tracking/2026-10-12-hindsight-deployment-planning.md`
(vault).

Written at the end of stage 1, so be precise about what is proven and what is not:

- **Landed and reconciled by Flux:** the `hindsight` namespace, the SOPS credential bundle, the CNPG
  cluster `hindsight-db` with pgvector and S3 backups, the OCI `HelmRelease` for chart 0.10.3, the
  LAN/Netbird NodePort Services, and the observability objects (ServiceMonitor from the chart, the
  three upstream dashboards, 19 alerts, Alertmanager routing, Tempo traces, Loki logs) — H2-234
  through H2-242.
- **Still ahead:** the pilot on the `andrzej` profile (H2-243), the migration of both stores
  (H2-245, H2-246), the roll-over of the remaining profiles after the soak (H2-247) and Honcho's
  retirement (H2-249). Nothing in this ADR is a claim that a memory has already been recalled out of
  Hindsight in anger.

Numbering, because it moved: this epic first booked **ADR-050** while `docs/adr/` ended at 046; by the
time stage 1 was committed, 047–051 had been taken by unrelated work. The recorded number is
**052**, and the index in `docs/adr/README.md` carries a note saying so.

## Context

**Before.** Agent memory in this homelab lived in two bespoke stores, each wired to Hermes by hand:

- **Honcho** — `honcho-api`, `honcho-deriver`, `honcho-redis` and its own CNPG cluster, exposed on
  NodePort 30800, serving the `default` and `florian` profiles. Memory is organised as
  workspaces → peers → sessions → conclusions.
- **OpenViking** — a single container with a 20 Gi `local-path` PVC and an hourly `.ovpack` export to
  OMV MinIO, exposed on NodePort 30193, serving the `andrzej`, `careerpa` and `szarik` profiles
  *and* the OpenChamber agent — the last one living in a different OpenViking account, which is the
  account boundary that already caused one migration-shaped problem earlier in the project. It also
  doubles as a store for technical-project material (files, skills, vectors), which the profiles use
  as an injection source.

Both work. Neither is a *platform*, and the costs compound:

1. **Memory is keyed by profile, not by agent.** It lives in the store that happens to be configured
   for that Hermes profile, so it does not travel with the work, and the OpenChamber agent's memory
   ended up in a third place.
2. **No entity resolution, no consolidated observations, no mental models.** Both stores are
   "write text, search text". Anything resembling a durable understanding of a person or project has
   to be re-derived on every recall.
3. **Two of everything.** Two backup stories, two exposure stories, two credential sets, two upgrade
   cycles, two things to keep observable.
4. **Neither is a first-class Hermes memory provider.** Both integrations are home-grown, so every
   Hermes or store change is our problem.

Hindsight replaces that with one Postgres-backed platform that does extraction, entity resolution,
consolidated observations, mental models and knowledge pages, and is consumed two ways: as a native
Hermes memory provider and as a built-in MCP server.

**Constraints this decision had to respect** (they shape every choice below):

- Guardrails: Flux + HelmRelease only; CloudNativePG for every Postgres instance; SOPS/age secrets in
  a public repo; OMV is the only durable store; no service is "live" before it is observable.
- **Hermes runs on the M1 Max, outside the cluster.** "Cluster-internal only" is not physically
  available to a plugin that has to reach the API.
- **One k3s node, and its CPU *requests* are already ~78% committed** (memory ~49%). On this cluster
  the scarce resource is the request, not the RAM.
- homelab-2nd's NVMe is fast and explicitly **not** durable — the node is rebuildable from Git plus
  backups.

## Decision

Hindsight runs in k3s on homelab-2nd, from the upstream chart, configured as follows. The
machine-readable copy of this table lives in `apps/hindsight/README.md`.

### 1. Hindsight is the agent-memory platform

One store for fact extraction, entity resolution, consolidated observations, mental models and
knowledge pages, consumed **both** as a native Hermes memory provider (`memory.provider: hindsight`,
`local_external`) **and** as an MCP server. It replaces **Honcho** (profiles `default`, `florian`) and
**OpenViking** (profiles `andrzej`, `careerpa`, `szarik`, plus the OpenChamber agent) as the primary
agent memory, with per-profile banks so memory follows the agent rather than the store.

The migration is a deliberate batch job, not a loop: every `retain` is an LLM extraction call, so
importing the combined corpus (order of ten thousand objects, dominated by Honcho's conclusions)
costs tokens and time and must be verified by spot-check recall in the target, not by row counts in
the source.

### 2. Postgres is CNPG, never the chart's bundled Postgres

| Piece | Value |
|---|---|
| Cluster | `hindsight-db`, `instances: 1`, image `ghcr.io/cloudnative-pg/postgresql:16` |
| Storage | `local-path`, 10 Gi — fast, **not durable** by design |
| Owner / database | `hindsight` / `hindsight`, credentials from `hindsight-db-credentials` |
| Chart DB | `postgresql.enabled: false`; host `hindsight-db-rw.hindsight.svc.cluster.local:5432` |
| pgvector | `bootstrap.initdb.postInitApplicationSQL: ["CREATE EXTENSION IF NOT EXISTS vector;"]` |
| Backups | barman → `s3://cnpg-backups/hindsight` on OMV MinIO, `retentionPolicy: 30d`, daily `ScheduledBackup` with `immediate: true`, generation 1 |
| Chart secret | `existingSecret: hindsight-secrets`, which **must** also carry the `postgres-password` key |

Three details are load-bearing and were found by reading the templates and the CNPG docs rather than
the chart's prose:

- **pgvector needs a superuser.** Hindsight's schema requires the `vector` extension, and the
  application role is not a superuser, so the extension has to be created at bootstrap. CNPG's
  `postInitApplicationSQL` runs as the superuser against the application database right after
  `initdb` — it is the designed hook for exactly this.
- **`existingSecret` does not remove the chart's need for a DB password.** The api deployment and the
  worker statefulset read `postgres-password` out of `existingSecret` whenever
  `postgresql.enabled=false`, and the chart's own secret template is not rendered at all. A bundle
  without that key produces a pod that never starts.
- **The chart assembles the DSN itself.** `POSTGRES_PASSWORD` is emitted before
  `HINDSIGHT_API_DATABASE_URL`, which interpolates `$(POSTGRES_PASSWORD)` — that ordering is what
  makes Kubernetes env interpolation work, and it is why the rendered DSN must be inspected with
  `helm template` before committing. (Liveness `/health/live` does no database I/O while readiness
  `/health` queries it; the asymmetry is deliberate.)

The durable copy of the data is the S3 backup on OMV, not the PVC: the node can be rebuilt, the
database can be restored.

### 3. LLM traffic goes through our own LiteLLM proxy

`HINDSIGHT_API_LLM_PROVIDER: litellm` against `http://litellm.llm-hub.svc.cluster.local:4000`, model
`nemotron-3-nano-30b-ollama`, with `gpt-oss-20b-ollama` as the intended fallback. The credential is a
LiteLLM virtual key — deliberately **scoped to six model identifiers** (the lightweight models in bare
and `openai/`-prefixed form) instead of inheriting the key provisioner's whole model list.

Why: one credential for the whole homelab, cost tracking in the place that already tracks it, and
changing the model is a one-file change in `apps/llm-hub` rather than a new vendor key in a new
namespace. Nothing here holds an upstream provider key.

**The trade-off, written down because it will bite someone:** the key provisioner only *updates* keys
it knows about — it never creates them — so a virtual key that is not registered there sits outside
the sync. Adding a model to Hindsight's config therefore needs a hand update of the key (or a new
key), or the request fails authorisation. Least privilege bought exactly one manual step per model;
that is accepted in exchange for not handing a memory service six dozen routes it will never call.

### 4. Slim image plus external embeddings/reranker — served on CPU

- Chart pinned `0.10.3`; `hindsight-api` at `0.10.3-slim`; `hindsight-control-plane` at `0.10.3`
  (upstream publishes no slim UI); the chart's dedicated worker is **off** in the first cut.
- Embeddings and reranking are served by the chart's own TEI deployments: `all-MiniLM-L6-v2`
  (384-dim) and `ms-marco-MiniLM-L6-v2`, on the chart's `cpu-1.8.3` images. The api's model-cache PVC
  is off, because there is nothing local to cache and a ReadWriteOnce volume would pin the pod.

**The honest ruling.** The intent was the NVIDIA GPU. The host GPU is a **GTX 970M** — Maxwell,
compute capability **5.2** — and TEI's published CUDA images require **7.5** or newer, a floor CUDA 13
made absolute for everything below it. So "slim image + our GPU" resolves to **CPU TEI for both
models**, which is what the chart deploys anyway. That is less work than the original plan, not more,
but it is slower per recall.

The GPU is not written off. `gpu-embedding/ollama-embeddings` already serves `nomic-embed-text`
(768-dim) on it, so moving *embeddings* there later is a provider swap. The trap, recorded here
because it is invisible until the recall results look wrong: **768 ≠ 384 is an index rebuild**, not a
config tweak.

Slim + external is also what keeps the workload schedulable: the api asks 500m CPU / 1 Gi memory on a
node whose CPU requests are already ~78% committed.

### 5. Exposure: the UI is public behind SSO, the data API never is

- **Control Plane:** its own Cloudflare tunnel at `hindsight.voitech.dev`, TLS terminated at the
  Cloudflare edge, **Authentik SSO** in front. One public hostname, one tunnel, one token — guardrail
  8, unchanged.
- **Data API:** never published. It gets a NodePort on homelab-2nd — **30239** for the API, **30240**
  for the Control Plane — reachable on the LAN address and on the node's Netbird address. MCP
  authentication is on: `HINDSIGHT_API_TENANT_EXTENSION` set to the built-in
  `ApiKeyTenantExtension`, with the tenant key in the SOPS bundle.

**The ruling behind that split.** Hermes runs on the M1 Max, *outside* the cluster, so a
ClusterIP is useless to it and "the API stays cluster-internal" cannot be true as literally stated.
A NodePort is the smallest thing that works, it is the same shape OpenViking already uses, and it is
not a public surface. Putting Authentik SSO in front of an API consumed by a plugin would look
tidier and protect nothing: the plugin needs a non-interactive credential that bypasses the
interactive gate anyway. The UI is different — a human looks at it — so it gets the tunnel and the
SSO. Cost if the ruling is wrong: one LAN-exposed port that `local_external` needed regardless.

### 6. OpenViking is retained deliberately, not by accident

OpenViking keeps running after the migration: as an **MCP endpoint** and as a **redundant store for
technical projects**, with its hourly `.ovpack` export to MinIO still verified. It is a retained
component with a job, not leftover debt — Hindsight is the agent memory, OpenViking holds the
technical-project corpus and offers a second MCP route into it.

What would end it: a soak in which Hindsight's recall over technical material plus its MCP route prove
sufficient, and the technical projects have been migrated bank by bank. That is a separate decision,
with its own ADR, and it is explicitly **not** part of H2-232.

Honcho gets no such reprieve. It is retired after the soak, behind a final verified backup, and the
epic's stage 3 is written for exactly that.

### Not decided here

Cutover order for the remaining profiles beyond the pilot, remote/long-term metric storage, and any
change to the Hermes side beyond the `andrzej` pilot are out of scope for this ADR.

## Consequences

**Good**

- One memory platform: one backup story, one exposure story, one credential, one thing to keep
  observable and upgradable.
- Recall/retain/reflect, entity resolution and consolidated observations come from upstream instead
  of from home-grown ingest scripts.
- Memory is keyed to the agent, so it travels with the work rather than with whichever store a profile
  happened to be pointed at.
- Two first-class consumer routes (native Hermes provider, MCP server) instead of two bespoke
  integrations.
- CNPG gives PITR-capable backups of a database living on storage that is explicitly disposable, and
  `local-path` keeps recall latency off the network.
- The reasoning for the CPU-vs-GPU and LAN-vs-public calls is a reviewable file in Git rather than a
  conversation nobody can find later.

**Bad / accepted costs**

- **Two memory stores until the soak ends.** More to explain, two backup paths to keep verified, and
  OpenViking's running cost stays.
- **CPU embeddings and reranking are slower than the GPU would have been, on every recall.** The
  trigger to revisit is measured latency, not impatience.
- **pgvector is created by a bootstrap hook, not by a chart or an operator.** `postInitApplicationSQL`
  runs once, at `initdb`. A cluster rebuilt by recovery does not re-run it, so a recovery runbook has
  to re-create the extension if it is ever absent — and it is the second reason this cluster cannot use
  a minimal CNPG operand image (the first being `barman-cloud`).
- **The `existingSecret` ↔ `postgres-password` coupling is a live trap.** The SOPS bundle must carry a
  key for a secret the chart claims not to manage; trimming it later yields a crash-looping api with no
  obvious cause.
- **Adding a model to Hindsight needs a hand-updated key** (section 3).
- **The API is reachable by anything on the LAN or the Netbird network**, gated only by the MCP tenant
  key. Accepted for a single-tenant homelab; the alternative was worse (section 5).
- **Another Postgres cluster on the same node**: another 250m CPU / 256 Mi request and another WAL
  stream flowing into MinIO.
- **Nothing here is runtime-proven yet.** Stage 1 is reconciled, but the pilot, the migration and the
  recision of OpenViking's role are still ahead; this ADR is the plan of record that the runtime has
  to confirm.

## Alternatives considered

- **Hindsight Cloud (the vendor's managed service).** Rejected: the point of the epic is self-hosted
  memory, and this is the most personal data in the homelab — profiles, conclusions, observations.
  It would add a recurring cost, put the retention and backup story outside our control, and make the
  memory of our own agents depend on a third party's uptime. It stays a migration option rather than a
  platform, because the store is plain Postgres.
- **The bundled-models `full image`.** Rejected: roughly 9 GB of baked-in models pulled per node, a
  larger attack surface, and a model-cache PVC that would pin the pod on a single-node cluster — all to
  duplicate TEI deployments we already run, and to ignore the GPU-served embedder already resident in
  the cluster. The accepted cost is a real dependency: if TEI is down, recall is down, which the
  metrics make visible instead of hiding.
- **The chart-bundled Postgres.** Rejected outright by guardrail 3 — no standalone Postgres, ever —
  and independently by operations: no backup path of ours, no PITR, and a PVC whose lifecycle is tied
  to a Helm release rather than to a `Cluster` object we can operate.
- **Exposing the data API publicly, behind the tunnel and SSO, like the UI.** Rejected because it
  would not be a security boundary: the plugin needs a credential that is not an interactive login, so
  the API would gain a public hostname while the credential that actually guards it stays the tenant
  key. A public hostname plus a non-interactive key is strictly worse than a LAN/Netbird port plus the
  same key.
- **GPU TEI** (the original "slim image + our NVIDIA GPU" plan). Rejected on capability, not
  preference: the GPU is Maxwell, compute capability 5.2, and TEI's CUDA images need 7.5 or newer.
  Pinning an old CUDA-12 TEI image to keep the plan alive was rejected as unsupported and fragile for a
  service that has to be boring for years. The GPU still earns its keep serving embeddings to other
  workloads, and it is the first candidate when latency says so.
- **Keeping Honcho alongside Hindsight and migrating only OpenViking.** Rejected: memory would then
  live in two models with different semantics, and "which store is the truth?" is the question this
  whole epic exists to delete. Two stores is the problem; it is not a safety net.
- **Going straight to the 768-dim GPU embedder to avoid CPU inference.** Rejected for the first cut:
  it forces an index rebuild before there is a single latency measurement to justify it, and 384-dim is
  the model the chart ships and tests. The revisit trigger is in the next section.
- **Enabling the chart's dedicated worker from day one.** Deferred, not rejected: a second pod doubling
  the worker footprint for one user, on the node whose CPU requests are the binding constraint. The
  gauges for backlog depth exist so a real need shows up as data.

## When to revisit

- **GPU contention or a GPU that supports modern CUDA.** Once the pilot has latency numbers, decide
  whether CPU TEI is good enough. The upgrade path (`gpu-embedding/ollama-embeddings`, 768-dim) is a
  provider swap plus an **index rebuild** — as is any other change of embedding model.
- **Pilot `recall` quality disappointing**, or a pile of `no_facts` outcomes: first swap the LLM route
  (one file in `apps/llm-hub`), then the embedding/reranking models, remembering that a dimension
  change means a rebuild rather than a config edit.
- **An upstream first-party CNPG story** — an external-database path that also bootstraps pgvector, or
  a documented compatibility statement. That would let us delete the `postInitApplicationSQL` hook and
  its recovery caveat.
- **A CPU-request budget change, or a second node.** Revisit the disabled worker and the api's
  requests; also the `local-path` choice, if a shared storage class ever arrives that is both faster
  and safe for a live database.
- **The end of the soak.** Revisit OpenViking's retained role either to confirm it or to migrate the
  technical projects fully and retire it — as its own decision, not as a footer to this one.
- **If Hindsight's licence or its OCI publishing changes** (MIT and `ghcr.io` today). The exit is a
  dumped-and-restored Postgres database into whatever replaces it, because the durable artifact here is
  a Postgres backup on OMV.
