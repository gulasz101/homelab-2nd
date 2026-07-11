#!/usr/bin/env python3
"""Render a provisioned Grafana dashboard ConfigMap for a namespace.

Usage:
    python3 render_namespace_dashboard.py <namespace> <uid> <title> > <namespace>-dashboard-configmap.yaml

The dashboard is provisioned to Grafana via the sidecar in the observability
namespace. It expects Prometheus datasource uid "PBFA97CFB590B2093" and Loki
datasource uid "P8E80F9AEF21F6940" (provisioned by our LGTM stack).

Panels:
  - CPU usage vs request vs limit (unit: cores)
  - CPU utilisation % of limit
  - Memory usage vs request vs limit (unit: bytes, Grafana auto MB/GB)
  - Memory utilisation % of limit
  - PVC utilisation % (namespace-scoped)
  - Node disk utilisation % (homelab-2nd)
  - Logs panel (uses k8s_namespace_name label)
"""
import json
import sys

if len(sys.argv) != 4:
    print("usage: python3 render_namespace_dashboard.py <namespace> <uid> <title>", file=sys.stderr)
    sys.exit(1)

NAMESPACE = sys.argv[1]
UID = sys.argv[2]
TITLE = sys.argv[3]

PROM_DS = {"type": "prometheus", "uid": "PBFA97CFB590B2093"}
LOKI_DS = {"type": "loki", "uid": "P8E80F9AEF21F6940"}


def ts_panel(panel_id, title, targets, unit, grid_pos, thresholds=None, min_val=0, max_val=None):
    cfg = {
        "type": "timeseries",
        "id": panel_id,
        "title": title,
        "datasource": PROM_DS,
        "targets": targets,
        "fieldConfig": {
            "defaults": {
                "custom": {
                    "drawStyle": "line",
                    "lineInterpolation": "linear",
                    "pointSize": 5,
                    "showPoints": "auto",
                    "spanNulls": False,
                    "stacking": {"mode": "none", "group": "A"},
                    "axisPlacement": "auto",
                    "axisLabel": "",
                    "unit": unit,
                },
                "min": min_val,
            },
            "overrides": [],
        },
        "options": {
            "legend": {"displayMode": "table", "placement": "right", "calcs": ["lastNotNull", "max"]},
            "tooltip": {"mode": "multi", "sort": "none"},
        },
        "gridPos": grid_pos,
    }
    if max_val is not None:
        cfg["fieldConfig"]["defaults"]["max"] = max_val
    if thresholds:
        cfg["fieldConfig"]["defaults"]["thresholds"] = thresholds
    return cfg


def row_panel(panel_id, title, grid_pos, ds=None):
    return {
        "type": "row",
        "id": panel_id,
        "title": title,
        "datasource": ds or PROM_DS,
        "gridPos": grid_pos,
    }


