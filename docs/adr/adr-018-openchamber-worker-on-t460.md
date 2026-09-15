# ADR-018: OpenChamber worker — t460 container, split local/dur able storage

## Status

Accepted — 2026-09-14 · amended 2026-09-15 (durability, GitHub access, OMV NFS)

## Context

The Supreme Leader asked for **OpenChamber** — a self-hosted web workspace around the OpenCode
coding agent — to be reachable remotely, protected by Authentik SSO, exposed as
`openchamber.voitech.dev` through a dedicated Cloudflare Tunnel, and usable as an **Itsaplan**
worker. It was pinned to `t460`, the idle 4c/7.6G node. OpenCode inside it must reach homelab
Firecrawl, OpenViking and docs-mcp, and use OpenCode Go models through LiteLLM with the
vendor-required `x-opencode-session` header preserved.

The two things the worker must not lose: **session history** and the ability to **commit to GitHub**.

Constraints:

- The homelab is GitOps-on-k3s (Flux + Helm). Anything not in the repo does not exist.
- `t460` is already a k3s **worker** and runs no hypervisor (no libvirt, no KubeVirt).
- OMV is the only durable store. Its NFS exports are per-client-IP subpaths.
- OpenChamber has no native OIDC.
- OpenCode Go requires a stable `x-opencode-session` header per conversation.

## Decision

1. **Run OpenChamber as a single-pod Deployment pinned to `t460`**, from a purpose-built Ubuntu
   24.04 image (`ghcr.io/gulasz101/openchamber-web`) containing Node 22, the OpenCode CLI,
   OpenChamber and the `gh` CLI — not a VM (no hypervisor on t460, and a VM would escape Flux).
2. **Split storage between durable NFS and local NVMe.**
   - `/storage` → **OMV NFS** share `/srv/dev-disk-by-uuid-cda9bf6e…/openchamber/data`, exported to
     `192.168.1.111` (t460). Holds OpenChamber settings/device tokens, the seeded OpenCode config
     and the workspace clones.
   - `/var/lib/openchamber` → **t460 local NVMe** (`local-path` PVC). Holds the OpenCode **SQLite**
     session database and state.
   - Rationale: SQLite runs in **WAL mode**, which needs shared memory (`-shm`) and is explicitly
     unsupported on NFS. The homelab guardrail already says "live DBs → local NVMe; durability →
     MinIO", so this split applies the guardrail rather than fighting it.
3. **Durability for the local NVMe data is a CronJob** (hourly, minute 20) that snapshots
   everything — NFS *and* local volumes — to `s3://cnpg-backups/openchamber/` with 14-day
   retention, using SQLite's online-backup API (WAL-safe). The archive is under 1 MB and the run
   takes seconds, so an hourly cadence costs nothing and keeps the worst-case loss small.
4. **Persist OpenCode's data/state on the PVC.** OpenCode stores sessions in SQLite under
   `~/.local/share/opencode` and **ignores `OPENCODE_DATA_DIR`**; by default that path lives in the
   container filesystem and is lost on every restart. It is mounted from the local NVMe PVC via
   `subPath` (`opencode-data`, `opencode-state`).
5. **GitHub access by token, never on disk.** `GITHUB_TOKEN` comes from a SOPS secret; the entrypoint
   configures an env-based `credential.<https://github.com>.helper` plus git identity, and exports
   `GH_TOKEN` so `gh` works for PR workflows.
6. **The OpenCode provider is the native `opencode-go` provider with `baseURL` pointed at LiteLLM.**
   Only the native provider emits `x-opencode-session`; a custom OpenAI-compatible provider emits
   `x-session-id`/`x-session-affinity`, which the gateway rejects. LiteLLM forwards client headers
   (`forward_client_headers_to_llm_api: true`) so the header reaches `opencode.ai/zen/go`.
7. **SSO is enforced by `oauth2-proxy` against Authentik.** A dedicated Authentik OAuth2 provider +
   application ("OpenChamber OIDC" / `openchamber`) is declared in the existing blueprint. The
   Cloudflare Tunnel fronts oauth2-proxy, not OpenChamber directly.
8. **Itsaplan integration reuses `@itsaplan/runner`** but calls the OpenChamber HTTP API instead of a
   Hermes webhook, so every task becomes a visible OpenChamber session.

## Consequences

**Positive**

- One Flux app, one image, one node selector — rebuildable, fully GitOps.
- Settings, device tokens, config and workspaces live on OMV: a t460 rebuild needs no restore for
  them.
- Sessions survive pod restarts (verified) and are recoverable from MinIO (verified restorable — the
  archived SQLite still contains the session rows).
- The MinIO backup credential is now a **scoped user** (`cnpg-openchamber-backup`) with a
  prefix-conditional policy; the root credential is no longer stored anywhere in the cluster.
- The worker can commit and push to GitHub; `gh` is available for PR workflows.
- `x-opencode-session` forwarding is verified end-to-end (a raw request without it is rejected).
- Logs flow to Loki via the OpenTelemetry Collector DaemonSet.

**Negative**

- `/storage` now depends on OMV NFS: if OMV/NFS is unavailable the pod cannot start (a new failure
  mode). This is the price of durability and matches the rest of the homelab.
- Live session data is local NVMe by design; the hourly backup bounds its loss to **1 hour**.
- `oauth2-proxy` is a new in-cluster component and a new pattern (the homelab otherwise does
  app-native OIDC).
- `forward_client_headers_to_llm_api` is a **global** LiteLLM setting.
- One-off node bootstrap was required (see below) — node-level state that GitOps does not cover.

### One-off node bootstrap (outside GitOps, documented)

`t460` had **no `nfs-common`**, so NFS mounts failed with
`fsconfig() failed: NFS: mount program didn't pass remote address`. t460's login user has no
passwordless sudo, so a short-lived **privileged pod** (`hostPID` + `nsenter`) installed
`nfs-common` (nfs-utils 2.8.3) on the node. This is node bootstrap, analogous to installing k3s,
and is recorded here and in the tracking note. Any future node added to the cluster needs
`nfs-common` before it can mount OMV NFS.

## Alternatives considered

- **A real VM (libvirt/KubeVirt) on t460.** Rejected: no hypervisor, and it would live outside Flux.
- **The whole `/storage` on NFS, including the SQLite DB.** Rejected: SQLite WAL needs shared
  memory and is unsafe on NFS; it would risk database corruption.
- **Everything on local NVMe with only S3 backups (the earlier design).** Rejected as the final
  state: it left settings/workspaces non-durable and the backup window as the only protection.
- **A scoped user created from inside the cluster.** Impossible: `minio/mc` and `minio/minio` images
  are no longer pullable, and MinIO encrypts the `add-user` admin API body (madmin), so plain SigV4
  calls return `XMinioAdminConfigBadJSON`. The user was therefore created on OMV.
- **Storing the GitHub token on disk (`~/.git-credentials`).** Rejected: the token stays in the
  environment, consumed by a credential helper.
- **Cloudflare Access only, no in-cluster SSO.** Rejected as the sole control: it depends on
  dashboard configuration not in Git and not testable from CI.

## When to revisit

- If the 1-hour RPO is still too loose → consider replicating the SQLite DB continuously, or accept
  the NFS/WAL trade-off differently.
- If OMV NFS becomes a reliability problem → consider a ReadWriteOnce NFS PV with `nconnect`, or
  fall back to local NVMe + more frequent backups.
- If LiteLLM gains per-model-group header forwarding → scope `forward_client_headers_to_llm_api`.
- If OpenChamber adds native OIDC → retire `oauth2-proxy`.
