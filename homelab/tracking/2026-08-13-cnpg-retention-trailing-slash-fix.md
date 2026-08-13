# CNPG retention cleanup fixed: remove trailing slash from destinationPath

**Date:** 2026-08-13
**Scope:** All CNPG PostgreSQL clusters backed up to OMV MinIO
**Affected services:** OpenWebUI, LiteLLM, Authentik, Honcho, Mattermost, Nextcloud, OpenGist, Shlink, tldraw

## Why this matters

Wojtek (Supreme Leader) asked whether backups for the OpenWebUI database were working correctly because he uses OpenWebUI heavily and did not want to lose them.

The answer: **base backups and WAL archiving were working, but retention cleanup was silently broken**. Old backups were never being deleted, so the MinIO bucket was growing without bound.

## Symptoms

- `openwebui-db` `Cluster` status showed `LastBackupSucceeded: False` and a recent `lastFailedBackup`.
- `plugin-barman-cloud` sidecar logs showed this error every retention cycle:

```text
Barman cloud backup delete exception: An error occurred (XMinioInvalidObjectName) when calling the ListObjectsV2 operation: Object name contains unsupported characters.
```

- OpenWebUI bucket `cnpg-backups/openwebui/` contained **76,187 objects**.
- Same error and pattern found in LiteLLM sidecar logs.

## Root cause

Every CNPG `ObjectStore` / `barmanObjectStore` in the repo used a trailing slash in `destinationPath`:

```yaml
destinationPath: s3://cnpg-backups/openwebui/
```

Barman Cloud's `barman-cloud-backup-delete` trips over that trailing slash when calling MinIO's `ListObjectsV2` during retention enforcement. This is a known upstream issue: **EnterpriseDB/barman#944**. The reporter fixed it by removing the trailing slash.

## What was checked

1. Cluster health: `openwebui-db-1` was `2/2 Running`, WAL archiving active.
2. Scheduled backup: `openwebui-db-hourly` exists and recent backups were `completed`.
3. Bucket inventory on OMV MinIO via `mc`:
   - `openwebui`: 76,187 objects, 42,568 older than 35 days.
   - `litellm`: similar object count.
4. Sidecar logs: confirmed `XMinioInvalidObjectName` during retention, not during backup or WAL archive.
5. GitHub issue barman#944: confirmed trailing slash is the trigger.
6. Barman version in sidecar: `3.19.1`; plugin-barman-cloud: `v0.13.0` — recent enough, so not a version bug.

## Fix

Removed the trailing slash from every CNPG `destinationPath`:

```yaml
destinationPath: s3://cnpg-backups/openwebui   # was s3://cnpg-backups/openwebui/
```

Files changed in `gulasz101/homelab-2nd`:

- `apps/llm-hub/openwebui-db-objectstore.yaml`
- `apps/llm-hub/litellm-db-objectstore.yaml`
- `infrastructure/auth/postgres-cluster.yaml`
- `apps/honcho/postgres-cluster.yaml`
- `apps/mattermost/objectstore.yaml`
- `apps/nextcloud/postgres-cluster.yaml`
- `apps/opengist/objectstore.yaml`
- `apps/shlink/objectstore.yaml`
- `apps/tldraw/objectstore.yaml`

### Live changes (break-glass)

Patched the live `ObjectStore` resources for `openwebui-db-backups` and `litellm-db-backups`, then deleted the DB pods so CNPG recreated them with the corrected sidecar config. This caused a brief restart of the OpenWebUI and LiteLLM databases.

Commits:

- `cc33811` — fix(llm-hub): remove trailing slash from CNPG ObjectStore destinationPath for MinIO compatibility
- `396db95` — fix(all-cnpg): remove trailing slash from every CNPG S3 destinationPath for MinIO compatibility

## Verification

After the fix:

- `openwebui-db` `Cluster` status: `phase: Cluster in healthy state`, latest backups `completed`.
- `ObjectStore` status:

```text
openwebui-db: lastSuccessfulBackupTime: 2026-08-13T08:13:14Z
litellm-db:   lastSuccessfulBackupTime: 2026-08-13T08:11:31Z
```

- Bucket object count dropped on its own from **76,187 → 26,253** for OpenWebUI and **~75,800 → 25,835** for LiteLLM, proving retention cleanup is now deleting old objects.
- The `XMinioInvalidObjectName` error stopped appearing.
- Remaining "object has been modified" errors in logs are transient Kubernetes resourceVersion conflicts between the backup and retention goroutines; they do not block deletion and should settle once the backlog clears.

## Remaining work

- The other CNPG clusters (Authentik, Honcho, Mattermost, Nextcloud, OpenGist, Shlink, tldraw) now have the corrected config in Git. Flux will reconcile them over time. Each will cause a short DB pod restart when reconciled.
- Monitor bucket sizes over the next few days to confirm retention catches up everywhere.

## Lesson

A single character (trailing `/`) in a config value can silently break an entire backup lifecycle. All CNPG examples show `s3://bucket/path/` but MinIO + Barman require `s3://bucket/path`. This should be a lint rule or ADR in the repo.

## References

- GitHub issue: https://github.com/EnterpriseDB/barman/issues/944
- CNPG docs-mcp-server / skill `homelab-gitops`
- OMV MinIO endpoint: `http://openmediavault.local:9000`, bucket: `cnpg-backups`
