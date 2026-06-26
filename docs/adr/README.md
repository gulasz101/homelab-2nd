# Architecture Decision Records (ADRs)

This directory records significant architectural decisions for the homelab. Each ADR explains the context, the decision, the consequences, and the alternatives considered.

ADRs are numbered sequentially. The numbering is not reused if an ADR is superseded.

## Index

| Number | Title | Status | Date |
|---|---|---|---|
| ADR-001 | Prometheus time-series storage stays on `local-path` | Accepted | 2026-06-26 |

## Writing an ADR

Use the template in `adr-001-prometheus-storage-local-path.md`:
- **Context** — what problem or question triggered the decision.
- **Decision** — what was decided, stated clearly.
- **Consequences** — positive and negative outcomes.
- **Alternatives considered** — other options and why they were rejected.
- **When to revisit** — conditions that would make the decision obsolete.

Keep ADRs concise, opinionated, and homelab-specific. They are source material for blog posts, so include enough detail for a future writer to reconstruct the reasoning.
