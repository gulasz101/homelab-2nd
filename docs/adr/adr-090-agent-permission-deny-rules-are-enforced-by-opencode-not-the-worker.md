# ADR-090: An agent's deny rules are enforced by OpenCode, not by the worker's good manners

- **Status:** Accepted
- **Date:** 2026-10-26
- **Deciders:** Wojtek (owner), Andrzej (CTO, homelab-2nd)
- **Tracked by:** GUL-183 (live test), GUL-162 (the guard that missed), GUL-143 (the run that found it)
- **Related:** ADR-086 (run ceilings), ADR-087/088 (who runs the day)

## Context

On 2026-10-25 two Pi runs sat for ~50 minutes on `find / -name ...` and blocked the shared queue.
The fix at the time was an instruction: every agent `AGENTS.md` gained a hard rule "never search
from the filesystem root or a whole home directory", and Pi's shell was patched to refuse the
obvious forms.

That is a policy, not a control. On 2026-10-25 a Paperclip **OpenCode** run on GUL-143 executed
`...; find / -name yaml` and got away with it. Investigation (GUL-162) found two independent
reasons, and only the second one matters:

1. The `AGENTS.md` prose was not read, or not obeyed, at the moment of the call. Expected — it is
   text in a prompt, competing with a task the model was told to finish.
2. The `opencode_local` adapter's `dangerouslySkipPermissions` setting defaulted to **`true`**. With
   `true` the adapter rewrites the merged OpenCode config with `permission: "allow"`, which
   overwrites the `permission.bash` deny block in `~/.config/opencode/opencode.json`. Every pattern
   an operator wrote was silently discarded on the way into the run.

The second is the interesting one: the deny rules were present, correct, and never reached the
process. A reviewer reading `opencode.json` would have concluded the guard was in place. Nobody had
tested it *inside a Paperclip run* — Pi had only tested a manual `opencode run`, which does not go
through the adapter and therefore never saw the rewrite.

## Decision

**Agent read-scope is enforced by OpenCode's permission layer, and that layer must survive the
adapter. Set `dangerouslySkipPermissions: false` on every local agent, and prove it with a live
Paperclip run, not a manual CLI invocation.**

- `dangerouslySkipPermissions: false` is a standing requirement for any agent on a local adapter.
  It is not a per-task toggle and must not be flipped to unblock a run.
- The deny patterns live in `~/.config/opencode/opencode.json` as `permission.bash` entries, and must
  cover the wrapped forms — `*find /`, `*find / *`, `*grep * /`, `*grep * / *` — not just the bare
  commands. A rule that only matches `find /` is defeated by `true; find /`, `timeout 5 find /`,
  `bash -c "find /"` and `find ~`.
- A guard is considered installed only after a **real Paperclip run** shows the permission error in
  the tool result. A command the model declined to run proves nothing; a manual `opencode run`
  proves nothing about the adapter path.

### Evidence (GUL-183, 2026-10-26)

One Paperclip OpenCode run, `e10c0101-3ad4-432c-9241-41931d8264f8`, 131 s, finished on its own. All
six forbidden forms were refused by OpenCode before execution, each with:

> `The user has specified a rule which prevents you from using this specific tool call. Here are
> some of the relevant rules [...]`

including `true; find / -maxdepth 0`, `timeout 5 find / -maxdepth 0`,
`bash -c "find / -maxdepth 0"`, `find ~ -maxdepth 0` and `timeout 5 grep -rq x /`. The three
in-scope reads (`ls ~/Projects`, `find ~/Projects/homelab-2nd`, `grep` in a specific file) all ran,
and a write to `/tmp` raised no prompt — so the guard discriminates rather than blanket-denying.

## Consequences

- Deny rules are a control again: they bind regardless of what the model decides or what the task
  prose says. The `AGENTS.md` rules stay as the first line, but they are no longer the only line.
- `dangerouslySkipPermissions: false` costs prompts. A run can now block on an approval that `true`
  would have auto-allowed, so run time and wake latency go up. This is the accepted price; a stalled
  run is visible via the issue monitor, a silently over-privileged one is not.
- Two failure modes now have to be distinguished when a guard "does not work": the rule is missing
  from `opencode.json`, or the rule is present and the adapter overwrote it. Checking the config
  file alone cannot tell them apart — only a run log can.
- Every new agent on a local adapter inherits this as a checklist item, not a nice-to-have.

## Alternatives considered

- **Rely on `AGENTS.md` instruction.** Rejected: this is what failed on 2026-10-25. Text in a prompt
  is a suggestion competing with the task; a permission rule is a wall.
- **Patch each agent's shell wrapper to refuse the commands.** Rejected as the primary control: it
  is per-agent, per-shell, and easy to bypass with `bash -c`, `timeout`, or a different binary. It is
  a reasonable second layer, which is why Pi's shell patch stays.
- **Leave `dangerouslySkipPermissions: true` and keep rules in the config anyway.** Rejected: with
  `true` the adapter writes `permission: "allow"`, so the config is decorative. This was the actual
  state before GUL-162.
- **Test with a manual `opencode run`.** Rejected as evidence: it skips the adapter, which is the
  component that was overwriting the config. It would have passed while the real runs stayed
  unprotected.

## When to revisit

- If a legitimate task genuinely needs a root or whole-home read (a disk audit, a duplicate-file
  sweep), do not flip `dangerouslySkipPermissions` — scope the command to a directory or add a
  narrowly worded allow for that one path, and note why in the issue.
- If OpenCode changes its config merge order or drops `permission.bash` pattern matching, re-run the
  GUL-183 test before trusting the guard.
- If a local adapter other than `opencode_local` grows an equivalent "skip permissions" fast path,
  it needs the same rule and the same live proof.
