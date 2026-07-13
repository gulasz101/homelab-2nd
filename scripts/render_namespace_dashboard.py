#!/usr/bin/env python3
"""
Generate a provisioned Grafana dashboard ConfigMap for a homelab service namespace.

Output is a Kubernetes ConfigMap JSON with the dashboard under .data.<name>.json,
suitable for Flux + the Grafana sidecar (label grafana_dashboard: "1").

Examples:

    # gpu-embedding (single GPU service)
    python3 scripts/render_namespace_dashboard.py \
        --namespace gpu-embedding \
        --title "gpu-embedding — Ollama Embedding Service" \
        --uid gpu-embedding-ollama \
        --with-gpu \
        --services ollama-embeddings \
        --pvcs "ollama-embeddings:ollama-models" \
        > apps/gpu-embedding/gpu-embedding-dashboard-configmap.yaml

    # honcho (multi-service, no GPU)
    python3 scripts/render_namespace_dashboard.py \
        --namespace honcho \
        --title "honcho — Memory & Dialectic" \
        --uid honcho-overview \
        --services honcho-api,honcho-deriver,honcho-db,honcho-redis \
        --pvcs "honcho-db:honcho-db-1,honcho-redis:redis-data" \
        > apps/honcho/honcho-dashboard-configmap.yaml
"""

import argparse
import json
import sys
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

PROM_UID = "PBFA97CFB590B2093"
LOKI_UID = "P8E80F9AEF21F6940"


@dataclass
class Panel:
    panel_id: int
    title: str
    panel_type: str = "timeseries"
    datasource: Optional[dict] = None
    targets: List[dict] = field(default_factory=list)
    field_config: dict = field(default_factory=dict)
    options: dict = field(default_factory=dict)
    grid_pos: dict = field(default_factory=lambda: {"h": 7, "w": 12, "x": 0, "y": 0})

    def to_dict(self) -> dict:
        panel = {
            "id": self.panel_id,
            "title": self.title,
            "type": self.panel_type,
            "datasource": self.datasource,
            "targets": self.targets,
            "fieldConfig": self.field_config,
            "options": self.options,
            "gridPos": self.grid_pos,
        }
        # Row and text panels don't need the timeseries-only structures.
        if self.panel_type in ("row", "text"):
            panel.pop("targets", None)
            panel.pop("fieldConfig", None)
        if self.panel_type == "row":
            panel.pop("options", None)
        return panel


def prom_ds() -> dict:
    return {"type": "prometheus", "uid": PROM_UID}


def loki_ds() -> dict:
    return {"type": "loki", "uid": LOKI_UID}


def timeseries_defaults(
    unit: str,
    min_val: Optional[float] = 0,
    max_val: Optional[float] = None,
    thresholds: Optional[List[Tuple[Optional[float], str]]] = None,
) -> dict:
    """Build fieldConfig.defaults for a timeseries panel."""
    defaults: dict[str, Any] = {
        "unit": unit,
        "custom": {
            "drawStyle": "line",
            "lineInterpolation": "linear",
            "barAlignment": 0,
            "lineWidth": 1,
            "fillOpacity": 20,
            "gradientMode": "opacity",
            "spanNulls": False,
            "insertNulls": False,
            "showPoints": "never",
            "pointSize": 5,
            "stacking": {"mode": "none", "group": "A"},
            "axisPlacement": "auto",
            "axisLabel": "",
            "axisColorMode": "text",
            "scaleDistribution": {"type": "linear"},
            "axisCenteredZero": False,
            "hideFrom": {"tooltip": False, "viz": False, "legend": False},
            "thresholdsStyle": {"mode": "off"},
        },
    }
    if min_val is not None:
        defaults["min"] = min_val
    if max_val is not None:
        defaults["max"] = max_val
    if thresholds:
        defaults["thresholds"] = {
            "mode": "absolute",
            "steps": [
                {"color": color, "value": value}
                for value, color in thresholds
            ],
        }
    return defaults


