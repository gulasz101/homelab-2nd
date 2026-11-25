# The factory engine owns the work-order state, runs with no model, and merges its own PRs

- **Status**: Pending
- **Date**: 2026-11-25
- **Issue**: GUL-2037 (plan approved by the owner 2026-11-22, revision 7; built and burned in 2026-11-22 to 2026-11-25)
- **Related**: ADR-093 (Pi-only code factory: this replaces its decisions on who merges, who runs the tick, and the Reviewer model), ADR-095 (one work order per checkout: superseded), ADR-101 (the tick reads the merge on GitHub: superseded for the engine), ADR-085 (Hindsight on FreeLLMAPI: retain and consolidation move off it), keel-v2 (https://github.com/MiladNalbandi/keel-v2, the model for this design)

## Context

Three weeks after ADR-093 the factory ran, but nothing finished without a human. It had 34 work
orders since 2026-10-28: 14 merged, 6 escalated. On 2026-11-22, 20 issues were `blocked`, and most
of them waited on each other or on the PM's 05:30 round, not on real work. The causes, each seen
on a real order:

1. **Paperclip blockers were the state machine.** Every order made a pre-made chain of 5 `blocked`
   stage issues. Every Paperclip trap hit it: the cancel order, 409s, a cancelled stage waking a fix
   round, recovery holds (GUL-1387, GUL-1758, GUL-1943, GUL-1792).
2. **One shared checkout** (ADR-095). GUL-1937 and GUL-2016 waited on GUL-1993 only for the checkout.
3. **Escalation meant waiting for 05:30.** GUL-2026 and GUL-1993 hit their third request-changes and
   sat until the next day.
4. **A wrong frozen test killed the order.** GUL-2026's red test needed an `--ac` argument that
   `scripts/check.sh` never passes. Green may not touch tests, so it failed 3 times, and nothing in
   the factory could say "the test is wrong".
5. **An LLM did the mechanical work.** Majster (DeepSeek) ran `factory decide/tick`, which cost
   tokens and failed in silly ways.
6. **Every PR waited for the owner's merge**, even a 4-line config change.
7. **The Reviewer used the same model family as the Builder**, so review found little.
8. **Agents started from zero.** Memory and docs were a rule in AGENTS.md that a cheap model skips.

The owner's direction: he gives a direction, answers the questions, approves the spec, and the work
gets done. Agents test, review and approve on their own unless something is critical.

## Decision

### 1. The engine owns the state; agents only write and judge

`agents/factory/engine.py` (contract in `agents/factory/ENGINE.md`) keeps one JSON state file per
work order in `~/factory/engine-state/`. Paperclip is only where agents get their task. A stage
issue is created when its stage starts, never before, and **no stage issue is ever `blocked`**. A
failed attempt is a new issue; the old one is unassigned first, so Paperclip cannot wake it again.

### 2. A supervisor with no model

The tick runs every 2 minutes from the system LaunchDaemon `dev.voitech.factory-engine` (user
`paperclip`, `~/factory/engine-runner/loop.sh`). A LaunchAgent cannot work on this Air: it sits at
the login window, so there is no `gui/501` domain. Before each tick the loop moves its checkout to
the newest `origin/main` (clean checkout only), so a merged engine PR goes live with no restart. The
loop uses its own temp folder (`~/factory/engine-state/tmp`), not a Paperclip run's, because
Paperclip deletes a run's temp folder when the run ends (GUL-2089). Majster is retired (paused, not
deleted).

### 3. One git worktree per work order, max 2 at once

Each order gets `~/factory/worktrees/homelab-2nd/<branch>` and its own Paperclip project workspace,
so its agents start inside it. A missing worktree stops the order as `ENV` and uses no attempt. The
worktree is deleted when the order ends. `maxActiveOrders` is 2, because of the Go model rate limits
and the Claude subscription limit the Reviewer shares with the PM.

### 4. Two human touch points

The PM opens one question card (max 6 questions, each with a recommended answer), then writes the
`spec` document and a `request_confirmation` card bound to that spec revision (`human_only`). The
engine starts the order on its next tick when **a user** accepts the card **for the current
revision** (`autoPickup`). An agent's accept, or an accept for an old revision, starts nothing.
The spec is frozen at start and changes only through an `AMEND:` block.

