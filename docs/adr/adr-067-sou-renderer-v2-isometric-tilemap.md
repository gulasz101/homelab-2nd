# ADR-067 — SOU renderer v2: an engine-native isometric tilemap (Phaser 4)

- **Status:** Accepted (2026-10-16, operator-directed; implementation begins on branch `sou-renderer-v2`)
- **Supersedes:** the screen-space scene layout of SOU-88 (`frontend/nav.js`) and the
  room-pack "suppress the upstream furniture" architecture of SOU-115/SOU-120.
- **Amends:** ADR-065 (geometry declared, not generated) — the declared lattice becomes an
  engine tilemap instead of a Pillow drawing.
- **Related:** ADR-060 (rooms + art licensing), ADR-061 (SOU product definition and invariants),
  ADR-064 (room shell vs engine furniture).
- **Ticket:** SOU-122 (epic), SOU-123..SOU-128 (steps).

## Context

SOU shipped a scene that is drawn by hand-placed sprites. Measured, verified defects — not
opinions:

1. **Coordinates are screen pixels, so nobody can check them.** `frontend/index.html` places
   every object with hardcoded `game.add.sprite(x, y, texture)` and hardcoded depths
   (`setDepth(5)`, `10`, `20`, `99`, `1001`, `1100`, `2000`, `2600`, `2700`, `999999`). A prop
   sits where it sits because someone typed a number. There is no lattice under it, so
   "does this object sit on the floor" is an opinion, and the class of defect the operator
   keeps finding — an object that looks plausible but is not in the room plane — is
   unfalsifiable by construction.
