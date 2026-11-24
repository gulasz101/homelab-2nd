# Factory intake runbook (GUL-2037 phase 5)

How one direction becomes a merged PR with two owner clicks. Contract:
`agents/factory/ENGINE.md`, section "Intake (`autoPickup`)".

## Give a direction

File one issue in the Paperclip "Gulasz101 Homelab" company, homelab-2nd project,
and assign it to Claude Code (the PM). Say what you want and why it matters, not
how to build it: the how is the factory's job. One direction per issue, and a
second idea gets its own issue.

## The question card

Claude Code researches the repo and the docs index, then opens one question card
with at most 6 questions, each carrying a recommended answer. Answer the ones
that matter and leave the rest, or reply `auto` to take every recommendation.
That is the first click.

## The spec card

Claude Code writes the work order's `spec` document: the change, the acceptance
criteria with a check command each, and the allowed paths. It then opens a
`request_confirmation` card bound to that exact spec revision, with an
idempotency key that starts `spec-gate:`. The card is human only, so an agent may
never accept it. The work order moves to `in_review`. Approving that card is the
second click.

## After the accept

The engine starts the work order only when a human accepted the card and the
card's revision is the spec's current revision. An accept by an agent, a card for
an older revision, and a rejected card all start nothing. Once accepted, the
stages run in this order: Librarian, red, green, review, verify, gate.

The gate leaves the PR to the GitHub App `gulasz101-factory` when `autoMerge` is
true in `agents/factory/engine.json`, and otherwise waits for the owner to merge
on GitHub. After the merge the engine waits for Flux to report `Ready` and
reverts the merge if the check fails.

## Engine internals

`agents/factory/engine.py` runs one launchd tick every 2 minutes, with no model
and no tokens. Each order's state lives in `~/factory/engine-state/<GUL-n>.json`
and is mirrored to the issue's `engine-state` document, so the board shows the
phase without a database. Each order runs in its own git worktree under
`~/factory/worktrees/`. At most 2 orders are active at once (`maxActiveOrders` in
`agents/factory/engine.json`); the rest wait in `queued`.

A failed stage goes up the stall ladder in `docs/factory-stall-ladder.md`, and a
final stall wakes the owner with one `[stall]` issue. A change that touches a
never-path is never merged by the App: it waits for the owner.

## Watch it and stop it

Watch the work order's comments, the issue's `engine-state` document, and the
Lodge at https://lodge.voitech.dev/v3/.

To stop every order at once, create the file
`~/paperclip-agents/majster/factory/STOP` on the Air. The next tick prints
`stopped`, exits 0 and writes nothing. Delete the file to resume.
