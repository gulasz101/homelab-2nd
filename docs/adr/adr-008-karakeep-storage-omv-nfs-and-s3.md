# ADR-008: Karakeep working data lives on OMV NFS; durable assets live on OMV MinIO S3

Date: 2026-07-22
Status: Proposed
Supersedes: nothing
Superseded by: nothing

## Context

We are deploying **Karakeep** (formerly Hoarder), a single-writer bookmark-everything application, in a new `karakeep` namespace on `homelab-2nd`. The homelab topology has a hard rule:

- `homelab-2nd` provides compute + fast/ephemeral storage only.
- `openmediavault` (OMV) provides durable storage.

The HelmForge `karakeep` chart defaults to a PVC for its working data directory (`/data`), where it keeps:

- SQLite database (`db.db`)
- Meilisearch full-text index (`meilisearch/`)
- Background-job queue state

The chart also stores durable assets (cached page archives, uploaded files, screenshots) in that same directory by default, but Karakeep supports pushing those to an S3-compatible object store.

This raised two questions:

1. Where does the working-data PVC live?
2. Where do durable assets live?

The answer must keep zero durable data on `homelab-2nd`.

## Decision

**Karakeep's `/data` PVC is backed by an OMV NFS export, and durable assets are stored in OMV MinIO S3. No state is kept on `homelab-2nd` storage.**

### Rationale

1. **Hard guardrail: no data on homelab-2nd.** The Supreme Leader explicitly stated this. `local-path` on the NVMe is therefore unacceptable for Karakeep's working data, even though the chart defaults to it.
2. **OMV is the durable store.** Both NFS and MinIO S3 live on OMV. Splitting by access pattern makes sense:
   - NFS for the small, random-I/O SQLite + Meilisearch files.
   - S3 for large, object-style assets and backups.
3. **SQLite on NFS is a known trade-off.** SQLite's locking model is not ideal over NFS, but Karakeep is a single-replica, single-writer workload with low contention. The same mount options that work for Nextcloud (`hard, intr, nconnect=8`) are used. This is an acceptable risk for a personal bookmark app and can be revisited if corruption appears.
4. **CNPG is not applicable.** Karakeep does not support Postgres. SQLite is the only option, so CloudNativePG is not involved.
5. **S3 for assets avoids storing large archives on the working PVC.** Cached pages, screenshots, and PDFs can grow quickly; MinIO is the right durable home for them.
6. **Nightly SQLite backup to MinIO adds a second durability layer.** Even though the working PVC is already on OMV NFS, copying the SQLite DB and Meilisearch subpath to a versioned MinIO bucket protects against accidental deletion or application-level corruption.

## Consequences

### Positive

- Zero data on `homelab-2nd` physical disk; full alignment with the storage topology.
- Durable assets live in MinIO, where they can be versioned and lifecycle-managed.
- Working data survives a `homelab-2nd` node rebuild because it is on OMV.
- Backup job gives point-in-time recovery for SQLite.

### Negative / Risks

- SQLite on NFS can theoretically corrupt under concurrent access or lock misbehavior. Mitigated by single-replica deployment and Nextcloud-proven mount options.
- NFS performance is lower than local NVMe for random I/O. For a low-write bookmark app this is acceptable.
- Manual PV/PVC provisioning is required because OMV does not expose a dynamic NFS StorageClass to k3s.
- If OMV NFS becomes unavailable, Karakeep stops. This is the same dependency Nextcloud already has.

## Alternatives considered

| Option | Why rejected |
|---|---|
| `local-path` PVC on homelab-2nd for `/data` | Violates the "no data on homelab-2nd" rule. |
| Single OMV MinIO bucket for both working data and assets | SQLite needs a POSIX filesystem; S3 cannot host a SQLite database. |
| Migrate Karakeep to Postgres ourselves | Karakeep does not support Postgres; this would require forking the app. |
| Deploy a Ceph/Rook cluster on OMV for block storage | Far too heavy for one small app. |
| Use an NFS `StorageClass` provisioner | None exists in the cluster; dynamic provisioning would add another component. Manual PVs are simpler and match the Nextcloud pattern. |

## When to revisit

Revisit this ADR if:

- SQLite on NFS shows corruption or locking errors in Karakeep logs.
- The working data grows beyond the 10Gi NFS share.
- A lightweight OMV-backed block storage option (e.g., Longhorn, TopoLVM, or Ceph single-node) becomes available and is simpler than NFS.
- Karakeep adds native Postgres support and we can switch to CloudNativePG + S3 backups.

## References

- `apps/nextcloud/nextcloud-data-pv.yaml` — existing OMV NFS PV pattern.
- `apps/nextcloud/nextcloud-data-pvc.yaml` — existing bound PVC pattern.
- Tracking note: `homelab/tracking/2026-07-22-karakeep-deployment-plan.md`
- HelmForge Karakeep chart: `library=helmforge-karakeep` in docs-mcp.
