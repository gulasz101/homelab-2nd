#!/usr/bin/env python3
"""
Generate a provisioned Grafana dashboard ConfigMap for a homelab service namespace.

Output is a Kubernetes ConfigMap JSON with the dashboard under .data.<name>.json,
suitable for Flux + the Grafana sidecar (label grafana_dashboard: "1").

Example:
    python3 scripts/render_namespace_dashboard.py \
        --namespace gpu-embedding \
        --title "gpu-embedding — Ollama Embedding Service" \
        --uid gpu-embedding-ollama \
        --with-gpu \
        > apps/gpu-embedding/gpu-embedding-dashboard-configmap.yaml
"""

import argparse
import json
import sys
from dataclasses import dataclass, field
from typing import Any, List, Optional, Tuple, Union

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


def timeseries_options() -> dict:
    return {
        "legend": {
            "displayMode": "table",
            "placement": "right",
            "calcs": ["lastNotNull", "max"],
        },
        "tooltip": {"mode": "multi", "sort": "none"},
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


def cpu_panels(namespace: str, start_y: int) -> List[Panel]:
    y = start_y
    return [
        row_panel(1, "CPU", y),
        Panel(
            panel_id=2,
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
            panel_id=3,
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


def memory_panels(namespace: str, start_y: int) -> List[Panel]:
    y = start_y
    return [
        row_panel(4, "Memory", y),
        Panel(
            panel_id=5,
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
            panel_id=6,
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


def disk_panels(namespace: str, start_y: int) -> List[Panel]:
    y = start_y
    threshold_steps = [
        (None, "green"),
        (75, "yellow"),
        (90, "red"),
    ]
    return [
        row_panel(7, "Disk / PVC", y),
        Panel(
            panel_id=8,
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
            panel_id=9,
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


def gpu_panels(start_y: int) -> List[Panel]:
    y = start_y
    threshold_steps = [
        (None, "green"),
        (75, "yellow"),
        (90, "red"),
    ]
    return [
        row_panel(10, "GPU (single-GPU node)", y),
        Panel(
            panel_id=11,
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
            panel_id=12,
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
            panel_id=13,
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


def logs_panel(namespace: str, start_y: int) -> List[Panel]:
    y = start_y
    base_expr = f'{{k8s_namespace_name="{namespace}"}}'
    return [
        row_panel(14, "Logs", y, datasource=loki_ds()),
        Panel(
            panel_id=15,
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
                "wrapLogMessage": True,
                "sortOrder": "Descending",
                "enableLogDetails": True,
            },
            grid_pos={"h": 12, "w": 24, "x": 0, "y": y + 1},
        ),
    ]


def build_dashboard(
    namespace: str,
    title: str,
    uid: str,
    with_gpu: bool = False,
) -> dict:
    panels: List[Panel] = []
    y = 0

    panels.append(
        text_panel(
            0,
            "Overview",
            f"""Per-namespace dashboard for **{namespace}**.

CPU and memory panels show usage alongside Kubernetes requests and limits with human-readable units (cores, bytes, percent).
Logs panel ships multiple pre-built LogQL filters — toggle them on/off from the query row above the panel.
{f"GPU metrics are included because this namespace runs GPU workloads; the full GPU dashboard is in the **Homelab** folder." if with_gpu else ""}""",
            y,
            h=2,
        )
    )
    y += 2

    panels.extend(cpu_panels(namespace, y))
    y += 16  # row(1) + cpu usage(8) + cpu util(7)

    panels.extend(memory_panels(namespace, y))
    y += 16

    panels.extend(disk_panels(namespace, y))
    y += 8

    if with_gpu:
        panels.extend(gpu_panels(y))
        y += 8

    panels.extend(logs_panel(namespace, y))

    dashboard = {
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
    return dashboard


def build_configmap(
    namespace: str,
    title: str,
    uid: str,
    with_gpu: bool = False,
) -> dict:
    dashboard = build_dashboard(namespace, title, uid, with_gpu)
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


def main() -> int:
    parser = argparse.ArgumentParser(description="Render a namespace observability dashboard ConfigMap")
    parser.add_argument("--namespace", required=True, help="Kubernetes namespace to monitor")
    parser.add_argument("--title", required=True, help="Dashboard title")
    parser.add_argument("--uid", required=True, help="Dashboard UID")
    parser.add_argument("--with-gpu", action="store_true", help="Include GPU metric panels")
    parser.add_argument("--indent", type=int, default=None, help="Pretty-print JSON with this indent (default compact)")
    args = parser.parse_args()

    cm = build_configmap(args.namespace, args.title, args.uid, args.with_gpu)
    if args.indent is not None:
        print(json.dumps(cm, indent=args.indent))
    else:
        print(json.dumps(cm, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
