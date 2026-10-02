# ADR-023: OpenChamber worker on OpenChamber 2 / OpenCode 2

## Status

Accepted — 2026-09-30 · amends ADR-018 (same worker, new runtime)

**Amended by [ADR-024](adr-024-openchamber-2.1.0-upgrade.md)** (2026-10-02). The
decision to run the worker on OpenCode 2 stands. Two things in this ADR are
corrected or refined there: the claim in §5 and in *When to revisit* that the
worker "is pinned and does not self-update" turned out to be **false** — an
in-pod `POST /api/opencode/upgrade` moved `@opencode/cli` 2.0.20 → 2.0.22 on
2026-10-02 — and the Dockerfile pin is now treated as a floor rather than a
ceiling.

## Context

The t460 OpenChamber worker (ADR-018) ran `@openchamber/web@1.23.1` on the
OpenCode 1.x CLI (`opencode-ai@1.18.30`). The UI began offering the jump to
**2.0.4**, and 2.0.0 (2026-09-23) is not a normal minor: it **moves OpenChamber
onto OpenCode 2** and requires **OpenCode >= 2.0.15**. On OpenCode 1.x the app
refuses to run and shows an update screen.

Two facts made this non-trivial:

1. **OpenCode 2 is a different distribution.** It is not `opencode-ai` (that npm
   line stops at `1.18.33`). It ships as **`@opencode/cli`** — a compiled Bun
   binary delivered via per-platform optional deps (`@opencode/cli-linux-x64`,
   ~204 MB) with an npm `postinstall` that hardlinks the right binary into
   `bin/`. Upgrading the app therefore also swaps the agent runtime.
2. **Our integration surface is bespoke.** ADR-018/019 depend on: the native
   `opencode-go` provider pointed at LiteLLM with the `x-opencode-session`
   header; the Itsaplan bridge calling OpenChamber HTTP routes directly; and a
   split storage layout (`/storage` OMV NFS, `/var/lib/openchamber` local NVMe).

The worker session that did the build runs *inside the pod*, with no cluster
RBAC and a GitOps-only mandate, so it cannot perform the live deploy itself.

## Decision

1. **Upgrade to OpenChamber 2.0.4 + `@opencode/cli@2.0.20` + `bun@1.4.2`**, from
   the same purpose-built Ubuntu 24.04 image (`ghcr.io/gulasz101/openchamber-web`).
   Versions stay pinned ARGs in `build/openchamber/Dockerfile`; the workflow
   tags immutably (`2.0.4-r1` + `latest`).
2. **Keep the two-commit GitOps ordering.** Commit 1 rebuilds and pushes the
   image; only once the tag exists in GHCR does commit 2 flip the Deployment's
   image tag. This avoids Flux pulling a tag that does not exist yet.
3. **Preserve the storage split and the integration surface.** `/storage` stays
   on OMV NFS, `/var/lib/openchamber` stays on local NVMe; the Itsaplan bridge
   HTTP routes and the seed `opencode.json` (native `opencode-go`, `skills.paths`,
   `mcp`, permissions) carry over unchanged.
4. **Move the UI password off the command line.** The entrypoint no longer passes
   `--ui-password`; OpenChamber reads `OPENCHAMBER_UI_PASSWORD` from the
   environment (already set from the SOPS secret). This closes H2-36.
5. **Accept Bun into the image.** Upstream's own container images ship Bun;
   OpenChamber prefers it for its daemon/update paths and falls back to Node.
   The worker is pinned and does not self-update, so Bun is a compatibility
   choice, not a requirement.

## Consequences

**Positive**

- One Flux app, one image, one node selector — still rebuildable from Git.
- The SQLite session DB migrates in place; sessions from OpenCode 1.x carry over.
- OpenCode 2 hot-reloads config, skills, agents, MCP and plugins on save, so
  worker behaviour (skill, agent prompt, MCP set) can be changed without a
  restart — a better GitOps loop than 1.x.
- The UI password no longer leaks through `ps` / `/proc/<pid>/cmdline`.

**Negative**

- **The DB migration is effectively one-way.** Once OpenCode 2 has migrated the
  SQLite DB, rolling the pod back to 1.23.1 may not be able to read it. The
  rollback path therefore includes restoring `opencode-data` from a pre-upgrade
  MinIO archive, not just reverting the image tag.
- **New runtime, same bespoke config.** `opencode-go` + LiteLLM +
  `x-opencode-session`, and `skills.paths`, must be re-proven live; they are
  configured-compatible on paper (checked against the OpenCode 2 `config.json`
  schema) but only a live round-trip proves the header still reaches the gateway.
- Heavier pod (the OpenCode 2 binary is large): the 3 Gi memory limit is watched
  by the existing `openchamber-resources` PrometheusRule.
- A one-off, few-minute outage on deploy (`Recreate` + RWO `local-path` on t460).

## Alternatives considered

- **Stop at OpenChamber 1.24.2 (last 1.x).** Rejected: buys a little time but
  anchors on a runtime (OpenCode 1.x) the app has already moved off; we would do
  the OpenCode 2 migration later anyway, on a line that no longer gets fixes.
- **Install OpenChamber 2.0.4 and leave OpenCode at 1.18.30.** Rejected: 
  OpenChamber 2 requires OpenCode >= 2.0.15 and will not start.
- **Keep `opencode-ai` and pin a 2.x from that name.** Rejected: no such
  release exists; the distributor changed names.
- **`kubectl set image` / hand-apply during the deploy.** Rejected: breaks the
  GitOps guardrail (GitOps is law). The window is handled by an ordered commit,
  not by imperative mutation.
- **Install Bun from the GitHub release tarball instead of the npm package.**
  Rejected for now: the npm `bun@1.4.2` package ships matching `bun`/`bunx`
  bin stubs and installs into the existing global prefix with no extra plumbing;
  the tarball route is there if the npm package proves awkward on future archs.

## When to revisit

- If OpenCode 2 changes the native `opencode-go` provider or drops
  `x-opencode-session` → revisit the LiteLLM baseURL shim (ADR-018 §6).
- If the SQLite migration is ever non-destructive in reverse → simplify the
  rollback runbook to a tag revert alone.
- If OpenChamber adds native OIDC → retire `oauth2-proxy` (ADR-018).
- If the worker's footprint approaches the 3 Gi limit → raise it or drop Bun.
- If OpenChamber self-update is ever enabled in the pod → revisit the pinning
  (an in-pod updater would fight the immutable image).