def stat_panel_defaults(unit: str) -> dict:
    """Defaults for a stat panel showing current value."""
    return {
        "unit": unit,
        "custom": {},
        "min": None,
        "max": None,
        "thresholds": {
            "mode": "absolute",
            "steps": [
                {"color": "green", "value": None},
                {"color": "yellow", "value": 80},
                {"color": "red", "value": 90},
            ],
        },
    }


def timeseries_options() -> dict:
    return {
        "legend": {
            "displayMode": "table",
            "placement": "right",
            "calcs": ["lastNotNull", "max"],
        },
        "tooltip": {"mode": "multi", "sort": "none"},
    }


def stat_options() -> dict:
    return {
        "graphMode": "area",
        "colorMode": "value",
        "justifyMode": "auto",
        "orientation": "auto",
        "textMode": "auto",
    }


def row_panel(panel_id: int, title: str, y: int, datasource: Optional[dict] = None) -> Panel:
    return Panel(
        panel_id=panel_id,
        title=title,
        panel_type="row",
        datasource=datasource or prom_ds(),
        grid_pos={"h": 1, "w": 24, "x": 0, "y": y},
    )


def text_panel(panel_id: int, title: str, content: str, y: int, h: int = 2) -> Panel:
    return Panel(
        panel_id=panel_id,
        title=title,
        panel_type="text",
        datasource=prom_ds(),
        grid_pos={"h": h, "w": 24, "x": 0, "y": y},
        options={"mode": "markdown", "content": content},
    )


def friendly_name(pod_prefix: str, aliases: Optional[Dict[str, str]] = None) -> str:
    """Return a human-friendly service label from a pod prefix.

    Explicit aliases (service prefix -> display label) win. Otherwise strip a
    leading namespace segment if present, else fall back to the last segment.

    Examples:
        'honcho-api' -> 'api'
        'mattermost-mattermost-team-edition' -> 'mattermost' (last segment is confusing)
        'cloudflared-chat' with alias -> 'tunnel'
    """
    if aliases and pod_prefix in aliases:
        return aliases[pod_prefix]
    # Strip leading namespace if present (namespace-service-...)
    # e.g. 'mattermost-mattermost-team-edition' has segments ['mattermost', 'mattermost', 'team', 'edition']
    # We can't always auto-detect, so if the prefix contains the namespace twice, prefer
    # the part after the first namespace segment.
    segments = pod_prefix.split("-")
    # Heuristic: if first segment looks like a namespace and the rest starts with a known service word,
    # use the last meaningful segment minus trailing common noise.
    label = segments[-1]
    # Remove common trailing noise from deployment names.
    for noise in ("team", "edition", "deployment", "service"):
        if label.lower() == noise and len(segments) > 1:
            label = segments[-2]
    return label


def service_cpu_stat(
    namespace: str, pod_prefix: str, panel_id: int, x: int, y: int, aliases: Optional[Dict[str, str]] = None
) -> Panel:
    """CPU usage / request / limit stat panel for a single service."""
    label = friendly_name(pod_prefix, aliases)
    return Panel(
        panel_id=panel_id,
        title=f"{label} CPU",
        panel_type="stat",
        datasource=prom_ds(),
        targets=[
            {
                "refId": "A",
                "expr": f'sum(rate(container_cpu_usage_seconds_total{{namespace="{namespace}",pod=~"{pod_prefix}.*",container!=""}}[5m]))',
                "legendFormat": "usage",
                "instant": True,
            },
            {
                "refId": "B",
                "expr": f'sum(kube_pod_container_resource_requests{{namespace="{namespace}",pod=~"{pod_prefix}.*",resource="cpu",container!=""}})',
                "legendFormat": "request",
                "instant": True,
            },
            {
                "refId": "C",
                "expr": f'sum(kube_pod_container_resource_limits{{namespace="{namespace}",pod=~"{pod_prefix}.*",resource="cpu",container!=""}})',
                "legendFormat": "limit",
                "instant": True,
            },
        ],
        field_config={"defaults": stat_panel_defaults("cores"), "overrides": []},
        options=stat_options(),
        grid_pos={"h": 4, "w": 8, "x": x, "y": y},
    )


