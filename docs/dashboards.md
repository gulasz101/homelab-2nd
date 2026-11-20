# Dashboards

One standard, one generator. Every Grafana dashboard that ships from `apps/*/` and
`infrastructure/auth/` is an *output*: `scripts/render_namespace_dashboard.py` renders it
from `scripts/dashboards/manifest.json`, and re-rendering reproduces each ConfigMap byte
for byte. Nothing is hand-edited, so a dashboard cannot drift from the standard.

The machine-readable half of this document is `scripts/tests/dashboard-standard-check.sh`
(`AC-1`…`AC-7`); the rules below are the prose version of what that check enforces.

## Rendering

```bash
scripts/render_dashboards.sh                        # rewrite the tree in place
scripts/render_dashboards.sh --output-dir /tmp/out   # render somewhere else
scripts/render_dashboards.sh --list                  # print the manifest outputs
```

The wrapper forwards to the generator, which also accepts `--manifest PATH`. Both take no
third-party dependencies — the Air and CI have no PyYAML, so the generator is standard
library only and writes the ConfigMap as JSON (which is valid YAML).

## The standard

Every dashboard in the set:

| Rule | Value |
| --- | --- |
| Title | `<namespace> — <What>` (em dash, namespace first) |
| Tags | `homelab` plus the namespace |
| Refresh | `30s` |
| Schema | one `SCHEMA_VERSION` constant for the whole set |
| Datasource | every panel points at the template variables `datasource` (Prometheus) and `loki` (Loki), never at a datasource UID |
| Link | a `homelab`-tagged `dashboards` dropdown (“Homelab dashboards”) |
| Rows | `Golden signals`, then `Resources`, then `Logs` |
| Panels | every non-row, non-text panel carries a `description` and a `fieldConfig.defaults.unit` |

The datasource rule is the important one. Grafana mints a UID per provisioned
datasource, so a dashboard that hardcodes one goes blank the moment the datasource is
re-provisioned (GUL-1693). The two variables resolve to the provisioned Prometheus and
Loki at load time, so a rebuilt stack cannot blind a dashboard.

Rows are the reading order a responder needs: is it saturated or failing (golden
signals), what is it consuming (resources), what is it saying (logs).

## The manifest

`scripts/dashboards/manifest.json` holds one entry per ConfigMap:

```json
{
  "output": "apps/arr-stack/arr-stack-dashboard-configmap.yaml",
  "namespace": "arr-stack",
  "title": "arr-stack — Sonarr / Radarr / Prowlarr / Bazarr / Jellyfin",
  "uid": "arr-stack-dashboard",
  "services": [{"pod": "sonarr", "label": "sonarr", "pvc": "sonarr-config"}]
}
```