2. **`frontend/nav.js` models a walkable grid in *screen* space** (`cell: 16`, a horizontal
   `floor` band `top: 612 / bottom: 820`, and furniture `footprints` in pixels "measured off
   the render"), explicitly because the art is a front-facing illustration with no walkable
   floor plane. Pathing, anchoring and collision all inherit that approximation.
3. **The room pack fights the upstream scene.** SOU-115/120 exist because a generated room
   has to *suppress* ~40 upstream objects that the loader does not own
   (`UPSTREAM_FURNITURE_KEYS`, a two-path fallback, and a black-background regression when the
   pack goes active). That is an entire defect class created by rendering a new room *on top
   of* the old one instead of replacing the scene.
4. **The engine is used as a sprite blitter.** Phaser is imported for `add.sprite` and
   `physics.add.sprite`; none of the machinery that makes a 2D engine worth using — tilemaps,
   tile collision, object layers, camera culling, scene lifecycle — is used.

Meanwhile the *data* layer is already correct: `scripts/room_geometry.py` declares the
projection, the tile vectors, the wall planes and the light vector, and
`profiles/rooms/<id>_room.json` declares every prop in **grid coordinates** with its `grid:
[gx, gy]`, measured size in tiles and real-world size in metres. The gap is only that this
declared lattice is rendered by Pillow instead of being handed to the engine.

### The fact that makes this cheap (verified, not assumed)

Phaser's native isometric projection is *identical* to the lattice this repo already declared.
From the Phaser source (`src/tilemaps/components/IsometricTileToWorldXY.js`, read at commit
`02d8931b626d9764c133cbb3fbf99966c03c757c`):

```js
var x = layerWorldX + (tileX - tileY) * (tileWidth / 2);
var y = layerWorldY + (tileX + tileY) * (tileHeight / 2);
```

against `room.json`:

```
screen(gx, gy) = (ox + (gx - gy) * tw / 2, oy + (gx + gy) * th / 2)   // tw 96, th 55, slope 0.573
```

Same formula, same 30° true-isometric geometry (ADR-065). Therefore the declared geometry and
every generated room pack become a **native engine tilemap with no re-derivation**, positions
become engine-checkable numbers, and the published pack stays valid.

## Decision

1. **Phaser 4 becomes the renderer for the v2 scene.** Pin `phaser@4.2.1`, vendored like the
   current 3.80.1 build (`frontend/static/vendor/phaser-4.2.1.min.js`). Rationale: the scene is
   being rewritten anyway, Phaser 4 is the current major (npm `latest`), and the first-party
   guidance is v4-only — the 28 official Phaser skills (vendored into this repo at
   `.opencode/skills/phaser-*`, see below) and the API reference indexed into the docs MCP
   server (`phaser` 4.0.0). Invariant 1 of ADR-061 holds: Phaser stays, the renderer changes.
   Every API v2 depends on must be exercised by a real run against 4.2.1 before it is trusted;
   a documented fallback is to pin 4.0.0 (the version whose docs are indexed).

2. **A room is a Tiled-compatible isometric tilemap, generated from the declarative room
   profile.** One input (`profiles/rooms/<id>_room.json`), one generator
   (`scripts/gen_iso_room.py` + `scripts/iso_lattice.py`), two outputs:
   - `<id>/room.map.json` — Tiled-format map, `orientation: "isometric"`, `tilewidth: 96`,
     `tileheight: 55`, with tile layers `floor`, `walls`, `collision`;
   - `<id>/room.json` v2 — the descriptor: canvas, lattice, `props[]`, `anchors[]`, `zones[]`,
     `doors[]`, `rooms[]`, **all in grid coordinates**.

   The map carries tile layers only; the descriptor carries placement. Both come from one input
   in one run, so they cannot disagree. `TilemapLayer` (never `TilemapGPULayer`, which is
   orthographic-only and cannot render isometric maps).

3. **Tile coordinates are the only coordinates.** Anchors, props, walls, zones and doors are
   declared in `(gx, gy)`; screen pixels are produced by the engine (`layer.tileToWorldXY`).
   No measured screen-space number is stored anywhere in the v2 data path. This is the
   mechanism that retires defect class (1) and (2) above.

4. **Movement is grid pathing, not screen-space footprints.** Walkability is a `collision`
   tile layer; the character walks an A\* path over it and every step is asserted walkable
   before it is taken. Obstacle avoidance is therefore a property of the map, and adding an
   obstacle is a data edit. Arcade physics is **not** used for walls: its bodies are AABBs in
   screen space, which is the wrong geometry for an isometric floor and would put colliders in
   the wrong place at the two diamond edges. Grid pathing is exact and deterministic;
   `check_*` tooling can verify a path the same way it verifies a prop.

5. **Depth is painter's algorithm on the lattice.** `depth = f(gx + gy)` for characters and
   floor-standing props (the same `+ depth_offset` escape hatch for multi-tile objects like the
   rack). This replaces the ~10 magic `setDepth` constants with one rule.

6. **Asset contract v3 adds orientation.** A pixel-art prop cannot be rotated freely — rotating
   a rendered sprite by an arbitrary angle resamples it and destroys the pixel grid. Objects
   therefore declare `variant` ∈ `{se, sw, ne, nw}` (the four lattice quadrants, matching the
   diamond's four faces) plus `flipX` (a mirror is pixel-exact and free). The generator renders
   each prop once per *orientation actually used*, not four times speculatively.

7. **The character is driven by tool-call category, through data.** `activity_map.json` maps an
   event (event_type + tool/payload family) → `{zone, activity, animation, dwell_ms}`;
   `zones` come from the room descriptor. Idle (no events for N seconds) resolves to the rest
   zone and cycles through "alive" micro-behaviours. The mapping is data, in the repo, with
   tests — not `if` chains in the renderer (ADR-061 invariant 3: adding an agent is an adapter,
   never a renderer edit).

8. **v1 keeps serving until v2 passes its acceptance criteria**, then is deleted in its own
   step (SOU-128). The room-pack suppression path, `frontend/nav.js`, and the hand-placed
   upstream furniture are removed at that point, not before — the operator must be able to
   open both.

9. **First-party Phaser skills are vendored into the repo** at `.opencode/skills/phaser-*/`
   (28 skills + 8 reference files, upstream `phaserjs/phaser@skills`, MIT). OpenCode loads
   project-local skills from `.opencode/skills/<name>/SKILL.md` (verified against
   `opencode.ai/docs/skills`), so the t460 worker gets engine-accurate instructions with the
   checkout, and a human or agent reading the repo gets them without a network call. They are a
   vendored copy, refreshed deliberately, not a submodule.

## Consequences

- **Superseded work.** SOU-120 (patch the black background when the pack goes active) and the
  suppression half of SOU-115 are retired by construction: in v2 the scene *is* the room, so
  there is nothing to suppress and no fallback path to keep consistent. Parts of SOU-113/114
  (prop scaling, footprint shadows) survive as descriptor fields; the measured-screen-pixel
  parts do not.
- **The Pillow preview stops being the deliverable.** `scripts/finish_room_props.py` remains a
  diagnostic (it proved prop alignment), but it is no longer what the operator looks at. The
  app is. (This repo has already burned a day on a preview that the running app never loaded —
  see the SOU-104 notes.)
- **The art budget changes shape.** Floors and walls are *drawn* by the generator as exact
  rhombi and wall quads (deterministic, free, perfect alignment). Generation supplies
  **objects only**: props and characters. Assets are judged per tile/per prop, which is the
  smaller unit the operator asked for.
- **Docs MCP gains `phaser` (4.0.0 API reference, 708 pages) and `tiled`** (map format), so
  both the orchestrator and the worker can look up an API shape instead of guessing one.
  Upstream's `/phaser/concepts/*` guide section is listed in the sitemap but returns 404 — it
  does not exist, and the indexing job for it failed correctly. The guide role is filled by the
  vendored official skills.
- **One room first.** The first v2 room is the homelab office: desk (work), server rack
  (commands), library shelf (reading/search), sofa (resting), coffee (waiting), door
  (session start/end). The loader is written N-agent-ready (roster-driven), but exactly one
  character is rendered until the room and the mapping are proven.

## Open questions (operator ruling wanted; defaults are implemented meanwhile)

1. **Does "rotate" mean four discrete facings?** Default: yes — `{se,sw,ne,nw}` + mirror,
   because free rotation of pixel art is not viable. Cost if wrong: props render in one
   orientation until the variant pipeline exists, so a second orientation is a re-generation.
2. **Do the walls get generated art?** Default: v2 draws walls as exact quads (lattice-correct
   by construction) and generation supplies a wall/floor *texture* applied inside those quads
   later, so the AI never owns the silhouette.

## Verification plan

| Claim | How it is checked |
|---|---|
| The generated map is a valid isometric Tiled map | schema + `orientation`/`tilewidth`/`tileheight` assertions in `backend/tests/`-style pytest, plus opening it in Tiled |
| Python lattice == Phaser lattice | a node test that boots the vendored Phaser 4 build, calls `map.tileToWorldXY()` for several tiles and compares to the Python-produced numbers |
| Every anchor is walkable | pytest over the descriptor: resolve each anchor to a collision-layer cell, assert walkable or explicitly exempt |
| The scene renders the room (not a preview) | browser screenshot of the running app on the Mac dev instance, plus a grep proving the running page references the v2 bundle |
| The character walks without entering obstacles | path assertion + timed screenshots across a zone transition |
| An activity changes where the character is | POST a real event to the running backend, capture the zone change |