### 5. The knowledge steps are engine steps

- Before every stage the engine recalls from Hindsight (the repo bank `coding-agent::homelab-2nd`
  plus `hermes-andrzej`, read only) and puts the result at the top of the prompt. After the order it
  saves the lessons in one retain call, not one per stage.
- A **Librarian** stage runs first. A script reads the lockfiles and checks docs-mcp; if every
  library is indexed at our version, the engine writes the `docs-ready` note itself and no model
  runs. Otherwise the Librarian indexes what is missing (20-minute limit; "no docs: <reason>" passes).
- Every agent keeps its own Hindsight bank; nothing is moved. Hermes agents read the factory bank
  through `recall_additional_banks`. Hindsight retain and consolidation run on `beam-ollama` through
  LiteLLM, with a fallback to FreeLLMAPI `auto`.

### 6. A stall ladder instead of escalation

When a stage fails all its attempts: a read-only **Investigator** (`deepseek-v4-pro-ollama`) reads
the attempts and gives one verdict.
- `TEST-WRONG` (no PR yet): green's leftovers go to a stash, red rewrites the tests, green runs again.
- `CODE-WRONG`: one more attempt on Builder Pro, with the Investigator's advice.
- `SPEC-WRONG` or `ENV`: the order stops and wakes the PM, with a proposed `AMEND:` block. No model
  changes the frozen spec. If the only fix is in a frozen test file, the verdict is `SPEC-WRONG`.
- Max 2 investigations per order, then one `[stall]` issue for the PM, max 3 PM wakes a day.
- The same failure twice adds "SAME FAILURE, find a different cause" to the next prompt. Every `FAIL`
  line of the check (max 200) reaches the next attempt and the Investigator.

### 7. Test paths stay frozen, with one named exception

Red may change only test paths; green may change only non-test paths. A spec may list
`builderTestPaths`: test files that are product code (for example a check script whose own selftest
is the AC check). Green may change them, red may not, and no AC check may name them. `lint-spec`
refuses a spec where every allowed path is a test path.

### 8. Models

| stage | agent / model |
|---|---|
| Librarian, Tester (red), Builder (green) | Pi, `deepseek-v4.1-flash-go` |
| Reviewer | `claude_local`, `claude-sonnet-5-5`; on a usage limit the rest of the order goes to Pi on `glm-5.3-flash-go`, and the PR body says so |
| Verifier | Pi, `glm-5.3-flash-go` |
| Investigator, Builder Pro | `deepseek-v4-pro-ollama` (the `-go` model was switched off in the OpenCode Go console) |
| Supervisor | no model |

No Opus inside the factory. The PM (Opus) plans, writes specs, takes the last stall step and reviews
what merged.

### 9. The factory merges its own PRs, and GitHub enforces the limits

- The engine squash-merges as the GitHub App `gulasz101-factory` when the gate and CI `check` pass and
  the diff touches no never-path (`agents/factory/never-paths.json`). It merges only the head the
  stages checked (`--match-head-commit`) and lists every self-approval in a PR comment.
- When `main` moved, the engine presses "Update branch" itself (max 3 times) and merges only if the
  new head is the checked head plus a commit of `main` and CI passes again.
- The App token is scoped to the order's one repo. The App has no Workflows permission.
- The ruleset `protect-main` requires `check`, a PR, and code-owner review. `CODEOWNERS` makes the
  owner the owner of every never-path, `.github/` and `docs/adr/`, so GitHub itself refuses the App
  on those paths. The owner may bypass only inside a PR. A never-path PR is not a gate failure: it
  waits for the owner with a SAFETY note.
- The App key is a mode-600 file on the Air (`FACTORY_GH_APP_KEY_FILE`). The keychain is not used: a
  daemon outside the login session sees only the System keychain.

### 10. A merge is a deploy, so the engine checks it

After the merge the order goes to `deploy_check`: the engine waits until every Flux Kustomization is
`Ready` on the merge commit (max 30 minutes) and runs the spec's optional `liveChecks`. If Flux fails
on the merge or a live check fails, the engine opens and merges a revert PR as the App and wakes the
PM. A Kustomization that was already broken before the merge never causes a revert.

