# ADR-065: Rooms declare their geometry; objects are generated in that projection and gated by measurement

**Date:** 2026-10-15
**Status:** Accepted
**Deciders:** akadmin (Supreme Leader), Szarik
**Project:** SOU (Star-Office-UI fork)
**Related:** ADR-064 (scene composition: shell vs engine furniture), ADR-060 (spatial redesign + art licensing), ADR-061 (product definition)

## Context

The operator's complaint was that furniture does not "follow the walls or geometry" — assets
sit on a dark background rather than standing in a room. Two investigations produced the
actual cause, and it is not placement.

**1. A generated backdrop has no measurable geometry.** Probing the generated shell:
grout spacing along scanlines measured 50, 42, 34, 62, 53 and 77.5 px, and two grout lines
*in the same image* sloped at 0.241 and 0.450 px/row against a true 2:1 value of 0.500.
Diffusion produces something that looks locally plausible and is globally inconsistent, so
there is no lattice to align to and no amount of tuning converges.

**2. The upstream furniture is drawn in a different projection than any isometric floor.**
Placing the real props on a mathematically exact 2:1 lattice and measuring base slopes:

| prop | base slope (left / right) | lattice needs |
|---|---|---|
| desk generated *in* the declared projection | +0.576 / −0.584 | ±0.500 |
| upstream `desk-v3` | **+0.003 / −0.007** | ±0.500 |
| upstream `sofa-idle-v3` | +1.043 / −1.147 | ±0.500 |

The upstream desk's base is horizontal: a front-facing drawing. **No placement can align it**,
which also means "reuse the upstream furniture in the new rooms" is a dead end by
construction, not a tuning problem.

**3. The projection we ask for is not always the projection we get.** Prompted with
"TRUE 2:1 ISOMETRIC … 26.57 degrees … 2 pixels across for every 1 pixel down", the model
returned slope 0.577 — the classic 30° isometric. Close, consistent, and not what was asked.

## Decision

1. **Geometry is declared in code and drawn, never inferred from generated pixels.** The room
   is a data structure: canvas, floor origin, tile vectors, grid extents, wall seam and wall
   planes (`scripts/room_geometry.py`, `ROOM`). The floor is *drawn* as exact rhombi.
2. **Placement is arithmetic on that lattice, not tuned coordinates.**
   `screen(gx, gy) = (origin + (gx − gy)·TILE_W/2, origin + (gx + gy)·TILE_H/2)`. Every object
   is anchored to a grid cell, so "follows the floor" is a property of the formula.
3. **Objects are generated per room, IN the room's declared projection** — the projection is
   stated numerically in the prompt (angle and pixel ratio), because the word "isometric"
   alone is not a specification.
4. **Alignment is a gate, not an opinion.** `scripts/check_prop_alignment.py` measures a
   prop's base-edge slopes against the declared lattice and fails on a projection mismatch
   (tolerance 0.12). A prop that fails does not enter a room.
5. **Declare the lattice at the angle the art reliably reproduces.** The generator reliably
   returns ~30° (0.577), so the room declares that and the tolerance absorbs the rest; asking
   for 26.57° and silently accepting 30° would poison every anchor downstream.
6. **Wall-mounted objects belong to a wall plane, not the floor grid** — they anchor to the
   wall seam, so the contract has two anchor types from the start (floor cell, wall line).
7. **Phaser is unaffected and remains the renderer.** It draws sprites at coordinates and
   depth-sorts by y; the previously missing piece was the coordinate system, not engine
   capability.

## Consequences

**Positive.** The class of defect the operator reported becomes impossible to introduce
silently: a prop from the wrong projection fails a measurable gate. Room layouts become data,
which is a precondition for ADR-064's "one room per agent" — each agent's furniture set is
generated for its own room instead of being borrowed from upstream. Placement can be checked
without a browser.

**Negative / costs.** Every room's furniture must be generated rather than reused, so the art
cost scales with room count, and each generated prop carries the usual provenance manifest.
A room's lattice is coupled to the projection its art was generated in — changing the
projection invalidates the room's furniture set, which is deliberate and checkable.

**Open.** Whether to standardise on the model's natural 30° isometric (zero skew work, slightly
unusual for pixel art) or to force 2:1 by skewing generated art by 1.0/1.155 (conventional
look, one extra lossy resample). Not blocking: the lattice is a declaration either way.
