# ADR-073: Hermes runs on the M1 Air (paperclip); the Max's copy is a retired standby

**Date:** 2026-10-20
**Status:** Accepted
**Deciders:** Wojtek Gula; implemented by Claude Code (H2-327)
**Project:** agent platform
**Related:** H2-327 (migration), H2-118 (webhook target), ADR-017 (Itsaplan → Hermes webhook)

## Context

Hermes Agent (one gateway serving every profile: default/Bill Cipher, andrzej, florian, szarik,
zdzislaw, careerpa) ran on the M1 Max, which is also a daily-use desktop with heavy local services.
The owner set up an M1 Air (`paperclip`, 192.168.1.191, 16 GB) as a dedicated always-on host.

Two facts shaped the move:

- **One gateway multiplexes every profile and keeps one routing table** (`gateway_routing` in
  the root `state.db`). Moving profiles one at a time, as first planned, would have meant two
  gateways on two hosts fighting over the same routing state.
- **Hermes stores absolute home paths everywhere**: about 150 live cron/skill/script files, the
  LaunchAgent plists, the managed venv shebangs, and the agents' own skills and memories all name
  `/Users/wojciechgula/...`. The Air's user is `paperclip`.

## Decision

1. **Move the whole install in one window.** Rsync `~/.hermes` while the Max runs (rehearsal),
   stop the Max gateway from outside, do a final state-only rsync, start the Air gateway. Actual
   downtime on 2026-10-20 was about 90 seconds (10:57:32 → 10:59:14).
2. **`/Users/wojciechgula` is a symlink to `/Users/paperclip` on the Air**, and Hermes runs with
   `HERMES_HOME=/Users/wojciechgula/.hermes`. No path in any file, memory or skill is rewritten.
   Two things still had to change because Hermes *resolves* paths:
   - `gateway_routing.scope` stores the resolved sessions dir, so it was rewritten to
     `/Users/paperclip/...` in the root and per-profile `state.db` files (394 rows).
   - The dependency environment is keyed by a hash of the resolved checkout path, so
     `hermes pm repair` built a new one on the Air (`installs/71dcbab1…`).
3. **Services that stay on the Max are reached over the LAN** (192.168.1.119): Camofox `:9377`
   (configs repointed from `localhost`), Star Office backend `:19000`, Kokoro TTS `:8880`. Heavy
   local image work (`sd.cpp-models`, `ideogram4-local`, `~/.venvs/sou-flux`) stays on the Max.
4. **The Max's `~/.hermes` is a cold standby for 14 days**, its gateway, watchdog and backup
   LaunchAgents booted out. Rollback: bootout on the Air, bootstrap on the Max.

## Consequences

- The agents keep every memory, session and skill byte-for-byte; nothing they "know" about paths
  went stale.
- The symlink is load-bearing: removing `/Users/wojciechgula` on the Air breaks Hermes. It is
  documented in the `hermes` skill and here.
- Itsaplan's webhooks must target the Air (`192.168.1.191:8644`); until changed they hit the dead
  Max listener.
- The Air must auto-login as `paperclip` after a reboot, or the gateway (a GUI-domain
  LaunchAgent) never starts. On 2026-10-20 autologin still named the old, removed user.
- Two gateways must never run against the same bot tokens: the Max's copy must stay stopped.

## Alternatives considered

- **Profile-by-profile cutover** (Andrzej's plan): rejected, see the routing table above.
- **A real `wojciechgula` user on the Air**: no symlink, but it needs a second autologin user,
  its own Syncthing for the vault, and Homebrew shared across users. More moving parts for the
  same result.
- **Rewrite every path to `/Users/paperclip`**: hundreds of files plus the agents' memories;
  anything missed fails quietly later.
- **Fresh install plus a state copy**: still hits the same path problem, and loses nothing the
  rsync didn't already carry.

## When to revisit

- If the Air is reinstalled or its user renamed: recreate the symlink before starting Hermes.
- If Hermes stops resolving paths for routing/env keys, or adds a supported host-move command.
- When the Max standby window ends (2026-11-03): delete the Max's `~/.hermes` after the owner agrees.
