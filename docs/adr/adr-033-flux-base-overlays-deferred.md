# ADR-033: `apps/base` + `apps/overlays` restructure is deferred to a per-service migration campaign

**Status:** Accepted  
**Date:** 2026-10-04  
**Supersedes:** the "Phase 3" placeholder in ADR-012 (the `apps/overlays/staging` stub)  
**Related:** ADR-012 (multi-environment Flux repo layout), ADR-002 (raw manifests are a last resort)

## Context

The canonical Flux v2 multi-tenancy layout splits every application into a
reusable base and per-environment overlays:

```
apps/{base,production,staging}/<service>
infrastructure/{base,production,staging}/<service>
clusters/{production,staging}/apps.yaml + infrastructure.yaml
```

H2-50 asked for this restructure alongside shipping Excalidraw. ADR-012 already
made the *cluster* half of that decision (path-based environments:
`clusters/production` is live, `clusters/staging` is an inert skeleton whose
`apps.yaml` points at `apps/overlays/staging` — a directory that does not
exist), and explicitly deferred the `apps/base` + `apps/overlays` split to "a
per-service campaign that needs its own ADR and a zero-diff migration per
service". This is that ADR.

Two facts make a big-bang restructure dangerous here:

1. **`prune: true` is set on every child Kustomization.** The 2026-09-11 rename
   incident (ADR-012) showed that if the root build stops producing a child CR
   even for one reconcile, Flux cascade-deletes every workload it managed. The
   shim must reproduce the *entire* previous build; a half-done split does not.
2. **The homelab is single-cluster and live.** There is no staging cluster to
   validate against, so an overlay refactor has no safe rehearsal environment.

## Decision

**Do not execute the `apps/{base,overlays}` restructure as part of shipping a
feature.** It is a standalone campaign, done one service at a time, with a
render-diff gate proving zero functional change per step. Until that campaign
runs, the flat `apps/<service>/` + `infrastructure/<service>/` layout stays.

The migration is defined here so the campaign can start without another design
round. Target layout:

```
apps/
├── base/<service>/                 # deployment, service, configmaps, HelmRelease values common to all envs
├── production/<service>/kustomization.yaml   # bases: [../../base/<service>] + prod patches
└── staging/<service>/kustomization.yaml      # same base + staging patches (or not deployed at all)
infrastructure/
├── base/…, production/…, staging/…
clusters/
├── production/{apps.yaml,infrastructure.yaml}   # spec.path -> ./apps/production, ./infrastructure/production
└── staging/{apps.yaml,infrastructure.yaml}      # spec.path -> ./apps/staging, ./infrastructure/staging
```

`clusters/staging/apps.yaml` already exists and is inert; when a staging cluster
is bootstrapped it will build `./apps/staging` unchanged.

### Migration plan (per service, reversible)

1. **Pre-flight.** `kustomize build apps > /tmp/before.yaml`; record
   `kubeconform -strict -ignore-missing-schemas -skip Secret` summary. Confirm
   the tree is clean and the service is healthy.
2. **Create `apps/base/<service>/`** by `git mv` of the current manifests
   (SOPS files move byte-identically; `.sops.yaml` uses `path_regex: .*`, so
   relocation never affects decryption). No content changes in this step.
3. **Create `apps/production/<service>/kustomization.yaml`** with
   `resources: [../../base/<service>]` and *no* patches yet — the overlay must
   be byte-for-byte equivalent to the base.
4. **Render-diff gate.** `kustomize build apps > /tmp/after.yaml`; prove
   `/tmp/before.yaml` and `/tmp/after.yaml` are identical (modulo the kustomize
   directory annotations). `git diff --stat` must show only moves plus the new
   overlay `kustomization.yaml` and the parent list change.
5. **Flip `apps/kustomization.yaml`** to reference the overlay paths. Commit
   and push; one service per commit. Watch the `apps` Kustomization reports
   `Ready` and that no object count changed in the cluster.
6. **Add environment patches only after the zero-diff move is live.** First a
   no-op patch (e.g. an annotation), then real staging deltas.
7. **Only when every service has moved** and `apps/production` is the sole
   parent, remove the flat top-level entries. Drop the `apps/overlays/staging`
   stub from ADR-012 in favour of `apps/staging`.

Rollback at any step is `git revert` of that single per-service commit; the
flat layout is untouched until the last service moves.

## Consequences

**Positive**

- No risky big-bang; each service is a small, reviewable, zero-diff commit.
- Base/overlay separation becomes available incrementally — the first service
  that actually needs a staging delta can get it without waiting for the rest.
- The plan matches `flux2-multi-tenancy` and the ADR-012 skeleton, so staging
  becomes usable the day hardware appears.

**Negative**

- Until the campaign completes, the repo carries two mental models (flat today,
  base/overlay tomorrow) and a stale `apps/overlays/staging` reference.
- Zero-diff moves create churn in `git log` with no functional change; a
  reviewer must trust the render-diff gate.
- `prune: true` means every step is a potential 2026-09-11 repeat if the render
  guard is skipped.

## Alternatives considered

- **Big-bang restructure now.** Rejected: no staging cluster to rehearse, and a
  single missed service under `prune: true` deletes live workloads (precedent:
  2026-09-11).
- **Branch-per-environment instead of path overlays.** Rejected in ADR-012;
  branches force cherry-picking and make shared-base changes harder.
- **Skip base/overlays entirely.** Rejected: the issue (and Flux's documented
  pattern) wants them; a plan doc plus this ADR keeps the door open without the
  risk today.
- **Namespace-based environments in one cluster immediately.** Rejected for
  now: the services share external resources (MinIO buckets, tunnel hostnames)
  that namespaces do not isolate, so per-env deployments would need more design
  than a Kustomize overlay split.

## When to revisit

- A staging cluster is bootstrapped (then start with the most stateful service
  and its backup/restore story, not with a stateless one).
- Any service genuinely needs a per-environment delta (then migrate just that
  one and stop).
- `apps/overlays/staging` starts confusing newcomers — replace it with
  `apps/staging` as part of the first migration commit.

## References

- ADR-012 — multi-environment Flux repo layout and the 2026-09-11 prune incident
- `clusters/production/apps.yaml`, `clusters/staging` (skeleton)
- H2-50 — "Replace tldraw with Excalidraw … + Flux overlays intro"
- Tracking note: `2026-10-04-h2-50-excalidraw-whiteboard.md`
