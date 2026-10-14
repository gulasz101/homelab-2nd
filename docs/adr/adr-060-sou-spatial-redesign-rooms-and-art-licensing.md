# ADR-060: SOU Spatial Redesign — One Room per Agent, Camera-Followed Movement, Licence-Clean Art

**Date:** 2026-10-14
**Status:** Accepted
**Supersedes:** the single-agent spatial assumptions in `frontend/layout.js` / `frontend/game.js`
**Related:** ADR-057 (database layer), ADR-058 (event schema v1), ADR-059 (OpenClaw decoupling)
**Issues:** SOU-88 (spatial redesign), SOU-80 (multi-agent renderer, prerequisite), SOU-79 (English-only)

## Context

The fork renders all agents in **one flat shared office**. `frontend/layout.js` defines a
handful of shared `areas` (`breakroom`, `writing`, `researching`, `serverroom`) and
`frontend/game.js` derives a sprite's position from its *state* via `AREA_POSITIONS`. The
consequences:

- Every agent in the same state lands on the **same tile** — sprites overlap and the scene
  cannot show more than a couple of agents legibly.
- There is **no concept of an agent owning space**. `area` is a single string field on the
  agent record; nothing models N agents owning N rooms.
- Movement is a teleport on state change: no walk cycle, no route, no pathfinding.
- The scene is built around one privileged character (`Star`, `isMain: true`) with everyone
  else framed as a visitor.

The Supreme Leader's ruling (2026-10-14) is that the dashboard is the fork's actual product
and must read as a **multi-agent** visualisation: a building where **each agent gets its own
room on joining** and **agents move between rooms** as their activity changes.

## Decisions

### D1 — Layout model: ONE BUILDING, ONE ROOM PER AGENT, CAMERA FOLLOWS ACTIVITY

Chosen over a floor-plan grid (rooms shrink as N grows) and over polishing the single shared
office (does not satisfy "own room"). Rationale given: it scales to many agents and suits the
eventual use as a Twitch background.

Consequences: the renderer needs a **camera** that tracks whichever agent(s) are active, plus
room culling so off-screen rooms are not rendered. This is the most expensive of the options
and is accepted deliberately.

### D2 — Rooms are allocated on join and persisted

Room ownership is part of the agent record, not a rendering detail. On first event from an
agent, the dashboard allocates the next free room and persists the assignment; the assignment
is **stable across restarts** and a rejoining agent resumes its own room. This extends the
roster record that `load_agents_state()` already rebuilds from the DB.

Room identity and room *position* are separate: identity is the durable assignment, position
comes from the layout data.

### D3 — Layout is data, not code

Rooms, their bounds, doorways, and shared facilities live in `frontend/layout.js` (or a JSON
it loads), so the room set can change without editing renderer logic. `game.js` reads the
layout; it does not hardcode room coordinates.

### D4 — Movement is a walk, not a teleport

When an agent's activity changes, its sprite traverses a defined route (through doorways,
not straight through walls) with a walk cycle to the destination — its own room when idle,
shared facilities when working (server room when executing, etc.).

### D5 — Activity is legible at the sprite

Each sprite carries its name and its **current activity**, so a viewer can tell which agent is
doing what without opening a panel. This is the point of the dashboard; a scene of anonymous
sprites does not satisfy it.

### D6 — Art direction: COZY 16-BIT RPG / LODGE

Warm wood, firelight, "Stardew-ish" — an explicit re-do of the existing mountain-lodge feel in
a licence-clean pipeline. Not isometric-corporate, not cyberpunk.

## Art licensing — the constraint that actually bites

The existing art pack is LimeZu (non-commercial) and must be replaced. While investigating the
generation route, a trap was confirmed on 2026-10-14:

- **❌ Ideogram 4 (both `nf4` and `fp8` weight variants) is licensed
  "Ideogram 4 Non-Commercial"** — per the model card at
  `huggingface.co/ideogram-ai/ideogram-4-fp8` (and `-nf4`), and the repository is gated behind
  conditions acceptance. The `ideogram4-local` pipeline already installed on the M1 Max runs
  these weights, so **anything it generates is non-commercial** — the same defect class as the
  LimeZu assets it would replace. Generated art from that pipeline must NOT ship in the repo or
  in any public/Twitch-facing surface. (Note: the *code* repo `ideogram-oss/ideogram4` is
  Apache-2.0, but code licence does not govern the weights or their outputs — do not conflate
  them.)
- **✅ Qwen-Image 1.0 (`Qwen/Qwen-Image`) is Apache-2.0** and is the permitted generation route.
- **❌ Qwen-Image 2.1 is FORBIDDEN** — research-only licence. Do not use it regardless of
  apparent quality.
- **Never img2img, and never train, on Star-Office or LimeZu PNGs.** Those assets are being
  replaced; they are not training material.

The default art pack is therefore **blocked** until a Qwen-Image 1.0 (or other verifiably
licence-clean) route is stood up and verified. A working pipeline is not the same as a
permitted one.

The dashboard's existing Gemini "New Home" / background-reskin feature is **kept** — it is a
runtime reskin performed by the operator with their own key, distinct from the shipped default
pack.

## Consequences

**Positive.** The scene becomes genuinely multi-agent and legible; the layout becomes data and
therefore cheap to iterate; room ownership is durable so an agent's place in the world is
stable. The licence position is now explicit and checkable, which prevents a repeat of the
LimeZu problem.

**Negative / costs.** Camera + culling is the most expensive layout option. Room allocation
adds a persisted field to the roster and a migration concern for existing agents. Movement
requires walk-cycle sprites that do not exist in the current pack — so D4 cannot be visually
completed before the art pack is unblocked; the route and state machine can be built and tested
with placeholder sprites.

## Sequencing

`SOU-79 (English-only) → SOU-80 (multi-agent renderer) → SOU-88 (this ADR: rooms + movement)`.
Art pack generation is a separate ticket, gated on the Qwen-Image 1.0 route being verified.

Do not start SOU-88 before SOU-80 lands — SOU-80 removes the privileged `main` agent and makes
agents first-class, which the room model assumes.
