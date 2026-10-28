# ADR-095: One factory work order per checkout until Paperclip's isolated workspaces are switched on

- **Status**: Accepted
- **Date**: 2026-10-28
- **Issue**: GUL-439 (factory phase 2, ADR-093 decision 2)
- **Related**: ADR-093 (Pi-only code factory with scripted gates)

## Context

The factory cuts a branch, writes a failing test, fixes it, opens a PR and then
gates the merge — all in one working tree, decided by `agents/factory/factory.py`.
Two work orders alive at once in the same checkout would mix their diffs: `check-red`
and `check-green` compare the *working tree* against a recorded SHA, so a second
order's uncommitted files would appear in the first order's diff and both checks
would lie.

Paperclip supports the right answer: an `isolated_workspace` execution workspace
with a `git_worktree` strategy — one worktree and one branch per task, cut from
the project's checkout at admission, cleaned up when the task closes. Children
inherit their parent's workspace automatically, which is exactly what the stage
chain needs, and `pi_local` is a git-sensitive adapter that runs correctly in one.

It is not available on this instance:

- the feature is gated on the instance experimental flag `enableIsolatedWorkspaces`
  (`heartbeat.ts`); with it off, per-issue workspace settings are discarded and the
  project policy is nulled by `gateProjectExecutionWorkspacePolicy`, so a project
  policy is silently ignored and every run of the project lands in the single
  shared checkout;
- the live value is `instance_settings.experimental = {}` → off. Turning it on is a
  board/instance-admin action, not something an agent key can do (`403 Board access
  required`), and it is an experimental switch on a running company.

## Decision

Until that flag is on, the factory runs **one work order at a time**. `factory
start` refuses while another work order (open issue with a `spec` document,
assigned to Majster) is open in the same project, and says why. One checkout, one
diff, no second branch in the same tree.

We do not build a worktree manager of our own: no `git worktree` bookkeeping, no
per-order directories, no branch registry. The checkout decision lives in one
function (`work_order_cwd()`) and one guard (`open_work_orders()`), both in
`agents/factory/factory.py`.

## Consequences

- Throughput is one work order per project at a time. Acceptable: a work order is
  a full red/green/review/verify/gate cycle that ends in a human merge, and the
  merge is the real bottleneck.
- No risk of one work order's diff leaking into another's checks — the reason the
  rule exists.
- The stage agents keep working in the shared checkout, so the "shared workspace
  is branch-switched by another run" hazard (GUL-424) remains for everything
  outside the factory. The factory itself no longer contributes to it.
- When the flag is flipped, the change is small and local: read the work order's
  execution workspace `cwd`, drop the one-at-a-time guard, and the stage children
  inherit the parent's worktree for free.

## Alternatives considered

- **Turn the experimental flag on now.** It is Wojtek's call on a live company and
  the feature is experimental; the factory has no work orders yet, so nothing is
  lost by waiting.
- **A worktree manager in the script.** A second implementation of a thing
  Paperclip already does, with its own cleanup bugs, branch ownership and
  concurrency; explicitly ruled out in GUL-439.
- **Per-issue typed workspace selection.** Present on the installed server's HEAD
  but not on the running build (`issues.workspace_selection` does not exist in the
  live database), so it cannot be relied on yet.
- **Copy the repo per work order.** Diffs would still be correct, but nothing would
  clean up, and CI `gh` calls would see a repo without a shared remote state.

## When to revisit

When `enableIsolatedWorkspaces` is turned on and the "Code Factory" project
carries `executionWorkspacePolicy {enabled: true, defaultMode: "isolated_workspace",
workspaceStrategy: {type: "git_worktree"}}`. Re-run `factory start` against two
scratch work orders and confirm two different `cwd`s; then delete the
one-at-a-time guard.