def service_memory_stat(
    namespace: str, pod_prefix: str, panel_id: int, x: int, y: int, aliases: Optional[Dict[str, str]] = None
) -> Panel:
    """Memory usage / request / limit stat panel for a single service."""
    label = friendly_name(pod_prefix, aliases)
    return Panel(
        panel_id=panel_id,
        title=f"{label} memory",
        panel_type="stat",
        datasource=prom_ds(),
        targets=[
            {
                "refId": "A",
                "expr": f'sum(container_memory_working_set_bytes{{namespace="{namespace}",pod=~"{pod_prefix}.*",container!=""}})',
                "legendFormat": "usage",
                "instant": True,
            },
            {
                "refId": "B",
                "expr": f'sum(kube_pod_container_resource_requests{{namespace="{namespace}",pod=~"{pod_prefix}.*",resource="memory",container!=""}})',
                "legendFormat": "request",
                "instant": True,
            },
            {
                "refId": "C",
                "expr": f'sum(kube_pod_container_resource_limits{{namespace="{namespace}",pod=~"{pod_prefix}.*",resource="memory",container!=""}})',
                "legendFormat": "limit",
                "instant": True,
            },
        ],
        field_config={"defaults": stat_panel_defaults("bytes"), "overrides": []},
        options=stat_options(),
        grid_pos={"h": 4, "w": 8, "x": x, "y": y},
    )


def service_pvc_stat(
    namespace: str, pod_prefix: str, pvc_name: str, panel_id: int, x: int, y: int, aliases: Optional[Dict[str, str]] = None
) -> Panel:
    """PVC used / capacity stat panel for a single service."""
    label = friendly_name(pod_prefix, aliases)
    return Panel(
        panel_id=panel_id,
        title=f"{label} PVC",
        panel_type="stat",
        datasource=prom_ds(),
        targets=[
            {
                "refId": "A",
                "expr": f'kubelet_volume_stats_used_bytes{{namespace="{namespace}",persistentvolumeclaim="{pvc_name}"}}',
                "legendFormat": "used",
                "instant": True,
            },
            {
                "refId": "B",
                "expr": f'kubelet_volume_stats_capacity_bytes{{namespace="{namespace}",persistentvolumeclaim="{pvc_name}"}}',
                "legendFormat": "capacity",
                "instant": True,
            },
        ],
        field_config={"defaults": stat_panel_defaults("bytes"), "overrides": []},
        options=stat_options(),
        grid_pos={"h": 4, "w": 8, "x": x, "y": y},
    )


def per_service_row(
    namespace: str,
    services: List[str],
    pvcs: Dict[str, str],
    start_y: int,
    start_id: int,
    aliases: Optional[Dict[str, str]] = None,
) -> Tuple[List[Panel], int]:
    """Return panels and the next free panel id. Layout: one row per service."""
    panels: List[Panel] = []
    y = start_y
    next_id = start_id

    panels.append(row_panel(next_id, "Per-service resources", y, datasource=prom_ds()))
    next_id += 1
    y += 1

    for pod_prefix in services:
        has_pvc = pod_prefix in pvcs
        # If the service has a PVC we use three 8-wide stat panels in one row.
        # Otherwise CPU + memory share the row (two 8-wide panels, 8 unused).
        panels.append(service_cpu_stat(namespace, pod_prefix, next_id, 0, y, aliases))
        next_id += 1
        panels.append(service_memory_stat(namespace, pod_prefix, next_id, 8, y, aliases))
        next_id += 1
        if has_pvc:
            panels.append(service_pvc_stat(namespace, pod_prefix, pvcs[pod_prefix], next_id, 16, y, aliases))
            next_id += 1
        y += 4

    return panels, next_id


