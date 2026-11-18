# Hermes runs only on the M1 Air; the Max's copy is retired, not a standby

- **Status**: Pending
- **Date**: 2026-11-09
- **Deciders**: Wojtek Gula (owner rule); implemented by Claude Code
- **Project**: agent platform
- **Supersedes**: decision 4 of [ADR-073](../adr-073-hermes-runs-on-the-m1-air.md) ("the Max's `~/.hermes` is a cold standby")
- **Related**: `pending/hermes-browser-camofox-web-firecrawl-lan.md` (Camofox's runtime moved out of Hermes's directory)

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
2. `~/.local/bin/hermes` became a stub that refuses and exits 1. (The real launcher was archived
   and removed in step 5.)
3. Before archiving, `~/.hermes/gateway_state.json` was set to `stopped` and a
   `RETIRED-DO-NOT-START.md` was added. Both are inside the archive now.
4. Nothing from the Max's `~/.hermes` (configs, memories, sessions, backups) is ever restored or
   copied onto the Air. A rollback, if one is ever needed, goes to the Air's own MinIO backups.
5. **Archived, then deleted (same day).** The whole of `~/.hermes`, the retired plists, the old
   state-backup MinIO env and the old launcher were streamed as a zstd tar to OMV:
   `backups/m1max-hermes-retired-20261109/m1max-dot-hermes-20261109.tar.zst` (7.5 GB, sha256
   `bc153755…0a1e53`, also in `SHA256SUMS` next to it, mode 600). It was verified by checksum,
   `zstd -t` and an exact entry count (330,455) before `~/.hermes` was removed from the Max. It's a
   paranoia copy for reading only: it's never restored onto a running host.
6. **`~/.hermes` on the Max is now a read-only *file*** holding this notice, so no installer,
   restore or `hermes` run can recreate the directory. `hermes`, `hermes-acp` and `hermes-agent` in
   `~/.local/bin` are refusal stubs. Camofox's Node runtime moved to `~/.local/share/camofox/`
   (`pending/hermes-browser-camofox-web-firecrawl-lan.md`), and the dead `zeroclaw-cookie-guard`
   LaunchAgent, which ran a script from the old profile, was retired too.

## Consequences

- One gateway, one identity per agent, one bill.
- There's no warm standby. If the Air dies, recovery means reinstalling on the Air (or a new host)
  from the Air's backups. That's slower than flipping a LaunchAgent, but it can't double-post.
- The Max no longer holds Hermes API keys, and 14 GB of disk came back. Those keys live on only in the
  OMV archive (root-only, mode 600).
- The watchdog and the state.db backups exist only on the Air (`dev.voitech.homelab.*` and
  `com.gulasz101.hermes-*` in the Air's LaunchAgents).

## Alternatives considered

- **Keep the standby but `launchctl disable` it**: that survives reboots, but `hermes gateway
  start` would reinstall and enable the plist. Rejected: the owner wants no second identity at all.
- **Delete the Max's `~/.hermes` without an archive**: rejected. The owner wanted one more copy
  just in case.

## When to revisit

- The owner explicitly moves Hermes to another host, or asks for a real HA setup. Two gateways
  will need a leader lock on the bot tokens, which Hermes doesn't provide today.
- The OMV archive is past any use (say, 6 months with no need to read it). Delete it then.
