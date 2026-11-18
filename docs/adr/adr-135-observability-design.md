# ADR-135: Observability design — one telemetry pipeline, one dashboard standard, three SLOs

- **Status**: Accepted (amended 2026-11-18 by GUL-1779: the telemetry pipeline and the dashboard
  standard are folded in beside the SLO half from GUL-1599)
- **Date**: 2026-11-18
- **Issue**: GUL-1599 (OTel work order 5, gap G7) and GUL-1779 (this umbrella record), stage
  GUL-1754; parent GUL-1593
- **Related**: ADR-005 (per-namespace observability), GUL-1593 (OTel hardening review, which found
  gaps G2 and G7), GUL-1595 (work order 1), GUL-1596 (work order 2), GUL-1597 + GUL-1738 (work
  order 3), GUL-1598 + GUL-1758 (work order 4a)

## Context

Three failure classes were open in the observability stack, and each of them was a way for the
homelab to look healthy while it was not.

**The data path itself was unwatched.** The collector, Loki, Tempo and Prometheus could each stop
carrying telemetry while every application pod stayed green. `flux-gitops-prometheus-rules.yaml`
already did this for deployment; nothing did it for the data path (gap G2).

**Dashboards had drifted.** Each namespace's Grafana board was hand-written, so a re-provisioned
datasource UID or a missing unit left a panel silently blank, and two boards for the same kind of
workload told different stories (GUL-1693).

**Alerts were on causes, never on effects.** Every alert answered "is something broken right now";
none answered "are users getting worse service than we promised, and how fast are we spending the
allowance for that" (gap G7). The result is both noisy and late: a slow-burn latency regression
pages nobody, while a one-minute blip pages everyone.

This ADR is the umbrella record for work orders 1–5 under GUL-1593. It does not replace the
per-work-order files; it states the contract they share, because the three pieces only work as one
pipeline: the collector feeds the trace and log backends, the dashboards read what the pipeline
wrote, and the SLOs divide numbers the trace backend produces.

## Decision

### 1. The telemetry pipeline is a service, and every stage has an owner and an alert

One OTel collector per node, as a DaemonSet, so a node's logs and spans never cross the network to
reach a collector that shares none of its context. Today that is four pods, one per node.

| Stage | Guarantee | Where it is written down |
|---|---|---|
| Collect | `memory_limiter` runs first in every pipeline: `limit_percentage: 80`, `spike_limit_percentage: 20`, `check_interval: 1s` — a busy node sheds telemetry instead of growing until the kubelet OOM-kills the collector and takes that node's whole log pipeline with it | `infrastructure/observability/opentelemetry-collector-helm-release.yaml` |
| Envelope | requests `100m` CPU / `256Mi` memory, memory limit `512Mi`, chart pinned `0.178.0` | same file |
| Coverage | the DaemonSet tolerates the `dedicated=zigbee:NoSchedule` taint, so `zigbee2mqtt`'s logs reach Loki from the dedicated node | same file |
| Locality | `internalTrafficPolicy: Local` on the collector Service — in-cluster clients talk to their own node's collector | same file |
| Ship | all three exporters (`otlphttp/loki`, `otlp/tempo`, `otlphttp/prometheus`) carry `sending_queue` **and** `retry_on_failure`, so a backend restart drops nothing it could have retried | same file |
| Static check | AC-1…AC-7 assert those properties from the file text — no cluster, no PyYAML, so they run in CI | `infrastructure/observability/tests/otel-collector-check.sh` |

Prometheus is fed over its own OTLP receiver (`/api/v1/otlp/v1/metrics`, Prometheus 2.55+), not by a
second scrape of the collector; Loki takes logs over its OTLP endpoint with schema `v13` (structured
metadata), Tempo takes spans over `otlp/tempo`.

#### 1a. Logs, traces and metrics point at each other

Correlation is a fixed set of links, declared once and checked statically:

- **Fixed datasource UIDs** — Prometheus `PBFA97CFB590B2093`, Loki `P8E80F9AEF21F6940`, Tempo
  `tempo`. A dashboard hardcoding any other UID goes blank the day Grafana re-provisions the
  datasource (GUL-1693).
- **Metric → trace**: the Prometheus datasource keeps exemplars and points
  `exemplarTraceIdDestinations` at Tempo, so clicking an exemplar opens the trace.
- **Log → trace**: Loki carries a derived field that turns a `trace_id` into a Tempo link.
- **Trace → log, trace → metric**: the Tempo datasource links to Loki by trace id, and to Prometheus
  for span metrics and the service map.
