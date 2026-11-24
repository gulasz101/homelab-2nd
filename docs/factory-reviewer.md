# Factory reviewer runbook (GUL-2037 phase 4)

Who reviews a factory diff, what keeps that reviewer from writing anything, and
what happens when the Anthropic subscription hits its limit.
Contract: `agents/factory/ENGINE.md`; stage config: `agents/factory/engine.json`.

## Who reviews

The review stage runs the agent **Reviewer Sonnet**: adapter `claude_local`,
model `claude-sonnet-5-5`, engine `acp`, Anthropic subscription. It reads the
whole diff against the spec and writes the `findings` document; an empty list is
a legal verdict. The Builder that produced the diff is a Pi agent on
`deepseek-v4.1-flash-go`, so nothing is shared between them: not context, not
tools, not a session.

## The read-only guard

`claude_local` runs on Paperclip's ACP engine, which ignores extra CLI flags.
ACP does load the worktree's `.claude/settings.local.json`, so the engine writes
the guard there before every attempt (`prepare_claude_guard` in
`agents/factory/engine.py`), copying it from the source named in `engine.json`
under `claudeGuards`, currently
`/Users/paperclip/paperclip-agents/reviewer-sonnet/settings.json`. Paperclip's
own keys stay, and `.claude/` goes into the repo's `info/exclude` so the guard
is never committed.

The file holds two things:

- `permissions.deny`: `Edit`, `Write`, `MultiEdit`, `NotebookEdit`. Every edit
  tool is refused before it runs.
- a `PreToolUse` hook on `*` that runs the `factory-guard` hook with the role
  `readonly`: turn cap 60, no writes anywhere, and bash limited to a read-only
  allowlist (`ls`, `cat`, `grep`, `git log|show|diff|status|blame`, the stage
  check scripts) plus the three Paperclip API calls in the stage description.
  A call the hook cannot parse is blocked, and the stage pays a turn for it.

`readonly` also means no commit and no push: the reviewer never touches the
branch it is judging.

## Fallback on the usage limit

The Reviewer shares the Claude subscription with the owner, so a run can fail on
the provider usage limit. That is not a failed attempt: `engine.py` moves the
stage to its fallback agent for the rest of the order, records the stage in
`fallbackStages`, and states it in the work-order comment as
`review fallback: glm-5.3-flash-go` (the `fallbackNames` entry in
`engine.json`). That fallback is the Pi Reviewer, agent
`51c624e7-5018-4f22-a23c-dd4911e44a61`, running `glm-5.3-flash-go`.
Everything else about the stage stays the same: same brief, same `readonly`
role, same `findings` document, same hand-off.
