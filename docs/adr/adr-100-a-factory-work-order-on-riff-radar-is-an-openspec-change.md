# ADR-100: A factory work order on riff_radar is an OpenSpec change

- **Status**: Proposed
- **Date**: 2026-10-29
- **Issue**: GUL-551
- **Related**: ADR-093 (the scripted factory and the owner's merge button), ADR-095 (one work order per checkout), ADR-096 (the pipeline runs on `main`), GUL-262 (the factory itself), GUL-547 (riff_radar's `check` baseline)

## Context

riff_radar moves from Wojtek's early "spec-driven" setup — one `AGENTS.md` (a symlink to
`CLAUDE.md`) telling an agent to write `<phase>`/`<task>` files into `docs/plans/` — to OpenSpec
(GUL-551). The 58 plan files are archived under `docs/archive/plans/`; behaviour now lives in
`openspec/specs/<capability>/spec.md` and work in progress lives in `openspec/changes/<change>/`.

The factory already has a different idea of "spec". A work order is a Paperclip issue whose
`spec` document ends in one fenced JSON block (`repo`, `base`, `kind`, `allowedPaths`, `acs`,
`maxDiffLines`), linted by `agents/factory/factory.py lint-spec` and graded by `check-red`,
`check-green`, `check-gate` (CONTRACT.md). Two spec systems, one repo, so the question is not
whether they merge but which one is the record of what.

They answer different questions:

- the Paperclip `spec` document is the **work order envelope**: what may be touched, how the
  stage gate measures it, how big the diff may be. It is machine-read, versioned by Paperclip,
  and never reviewed as prose.
- the OpenSpec change is the **change itself**: why, what behaviour changes, what proves it, in
  what order. It is prose a human reads, and it outlives the work order once archived.

## Decision

A factory work order against riff_radar **is** an OpenSpec change. The work order's `spec`
document points at that change; it does not restate it.

| Question | Lives in | Owned by |
|---|---|---|
| Why this work exists, what changes, what is out of scope | `openspec/changes/<change>/proposal.md` | the work order's author, reviewed in the PR |
| New/changed/removed behaviour, with scenarios | `openspec/changes/<change>/specs/<capability>/spec.md` (delta: `## ADDED` / `## MODIFIED` / `## REMOVED Requirements`) | same |
| How it will be built, when the approach is not obvious | `openspec/changes/<change>/design.md` | same |
| The ordered work items and their tick state | `openspec/changes/<change>/tasks.md` (`[ ]` → `[x]`) | red/green executors, one tick per commit |
| Repo, base branch, allowed paths, AC check commands, max diff | the Paperclip `spec` document's JSON block | the factory, `lint-spec` |
| The stage ledger (baseSha, branch, cwd, stage issue ids) | the Paperclip `ledger` document | `factory.py` only |

The change directory is `openspec/changes/<change>/`, where `<change>` is the slug in the
work order's spec. Its deltas are folded into `openspec/specs/` by `openspec archive <change>`,
which is the factory's `gate` stage, not something a work order may do to the specs by hand.

## Consequences

**What this buys.**

- The PR carries one readable story: proposal, delta, tasks. The stage briefs stay about the
  diff because the spec document already names what may be touched.
- `tasks.md` gives the red/green stages a shared, human-visible checklist whose ticks are
  committed, so "task 4 is done" is a `git show`, not a claim in a comment.
- Archiving is the moment behaviour becomes the repo's own spec, which is exactly the moment
  the work order closes. A repo without an archived change has no new baseline.

**What it costs.**

- Two files must stay in step: the change slug in the spec JSON and the directory under
  `openspec/changes/`. Nothing enforces that today (see below).
- Every work order now needs `openspec/changes/<change>/**` in `allowedPaths`, or its own
  proposal edit fails `check-green`.
- A work order that changes no behaviour (a docs or chore order) still carries a change
  directory it will archive into a delta that changes nothing. Accept it, or use `kind: docs`
  orders for those and let them skip OpenSpec entirely.

## What `lint-spec` and `CONTRACT.md` would need to change (proposal only, no code in GUL-551)

1. **A `kind: openspec`.** The five kinds (`docs`, `tests`, `manifest`, `code`, `agent-rules`)
   all describe a diff. A spec-driven change touches `openspec/changes/**` *and* the code it
   specifies, and `kind` drives the gate's expectations. Add `openspec`, refusing any work
   order whose diff has no file under `openspec/changes/`.
2. **A `change` field** in the JSON block, `<slug>`, required when `kind: openspec`.
   `lint-spec` resolves `openspec/changes/<slug>/proposal.md` in the base commit and fails the
   lint (exit 1, not 2) when it is missing — the same "the spec is wrong before any work
   starts" class as an unparseable JSON block.
3. **Auto-allowed path.** With `change` present, `openspec/changes/<slug>/**` joins
   `allowedPaths` without the author listing it. Everything else stays explicit.
4. **One reserved AC check.** Extend the AC convention so the first AC of an `openspec` order
   must be the validator:
   `npx --yes @fission-ai/openspec@1.15.0 validate <slug> --strict`. Pin the version in the
   check string: an unpinned `npx @fission-ai/openspec` turns a validator upgrade into a
   red gate on unrelated work. (A vendored `openspec` in `devDependencies` plus
   `bun run openspec -- validate` would be better; that is a repo decision, not a factory one.)
5. **`check-gate` reads `tasks.md`.** Today the gate proves the diff is small, in scope, and
   green, and that `check` passed. An `openspec` order should also refuse while
   `openspec/changes/<slug>/tasks.md` holds a `[ ]`. That is the cheap machine-readable half of
   "the change is finished"; the prose half stays the reviewer's.
6. **Never paths stay as they are.** `openspec/specs/**` is *not* a never path — `archive` edits
   it legitimately — but a gate-passing work order must not have edited it. That is an
   `allowedPaths` discipline, not a content rule: name the change directory and the code paths,
   never `openspec/specs/**`, and the existing glob check refuses the archive edit as
   out-of-scope. If that turns out to be too easy to get wrong, the stronger form is a content
   rule in `never-paths.json` (`newFilesUnder` does not fit: archive *modifies* existing spec
   files) — note it, do not build it yet.

Nothing in this ADR changes factory code. Items 1–5 are a follow-up work order; item 6 is a
reviewer habit until it bites.

## Alternatives considered

- **Keep `docs/plans/` and skip OpenSpec.** Rejected by the owner: the plans stopped matching
  the code, and 131 unchecked boxes across 58 files are neither a plan nor evidence.
- **Have the work order carry the whole OpenSpec change and drop the Paperclip `spec`.** The
  stage checks need `allowedPaths`, AC commands and `maxDiffLines` in a machine-readable block;
  parsing them out of `proposal.md` prose means the gate reads whatever the author felt like
  writing. Kept separate on purpose.
- **Have the work order carry only the Paperclip spec and generate the OpenSpec change from it.**
  Generation would produce a delta no human reviewed, which defeats the point of the delta.
- **Make `openspec/specs/**` a never path.** It would refuse `archive` itself, which is a
  legitimate end of every `openspec` order.

## When to revisit

- If `openspec archive` becomes an automatic post-merge step, item 6's discipline is moot and
  the archive should be its own stage with the specs edit in scope.
- If the factory ever supports a repo whose spec system is not OpenSpec, `kind: openspec` and
  `change` should become a repo-level factory setting rather than a per-spec field.
- If two work orders in one checkout touch the same capability's delta (ADR-095 allows one at a
  time; if that changes, conflict handling in `openspec/specs/` becomes a real problem).
