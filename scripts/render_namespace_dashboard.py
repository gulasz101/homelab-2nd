#!/usr/bin/env python3
"""
Render the homelab Grafana dashboard set — the one generator.

The standard it enforces is written down in `docs/dashboards.md`; the machine
readable half lives in `scripts/dashboards/manifest.json`. Every dashboard in
`apps/*/` and `infrastructure/auth/` is an output of this file: re-rendering the
manifest reproduces each ConfigMap byte for byte (no hand edits, no drift).

    scripts/render_dashboards.sh                      # rewrite the tree in place
    scripts/render_dashboards.sh --output-dir /tmp/x  # render somewhere else

Standard, in one paragraph: title `<namespace> — <What>`, tags `homelab` plus
the namespace, refresh `30s`, one SCHEMA_VERSION for the whole set, two
datasource template variables (`datasource` for Prometheus, `loki` for Loki)
that every panel points at instead of a hardcoded uid, the homelab dashboards
dropdown link, three rows in the order Golden signals / Resources / Logs, and
every data panel carrying a description and a unit.

Output is a Kubernetes ConfigMap in JSON (valid YAML), with the dashboard under
`.data.<key>.json`, labelled for the Grafana sidecar (`grafana_dashboard: "1"`)
and annotated with its folder (`grafana.folder`).

Standard library only: the Air and CI have no PyYAML.
"""

import argparse
import json
import os
import sys

# One schema version for every dashboard in the set (GUL-1598). Bumping this is
# a deliberate, set-wide change: every dashboard is re-rendered in the same PR.
SCHEMA_VERSION = 41

MANIFEST_DEFAULT = "scripts/dashboards/manifest.json"

# Panels never name a datasource uid. Both uids Grafana mints are pinned in the
# provisioning file and reachable through these variables, so a re-provisioned
# datasource cannot blind a dashboard (GUL-1693 is exactly that failure).
PROM = {"type": "prometheus", "uid": "${datasource}"}
LOKI = {"type": "loki", "uid": "${loki}"}

# The two uids `infrastructure/observability/grafana-helm-release.yaml` pins
# (GUL-1693). A `platform` dashboard of the observability stack itself names
# them instead of the variables: signal-correlation-check.sh AC-1 requires the
# dashboards to query exactly one Prometheus uid and one Loki uid, and answers
# "the dashboards query 0 prometheus uids, so there is no single uid to pin"
# once every panel in the set uses ${datasource}. The row panels carry the uid
# and the data panels resolve a variable, so dashboard-liveness-check.sh AC-5
# (every logs panel declares ${loki}) still holds.
PINNED_PROM = {"type": "prometheus", "uid": "PBFA97CFB590B2093"}
PINNED_LOKI = {"type": "loki", "uid": "P8E80F9AEF21F6940"}

ROW_ORDER = ("Golden signals", "Resources", "Logs")

HOMELAB_LINK = {
    "asDropdown": True,
    "icon": "external link",
    "includeVars": False,
    "keepTime": True,
    "tags": ["homelab"],
    "targetBlank": False,
    "title": "Homelab dashboards",
    "tooltip": "Every homelab dashboard",
    "type": "dashboards",
    "url": "",
}

THRESHOLDS_80_90 = [
    {"color": "green", "value": None},
    {"color": "yellow", "value": 80},
    {"color": "red", "value": 90},
]

THRESHOLDS_75_90 = [
    {"color": "green", "value": None},
    {"color": "yellow", "value": 75},
    {"color": "red", "value": 90},
]

# --- SLO dashboards (GUL-1599) --------------------------------------------
# The SLOs `infrastructure/observability/slo/slo-prometheus-rules.yaml` records:
# three services, two SLIs, one error budget per service (1 - target). Panels
# read the recorded ERROR ratio and divide by that same budget, so the dashboard
# and the burn-rate alerts cannot disagree about what a burn rate means.
SLO_SERVICES = (
    {"service": "open-webui", "label": "Open WebUI", "target": 99.5, "budget": "0.005"},
    {"service": "hindsight-api", "label": "Hindsight API", "target": 99.5, "budget": "0.005"},
    {"service": "grafana", "label": "Grafana", "target": 95, "budget": "0.05"},
)
SLO_SLIS = ("availability", "latency")
SLO_BURN_WINDOWS = ("1h", "6h")

# The 30-day SLI and the budget-left figures pool the raw counters over the whole
# window instead of averaging the recorded per-day ratios: an average weights a
# quiet day like a busy one, so a burst of errors on a busy day disappears from
# the number that is supposed to show it (GUL-2165, pooled SLO arithmetic).
SLO_WINDOW = "30d"
# Open WebUI's kubelet probes arrive as SERVER spans and are not user traffic; the
# recording rules drop them on both sides of the ratio, so the 30-day panels have
# to drop them with the same matcher or the dashboard and the alerts disagree.
SLO_PROBE_EXCLUSION = 'span_name!~"/health(/db)?"'
# The latency threshold of each service, as the metric spells it: span-metric
# buckets are in seconds and named 1.024 / 2.048, Grafana's are 1.0.
SLO_LATENCY_BUCKET = {"open-webui": "1.024", "hindsight-api": "2.048", "grafana": "1.0"}

