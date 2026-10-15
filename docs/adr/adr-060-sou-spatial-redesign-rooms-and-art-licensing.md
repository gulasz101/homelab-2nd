# ADR-060: SOU Spatial Redesign — One Room per Agent, Camera-Followed Movement, Licence-Clean Art

**Date:** 2026-10-14
**Status:** Accepted — **amended 2026-10-15** (art generation route + cluster GPU finding: see "Amendment 2026-10-15" at the end)
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

---

## Amendment 2026-10-15 — art generation route (Supreme Leader's ruling)

**Decision.** The art pack is generated with **`black-forest-labs/FLUX.2-klein-4B`**
(**Apache-2.0**, not gated — verified on the model card and via the HF API) plus
**`Limbicnation/pixel-art-lora`** (Apache-2.0, trained exclusively on a CC0 set,
`base_model: FLUX.2-klein-4B`). **`Qwen/Qwen-Image` 1.0 is demoted to fallback**, not the primary
route: its licence is fine, but it is not sprite-specialised and the klein-4B + LoRA chain is the
one already scoped on SOU-2/SOU-8. The prohibition on **Qwen-Image 2.1** (research-only) stands.

**Why the D6 wording above is now insufficient.** D6 fixed the *look* (cozy 16-bit lodge). It named
Qwen-Image 1.0 as "the permitted generation route", which the tickets never did — SOU-2 and SOU-8
both name klein-4B. The ADR and the board disagreed for ten days; a future reader follows the ADR.
That is the defect this amendment closes.

**Cluster GPU finding (constrains the pipeline, not the look).** `homelab-2nd` does report
`nvidia.com/gpu: 1`, but the device is a **GeForce GTX 970M — 3 GB, Maxwell, compute 5.2** — and it
is **already fully claimed by `gpu-embedding/ollama-embeddings`**. The klein-4B pipeline wants
~13 GB and a bf16-capable device. Therefore:

- **Art generation runs on the M1 Max as a Mac-side batch step** (32 GB unified, MPS). It is not a
  cluster workload and cannot be one on this hardware.
- **No deployed component may depend on generating an image inside a request.** Any "agent joins →
  server renders its room" design is unbuildable here; generation must be decoupled from the join
  path (pre-generation + a placeholder bay while a pack is missing).

**Runtime note.** `Flux2KleinPipeline` now ships in **released diffusers 0.41.0** — the LoRA card's
"diffusers >= 0.37.0.dev0 from git main" requirement is satisfied by the wheel. Note the pipeline's
text encoder is **Qwen3**, not the Mistral3 encoder of the FLUX.2-dev pipeline, so off-the-shelf
FLUX.2-dev guidance does not transfer. `guidance_scale` is ignored on this distilled model.

**Art contract note (verified, feeds the post-process step).** "Downscale to the native sprite
size" has no single answer: `frontend/game.js` uses 128×128, 230×144, 256×256, 160×160, 230×230,
180×251, 65×65 and guest characters at 128×64 (2 × 64×64). Frames are sliced per asset by
`frameWidth`/`frameHeight`, and `asset-positions.json` / `asset-defaults.json` key position and
scale **by filename**. Post-processing must be driven per asset from the existing sheets.

**Camera-angle correction.** The shipped `office_bg.webp` is a **3/4 oblique** view (walls *and*
floor, ~32px tile scale, upscaled ~2×), not strictly top-down, and it carries readable third-party
signage ("CENTRAL PERK", "FRIENDS"). "No text, no logos" in generated backgrounds is therefore a
hard acceptance criterion, and the current background is disqualified as a public-repo style
reference for a second reason beyond LimeZu.

