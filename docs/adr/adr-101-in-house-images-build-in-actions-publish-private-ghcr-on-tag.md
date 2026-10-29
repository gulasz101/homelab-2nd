# ADR-101: In-house app images are built and smoked in GitHub Actions, published to private GHCR on a version tag

- **Status:** Accepted
- **Date:** 2026-10-29
- **Deciders:** Wojtek (owner), Andrzej (CTO, homelab-2nd)
- **Tracked by:** GUL-549 (first application: Riff Radar), GUL-262
- **Supersedes:** nothing

## Context

Three services now run images we build ourselves: `star-office-ui-fork`, `openchamber`, and — new
today — `riff_radar`. Each one had to answer the same four questions, and each answered them at a
different time, in a different file, from memory:

1. **Where does the build happen?** No k3s node has a container runtime worth trusting for builds,
   and `homelab-2nd` is the control plane, not a CI box.
2. **How does a new version reach the cluster?** Flux reads a tag. If a merge to `main` published
   `latest`, Flux would never notice the move (ADR-092 showed exactly how long `latest` can sit
   still in a running cluster).
3. **What guarantees the image runs at all?** `riff_radar`'s `Dockerfile` had a `HEALTHCHECK` that
   called `curl`, which `oven/bun:1-slim` does not ship. It would have failed forever and nobody
   would have known until the first deploy. The tag is not the risk; the image is.
4. **Who can pull it?** The source is private, so the image must be private too. A public GHCR
   package for a private repo is a source leak wearing a different hat.

## Decision

For every image we build from our own source:

- **Build on GitHub's amd64 runners**, in the app's own repository, from a workflow in
  `.github/workflows/`. `--platform linux/amd64` explicitly: every node in the cluster is amd64.
- **One job, one build.** The image that gets smoked is the image that gets pushed. A rebuild after
  the smoke tests a different artifact and proves nothing.
- **Smoke before publish**, against the real runtime env: start the container with a throwaway
  secret, wait for its health endpoint, and assert the thing it is supposed to do (for Riff Radar:
  seed a database, serve `/api/brand`). Publishing happens only after that passes.
- **Publish on a pushed version tag** `v*.*.*`, as `ghcr.io/gulasz101/<repo>:<version>` plus
  `:sha-<short>` for traceability. A merge to `main` never publishes. `pull_request` runs the same
  build and smoke and publishes nothing, so the PR proves the image before the tag exists.
- **Authenticate with the workflow's own `GITHUB_TOKEN`** and `permissions: packages: write`. No
  registry credentials in repo secrets — nothing to leak, nothing to rotate.
- **Keep the package private.** Tag the image with
  `org.opencontainers.image.source=https://github.com/gulasz101/<repo>` so GHCR links the package to
  the private repo and inherits its visibility instead of defaulting to public. Verify visibility
  after the first publish, do not assume it.
- **The app owns its `HEALTHCHECK`; the cluster owns its probes.** If the runtime base image lacks
  the tool a healthcheck wants, ask the runtime you do have (Riff Radar: `bun -e fetch(...)`), do not
  add `curl` to a slim image to satisfy a check.

The deploy side stays per-app: each service gets its own `HelmRelease`, its own `ImagePolicy` with a
semver range (the star-office pattern), and its own pull secret when the package is private.

## Consequences

- A published tag always corresponds to an image that booted and answered. The cluster cannot be the
  first place a broken image runs.
- The release event is a tag, so the human act of tagging is the act of publishing. Flux's semver
  `ImagePolicy` then has something honest to compare against, and no `latest` drift.
- Nothing secret lives in the repo: `GITHUB_TOKEN` covers GHCR, and the private package is protected
  by the same access control as the source.
- Cost: every publish needs a runner (free on public repos, minutes on private), and the smoke adds
  a minute or two to each run. Cheap next to debugging a dead image in the cluster.
- Cost: the smoke is only as good as its assertions. It caught three real bugs in Riff Radar
  (`bun install` on a pruned checkout, a workspace `node_modules` left out of the runtime stage, a
  seed that resolved paths from `process.cwd()`) and one in itself — an assertion that grepped for a
  log line the program never prints. Assert on what the program actually says.
- The image is not hardened by this: `oven/bun` runs as root unless told otherwise. Each deploy has
  to add `runAsNonRoot` and a writable data volume, or the image needs a non-root user with the data
  directories chowned. Riff Radar ships as root today; that is a deploy-issue decision.

## Alternatives considered

- **Build on a k3s node** (BuildKit on `homelab-2nd`): the control plane would then need a runtime,
  disk for layer caches, and root-ish privileges; and it would be unavailable exactly when the
  cluster is being rebuilt. Rejected — the cluster should consume images, not produce them.
- **Publish `latest` on merge to `main`**: needs `imagePullPolicy: Always` and a rollout restart to
  take effect, and gives Flux nothing to pin. This is the failure ADR-092 documented for
  `cloudflared`. Rejected.
- **Push to a self-hosted registry** (Harbor on OMV): one more stateful service to back up and
  secure for no capability GHCR does not already have. Rejected for now.
- **Trust `docker build` success as proof**: exactly the trap that shipped the broken `HEALTHCHECK`.
  Rejected.

## When to revisit

- If GitHub Actions minutes become the bottleneck, or a build needs more than a runner can give.
- If a service needs multi-arch images (arm64 arrives with a real arm64 worker).
- If we start publishing images for repos that are public — the private-package rule then needs a
  per-repo exception, written here.
- If Renovate-style automated tag bumps are introduced: the tag becomes a machine event, and the
  smoke in front of the push matters even more.
