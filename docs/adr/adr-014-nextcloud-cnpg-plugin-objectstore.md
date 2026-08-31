---
status: accepted
date: 2026-08-31
---

# ADR-014: Nextcloud CNPG backups via the barman-cloud plugin ObjectStore

## Context

On 2026-08-31 the homelab-2nd node (8c/31GB/408GB NVMe) started firing alerts: high CPU, high load, and kubelet DiskPressure. Investigation showed:

- Root LV was **95% full** (389 GiB / 433 GiB).
- The largest single consumer was the **Nextcloud CNPG database PVC**, specifically `pg_wal` at **315 GiB**.
- The `nextcloud-db` Cluster had no WAL archiver sidecar, so `archive_command` was empty and WAL files had been accumulating since June 21st, 2026.
- The cluster was still configured with the deprecated in-tree `backup.barmanObjectStore` API. CNPG v1.30+ is stricter: a WAL archiver plugin (`barman-cloud.cloudnative-pg.io`) cannot be enabled on a cluster that also defines `backup.barmanObjectStore`. The admission webhook rejected any `spec.plugins` addition until the in-tree config was removed.

Other clusters in the homelab (opengist, shlink, litellm, mattermost, openwebui, authentik) had already been migrated to the plugin-only pattern, each with a `barmancloud.cnpg.io/v1 ObjectStore` CR. Nextcloud had been missed during that earlier migration.

## Decision

Migrate Nextcloud CNPG backups to the same plugin-only pattern used by the rest of the fleet:

1. Add a `barmancloud.cnpg.io/v1 ObjectStore` CR in the `nextcloud` namespace pointing at the existing OMV MinIO `s3://cnpg-backups/nextcloud` bucket.
2. Remove the in-tree `backup.barmanObjectStore` block from `Cluster/nextcloud-db`.
3. Add `spec.plugins` with `barman-cloud.cloudnative-pg.io` as the WAL archiver (`isWALArchiver: true`).
4. Update `ScheduledBackup/nextcloud-db-daily` from the default method to `method: plugin`.
5. Rotate the MinIO access key for the `nextcloud` user because the existing key in `nextcloud-backup-creds` was stale (`InvalidAccessKeyId`).

## Consequences

**Positive:**
- WAL archiving resumed immediately; the 315 GiB backlog started draining to OMV MinIO.
- Disk pressure on homelab-2nd was relieved (95% → 88% within minutes, continuing to fall).
- Nextcloud CNPG backups now follow the same pattern as every other CNPG cluster in the repo.
- The S3 backup destination and credentials are owned by a dedicated `ObjectStore` CR, which is easier to audit and reuse.

**Negative / risks:**
- Draining 315 GiB of WAL over the LAN to OMV keeps the node busy for a while; CPU and barman processes will remain elevated until the backlog clears.
- PostgreSQL 16 image path and existing PVC were preserved, but a pod restart was required for the plugin sidecar to be injected. This briefly interrupted Nextcloud, which is acceptable because Nextcloud is not yet in active use.
- Old failed Backup objects (created with `method: barmanObjectStore`) had to be cleaned up manually; they were noise, not data.

## Alternatives considered

- **Add more disk to homelab-2nd.** Rejected: the root LV is already on the only physical disk; LVM VG has zero free extents. Adding disk would only postpone the real problem.
- **Move the Nextcloud DB PVC off the node.** Rejected: the DB itself is meant to live on local-path for low latency; only backups/WALs need to leave the node. The fix is archiving, not relocating the live database.
- **Manually delete WAL files.** Rejected: extremely risky, would corrupt the database timeline, and is unnecessary once archiving is enabled.

## When to revisit

- If CNPG deprecates or changes the plugin contract again.
- If Nextcloud becomes actively used and a maintenance window is needed for future plugin changes.
- If OMV MinIO capacity or network path becomes a bottleneck.