def slo_sum_increase(metric, selector, window=SLO_WINDOW):
    """`sum(increase(<metric>{<selector>}[<window>]))`, braces only when needed."""
    if selector:
        return "sum(increase(%s{%s}[%s]))" % (metric, selector, window)
    return "sum(increase(%s[%s]))" % (metric, window)


def slo_pooled_counts(service, sli, window=SLO_WINDOW):
    """(errors, total) for one service/SLI over `window`, from the counters.

    Pooling means summing the errors and the requests and dividing once, which
    is only possible over the counters the recording rules read - a recorded
    ratio has already lost its denominator. The metric, the labels and the
    latency bucket are the ones `slo-prometheus-rules.yaml` uses, probe
    exclusion included, so the two cannot drift.
    """
    bucket = SLO_LATENCY_BUCKET[service]
    if service == "grafana":
        if sli == "availability":
            return (slo_sum_increase("grafana_http_request_duration_seconds_count", 'status_code=~"5.."', window),
                    slo_sum_increase("grafana_http_request_duration_seconds_count", "", window))
        total = slo_sum_increase("grafana_http_request_duration_seconds_bucket", 'le="+Inf"', window)
        good = slo_sum_increase("grafana_http_request_duration_seconds_bucket", 'le="%s"' % bucket, window)
        return ("%s - %s" % (total, good), total)
    base = 'service="%s", span_kind="SPAN_KIND_SERVER"' % service
    if service == "open-webui":
        base += ", " + SLO_PROBE_EXCLUSION
    if sli == "availability":
        return (slo_sum_increase("traces_spanmetrics_calls_total",
                                 base + ', status_code="STATUS_CODE_ERROR"', window),
                slo_sum_increase("traces_spanmetrics_calls_total", base, window))
    total = slo_sum_increase("traces_spanmetrics_latency_bucket", base + ', le="+Inf"', window)
    good = slo_sum_increase("traces_spanmetrics_latency_bucket", base + ', le="%s"' % bucket, window)
    return ("%s - %s" % (total, good), total)


def slo_pooled_ratio(service, sli, window=SLO_WINDOW):
    """The pooled error ratio of one service/SLI: summed errors over summed total."""
    errors, total = slo_pooled_counts(service, sli, window)
    return "(%s) / (%s)" % (errors, total)


LOG_OPTIONS = {
    "dedupStrategy": "none",
    "enableLogDetails": True,
    "prettifyLogMessage": True,
    "showCommonLabels": True,
    "showControls": True,
    "showFieldSelector": True,
    "showLabels": True,
    "showLogContextToggle": True,
    "showTime": True,
    "sortOrder": "Descending",
    "syntaxHighlighting": True,
    "wrapLogMessage": True,
}


# ---------------------------------------------------------------------------
# panel fieldConfig / options builders
# ---------------------------------------------------------------------------
def timeseries_defaults(unit, min_val=None, max_val=None, thresholds=None):
    defaults = {
        "unit": unit,
        "custom": {
            "axisCenteredZero": False,
            "axisColorMode": "text",
            "axisLabel": "",
            "axisPlacement": "auto",
            "barAlignment": 0,
            "drawStyle": "line",
            "fillOpacity": 20,
            "gradientMode": "opacity",
            "hideFrom": {"legend": False, "tooltip": False, "viz": False},
            "insertNulls": False,
            "lineInterpolation": "linear",
            "lineWidth": 1,
            "pointSize": 5,
            "scaleDistribution": {"type": "linear"},
            "showPoints": "never",
            "spanNulls": False,
            "stacking": {"group": "A", "mode": "none"},
            "thresholdsStyle": {"mode": "off"},
        },
    }
    if min_val is not None:
        defaults["min"] = min_val
    if max_val is not None:
        defaults["max"] = max_val
    if thresholds:
        defaults["thresholds"] = {"mode": "absolute", "steps": thresholds}
    return defaults


def stat_defaults(unit, thresholds=None):
    return {
        "unit": unit,
        "custom": {},
        "min": None,
        "max": None,
        "thresholds": {"mode": "absolute", "steps": thresholds or THRESHOLDS_80_90},
    }


def timeseries_options():
    return {
        "legend": {
            "calcs": ["lastNotNull", "max"],
            "displayMode": "table",
            "placement": "right",
            "showLegend": True,
        },
        "tooltip": {"mode": "multi", "sort": "none"},
    }


def stat_options():
    return {
        "colorMode": "value",
        "graphMode": "area",
        "justifyMode": "auto",
        "orientation": "auto",
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
        "textMode": "auto",
    }


# ---------------------------------------------------------------------------
# PromQL / LogQL
# ---------------------------------------------------------------------------
def pod_selector(namespace, prefix, exclude=()):
    """A pod-name prefix as a selector, optionally minus sibling workloads.

    `exclude` exists because a prefix is a substring match: `nextcloud-` also
    matches `nextcloud-db` and `nextcloud-redis-master`, and summing those into
    the app panel double-counts them. RE2 has no lookahead, so the exclusions
    are a second `pod!~` matcher.
    """
    selector = 'namespace="%s",pod=~"%s.*"' % (namespace, prefix)
    if exclude:
        if isinstance(exclude, str):
            exclude = [exclude]
        selector += ',pod!~"%s"' % "|".join("%s.*" % item for item in exclude)
    return selector


