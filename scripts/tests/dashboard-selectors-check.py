#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# GUL-1993 (red stage): the panel selectors of two dashboards are wrong, so the
# panels are empty or double-count.
#
# observability-overview — the prometheus CPU and memory panels select
#   pod=~"prometheus-stack-kube-prom-prometheus.*"
# while the pod is really prometheus-prometheus-stack-kube-prom-prometheus-0
# (the operator prefixes the StatefulSet with the Prometheus object's name), so
# all six targets are empty. The CPU panel's description also has to say that
# the pod sets no CPU limit, so the empty limit series reads as expected rather
# than as a second defect.
#
# openchamber — syncthing is a sidecar container INSIDE the openchamber web pod,
# not a pod of its own: the syncthing panels select
# pod=~"openchamber-syncthing.*", which matches nothing, and the "web" panels
# select container!="" over the same pods, which counts the syncthing container
# twice.
#
#   AC-4  the prometheus CPU and memory panels of observability-overview select
#         pod=~"prometheus-prometheus-stack-kube-prom-prometheus.*", and that
#         selector matches prometheus-prometheus-stack-kube-prom-prometheus-0,
#         so all six targets return data.
#   AC-5  the prometheus CPU panel description records that the pod sets no CPU
#         limit, so an empty limit series is expected rather than a defect.
#   AC-6  the syncthing panels select pod=~"openchamber.*",container="syncthing"
#         and the openchamber web panels exclude that container.
#
# Reads only files in the worktree, touches no network.
#
# Usage: python3 scripts/tests/dashboard-selectors-check.py
# Exit:  0 = every AC passes, 1 = at least one fails.
# ---------------------------------------------------------------------------
import json
import os
import re
import shutil
import subprocess
import sys

OVERVIEW = "infrastructure/observability/dashboards/observability-overview-dashboard-configmap.yaml"
OPENCHAMBER = "apps/openchamber/openchamber-dashboard-configmap.yaml"

# The real pod name, as read off the cluster by GUL-1606.
PROMETHEUS_POD = "prometheus-prometheus-stack-kube-prom-prometheus-0"
PROMETHEUS_SELECTOR = 'prometheus-prometheus-stack-kube-prom-prometheus.*'
PROMETHEUS_TARGETS = 6
SYNCTHING_POD_SELECTOR = "openchamber.*"
SYNCTHING_CONTAINER = "syncthing"

MATCHER = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)\s*(=~|!~|!=|=)\s*"([^"]*)"')

reasons = {"AC-4": [], "AC-5": [], "AC-6": []}


