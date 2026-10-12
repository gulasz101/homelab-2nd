# ADR-048: One-shot `Job` objects carry a version suffix in their name

## Status

Accepted — 2026-10-12. Written the morning after a single Failed Job silently froze every
application deploy in the repo for 20 hours.

## Context

`Job.spec.template` is **immutable** in Kubernetes. Once a Job object exists, its pod template can
never be edited — not by `kubectl apply`, not by Flux, not by anything. To change what a Job runs you
must create a *new* Job object.

That collides with GitOps in a way that is much worse than it first looks, because of how this repo
is laid out:

- `apps/` is **one Flux Kustomization**, and a Kustomization is **all-or-nothing**. Flux validates
  the whole desired set with a server-side dry-run before it applies anything.
- So if *one* object in `apps/` cannot be applied, **nothing** in `apps/` is applied.

Combine the two and a stale one-shot Job becomes a repo-wide deploy freeze. That is exactly what
happened:

```
2026-10-11 22:06Z  zigbee/nodered-mqtt-credential pod dies -> BackoffLimitExceeded (Failed)
2026-10-11 22:11Z  the working script is committed (7cbb3fb), YAML repaired (4e0700d)
2026-10-12 00:13Z  ADR-047 committed (7f95735)

$ kubectl get kustomization apps -n flux-system
NAME   READY   STATUS
apps   False   Job/zigbee/nodered-mqtt-credential dry-run failed (Invalid):
              Job.batch "nodered-mqtt-credential" is invalid: spec.template: ... field is immutable

applied   = main@sha1:0daf87d0e4cdc17002a296ef5c7852b1fe2aeb57   (2026-10-11 23:54)
attempted = main@sha1:7f957355d1e21a751a98feb4d6da0ea1614641cf   (2026-10-12 00:13)
```

The Job had failed. The fix was committed five minutes later. **Twenty hours on, the fix still had
not been applied, and no other application change could be applied either.** Nothing alerted; every
workload kept running; the only symptom was a `Ready=False` nobody was reading.

**This is not a new lesson for this repo, it is an un-generalised one.** The mattermost lane hit the
identical wall on 2026-09-19 and solved it locally, in a file comment:

> *Name is "-gen2": Kubernetes Jobs are immutable, so a fixed Job had to be replaced rather than
> edited.* — `apps/mattermost/purge-dead-push-sessions-job-gen2.yaml`

`mattermost-gitlab-sso-setup-v6` carries the same idea. Two lanes had independently discovered the
rule and neither wrote it down, so the zigbee lane walked into it anyway.

## Decision

**Every one-shot `Job` object in `apps/` carries a version suffix in `metadata.name`, and the suffix
MUST be bumped every single time `spec.template` changes.**

```yaml
metadata:
  name: nodered-mqtt-credential-v2   # <- bump to -v3 when the script changes
```

Rules that come with it:

1. **Bump the suffix, never edit the template under a stable name.** Renaming makes the dry-run
   difference disappear (the desired object is a *different* object), so the Kustomization applies
   again.
2. **The superseded Job is pruned automatically.** Jobs applied by the `apps` Kustomization carry
   `kustomize.toolkit.fluxcd.io/name: apps`, so once the manifest no longer contains the old name,
   Flux prunes it. No manual `kubectl delete` — which is the point.
3. **Bumping the suffix RE-RUNS the Job.** This is inherent, and it is the useful part: the version
   suffix is also the "run it again" button. It is the reason conversion must be deliberate.
4. **The suffix is a revision marker.** `-v2` in a Job name, in `kubectl get jobs`, in a pod name and
   in a log stream tells you which revision of the script produced that result. It replaces a
   guess.
5. **Only bump when the template changes.** A no-op rename is a no-op re-run.

Applied immediately to `zigbee/nodered-mqtt-credential` → `nodered-mqtt-credential-v2` (its
`spec.template` had changed and could not be applied).

## Consequences

**Good**

- A corrected one-shot Job can actually be delivered by GitOps. Before this, the only route was
  `kubectl delete job`, which is exactly the imperative shortcut guardrail 1 exists to prevent.
- **No single object can freeze `apps` by being un-editable.** The failure mode this ADR was written
  for cannot recur via a Job template change.
- Pruning is automatic, so the cluster does not accumulate dead Job objects by hand.
- The naming convention becomes a signal: when you see a Job without a suffix, you know it is an
  armed trap.
