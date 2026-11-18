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
- `withGpu` — add the GPU row (gpu-embedding).
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

## Adding or changing a dashboard

1. Edit or add the entry in `scripts/dashboards/manifest.json` (or change the generator if
   the standard itself changes).
2. `scripts/render_dashboards.sh`.
3. `scripts/tests/dashboard-standard-check.sh` — every AC must print `PASS`.

Never edit a `*-dashboard-configmap.yaml` by hand: the next render overwrites it, and AC-1
compares the tree against a fresh render.

## Not in this set

The four dashboards of the observability stack itself
(`infrastructure/observability/dashboards/*-dashboard-configmap.yaml` — Prometheus,
Loki, Tempo, Collector) are maintained in place, not rendered from this manifest. They
still carry one pinned Prometheus UID and one pinned Loki UID, which
`infrastructure/observability/tests/signal-correlation-check.sh` asserts.