def pvc_selector(pvc):
    """A PVC name as a selector. `name-*` means "<name>, any instance number".

    A CNPG instance PVC ("<cluster>-<n>") changes name on every switchover, so
    the manifest names the cluster and this renders the instance regex.
    """
    if pvc.endswith("-*"):
        return 'persistentvolumeclaim=~"%s-[0-9]+"' % pvc[:-2]
    return 'persistentvolumeclaim="%s"' % pvc


# ---------------------------------------------------------------------------
# dashboard builder
# ---------------------------------------------------------------------------
class Dashboard:
    """Accumulates panels with stable ids and a running grid cursor."""

    def __init__(self, spec):
        self.spec = spec
        self.namespace = spec["k8sNamespace"]
        # A platform dashboard shows the cluster, not one namespace's workloads,
        # so it renders only the manifest's own panels and pins the datasource
        # uids (see PINNED_PROM above).
        self.is_platform = bool(spec.get("platform"))
        self.prom = dict(PINNED_PROM) if self.is_platform else dict(PROM)
        self.logs_namespace = spec.get("logsNamespace") or self.namespace
        self.panels = []
        self.next_id = 1
        self.y = 0

    # -- primitives ---------------------------------------------------------
    def _add(self, panel, x, y, w, h):
        panel["id"] = self.next_id
        panel["gridPos"] = {"h": h, "w": w, "x": x, "y": y}
        self.next_id += 1
        self.panels.append(panel)
        return panel

    def row(self, title, datasource=None):
        panel = {
            "collapsed": False,
            "panels": [],
            "title": title,
            "type": "row",
        }
        if self.is_platform:
            panel["datasource"] = dict(datasource or self.prom)
        self._add(panel, 0, self.y, 24, 1)
        self.y += 1

    def text(self, title, content, h=2):
        panel = {
            "options": {"content": content, "mode": "markdown"},
            "title": title,
            "type": "text",
            "datasource": dict(self.prom),
        }
        self._add(panel, 0, self.y, 24, h)
        self.y += h

    def timeseries(self, title, description, unit, targets, x, y, w=12, h=7,
                   min_val=None, max_val=None, thresholds=None, datasource=None):
        panel = {
            "datasource": dict(datasource or self.prom),
            "description": description,
            "fieldConfig": {
                "defaults": timeseries_defaults(unit, min_val, max_val, thresholds),
                "overrides": [],
            },
            "options": timeseries_options(),
            "targets": targets,
            "title": title,
            "type": "timeseries",
        }
        return self._add(panel, x, y, w, h)

    def stat(self, title, description, unit, targets, x, y, w=8, h=4,
             thresholds=None, datasource=None):
        panel = {
            "datasource": dict(datasource or self.prom),
            "description": description,
            "fieldConfig": {"defaults": stat_defaults(unit, thresholds), "overrides": []},
            "options": stat_options(),
            "targets": targets,
            "title": title,
            "type": "stat",
        }
        return self._add(panel, x, y, w, h)

    def logs(self, title, description):
        # Always the ${loki} variable, even on a platform dashboard: a logs panel
        # that pins a uid goes blank on a re-provisioned datasource and fails
        # dashboard-liveness-check.sh AC-5.
        namespace = self.logs_namespace
        base = '{k8s_namespace_name="%s"}' % namespace
        panel = {
            "datasource": dict(LOKI),
            "description": description,
            "fieldConfig": {"defaults": {"unit": "none"}, "overrides": []},
            "options": dict(LOG_OPTIONS),
            "targets": [
                {
                    "editorMode": "code",
                    "expr": base,
                    "queryType": "range",
                    "refId": "A",
                },
                {
                    "editorMode": "code",
                    "expr": '%s |~ "(?i)error|warn|fatal|panic"' % base,
                    "queryType": "range",
                    "refId": "B",
                },
                {
                    "editorMode": "code",
                    "expr": '%s |~ "(?i)start|ready|listen|shutdown"' % base,
                    "queryType": "range",
                    "refId": "C",
                },
            ],
            "title": title,
            "type": "logs",
        }
        return self._add(panel, 0, self.y, 24, 12)

    # -- the three standard rows -------------------------------------------
    def golden_signals(self):
        self.row(ROW_ORDER[0])
        ns = self.namespace
        y = self.y

        self.timeseries(
            "CPU saturation — % of limit",
            "CPU used by every container in the namespace as a percentage of its "
            "Kubernetes CPU limit. Above 80% the workload is throttling before it "
            "is unhealthy.",
            "percent",
            [
                {
                    # kube-state-metrics, not the cAdvisor quota pair: the
                    # cluster stopped exporting container_spec_cpu_* and every
                    # panel built on it rendered empty (GUL-1758).
                    "expr": '100 * sum(rate(container_cpu_usage_seconds_total{namespace="%s",container!=""}[5m]))'
                            ' / sum(kube_pod_container_resource_limits{namespace="%s",resource="cpu",container!=""})'
                            % (ns, ns),
                    "legendFormat": "used of limit",
                    "refId": "A",
                },
            ],
            0, y, w=12, h=7, max_val=100, thresholds=THRESHOLDS_80_90,
        )
        self.timeseries(
            "Memory saturation — % of limit",
            "Working-set memory of every container in the namespace as a percentage "
            "of its Kubernetes memory limit. Rising to the limit ends in OOMKill.",
            "percent",
            [
                {
                    "expr": '100 * sum(container_memory_working_set_bytes{namespace="%s",container!=""})'
                            ' / sum(kube_pod_container_resource_limits{namespace="%s",resource="memory",container!=""})'
                            % (ns, ns),
                    "legendFormat": "used of limit",
                    "refId": "A",
                },
            ],
            12, y, w=12, h=7, max_val=100, thresholds=THRESHOLDS_80_90,
        )
        y += 7

        self.timeseries(
            "Pod network throughput",
            "Bytes per second received and transmitted by each pod in the namespace "
            "(interface names may add a little loopback traffic).",
            "Bps",
            [
                {
                    "expr": 'sum by (pod) (rate(container_network_receive_bytes_total{namespace="%s"}[5m]))' % ns,
                    "legendFormat": "{{pod}} receive",
                    "refId": "A",
                },
                {
                    "expr": 'sum by (pod) (rate(container_network_transmit_bytes_total{namespace="%s"}[5m]))' % ns,
                    "legendFormat": "{{pod}} transmit",
                    "refId": "B",
                },
            ],
            0, y, w=12, h=7,
        )
        self.timeseries(
            "Container restarts",
            "Container restarts in the namespace over the last 5 minutes. Any "
            "non-zero value is a crash loop or a probe killing a slow start.",
            "short",
            [
                {
                    "expr": 'sum by (pod, container) (increase(kube_pod_container_status_restarts_total{namespace="%s"}[5m]))' % ns,
                    "legendFormat": "{{pod}}/{{container}}",
                    "refId": "A",
                },
            ],
            12, y, w=12, h=7, min_val=0,
        )
        y += 7

        self.timeseries(
            "Error log lines per minute",
            "Loki lines in the namespace matching error/warn/fatal/panic, per "
            "minute. The log-side half of the error signal when a service exposes "
            "no request metrics.",
            "short",
            [
                {
                    "expr": 'sum(count_over_time({k8s_namespace_name="%s"} |~ "(?i)error|warn|fatal|panic" [1m]))' % ns,
                    "legendFormat": "matching lines",
                    "refId": "A",
                },
            ],
            # A count_over_time is LogQL, so the panel must point at Loki: on the
            # Prometheus datasource every one of these dashboards query-errors.
            0, y, w=24, h=6, min_val=0, datasource=LOKI,
        )
        y += 6
        self.y = y
        self.custom_panels(ROW_ORDER[0])

    def service_namespace(self, service):
        """The namespace a workload actually runs in.

        A dashboard is usually one namespace, but whiteboard's tunnel lives in
        `apps-tldraw` (the Cloudflare route is pinned to a service there), so a
        service may name its own namespace instead of the dashboard's.
        """
        return service.get("k8sNamespace") or self.namespace

    def service_stats(self):
        """The CPU / memory / PVC stat triplet, rendered once per manifest service.

        Shared with the platform dashboards: those list the workloads they care
        about instead of covering a whole namespace.
        """
        y = self.y
        for service in self.spec.get("services") or []:
            pod = service["pod"]
            label = service.get("label") or pod
            pvc = service.get("pvc")
            pod_ns = self.service_namespace(service)
            excluded = service.get("exclude") or ()
            selector = pod_selector(pod_ns, pod, excluded)

            self.stat(
                "%s CPU" % label,
                "CPU used by %s pods next to their request and limit, in cores." % label,
                "cores",
                [
                    {
                        "expr": 'sum(rate(container_cpu_usage_seconds_total{%s,container!=""}[5m]))'
                                % selector,
                        "instant": True,
                        "legendFormat": "usage",
                        "refId": "A",
                    },
                    {
                        "expr": 'sum(kube_pod_container_resource_requests{%s,resource="cpu",container!=""})'
                                % selector,
                        "instant": True,
                        "legendFormat": "request",
                        "refId": "B",
                    },
                    {
                        "expr": 'sum(kube_pod_container_resource_limits{%s,resource="cpu",container!=""})'
                                % selector,
                        "instant": True,
                        "legendFormat": "limit",
                        "refId": "C",
                    },
                ],
                0, y,
            )
            self.stat(
                "%s memory" % label,
                "Working-set memory of %s pods next to their request and limit, in bytes." % label,
                "bytes",
                [
                    {
                        "expr": 'sum(container_memory_working_set_bytes{%s,container!=""})'
                                % selector,
                        "instant": True,
                        "legendFormat": "usage",
                        "refId": "A",
                    },
                    {
                        "expr": 'sum(kube_pod_container_resource_requests{%s,resource="memory",container!=""})'
                                % selector,
                        "instant": True,
                        "legendFormat": "request",
                        "refId": "B",
                    },
                    {
                        "expr": 'sum(kube_pod_container_resource_limits{%s,resource="memory",container!=""})'
                                % selector,
                        "instant": True,
                        "legendFormat": "limit",
                        "refId": "C",
                    },
                ],
                8, y,
            )
            if pvc:
                self.stat(
                    "%s PVC" % label,
                    "Used and capacity bytes of the %s persistent volume claim." % pvc,
                    "bytes",
                    [
                        {
                            "expr": 'kubelet_volume_stats_used_bytes{namespace="%s",%s}'
                                    % (pod_ns, pvc_selector(pvc)),
                            "instant": True,
                            "legendFormat": "used",
                            "refId": "A",
                        },
                        {
                            "expr": 'kubelet_volume_stats_capacity_bytes{namespace="%s",%s}'
                                    % (pod_ns, pvc_selector(pvc)),
                            "instant": True,
                            "legendFormat": "capacity",
                            "refId": "B",
                        },
                    ],
                    16, y,
                )
            y += 4
        self.y = y

    def resources(self):
        self.row(ROW_ORDER[1])
        ns = self.namespace
        self.service_stats()
        y = self.y

        self.timeseries(
            "CPU usage vs request vs limit per pod",
            "CPU per pod and container next to its Kubernetes request and limit, in "
            "cores. A usage line flattening onto the limit is throttling.",
            "cores",
            [
                {
                    "expr": 'sum by (pod, container) (rate(container_cpu_usage_seconds_total{namespace="%s",container!=""}[5m]))' % ns,
                    "legendFormat": "{{pod}}/{{container}} usage",
                    "refId": "A",
                },
                {
                    "expr": 'sum by (pod, container) (kube_pod_container_resource_limits{namespace="%s",resource="cpu",container!=""})' % ns,
                    "legendFormat": "{{pod}}/{{container}} limit",
                    "refId": "B",
                },
                {
                    "expr": 'sum by (pod, container) (kube_pod_container_resource_requests{namespace="%s",resource="cpu",container!=""})' % ns,
                    "legendFormat": "{{pod}}/{{container}} request",
                    "refId": "C",
                },
            ],
            0, y, w=24, h=8,
        )
        y += 8

        self.timeseries(
            "Memory usage vs request vs limit per pod",
            "Working-set memory per pod and container next to its Kubernetes request "
            "and limit, in bytes.",
            "bytes",
            [
                {
                    "expr": 'sum by (pod, container) (container_memory_working_set_bytes{namespace="%s",container!=""})' % ns,
                    "legendFormat": "{{pod}}/{{container}} usage",
                    "refId": "A",
                },
                {
                    "expr": 'sum by (pod, container) (kube_pod_container_resource_limits{namespace="%s",resource="memory",container!=""})' % ns,
                    "legendFormat": "{{pod}}/{{container}} limit",
                    "refId": "B",
                },
                {
                    "expr": 'sum by (pod, container) (kube_pod_container_resource_requests{namespace="%s",resource="memory",container!=""})' % ns,
                    "legendFormat": "{{pod}}/{{container}} request",
                    "refId": "C",
                },
            ],
            0, y, w=24, h=8,
        )
        y += 8

        if self.spec.get("services"):
            self.timeseries(
                "PVC utilisation",
                "Used space of every persistent volume claim in the namespace as a "
                "percentage of its capacity.",
                "percent",
                [
                    {
                        "expr": '100 * kubelet_volume_stats_used_bytes{namespace="%s"}'
                                ' / kubelet_volume_stats_capacity_bytes{namespace="%s"}' % (ns, ns),
                        "legendFormat": "{{persistentvolumeclaim}}",
                        "refId": "A",
                    },
                ],
                0, y, w=12, h=7, max_val=100, thresholds=THRESHOLDS_75_90,
            )
        self.timeseries(
            "Node disk utilisation",
            "Used space of the node filesystems holding the k3s data directory and "
            "the PVC backing store, as a percentage of capacity. node-exporter is "
            "scraped behind its job label, not behind a per-host label.",
            "percent",
            [
                {
                    "expr": '100 - ((node_filesystem_avail_bytes{job="node-exporter",fstype!="tmpfs",fstype!="overlay"} * 100)'
                            ' / node_filesystem_size_bytes{job="node-exporter",fstype!="tmpfs",fstype!="overlay"})',
                    "legendFormat": "{{mountpoint}}",
                    "refId": "A",
                },
            ],
            12, y, w=12, h=7, max_val=100, thresholds=THRESHOLDS_75_90,
        )
        y += 7

        self.y = y
        self.custom_panels(ROW_ORDER[1])

    def slo_golden_signals(self):
        """Golden signals row of an SLO dashboard: the SLI, the budget, the burn.

        Every query is over the same counters the recording rules in
        `infrastructure/observability/slo/slo-prometheus-rules.yaml` read, with
        the same labels and the same probe exclusion, so the SLI definition
        lives in two places that are generated from one each rather than in a
        dashboard that quietly disagrees with the alerts.
        The 30-day SLI is not one of the seven recorded windows (the alerts need
        seven, not eight), so it is POOLED, not averaged: the errors and the
        requests are summed over the whole 30 days and divided once. Averaging
        the recorded 1d error ratios would weight a quiet day as heavily as a
        busy one and hide a burst of errors that landed on the busy one
        (GUL-2165). `[30d]` is in the query rather than in a hidden recording
        rule.

        Four stats per service, one pair per SLI: the 30-day SLI and that SLI's
        own error budget. One "budget left" figure per service hides which of
        the two is being spent, and the pair is what the alerts are split on:
        an availability burn is errors, a latency burn is saturation, so a
        service can be out of budget on one SLI while the other is fine
        (GUL-1962).
        """
        self.row(ROW_ORDER[0])
        y = self.y
        for slo in SLO_SERVICES:
            service = slo["service"]
            label = slo["label"]
            budget = slo["budget"]
            target = slo["target"]
            for index, sli in enumerate(SLO_SLIS):
                ratio = slo_pooled_ratio(service, sli)
                self.stat(
                    "%s %s — 30d" % (label, sli),
                    "Share of %s requests in the last 30 days that met the %s SLO "
                    "(target %s %%). Pooled over the whole window: the failed "
                    "requests and the total are summed and divided once, so a "
                    "busy day counts for more than a quiet one. It is the "
                    "inverse of the number the error budget and the burn rates "
                    "are built from.%s"
                    % (label, sli, ("%.1f" % target).rstrip("0").rstrip("."),
                       " Kubelet probe traffic (/health, /health/db) is excluded."
                       if service == "open-webui" else ""),
                    "percent",
                    [
                        {
                            "expr": "100 * (1 - %s)" % ratio,
                            "instant": True,
                            "legendFormat": sli,
                            "refId": "A",
                        },
                    ],
                    6 * index, y, w=6, h=4,
                    thresholds=[
                        {"color": "red", "value": None},
                        {"color": "green", "value": target},
                    ],
                )
            # The same budget number, once per SLI: the panel selects the pair,
            # so a reader can see which half of the service is spending it
            # without swapping a legend entry. 25 % / 50 % are the page and
            # ticket boundaries the burn-rate alerts use.
            for index, sli in enumerate(SLO_SLIS):
                ratio = slo_pooled_ratio(service, sli)
                self.stat(
                    "%s %s error budget left — 30d" % (label, sli),
                    "How much of %s's 30-day %s error budget is unspent, in "
                    "percent. 100 %% means nothing spent, 0 %% means the %s %% "
                    "target has been missed; the budget is %s (1 - target). "
                    "Pooled, not averaged: summed errors over summed requests "
                    "over the 30 days, so a burst on a busy day is not diluted "
                    "by the quiet days around it. One "
                    "budget per SLI: an availability burn is errors, a latency "
                    "burn is saturation, so the two are checked differently once "
                    "one of them runs out. Under 25 %% the service pages at the "
                    "fast burn rate within hours, under 50 %% the ticket alerts "
                    "start.%s"
                    % (label, sli, ("%.1f" % target).rstrip("0").rstrip("."), budget,
                       " Kubelet probe traffic (/health, /health/db) is excluded."
                       if service == "open-webui" else ""),
                    "percent",
                    [
                        {
                            "expr": "100 * (1 - (%s) / %s)" % (ratio, budget),
                            "instant": True,
                            "legendFormat": sli,
                            "refId": "A",
                        },
                    ],
                    6 * (len(SLO_SLIS) + index), y, w=6, h=4,
                    thresholds=[
                        {"color": "red", "value": None},
                        {"color": "yellow", "value": 25},
                        {"color": "green", "value": 50},
                    ],
                )
            y += 4

            targets = []
            for ref, window in zip(("A", "B"), SLO_BURN_WINDOWS):
                targets.append({
                    "expr": 'slo:sli_error:ratio_rate%s{service="%s"} / %s' % (window, service, budget),
                    "legendFormat": "{{slo}} %s burn rate" % window,
                    "refId": ref,
                })
            self.timeseries(
                "%s burn rate — how fast the error budget is going" % label,
                "Error ratio over the last %s divided by the %s error budget, per "
                "SLI. 1 is spending exactly the budget, so the budget is gone within "
                "the 30-day window; the page threshold is 14.4 over 1h (2 %% of the "
                "budget in an hour) and 6 over 6h. A latency-only burn is "
                "saturation, an availability burn is errors."
                % (" and ".join(SLO_BURN_WINDOWS), budget),
                "short",
                targets,
                0, y, w=24, h=7,
            )
            y += 7
        self.y = y

    def logs_row(self):
        # On a platform dashboard the Loki uid has to appear somewhere and every
        # logs panel must keep the variable, so the row carries the pinned uid.
        self.row(ROW_ORDER[2],
                 datasource=PINNED_LOKI if self.is_platform else None)
        self.logs(
            "%s logs" % self.logs_namespace,
            "Every log line the namespace ships to Loki, with toggles for the "
            "error/warn and the startup/ready subsets.",
        )
        self.y += 12

    # -- app-specific panels ------------------------------------------------
    def custom_panels(self, row):
        """The panels the manifest adds to one standard row.

        A namespace dashboard for an app with its own metrics is useless without
        them — Hindsight's consolidation backlog, the whiteboard tunnel — and
        deleting them to fit the standard loses the signal the dashboard existed
        for. They live in the manifest so the generator stays the only writer and
        the panels obey the same datasource, description and unit rules as the
        generated ones.
        """
        extras = [panel for panel in (self.spec.get("panels") or [])
                  if (panel.get("row") or ROW_ORDER[0]) == row]
        if not extras:
            return
        x = 0
        line_height = 0
        y = self.y
        for extra in extras:
            kind = extra.get("type") or "stat"
            if kind not in ("stat", "timeseries"):
                raise ValueError("manifest panel %r has unsupported type %r"
                                 % (extra.get("title"), kind))
            title = extra.get("title")
            description = extra.get("description")
            unit = extra.get("unit")
            if not isinstance(title, str) or not title.strip():
                raise ValueError("manifest panel has no title: %r" % (extra,))
            if not isinstance(description, str) or not description.strip():
                raise ValueError("manifest panel %r has no description" % title)
            if not isinstance(unit, str) or not unit.strip():
                raise ValueError("manifest panel %r has no unit" % title)
            if extra.get("row") not in (None, ROW_ORDER[0], ROW_ORDER[1]):
                raise ValueError("manifest panel %r targets row %r; app panels "
                                 "may join %r or %r only"
                                 % (title, extra.get("row"), ROW_ORDER[0], ROW_ORDER[1]))
            targets = []
            for ref, target in zip("ABCDEFGH", extra.get("targets") or []):
                expr = target.get("expr")
                if not isinstance(expr, str) or not expr.strip():
                    raise ValueError("manifest panel %r has a target without an expr" % title)
                rendered = {"editorMode": "code", "expr": expr, "refId": ref}
                legend = target.get("legend")
                if legend:
                    rendered["legendFormat"] = legend
                if kind == "stat" or target.get("instant"):
                    rendered["instant"] = True
                targets.append(rendered)
            if not targets:
                raise ValueError("manifest panel %r has no targets" % title)
            datasource = (LOKI if extra.get("datasource") == "loki" else PROM)
            if self.is_platform:
                datasource = (PINNED_LOKI if extra.get("datasource") == "loki"
                              else PINNED_PROM)
            thresholds = extra.get("thresholds")
            if kind == "stat":
                width, height = extra.get("w", 8), extra.get("h", 4)
                self.stat(title, description, unit, targets, x, y, w=width, h=height,
                          thresholds=thresholds, datasource=datasource)
            else:
                width, height = extra.get("w", 12), extra.get("h", 7)
                self.timeseries(title, description, unit, targets, x, y,
                                w=width, h=height, min_val=extra.get("min"),
                                max_val=extra.get("max"), thresholds=thresholds,
                                datasource=datasource)
            x += width
            line_height = max(line_height, height)
            if x >= 24:
                x = 0
                y += line_height
                line_height = 0
        if x:
            y += line_height
        self.y = y

    # -- assembly -----------------------------------------------------------
    def overview(self):
        footer = ("\n\nRe-rendered from `scripts/dashboards/manifest.json` — edit the "
                  "manifest or `scripts/render_namespace_dashboard.py`, never this JSON.")
        if self.is_platform:
            return (self.spec.get("overview") or "") + footer
        if not self.spec.get("slo"):
            return ("Standard dashboard for **%s**. Rows follow the homelab order: golden "
                    "signals (saturation, traffic, restarts, errors), then resources "
                    "(per-service requests against limits, storage, node power), then logs."
                    % self.spec["k8sNamespace"]) + footer
        services = ", ".join("%s %s %%" % (slo["label"], slo["target"])
                             for slo in SLO_SERVICES)
        return ("The **SLOs** of the three services that answer a request: %s. Two SLIs "
                "each — availability and latency — recorded as an error ratio for the "
                "seven alerting windows, with one error budget per service (1 - target).\n\n"
                "Rows follow the homelab order: golden signals (the 30-day SLI, the error "
                "budget left, the burn rate), resources (the observability namespace "
                "itself), then logs. The alarms that read these series are in "
                "`infrastructure/observability/slo/slo-prometheus-rules.yaml`; the design "
                "is `docs/adr/adr-135-observability-design.md`."
                % services) + footer

    def platform(self):
        """A dashboard of the platform itself, from the manifest's own panels.

        The same three rows, but the golden signals of a collector or a node are
        not `http_requests_total` and the resources are not one namespace, so
        this row walk lists the workloads the entry names and fills the rest
        from its panels.
        """
        self.row(ROW_ORDER[0])
        self.custom_panels(ROW_ORDER[0])
        self.row(ROW_ORDER[1])
        self.service_stats()
        self.custom_panels(ROW_ORDER[1])
        self.logs_row()

    def render(self):
        spec = self.spec
        self.text("Overview", self.overview(), h=3)
        if self.is_platform:
            self.platform()
        elif spec.get("slo"):
            self.slo_golden_signals()
            self.resources()
            self.logs_row()
        else:
            self.golden_signals()
            self.resources()
            self.logs_row()

        dashboard = {
            "annotations": {"list": []},
            "description": spec.get("description", "Standard homelab dashboard for the %s namespace."
                                                   % spec["k8sNamespace"]),
            "editable": True,
            "fiscalYearStartMonth": 0,
            "graphTooltip": 0,
            "id": None,
            "links": [dict(HOMELAB_LINK)],
            "liveNow": True,
            "panels": self.panels,
            "refresh": "30s",
            "schemaVersion": SCHEMA_VERSION,
            "tags": ["homelab", spec["namespace"]],
            "templating": {"list": template_variables(spec)},
            "time": {"from": "now-6h", "to": "now"},
            "timepicker": {},
            "timezone": "browser",
            "title": spec["title"],
            "uid": spec["uid"],
            "version": 1,
        }
        return dashboard


