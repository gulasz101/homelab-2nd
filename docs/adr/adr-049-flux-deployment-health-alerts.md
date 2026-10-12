# ADR-049: Flux deployment health is alerted from controller metrics plus kube-state-metrics resource state

## Status

Accepted — 2026-10-12. Written the same day as the incident it answers, and the day ADR-048 named
this as its missing follow-up.

## Context

On 2026-10-11/12 the `apps` Kustomization sat `Ready=False` for ~20 hours (ADR-048: a Failed one-shot
`Job` with an immutable `spec.template`). Nothing alerted. Every pod stayed green, every service
stayed up; the only symptom was a `Ready=False` on a Flux object nobody was reading. It was found by
accident while answering an unrelated question.

The gap was total, not partial: **nothing scraped `flux-system` at all.** `kubectl get
servicemonitor,podmonitor -A` showed exactly one monitor in the whole cluster (`zigbee/influxdb`).
Prometheus held no `gotk_*` series whatsoever, so no alert on the GitOps pipeline was even
expressible, let alone firing.

Writing one turned out to be less obvious than it looks:

- **The controllers expose no revision.** `gotk_reconcile_condition{kind,name,namespace,status,type}`
  answers "is it Ready", not "is what is deployed the current revision". The headline question —
  *applied revision vs the revision Git is serving* — cannot be asked of it. An expression written
  against a metric that does not carry the label looks plausible, loads cleanly, reports
  `health=ok`, and **never fires**. That is worse than no alert: it converts "we don't know" into
  "we're covered".
- **The revision-labelled metric is not a Flux metric at all.** Flux documents resource state as a
  *kube-state-metrics* concern, read from the custom resources through `customResourceState`, with a
  configuration the user supplies. It exists only if you ask for it.
- The Flux version here is v1.8.5 (kustomize-controller), kube-state-metrics v2.20.0, deployed as a
  subchart of the `prometheus-stack` HelmRelease (kube-prometheus-stack, chart `>=69.0.0`).

## Decision

**Flux deployment health is alerted from two metric sources, both of which must be present for the
pipeline to be observable: the controllers' own `gotk_*` metrics, and revision-labelled resource
state exported by kube-state-metrics.**

### 1. Scrape the controllers — one PodMonitor, not Services

`infrastructure/observability/flux-controller-podmonitor.yaml` selects every pod in `flux-system`
carrying `app.kubernetes.io/part-of: flux` and scrapes the named container port `http-prom` (8080).

A PodMonitor rather than Service + ServiceMonitor: every deployed controller (source v1.8.5,
kustomize v1.8.5, helm v1.5.5, notification v1.8.4) exposes the same named port, so one object covers
all of them, and no second `Service` is created that would either collide with the existing
`source-controller` Service (port 80 → 9090) or need a suffixed name that lies about what it is. This
is also the shape Flux upstream uses.

### 2. Get the revisions from kube-state-metrics

`infrastructure/observability/prometheus-stack-helm-release.yaml` enables
`kube-state-metrics.customResourceState` with `gotk_resource_info` for three kinds:

| kind | `revision` label comes from |
|------|-----------------------------|
| Kustomization | `status.lastAppliedRevision` |
| GitRepository | `status.artifact.revision` |
| HelmRelease | `status.history[0].chartVersion` |

plus `exported_namespace`, `ready`, `suspended`, and for Kustomizations `source_name`, `source_kind`,
`source_namespace`. `rbac.extraRules` grants kube-state-metrics `list`/`watch` on the three Flux
kinds; without it the collector silently produces nothing.

**The upstream Flux example's `collectors: []` + `--custom-resource-state-only=true` is deliberately
NOT used.** It would drop every `kube_*` series and break every existing dashboard and node/pod
alert. The custom resource state is added *alongside* the default collectors.

### 3. Four alerts, in one PrometheusRule

`infrastructure/observability/flux-gitops-prometheus-rules.yaml`, label `release: prometheus-stack`
(the Prometheus CR's `ruleSelector` — a rule without that label is loaded by the operator and
silently never given to Prometheus):

| alert | signal |
|-------|--------|
| `FluxKustomizationNotReady` | `gotk_reconcile_condition{kind="Kustomization",type="Ready",status="False"}` > 0 for 15m |
| `FluxHelmReleaseNotReady` | same, `kind="HelmRelease"` |
| `FluxGitRepositoryNotReady` | same, `kind="GitRepository"` |
| `FluxKustomizationRevisionLagging` | Kustomization `revision` is not the `revision` of its GitRepository source |

The revision-lag rule is a **label-join**, because PromQL cannot compare two label values directly:

```promql
(
  max by (exported_namespace, name, source_name, revision) (
    gotk_resource_info{customresource_kind="Kustomization",
                       source_kind="GitRepository", suspended!="true"}
  )
  unless on (exported_namespace, source_name, revision)
  max by (exported_namespace, source_name, revision) (
    label_replace(
      gotk_resource_info{customresource_kind="GitRepository"},
      "source_name", "$1", "name", "(.*)"
    )
  )
) > 0
```

`unless on (...)` keeps only the Kustomizations whose `(namespace, source, applied revision)` triple
does **not** exist on the GitRepository side. An up-to-date Kustomization contributes nothing. It is
guarded to `source_kind="GitRepository"` so a Bucket/OCI-backed Kustomization can never match the
GitRepository set and become a permanent false positive, and `suspended!="true"` so a deliberate
freeze is not an incident.

`for: 15m` on all four. kustomize-controller reacts to a source change immediately, so a normal
rollout closes the lag gap in seconds; only a genuine failure holds it open.

### 4. Route it like everything else

