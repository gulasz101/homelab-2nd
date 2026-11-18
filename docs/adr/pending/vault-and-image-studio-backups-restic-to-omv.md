# The vault and Image Studio are backed up to OMV with restic, not copied with Syncthing

- **Status**: Pending
- **Date**: 2026-11-11
- **Issue**: GUL-1393 (parent GUL-29)

## Context

The Obsidian vault (~4.7 GB, 13,205 files) and `~/image-studio` (~1.9 GB, 5,148 files: the
backlog `queue.json`, cards, briefs, handoffs, audit) live on the Air. GUL-1393 asked for proof
that the vault already reaches OMV through a backup job. **It did not.** There was no such job:
no NFS or SMB mount of an OMV share on either Mac, no vault entry in any `homelab-2nd` manifest,
crontab or launchd file, no `vault`/`obsidian` directory anywhere in `/srv` on OMV (checked to
depth 7), and no bucket on OMV MinIO holding it. The vault's only protection was Syncthing
between the Air and the M1 Max — a *copy*, not a backup: one `rm`, one bad edit, one Obsidian
plugin that rewrites files, and both sides agree on the damage within seconds. `~/image-studio`
had nothing at all.

So the real task was to create the job, not to inspect it. That is an architecture decision:
what carries the bytes, where the copy lives, how it is validated, and what can restore it at
03:00 without the owner in front of the machine.

Constraints that shaped it:

- OMV is the only durable store, and its MinIO already is the S3 backend for everything else
  (`hermes-state-backups`, `cnpg-backups`, `arr-stack-backups`, …). One transport, one alerting
  path, one credential model.
- The Air is headless most days, so the job must be a **system** LaunchDaemon (ADR-107): a
  `gui/501` LaunchAgent does not fire when nobody is logged in — that is exactly how the 30 Oct
  state backup was lost.
- A launchd-spawned non-Apple binary cannot open LAN sockets on this host (GUL-87, ADR-079), so
  the S3 endpoint must be the `127.0.0.1:9000` loopback relay, never the OMV address.
- The vault is text with a long tail of binary attachments; the Image Studio tree carries
  regenerable `tmp/`, `cache/` and `.venv-imgcheck/`.

## Decision

**A nightly restic backup of `~/vault` and `~/image-studio` to a dedicated MinIO bucket
`paperclip-backups` on OMV, run by a system LaunchDaemon `com.gulasz101.vault-backup` at 02:40.**

- One repository, `s3:http://127.0.0.1:9000/paperclip-backups/restic`, two tagged snapshots per
  run: `--tag vault` and `--tag image-studio`, both `--host paperclip`.
- Encryption and deduplication come from restic; retention is `--keep-daily 7 --keep-weekly 4`,
  with `--prune` and a structural `restic check` only on Sunday so the nightly run stays short.
- The repository password and the MinIO key live in `~/.config/vault-backup/minio.env` (0600,
  host-only). They are **not** in the repo — the repo is public. A MinIO user `paperclip-backup`
  with a bucket-scoped policy (list/get/put/delete on `paperclip-backups` only) means a leaked
  key cannot touch CNPG backups or any other bucket.
- `tmp/`, `cache/` and `.venv-imgcheck/` inside `~/image-studio` are excluded: throwaway by
  construction. Everything else, including `staging/`, is protected.
- The script and the plist live in `homelab-2nd` under `host/paperclip-air/` and are installed by
  `homelab-install-scheduled-jobs.sh`. The installed copies are the artifact; the repo is the
  source.
- Verification is part of the release, not an afterthought: a manual `restic ls` plus a restore of
  one file back to disk and a `shasum` comparison against the source, recorded in the issue.

## Consequences

- The vault and the Image Studio backlog now survive the loss of the Air, a bad sync, or a wiped
  directory. Restore is one command and needs no second machine to be healthy.
- Snapshots are versioned: a file deleted in October can come back, which Syncthing could never do.
- ~6.6 GB of new data on OMV, then a small incremental delta per night (restic only uploads new
  chunks; the vault's churn is text).
- A second credential store on the host (`~/.config/vault-backup/`). It is host state, not repo
  state, and has the same exposure profile as `~/.config/hermes-state-backup/`.
- restic is a new host dependency, installed to `~/.local/bin/restic` and pinned in the plist PATH.
  Nothing else on the Air depends on it.
- The first run is slow (reads and uploads everything). Later runs are minutes.
- Failure is silent unless someone reads the log; the alerting hook (status file
  `~/.config/vault-backup/last-run` → heartbeat) is a follow-up, not part of this decision.
- A new system daemon cannot be activated from inside a Hermes gateway: the gateway guard refuses
  `launchctl bootstrap`/`submit` regardless of label, by design. The plist and script land in
  `/Library/LaunchDaemons` and `/usr/local/libexec/homelab`, and activation is one command from a
  shell outside Hermes (or the next boot): see the issue for the exact line. Any future agent-run
  daemon install has the same shape, so the install script should say so.

## Alternatives considered

- **rsync to an OMV share over SSH with `--link-dest` snapshots.** No new credentials and no new
  binary, but no encryption at rest, no dedupe, a full directory tree to walk nightly, and a
  half-finished rsync leaves a snapshot that looks complete. Rejected.
- **Add the vault and `~/image-studio` to the existing Syncthing folder set.** Cheapest by far and
  wrong for the reason above: Syncthing is replication, not backup. It also needs Syncthing
  installed on OMV, which it is not.
- **A k3s CronJob reading the Mac over NFS.** Inverts the dependency: the cluster would need a
  write mount into the Air's home directory, and a broken cluster would stop backups.
- **Extend the existing `hermes-state-backup` bucket.** Its MinIO credential is scoped to that
  bucket, and mixing a 6.6 GB asset tree with Hermes state makes the retention policy of both
  worse. A separate bucket and user cost nothing.

## When to revisit

- If restic's daily delta on this data grows past the 02:40–05:30 window, or OMV's free space on
  the `backups` disk falls below 20%.
- If the vault moves somewhere with no restic binary (a NAS-native app), or Obsidian Sync becomes
  the source of truth and the local vault becomes a cache.
- If the restore drill fails twice in a row: then the decision is not "restic" but "which store",
  and the answer has to change.
- When `~/image-studio` grows past a few tens of GB (staging is already 1.8 GB of renders), revisit
  whether `staging/` belongs in the backup at all.