def template_variables(spec=None):
    variables = [
        {
            "current": {"selected": True, "text": "Prometheus", "value": "Prometheus"},
            "hide": 0,
            "includeAll": False,
            "label": "Prometheus",
            "multi": False,
            "name": "datasource",
            "options": [],
            "query": "prometheus",
            "refresh": 1,
            "regex": "",
            "skipUrlSync": False,
            "type": "datasource",
        },
        {
            "current": {"selected": True, "text": "Loki", "value": "Loki"},
            "hide": 0,
            "includeAll": False,
            "label": "Loki",
            "multi": False,
            "name": "loki",
            "options": [],
            "query": "loki",
            "refresh": 1,
            "regex": "",
            "skipUrlSync": False,
            "type": "datasource",
        },
    ]
    # A dashboard may need one more variable (Hindsight filters every query by
    # `tenant`). The manifest carries it as a ready Grafana variable object, so
    # the generator does not grow a variable language of its own.
    for extra in (spec or {}).get("variables") or []:
        if not isinstance(extra, dict) or not isinstance(extra.get("name"), str):
            raise ValueError("manifest variable is not an object with a name: %r" % (extra,))
        variables.append(dict(extra))
    return variables


# ---------------------------------------------------------------------------
# manifest
# ---------------------------------------------------------------------------
def load_manifest(path):
    with open(path, encoding="utf-8") as handle:
        raw = json.load(handle)
    entries = raw.get("dashboards") if isinstance(raw, dict) else raw
    if not isinstance(entries, list) or not entries:
        raise ValueError("%s carries no dashboards list" % path)
    return entries


