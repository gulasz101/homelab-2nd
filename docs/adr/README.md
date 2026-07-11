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

## Writing an ADR

Use the template in `adr-001-prometheus-storage-local-path.md`:
- **Context** — what problem or question triggered the decision.
- **Decision** — what was decided, stated clearly.
- **Consequences** — positive and negative outcomes.
- **Alternatives considered** — other options and why they were rejected.
- **When to revisit** — conditions that would make the decision obsolete.

Keep ADRs concise, opinionated, and homelab-specific. They are source material for blog posts, so include enough detail for a future writer to reconstruct the reasoning.
