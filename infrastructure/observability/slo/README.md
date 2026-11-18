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
