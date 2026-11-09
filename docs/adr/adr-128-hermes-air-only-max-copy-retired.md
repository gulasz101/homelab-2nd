# ADR-128: Hermes runs only on the M1 Air; the Max's copy is retired, not a standby

**Date:** 2026-11-09
**Status:** Accepted
**Deciders:** Wojtek Gula (owner rule); implemented by Claude Code
**Project:** agent platform
**Supersedes:** decision 4 of [ADR-073](adr-073-hermes-runs-on-the-m1-air.md) ("the Max's `~/.hermes` is a cold standby")

## Context

ADR-073 moved Hermes to the M1 Air (`paperclip`) on 2026-10-20 and kept the Max's `~/.hermes` as a
14-day cold standby. Its gateway, watchdog and state-backup LaunchAgents were booted out, but their
plists stayed in `~/Library/LaunchAgents` with `RunAtLoad=true`.

The Max rebooted at 10:08 on 2026-11-09. launchd loaded the gateway plist at login, and the stale
Max gateway connected to Mattermost and Telegram with the same bot tokens as the Air. Until 19:38,
every message got two replies: one from the Air (DeepSeek routes) and one from the Max, whose
configs still name Kimi models. Token spend doubled, and the Max also ran crons and the kanban
dispatcher against its own stale state.

"Booted out" doesn't survive a reboot. A standby that's one reboot away from running isn't a standby.

## Decision

Owner rule: **Hermes runs only on the M1 Air.** It stays that way until Wojtek explicitly says otherwise.

On the Max:

1. Every Hermes LaunchAgent (`ai.hermes.gateway`, `com.gulasz101.hermes-memory-watchdog`,
   `com.gulasz101.hermes-state-backup`) is booted out, `launchctl disable`d, and its plist moved to
   `~/Library/LaunchAgents.retired-hermes/*.RETIRED-2026-11-09`.
2. `~/.local/bin/hermes` is a stub that refuses and exits 1. The real launcher is kept as
   `hermes.RETIRED-2026-11-09`.
3. `~/.hermes/gateway_state.json` says `stopped`. `~/.hermes/RETIRED-DO-NOT-START.md` explains why.
4. Nothing from the Max's `~/.hermes` (configs, memories, sessions, backups) is ever restored or
   copied onto the Air. A rollback, if one is ever needed, goes to the Air's own MinIO backups.
5. `~/.hermes/tools/` stays on the Max for now: Camofox runs its node binary from there.

## Consequences

- One gateway, one identity per agent, one bill.
- There's no warm standby. If the Air dies, recovery means reinstalling on the Air (or a new host)
  from the Air's backups. That's slower than flipping a LaunchAgent, but it can't double-post.
- The Max's `~/.hermes` still takes disk space and still holds live API keys in `.env` files. It
  should be deleted, apart from the Camofox tools, once the owner agrees.
- The watchdog and the state.db backups exist only on the Air (`dev.voitech.homelab.*` and
  `com.gulasz101.hermes-*` in the Air's LaunchAgents).

## Alternatives considered

- **Keep the standby but `launchctl disable` it**: that survives reboots, but `hermes gateway
  start` would reinstall and enable the plist. Rejected: the owner wants no second identity at all.
- **Delete the Max's `~/.hermes` now**: cleanest, but Camofox depends on `~/.hermes/tools`, and a
  deletion can't be undone. It's deferred until the owner confirms it.

## When to revisit

- The owner explicitly moves Hermes to another host, or asks for a real HA setup. Two gateways
  will need a leader lock on the bot tokens, which Hermes doesn't provide today.
- Camofox moves out of `~/.hermes/tools`. After that, the Max's `~/.hermes` can be deleted.
