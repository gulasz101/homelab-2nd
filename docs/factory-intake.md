# Factory intake runbook (GUL-2037 phase 5)

How one direction becomes a merged PR with two owner clicks. The engine that reads
it is `agents/factory/engine.py`; the contract is `agents/factory/ENGINE.md`,
section "Intake (`autoPickup`)".

## Give a direction

File one issue in the Paperclip "Gulasz101 Homelab" company, in the homelab-2nd
project. Top level, with no parent: the engine reads only top-level issues.
Assign it to Claude Code (the PM). Say what you want and why it matters, not how
to build it, because the how is the factory's job. One direction per issue; a
second idea gets its own issue.

## The question card

Claude Code researches the repo and the docs index, then opens one
`ask_user_questions` card with at most 6 questions, each with a recommended
answer. Answer the ones that matter and leave the rest, or reply `auto` to take
every recommendation. That is the first click.

## The spec card

Claude Code writes the work order's `spec` document (it must pass
`factory.py lint-spec`): the change, the acceptance criteria with one check
command each, and the allowed paths. It then opens a `request_confirmation` card
on that exact spec revision, with an idempotency key that starts `spec-gate:`,
target `issue_document` / `spec`, and `resolverPolicy: "human_only"`. The card is
human only, so an agent may never accept it. The work order moves to `in_review`.
Approving the card is the second click.

## After the accept

Every tick, before it steps the running orders, the engine lists the `in_review`
issues of the project and starts each one whose card a human accepted for the
spec's current revision. Three things start nothing: an accept by an agent, a
card bound to an older revision, and a rejected card. A spec that fails lint is
refused with one comment per revision, and a new revision with a new accepted
card is tried again.

The stages then run in this order: Librarian, red, green, review, verify, gate.

The gate leaves the PR to the GitHub App `gulasz101-factory` while `autoMerge` is
true in `agents/factory/engine.json`, and otherwise waits for the owner to merge
on GitHub. After the merge the engine waits for Flux to report `Ready` and
reverts the merge when the post-merge check fails.

## Engine internals

`agents/factory/engine.py` runs one launchd tick every 2 minutes (`StartInterval`
120 in `agents/factory/launchd/dev.voitech.factory-engine.plist`), with no model
and no tokens. Each order's state lives in `~/factory/engine-state/<GUL-n>.json`
and is mirrored to the issue's `engine-state` document, so the board shows the
phase without a database. Each order runs in its own git worktree under
`~/factory/worktrees/<repo>/<branch>`. At most 2 orders are active at once
(`maxActiveOrders` in `agents/factory/engine.json`); the rest wait in `queued`.

A failed stage climbs the stall ladder in `docs/factory-stall-ladder.md`, and a
final stall wakes the owner with one `[stall]` issue. A change that touches a
never path in `agents/factory/never-paths.json` is never merged by the App: it
waits for the owner.

## Watch it and stop it

Watch the work order's comments, its `engine-state` document, and Lodge at
https://lodge.voitech.dev/v3/.

To stop every order at once, create the file
`~/paperclip-agents/majster/factory/STOP` on the Air. The next tick prints
`stopped`, exits 0 and writes nothing. Delete the file to resume.