def cpu_panels(namespace: str, start_y: int, first_id: int = 1) -> Tuple[List[Panel], int]:
    y = start_y
    panels = [
        row_panel(first_id, "CPU", y),
        Panel(
            panel_id=first_id + 1,
            title="CPU usage vs request vs limit per pod",
            datasource=prom_ds(),
            targets=[
                {
                    "refId": "A",
                    "expr": f'sum by (pod, container) (rate(container_cpu_usage_seconds_total{{namespace="{namespace}",container!=""}}[5m]))',
                    "legendFormat": "{{pod}}/{{container}} usage",
                },
                {
                    "refId": "B",
                    "expr": f'sum by (pod, container) (container_spec_cpu_quota{{namespace="{namespace}",container!=""}} / container_spec_cpu_period{{namespace="{namespace}",container!=""}})',
                    "legendFormat": "{{pod}}/{{container}} limit",
                },
                {
                    "refId": "C",
                    "expr": f'sum by (pod, container) (kube_pod_container_resource_requests{{namespace="{namespace}",resource="cpu",container!=""}})',
                    "legendFormat": "{{pod}}/{{container}} request",
                },
            ],
            field_config={"defaults": timeseries_defaults("cores"), "overrides": []},
            options=timeseries_options(),
            grid_pos={"h": 8, "w": 24, "x": 0, "y": y + 1},
        ),
        Panel(
            panel_id=first_id + 2,
            title="CPU utilisation % of limit per container",
            datasource=prom_ds(),
            targets=[
                {
                    "refId": "A",
                    "expr": f'100 * sum by (pod, container) (rate(container_cpu_usage_seconds_total{{namespace="{namespace}",container!=""}}[5m])) / sum by (pod, container) (container_spec_cpu_quota{{namespace="{namespace}",container!=""}} / container_spec_cpu_period{{namespace="{namespace}",container!=""}})',
                    "legendFormat": "{{pod}}/{{container}}",
                },
            ],
            field_config={
                "defaults": timeseries_defaults(
                    "percent",
                    max_val=100,
                    thresholds=[
                        (None, "green"),
                        (80, "yellow"),
                        (90, "red"),
                    ],
                ),
                "overrides": [],
            },
            options=timeseries_options(),
            grid_pos={"h": 7, "w": 12, "x": 0, "y": y + 9},
        ),
    ]
    return panels, first_id + 3


def memory_panels(namespace: str, start_y: int, first_id: int = 4) -> Tuple[List[Panel], int]:
    y = start_y
    panels = [
        row_panel(first_id, "Memory", y),
        Panel(
            panel_id=first_id + 1,
            title="Memory usage vs request vs limit per pod",
            datasource=prom_ds(),
            targets=[
                {
                    "refId": "A",
                    "expr": f'sum by (pod, container) (container_memory_working_set_bytes{{namespace="{namespace}",container!=""}})',
                    "legendFormat": "{{pod}}/{{container}} usage",
                },
                {
                    "refId": "B",
                    "expr": f'sum by (pod, container) (kube_pod_container_resource_limits{{namespace="{namespace}",resource="memory",container!=""}})',
                    "legendFormat": "{{pod}}/{{container}} limit",
                },
                {
                    "refId": "C",
                    "expr": f'sum by (pod, container) (kube_pod_container_resource_requests{{namespace="{namespace}",resource="memory",container!=""}})',
                    "legendFormat": "{{pod}}/{{container}} request",
                },
            ],
            field_config={"defaults": timeseries_defaults("bytes"), "overrides": []},
            options=timeseries_options(),
            grid_pos={"h": 8, "w": 24, "x": 0, "y": y + 1},
        ),
        Panel(
            panel_id=first_id + 2,
            title="Memory utilisation % of limit per container",
            datasource=prom_ds(),
            targets=[
                {
                    "refId": "A",
                    "expr": f'100 * sum by (pod, container) (container_memory_working_set_bytes{{namespace="{namespace}",container!=""}}) / sum by (pod, container) (kube_pod_container_resource_limits{{namespace="{namespace}",resource="memory",container!=""}})',
                    "legendFormat": "{{pod}}/{{container}}",
                },
            ],
            field_config={
                "defaults": timeseries_defaults(
                    "percent",
                    max_val=100,
                    thresholds=[
                        (None, "green"),
                        (80, "yellow"),
                        (90, "red"),
                    ],
                ),
                "overrides": [],
            },
            options=timeseries_options(),
            grid_pos={"h": 7, "w": 12, "x": 0, "y": y + 9},
        ),
    ]
    return panels, first_id + 3


