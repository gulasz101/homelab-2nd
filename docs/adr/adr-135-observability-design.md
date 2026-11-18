# ADR-135: Observability design — SLOs, multi-window burn-rate alerts and the SLO dashboard

- **Status**: Accepted
- **Date**: 2026-11-18
- **Issue**: GUL-1599 (OTel work order 5, gap G7), stage GUL-1754
- **Related**: ADR-005 (per-namespace observability), GUL-1593 (OTel hardening review, which found
  gap G7), GUL-1598 (one dashboard standard and one generator)

## Context

The stack had alerts on **causes** — a pod not ready, a target down, a backup failed — and nothing
on **effects**. Every alert answered "is something broken right now"; none answered "are users
getting worse service than we promised, and how fast are we spending the allowance for that". The
result is both noisy and late: a slow-burn latency regression pages nobody, while a one-minute blip
pages everyone.

Two pieces were already in place and shaped the design:

- **Span metrics** (OTel work order 2): Tempo's `span_metrics` processor remote-writes
  `traces_spanmetrics_calls_total` and `traces_spanmetrics_latency_bucket` into the
  kube-prometheus stack. Labels: `service`, `span_name`, `span_kind`, `status_code`. The histogram
  bucket boundaries are in **seconds** (`0.002 … 16.384` by default).
- **Grafana's own instrumentation**: `grafana_http_request_duration_seconds`, a Prometheus client
  histogram labelled with `status_code`, `method` and `handler`.

Three services answer requests for a person and deserve an SLO: **Open WebUI** (the chat UI),
**Hindsight API** (the memory service behind it) and **Grafana** itself. Everything else in the
homelab is batch work, where a failed run is reported by the job, not by a latency quantile.

## Decision

### Three services, two SLIs each

| Service | Availability | Latency | Target |
|---|---|---|---|
| Open WebUI (`open-webui`) | share of `SPAN_KIND_SERVER` spans that are not `STATUS_CODE_ERROR` | share under **1.024 s** | 99.5 % |
| Hindsight API (`hindsight-api`) | same | share under **2.048 s** | 99.5 % |
| Grafana | share of HTTP requests that are not 5xx | share under **1 s** | 95 % |

The span `service` label is the OTel resource `service.name` the workload sets itself
(`OTEL_SERVICE_NAME=open-webui`, `HINDSIGHT_API_OTEL_SERVICE_NAME=hindsight-api`), so no rule has to
guess a deployment name. Only `SPAN_KIND_SERVER` spans count: a client span measures the caller's
patience, not the callee's health, and counting both double-counts one request.

The latency thresholds are **actual bucket boundaries** on purpose. `le="1"` is not a series that
exists for Tempo's span metrics, and a rule selecting it records nothing and never fires — the
silent-rule trap GUL-1593 forbids. Grafana's client library does have a `1` bucket, so it keeps the
round number.

### The recorded quantity is the error ratio

`slo:sli_error:ratio_rate<window>` for `5m, 30m, 1h, 2h, 6h, 1d, 3d` — 3 services × 2 SLIs × 7
windows = **42 series**. The error ratio, not the success ratio, is what a burn rate multiplies:
`burn_rate = error_ratio / error_budget`, with `error_budget = 1 - target` (`0.005` for a 99.5 %
target, `0.05` for 95 %). Each series carries exactly `service` and `slo`, so the alert layer
aggregates `by (slo)` without a second series shape.

### Alerting: the four workbook rates, two windows each

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

Every rule carries `alertgroup: slo` **and** `namespace: observability`. The second label is not
decoration: with prometheus-operator's default `OnNamespace` matcher strategy the generated route
carries `namespace="observability"`, so a rule labelled with another namespace fires, matches
nothing and lands on the top-level `null` receiver.

Routing: `alertgroup = slo` → the existing `homelab-node-mattermost-webhook-url` SOPS secret, as a
Slack-formatted Mattermost message with `sendResolved: true`. The secret is reused, never copied —
the operator resolves `urlSecret` in the AlertmanagerConfig's own namespace.

### Selectors are part of the contract

`PrometheusRule` needs `release: prometheus-stack` (the `Prometheus` CR's `ruleSelector`);
`AlertmanagerConfig` needs `release: kube-prometheus-stack` (`alertmanagerConfigSelector`). Without
them the operator loads the object and the stack ignores it, silently — a rule that exists and never
fires reads exactly like a rule that fires and never triggers.

The burn-rate group is written **before** the recording group in the rule file. That is a
red-stage constraint, not an ordering semantic: the check's record-block parser drops a pending
`- record:` block when the next line is an `- alert:`, so the 3d recording block that sat above the
alerts was not counted.

### The SLO dashboard is generated, like every other dashboard

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

## Consequences

- Alerts now cost a decision, not a page: the two page rates fire on real budget spend, the two
  ticket rates are for the daily sweep. A latency-only burn is saturation (CPU, a slow dependency, a
  full queue); an availability burn is errors. That ordering is written into every alert
  description, and the descriptions point at this ADR's runbook section through
  `infrastructure/observability/slo/README.md`.
- The SLOs are only as good as `STATUS_CODE_ERROR`: a service returning 200 with an error body burns
  nothing. Accepted — a status-code SLI is the honest, cheap starting point, and it is the one every
  service already reports without changes.
- Recording cost is small: 42 series over counters that are already scraped.
- A missing `le` boundary now fails loudly: a rule selecting a non-existent bucket produces no series
  and the burn rate divides by an empty vector. Adding a latency SLO means checking the generator's
  histogram buckets first.
- The `30d` SLI is a range query, not a recording series: the seven windows cover every alerting
  case, and an eighth series per (service, SLI) would be paid for on every scrape to serve four
  dashboard panels.
- **Not deployable yet**: `infrastructure/kustomization.yaml` does not list `observability/slo/*`, so
  Flux does not apply these files — the same gap the merged work-order-3 rule files
  (`observability/otel-pipeline-*`) still have. Wiring them is a separate change.

## Runbook

1. A `*SLOBurn*` page names its service and, in `$labels.slo`, which SLI is burning. Open the
   `Observability — SLOs` dashboard first: the burn-rate panel says whether this is an availability
   burn (errors) or a latency burn (saturation), and the burn-down says how much budget is left.
2. Then the service's own dashboard (llm-hub for Open WebUI, hindsight for the API, and Grafana's own
   metrics) for the cause: errors, CPU/memory saturation, a slow dependency, a full queue.
3. A ticket alert is a review item for the next working day, not an out-of-hours call.
4. If an alert is wrong rather than the service: fix the recording rule, not the threshold — a
   threshold tuned around a broken SLI hides the next real burn.

## Alternatives considered

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

- When a service gains a **real latency objective from a user** — the thresholds above are a first
  pass chosen from the span-metric buckets, not from an interview with the people using the UI.
- If Tempo's span-metric **bucket boundaries** change, the `le` values in the rules must be updated in
  the same change; a stale `le` records nothing.
- If a fourth service earns an SLO, extend `SLO_SERVICES` in the generator and the three selector
  loops in the rule file; do not copy the dashboard.
- If the 30-day SLI panels become too expensive on a large Prometheus, record
  `slo:sli_error:ratio_rate30d` and switch the panels to it — the alerting contract does not change.
- If a second Alertmanager receiver is introduced for SLOs (e.g. a ticket system), split the route on
  `severity`; the `alertgroup: slo` label stays the routing key.
