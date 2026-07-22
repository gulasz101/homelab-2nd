# Karakeep GitOps deployment plan

**Date:** 2026-07-22
**Topic:** Deploy Karakeep bookmark manager behind Authentik SSO, wired to local gemma-4-12b-uncensored via LiteLLM.

## Goal

Stand up a new `karakeep` namespace on homelab-2nd with the Karakeep bookmark-everything app, protected by Authentik SSO for `akadmin` and Sylwia, using the local `gemma-4-12b-uncensored` model for AI tagging.

## Background reading

- Karakeep docs indexed in docs-mcp as `library=karakeep`.
- Authentik integration page indexed as `library=karakeep-integrations`.
- HelmForge chart indexed as `library=helmforge-karakeep`.
- Existing homelab patterns: Authentik SSO recipe in `homelab-gitops` skill, LiteLLM proxy in `apps/llm-hub`, OMV MinIO for durable storage, Cloudflare Tunnel ingress, per-namespace observability package.

## Decisions

1. **Namespace:** `karakeep`.
2. **Public hostname:** `keep.voitech.dev`.
3. **Chart:** HelmForge `karakeep` 1.2.7 with pinned app image `0.32.0`.
4. **Working data PVC:** 10Gi OMV NFS share mounted at `/data` for SQLite + Meilisearch index + queue state. No data on homelab-2nd physical disk.
5. **Durable assets:** S3 to OMV MinIO bucket `karakeep-assets`.
6. **SQLite backup:** nightly CronJob copying the DB to OMV MinIO.
7. **Search / crawler:** Meilisearch + Chromium as chart sidecars.
8. **SSO:** Authentik OAuth2 provider; SSO-only via `DISABLE_PASSWORD_AUTH=true`.
9. **AI tagging:** OpenAI-compatible endpoint through LiteLLM proxy, model `gemma-4-12b-uncensored`.
10. **Observability:** OTel traces/logs to Collector, Prometheus metrics via PodMonitor, Grafana dashboard, standard alert package.

## Steps to execute

### Pre-flight (manual / break-glass)

1. On OMV, create folder and NFS export `/srv/dev-disk-by-uuid-cda9bf6e-0ed1-4e61-b063-1cbab7351886/karakeep/data` (10Gi), plus MinIO bucket `karakeep-assets` with a dedicated user.
2. In Cloudflare Zero Trust, create tunnel `keep.voitech.dev` and note its token.
3. In Authentik, create application/provider `karakeep`:
   - Redirect URI: `https://keep.voitech.dev/api/auth/callback/custom`
   - Scopes: `openid`, `profile`, `email`, `homelab-role`
   - Bindings: `homelab-users`, `homelab-admins`

### GitOps manifests

4. Create SOPS secrets:
   - `karakeep-app-secret.sops.yaml` — `NEXTAUTH_SECRET`, `MEILI_MASTER_KEY`
   - `karakeep-oidc-client.sops.yaml` — Authentik client_id, client_secret, well-known URL
   - `karakeep-minio-creds.sops.yaml` — OMV MinIO credentials
   - `karakeep-tunnel-token.sops.yaml` — Cloudflare tunnel token
   - `karakeep-prometheus-token.sops.yaml` — `/api/metrics` bearer token
   - `karakeep-mattermost-webhook-url.sops.yaml`

5. Create HelmRelease `karakeep-helm-release.yaml` with:
   - SSO env vars from secrets
   - S3 asset store env vars
   - LiteLLM OpenAI-compatible AI variables
   - OTel variables
   - `meilisearch.enabled: true`, `chromium.enabled: true`
   - `persistence.existingClaim: karakeep-data` (OMV NFS 10Gi, no storageClass)

6. Create supporting manifests:
   - `namespace.yaml`, `karakeep-helm-repository.yaml`
   - `karakeep-data-pv.yaml`, `karakeep-data-pvc.yaml` (OMV NFS 10Gi)
   - `cloudflared-keep-deployment.yaml`
   - `keep-tunnel-ingress-configmap.yaml`
   - `karakeep-sqlite-backup-cronjob.yaml`
   - `karakeep-podmonitor.yaml`
   - `karakeep-dashboard-configmap.yaml`
   - `karakeep-prometheus-rules.yaml`
   - `karakeep-loki-rule.yaml`
   - `karakeep-alertmanager-config.yaml`

7. Add all new resources to `apps/kustomization.yaml`.

### Reconcile and verify

8. Push to `main`, force Flux reconciliation.
9. Verify pod health, DNS, SSO login, bookmark + AI tagging, logs in Grafana.
10. Promote `akadmin` to admin in Karakeep UI; confirm Sylwia is a normal user.

## Risks and mitigations

- SQLite single-writer pod on NFS: Karakeep is single-writer and low-contention; mount options mirror Nextcloud (`hard, intr, nconnect=8`). If locking issues appear, revisit with a dedicated OMV-backed block storage class or Rook.
- Lockout from SSO-only before admin exists: promote first SSO user via Karakeep admin panel; can re-enable password auth in GitOps as break-glass.
- CPU saturation on single-node cluster: set low resource requests, one inference worker.

## Files to create

See the execution plan for full manifest list.
