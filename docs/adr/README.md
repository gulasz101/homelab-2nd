# Architecture Decision Records (ADRs)

This directory records significant architectural decisions for the homelab. Each ADR explains the context, the decision, the consequences, and the alternatives considered.

ADRs are numbered sequentially. The numbering is not reused if an ADR is superseded.

## Index

| Number | Title | Status | Date |
|---|---|---|---|
| ADR-001 | Prometheus time-series storage stays on `local-path` | Accepted | 2026-06-26 |
| ADR-002 | docs-mcp-server runs locally in k3s | Accepted | 2026-06-28 |
| ADR-003 | GPU embeddings run in k3s via Ollama (TEI abandoned for Maxwell sm_52) | Accepted | 2026-06-30 |
| ADR-004 | Honcho runs in k3s with CNPG and NodePort | Accepted | 2026-07-03 |
| ADR-005 | Per-namespace observability (dashboards, Prometheus rules, Loki alerts) | Accepted | 2026-07-12 |
| ADR-010 | Self-host Firecrawl v2 and wire it to Open WebUI web search | Proposed | 2026-08-05 |
| ADR-011 | arr-stack migrates to a dedicated k3s namespace | Proposed | 2026-09-05 |
| ADR-012 | Multi-environment Flux repo layout (`clusters/production` + `clusters/staging`) | Accepted | 2026-09-12 |
| ADR-013 | NetBird host firewall disabled on the k3s control-plane node | Accepted | 2026-09-13 |
| ADR-014 | arr-stack API keys are owned by the apps; the SOPS secret mirrors them | Accepted | 2026-09-13 |
| ADR-015 | Authentik SSO providers are declared in a Blueprint, never created imperatively | Accepted | 2026-09-13 |
| ADR-016 | Karakeep state is reconstructed from vault manifests + Hermes history; back up before the thing you want to protect | Accepted | 2026-09-13 |
| ADR-017 | Itsaplan H2 is reconstructed through its own API with historical ids; API keys are re-seeded by hash | Accepted | 2026-09-13 |
| ADR-018 | OpenChamber worker — t460 container, split local/durable storage | Accepted | 2026-09-14 |
| ADR-019 | Itsaplan agent results post back as issue comments via the bridge | Accepted | 2026-09-15 |
| ADR-020 | Open WebUI gets cluster-internal MCP tool servers via `TOOL_SERVER_CONNECTIONS` (additive to Firecrawl) | Accepted | 2026-09-26 |
| ADR-021 | Pi-hole DNS shield on k3s (family discipline layer) | Accepted | 2026-09-27 |
| ADR-022 | Pi-hole Family Shield enforcement layer — group topology, whole-home noporn, curfew-by-CronJob | Accepted | 2026-09-29 |
| ADR-023 | OpenChamber worker on OpenChamber 2 / OpenCode 2 (amends ADR-018) | Accepted | 2026-09-30 |
| ADR-024 | OpenChamber 2.1.0 and the in-pod OpenCode CLI self-upgrade (amends ADR-023) | Accepted | 2026-10-02 |
| ADR-025 | OpenChamber Node.js HTTP header size limit | Accepted | 2026-10-02 |
| ADR-026 | OpenCode Go session header — LiteLLM fallback strategy | Superseded by ADR-029 | 2026-10-02 |
| ADR-027 | Strip browser SSO headers before the internal OpenCode hop | Accepted | 2026-10-02 |
| ADR-028 | docs-mcp-server on streamable HTTP `/mcp`, pinned image, Recreate strategy | Accepted | 2026-10-03 |
| ADR-029 | OpenCode Go session header — per-request normalization in LiteLLM (supersedes ADR-026) | Accepted | 2026-10-03 |
| ADR-030 | Nightly config backups exclude re-derivable media metadata | Accepted | 2026-10-03 |
| ADR-031 | Qwen3.8-27B MLX 4-bit replaces the ≤12B local-model cap | Accepted | 2026-10-03 |
| ADR-032 | Public-ingress tunnels are created through the Cloudflare API, not the Zero Trust dashboard | Accepted | 2026-10-07 |
| ADR-033 | `apps/base` + `apps/overlays` restructure deferred to a per-service migration campaign | Accepted | 2026-10-04 |
| ADR-034 | Hermes MCP write-backs authenticate with the Andrzej agent key, not the god-user key | Accepted | 2026-10-04 |
| ADR-035 | Bound oauth2-proxy per-request CSRF cookie pile (`--cookie-csrf-per-request-limit=3`) | Accepted | 2026-10-05 |
| ADR-036 | Local MLX context — pin the MLX runtime to 1.8.5 (LM Studio auto-fit override) | Accepted | 2026-10-05 |
| ADR-037 | Mail-Archive storage model — DB-resident archive, CNPG backups to OMV MinIO, DataProtection keyring on NFS | Accepted | 2026-10-07 |
| ADR-038 | Per-device scheduled curfews — the dedicated-marker pattern (Sylwia's Instagram-only evening block) | Accepted | 2026-10-08 |
| ADR-039 | Mail-Archiver tolerates the .NET-on-Linux revocation-check soft failure (`IgnoreSelfSignedCert=true`) | Superseded by ADR-040 | 2026-10-08 |
| ADR-040 | Mail-Archiver needs HTTP (port 80) egress for certificate-revocation checks (supersedes ADR-039) | Accepted | 2026-10-08 |
| ADR-041 | Grafana's local admin consumes the SOPS secret (`admin.existingSecret`), never the chart's generated one | Accepted | 2026-10-09 |
| ADR-042 | "Grey-zone" Anthropic reseller keys live in their own SOPS secret and route per-provider through LiteLLM | Accepted | 2026-10-09 |
| ADR-043 | The grey-zone supervisor is its own Hermes profile, and each Itsaplan project gets its own OpenChamber worker lane | Accepted | 2026-10-09 |
| ADR-044 | A local LM Studio model as the Hermes gateway's offline fallback | Accepted | 2026-10-10 |
| ADR-046 | The zigbee namespace storage model — durability per workload, not per namespace | Accepted | 2026-10-11 |
| ADR-047 | Surface Pro 4 boot-slot ownership and linux-surface kernel pinning | Accepted | 2026-10-12 |
| ADR-048 | One-shot `Job` objects carry a version suffix in their name | Accepted | 2026-10-12 |
| ADR-049 | Flux deployment health is alerted from kube-state-metrics resource state plus the controller scrape | Accepted | 2026-10-12 |
| ADR-050 | The SOU fork lane reaches `qwen3.8-flash` through an explicit OpenAI-protocol LiteLLM provider | Accepted | 2026-10-12 |
| ADR-051 | A grey-zone profile falls back to the *other* reseller's copy of the same model (amends ADR-042) | Accepted | 2026-10-12 |
| ADR-052 | Hindsight is the agent-memory platform — CNPG + pgvector, LiteLLM LLM, CPU TEI, tunnel + SSO, OpenViking retained as an MCP endpoint | Accepted | 2026-10-13 |
| ADR-053 | The Hindsight Control Plane is published behind its Cloudflare Tunnel through in-cluster oauth2-proxy + Authentik (never bare, no Cloudflare Access on top) | Accepted | 2026-10-13 |
| ADR-054 | Hindsight fact extraction runs on gpt-oss-120b via OpenRouter, not Ollama Cloud (amends ADR-052) | Accepted | 2026-10-14 |
| ADR-062 | ZeroClaw reaches in-cluster Firecrawl over a LAN NodePort, with `http_request` auto-approved | Accepted | 2026-10-15 |
| ADR-057 | SOU database layer — Postgres primary, SQLite fallback | Accepted | 2026-10-13 |
| ADR-058 | SOU event schema v1 — agent-agnostic JSON | Accepted | 2026-10-13 |
| ADR-059 | SOU OpenClaw decoupling — ruthless divergence | Accepted | 2026-10-13 |
| ADR-060 | SOU spatial redesign — one room per agent, camera-followed movement, licence-clean art | Accepted | 2026-10-14 |
| ADR-061 | SOU product definition and cross-cutting invariants | Accepted | 2026-10-14 |
| ADR-063 | LiteLLM router fallback `qwen3.8-flash` → `deepseek-v4.1-flash` for runner lanes | Accepted | 2026-10-15 |
| ADR-064 | SOU scene composition — the backdrop is a room *shell*, the engine owns the furniture | Accepted | 2026-10-15 |
| ADR-065 | SOU rooms declare their geometry; objects are generated in that projection and gated by measurement | Accepted | 2026-10-15 |
| ADR-066 | Bill Cipher gets a personal Interia mailbox on the Hermes Email gateway | Accepted | 2026-10-16 |
| ADR-067 | SOU renderer v2 — an engine-native isometric tilemap (Phaser 4) | Accepted | 2026-10-16 |
| ADR-068 | OpenCode Go lanes terminate their fallback chain on a different account (`gpt-oss-120b-openrouter`) | Accepted | 2026-10-17 |
| ADR-069 | Go-lane cross-account fallback keeps the model: `deepseek-v4.1-flash-openrouter` before gpt-oss | Accepted (amended by ADR-070) | 2026-10-17 |
| ADR-070 | Go-lane fallback tries Ollama Cloud (`deepseek-v4.1-flash-ollama`) before OpenRouter (amends ADR-069) | Accepted | 2026-10-17 |
| ADR-071 | Hermes `state.db` is the agent-memory source of record; nightly backup to OMV MinIO | Accepted | 2026-10-19 |
| ADR-072 | Live databases are pinned to homelab-2nd; zigbee-node is dedicated to the Zigbee stack | Accepted | 2026-10-19 |
| ADR-073 | Hermes runs on the M1 Air; the Max's copy is a retired standby | Accepted | 2026-10-20 |
| ADR-074 | Agent orchestration control plane on the M1 Air (Paperclip) | Accepted | 2026-10-20 |
| ADR-075 | Paperclip org chart, agent runtimes and the "plan big, execute cheap" split | Accepted | 2026-10-20 |
| ADR-076 | Paperclip is the record for chat requests; one Paperclip identity per agent | Accepted | 2026-10-21 |
| ADR-077 | Speech-to-text lives in k3s (Speaches + `speaches-api-lan` NodePort), not on each host | Accepted | 2026-10-21 |
| ADR-078 | Star Office ingest tokens live in the database registry; the env map is gone | Accepted | 2026-10-21 |
| ADR-079 | LaunchAgents on the Air reach LAN services through loopback relays, never directly | Accepted | 2026-10-22 |
| ADR-080 | The memory watchdog reads the backup JOB's exit status, not just its log | Accepted | 2026-10-22 |
| ADR-081 | `hindsight-db` backups move to the barman-cloud plugin, continuing the same archive | Accepted | 2026-10-22 |
| ADR-082 | Hindsight fact-extraction LLM moved to `beam-free-go` (OpenCode Go, free) | Superseded by ADR-083 | 2026-10-23 |
| ADR-083 | Hindsight LLM (retain + consolidation) moved to free-openrouter (supersedes ADR-082) | Superseded by ADR-085 | 2026-10-24 |
| ADR-084 | FreeLLMAPI as the homelab's free-tier LLM aggregator | Accepted | 2026-10-24 |
| ADR-085 | LiteLLM carries paid subscriptions only; free tiers move to FreeLLMAPI | Accepted | 2026-10-24 |
| ADR-086 | Agent run ceilings must exceed the slowest dependency wait | Accepted | 2026-10-26 |
| ADR-087 | An hourly watchdog agent owns board triage | Accepted | 2026-10-26 |
| ADR-088 | The PM is a morning reviewer; the watchdog runs the day | Accepted | 2026-10-26 |

> Note: rows ADR-057…ADR-061 and ADR-063…ADR-066 were back-filled on 2026-10-16 alongside
> ADR-067 — the files had landed without index rows (same recurring miss as ADR-035/036,
> ADR-044, ADR-047, ADR-049 and ADR-062). ADR-055 and ADR-056 have no file: the numbers are
> unassigned, not missing.

> Note: ADR-052 was booked as ADR-050 while epic H2-232 was being planned (the directory then
> ended at ADR-046 with 045 reserved); 047–051 landed from unrelated work before stage 1 was
> committed, so the decision is recorded as 052. The epic's older internal references to
> "ADR-050" mean this file.

> Note: ADR-045 is reserved by H2-212 (the Zigbee coordinator radio-head decision) and is not in
> this index yet; ADR-044's row was added here alongside ADR-046, since the file existed but the
> index row had been missed.

> Note: ADR-049's row was back-filled alongside ADR-050 (2026-10-12) — its file had landed without
> an index row, the same miss as ADR-035/036, ADR-044 and ADR-047.

> Note: ADR-047's row was back-filled alongside ADR-048 (2026-10-12) — the file landed without its
> index row, same as ADR-035/036 and ADR-044.

> Note: ADR-035 and ADR-036 existed as files but were missing from this index;
> added alongside ADR-037 (same edit, 2026-10-07).

> Note: `ADR-032` was previously cited by the fitness (openGym) manifests for a
> never-written openGym deployment-design ADR. The number now documents
> Cloudflare tunnel creation via API (H2-112), and those stale citations were
> corrected alongside it (H2-191); the openGym design rationale lives in the
> H2-106 tracking note.

## Writing an ADR

Use the template in `adr-001-prometheus-storage-local-path.md`:
- **Context** — what problem or question triggered the decision.
- **Decision** — what was decided, stated clearly.
- **Consequences** — positive and negative outcomes.
- **Alternatives considered** — other options and why they were rejected.
- **When to revisit** — conditions that would make the decision obsolete.

Keep ADRs concise, opinionated, and homelab-specific. They are source material for blog posts, so include enough detail for a future writer to reconstruct the reasoning.
