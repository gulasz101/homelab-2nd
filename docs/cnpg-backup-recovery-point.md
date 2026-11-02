# CNPG backups on OMV MinIO: what recovery point do we actually have?

Status: measured 2026-11-02 on the restored drill for [GUL-822]. Re-run the drill whenever
the backup design, the object store or the disk behind it changes.

The object store is `cnpg-backups` on OMV MinIO (`/dev/sdd` since the 2026-11-02 cutover).
Every CNPG cluster archives into `s3://cnpg-backups/<cluster>` through the barman-cloud
plugin, one `serverName` per generation (see `cnpg-backup-servername-generations.md`).

## Recovery point (cnpg-backups)

**Expected recovery point today: the head of the WAL archive, minutes behind production.**
A base backup plus the WAL chain restores to the last archived segment, not to the moment you
run the restore. Measured lag on 2026-11-02: the restored mattermost held the newest row from
`20:36:40Z` while production was at `20:41:40Z` for a drill started at `20:39Z`.

**A base backup alone is the fallback when the WAL chain has a hole.** It always starts and
gives you a consistent database, but it stops at the first missing WAL segment, which can be
hours or days behind the archive head. Never promise a point in time that sits behind a known
hole in the chain.

## The 2026-11-02 measurement

Three drills, all hand-applied into a throwaway namespace, no `backup:` stanza and no
WAL archiver (so the archive could not be written to), deleted afterwards.

| drill | base backup | started | replayed to | RTO |
|---|---|---|---|---|
| itsaplan, latest | `post-migration-20261102` (`20261102T195850`, begin WAL `37/33`) | yes | archive head, prom. tli 2 at `37/3D` | 1m24s |
| mattermost, latest | `post-migration-20261102` (`20261102T195850`, begin WAL `87/02`) | yes | archive head, prom. tli 3 at `87/B0` | 1m09s |
| mattermost, 18 h old | `daily-20261102020000` (`20261102T020000`, begin WAL `86/37`) | yes | archive head, newest post `20:36:40Z` | 3m34s |
| itsaplan, pre-hole | `20261030040000` (`20261030T040001`, begin WAL `33/19`) | yes | **stopped at `33/91` (2026-10-30 13:45)** | ~3m |

Data checks: restored `system_identifier` matched production on all three promoted clusters
(`7684377732797345812` itsaplan, `7653428587874172947` mattermost), so these are real physical
restores, not silent `initdb`. Row counts and newest row timestamps matched production too.

RTO numbers are lower bounds: both databases are small and MinIO is on the LAN.

## Where the WAL chain is broken

Lost objects from the `/dev/sdc` failure: 130 were reported unreadable by the first `rsync`
pass, 127 are genuinely gone on `/dev/sdd` (the directory exists, `xl.meta` does not). All of
them sit **before** the post-cutover base backups:

| cluster | logids with missing segments | wall clock covered |
|---|---|---|
| itsaplan (tli 1) | `0x2D` ×3, `0x2E` ×5, `0x2F` ×1, `0x30` ×11, `0x31` ×3, `0x32` ×2, `0x33` ×2 (`8F`, `93`) | 2026-10-25 → 2026-10-30 13:45 |
| mattermost (tli 2) | `0x7D` ×1, `0x7E` ×3, `0x80` ×10, `0x81` ×2, `0x82` ×1, `0x83` ×2 | 2026-10-25 → 2026-10-31 01:45 |

Consequence: any restore whose base backup begins before the first hole replays only up to
that hole. We keep 30 days of base backups, so "restore to any point in the last 30 days" is
false for these two clusters. Backups from 2026-10-31 onward replay to the archive head.

## Running a drill

1. Pick the target cluster's latest completed `Backup` and note `.status.backupId`,
   `.status.beginWal`, `.status.startedAt`.
2. Create a throwaway namespace and copy, into it, the cluster's `ObjectStore` and the two
   Secrets it needs (the object-store credentials and the app role credentials). Values come
   from the live cluster, never from a file in the repo.
3. Apply the drill `Cluster` below. No `plugins:` and no `backup:` stanza: a drill that
   archives writes WAL into the live `serverName` and corrupts the archive it is testing.
4. **Copy the bootstrap job's log while it runs** —
   `kubectl -n <ns> logs <cluster>-1-full-recovery-<suffix> -c full-recovery`. The pod is
   deleted when the job completes, and with it the only record of where replay stopped.
5. Compare `system_identifier`, `pg_control_checkpoint()`, row counts and newest row
   timestamps against production. Read `checkpoint_lsn` after promotion: the promotion
   checkpoint opens the next segment, so the replayed end is the segment before it.
6. Delete the namespace and confirm no `<drill>` prefix appeared under `cnpg-backups`.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: itsaplan-db-drill
  namespace: restore-drill
  labels:
    homelab.voitech.dev/transient: restore-drill
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:17-minimal-trixie   # must match the major version
  bootstrap:
    recovery:
      source: origin
      database: itsaplan
      owner: itsaplan
      secret:
        name: itsaplan-db-credentials
      # recoveryTarget:
      #   backupID: "20261102T195850"   # pin a specific base backup; omit for the latest
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: itsaplan-db-backups
          serverName: itsaplan-db
  storage:
    storageClass: local-path
    size: 10Gi
```

## Revisit when

- The backup design changes (different plugin, different bucket, retention shortened).
- `cnpg-backups` moves to the raid1 pair ([GUL-813]).
- Renovate bumps the CNPG operator or the postgres images: the `imageName` major version in a
  drill must still match the cluster it restores, or the restore fails at `pg_controldata`.

[GUL-822]: https://paperclip.voitech.dev/GUL/issues/GUL-822
[GUL-813]: https://paperclip.voitech.dev/GUL/issues/GUL-813