def disk_panels(namespace: str, start_y: int, first_id: int = 7) -> Tuple[List[Panel], int]:
    y = start_y
    threshold_steps = [
        (None, "green"),
        (75, "yellow"),
        (90, "red"),
    ]
    panels = [
        row_panel(first_id, "Disk / PVC", y),
        Panel(
            panel_id=first_id + 1,
            title=f"PVC utilisation ({namespace})",
            datasource=prom_ds(),
            targets=[
                {
                    "refId": "A",
                    "expr": f'100 * kubelet_volume_stats_used_bytes{{namespace="{namespace}"}} / kubelet_volume_stats_capacity_bytes{{namespace="{namespace}"}}',
                    "legendFormat": "{{persistentvolumeclaim}}",
                },
            ],
            field_config={
                "defaults": timeseries_defaults("percent", max_val=100, thresholds=threshold_steps),
                "overrides": [],
            },
            options=timeseries_options(),
            grid_pos={"h": 7, "w": 12, "x": 0, "y": y + 1},
        ),
        Panel(
            panel_id=first_id + 2,
            title="Node disk utilisation (homelab-2nd)",
            datasource=prom_ds(),
            targets=[
                {
                    "refId": "A",
                    "expr": '100 - ((node_filesystem_avail_bytes{host="homelab-2nd",fstype!="tmpfs",fstype!="overlay"} * 100) / node_filesystem_size_bytes{host="homelab-2nd",fstype!="tmpfs",fstype!="overlay"})',
                    "legendFormat": "{{mountpoint}}",
                },
            ],
            field_config={
                "defaults": timeseries_defaults("percent", max_val=100, thresholds=threshold_steps),
                "overrides": [],
            },
            options=timeseries_options(),
            grid_pos={"h": 7, "w": 12, "x": 12, "y": y + 1},
        ),
    ]
    return panels, first_id + 3


def gpu_panels(start_y: int, first_id: int = 10) -> Tuple[List[Panel], int]:
    y = start_y
    threshold_steps = [
        (None, "green"),
        (75, "yellow"),
        (90, "red"),
    ]
    panels = [
        row_panel(first_id, "GPU (single-GPU node)", y),
        Panel(
            panel_id=first_id + 1,
            title="GPU utilization %",
            datasource=prom_ds(),
            targets=[
                {
                    "refId": "A",
                    "expr": "nvidia_smi_utilization_gpu_ratio * 100",
                    "legendFormat": "{{name}}",
                },
            ],
            field_config={
                "defaults": timeseries_defaults("percent", max_val=100, thresholds=threshold_steps),
                "overrides": [],
            },
            options=timeseries_options(),
            grid_pos={"h": 7, "w": 8, "x": 0, "y": y + 1},
        ),
        Panel(
            panel_id=first_id + 2,
            title="GPU memory used",
            datasource=prom_ds(),
            targets=[
                {
                    "refId": "A",
                    "expr": "nvidia_smi_memory_used_bytes",
                    "legendFormat": "{{name}} used",
                },
                {
                    "refId": "B",
                    "expr": "nvidia_smi_memory_total_bytes",
                    "legendFormat": "{{name}} total",
                },
            ],
            field_config={"defaults": timeseries_defaults("bytes"), "overrides": []},
            options=timeseries_options(),
            grid_pos={"h": 7, "w": 8, "x": 8, "y": y + 1},
        ),
        Panel(
            panel_id=first_id + 3,
            title="GPU temperature & power draw",
            datasource=prom_ds(),
            targets=[
                {
                    "refId": "A",
                    "expr": "nvidia_smi_temperature_gpu",
                    "legendFormat": "{{name}} temp °C",
                },
                {
                    "refId": "B",
                    "expr": "nvidia_smi_power_draw_watts",
                    "legendFormat": "{{name}} power W",
                },
            ],
            field_config={
                "defaults": timeseries_defaults("celsius", min_val=0),
                "overrides": [
                    {
                        "matcher": {"id": "byName", "options": "/.*power W/"},
                        "properties": [
                            {
                                "id": "unit",
                                "value": "watt",
                            },
                            {
                                "id": "custom.axisPlacement",
                                "value": "right",
                            },
                        ],
                    },
                ],
            },
            options=timeseries_options(),
            grid_pos={"h": 7, "w": 8, "x": 16, "y": y + 1},
        ),
    ]
    return panels, first_id + 4