- **Service graph and span metrics**: Tempo's `metrics-generator` runs the `service-graphs` and
  `span-metrics` processors and remote-writes their output into the kube-prometheus stack. Those two
  series are what section 3 divides.

Files: `infrastructure/observability/grafana-helm-release.yaml` (datasources, exemplars, derived
fields), `infrastructure/observability/tempo-helm-release.yaml` (metrics-generator). Checked by
`infrastructure/observability/tests/signal-correlation-check.sh`, AC-1…AC-6 — including AC-6: no
dashboard may reference a datasource UID that nothing declares.

#### 1b. Seven alerts watch the pipeline

The rules are written against metric names verified on the live Prometheus, not guessed from
documentation: a rule naming a series that does not exist loads with `health=ok` and can never fire,
which is the trap GUL-1593 forbids.

| Alert | Fires when | Hold | Severity |
|---|---|---|---|
| `OtelCollectorDown` | a collector target is `up == 0`, **or** fewer than 4 targets exist at all | 5m | critical |
| `OtelCollectorRefusingData` | `rate(otelcol_receiver_refused_{spans,metric_points,log_records}[5m]) > 0` | 10m | critical |
| `OtelExporterSendFailed` | `rate(otelcol_exporter_send_failed_metric_points[5m]) > 0` | 10m | critical |
| `OtelExporterQueueFilling` | `otelcol_exporter_queue_size / otelcol_exporter_queue_capacity > 0.7` | 10m | warning |
| `LokiIngestErrors` | Loki answers 5xx on an ingest route (`otlp_v1_logs`, `Push`) | 10m | critical |
| `TempoIngestErrors` | Tempo refuses spans, or discards accepted ones (`tempo_discarded_spans_total`) | 10m | critical |
| `PrometheusRuleEvaluationFailures` | a rule group fails to evaluate, so its alerts never fire | 15m | warning |

`count(...) < 4` is the subtle one: a pruned PodMonitor or a lost node removes targets instead of
failing them, and every per-target check then agrees that all is well. The `4` is the node count —
four nodes, one collector each. The `0.7` queue threshold is OpenTelemetry's own "investigate at
60–70 % of capacity" guidance, and it fires before sends start failing.
`PrometheusRuleEvaluationFailures` watches the watcher: a bad `expr` fails its whole rule group, so
it cannot live in the group it watches.

Files: `infrastructure/observability/otel-pipeline-prometheus-rules.yaml`,
`infrastructure/observability/otel-pipeline-alertmanager-config.yaml`, checked by
`infrastructure/observability/tests/otel-pipeline-alerts-check.sh`. Routing key: `alertgroup:
otel-pipeline`; every rule also carries `namespace: observability` (see the namespace trap in 3c).

### 2. One dashboard standard, one generator, no hand-written panels

Every dashboard that ships from `apps/*/` and `infrastructure/auth/` is an **output**:
`scripts/render_namespace_dashboard.py` renders it from `scripts/dashboards/manifest.json`, and
re-rendering reproduces each ConfigMap byte for byte. Nothing is hand-edited, so a dashboard cannot
drift from the standard. The manifest holds 21 entries: 20 namespaces plus one `Observability` entry
for the SLO board in section 3d.

| Rule | Value |
|---|---|
| Title | `<namespace> — <What>`, em dash, namespace first |
| Tags / refresh / schema | `homelab` + the namespace / `30s` / one `SCHEMA_VERSION` for the whole set |
| Datasource | every panel uses the `datasource` (Prometheus) and `loki` template variables, never a UID |
| Rows | `Golden signals`, then `Resources`, then `Logs` |
| Panels | every panel carries a `description` and a `fieldConfig.defaults.unit` |

The datasource rule is the one that matters: a rebuilt stack cannot blind a dashboard. The rows are
the reading order a responder needs — is it saturated or failing, what is it consuming, what is it
saying. The prose half of the standard is `docs/dashboards.md`; the machine half is
`scripts/tests/dashboard-standard-check.sh` (AC-1…AC-7), which also asserts that exactly one
generator exists in the repo and that re-rendering changes nothing.

### 3. SLOs: three services, two SLIs each

Two pieces were already in place and shaped the design:

- **Span metrics** (section 1a): Tempo's `span_metrics` processor remote-writes
  `traces_spanmetrics_calls_total` and `traces_spanmetrics_latency_bucket` into the
  kube-prometheus stack. Labels: `service`, `span_name`, `span_kind`, `status_code`. The histogram
  bucket boundaries are in **seconds** (`0.002 … 16.384` by default).