# --------------------------------------------------------------------------
# reading
# --------------------------------------------------------------------------
def read_text(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def load_dashboards(path):
    """(documents, error). JSON first, yq for the YAML-shaped ConfigMaps."""
    if not os.path.exists(path):
        return [], "%s does not exist" % path
    text = read_text(path)
    try:
        document = json.loads(text)
    except ValueError:
        yq = shutil.which("yq")
        if not yq:
            return [], "%s is YAML and yq is not on PATH" % path
        proc = subprocess.run([yq, "-o=json", ".", path], capture_output=True, text=True)
        if proc.returncode != 0:
            return [], "%s could not be parsed: %s" % (path, proc.stderr.strip()[:120])
        document = json.loads(proc.stdout)
    data = document.get("data") if isinstance(document, dict) else None
    if not isinstance(data, dict) or not data:
        return [], "%s carries no ConfigMap data" % path
    found = []
    for key, value in data.items():
        if not key.endswith(".json"):
            continue
        if isinstance(value, dict):
            found.append(value)
        else:
            try:
                found.append(json.loads(value))
            except ValueError:
                return [], "%s data key %s is not JSON" % (path, key)
    if not found:
        return [], "%s carries no .json dashboard key" % path
    return found, None


def iter_panels(dash):
    stack = list(dash.get("panels") or [])
    while stack:
        panel = stack.pop(0)
        if not isinstance(panel, dict):
            continue
        yield panel
        stack = list(panel.get("panels") or []) + stack


def data_panels(dash):
    return [panel for panel in iter_panels(dash)
            if panel.get("type") not in ("row", "text", None)]


def panel_title(panel):
    return str(panel.get("title") or "")


def targets(panel):
    return [target for target in (panel.get("targets") or [])
            if isinstance(target, dict)]


def exprs(panel):
    found = []
    for target in targets(panel):
        for key in ("expr", "query", "expression"):
            value = target.get(key)
            if isinstance(value, str) and value.strip():
                found.append(value.strip())
    return found


def matchers(expr):
    return [(label, op, value) for label, op, value in MATCHER.findall(expr)]


def pod_selectors(panel):
    """Every (op, value) that constrains the `pod` label in one panel."""
    found = []
    for expr in exprs(panel):
        for label, op, value in matchers(expr):
            if label == "pod":
                found.append((op, value))
    return found


def selectors_match(selectors, wanted):
    """True when some positive `pod` selector equals `wanted` literally."""
    return any(op == "=~" and value == wanted for op, value in selectors)


def selector_matches_pod(selector):
    """Does a pod=~ selector actually select PROMETHEUS_POD?"""
    try:
        return re.match(selector, PROMETHEUS_POD) is not None
    except re.error:
        return False


def label_label(panel):
    return "panel %s %r" % (panel.get("id", "?"), panel_title(panel))


# --------------------------------------------------------------------------
# AC-4 — the prometheus CPU and memory panels select the real pod
# --------------------------------------------------------------------------
def ac4():
    dashboards, problem = load_dashboards(OVERVIEW)
    if problem:
        yield problem
        return
    wanted = []
    for dash in dashboards:
        for panel in data_panels(dash):
            title = panel_title(panel).lower()
            if re.search(r"prometheus\s+(cpu|memory)", title):
                wanted.append(panel)
    if not wanted:
        yield ("%s has no panel titled 'prometheus CPU' / 'prometheus memory'"
               % OVERVIEW)
        return
    kinds = {re.search(r"prometheus\s+(cpu|memory)", panel_title(panel).lower()).group(1)
             for panel in wanted}
    for kind in sorted({"cpu", "memory"} - kinds):
        yield "%s has no 'prometheus %s' panel" % (OVERVIEW, kind)
    total = 0
    for panel in wanted:
        selectors = pod_selectors(panel)
        total += len(exprs(panel))
        if not selectors:
            yield "%s selects no pod label at all" % label_label(panel)
            continue
        if not selectors_match(selectors, PROMETHEUS_SELECTOR):
            yield ("%s selects %s; the standard selector is pod=~\"%s\", which the real "
                   "pod %s matches"
                   % (label_label(panel),
                      ", ".join("pod%s\"%s\"" % (op, value) for op, value in selectors),
                      PROMETHEUS_SELECTOR, PROMETHEUS_POD))
            continue
        if not selector_matches_pod(PROMETHEUS_SELECTOR):
            yield ("pod=~\"%s\" does not match the real pod name %s"
                   % (PROMETHEUS_SELECTOR, PROMETHEUS_POD))
    if total != PROMETHEUS_TARGETS:
        yield ("the prometheus CPU and memory panels carry %d targets; %d are expected "
               "(usage, request, limit for each), so the six series all come back"
               % (total, PROMETHEUS_TARGETS))


# --------------------------------------------------------------------------
# AC-5 — the CPU panel says the empty limit series is expected
# --------------------------------------------------------------------------
ABSENCE = re.compile(r"(?i)\b(no|none|not|never|unset|absent|without|unlimited|"
                     r"empty|missing|zero)\b")
CPU_LIMIT = re.compile(r"(?i)cpu[\s_\-]*limit")


def ac5():
    dashboards, problem = load_dashboards(OVERVIEW)
    if problem:
        yield problem
        return
    panels = [panel for dash in dashboards for panel in data_panels(dash)
              if re.search(r"(?i)prometheus\s+cpu", panel_title(panel))]
    if not panels:
        yield "%s has no 'prometheus CPU' panel to describe" % OVERVIEW
        return
    for panel in panels:
        description = panel.get("description")
        if not isinstance(description, str) or not description.strip():
            yield ("%s has no description, so nothing records that the pod sets no "
                   "CPU limit" % label_label(panel))
            continue
        if not CPU_LIMIT.search(description):
            yield ("%s description does not mention a CPU limit: %r"
                   % (label_label(panel), description.strip()[:160]))
            continue
        if not ABSENCE.search(description):
            yield ("%s description mentions a CPU limit but does not record that the "
                   "pod sets none, so an empty limit series still reads as a defect: %r"
                   % (label_label(panel), description.strip()[:160]))


# --------------------------------------------------------------------------
# AC-6 — syncthing is a container in the web pod, counted once
# --------------------------------------------------------------------------
def container_matchers(panel):
    found = []
    for expr in exprs(panel):
        for label, op, value in matchers(expr):
            if label == "container":
                found.append((op, value))
    return found


def excludes_syncthing(selectors):
    """True when the container matchers cannot select the syncthing container."""
    if not selectors:
        return False
    positive = [(op, value) for op, value in selectors if op in ("=", "=~")]
    negative = [(op, value) for op, value in selectors if op in ("!=", "!~")]
    if positive:
        return all(not selector_matches(value, op, SYNCTHING_CONTAINER)
                   and not (op == "=" and value == SYNCTHING_CONTAINER)
                   for op, value in positive)
    return any(selector_matches(value, op, SYNCTHING_CONTAINER)
               for op, value in negative)


def selector_matches(value, op, literal):
    try:
        return re.fullmatch(value, literal) is not None
    except re.error:
        return False


def ac6():
    dashboards, problem = load_dashboards(OPENCHAMBER)
    if problem:
        yield problem
        return
    syncthing, web = [], []
    for dash in dashboards:
        for panel in data_panels(dash):
            title = panel_title(panel).lower()
            if "syncthing" in title:
                syncthing.append(panel)
            elif re.match(r"^openchamber\s+web\b", title):
                web.append(panel)
    if len(syncthing) < 2:
        yield ("%s carries %d syncthing panel(s) %s; the sidecar needs a CPU and a "
               "memory panel" % (OPENCHAMBER, len(syncthing),
                                 [panel_title(panel) for panel in syncthing]))
    if len(web) < 2:
        yield ("%s carries %d 'openchamber web' panel(s) %s; the web container needs a "
               "CPU and a memory panel" % (OPENCHAMBER, len(web),
                                           [panel_title(panel) for panel in web]))
    for panel in syncthing:
        selectors = pod_selectors(panel)
        containers = container_matchers(panel)
        if not selectors_match(selectors, SYNCTHING_POD_SELECTOR):
            yield ("%s selects %s; syncthing is a sidecar of the web pod, so it must "
                   "select pod=~\"%s\""
                   % (label_label(panel),
                      ", ".join("pod%s\"%s\"" % (op, value) for op, value in selectors)
                      or "no pod label",
                      SYNCTHING_POD_SELECTOR))
        if not any(op == "=" and value == SYNCTHING_CONTAINER
                   for op, value in containers):
            yield ("%s selects %s; it must name the sidecar container with "
                   "container=\"%s\" or it counts every container of the pod"
                   % (label_label(panel),
                      ", ".join("container%s\"%s\"" % (op, value)
                                for op, value in containers) or "no container label",
                      SYNCTHING_CONTAINER))
    for panel in web:
        containers = container_matchers(panel)
        if not excludes_syncthing(containers):
            yield ("%s selects %s, so the syncthing sidecar is counted again on top of "
                   "its own panels; the web panels must exclude container=\"%s\""
                   % (label_label(panel),
                      ", ".join("container%s\"%s\"" % (op, value)
                                for op, value in containers) or "every container",
                      SYNCTHING_CONTAINER))


# --------------------------------------------------------------------------
# run
# --------------------------------------------------------------------------
for ac, check in (("AC-4", ac4), ("AC-5", ac5), ("AC-6", ac6)):
    try:
        reasons[ac].extend(check())
    except Exception as exc:  # noqa: BLE001 - never lose an AC line to a crash
        reasons[ac].append("check errored: %s: %s" % (type(exc).__name__, exc))

failed = 0
for ac in ("AC-4", "AC-5", "AC-6"):
    items = [str(item).replace("\n", " ") for item in reasons[ac]]
    if items:
        failed += 1
        detail = " | ".join(items[:3])
        if len(items) > 3:
            detail += " (+%d more)" % (len(items) - 3)
        if len(detail) > 320:
            detail = detail[:317] + "..."
        print("%s: FAIL %s" % (ac, detail))
    else:
        print("%s: PASS" % ac)

sys.stderr.write("dashboard-selectors-check: %d of 3 ACs fail\n" % failed)
sys.exit(1 if failed else 0)
