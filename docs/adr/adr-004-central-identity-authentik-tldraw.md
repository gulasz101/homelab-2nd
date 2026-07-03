# ADR-004: Central identity with Authentik + custom tldraw backend on k3s

Date: 2026-06-29
Status: Proposed
Supersedes: nothing
Superseded by: nothing

## Context

The Supreme Leader wants to deploy a self-hosted tldraw instance (`white-board.voitech.dev`) that supports real-time collaboration, authentication, and a project/room model. The initial request pointed at `https://tldraw.dev/quick-start`, which is the developer SDK.

After analysis (see tracking note `2026-06-29-tldraw-deployment-proposal.md`), it is clear that:

1. tldraw.com is the full product; the open SDK gives us the canvas and the `tldraw sync` engine.
2. `tldraw sync` provides WebSocket rooms, client synchronization, and asset hooks, but explicitly does **not** provide authentication, authorization, project/room registry, or long-term snapshots.
3. Building those missing pieces is a custom application, not a third-party Helm install.
4. The Supreme Leader also wants to stop the current pattern where every service has its own local credentials, and instead move toward a single identity provider for the whole homelab.

This ADR records the decision to:

- Add **Authentik** as the central identity provider for the homelab.
- Build a **custom tldraw sync backend** for `white-board.voitech.dev`.
- Use **CloudNativePG** for every Postgres instance (Authentik DB + tldraw project DB).
- Use **OMV MinIO** for durable object storage (assets, snapshots, and all CNPG backups).
- Use **Cloudflare Tunnels** for public ingress.
- Keep all secrets **SOPS-encrypted** in the public repo.

## Decision

### 1. Central identity provider: Authentik

Deploy Authentik in a new `auth` namespace as shared infrastructure. It becomes the single source of truth for homelab users and groups.

- **Domain:** `auth.voitech.dev`
- **Database:** CloudNativePG Postgres 16 cluster, backups + WAL to OMV MinIO
- **Cache/queue:** Redis Deployment in the `auth` namespace, backed by a `local-path` PVC
- **Ingress:** Cloudflare Tunnel, TLS at the edge
- **Initial users:** Supreme Leader + wife, plus any future users/groups
- **First application:** tldraw OIDC provider
- **Future applications:** Mattermost, Nextcloud, Grafana, LiteLLM, Open WebUI — wherever OIDC/SAML/LDAP is supported

### 2. tldraw backend: custom Node application

Instead of using the community `foxxmd/tldraw` wrapper, build a small custom backend using the official `@tldraw/sync-core` and `@tldraw/sync` packages.

Responsibilities of the backend:

- Serve the React frontend.
- Authenticate users via Authentik OIDC (JWT validation).
- Enforce authorization: users can only access projects/rooms they belong to.
- Maintain a project/room registry in Postgres.
- Manage `TLSocketRoom` instances using `SQLiteSyncStorage` for active state.
- Upload/download assets via a custom `TLAssetStore` implementation talking to OMV MinIO.
- Periodically snapshot room state to OMV MinIO for long-term durability.
- Expose `/metrics` for Prometheus and log to stdout for the OTel Collector.

### 3. Storage topology

| Data | Location | Rationale |
|------|----------|-----------|
| Authentik Postgres live data | `local-path` PVC on homelab-2nd | Fast, low-latency OLTP |
| Authentik Postgres backups + WAL | OMV MinIO | Durability |
| tldraw project/room metadata live data | `local-path` PVC on homelab-2nd | Fast, low-latency |
| tldraw project/room metadata backups + WAL | OMV MinIO | Durability |
| Active tldraw room state (SQLite) | `local-path` PVC on homelab-2nd | tldraw sync's recommended production storage |
| Long-term room snapshots | OMV MinIO S3 | Durability |
| User-uploaded images/videos | OMV MinIO S3 | Large binary object storage |
| Redis data for Authentik | `local-path` PVC on homelab-2nd | Cache is rebuildable |