- **Grafana's own instrumentation**: `grafana_http_request_duration_seconds`, a Prometheus client
  histogram labelled with `status_code`, `method` and `handler`.

Three services answer requests for a person and deserve an SLO: **Open WebUI** (the chat UI),
**Hindsight API** (the memory service behind it) and **Grafana** itself. Everything else in the
homelab is batch work, where a failed run is reported by the job, not by a latency quantile.

| Service | Availability | Latency | Target |
|---|---|---|---|
| Open WebUI (`open-webui`) | share of `SPAN_KIND_SERVER` spans that are not `STATUS_CODE_ERROR` | share under **1.024 s** | 99.5 % |
| Hindsight API (`hindsight-api`) | same | share under **2.048 s** | 99.5 % |
| Grafana | share of HTTP requests that are not 5xx | share under **1 s** | 95 % |

The span `service` label is the OTel resource `service.name` the workload sets itself
(`OTEL_SERVICE_NAME=open-webui` in `apps/llm-hub/openwebui-helm-release.yaml`,
`HINDSIGHT_API_OTEL_SERVICE_NAME=hindsight-api` in `apps/hindsight/hindsight-helm-release.yaml`), so
no rule has to guess a deployment name. Only `SPAN_KIND_SERVER` spans count: a client span measures
the caller's patience, not the callee's health, and counting both double-counts one request.

The latency thresholds are **actual bucket boundaries** on purpose. `le="1"` is not a series that
exists for Tempo's span metrics, and a rule selecting it records nothing and never fires — the
silent-rule trap GUL-1593 forbids. Grafana's client library does have a `1` bucket, so it keeps the
round number.

#### 3a. The recorded quantity is the error ratio

`slo:sli_error:ratio_rate<window>` for `5m, 30m, 1h, 2h, 6h, 1d, 3d` — 3 services × 2 SLIs × 7
windows = **42 series**. The error ratio, not the success ratio, is what a burn rate multiplies:
`burn_rate = error_ratio / error_budget`, with `error_budget = 1 - target` (`0.005` for a 99.5 %
target, `0.05` for 95 %). Each series carries exactly `service` and `slo`, so the alert layer
aggregates `by (slo)` without a second series shape.

#### 3b. Alerting: the four workbook rates, two windows each

Google SRE workbook, "Alerting on SLOs" — a long window (is the budget actually going) paired with
a short one (is it still going), which is what stops a single bad minute from paging:

| Alert | Burn rate | Windows | Hold | Severity |
|---|---|---|---|---|
| `*SLOBurnPageFast` | > 14.4 | 1h and 5m | 2m | critical |
| `*SLOBurnPageSlow` | > 6 | 6h and 30m | 15m | critical |
| `*SLOBurnTicket` | > 3 | 1d and 2h | 1h | warning |
| `*SLOBurnTicketSlow` | > 1 | 3d and 6h | 3h | warning |

One alert per service and rate (12 rules), each covering both of its SLIs: the expression reduces
`by (slo)`, so a firing instance names the SLI in `$labels.slo`. Twelve rules, not twenty-four, and
still one actionable alert per (service, SLI) pair.

#### 3c. Selectors and labels are part of the contract

Every rule carries `alertgroup: slo` **and** `namespace: observability`. The second label is not
decoration: with prometheus-operator's default `OnNamespace` matcher strategy the generated route
carries `namespace="observability"`, so a rule labelled with another namespace fires, matches
nothing and lands on the top-level `null` receiver. The same trap applies to the `otel-pipeline`
group.