def normalise(path):
    path = path.strip()
    while path.startswith("./"):
        path = path[2:]
    return os.path.normpath(path).replace(os.sep, "/")


def entry_output(entry):
    for key in ("output", "path", "file"):
        value = entry.get(key)
        if isinstance(value, str) and value:
            return value
    raise ValueError("manifest entry has no output path: %r" % (entry,))


def entry_identity(entry):
    """The dashboard identity: (namespace, configmap name, folder)."""
    namespace = entry.get("namespace") or entry.get("ns")
    if not namespace:
        path = normalise(entry_output(entry))
        if path.startswith("apps/"):
            namespace = path.split("/")[1]
        elif path.startswith("infrastructure/auth/"):
            namespace = "auth"
        else:
            raise ValueError("manifest entry %r names no namespace" % path)
    return (
        namespace,
        entry.get("configmapName") or "%s-dashboard" % namespace,
        entry.get("folder") or namespace,
    )


def entry_dashboards(entry, namespace):
    """The dashboard specs one entry renders (a ConfigMap may hold several).

    A single-dashboard entry carries its title/uid/services at the top level; a
    multi-dashboard entry (hindsight ships three) carries a `dashboards` list and
    the entry-level fields act as defaults.
    """
    defaults = {key: value for key, value in entry.items() if key != "dashboards"}
    listed = entry.get("dashboards", [entry])
    if not isinstance(listed, list) or not listed:
        raise ValueError("manifest entry %r lists no dashboards" % (entry,))
    specs = []
    for item in listed:
        if not isinstance(item, dict):
            raise ValueError("manifest dashboard %r is not an object" % (item,))
        merged = dict(defaults)
        merged.update(item)
        merged["namespace"] = namespace
        merged["k8sNamespace"] = merged.get("k8sNamespace") or namespace
        merged["title"] = merged.get("title") or "%s — %s" % (namespace, namespace)
        merged["uid"] = merged.get("uid") or "%s-dashboard" % namespace
        merged["key"] = merged.get("key") or "%s-dashboard.json" % namespace
        merged["services"] = merged.get("services") or []
        specs.append(merged)
    return specs


