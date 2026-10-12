# ADR-049: Flux deployment health is alerted from kube-state-metrics resource state plus the controller scrape

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
Prometheus held zero `gotk_*` series, so no alert on the GitOps pipeline was even expressible.

Writing one turned out to be much less obvious than it looks, and the interesting part of this ADR is
what the live cluster refused to do.

### The metric everyone reaches for does not exist

`gotk_reconcile_condition{kind,name,namespace,status,type}` is the metric the ticket was written
around, and it is in a lot of blog posts and older docs. It is **not** in Flux v1.8.5's output. Not
"requires a feature gate", not "needs a label" — absent. Verified against the live scrape once the
PodMonitor was in place, 2026-10-12 19:22Z:

```
$ curl -sG <prometheus>/api/v1/label/__name__/values | grep -E '^gotk'
gotk_event_http_request_duration_seconds_bucket
gotk_event_http_request_duration_seconds_count
gotk_event_http_request_duration_seconds_sum
gotk_event_http_requests_inflight
gotk_event_http_response_size_bytes_bucket
gotk_event_http_response_size_bytes_count
gotk_event_http_response_size_bytes_sum
gotk_reconcile_duration_seconds_bucket
gotk_reconcile_duration_seconds_count
gotk_reconcile_duration_seconds_sum
gotk_resource_info
gotk_token_cache_evictions_total
gotk_token_cached_items
```

No `gotk_reconcile_condition`, no `gotk_suspend_status`. And the failure mode is nasty, because a rule
written against it **loads and reports healthy**:

```
$ curl -s <prometheus>/api/v1/rules?type=alert        # group flux-gitops, first push
FluxKustomizationNotReady   health="ok"  state="inactive"
  query: max by (exported_namespace, name) (gotk_reconcile_condition{kind="Kustomization",status="False",type="Ready"}) > 0
```

`health=ok` means "the expression parses". It says nothing about whether the metric exists. An alert
written this way can never fire, while the dashboard says everything is fine — which is a strictly
worse outcome than having no alert, because it converts "we don't know" into "we're covered".

### The revision-labelled metric is not a Flux metric

The revision is not in the controller metrics either. Flux documents resource state as a
**kube-state-metrics** concern: read the custom resources with a `customResourceState` config the
operator supplies. It exists only if you ask for it. In this cluster that is the
`prometheus-stack` HelmRelease (kube-prometheus-stack `>=69.0.0`, kube-state-metrics v2.20.0).

## Decision

**Flux deployment health is alerted from one metric source — kube-state-metrics
`gotk_resource_info` — plus one liveness signal from scraping the controllers directly. Both halves
must be present for the pipeline to be observable.**

### 1. Scrape the controllers — one PodMonitor, not Services

`infrastructure/observability/flux-controller-podmonitor.yaml` selects every pod in `flux-system`
carrying `app.kubernetes.io/part-of: flux` and scrapes the named container port `http-prom` (8080).

A PodMonitor rather than Service + ServiceMonitor: every deployed controller (source v1.8.5,
kustomize v1.8.5, helm v1.5.5, notification v1.8.4) exposes the same named port, so one object covers
all of them, and no second `Service` is created that would either collide with the existing
`source-controller` Service (port 80 → 9090) or need a suffixed name that lies about what it is. This
is also the shape Flux upstream uses.

It is **not** the source of the readiness alerts (that metric does not exist). It provides
`up{namespace="flux-system"}`, `gotk_reconcile_duration_seconds_*`, `controller_runtime_*` and
`gotk_token_cache_*` — which is what makes the "the monitoring itself died" alert possible, and what
makes the existing `kube-flux` dashboard's reconciliation-rate panel work.

### 2. Get readiness *and* revisions from kube-state-metrics

`infrastructure/observability/prometheus-stack-helm-release.yaml` enables
`kube-state-metrics.customResourceState` with `gotk_resource_info` for three kinds:

| kind | labels |
|------|--------|
| Kustomization | `ready`, `revision` ← `status.lastAppliedRevision`, `source_name`, `source_kind`, `source_namespace` |
| GitRepository | `ready`, `revision` ← `status.artifact.revision`, `url` |
| HelmRelease | `ready`, `revision` ← `status.history[0].chartVersion`, chart labels |

plus `exported_namespace` and `suspended` on all three. `rbac.extraRules` grants kube-state-metrics
`list`/`watch` on the three Flux kinds; without it the collector silently produces nothing.

**The upstream Flux example's `collectors: []` + `--custom-resource-state-only=true` is deliberately
NOT used.** It would drop every `kube_*` series and break every existing dashboard and node/pod
alert. The custom resource state is added *alongside* the default collectors.

### 3. Five alerts, in one PrometheusRule

`infrastructure/observability/flux-gitops-prometheus-rules.yaml`, label `release: prometheus-stack`
(the Prometheus CR's `ruleSelector` — a rule without that label is loaded by the operator and silently
never given to Prometheus):

| alert | signal |
|-------|--------|
| `FluxKustomizationNotReady` | `gotk_resource_info{customresource_kind="Kustomization",ready=~"False\|Unknown",suspended!="true"}` > 0 for 15m |
| `FluxHelmReleaseNotReady` | same, `customresource_kind="HelmRelease"` |
| `FluxGitRepositoryNotReady` | same, `customresource_kind="GitRepository"` |
| `FluxKustomizationRevisionLagging` | Kustomization `revision` is not the `revision` of its GitRepository source |
| `FluxControllersUnmonitored` | `up{namespace="flux-system"} == 0` **or** `absent(up{namespace="flux-system"})` for 15m |

`ready=~"False|Unknown"` rather than `ready="False"`: a resource whose Ready condition is Unknown is
also not deployable. A resource with no Ready condition yet (just created) has no `ready` label at all
and is deliberately not alerted on. `suspended!="true"` keeps a deliberately frozen object quiet — it
will never become Ready again and that is not an incident.

