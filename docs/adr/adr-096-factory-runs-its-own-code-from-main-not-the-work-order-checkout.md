# ADR-096: The factory runs its own code from a checkout of main, never from the work order's checkout

- **Status**: Accepted
- **Date**: 2026-10-28
- **Issue**: GUL-502
- **Related**: ADR-093 (Pi-only code factory, scripted gates), ADR-095 (one work order per checkout)

## Context

`start` cuts the work order's branch (`gul-<N>-<slug>`) in the factory checkout at the
spec's `baseSha` and stores that path in the ledger as `cwd`. Every stage check then runs
against that working tree: `check-red`/`check-green` diff it, `commit` commits in it,
`open-pr` pushes its branch. That is correct — the diff is the deliverable.

But the agents were also told to run the *script* from the same checkout
(`python3 -I {{cwd}}/agents/factory/factory.py decide …`). So the code that decided a
stage was frozen at `baseSha` for the life of the work order, while the script's own
fixes were landing on `main`. On 28 Oct that produced a run where every fix merged that
day was inert: `decide` still called the pre-GUL-496 client, patched the gate `done`,
then died on `409 Document update requires baseRevisionId` — a fix that had been on
`main` for hours. Two issues were closed as done and both kept reproducing, because
"fixed on main" was never where the factory looked.

## Decision

The factory's code and the work order's tree are separated.

- The script runs from a **tooling checkout** — `/Users/paperclip/factory/tooling`, a
  plain clone of `homelab-2nd` that is force-moved to `refs/remotes/origin/main` before
  every call (fetch, then `checkout --detach origin/main`). No branch, no local commits,
  no drift.
- All three Paperclip subcommands go through one wrapper,
  `agents/factory/factory-run.sh`, installed as `~/.local/bin/factory` and
  `/Users/paperclip/factory/bin/factory`. Stage templates and the Foreman brief name the
  wrapper; the fallback "run the copy in the checkout" instruction is gone.
- The work order's checkout stays the *data*: `decide` still takes `cwd` from the ledger
  and checks run there. Nothing about the diff changes.
- A refresh that fails is exit 2, loudly. A missing or dirty tooling checkout is exit 2
  with the fix in the message. Running a stale copy is never the quiet fallback.
- `start` refuses a `cwd` that resolves to the tooling checkout itself, because a branch
  cut there would be moved off it by the next invocation.

## Consequences

- A fix merged to `main` is the code that decides the very next stage. No restart, no
  pull, no re-cut of a work order branch.
- The factory now needs `origin` reachable at `decide` time (as `start` already did). An
  offline host fails the stage with exit 2 instead of silently deciding with old code —
  the failure is visible in the JSON line and the operator can act on it.
- Deciding code is one identifiable thing: `git -C /Users/paperclip/factory/tooling log -1`
  says exactly what decided. The wrapper prints that short SHA on stderr on every call.
- A work order can no longer be used to test the factory's own script changes; those go
  through a PR and `main`, then take effect immediately — which is the point.

## Alternatives considered

- **Refresh the work order's checkout to `main` before each `decide`.** Rejected: that
  checkout must stay on the work order's branch, because every check diffs its working
  tree and its commits. Switching it to `main` would make the checks look at the wrong
  tree — the fix would break the factory to fix the factory.
- **`git archive origin/main agents/factory` into a temp dir per call.** Equivalent
  freshness, but throws the copy away: nothing to read, `git log`, or run the tests
  against when a stage decision looks wrong. The clone costs one directory and gives a
  debuggable object.
- **A launchd timer that pulls the tooling copy every N minutes.** Reintroduces the same
  class of bug — fixes arrive late and silently, and the delay is invisible in the run.
- **Let the stage agent choose which copy to run.** A model deciding which code judges it
  is the thing ADR-093 exists to prevent.

## When to revisit

- If Paperclip's isolated per-issue workspaces are switched on (ADR-095's revisit
  trigger), re-check that the tooling checkout is still outside any task workspace.
- If the factory ever moves off this Mac, the tooling path and the wrapper's install
  location are bootstrap steps for the new host.
- If `decide` starts needing the tooling checkout to hold generated state (it must not),
  this split stops being clean.