- `output` — repo-relative path of the ConfigMap the entry renders.
- `namespace` — the Kubernetes namespace the panels query.
- `title`, `uid` — the dashboard title and Grafana UID.
- `services` — one item per workload: `pod` is a pod-name *prefix* (rendered as
  `pod=~"<prefix>.*"`), `label` is what the legend shows, and `pvc` names the volume to
  chart. A `pvc` ending in `-*` is a CNPG cluster (`hindsight-db-*`): the generator emits
  an instance regex, because the instance number changes on switchover and a hardcoded one
  goes stale (`scripts/tests/cnpg-instance-name-check.sh`). A service may also carry
  `k8sNamespace` (whiteboard's tunnel runs in `apps-tldraw`, not `apps-whiteboard`) and
  `exclude`, a list of sibling pod prefixes to subtract from the selector — `nextcloud-`
  also matches `nextcloud-db` and `nextcloud-redis-master`, and summing those into the
  app panel double-counts them.

Optional per entry:

- `k8sNamespace` — when the Kubernetes namespace is not the dashboard name (whiteboard
  renders as `whiteboard` but queries `apps-whiteboard`).
- `panels` — extra panels, see below (gpu-embedding uses this for its node-side power
  and thermal signal, because the GPU has no exporter any more).
- `configmapName`, `folder` — the ConfigMap name and the `grafana.folder` annotation.
- `dashboards` — render several dashboards into one ConfigMap. Hindsight uses this to ship
  `hindsight-operations.json`, `hindsight-api-service.json` and `hindsight-llm.json` in the
  `hindsight-dashboards` ConfigMap, folder `hindsight`.
- `panels` — the app's own panels, appended to one of the standard rows. Each item is
  `row` (`Golden signals` or `Resources`), `type` (`stat` or `timeseries`), `title`,
  `description`, `unit`, `targets` (`[{"expr": …, "legend": …}]`) plus optional
  `thresholds`, `datasource: "loki"`, `min`, `max`, `w`, `h`. They exist so an app with
  its own metrics (Hindsight's consolidation backlog, the whiteboard tunnel) keeps the
  signal the dashboard was built for; they are rendered by the same primitives, so they
  obey the datasource, description and unit rules, and the generator stays the only
  writer.
- `variables` — extra Grafana template variables as ready-made variable objects, merged
  after the two required datasource variables. Hindsight adds a `tenant` query variable,
  which every one of its queries filters on.
- `platform` — `true` for a dashboard that is about the cluster itself rather than one
  application (`Observability — Pipeline health`, `Homelab — Flux reconciliation and
  nodes`, the power and system-load boards). The row panels and every Prometheus target
  then carry the pinned Prometheus UID and the Loki row the pinned Loki UID instead of
  `${datasource}` / `${loki}`, because these boards are also the dashboards that answer
  "is the datasource itself alive?". The logs panels keep the `${loki}` variable.
- `logsNamespace` — the namespace the Logs row streams from, when it is not the
  dashboard's own (defaults to `k8sNamespace` or `namespace`).

A dashboard of an application is an entry in this file, not a hand-written ConfigMap:
`karakeep`, `riffradar`, `openchamber` and `host-watch` were the last four apps without
one and are rendered here now. An app's directory `kustomization.yaml` must list the
rendered `*-dashboard-configmap.yaml`, otherwise Flux never applies it and AC-2 of
`scripts/tests/dashboard-standard-check.sh` says so by name.

## Adding or changing a dashboard

1. Edit or add the entry in `scripts/dashboards/manifest.json` (or change the generator if
   the standard itself changes).
2. `scripts/render_dashboards.sh`.
3. `scripts/tests/dashboard-standard-check.sh` — every AC must print `PASS`.

Never edit a `*-dashboard-configmap.yaml` by hand: the next render overwrites it, and AC-1
compares the tree against a fresh render.

## Making the panels actually return data

A dashboard that renders but queries nothing is worse than no dashboard: the panel looks
healthy and the signal is gone. `scripts/tests/dashboard-liveness-check.sh` (GUL-1758) is
the machine-readable half of these rules; it reads the ConfigMaps in the tree and the
manifest, and every generated *and* hand-maintained dashboard has to obey it.

- **CPU limits and requests come from kube-state-metrics.** `container_spec_cpu_quota` /
  `container_spec_cpu_period` are cAdvisor series this cluster no longer exports, so a
  panel built on them is permanently empty. Select
  `kube_pod_container_resource_limits{resource="cpu"}` or
  `kube_pod_container_resource_requests{resource="cpu"}` instead.
- **No `nvidia_smi_` metrics.** The GPU exporter was retired; GPU load is read from the
  node side (`node_rapl_`, `node_hwmon_`, `node_thermal_`).
- **Node series are selected by job, never by host.** node-exporter is scraped behind
  `job="node-exporter"` (static targets use `job="omv-node"`); a `host=` matcher is not
  on the series and leaves the panel empty.
- **LogQL stays on Loki.** A panel whose targets contain `count_over_time(` or a
  `{k8s_namespace_name=…}` stream selector declares `datasource: loki` (the `${loki}`
  variable), and a logs panel must not filter its own telemetry/otel lines out of the
  stream it exists to show. `|=` and `|~` are the valid line filters; `|=~` is not.
- **Selectors name things that exist.** Every `namespace="X"` is a namespace the manifest
  declares for that dashboard, and every `persistentvolumeclaim="X"` is a CNPG instance
  (`…-0`) or a claim in the check's `kubectl get pvc -A` allowlist.

Run it the same way as the standard suite: `bash scripts/tests/dashboard-liveness-check.sh`
(`--ac N` for one rule).

## Not app dashboards: the platform boards are rendered too

The five dashboards of the observability stack and the cluster itself
(`infrastructure/observability/dashboards/*-dashboard-configmap.yaml`: pipeline health,
SLOs, Flux reconciliation and nodes, power and thermals, system load) are generated from
this same manifest, with `"platform": true`. They still carry one pinned Prometheus UID
and one pinned Loki UID, which
`infrastructure/observability/tests/signal-correlation-check.sh` asserts — that is what
`platform` is for. Re-rendering them is what keeps them honest: before GUL-1973 they were
the only dashboards in the repo nobody could reproduce.