PANELS = [
    row_panel(1, "CPU", {"h": 1, "w": 24, "x": 0, "y": 0}),
    ts_panel(
        2,
        "CPU usage vs request vs limit per pod",
        [
            {
                "refId": "A",
                "expr": f'sum by (pod, container) (rate(container_cpu_usage_seconds_total{{namespace="{NAMESPACE}",container!=""}}[5m]))',
                "legendFormat": "{{pod}}/{{container}} usage",
            },
            {
                "refId": "B",
                "expr": f'sum by (pod, container) (container_spec_cpu_quota{{namespace="{NAMESPACE}",container!=""}} / container_spec_cpu_period{{namespace="{NAMESPACE}",container!=""}})',
                "legendFormat": "{{pod}}/{{container}} limit",
            },
            {
                "refId": "C",
                "expr": f'sum by (pod, container) (kube_pod_container_resource_requests{{namespace="{NAMESPACE}",resource="cpu",container!=""}})',
                "legendFormat": "{{pod}}/{{container}} request",
            },
        ],
        "cores",
        {"h": 8, "w": 24, "x": 0, "y": 1},
    ),
    ts_panel(
        3,
        "CPU utilisation % of limit per container",
        [
            {
                "refId": "A",
                "expr": f'100 * sum by (pod, container) (rate(container_cpu_usage_seconds_total{{namespace="{NAMESPACE}",container!=""}}[5m])) / sum by (pod, container) (container_spec_cpu_quota{{namespace="{NAMESPACE}",container!=""}} / container_spec_cpu_period{{namespace="{NAMESPACE}",container!=""}})',
                "legendFormat": "{{pod}}/{{container}}",
            },
        ],
        "percent",
        {"h": 7, "w": 12, "x": 0, "y": 9},
        thresholds={
            "steps": [
                {"color": "green", "value": None},
                {"color": "yellow", "value": 80},
                {"color": "red", "value": 90},
            ]
        },
        max_val=100,
    ),
    row_panel(4, "Memory", {"h": 1, "w": 24, "x": 0, "y": 16}),
    ts_panel(
        5,
        "Memory usage vs request vs limit per pod",
        [
            {
                "refId": "A",
                "expr": f'sum by (pod, container) (container_memory_working_set_bytes{{namespace="{NAMESPACE}",container!=""}})',
                "legendFormat": "{{pod}}/{{container}} usage",
            },
            {
                "refId": "B",
                "expr": f'sum by (pod, container) (kube_pod_container_resource_limits{{namespace="{NAMESPACE}",resource="memory",container!=""}})',
                "legendFormat": "{{pod}}/{{container}} limit",
            },
            {
                "refId": "C",
                "expr": f'sum by (pod, container) (kube_pod_container_resource_requests{{namespace="{NAMESPACE}",resource="memory",container!=""}})',
                "legendFormat": "{{pod}}/{{container}} request",
            },
        ],
        "bytes",
        {"h": 8, "w": 24, "x": 0, "y": 17},
    ),
    ts_panel(
        6,
        "Memory utilisation % of limit per container",
        [
            {
                "refId": "A",
                "expr": f'100 * sum by (pod, container) (container_memory_working_set_bytes{{namespace="{NAMESPACE}",container!=""}}) / sum by (pod, container) (kube_pod_container_resource_limits{{namespace="{NAMESPACE}",resource="memory",container!=""}})',
                "legendFormat": "{{pod}}/{{container}}",
            },
        ],
        "percent",
        {"h": 7, "w": 12, "x": 0, "y": 25},
        thresholds={
            "steps": [
                {"color": "green", "value": None},
                {"color": "yellow", "value": 80},
                {"color": "red", "value": 90},
            ]
        },
        max_val=100,
    ),
    row_panel(7, "Disk / PVC", {"h": 1, "w": 24, "x": 0, "y": 32}),
    ts_panel(
        8,
        f"PVC utilisation ({NAMESPACE})",
        [
            {
                "refId": "A",
                "expr": f'100 * kubelet_volume_stats_used_bytes{{namespace="{NAMESPACE}"}} / kubelet_volume_stats_capacity_bytes{{namespace="{NAMESPACE}"}}',
                "legendFormat": "{{persistentvolumeclaim}}",
            },
        ],
        "percent",
        {"h": 7, "w": 12, "x": 0, "y": 33},
        thresholds={
            "steps": [
                {"color": "green", "value": None},
                {"color": "yellow", "value": 75},
                {"color": "red", "value": 90},
            ]
        },
        max_val=100,
    ),
    ts_panel(
        9,
        "Node disk utilisation (homelab-2nd)",
        [
            {
                "refId": "A",
                'expr': '100 - ((node_filesystem_avail_bytes{host="homelab-2nd",fstype!="tmpfs",fstype!="overlay"} * 100) / node_filesystem_size_bytes{host="homelab-2nd",fstype!="tmpfs",fstype!="overlay"})',
                "legendFormat": "{{mountpoint}}",
            },
        ],
        "percent",
        {"h": 7, "w": 12, "x": 12, "y": 33},
        thresholds={
            "steps": [
                {"color": "green", "value": None},
                {"color": "yellow", "value": 75},
                {"color": "red", "value": 90},
            ]
        },
        max_val=100,
    ),
    row_panel(10, "Logs", {"h": 1, "w": 24, "x": 0, "y": 40}, ds=LOKI_DS),
    {
        "type": "logs",
        "id": 11,
        "title": f"{NAMESPACE} logs",
        "datasource": LOKI_DS,
        "targets": [
            {
                "refId": "A",
                "expr": f'{{k8s_namespace_name="{NAMESPACE}"}}',
                "editorMode": "builder",
            },
        ],
        "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending"},
        "gridPos": {"h": 10, "w": 24, "x": 0, "y": 41},
    },
]

DASHBOARD = {
    "annotations": {"list": []},
    "editable": True,
    "fiscalYearStartMonth": 0,
    "graphTooltip": 0,
    "id": None,
    "links": [],
    "liveNow": True,
    "panels": PANELS,
    "refresh": "30s",
    "schemaVersion": 39,
    "tags": ["homelab", NAMESPACE],
    "templating": {"list": []},
    "time": {"from": "now-30m", "to": "now"},
    "timepicker": {},
    "timezone": "browser",
    "title": TITLE,
    "uid": UID,
    "version": 1,
}

CONFIGMAP = {
    "apiVersion": "v1",
    "kind": "ConfigMap",
    "metadata": {
        "name": f"{NAMESPACE}-dashboard",
        "namespace": "observability",
        "labels": {"grafana_dashboard": "1"},
        "annotations": {"grafana.folder": NAMESPACE},
    },
    "data": {f"{NAMESPACE}-dashboard.json": json.dumps(DASHBOARD, separators=(",", ":"))},
}

print(json.dumps(CONFIGMAP, indent=2))