def logs_panel(namespace: str, start_y: int, first_id: int = 14) -> Tuple[List[Panel], int]:
    y = start_y
    base_expr = f'{{k8s_namespace_name="{namespace}"}}'
    panels = [
        row_panel(first_id, "Logs", y, datasource=loki_ds()),
        Panel(
            panel_id=first_id + 1,
            title=f"{namespace} logs",
            panel_type="logs",
            datasource=loki_ds(),
            targets=[
                {
                    "refId": "A",
                    "expr": base_expr,
                    "editorMode": "builder",
                    "queryType": "range",
                    "legendFormat": "",
                },
                {
                    "refId": "B",
                    "expr": f'{base_expr} |=~ "(?i)error|warn|fatal|panic"',
                    "editorMode": "builder",
                    "queryType": "range",
                    "legendFormat": "",
                    "hide": False,
                },
                {
                    "refId": "C",
                    "expr": f'{base_expr} |~ "\\[GIN\\].*\\|\\s+(?:[3-9]\\d{{2}}|[1-9]\\d{{3}})\\s+\\|"',
                    "editorMode": "code",
                    "queryType": "range",
                    "legendFormat": "",
                    "hide": True,
                },
                {
                    "refId": "D",
                    "expr": f'{base_expr} |=~ "(?i)pulling|loading model|load model"',
                    "editorMode": "builder",
                    "queryType": "range",
                    "legendFormat": "",
                    "hide": True,
                },
                {
                    "refId": "E",
                    "expr": f'{base_expr} |=~ "(?i)cuda|nvidia|gpu"',
                    "editorMode": "builder",
                    "queryType": "range",
                    "legendFormat": "",
                    "hide": True,
                },
            ],
            options={
                "showTime": True,
                "showLabels": True,
                "showCommonLabels": True,
                "showLogContextToggle": True,
                "wrapLogMessage": True,
                "prettifyLogMessage": True,
                "sortOrder": "Descending",
                "enableLogDetails": True,
                "dedupStrategy": "none",
                "showControls": True,
                "showFieldSelector": True,
                "syntaxHighlighting": True,
            },
            grid_pos={"h": 12, "w": 24, "x": 0, "y": y + 1},
        ),
    ]
    return panels, first_id + 2


