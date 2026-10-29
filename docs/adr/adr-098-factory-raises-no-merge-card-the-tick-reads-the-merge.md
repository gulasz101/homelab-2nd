# ADR-098: The factory raises no merge card; the hourly tick reads the merge on GitHub

- **Status**: Accepted
- **Date**: 2026-10-29
- **Issue**: GUL-553
- **Related**: ADR-093 (the gate and the merge button this refines), ADR-096 (the pipeline runs on the factory's own code), GUL-506 (the accepted card that merged nothing)

## Context

ADR-093 ends the pipeline with a `request_confirmation` card on the work order,
"Merge PR #N?", and the owner keeps the merge button. In practice the card was a
button that merged nothing: no agent acted on the answer. On 2026-10-28 the card
for PR #81 was accepted at 17:43Z, the run it woke died with an empty log, and the
PR sat open for 28 minutes until it was merged by hand.

Two things were wrong with it:

1. **Nothing in the pipeline read the answer.** The only code that could have
   acted on "accepted" was a general agent wake, which has no step for it.
2. **It duplicated an action the owner already takes.** The `protect-main`
   ruleset blocks a red `check`, so the merge happens on GitHub regardless. The
   card was a second, weaker copy of the same decision.

Paperclip will not let an agent park an issue `in_review` on nothing: the
disposition guard demands a live path (pending interaction, approval, human
assignee, typed participant, or a scheduled issue monitor). So "drop the card"
alone would have been refused by the platform.

## Decision

The gate raises **no card**. On a gate pass the work order goes `in_review` with:

- one comment naming the PR and telling the owner to merge it on GitHub;
- an issue monitor: `executionPolicy.monitor` with `kind: external_service`,
  `serviceName: github pull request`, `externalRef` = the PR URL, `nextCheckAt` =
  `YYYY-MM-DDTHH:MM:SSZ` (the API's regex accepts `Z`, not a `+00:00` offset),
  `maxAttempts` 72.

That monitor is the review path the guard accepts, and it is real: Paperclip's
scheduler wakes the work order's assignee (Majster) hourly.

`factory tick --apply`, which Majster already runs every hour, then reads the PR
with `gh pr view <n> --repo OWNER/REPO --json state,mergedAt,mergeCommit` and
settles each gate-passed work order:

- `MERGED` → withdraw any leftover "Merge PR #N?" card, write `merge: {state,
  sha, at}` and `outcome: merged` to the ledger, comment the merge commit, move
  the work order to `done`, clear the monitor.
- `OPEN` → one line in the sweep, monitor re-armed. Nothing else.
- `CLOSED` without a merge → `blocked`, one plain sentence, ledger `outcome:
  closed`.
- `gh` error → `merge-unknown` on the line, reason on stderr, nothing written.

Without `--apply`, `tick` stays read-only, and it never applies while the STOP
flag exists.

## Consequences

- The owner's only action is the GitHub merge. There is no second button to
  press and no card to accept, so a card on this board means something again.
- Merges are noticed within one hour, not within one click. The cost of a real
  signal is latency; the old card had no latency and no effect.
- One more `gh` call per waiting work order per sweep, using the same
  `FACTORY_GH` binary the gate already trusts and a read-only `pr view`.
- The `in_review` state now means "waiting for a human on GitHub" and the monitor
  carries the intent, so the board can be read without a comment thread.
- A PR merged and then reverted still shows `MERGED`: `state` is the fact, and a
  revert is a new work order, not a reason to keep this one open.

## Alternatives

- **Keep the card, reword it to "Merge the PR on GitHub; this card does
  nothing".** Honest, but it still asks for a click and still leaves `in_review`
  valid only because of a card nobody should press. It also needs the same tick
  work to notice the merge, so it is strictly more work for the same result.
- **Let a general agent act on the card's acceptance.** That is what failed: a
  wake with no deterministic step, an empty log, a cancelled run. Adding a step
  for it means a model in the merge path, which ADR-093 exists to avoid.
- **Merge from the pipeline.** Rejected: the owner keeps the merge button, and the
  factory's own repo rules (`protect-main`) assume a human merge.
- **No monitor, work order stays `in_progress`.** Cheaper, but Paperclip then has
  no scheduled path for the wait and its liveness classifier flags the issue as
  parked work. The monitor is the honest representation of the wait.

## When to revisit

- If Paperclip ships event subscriptions for GitHub (a PR merge webhook), replace
  the hourly poll with the event and keep everything else as is.
- If merges routinely wait longer than three days, raise `maxAttempts` or make it
  a board decision rather than a timer.
- If more than one work order waits on a merge at a time, the sweep's one `gh`
  call per work order becomes worth batching; measure before changing it.
