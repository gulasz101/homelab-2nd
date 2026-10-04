# ADR-034: Hermes MCP write-backs authenticate with the Andrzej agent key, not the god-user personal key

**Status:** Accepted
**Date:** 2026-10-04
**Issue:** H2-127

## Context

Since the ADR-017 board reconstruction, every Itsaplan write-back made by the Mac
Hermes session (Route A delegated runs: result comments, card moves, attachments)
was authored as **Wojciech Gula (god user)**. OpenChamber (Route B) authored its
comments as the **openchamber agent** via `x-api-key` (ADR-019). Two agents, two
authorship models — a confusing audit trail, and it silently weakened the
mention-loop guard: the API drops run triggers from *agent-authored* comments
(`enqueueMentionRuns`: `if (comment.actorUserId && isAgentUser(...)) return;`),
but Andrzej's comments were admin-authored, so a stray `@andrzej` or `@admin`
in one of my comments could genuinely re-trigger work. The skill therefore
mandated zero-width-space neutralisation on every Route A comment — a workaround
for a misattributed identity, not a fix.

Root cause (ADR-017 decision #3): the Mac's MCP header references
`MCP_ITSAPLAN_API_KEY`, an `itp_…` key that was re-seeded by hash during the
reconstruction bound to `reference_id` = the god user, specifically so that no
Mac-side change was needed. That was the right call under recovery pressure; it
just left the wrong identity wired in.

## Decision

Point the Hermes `andrzej` profile's Itsaplan MCP header at the **Andrzej agent
key** instead of the god-user personal key:

- `mcp_servers.itsaplan.headers.Authorization: Bearer ${ITSAPLAN_ANDRZEJ_AGENT_API_KEY}`
  in `~/.hermes/profiles/andrzej/config.yaml` (set via `hermes config set`; takes
  effect on the next gateway restart — `hermes -p andrzej gateway restart` from an
  external shell).
- The env var holds the SAME secret value as the cluster SOPS secret
  `itsaplan-andrzej-agent-key` (key `ITSAPLAN_API_KEY`) that the arr-box runner
  already uses. One agent identity, two consumers, mirroring Route B exactly.
  (Note found during this work: the Mac's copy of that variable had gone stale
  after the ADR-017 decision-#4 rotation — it was re-synced to the live value and
  verified against the API.)
- The god-user key `MCP_ITSAPLAN_API_KEY`/`ITSAPLAN_API_KEY` stays in the Mac
  `.env` as an undocumented-by-usage **break-glass admin identity**, referenced by
  nothing after this change.

Verified live before switching (2026-10-04, v0.17.0):
- `/mcp` accepts the agent key as `Authorization: Bearer` **and** as `x-api-key`
  (`mount.ts` `extractApiKey` falls through Bearer → x-api-key; the key resolves
  through the same better-auth session path regardless of user kind — `itp_` is
  just a branding prefix, the authoring identity comes from `apikey.reference_id`).
- Agent-key reads work (`get_issue`, `list_issues`, `get_project`).
- Agent-key writes work: created scratch issue H2-128, commented, moved its card,
  then deleted it — activity rows all showed `actorName: "Andrzej"`,
  `actorUserId: f85ce3c6…` (the agent).

## Consequences

**Positive**
- Audit trail honest: agent work shows the agent, human work shows the human.
- The mention-loop guard now applies to my comments by design: agent-authored
  comments never enqueue mention runs, so the zero-width neutralisation ritual
  is no longer load-bearing for Route A (`@admin` tags to the human are safe
  notifications, not triggers).
- Route A and Route B share one auth model (`x-api-key`/Bearer with an agent key);
  one pattern to document and reason about.

**Negative / accepted**
- The Mac now holds a second key that can mutate the board; key hygiene matters
  (it lives in the profile `.env`, same as before, SOPS-owned cluster copy is the
  canonical home).
- Rotating the agent key requires TWO updates (cluster SOPS secret **and** the Mac
  `.env` var) or Route A silently reverts to a stale `INVALID_API_KEY` — which is
  exactly how the staleness bit this session. Documented in the rotation recipe.
- A gateway restart is required for live sessions to pick up the new header;
  until then old sessions keep writing as the god user (authorship is per
  connection, not per policy).

**Alternatives considered**
- *Option 2 in H2-127 (a separate `Andrzej-bot` personal user):* rejected — the
  agent user already exists with the correct `reference_id` binding and its key
  works on `/mcp`; inventing a fourth identity adds surface for no benefit.
- *Option 3 (split reads on MCP-as-admin, writes via REST with agent key):*
  rejected — two auth paths, more contract complexity, strictly worse ergonomics.
- *Re-seed the god key's `reference_id` to the agent in SQL:* rejected — raw-SQL
  identity surgery breaks the ADR-017 "reconstruct through the app's own API"
  principle and would orphan the admin break-glass key.

**When to revisit**
- Itsaplan introduces a first-class machine/service user kind or per-key
  permission scoping that distinguishes reads/writes — re-evaluate keeping the
  unscoped god key at all.
- If agent-key rotation friction causes another silent staleness incident, move
  the Mac value's provisioning into GitOps (SOPS-rendered env injection) instead
  of manual sync.

## References

- ADR-017 decision #3 (origin of the god-user binding), decision #4 (runner key rotation)
- ADR-019 (Route B bridge posts with agent key via `x-api-key` — the correct pattern)
- `docs/itsaplan-hermes-task-flow.md` §Results (updated with this change)
- `skill:agent-task-delegation` (authorship caveat rewritten post-fix)
- Issue H2-127
