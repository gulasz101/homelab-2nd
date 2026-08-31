---
title: "Nextcloud CNPG WAL backlog caused homelab-2nd disk pressure"
date: 2026-08-31
tags: [homelab-2nd, nextcloud, cnpg, minio, wal, disk-pressure, barman-cloud, gitops]
---

# 2026-08-31 — Nextcloud CNPG WAL backlog caused homelab-2nd disk pressure

## Symptom

`akadmin` reported alerts: homelab-2nd was hot and struggling. Initial guess was another failing PG backup job or embeddings workload.

## Diagnosis

### Initial checks

- `top` on homelab-2nd showed high CPU from `k3s-server`, `barman-cloud-backup-list/show`, and the authentik debugger.
- Root filesystem was **95% full**: 389 GiB / 433 GiB.
- `/var/lib/rancher/k3s/storage/` consumed ~337 GiB.

### Finding the real hog

The Nextcloud data PVC is on OMV NFS and was not the local disk consumer. The local-path PVC for `nextcloud-db` was:

```bash
sudo du -sh /var/lib/rancher/k3s/storage/* | sort -h | tail -n 5
```

Inside it, `pg_wal` was **315 GiB** with 40,000+ WAL files.

### Why WALs were not archiving

```bash
sudo kubectl exec -n nextcloud nextcloud-db-1 -c postgres -- psql -U nextcloud -d nextcloud -tAc "SHOW archive_command;"
# returned empty
```

The `nextcloud-db` Cluster had **no `spec.plugins`** section, so the barman-cloud sidecar was never injected. The cluster was still using the deprecated in-tree `backup.barmanObjectStore`. In CNPG v1.30+ those two APIs are mutually exclusive; adding `spec.plugins` was rejected by the webhook until the in-tree block was removed.

## Fix (all via GitOps)

### 1. Add `ObjectStore` CR

Created `apps/nextcloud/objectstore.yaml`:

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: nextcloud-db-backups
  namespace: nextcloud
spec:
  configuration:
    destinationPath: s3://cnpg-backups/nextcloud
    endpointURL: http://openmediavault.local:9000
    s3Credentials:
      accessKeyId:
        name: nextcloud-backup-creds
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: nextcloud-backup-creds
        key: SECRET_ACCESS_KEY
    data:
      compression: gzip
    wal:
      compression: gzip
```

Note: the live `nextcloud-backup-creds` secret uses `SECRET_ACCESS_KEY`, not `ACCESS_SECRET_KEY` like newer secrets. The ObjectStore was pointed at the actual key.

### 2. Migrate the Cluster

In `apps/nextcloud/postgres-cluster.yaml`:

```yaml
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: nextcloud-db-backups
        serverName: nextcloud-db

  backup:
    retentionPolicy: "30d"
```

Removed the old in-tree `backup.barmanObjectStore` block.

### 3. Update scheduled backup

`apps/nextcloud/scheduled-backup.yaml`:

```yaml
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  immediate: true
```

### 4. Include objectstore in kustomization

`apps/kustomization.yaml` was missing `nextcloud/objectstore.yaml`, so Flux never created it. Added it.

### 5. Rotate stale MinIO key

After enabling the plugin, archiver failed with `InvalidAccessKeyId`. On OMV:

```bash
docker exec minio mc admin accesskey create local nextcloud --json
```

Updated `apps/nextcloud/nextcloud-backup-creds.sops.yaml` via SOPS with the new key pair.

### 6. Restart the DB pod

A pod restart was required for the plugin sidecar to be injected (CNPG v1.30 injects the sidecar on pod creation). The `cloudnative-pg` operator was also restarted once because it was not recreating the pod after the cluster spec change.

```bash
sudo kubectl delete pod -n nextcloud nextcloud-db-1
# later, after objectstore was created:
sudo kubectl rollout restart deployment/cloudnative-pg -n cnpg-system
```

## Verification

- `ContinuousArchiving` condition flipped to `True`/`ContinuousArchivingSuccess`.
- Barman sidecar logs showed successful WAL archives to OMV MinIO.
- Disk usage dropped from **95% → 88%** within minutes as the WAL backlog drained.
- `DiskPressure` node condition flipped to `False`.
- A fresh `Backup` CR using `method: plugin` was started and ran successfully.

## Cleanup

- Deleted failed legacy Backup objects created with `method: barmanObjectStore`.
- Deleted the stuck `nextcloud-db-daily-20260831030300` plugin backup object that was created before the MinIO key rotation.

## Lessons / blog gold

1. **A cluster can look healthy while silently filling its disk.** `Ready True` and `ClusterIsReady` do not mean WAL archiving works.
2. **CNPG v1.30 is stricter about plugin vs in-tree APIs.** The webhook rejection was the only hint that the old config was incompatible.
3. **Check `pg_stat_archiver` and `SHOW archive_command` first.** If `archive_command` is empty, WALs are not leaving the node.
4. **The `ObjectStore` CR must be listed in the kustomization.** Flux did not create it because it was not referenced; this delayed the fix by one reconcile cycle.
5. **Rotated MinIO keys must be updated in SOPS secrets immediately.** A stale key caused a second round of failures after the plugin was enabled.

## Links

- ADR-014: `docs/adr/adr-014-nextcloud-cnpg-plugin-objectstore.md`
- Commit: `fix(nextcloud): migrate CNPG backups to barman-cloud plugin ObjectStore`
- CNPG plugin docs: https://cloudnative-pg.io/docs/1.30/barman-cloud-plugin/
