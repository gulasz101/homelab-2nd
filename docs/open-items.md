# Open items

Tracked backlog for known gaps, workarounds, and follow-ups in the homelab-2nd GitOps repo. Keep entries short, dated, and actionable.

## Incident: 2026-09-11 repo-restructure data loss

The `clusters/homelab-2nd` → `clusters/production` rename used a shim that copied only `flux-system/*`, omitting the child Kustomization CRs (`apps.yaml`, `infrastructure.yaml`, `cert-manager.yaml`). With the root Kustomization's `prune: true`, Flux pruned the child Kustomizations and cascade-deleted all workloads and CNPG `Cluster` CRs. Databases without backups were lost. See ADR-012 for the corrected procedure.

Data lost (no backups at the time):

- **authentik** users (local accounts and preferences)
- **itsaplan** tasks
- **shlink** links
- **karakeep** bookmarks

## Open

### itsaplan partial reconstruction — OPEN (no usable source found)

- The `itsaplan` PostgreSQL database was lost and had no backups.
- The saved arr-box container logs (`/home/voitech/homelab-recovery/itsaplan-logs-arr-box.tgz`) were assessed on 2026-09-12: they are **post-wipe** (2026-09-11 22:29–22:43), i.e. the fresh DB's own startup (`Running migrations...`) plus planner/runner auth errors. **No task titles, payloads, or webhook JSON were present.** See `docs/itsaplan-reconstruction.md`.
- Remaining possible sources: Loki/Grafana logs from before 22:29 (retention-limited), rotated node logs, or OMV MinIO pre-prune dumps.
- TODO: search those sources if they still exist; otherwise accept the loss.

### tldraw — OPEN

`tldraw` is disabled/stale and will be replaced by **Excalidraw** in a future change. Do not invest in fixing it; migrate its use case instead.

## Resolved

### Karakeep durable storage + backups — DONE (2026-09-12)

- Root cause: the StatefulSet `volumeClaimTemplates.volumeName: karakeep-data` was silently dropped by the chart's schema, so `data-karakeep-0` fell back to `local-path`; a separate static PVC had claimed the NFS PV anyway.
- Fixed: `data-karakeep-0` is now bound to the durable NFS PV `karakeep-data` (OMV), the pod is pinned to `homelab-2nd`, and a daily `karakeep-backup` CronJob snapshots `db.db`/`queue.db` (SQLite online backup) to `s3://karakeep-backups/karakeep/` with 14-day retention. Commit `262a7a9`.

### NFS node pinning — DONE (2026-09-12)

`opengist`, `nextcloud`, `speaches`, and `karakeep` are pinned to `homelab-2nd`, where OMV exports their NFS paths (`opengist-data`, `nextcloud-data`, `nextcloud-html`, `speaches-model-cache`, `karakeep-data`). Commits `8222e4c`, `860afd5`, `262a7a9`. If more NFS-backed workloads are added, pin them or make the OMV exports node-agnostic.

### CNPG `skipEmptyWalArchiveCheck` workaround — DONE (2026-09-12)

- The annotation was only needed while the plugin's empty-archive guard was active (marker window) and for recovery bootstraps onto a non-empty target. On healthy clusters the marker is removed after the first archived WAL, so it is not needed at steady state.
- Verified on a pilot (`opengist-db`) with a forced WAL switch + on-demand backup, then **removed from all CNPG clusters**. Continuous archiving and backups confirmed healthy.
- Per-rebuild `serverName` isolation convention documented in `docs/cnpg-backup-servername-generations.md` (archiver target `<cluster>-genN`, recovery source the previous generation). Commit `8f80061`.