def build_configmap(entry):
    namespace, name, folder = entry_identity(entry)
    data = {}
    for spec in entry_dashboards(entry, namespace):
        data[spec["key"]] = json.dumps(Dashboard(spec).render(), separators=(",", ":"))
    return {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": name,
            "namespace": "observability",
            "labels": {"grafana_dashboard": "1"},
            "annotations": {"grafana.folder": folder},
        },
        "data": data,
    }


def render_all(manifest_path, output_dir):
    entries = load_manifest(manifest_path)
    written = []
    for entry in entries:
        relative = normalise(entry_output(entry))
        document = json.dumps(build_configmap(entry), indent=2, separators=(",", ": ")) + "\n"
        target = os.path.join(output_dir, relative) if output_dir else relative
        parent = os.path.dirname(target)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(document)
        written.append(relative)
    return written


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Render every homelab Grafana dashboard ConfigMap from one manifest")
    parser.add_argument("--manifest", default=MANIFEST_DEFAULT,
                        help="dashboard manifest (default %s)" % MANIFEST_DEFAULT)
    parser.add_argument("--output-dir", default=None,
                        help="write the files below this directory instead of the repo root")
    parser.add_argument("--list", action="store_true", help="print the manifest outputs and exit")
    args = parser.parse_args(argv)

    try:
        if args.list:
            for entry in load_manifest(args.manifest):
                print(normalise(entry_output(entry)))
            return 0
        written = render_all(args.manifest, args.output_dir)
    except (OSError, ValueError) as exc:
        sys.stderr.write("render_namespace_dashboard: %s\n" % exc)
        return 1
    sys.stderr.write("render_namespace_dashboard: rendered %d dashboard ConfigMaps\n" % len(written))
    return 0


if __name__ == "__main__":
    sys.exit(main())
