# Open items

Tracked backlog for known gaps, workarounds, and follow-ups in the homelab-2nd GitOps repo. Keep entries short, dated, and actionable.

## Incident: 2026-09-11 repo-restructure data loss

The `clusters/homelab-2nd` → `clusters/production` rename used a shim that copied only `flux-system/*`, omitting the child Kustomization CRs (`apps.yaml`, `infrastructure.yaml`, `cert-manager.yaml`). With the root Kustomization's `prune: true`, Flux pruned the child Kustomizations and cascade-deleted all workloads and CNPG `Cluster` CRs. Databases without backups were lost. See ADR-012 for the corrected procedure.

Data lost (no backups at the time):

- **authentik** users (local accounts and preferences)
- **itsaplan** tasks
- **shlink** links
- **karakeep** bookmarks

### itsaplan partial reconstruction — TODO

- The `itsaplan` PostgreSQL database was lost and had no backups.
- Partial reconstruction may be possible from arr-box container logs saved at `/home/voitech/homelab-recovery/itsaplan-logs-arr-box.tgz`.
- TODO: assess the archive, extract any recoverable task/state data, and reconstruct what is feasible.

### karakeep durable storage + backups — TODO

- `karakeep` had NO backups and its SQLite database lived on `local-path` (node-local, unrecoverable after the cascade delete).
- TODO: move `karakeep` data to durable storage and add a backup path. Another agent is adding a backup CronJob.

## NFS node pinning — TODO

`nextcloud-data`, `karakeep-data`, `speaches-model-cache`, and `opengist-data` are exported by OMV only to the `homelab-2nd` node. Pods using them that are not pinned to `homelab-2nd` can fail their NFS mount; `opengist` was pinned to `homelab-2nd` to fix exactly this.

- TODO: pin `nextcloud`, `karakeep`, and `speaches` to `homelab-2nd` (or make the OMV NFS exports node-agnostic), so rescheduling cannot land them on a node without the export.

## CNPG `skipEmptyWalArchiveCheck` recovery workaround — TODO

`cnpg.io/skipEmptyWalArchiveCheck: "enabled"` is set on all CNPG clusters (i.e. `apps/{honcho,itsaplan,llm-hub,mattermost,nextcloud,opengist,shlink,tldraw}` and `infrastructure/auth`). It bypasses the "WAL archive must be empty" guard so recovery and same-store WAL archiving work while databases are rebuilt from their existing barman archive.

- TODO: move to per-rebuild `serverName` isolation (a distinct barman `serverName` per cluster generation) so archives do not collide, then remove the annotation once it is safe.

## tldraw — TODO

`tldraw` is disabled/stale and will be replaced by **Excalidraw** in a future change. Do not invest in fixing it; migrate its use case instead.
