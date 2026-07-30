# ADR-009: OpenGist storage, ingress, and SSO

Date: 2026-07-30
Status: Proposed
Supersedes: nothing
Superseded by: nothing

## Context

We are deploying **OpenGist** (https://opengist.io, app version 1.14.0, Helm chart 0.10.0) into a new `opengist` namespace on `homelab-2nd`. The service is a self-hosted Git-powered pastebin intended for all homelab users, including non-admin family members. The homelab topology and guardrails create three design questions:

1. **Where does OpenGist store its data?** Git repositories require a POSIX filesystem with stable semantics, and the app stores them under `$opengist-home/repos`.
2. **How is it exposed publicly?** The hard rule is Cloudflare Tunnel only; no Kubernetes Ingress, no router ports, no cert-manager.
3. **How do users authenticate?** We already run Authentik for centralized SSO; local accounts should not be a primary path and, once OIDC is working, local registration should be disabled.
4. **How do we back up the database?** Every Postgres instance must use CloudNativePG with backups to OMV MinIO.

## Decision

1. **OpenGist data lives on OMV NFS.** The `opengist-home` directory (`/opengist`) is a 50Gi PersistentVolume backed by an OMV NFS export mounted with `hard,intr,nconnect=8`. This keeps durable Git state off `homelab-2nd` while providing the POSIX semantics Git repositories need.
2. **Public ingress uses a dedicated Cloudflare Tunnel.** The tunnel is configured with one hostname rule: `gist.voitech.dev` → `http://opengist-http.opengist.svc.cluster.local:6157` (the Helm chart exposes the application on service `opengist-http`, port 6157). TLS is terminated at the Cloudflare edge; the internal hop is plain HTTP.
3. **SSO uses Authentik OIDC.** OpenGist is configured with `oidc.provider-name: Authentik`, `oidc.discovery-url` pointing to the `opengist` application in Authentik, `oidc.group-claim-name: groups`, and `oidc.admin-group: homelab-admins`. Local registration and the local login form are disabled via the admin panel after the first OIDC admin login.
4. **Database uses CloudNativePG with OMV MinIO backups.** A CNPG `Cluster` named `opengist-db` runs in the `opengist` namespace; live PVCs sit on `local-path` on `homelab-2nd` for low latency. Hourly scheduled backups and continuous WAL archiving target `s3://cnpg-backups/opengist/` on OMV MinIO, authenticated with a dedicated scoped user `cnpg-opengist-backup`.
5. **Metrics and logs are wired into LGTM.** The OpenGist config enables the Prometheus metrics server on port 6158. The Helm chart creates a matching `ServiceMonitor`; logs are collected by the OpenTelemetry Collector DaemonSet and available in Loki. A Grafana dashboard named "opengist" is provisioned into the `opengist` folder.

## Consequences

### Positive

- Fully aligned with the homelab storage topology: durable data on OMV, fast live DB on `local-path`.
- No router ports opened; public exposure is through Cloudflare Tunnel only.
- Centralized authentication via Authentik; members of `homelab-admins` become OpenGist admins automatically.
- No durable state is lost if `homelab-2nd` is rebuilt from the Git repo.
- CNPG backups give point-in-time recovery for Postgres.
- Prometheus metrics and Loki logs are available from day one.

### Negative / Risks

- Git over NFS is less performant than local disk for large pushes. Mitigated by single-replica OpenGist and moderate expected load.
- The Cloudflare Tunnel hostname rule must be updated manually in the Zero Trust dashboard if the internal service name or port changes. The initial rule pointed to the non-existent `opengist.opengist.svc.cluster.local:6157`; we corrected it to `opengist-http.opengist.svc.cluster.local:6157` after the first failed request.
- Local registration/login-form disablement is managed through OpenGist's admin panel (database `admin_settings` table), not via `config.yml`. This means a future fresh install requires a one-time manual step or a DB init script.
- OpenGist does not expose disable-signup as a config file key, so the setting is not strictly GitOps. We document the exact DB update in the tracking note and could later automate it via a CNPG init container or post-deploy Job if needed.

## Alternatives considered

| Option | Why rejected |
|---|---|
| `local-path` PVC for OpenGist data on `homelab-2nd` | Violates the "no data on homelab-2nd" guardrail. |
| S3-backed `opengist-home` | Git repositories need POSIX filesystem semantics; S3 is not suitable. |
| Kubernetes Ingress + cert-manager | Public ingress must use Cloudflare Tunnel only. |
| Standalone Postgres StatefulSet | Hard rule: all Postgres instances use CloudNativePG. |
| Allow local registration alongside OIDC | Violates the "no fallbacks" rule once SSO is working. |

## When to revisit

Revisit this ADR if:

- OpenGist adds `disable-signup` and `disable-login-form` keys to `config.yml`, allowing us to move the setting into the GitOps-managed SOPS Secret.
- NFS performance becomes a bottleneck for Git operations and we need a block-storage alternative on OMV.
- We enable SSH Git access, which would require additional Cloudflare Tunnel SSH configuration or a separate ingress path.
- We migrate observability to a different stack (e.g., Mimir/Loki replacement).

## References

- `apps/opengist/opengist-helm-release.yaml`
- `apps/opengist/opengist-data-pv.yaml` and `opengist-data-pvc.yaml`
- `apps/opengist/postgres-cluster.yaml`, `objectstore.yaml`, `scheduled-backup.yaml`
- `apps/opengist/cloudflared-opengist-deployment.yaml` and `opengist-tunnel-ingress-configmap.yaml`
- `apps/opengist/opengist-config.sops.yaml`
- `apps/opengist/opengist-dashboard-configmap.yaml`
- Tracking note: `homelab/tracking/2026-07-29-opengist-deployment.md`
- OpenGist docs: https://opengist.io/docs/
- Cloudflare Tunnel remote management docs: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/remote-management/
