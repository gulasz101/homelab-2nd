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
