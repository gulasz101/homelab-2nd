# ADR-076: Paperclip is the record for chat requests; one Paperclip identity per agent

**Date:** 2026-10-21
**Status:** Accepted
**Deciders:** Wojtek Gula; implemented by Claude Code (GUL-48)
**Project:** agent platform
**Related:** ADR-074 (Paperclip control plane), ADR-075 (org chart and runtimes), ADR-017 decision #3 (the same identity mistake on Itsaplan)

## Context

Wojtek often asks the Hermes agents for work in Mattermost, because Paperclip is awkward on a
phone. He wants every such request traceable in Paperclip, as Itsaplan was meant to do.
An audit on 2026-10-21 found:

- Paperclip syncs its `paperclip` skill only to `claude_local`, `pi_local` and
  `opencode_local` agents. For `hermes_gateway` agents it answers "This adapter does not
  implement skill sync yet". Each Hermes profile had written its own Paperclip skill, five
  different ones, and none covered "Wojtek asked in chat, so open an issue".
- Only Matejko had his own Paperclip key. Andrzej, Szarik, Florian and Zdzisław used
  Wojtek's board login from `~/.paperclip/auth.json`, so Paperclip recorded their comments as
  Wojtek's (GUL-3, GUL-4, GUL-6, GUL-11, GUL-45). Bill's skill minted agent JWTs from the
  instance secret.
- Every agent comment or update needs the `X-Paperclip-Run-Id` of a real heartbeat run. This
  holds for full agent keys and for `task_bridge` keys alike; without a run an agent can only
  create and read issues.
- An agent-assigned issue created outside `backlog` starts a run for that agent. Created as
  `done` or `cancelled`, the queued run is cancelled before it starts (GUL-50).

## Decision

1. **One Paperclip identity per agent.** Each Hermes profile's `.env` holds
   `PAPERCLIP_API_URL` and its own agent API key. Agents write as themselves; the board login
   and the server secrets stay closed (SOUL rule, shared skill).
2. **Chat-led work, recorded at the end.** Work Wojtek starts in chat stays interactive in
   chat. When it is finished, the agent creates one issue assigned to itself, status `done`
   (or `cancelled` with the reason), holding the quoted request, what was done, result and
   evidence. Questions that change nothing get no issue.
3. **Hand-off for long or async work.** The agent creates a `todo` issue for itself or the
   owning colleague, self-contained, and Paperclip runs it; the run posts the result back to
   the Mattermost channel.
4. **One shared skill set.** `agents/hermes-skills/paperclip-chat-intake` (this repo) plus the
   official `paperclip` skill linked from the installed Paperclip, loaded by every profile via
   `skills.external_dirs` (`~/agent-skills/hermes-paperclip`). The self-written profile skills
   are archived.

## Consequences

- Positive: Paperclip shows who asked for what and who did it, with agent attribution.
- Positive: no duplicate runs. Records are created closed, and hand-offs are real Paperclip
  runs with transcript and cost.
- Positive: one skill to maintain, reviewed in Git; the official skill follows Paperclip
  upgrades.
- Negative: chat work has no live status in Paperclip; the record appears when the work ends.
  For live status, ask for a hand-off.
- Negative: each record creation leaves a cancelled run in the agent's run list.
- Negative: the boundary is behavioural. Hermes runs as the same macOS user as Paperclip and
  can read the board login; the skills and SOUL rules keep agents away from it, the OS does
  not.

## Alternatives considered

- **Paperclip runs every chat request (board-led only).** Clean trace, but Wojtek loses the
  interactive conversation he wants on his phone. Kept as the hand-off path.
- **Live chat issue, updated as the work goes.** Not possible: updates and comments need a
  run, and an issue in an active status starts a duplicate run.
- **`task_bridge` keys from the official `paperclip-task-bridge` skill.** They narrow what a
  chat-facing key can touch, but they still need a run for comments and updates, and
  Paperclip-woken runs need the full agent API (interactions, documents, attachments). Two
  keys per profile for little gain while the board login sits on the same OS user.
- **Paperclip's built-in chat integrations.** Slack, Discord, Teams, Telegram and GitHub only;
  no Mattermost.

## When to revisit

- Paperclip gains Mattermost (or Open WebUI) chat support, or agent writes without a run.
- Wojtek moves agent chat from Mattermost to Open WebUI.
- Paperclip moves to its own macOS user: then switch chat-facing writes to `task_bridge` keys.
