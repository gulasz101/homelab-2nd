# The Lodge learns an agent's Paperclip state by polling, because nothing inside the run can tell it

- **Status**: Pending
- **Date**: 2026-11-02
- **Issue**: GUL-827 (parent GUL-818)
- **Related**: GUL-826 (Claude Code hooks do not load under Paperclip), ADR-078 (the ingest-token registry), ADR-060 (room design), ADR-107 (the Air's scheduled jobs are system daemons)

## Context

The owner wants the Paperclip PM — the agent "Claude Code", the `claude_local` adapter, running on the Air — to have its own room in the Lodge and to move with its runs. It had been registered in the Star Office agent registry since 2026-10-18 with a token, a room type and a hoodie, and had **zero events**. The renderer only gives an agent an office when it has an event inside a 24 h window, so a registered agent with no reporter is invisible. The registration was never the problem; the writer was missing.

The obvious writer is a Claude Code hook, and it does not work. Paperclip runs the adapter with a sandboxed `HOME`, so `~/.claude/settings.json` — and every hook in it — is never read (GUL-826). Whatever mechanism we pick has to work from **outside** the run.

"Outside" is constrained: the Paperclip HTTP API is the only place that knows which runs are live, and it is guarded. Minting an **agent** API key is a board action (`403 Board access required` for an agent key, which is how GUL-827 hit the wall); the board key is the owner's own login and is not available to any agent process.

## Decision

1. **A poller on the Air derives the state; the run does not report it.** Every 10 s it reads `GET /api/companies/{company_id}/live-runs`, keeps the runs whose `agentId` is this agent, and posts `state_change {state: working}` when any is live, `idle` when none is. The trigger is Paperclip's own run record, so it works whatever the agent is doing inside the run and survives a Claude Code restart.

2. **State is derived, never stored.** There is no state file and no "was I running" flag. A restarted reporter, a restarted Paperclip and a dropped POST all correct themselves within one interval, because the next tick re-reads the truth. The one thing the process remembers is *when it last spoke*.

3. **`working` is re-asserted every 30 s.** The renderer falls back on its own after 60 s without events (`IDLE_COFFEE_MS` in `frontend/v3/activity.js`). A single `working` at the start of a run would leave a long run's character at the coffee machine for the rest of it. 30 s is under 60 s with room for one lost POST.

4. **Two credentials, both outside the repo.** The *write* side is the agent's ingest token from the ADR-078 registry (`backend/tokens.py register <agent> --room <type>`), which stores only a SHA-256 and enforces that a token writes only its own agent's room. The *read* side is a Paperclip **agent** API key for that same agent, and it can only be minted by the board. Both go into SOPS/age; the installer decrypts to a `0600` file on the host. Neither ever appears in a ticket, a log or this repository.

5. **No new art, and no repository change to add a room.** Since SOU-291/294 the repo knows no agent: `frontend/v3/src/rooms.js` reads `room: {type, hoodie}` from `GET /public/agents`, which is DB data. A new agent's room is a `set-room` call and one event, not a branch of room art. The PM uses the `career` type — advisor desk, whiteboard, framed certs — rather than the `garage` it was imported with.

## Consequences

- The Lodge now shows the PM, and the state moves within one poll interval (≤10 s to `working`, ≤10 s to `idle`) of Paperclip's own record. Verified on a real run: Paperclip run `c90775c7` ran 21:24:03Z–21:26:16Z; the first `working` landed 21:25:47Z and the `idle` 21:26:22Z.
- One more always-on process on the Air, and it is a **system LaunchDaemon**, not a user agent: the Air is headless most days, so anything that only runs while someone is logged in reads as healthy from the outside while doing nothing (ADR-107).
- The PM's read credential is board-minted, so onboarding a *new* agent's reporter has a human step unless Paperclip grows a way for an agent key to read its own company's run telemetry. That is the structural fix worth asking for upstream.
- The reporter is coupled to one Paperclip endpoint and to the renderer's `state_change` vocabulary. A Paperclip rename breaks the trigger loudly (401/404 in the daemon log); a silent break is the failure mode to watch, hence `check` as the smoke test.

## Alternatives

- **Claude Code hook in `~/.claude/settings.json`** — the intended design, dead on arrival: sandboxed `HOME` (GUL-826).
- **Hook from the project's `.claude/` directory**, which does survive the sandbox — rejected: it means committing a hook block into every repository the PM touches, and it still cannot report a run that dies before its first hook fires.
- **Detect the `claude` process** — rejected after testing it. A `claude` process was alive for nine days inside a `tmux` session on this Mac, so process presence is not run presence, and telling a Paperclip-spawned child from an interactive one means walking process ancestry that the adapter does not promise to keep.
- **Watch the per-run `.ndjson` log files** (`~/.paperclip/instances/*/data/run-logs/<company>/<agent>/`) — rejected: `lsof` showed no open handle even on a demonstrably live run, because the server appends and closes, so "being written" cannot be distinguished from "finished".
- **A Paperclip plugin with a run-lifecycle hook** — the cleanest event-driven answer, but installing one is a board action, and it puts homelab logic inside Paperclip's process. Worth revisiting if Paperclip ever exposes a supported run webhook.
- **Have the PM's own instructions post the event** — rejected outright: an LLM instruction is not a guarantee, and it would put the ingest token in the agent's instructions.

## When to revisit

- Paperclip ships a run-lifecycle webhook or plugin hook reachable without board approval: the poller becomes an event listener.
- Paperclip lets an agent key read its own company's run telemetry: the board-minted key step disappears.
- A second `claude_local` agent appears in the company — the reporter is already keyed by `agent_id`, not by process, so it only needs a second instance and token, but the "one poller per agent" cost is worth re-checking against a single multi-agent poller.
