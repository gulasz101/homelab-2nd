# ADR-018: OpenChamber worker as a t460-pinned container, not a VM

## Status

Accepted — 2026-09-14 · amended 2026-09-15 (durability, GitHub access)

## Context

The Supreme Leader asked for **OpenChamber** — a self-hosted web workspace around the OpenCode
coding agent — to be reachable remotely, protected by Authentik SSO, exposed as
`openchamber.voitech.dev` through a dedicated Cloudflare Tunnel, and usable as an **Itsaplan**
worker. It was to be pinned to `t460`, the idle 4c/7.6G node, "as some sort of Ubuntu image … or a
bigger VM". OpenCode inside it must reach homelab Firecrawl, OpenViking and docs-mcp, and use
OpenCode Go models through LiteLLM with the vendor-required `x-opencode-session` header preserved.

Constraints:

- The homelab is GitOps-on-k3s (Flux + Helm). Anything not in the repo does not exist.
- `t460` is already a k3s **worker** and runs no hypervisor (no libvirt, no KubeVirt).
- OMV is the only durable store, and its NFS exports are per-client-IP subpaths; **`t460` is not in
  any export**, and the export root is read-only, so no new subpath can be created from the cluster.
- OpenChamber has no native OIDC.
- OpenCode Go requires a stable `x-opencode-session` header per conversation.
- Session history and the ability to commit to GitHub are the two things the worker must not lose.

## Decision

1. **Run OpenChamber as a single-pod Deployment pinned to `t460`** (`nodeSelector:
   kubernetes.io/hostname: t460`), from a purpose-built Ubuntu 24.04 image
   (`ghcr.io/gulasz101/openchamber-web`, built in CI) containing Node 22, the OpenCode CLI,
   OpenChamber and the `gh` CLI. Not a VM: a VM would need hypervisor plumbing that does not exist
   on t460 and would escape Flux.
2. **Live data on t460 `local-path`** (`/storage`, 30Gi) because OMV NFS cannot be mounted there
   today. Durability is provided by a **CronJob every 6 hours** that snapshots the data to
   `s3://cnpg-backups/openchamber/` on OMV MinIO with 14-day retention (SQLite online-backup for
   the sessions DB). Moving `/storage` to OMV NFS is a follow-up once t460 is added to an export.
3. **Persist OpenCode's data/state on the PVC.** OpenCode stores its sessions in a SQLite database
   under `~/.local/share/opencode` and **ignores `OPENCODE_DATA_DIR`**; by default that path lives in
   the container filesystem and is lost on every restart. It is therefore mounted from the PVC via
   `subPath` (`opencode-data`, `opencode-state`).
4. **GitHub access is granted by token, not by writing a credential to disk.** `GITHUB_TOKEN` comes
   from a SOPS secret; the entrypoint configures an env-based `credential.<https://github.com>.helper`
   and git identity, and exports `GH_TOKEN` so the `gh` CLI works for PR workflows.
5. **OpenCode's provider is the native `opencode-go` provider with `baseURL` pointed at LiteLLM.**
   Only the native provider emits `x-opencode-session`; a custom OpenAI-compatible provider emits
   `x-session-id`/`x-session-affinity`, which the gateway rejects. LiteLLM forwards client headers
   (`forward_client_headers_to_llm_api: true`) so the header reaches `opencode.ai/zen/go`.
6. **SSO is enforced by `oauth2-proxy` against Authentik**, because OpenChamber has no native OIDC.
   A dedicated Authentik OAuth2 provider + application ("OpenChamber OIDC" / `openchamber`) is
   declared in the existing Authentik blueprint. The Cloudflare Tunnel fronts oauth2-proxy, not
   OpenChamber directly.
7. **Itsaplan integration reuses `@itsaplan/runner`** but calls the OpenChamber HTTP API instead of a
   Hermes webhook, so every Itsaplan task becomes a visible OpenChamber session.

## Consequences

**Positive**

- One Flux app, one image, one node selector — trivially rebuildable, fully GitOps.
- Sessions survive pod restarts (verified) and are not lost by the node: they are on the PVC and
  shipped to MinIO every 6 hours (verified restorable — the archived SQLite still contains the
  session rows).
- The worker can commit and push to GitHub, and `gh` is available for PR workflows.
- The `x-opencode-session` requirement is met end-to-end and independently verified (a raw request
  without the header is rejected by the vendor; an OpenCode request succeeds).
- Logs flow to Loki via the OpenTelemetry Collector DaemonSet.

**Negative**

- Live session data is on a single node's local disk; the 6-hour RPO is real. A t460 disk failure
  between backups loses that window.
- The MinIO backup secret currently holds the **MinIO root credentials**, because MinIO encrypts the
  `add-user` admin API body (madmin format) and the `minio/mc` image is no longer pullable, so a
  scoped user could not be created from the cluster. This is the main security debt of this ADR.
- `oauth2-proxy` is a new in-cluster component and a new pattern (the homelab otherwise does
  app-native OIDC).
- `forward_client_headers_to_llm_api` is a **global** LiteLLM setting; client headers are now
  forwarded to every upstream.
- A custom image must be rebuilt in CI to bump OpenChamber/OpenCode versions.

## Alternatives considered

- **A real VM (libvirt/KubeVirt) on t460.** Rejected: no hypervisor on t460, and it would live
  outside Flux.
- **Durable NFS storage for `/storage`.** Preferred in principle, but OMV exports are per-client-IP
  and t460 is not in one; adding the export needs OMV access that is not available from the cluster.
- **MinIO backups to a prefix owned by an existing scoped user** (e.g. the OpenViking user).
  Rejected: MinIO users here are prefix-scoped, and pretending OpenChamber data is OpenViking data is
  worse than the current debt.
- **Creating a scoped MinIO user from the cluster.** Attempted and abandoned: `minio/mc` and
  `minio/minio` images are no longer pullable, and the admin `add-user` body is madmin-encrypted, so
  plain SigV4 admin calls return `XMinioAdminConfigBadJSON`.
- **Storing the GitHub token on disk (`~/.git-credentials`).** Rejected: the token stays in the
  environment and is consumed by a credential helper.
- **Enforce SSO with Authentik's forward-auth outpost.** Rejected in favour of oauth2-proxy.
- **Cloudflare Access only (no in-cluster SSO).** Rejected as the sole control: it depends on
  dashboard configuration that is not in Git and cannot be tested from CI.

## When to revisit

- When t460 is added to an OMV NFS export → move `/storage` to NFS and drop the local-path PVC.
- When a scoped MinIO user can be created for `cnpg-backups/openchamber/*` → replace the root creds
  in `openchamber-minio-backup-creds`.
- If the 6-hour RPO is too loose → shorten the CronJob or move to NFS.
- If LiteLLM gains per-model-group header forwarding → scope
  `forward_client_headers_to_llm_api` off the global setting.
- If OpenChamber adds native OIDC → retire `oauth2-proxy`.
