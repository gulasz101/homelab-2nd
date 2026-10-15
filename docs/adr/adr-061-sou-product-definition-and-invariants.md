# ADR-061: SOU Product Definition and Cross-Cutting Invariants

**Date:** 2026-10-15
**Status:** Accepted
**Deciders:** akadmin (Supreme Leader), Szarik
**Project:** SOU (Star-Office-UI fork)
**Related:** ADR-057 (database layer), ADR-058 (event schema v1), ADR-059 (OpenClaw decoupling), ADR-060 (spatial redesign + art licensing)

## Context

The purpose and constraints of this project were briefed verbally, across several
sessions (voice memos, 2026-10-12 onwards). Verbal briefs do not survive session
loss, and the cost of that is specific and known: the same decisions get
re-litigated, an agent "rediscovers" a constraint the hard way, or a worker builds
something that contradicts the intent. This ADR pins the parts of the brief that
are **decisions, not preferences**.

## What SOU is

An **agent-agnostic activity visualisation**. One central place where the operator
sees what every agent in the fleet is actually doing, in a simple and fun way. The
fleet is plural by design: Hermes, OpenChamber, OpenCode, Pi, Claude, OpenClaw,
and whatever joins next. Forked from `ringhyacinth/Star-Office-UI` (Flask +
Phaser.js); upstream is OpenClaw-specific, so the core is being redesigned to be
harness-agnostic (ADR-059).

## Intended end use

Eventually a **stream/Twitch background**: a screen-shared view of the office
running as the backdrop to work. Consequences that follow from that: it must be
**legible at a glance** (ADR-060 D5), and it may one day be **public-facing**, so
non-commercial and third-party trademarked art cannot ship in it.

This is a personal project, not a production system. Where "correct" and "fun to
look at" conflict, the operator's taste wins.

## Invariants — decided, do not re-open without a new ADR

1. **Phaser.js stays.** It is the engine the operator learned on and identifies
   with; the renderer may be refactored, the engine is not swapped. Non-negotiable.
2. **Mechanics before artwork.** Event ingest and plug-and-play wiring *are* the
   product; art is decoration on top of a working loop. (Art generation is now
   unblocked — ADR-060 as amended.)
3. **Agent-agnostic, or it is a bug.** Nothing may be keyed to a single agent's
   harness. Adding an agent = writing an adapter, never editing the renderer
   (`POST /events` + JSON schema v1, ADR-058).
4. **Postgres-first, SQLite as a convenience.** Design every data path for Postgres
   from day one — we have rehearsed backup/restore for CNPG, and the homelab is the
   project's eventual home. SQLite stays a localhost testing affordance. No
   SQLite-only logic (ADR-057).
5. **Versioned JSON on the wire, not protobuf.** At this stage debuggability beats
   efficiency: payloads must be readable with `jq` and in devtools (ADR-058).
6. **Push, not pull.** Agents POST events. **More events is better than fewer** —
   all tool calls, so that a session reads back as a chain of what happened
   (Hermes opens 5 files → OpenChamber writes 2 → Andrzej commits).
7. **Hermes first.** It carries the most traffic; it is the integration to prove
   before the rest of the fleet.
8. **Local-first.** Development runs on the M1 Max (browser over LAN). k3s
   deployment, Cloudflare tunnel and Authentik SSO come *after* the mechanics work
   (SOU-10), never as a prerequisite for them.
9. **Reuse what the fork already has.** Read the existing source and build on it —
   the upstream data layer and harness support are already well developed, and we
   interact with the data layer far more than with the renderer. Rewriting working
   machinery is the failure mode to avoid.
10. **Licence rules (ADR-060).** Apache-2.0 weights only; **never** Qwen-Image-2.1;
    **never** img2img or train on Star-Office or LimeZu PNGs; no readable
    third-party text or logos baked into generated backgrounds.
11. **Art generation is a Mac-side batch step.** The k3s cluster has no usable GPU
    (its single device is a 3 GB Maxwell GTX 970M, already claimed by
    `gpu-embedding/ollama-embeddings`). Nothing in the deployed service may depend
    on in-request generation.

## Consequences

**Positive.** A session that has lost its context recovers the brief from this
repo. Delegated work can be scoped with a single reference: "these are the
invariants, ADR-061". The two constraints most likely to be violated by a
well-meaning worker — harness coupling (#3) and in-request generation (#11) — are
now explicit and checkable.

**Negative / costs.** Invariants #1 and #8 deliberately trade flexibility for
identity and practicality (Phaser is not the fastest option; local-first delays
the homelab deployment). Accepted deliberately.