`FluxControllersUnmonitored` closes the same hole one level up: if the flux-system scrape disappears,
every other rule here stops existing rather than firing, and their alerts resolve themselves. That is
the original bug's shape, so it gets its own alert.

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
GitRepository set and become a permanent false positive.

`for: 15m` on all five. kustomize-controller reacts to a source change immediately, so a normal
rollout closes the lag gap in seconds; only a genuine failure holds it open.

### 4. Route it like everything else

`infrastructure/observability/flux-gitops-alertmanager-config.yaml` matches `alertgroup: flux-gitops`
and sends to the existing `homelab-node-mattermost-webhook-url` SOPS Secret with `sendResolved: true`,
identical in shape to the node and CNPG configs.

### 5. What this does and does not cover

Covered: the apply fails, the fetch fails, the cluster has fetched a revision it cannot apply, and the
monitoring itself going blind.

**Not covered, deliberately: the GitRepository being behind `origin/main`.** No cluster metric knows
the remote HEAD; the GitRepository polls every 15m and there is no GitHub webhook Receiver in this
repo, so the artifact is *normally* up to 15m behind. "Behind by more than one poll interval" means
the fetch is failing, which `FluxGitRepositoryNotReady` already catches. Detecting it precisely would
need a GitHub API comparison — a different mechanism (CronJob/Exporter), out of scope here.

## Consequences

**Good**

- The 20h-freeze class is now audible. A Kustomization that cannot apply, a HelmRelease stuck
  upgrading, a dead source fetch, a stale applied revision, and the scrape itself dying all page
  Mattermost within ~16 minutes.
- Readiness and revision come from **one** metric, so there is one thing to keep working and one
  shape to test.
- The alert can be *tested*: the false-positive test (a throwaway Kustomization on a non-existent
  path) was observed reaching `Ready=False`, firing in Alertmanager, being delivered to the Mattermost
  webhook, and resolving after the object was pruned.
- `gotk_resource_info` also makes the existing `kube-flux` Grafana dashboard's "Stuck Kustomizations"
  and "Stuck HelmReleases" panels work for the first time — they queried
  `gotk_resource_info{resource=...}`, a label that does not exist, and had rendered "No data" since
  they were written. The PodMonitor revives the "Flux reconciliations / min" panel for the same
  reason.
- kube-state-metrics' default collectors are untouched, so nothing else regresses.
- No new component, no CronJob, no extra container image to keep patched.

**Bad / accepted costs**

- **A values change to the `prometheus-stack` HelmRelease.** kube-state-metrics restarts; Prometheus
  and Alertmanager are not touched, but the change does trigger a Helm upgrade of a large chart.
- **The not-Ready alerts now depend on the kube-state-metrics custom resource state config.** If that
  config were removed, four of the five alerts would silently stop working — the exact failure mode
  this ADR is about. Mitigation: the render check
  (`infrastructure/observability/tests/flux-gitops-alerts-check.sh`) asserts the metric's exact label
  paths and asserts that the rule file contains **no** reference to `gotk_reconcile_condition`, so a
  regression fails a check instead of an alert.
- **`gotk_resource_info` is an info metric whose data lives in *labels*.** Comparing label values
  requires the `unless`/`label_replace` join, which is harder to read than a numeric comparison and
  easy to break during a refactor.
- **Label cardinality.** Every Kustomization/HelmRelease/GitRepository in the cluster becomes a
  series, with the revision as a label — a new series per revision. Small here (tens of objects,
  deploys measured in hours), but it grows with the repo.
- **The lag comparison assumes the source lives in the same namespace as the Kustomization.** That is
  how every Kustomization in this repo is written (`sourceRef` with no `namespace`), and Flux
  requires same-namespace by default, but an explicit cross-namespace `sourceRef.namespace` would make
  the namespace half of the join fail and produce a false positive. `source_namespace` is exported so
  the fix is a one-line expression change if it ever happens.
- **Two alerts can fire for one root cause.** A Kustomization that is `Ready=False` *and* has a stale
  revision trips both `FluxKustomizationNotReady` and `FluxKustomizationRevisionLagging`. Accepted:
  they say different things (which object is broken vs what is deployed), and Alertmanager groups
  them.
- **`health=ok` in `/api/v1/rules` is not evidence that an alert works.** Three rules shipped in the
  first push of this work reported `health=ok` while referencing a metric that does not exist. The
  only thing that catches that is proving the metric live, and then firing the alert on purpose.

## Alternatives considered

- **Alert on `gotk_reconcile_condition`.** Rejected — it does not exist in this Flux version. It was
  implemented first, observed healthy-and-dead in `/api/v1/rules`, and replaced.
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
  incident: nobody was looking at it, and several of its panels were broken anyway.

## When to revisit

- **If a Kustomization ever uses an explicit cross-namespace `sourceRef.namespace`** — the join needs
  `source_namespace` in the key.
- **If GitRepository-behind-`origin/main` becomes a requirement** — needs a different mechanism (a
  GitHub API comparison, or a webhook Receiver so the poll interval stops being the floor).
- **If Flux ever (re)exposes a condition metric** — check
  `/api/v1/label/__name__/values` before assuming; the not-Ready rules could then be written on the
  controller's own metric instead of kube-state-metrics.
- **If the Kustomization/HelmRelease count grows into the hundreds** — revisit the cardinality cost of
  a revision-per-series label and consider dropping the HelmRelease collector, which nothing alerts
  on.
- **If `apps` is split into per-application Kustomizations (ADR-033)** — the alerts become more
  precise for free, because the not-Ready signal then names the one application rather than the whole
  repo.
