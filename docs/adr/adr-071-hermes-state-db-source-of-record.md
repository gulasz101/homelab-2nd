# ADR-071: Hermes `state.db` is the agent-memory source of record; nightly backup to OMV MinIO

**Date:** 2026-10-19
**Status:** Accepted
**Deciders:** Wojtek Gula; implemented by Andrzej (Hermes agent)
**Project:** hermes / agent memory (epic H2-232)
**Related:** H2-306 (findings), H2-308 (this work), ADR-052/053/054 (Hindsight), ADR-030 (nightly config backups)

## Context

H2-306 established that the Hermes `state.db` files on the M1 Max are the only lossless copy of
every agent conversation since 2026-06-19. Honcho was torn down; OpenViking and Hindsight hold
derived facts (retained extractions), not the conversations themselves. So the single most
valuable dataset in the homelab lived on one NVMe in one Mac with no second copy — a direct
violation of the guardrail that OMV is the only durable store.

Two failures compounded: the data had no backup, and on 2026-10-18 all five profiles silently lost
their memory wiring (`memory.provider` blanked to `''`, `hindsight` added to `plugins.disabled`)
without anything noticing for a day. A backup with no watchdog is a rumour; a watchdog with no
backup is a false sense of safety.

The profiles are ordinary files on the host (`~/.hermes/state.db` plus
`~/.hermes/profiles/<name>/state.db`) and are being written while the agent works, so they are live
SQLite databases in WAL mode — a file copy is not a valid snapshot.

## Decision

1. **`state.db` is the source of record for agent conversations.** Hindsight is the *recall* layer
   (derived, re-derivable); the SQLite files are the *history* layer and are what gets protected.
2. **Nightly, all five profiles are backed up to OMV MinIO**, bucket `hermes-state-backups`, object
   key `<YYYY-MM-DD>/<profile>.db.gz`, 30-day ILM expiry on the bucket.
3. **The snapshot is taken in-process**: `sqlite3 <db> ".backup '<tmp>'"`, then `gzip -n`, then
   upload, then delete the temp file. Never `cp` a live WAL database.
4. **A dedicated MinIO user `hermes-state-backup`** with a policy limited to `s3:PutObject`,
   `s3:GetObject`, `s3:ListBucket` on that bucket only. Credentials live only in
   `~/.config/hermes-state-backup/minio.env` (mode 600) on the Mac — never in git, never in a log,
   never in a ticket. The user deliberately cannot delete: retention belongs to ILM, not to the
   uploader. That "exactly one copy" claim is enforced, not assumed: the backup script runs `mc`
   with an ephemeral `MC_CONFIG_DIR` so `mc alias set` cannot leave a second copy of the secret in
   `~/.mc/config.json`, and `hermes-state-backup-rotate.sh` re-mints the secret with the new value
   travelling to MinIO on stdin (never argv, which `ps` exposes). Any credential from this user that
   reaches a transcript, a log or a chat gets rotated, not shrugged at.
5. **Automation is host-side, not cluster-side**: a LaunchAgent `com.gulasz101.hermes-state-backup`
   (daily 03:30) runs `~/.hermes/scripts/hermes-state-backup.sh`; a second LaunchAgent
   `com.gulasz101.hermes-memory-watchdog` (hourly) runs `~/.hermes/scripts/hermes-memory-watchdog.sh`.
   These are Mac-local by nature: the data only exists on the Mac.
6. **The watchdog alerts to Mattermost** (the andrzej home channel, via `hermes send`) when the
   memory provider is not `hindsight`, when `hindsight` is disabled, when zdzislaw's bank id drifts,
   when the newest Hindsight document is over 24 h old, when the backup log fails to show all five
   profiles succeeding, or when a Hindsight operation has been stuck in `processing` for more than
   3 h (read-only over `ssh homelab-2nd` → `sudo k3s kubectl -n hindsight exec hindsight-db-1 -c
   postgres -- psql`; a tripwire that cannot read alerts instead of staying silent). At most one
   alert per condition per 24 h.

## Consequences

- Any single profile's full conversation history can be restored from the previous night, proven by
  a real restore drill (`integrity_check` = ok, 131 532 messages on andrzej).
- The memory-wiring regression of 2026-10-18 becomes a Mattermost message within an hour, not a
  day-long silence.
- A wrong `state.db` upload cannot be deleted by the backup identity; it expires in 30 days. Accepted:
  the narrower policy is worth it, and the uploader has no business deleting.
- ~1.1 GB/night of new objects (about 33 GB of steady state at 30 days) lands on a 932 GB OMV disk
  that also carries every CNPG backup. Sizes grow with conversation volume.
- The backup depends on the Mac being awake and logged in (LaunchAgents are per-user); if the Mac is
  asleep at 03:30 nothing runs until the next day. The watchdog's condition 5 catches a missed run,
  but it cannot wake a sleeping laptop.
- No cluster involvement at all: nothing to reconcile in Flux, nothing in the repo except this ADR.

## Alternatives considered

- **Restore Honcho and keep memory in Postgres only.** Rejected: Honcho is torn down and was itself
  a *derived* store; the raw conversations were never in it.
- **Export OpenViking / Hindsight banks and call that the backup.** Rejected: those hold extracted
  facts, so a "restore" would rebuild an approximation of history, not history. Also insufficient for
  profile config and non-memory session state.
- **NFS-mount `~/.hermes/profiles` from OMV so there is nothing to copy.** Rejected: SQLite over NFS
  is a known corruption risk with multiple writers (it breaks file locking and WAL assumptions), and
  a database on the network is not a substitute for a point-in-time snapshot. Also makes every agent
  turn depend on OMV being up.
- **Flux/CronJob in k3s to do the backup.** Rejected: the source data is on the Mac, not in the
  cluster; the job would still need host access plus a mounted credential, which is more moving parts
  and more secret copies for the same result.
- **`pg_dump`-style logical export of each profile.** Rejected: no Postgres to dump; `sqlite3 .backup`
  *is* the logical-consistent snapshot for SQLite and is one command.
- **Keep 90 days of history.** Rejected for now: 30 days already gives a month of restore points;
  deeper retention belongs to a separate "conversation archive" decision if ever needed.

## When to revisit

- Conversation volume makes 30 days materially expensive or the 03:30 window consistently too short.
- The Mac moves to a always-on host or the profiles move into the cluster — then this becomes a
  cluster-side job with proper scheduling.
- Hindsight gains a proven lossless conversation store: the source-of-record statement above changes
  and `state.db` could be treated as a cache instead.
