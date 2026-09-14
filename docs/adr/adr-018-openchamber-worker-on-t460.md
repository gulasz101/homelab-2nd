# ADR-018: OpenChamber worker as a t460-pinned container, not a VM

## Status

Accepted — 2026-09-14

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

## Decision

1. **Run OpenChamber as a single-pod Deployment pinned to `t460`** (`nodeSelector:
   kubernetes.io/hostname: t460`), from a purpose-built Ubuntu 24.04 image
   (`ghcr.io/gulasz101/openchamber-web`, built in CI) containing Node 22, the OpenCode CLI and
   OpenChamber. Not a VM: a VM would need hypervisor plumbing that does not exist on t460 and would
   escape Flux. The pod is the "bigger box" the user asked for.
2. **Live data on t460 `local-path`** (`/storage`, 30Gi), because OMV NFS cannot be mounted there
   today. Durability is to be provided by a MinIO backup CronJob, mirroring the Karakeep pattern;
   moving to OMV NFS is a follow-up once t460 is added to an export.
3. **OpenCode's provider is the native `opencode-go` provider with `baseURL` pointed at LiteLLM.**
   Only the native provider emits `x-opencode-session`; a custom OpenAI-compatible provider emits
   `x-session-id`/`x-session-affinity`, which the gateway rejects. LiteLLM forwards client headers
   (`forward_client_headers_to_llm_api: true`) so the header reaches `opencode.ai/zen/go`.
4. **SSO is enforced by `oauth2-proxy` against Authentik**, because OpenChamber has no native OIDC.
   A dedicated Authentik OAuth2 provider + application ("OpenChamber OIDC" / `openchamber`) is
   declared in the existing Authentik blueprint. The Cloudflare Tunnel fronts oauth2-proxy, not
   OpenChamber directly.
5. **Itsaplan integration reuses `@itsaplan/runner`** but calls the OpenChamber HTTP API instead of a
   Hermes webhook, so every Itsaplan task becomes a visible OpenChamber session.

## Consequences

**Positive**

- One Flux app, one image, one node selector — trivially rebuildable, fully GitOps.
- Sessions created from Itsaplan are visible in the OpenChamber UI, so the work can be watched and
  continued by hand.
- The `x-opencode-session` requirement is met end-to-end and independently verified (a raw request
  without the header is rejected by the vendor; an OpenCode request succeeds).
- All three homelab MCP servers (OpenViking, docs-mcp, Firecrawl) are connected inside the worker.

**Negative**

- Live session data is on a single node's local disk and is **not durable until the MinIO backup
  job exists**; a t460 disk failure loses sessions.
- `oauth2-proxy` is a new in-cluster component and a new pattern (the homelab otherwise does
  app-native OIDC).
- `forward_client_headers_to_llm_api` is a **global** LiteLLM setting; client headers are now
  forwarded to every upstream. It works for the providers already in use, but it is broader than
  ideal.
- A custom image must be rebuilt in CI to bump OpenChamber/OpenCode versions.

## Alternatives considered

- **A real VM (libvirt/KubeVirt) on t460.** Rejected: no hypervisor on t460, and it would live
  outside Flux. The user's intent ("a bigger box with everything included") is satisfied by a
  container with a full toolchain.
- **Use the openchamber repo's own `oven/bun` Dockerfile.** Rejected in favour of a thin Ubuntu +
  npm-package image: far smaller, faster to build, and no source checkout to pin.
- **Run OpenChamber on `homelab-2nd` where OMV NFS already works.** Rejected: the user explicitly
  asked for t460, which is idle.
- **Enforce SSO with Authentik's forward-auth outpost.** Rejected in favour of oauth2-proxy —
  fewer moving parts for a WebSocket/SSE-heavy app.
- **Cloudflare Access only (no in-cluster SSO).** Rejected as the sole control: it depends on
  dashboard configuration that is not in Git and cannot be tested from CI. It remains an optional
  extra layer.
- **A custom OpenAI-compatible provider + a header-renaming sidecar.** Rejected: the native provider
  already emits the right header; no extra component needed.

## When to revisit

- When `t460` is added to an OMV NFS export → move `/storage` to NFS and drop the local-path PVC.
- If LiteLLM gains per-model-group header forwarding → scope
  `forward_client_headers_to_llm_api` off the global setting.
- If OpenChamber adds native OIDC → retire `oauth2-proxy` and use the app-native OIDC pattern.
- If session volume outgrows 30Gi or the backup job proves insufficient.
