# ADR-081: `hindsight-db` backups move to the barman-cloud plugin, continuing the same archive

**Date:** 2026-10-22
**Status:** Accepted
**Deciders:** Wojtek Gula; implemented by Pi (Paperclip run for GUL-90)
**Project:** Hindsight / agent memory (epic H2-232)
**Related:** GUL-90, GUL-86, ADR-052 (Hindsight platform), ADR-014 (the Nextcloud migration that made the in-tree API's deprecation concrete), ADR-080 (backup alerting)
**Tracking note:** `homelab/tracking/2026-10-22-gul-90-hindsight-barman-plugin-migration.md` (vault)

## Context

CloudNativePG deprecated the in-tree `spec.backup.barmanObjectStore` API in 1.26 and will remove
it. On 2026-10-22 `hindsight-db` was the only one of the twelve CNPG clusters in this repo still
using it:

```
hindsight/hindsight-db   plugin=            barmanOS=YES
<all eleven others>      plugin=barman-cloud.cloudnative-pg.io   barmanOS=no
```

This was not a credentials or policy problem. The MinIO user `hindsight-backups` already carried
the house three-ARN policy on `cnpg-backups/hindsight`, verified during the GUL-86 sweep. The
cluster was healthy (`ContinuousArchiving=True`, `LastBackupSucceeded=True`, daily base backups
completing), so the migration had to preserve a working, live archive rather than rebuild around
it.

Two properties of this particular cluster matter:

1. **It is on generation 2.** ADR-052 recorded generation 1 built with `initdb`; the 2026-10-19
   rebuild (H2-306, `docs/cnpg-backup-servername-generations.md`) restored generation 1's base
   backup and WAL into a new cluster that archives as `serverName: hindsight-db-gen2`. Generation
   1 remains the recovery source in `externalClusters`.
2. **The deprecated API and the plugin are mutually exclusive.** The 2026-08-31 Nextcloud
   incident (ADR-014) is the proof: the admission webhook rejected `spec.plugins` on a cluster
   that still had `backup.barmanObjectStore`, the cluster ran with an empty `archive_command`,
   and 315 GiB of unarchived WAL filled the node. A half-migration is worse than either end
   state.

## Decision

1. **Backups go through the `barman-cloud.cloudnative-pg.io` plugin**, configured by a new
   `barmancloud.cnpg.io/v1 ObjectStore` named `hindsight-db-backups` in the `hindsight`
   namespace. It keeps `destinationPath: s3://cnpg-backups/hindsight`, the existing
   `hindsight-minio-backup-creds` secret, gzip for data and WAL, and moves
   `retentionPolicy: 30d` from the Cluster to the ObjectStore (where the plugin defines it).
2. **The archiver keeps `serverName: hindsight-db-gen2`.** A migration is not a rebuild. The
   plugin reads and writes the same barman layout the in-tree implementation used, so pointing
   it at the existing gen2 namespace continues the WAL chain instead of freezing it. Starting a
   fresh `gen3` here would leave the newest restorable point pinned to migration day and would
   make the next rebuild restore from a stale archive for no benefit.
3. **`externalClusters` is converted to the plugin form in the same change**, keeping
   `serverName: hindsight-db` for generation 1. Both generations share one ObjectStore and are
   separated by `serverName` only; the docs' warning against reusing an ObjectStore for backup
   and recovery is satisfied by the distinct server names.
4. **The `ScheduledBackup` switches to `method: plugin` + `pluginConfiguration`.** It keeps the
   03:00 daily schedule and `immediate: true`.
5. **The operand image is not changed in this migration.** `ghcr.io/cloudnative-pg/postgresql:16`
   stays because it ships pgvector, which Hindsight's schema needs; the barman tooling inside it
   is now simply unused. Moving to `16-minimal-trixie` + an `extensions:` pgvector image is a
   separate change with its own restart and extension-path risk, and it buys nothing for backups.

## Consequences

- **All twelve clusters now use one backup interface.** One ObjectStore shape, one metric family
  (`barman_cloud_cloudnative_pg_io_*`), one retention field, one place to look when a backup is
  wrong.
- **The migration is visible as a rolling restart of the instance**, because `spec.plugins`
  changes the pod template. WAL archiving pauses for that restart; the archive already holds
  every segment up to the switch.
- **The archive stays compatible with the previous archiver.** A rollback to the in-tree block
  would still find `hindsight-db-gen2` populated, but the API will eventually disappear, so a
  rollback is a bridge, not a plan.
- **The plugin adds a sidecar to the database pod.** Its crash is now a WAL-archiving failure
  mode that did not exist before; the existing `CNPGArchivingStalled` alert covers it, and the
  sidecar has explicit 100m/128Mi requests and 500m/512Mi limits.
- **The legacy `cnpg_collector_last_*` series latches** on a cluster that has migrated. The
  existing alert expressions already guard the legacy branch with `last_available > 0` and
  compare timestamps, so a stale positive cannot fire `CNPGBackupFailed`; the rules file comment
  now says so instead of naming a cluster that no longer exists.
- **`docs/cnpg-backup-servername-generations.md` no longer describes a live in-tree cluster.**
  Its in-tree section is now historical, and it records that a migration must not bump the
  generation.

## Alternatives considered

- **Rebuild as `gen3` with a fresh archive.** Rejected: a rebuild of the only durable copy of
  agent memory to change a backup API, with no data benefit. It also abandons forward WAL
  continuation on `gen2`, so the restore point ages from migration day until the next base
  backup lands in the new namespace.
- **Stay on the in-tree API until CNPG removes it.** Rejected: the removal is already announced,
  and the Nextcloud incident shows what the transition looks like when it is forced under
  pressure (admission rejection, no archiver, disk pressure). Doing it on a healthy cluster is
  the cheap version.
- **Recreate the archive under a new bucket prefix.** Rejected for the same reason as `gen3`,
  plus it would break the documented generation convention and orphan 134 GiB of history that
  still serves as the generation-2 restore chain.
- **Volume snapshots instead of object storage.** Rejected: `local-path` has no snapshot support,
  and the whole point of ADR-052's storage split is that the node is rebuildable and OMV is the
  only durable store.
- **Move the operand to a minimal image at the same time.** Rejected as scope creep: it changes
  the extension-loading path (`extensions:` image volume) on a live cluster. The image choice is
  now purely about pgvector and can be revisited on the next planned rebuild.

## When to revisit

- **A rebuild happens.** Then bump the archiver to `hindsight-db-gen3` and the recovery source to
  `hindsight-db-gen2`, both together, per `docs/cnpg-backup-servername-generations.md`.
- **CNPG removes the in-tree `externalClusters.barmanObjectStore` form** (it is converted here,
  so this should be a no-op, but the operator release notes are the trigger to check).
- **The plugin stops being maintained**, or an operator upgrade changes the plugin name,
  ObjectStore API version, or sidecar requirement.
- **Retention or the OMV MinIO endpoint changes**, since both now live in the ObjectStore rather
  than the Cluster.
