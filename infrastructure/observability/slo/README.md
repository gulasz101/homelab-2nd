# SLOs and burn-rate alerting (GUL-1599, OTel work order 5)

The design record for this directory is
[ADR-135: Observability design — SLOs, multi-window burn-rate alerts and the SLO dashboard](../../../docs/adr/adr-135-observability-design.md):
the three services and their targets, the two SLIs, the recorded error ratio, the four workbook
burn rates, the routing contract, the SLO dashboard and the runbook.

Files:

- `slo-prometheus-rules.yaml` — 42 recording series (3 services × 2 SLIs × 7 windows) and 12
  burn-rate alerts.
- `slo-alertmanager-config.yaml` — routes `alertgroup: slo` to the existing Mattermost webhook Secret.

The dashboard is `infrastructure/observability/dashboards/slo-dashboard-configmap.yaml`, generated
from `scripts/dashboards/manifest.json` — edit the manifest, never the ConfigMap.

## The denominator of each SLI

What a percentage is *of* decides whether it means anything. One entry per service: both SLIs of
that service, the request population each one divides by, and the traffic that is deliberately not
in it.

- **Open WebUI** — availability divides the SERVER spans that are not `STATUS_CODE_ERROR` by every
  SERVER span; latency divides the spans that finished inside 1.024 s by every SERVER span. Both
  denominators exclude the kubelet probe spans on `/health` and `/health/db`, which are neither user
  requests nor representative of them: ~4 100 of them a day, almost all fast and 200, and they used
  to dilute the ratio so far that 100 consecutive user-visible 500s moved availability by 0.03 %.
  The exclusion is `span_name!~"/health(/db)?"` on both sides of the ratio in
  `slo-prometheus-rules.yaml`, so the SLI counts user traffic only.

- **Hindsight API** — availability divides the SERVER spans that are not `STATUS_CODE_ERROR` by
  every SERVER span; latency divides the spans that finished inside 2.048 s by every SERVER span.
  Its kubelet probes (`/health/live`) never reach the span metrics at all: Hindsight keeps health
  and `/metrics` out of tracing through its own OTEL excluded URLs, so the denominator is every
  traced request with no matcher needed here.

- **Grafana** — availability divides the requests answered 5xx by every request Grafana handles;
  latency divides the requests inside 1.0 s by every request. Both denominators are Grafana's own
  request counts, and the source is its `grafana_http_request_duration_seconds` histogram, not a
  span metric: no probe traffic is in it, so nothing has to be excluded here.