`PrometheusRule` needs `release: prometheus-stack` (the `Prometheus` CR's `ruleSelector`);
`AlertmanagerConfig` needs `release: kube-prometheus-stack` (`alertmanagerConfigSelector`). Without
them the operator loads the object and the stack ignores it, silently — a rule that exists and never
fires reads exactly like a rule that fires and never triggers.

Routing for both groups: `alertgroup = slo` and `alertgroup = otel-pipeline`, to the existing
`homelab-node-mattermost-webhook-url` SOPS secret, as a Slack-formatted Mattermost message with
`sendResolved: true`. The secret is reused, never copied — the operator resolves `urlSecret` in the
AlertmanagerConfig's own namespace.

The burn-rate group is written **before** the recording group in the rule file. That is a
red-stage constraint, not an ordering semantic: the check's record-block parser drops a pending
`- record:` block when the next line is an `- alert:`, so the 3d recording block that sat above the
alerts was not counted.

#### 3d. The SLO dashboard is generated, like every other dashboard

`Observability — SLOs` (`infrastructure/observability/dashboards/slo-dashboard-configmap.yaml`) is a
manifest entry in `scripts/dashboards/manifest.json` rendered by
`scripts/render_namespace_dashboard.py`, the single generator the dashboard standard (GUL-1598,
`docs/dashboards.md`) allows. The generator grew an `slo` mode: its Golden signals row
shows, per service, the 30-day availability SLI, the 30-day latency SLI, the error budget left and
the 1h/6h burn rate, all from the recording rules above. The 30-day SLI is not one of the seven
recorded windows, so it is `avg_over_time(slo:sli_error:ratio_rate1d{…}[30d])` — a range query over
the recorded series rather than an eighth recording rule, and the same number the alerts divide.

Re-rendering the manifest must reproduce the ConfigMap byte for byte, and every other dashboard must
come out unchanged; the check enforces both. A hand-edited dashboard would be drift, which is the
failure mode GUL-1598 removed.

## What is deliberately not covered yet

| Not covered | Why that is acceptable today |
|---|---|
| **Nothing under `infrastructure/observability/slo/` is applied by Flux.** `infrastructure/kustomization.yaml` lists no `slo/` entry, so `slo-prometheus-rules.yaml` and `slo-alertmanager-config.yaml` are in Git and not in the cluster — verified 2026-11-18: `kubectl -n observability get prometheusrule slo-recording-and-burn-rate` → `NotFound`, and the file carries no `slo` reference. The pipeline half no longer has this problem: PR #259 (GUL-1738) registered `otel-pipeline-prometheus-rules.yaml` and `otel-pipeline-alertmanager-config.yaml` at lines 68–69 of the same file. | Wiring SLO is the identical two-line change and belongs in its own PR. Until it lands, "the SLOs are alerted" is a design fact, not an operational one, and this row is the first thing to delete when it does land. Worth knowing while you wire it: `infrastructure/observability/tests/kustomization-reachability-check.sh` walks top-level manifests only, so a nested `slo/` directory stays invisible and the guard passes green while the rules sit unapplied. |
| **Most services emit no traces**, so they cannot carry an availability or latency SLI: only Hindsight, Open WebUI and Karakeep set an OTLP endpoint (`apps/hindsight/`, `apps/llm-hub/`, `apps/karakeep/`). | Those services keep a generated dashboard and cause alerts (ADR-005), which is what batch and appliance workloads need. An SLO on a service that emits no spans would measure nothing. |
| **Karakeep emits traces but has no SLO.** | A bookmark app's failures are noticed by the person using it; a latency objective would be invented rather than interviewed. |
| **A status-code SLI cannot see an error body**: a service returning 200 with an error burns no budget. | Accepted: a status-code SLI is the honest, cheap starting point, and it is the one every service already reports without changes. |
| **The four cluster-wide dashboards** under `infrastructure/observability/dashboards/` (`observability-overview`, `kube-flux-overview`, `homelab-system-load`, `homelab-gpu-power`) are still hand-written and outside the generator; `dashboard-standard-check.sh` AC-2 scopes itself to `apps/` and `infrastructure/auth/`. | They are single-purpose boards over cluster and GPU metrics, not namespace boards. Moving them into the manifest is a follow-up, not a prerequisite. |
| **Tempo's span metrics can stop without their own alert.** If `span_metrics` stops writing, the recording rules go empty and the burn-rate alerts simply stop firing. | The pipeline alerts (section 1b) cover Tempo refusing and discarding spans, and `PrometheusRuleEvaluationFailures` covers a broken rule group. A "span metrics went stale" rule is worth adding; it is not a prerequisite for the SLOs being correct. |
| **No log-based SLI, no cost or capacity SLO, no trace-retention objective.** | The interview that would give these numbers has not happened (GUL-1593). |

## Consequences

- The pipeline now fails loudly in four places (collector, exporter, Loki, Tempo) plus the rule
  evaluator, and every alert names the node, pod and exporter it came from.
- Every dashboard costs one manifest entry and no hand editing; a datasource re-provision cannot
  blank a board, and a panel without a unit or a description fails CI instead of shipping.
- Alerts now cost a decision, not a page: the two page rates fire on real budget spend, the two
  ticket rates are for the daily sweep. A latency-only burn is saturation (CPU, a slow dependency, a
  full queue); an availability burn is errors. That ordering is written into every alert
  description, and the descriptions point at this ADR's runbook section through
  `infrastructure/observability/slo/README.md`.
- Recording cost is small: 42 series over counters that are already scraped.
- A missing `le` boundary now fails loudly: a rule selecting a non-existent bucket produces no series
  and the burn rate divides by an empty vector. Adding a latency SLO means checking the generator's
  histogram buckets first.
- The `30d` SLI is a range query, not a recording series: the seven windows cover every alerting
  case, and an eighth series per (service, SLI) would be paid for on every scrape to serve four
  dashboard panels.
- The design is one file per work order, and this record is the only place the three halves are
  stated together — so a change to the pipeline contract or the dashboard standard belongs here as an
  amendment, not in a new ADR.

## Runbook

1. `OtelCollectorDown` / `OtelCollectorRefusingData` / `OtelExporter*`: the labels name the pod and
   the exporter. A collector down means that node ships nothing — check the pod first, the pipeline
   second. A queue above 70 % is a slow backend, not a slow collector; more capacity buys time and
   costs memory.
2. `LokiIngestErrors` / `TempoIngestErrors`: the backend is refusing data, not the collector. Loki
   writes chunks to the OMV MinIO bucket; Tempo writes to its `local-path` volume.
3. A `*SLOBurn*` page names its service and, in `$labels.slo`, which SLI is burning. Open the
   `Observability — SLOs` dashboard first: the burn-rate panel says whether this is an availability
   burn (errors) or a latency burn (saturation), and the burn-down says how much budget is left.
4. Then the service's own dashboard (llm-hub for Open WebUI, hindsight for the API, and Grafana's own
   metrics) for the cause: errors, CPU/memory saturation, a slow dependency, a full queue.