- It costs nothing at runtime — a string in a name.

**Bad / accepted costs**

- **Name churn.** `nodered-mqtt-credential-v2` is uglier than `nodered-mqtt-credential`, and the
  version in the name will eventually disagree with the version in the file name (the file keeps its
  descriptive name on purpose — the file is the *thing*, the Job is the *run of it*).
- **Forgetting to bump re-arms the trap exactly as before.** The mitigation is that the failure is
  loud *if anyone reads `kubectl get kustomization`* — and this incident proves nobody was. Follow-up
  worth doing: an alert on `kustomization.Ready=False` / `lastAppliedRevision` lagging `origin/main`.
- **The previous run's pods are pruned with the old Job**, so `kubectl logs` of the superseded
  revision is gone. Container stdout still lands in Loki, so logs are not actually lost — but the
  habit of `kubectl logs job/...` for a finished Job changes.
- **Bumping re-runs the Job, which for a destructive one-shot is a footgun.** Never convert a
  destructive Job to this convention casually.
- **Six other Jobs in the repo still use bare names** and remain armed:
  `nextcloud-oidc-provider-setup`, `honcho-db-migrate`, `itsaplan-oidc-bootstrap`,
  `zigbee2mqtt-restore-state`, plus the two already-suffixed mattermost ones. They are safe only
  while their templates never change; they should be converted opportunistically, **when a re-run is
  acceptable**, not in a sweep. `zigbee2mqtt-restore-state` in particular is deliberately left alone:
  re-running it is a restore.

## Alternatives considered

- **Break-glass `kubectl delete job` whenever the template changes.** Rejected: it is imperative, it
  is invisible to Git, it leaves the trap armed for the next person, and it needs a human to notice a
  `Ready=False` — the exact thing that failed here for 20 hours.
- **Wrap each one-shot Job in its own `HelmRelease`** and use `helm.sh/hook` +
  `hook-delete-policy: before-hook-creation`. This genuinely solves it — Helm deletes and recreates
  the Job on every upgrade. Rejected as disproportionate: a chart, a repository entry and a
  HelmRelease per 90-line script, for a repo that only has seven of them. Worth revisiting if the
  number grows.
- **Hash-suffixed names, the way Helm does it.** Kustomize can hash names for `configMapGenerator` /
  `secretGenerator` only. There is no name-hash transformer for arbitrary resources, so this cannot
  be declarative.
- **Make the Job's template immutable-proof** (e.g. put the script in a ConfigMap and keep the
  template constant). Elegant in theory and it *would* work for this Job — but it changes the
  failure mode rather than removing it: the next unrelated field in the template (an image tag, a
  secret ref, an env var) re-freezes the Kustomization. Rejected as a general rule.
- **Split `apps` into many small Kustomizations so one bad object cannot freeze everything.** This is
  the *systemic* fix and it is the right long-term answer — but it is the same ground as ADR-033
  (`apps/base` + `apps/overlays`, deferred), it is a large restructure, and it does not remove the
  need to name Jobs correctly. Rejected *for now*, endorsed as the direction.
- **Just delete the object from the desired set** and stop managing the Job with Flux at all.
  Rejected: that is "it doesn't exist if it's not in the repo" turned inside out — the credential
  seeding would become an undocumented manual step.

## When to revisit

- **If `apps` is ever split into per-application Kustomizations (ADR-033),** the blast radius drops
  from "the whole repo" to "one namespace", and this ADR's urgency drops with it. The naming rule
  still stands — it is what makes the Job correct at all, not just what contains the damage.
- **If the repo's one-shot Job count grows past ~10,** the HelmRelease-per-Job option stops being
  disproportionate and should be re-evaluated against the name-suffix rule.
- **If a destructive one-shot Job is ever added.** It needs a different answer than "bump the name
  and it re-runs" — most likely a deliberately manual, documented runbook with the Job kept out of
  the Kustomization entirely.
- **Once an alert exists on `Kustomization` readiness / applied-revision lag.** At that point the
  "nobody noticed for 20 hours" cost is gone, and the trade-off is purely about ergonomics.
- **If Kustomize or Flux ever gains name-hashing or per-object error tolerance.** Either one removes
  the manual bump, and this ADR becomes a historical note.
