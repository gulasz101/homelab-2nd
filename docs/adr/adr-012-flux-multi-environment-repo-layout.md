# ADR-012: Multi-environment Flux repo layout (`clusters/production` + `clusters/staging`)

**Status:** Accepted  
**Date:** 2026-09-12  

## Context

The homelab runs a single k3s cluster (`homelab-2nd`) reconciled by Flux from `gulasz101/homelab-2nd`. Since bootstrap the cluster root lived in `clusters/homelab-2nd/`, a directory named after the physical machine rather than the environment it serves. The plan is to add a second, staging cluster for testing manifests before they reach the production workloads.

Two facts about how Flux reads this repo drive the layout:

1. The in-cluster root `Kustomization` (`flux-system`) has a `spec.path` that points at a directory in Git, and it re-applies its own definition (`clusters/<env>/flux-system/gotk-sync.yaml`) on every reconcile.
2. The child Kustomizations (`apps`, `infrastructure`, `cert-manager`) are declared alongside the `flux-system/` directory in the same cluster path and are owned by the root Kustomization build. Their own `spec.path` values (`./apps`, `./infrastructure`) are repo-root-relative and independent of the cluster directory name.

A rename from `clusters/homelab-2nd` to `clusters/production` therefore has to flip the in-cluster root `spec.path` in a way that is observable between Git commits. Doing it in one commit leaves the live root pointing at a directory that no longer exists, freezing the sync.

## Decision

Adopt path-based environments under `clusters/`:

```
clusters/
├── production/          # live homelab-2nd cluster (renamed from homelab-2nd)
│   ├── apps.yaml
│   ├── infrastructure.yaml
│   ├── cert-manager.yaml
│   └── flux-system/
│       ├── gotk-components.yaml
│       ├── gotk-sync.yaml      # root Kustomization, path: ./clusters/production
│       └── kustomization.yaml
└── staging/             # inert skeleton until a staging cluster is bootstrapped
    └── flux-system/
```

1. **`clusters/production` is the live environment.** It is the renamed former `clusters/homelab-2nd`, byte-for-byte identical apart from the `spec.path` and the reference fixes in `README.md` and `scripts/homelab-security-scan.sh`.
2. **`clusters/staging` is a skeleton.** It contains the copied `flux-system/` trio and an `apps.yaml` pointed at `apps/overlays/staging`, but nothing reconciles it until a staging machine is bootstrapped with `flux bootstrap ... --path=clusters/staging`. A staging cluster must never be bootstrapped against `clusters/production`, and vice versa.
3. **Child Kustomization paths stay root-relative.** `./apps`, `./infrastructure`, `./infrastructure/cert-manager` do not move; renaming the cluster directory does not affect them.
4. **The change is a two-commit "dance".** Commit 1 moves the directory, leaves a shim at the old path, and flips the `gotk-sync.yaml` path. Only after the in-cluster `spec.path` is observed as `./clusters/production` is Commit 2 (removing the shim) pushed.
5. **Base/overlays are deferred.** Splitting `apps/` into `apps/base/<service>` + `apps/overlays/<env>/<service>` is a per-service campaign that needs its own ADR and a zero-diff migration per service. It is explicitly out of scope here.

## Consequences

**Positive**

- Environments are separated by path in one branch, which is Flux's documented multi-environment pattern and is easy to reason about.
- The physical machine name no longer leaks into the repo layout; `production` describes the role.
- A staging cluster can be bootstrapped later without restructuring; its skeleton is already in place.
- SOPS is unaffected: `.sops.yaml` uses `path_regex: .*` and `git mv` does not alter file contents.

**Negative**

- The `clusters/<env>/` path is part of the cluster's bootstrap identity, so any future rename repeats the two-commit dance (or an in-cluster break-glass patch).
- A path-based layout does not prevent production and staging from sharing mutable external resources (MinIO buckets, NFS exports, ingress hostnames); that isolation has to be designed separately.
- `clusters/staging` is dead weight until staging hardware exists; it can drift and confuse unless clearly marked inert.

## The 2026-09-11 shim incident and the lesson

Commit 1 of the rename was implemented with a shim that copied **only** `clusters/homelab-2nd/flux-system/*` back to the old path. The old directory had also contained the child Kustomization CRs `apps.yaml`, `infrastructure.yaml`, and `cert-manager.yaml`, and the root Kustomization has `prune: true`. For one reconcile the live root still built `./clusters/homelab-2nd`; the shim's build no longer produced the three child Kustomization CRs, so Flux pruned them. Pruning a child Kustomization with `prune: true` cascade-deleted every workload and CNPG `Cluster` CR it managed, and databases without backups were lost (see the incident post-mortem and `docs/open-items.md`).

**Lesson:** a shim at the old cluster path MUST reproduce the *entire* contents the old root Kustomization built — the child Kustomization CRs as well as `flux-system/*` — or `prune: true` will delete whatever is missing. The two commits must never be pushed together; the in-cluster path flip must be observed between them.

## Alternatives considered

- **Keep the name `clusters/homelab-2nd`.** Rejected: it does not scale to a second environment and ties the layout to one machine.
- **Branch-per-environment (`production` / `staging` branches).** Rejected: Flux supports path-based environments directly; branches force constant cherry-picking and make shared base changes harder to review.
- **One commit that moves the directory and fixes the path.** Rejected: the in-cluster root would build a missing path and freeze the sync (or, with a shim done wrong, prune resources as happened).
- **`clusters/<env>/` plus a shared `clusters/base/`.** Rejected for now: not needed until a second cluster exists; revisit if environments multiply.
- **Immediate `apps/base` + `apps/overlays` split.** Rejected: too large and risky to combine with the rename; it is Phase 3 with its own ADR.

## When to revisit

- A staging cluster actually bootstraps, or staging hardware is cancelled (then delete `clusters/staging`).
- Environments multiply beyond production/staging, making a shared base worth extracting.
- The `apps/base` + `apps/overlays` split begins (Phase 3) — it supersedes the placeholder `apps/overlays/staging`.
- External resources shared across environments cause cross-environment interference, forcing per-environment isolation.

## References

- Incident tracking note: `2026-09-11-repo-restructure-production-staging.md` (Obsidian vault)
- `docs/open-items.md` — incident data-loss summary and recovery TODOs
- ADR-011 (`adr-011-arr-stack-k3s-migration.md`) for ADR format conventions