5. A ticket alert is a review item for the next working day, not an out-of-hours call.
6. If an alert is wrong rather than the service: fix the recording rule, not the threshold — a
   threshold tuned around a broken SLI hides the next real burn.

## Alternatives considered

- **A collector per node with no memory limiter, relying on node pressure.** Rejected: the kubelet
  OOM-kills the collector and that node silently loses its whole log pipeline, which is the failure
  section 1 exists to prevent.
- **One central collector Deployment for the cluster.** Rejected: a single pod for every node's logs
  and spans is a single point of failure, and it moves every node's telemetry off-node.
- **Scraping the collector's own Prometheus exporter instead of its OTLP receiver.** Rejected: a
  second scrape path is a second thing that can break, and Prometheus' OTLP receiver is the supported
  native route.
- **Threshold alerts on the error ratio per service.** Rejected: one threshold cannot distinguish
  "2 % for five minutes" from "2 % for five days", which is exactly what an error budget is for.
- **One alert per (service, SLI, rate) — 24 rules.** Rejected: twice the rule surface for the same
  signal; `$labels.slo` carries the distinction at zero cost.
- **SLO dashboards per namespace, hand-written.** Rejected by the dashboard standard: every
  dashboard is generated from the manifest, so a re-render is byte-identical and drift is
  impossible.
- **A Grafana SLO plugin or an SLO CRD.** Rejected: another controller for arithmetic seven
  recording rules already express, and the alerts would live outside the repo's rule files, where
  the red/green checks and the alert-routing checks cannot see them.
- **Error-budget alerts only, no per-window burn rates.** Rejected: "the budget is 40 % gone" is
  not actionable; "14.4× burn over the last hour and still burning" is.

## When to revisit

- **When the pipeline rules and the SLO rules are wired into `infrastructure/kustomization.yaml`**,
  delete the first row of "What is deliberately not covered yet" together with its `NotFound`
  verification.
- When a service gains a **real latency objective from a user** — the thresholds above are a first
  pass chosen from the span-metric buckets, not from an interview with the people using the UI.
- If a service starts exporting traces it becomes a candidate for an SLO; if it stops, its SLO
  records an empty vector rather than failing, so check the OTLP endpoint when a burn rate goes
  quiet.
- If Tempo's span-metric **bucket boundaries** change, the `le` values in the rules must be updated in
  the same change; a stale `le` records nothing.
- If a fourth service earns an SLO, extend `SLO_SERVICES` in the generator and the three selector
  loops in the rule file; do not copy the dashboard.
- If the 30-day SLI panels become too expensive on a large Prometheus, record
  `slo:sli_error:ratio_rate30d` and switch the panels to it — the alerting contract does not change.
- If a second Alertmanager receiver is introduced for SLOs or the pipeline (e.g. a ticket system),
  split the route on `severity`; the `alertgroup` label stays the routing key.
- If a node is added or removed, the `count(...) < 4` guard in `OtelCollectorDown` must move with the
  node count.