### 11. Org chart

The owner has three direct reports, as peers: Bill Cipher (CEO), Claude Code (CPTO: product and
tech, owns the factory and the coding engineers) and Andrzej (Ops, not CTO: cluster, hosts,
break-glass, failures the factory cannot fix). Every agent posts to the Lodge under its own name.

## Consequences

**Burn-in result (2026-11-24 to 2026-11-25):** 4 of 4 real orders merged by the App with no human
step after the spec: GUL-2166 (PR #313), GUL-2165 (#312), GUL-2167 (#314), GUL-2205 (#316). Only 2 of
them ran clean. GUL-2167 needed an `AMEND:` to an AC that already passed on `main`, and GUL-2164 had
to be filed again as GUL-2205 because its fix lived in a test file. Both were faults in the PM's
specs, not in the agents' work. The Investigator found both causes with no human. The intake test
(GUL-2147) went from 2 owner clicks to a merge.

Good:
- An order no longer waits for 05:30 or for another order's checkout.
- A wrong test or a wrong spec is found and named by the factory, not by the owner.
- The owner merges only never-path PRs; GitHub enforces that even if the engine has a bug.

Bad, and watched:
- The engine's full check runs on the Air, CI runs on Linux. A test that depends on `$HOME` or a host
  path passes every stage and fails only in CI (GUL-2147). The red prompt now forbids that.
- Model calls go through `https://llm.voitech.dev` (Cloudflare, owner's choice). A call over 120 s
  dies with a 524. Paperclip retries the run and no attempt is used, so it costs time only.
- The Pi agents load the guard from a copy outside the repo. It fell behind `main` and the daily
  self-test stopped the engine (2026-11-25). Follow-up work order.
- `lint-spec` does not yet refuse an AC that already passes on `main`. Follow-up work order.
- Not seen live yet: the glm fallback on a real Sonnet limit (seen once, but blocked by an engine bug
  since fixed), a never-path order waiting for the owner, a real revert after a bad deploy, and the
  50-retains check on `beam-ollama`.
- The Reviewer shares the Claude subscription limit with the PM.

## What this supersedes

- **ADR-095** in full: one worktree per order replaces one order per checkout.
- **ADR-101** for orders the engine runs: the engine merges and reads the merge itself; there is no
  merge card.
- **ADR-093**: point "Wojtek merges" now holds only for never-paths and the point 6 "never" list
  (kept, and now enforced by GitHub); Majster's tick is replaced by the model-free supervisor; the
  Reviewer moves from Pi/DeepSeek to Sonnet. The scripted gates (`lint-spec`, `check-*`) and the
  never-paths stay as ADR-093 set them.
- The old orchestration in `factory.py` (`start`, `decide`, `tick`) is no longer used. Removing it is
  a separate work order.

## Alternatives considered

- **Keep Paperclip blockers as the engine and patch each trap.** Three weeks of patches (CONTRACT.md
  point 9) did not stop the blocking; each Paperclip change found a new trap.
- **Port keel-v2 as it is (LangGraph + SQLite, VS Code extension, MCP gateway).** Too much we don't
  need. We took its 8 ideas (run modes, two touch points, frozen spec with AMEND, stall ladder,
  failure fingerprint, worktree per order, one state store, loop guard) and kept our own checks.
- **Opus inside the factory** for review or the stall ladder. It would eat the PM's limit; Sonnet for
  review and a pro DeepSeek for the ladder were enough in burn-in.
- **Turn off "branch must be up to date" in the ruleset** so the App can merge an older PR. Rejected:
  updating the branch and re-running CI tests the change against the newest `main`.
- **Point Pi at LiteLLM over the LAN** to avoid the 524. The owner chose to keep llmhub.

## When to revisit

- Raise `maxActiveOrders` after one clean week of normal work.
- `riff_radar` joins the engine (decision 10 of the plan) after this ADR is adopted.
- If the glm fallback or the post-merge revert fails the first time it runs for real.
- If Paperclip adds a state model that makes its own blockers safe to drive an engine with.