`infrastructure/observability/flux-gitops-alertmanager-config.yaml` matches `alertgroup: flux-gitops`
and sends to the existing `homelab-node-mattermost-webhook-url` SOPS Secret with `sendResolved: true`,
identical in shape to the node and CNPG configs.

### 5. What this does and does not cover

Covered: the apply fails (rules 1/2), the fetch fails (rule 3), the cluster has fetched a revision it
cannot apply (rule 4).

**Not covered, deliberately: the GitRepository being behind `origin/main`.** No cluster metric knows
the remote HEAD; the GitRepository polls every 15m and there is no GitHub webhook Receiver in this
repo, so the artifact is *normally* up to 15m behind. "Behind by more than one poll interval" means
the fetch is failing, which rule 3 already catches. Detecting it precisely would need a GitHub API
comparison — a different mechanism (CronJob/Exporter), out of scope here.

## Consequences

**Good**

- The 20h-freeze class is now audible. A Kustomization that cannot apply, a HelmRelease stuck
  upgrading, a dead source fetch and a stale applied revision all page Mattermost within ~16 minutes.
- The revision question is answered by a real Prometheus metric, so the alert can be *tested*: the
  false-positive test (a throwaway Kustomization on a non-existent path) was observed firing in
  Alertmanager and delivered to Mattermost, then resolving.
- `gotk_resource_info` also makes the existing `kube-flux` Grafana dashboard's "Stuck Kustomizations"
  and "Stuck HelmReleases" panels work for the first time — they queried
  `gotk_resource_info{resource=...}`, a label that does not exist, and had been rendering "No data"
  since they were written.
- kube-state-metrics' default collectors are untouched, so nothing else regresses.
- The lag rule is one expression, no new component, no CronJob, no extra container image to keep
  patched.

**Bad / accepted costs**

- **A values change to the `prometheus-stack` HelmRelease.** kube-state-metrics restarts; Prometheus
  and Alertmanager are not touched, but the change does trigger a Helm upgrade of a large chart.
- **`gotk_resource_info` is an info metric whose revision lives in a *label*.** Comparing label
  values requires the `unless`/`label_replace` join, which is harder to read than a numeric
  comparison and easy to break during a refactor. The render check
  (`infrastructure/observability/tests/flux-gitops-alerts-check.sh`) pins the metric's shape so a
  silent change to the kube-state-metrics config fails the check rather than the alert.
- **Label cardinality.** Every Kustomization/HelmRelease/GitRepository in the cluster becomes a
  series, with the revision as a label — a new series per revision. Small here (tens of objects,
  deploys measured in hours), but it grows with the repo.
- **The lag comparison assumes the source lives in the same namespace as the Kustomization.** That is
  how every Kustomization in this repo is written (`sourceRef` with no `namespace`), and Flux
  requires same-namespace by default, but an explicit cross-namespace `sourceRef.namespace` would
  make the namespace half of the join fail and produce a false positive. `source_namespace` is
  exported so the fix is a one-line expression change if it ever happens.
- **Two alerts can fire for one root cause.** A Kustomization that is `Ready=False` *and* has a stale
  revision trips both `FluxKustomizationNotReady` and `FluxKustomizationRevisionLagging`. Accepted:
  they say different things (which object is broken vs what is deployed), and Alertmanager groups
  them.

## Alternatives considered

- **Alert only on `gotk_reconcile_condition`.** Rejected: it cannot express the headline requirement,
  and it is blind to the "Ready=True but applying yesterday's revision" case. It is kept as the
  not-Ready signal, not as the whole answer.
- **A CronJob comparing `.status.lastAppliedRevision` against the GitRepository artifact and POSTing
  to Alertmanager `/api/v2/alerts`.** This is the fallback the ticket named, to be used *only* if no
  metric can express the lag. A metric can, and a real metric is queryable, graphable, testable and
  needs no image to maintain. Rejected as unnecessary — but it remains the right answer if
  kube-state-metrics custom resource state ever goes away.
- **A second, dedicated kube-state-metrics instance for Flux.** Rejected: a whole extra deployment,
  Service, ServiceMonitor and RBAC to avoid one values change on a subchart that is already running.
- **Service + ServiceMonitor for each controller.** Rejected in favour of one PodMonitor (see above).
- **Flux's own `notification-controller` (`Alert` + `Provider` CRs) instead of Prometheus.** Genuinely
  tempting — it needs no Prometheus at all. Rejected: it fires on Flux *events*, which are transient
  and do not express duration ("not Ready **for 15 minutes**"), it has no state-based evaluation, and
  it would put Flux's health outside the one place every other alert in this homelab lives. Worth
  revisiting as a complement, not a replacement.
- **Trust the `kube-flux` Grafana dashboard.** Rejected — that is precisely the failure mode of the
  incident: nobody was looking at it, and two of its panels were broken anyway.

## When to revisit

- **If a Kustomization ever uses an explicit cross-namespace `sourceRef.namespace`** — the join needs
  `source_namespace` in the key.
- **If GitRepository-behind-`origin/main` becomes a requirement** — needs a different mechanism (a
  GitHub API comparison or a webhook Receiver so the poll interval stops being the floor).
- **If the Kustomization/HelmRelease count grows into the hundreds** — revisit the cardinality cost of
  a revision-per-series label and consider dropping the HelmRelease collector, which nothing alerts
  on.
- **If Flux adds a native revision-labelled controller metric** — the whole kube-state-metrics section
  of this ADR becomes removable.
- **If `apps` is split into per-application Kustomizations (ADR-033)** — the alerts become more
  precise for free, because the not-Ready signal then names the one application rather than the whole
  repo.