def build_dashboard(
    namespace: str,
    title: str,
    uid: str,
    with_gpu: bool = False,
    services: Optional[List[str]] = None,
    pvcs: Optional[Dict[str, str]] = None,
    aliases: Optional[Dict[str, str]] = None,
) -> dict:
    panels: List[Panel] = []
    y = 0
    next_id = 1000

    panels.append(
        text_panel(
            next_id,
            "Overview",
            f"""Per-namespace dashboard for **{namespace}**.

CPU and memory panels show usage alongside Kubernetes requests and limits with human-readable units (cores, bytes, percent).
Logs panel ships multiple pre-built LogQL filters — toggle them on/off from the query row above the panel.
{f"GPU metrics are included because this namespace runs GPU workloads; the full GPU dashboard is in the **Homelab** folder." if with_gpu else ""}""",
            y,
            h=2,
        )
    )
    next_id += 1
    y += 2

    if services:
        service_panels, next_id = per_service_row(
            namespace, services, pvcs or {}, y, next_id, aliases
        )
        panels.extend(service_panels)
        y += 1 + len(services) * 4  # row(1) + 4 per service

    cpu_ps, next_id = cpu_panels(namespace, y, next_id)
    panels.extend(cpu_ps)
    y += 16  # row(1) + cpu usage(8) + cpu util(7)

    mem_ps, next_id = memory_panels(namespace, y, next_id)
    panels.extend(mem_ps)
    y += 16

    disk_ps, next_id = disk_panels(namespace, y, next_id)
    panels.extend(disk_ps)
    y += 8

    if with_gpu:
        gpu_ps, next_id = gpu_panels(y, next_id)
        panels.extend(gpu_ps)
        y += 8

    log_ps, next_id = logs_panel(namespace, y, next_id)
    panels.extend(log_ps)

    return {
        "annotations": {"list": []},
        "editable": True,
        "fiscalYearStartMonth": 0,
        "graphTooltip": 0,
        "id": None,
        "links": [],
        "liveNow": True,
        "panels": [p.to_dict() for p in panels],
        "refresh": "30s",
        "schemaVersion": 39,
        "tags": ["homelab", namespace],
        "templating": {"list": []},
        "time": {"from": "now-30m", "to": "now"},
        "timepicker": {},
        "timezone": "browser",
        "title": title,
        "uid": uid,
        "version": 1,
    }


def build_configmap(
    namespace: str,
    title: str,
    uid: str,
    with_gpu: bool = False,
    services: Optional[List[str]] = None,
    pvcs: Optional[Dict[str, str]] = None,
    aliases: Optional[Dict[str, str]] = None,
) -> dict:
    dashboard = build_dashboard(namespace, title, uid, with_gpu, services, pvcs, aliases)
    filename = f"{namespace}-dashboard.json"
    return {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": f"{namespace}-dashboard",
            "namespace": "observability",
            "labels": {"grafana_dashboard": "1"},
            "annotations": {"grafana.folder": namespace},
        },
        "data": {filename: json.dumps(dashboard, separators=(",", ":"))},
    }


def parse_pvc_map(raw: Optional[str]) -> Dict[str, str]:
    if not raw:
        return {}
    result: Dict[str, str] = {}
    for pair in raw.split(","):
        if ":" not in pair:
            continue
        service, pvc = pair.split(":", 1)
        result[service.strip()] = pvc.strip()
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Render a namespace observability dashboard ConfigMap")
    parser.add_argument("--namespace", required=True, help="Kubernetes namespace to monitor")
    parser.add_argument("--title", required=True, help="Dashboard title")
    parser.add_argument("--uid", required=True, help="Dashboard UID")
    parser.add_argument("--with-gpu", action="store_true", help="Include GPU metric panels")
    parser.add_argument(
        "--services",
        type=lambda s: [x.strip() for x in s.split(",") if x.strip()],
        default=None,
        help="Comma-separated pod prefixes to render per-service stat panels (e.g. honcho-api,honcho-deriver,honcho-db,honcho-redis)",
    )
    parser.add_argument(
        "--pvcs",
        type=parse_pvc_map,
        default={},
        help='Service:pvc mappings for per-service PVC stat panels, e.g. "honcho-db:honcho-db-1,honcho-redis:redis-data"',
    )
    parser.add_argument(
        "--aliases",
        type=lambda s: dict(part.split(":", 1) for part in s.split(",") if ":" in part),
        default={},
        help='Display aliases for service labels, e.g. "mattermost-mattermost-team-edition:mattermost,cloudflared-chat:tunnel"',
    )
    parser.add_argument("--indent", type=int, default=None, help="Pretty-print JSON with this indent (default compact)")
    args = parser.parse_args()

    cm = build_configmap(args.namespace, args.title, args.uid, args.with_gpu, args.services, args.pvcs, args.aliases)
    if args.indent is not None:
        print(json.dumps(cm, indent=args.indent))
    else:
        print(json.dumps(cm, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