This follows the established homelab rule: **live data on local-path, durable data on OMV MinIO**.

### 4. Ingress

Both `auth.voitech.dev` and `white-board.voitech.dev` are exposed via dedicated Cloudflare Tunnels. TLS is terminated at the Cloudflare edge; internal traffic is plain HTTP over the cluster network. No cert-manager or router ports are opened.

### 5. Secrets

All credentials (Postgres passwords, MinIO keys, Authentik secret key, OIDC client secret, tldraw license key, Redis password) are stored as SOPS-encrypted Kubernetes Secrets using the existing age public key in `.sops.yaml`. The age private key remains in the Supreme Leader's password manager.

### 6. Container images

The custom tldraw backend and frontend are built as a single container image via GitHub Actions and pushed to `ghcr.io/gulasz101/tldraw-homelab`. The Dockerfile lives in the repo. Flux references a pinned image tag; image updates are handled by bumping the tag in Git (not by auto-tag-latest).

### 7. Observability

- Logs: container stdout/stderr → OTel Collector DaemonSet → Loki.
- Metrics: Prometheus scrapes `/metrics` via ServiceMonitor.
- Traces: optional OTLP if we add tracing to the backend.
- Dashboard: Grafana "Homelab" folder, provisioned via ConfigMap.

## Consequences

### Positive

- **Single identity:** One login for the whole homelab; no more per-service password sprawl.
- **Matches homelab guardrails:** Flux + HelmFirst where possible, CNPG for Postgres, OMV MinIO for objects, Cloudflare Tunnel ingress, SOPS secrets, full observability.
- **Blog-worthy:** The post can show how to build a real product on top of tldraw sync, not just run a demo.
- **Extensible:** Once Authentik is in place, adding OIDC to Mattermost, Nextcloud, Grafana, etc. becomes a configuration task, not a new architecture.

### Negative / Risks

- **Custom code:** We own the authz logic, room lifecycle, and snapshot logic. Bugs are ours.
- **License:** A non-localhost deployment requires a tldraw license (hobby license is free but requires application).
- **Single replica for room state:** SQLite active state is per-pod. For a single-node homelab this is fine, but it limits horizontal scaling without re-architecting room placement.
- **Maintenance:** Another moving part (Authentik) to keep updated and backed up.
- **Time:** This is a multi-phase build, not a one-evening Helm install.

## Alternatives considered

| Option | Why rejected |
|--------|--------------|
| foxxmd/tldraw-selfhosted Docker image | No auth, no projects, local file storage only. Does not meet requirements. |
| Keycloak | Mature but heavier and more complex to operate than Authentik for a homelab. Authentik has a cleaner UX and better proxy/OIDC outpost support. |
| Dex + oauth2-proxy | Dex is thin and oauth2-proxy is app-specific; would not give a central admin UI or room/project data model. |
| Standalone Postgres chart for tldraw | Violates guardrail #3: CloudNativePG must be used for all Postgres. |
| Storing assets on homelab-2nd local disk | Violates guardrail #4: large/durable data belongs on OMV. |
| Public ingress via cert-manager + router ports | Violates guardrail #8: Cloudflare Tunnel is the agreed public ingress model. |

## When to revisit

- If tldraw ships an official self-hosted product with auth and projects.
- If the homelab grows beyond one node and we need multi-replica room state sharing.
- If Authentik proves too heavy and we want to migrate to a lighter OIDC provider.
- If we start using Authentik for reverse-proxy auth (proxy provider) and want to consolidate more services behind it.

## References

- Tracking note: `homelab/tracking/2026-06-29-tldraw-deployment-proposal.md`
- Architecture diagram: `docs/tldraw-option-b-full-plan-architecture.html`
- tldraw sync docs: https://tldraw.dev/docs/sync
- Authentik Kubernetes install docs: https://docs.goauthentik.io/docs/install-config/install/kubernetes
- Homelab skill: `homelab-gitops`

