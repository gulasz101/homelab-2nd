#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-1758 (WO-4A follow-up, red half): the dashboards must be *live*.
#
# `docs/dashboards.md` and `scripts/tests/dashboard-standard-check.sh` say every
# generated dashboard has the same shape, schema and description. They say
# nothing about whether the panels can return data: after GUL-1598 22 log
# panels asked Prometheus for `{...}` / `count_over_time(...)` LogQL, a cluster
# of CPU panels read `container_spec_cpu_quota` (the cAdvisor metric that
# kube-state-metrics replaces), the GPU board still selected `nvidia_smi_`
# metrics this cluster stopped exporting, node-level panels carried
# host="homelab-2nd" matchers (node-exporter is scraped behind a job label, not
# a host label) and a PVC selector pointed at a claim llm-hub does not have.
# Each of those renders an empty panel or a query error in Grafana - the 124
# empty targets this work order is about.
#
# This check is the machine-readable half of that follow-up: it reads the
# dashboard ConfigMaps in the worktree, the manifest
# `scripts/dashboards/manifest.json` and nothing else (no cluster, no network,
# no render).
#
#   AC-1: this script exists, `bash -n` accepts it, `scripts/check.sh --list`
#         discovers it, `--ac N` runs one check, and no argument runs every
#         check and exits 0 only when they all pass.
#   AC-2: no expr reads `container_spec_cpu_quota`; every CPU limit/request
#         panel selects `kube_pod_container_resource_limits` or
#         `kube_pod_container_resource_requests` with resource="cpu".
#   AC-3: no expr reads `nvidia_smi_`, the manifest has no "withGpu": true, the
#         GPU board has no nvidia panel and still has a node power/thermal expr.
#   AC-4: no expr matches host="homelab-2nd", no node_* expr carries a host=
#         matcher, and node-level exprs select job="node-exporter" or
#         instance=".*:9100".
#   AC-5: Loki and Prometheus stay apart: no `|=~`, no LogQL on a Prometheus
#         datasource, every logs panel declares ${loki}, and no logs panel
#         filters telemetry-ish words out of its own log stream.
#   AC-6: every namespace="X" is declared for that dashboard in the manifest,
#         the whiteboard tunnel reads namespace apps-tldraw, every
#         persistentvolumeclaim="X" is a real claim (CNPG instance or the
#         `kubectl get pvc -A` allowlist below), and llm-hub does not read
#         redis-data.
#
# Discovery: scripts/check.sh globs */tests/*-check.sh, so the filename is the
# registration - do not rename it. There are no fixture files: every check
# parses the dashboards that are in the tree, which is what makes it fail on a
# dashboard nobody has fixed yet.
#
# Usage: bash scripts/tests/dashboard-liveness-check.sh           run every AC
#        bash scripts/tests/dashboard-liveness-check.sh --ac 3    run AC-3 only
# Exit:  0 = every requested AC passed, 1 = at least one failed,
#        2 = usage error (an AC id this script does not have).
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT" || exit 2
SELF="$ROOT/scripts/tests/dashboard-liveness-check.sh"
ALL_ACS=(1 2 3 4 5 6)

usage() {
  printf 'usage: bash scripts/tests/dashboard-liveness-check.sh [--ac N]\n' >&2
  printf 'ACs: %s\n' "${ALL_ACS[*]}" >&2
}

want=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ac)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      want+=("$2")
      shift 2
      ;;
    --ac=*)
      want+=("${1#*=}")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'dashboard-liveness-check: unknown argument %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done
# No argument means every check: AC-1 of the work order asks for that.
if [ "${#want[@]}" -eq 0 ]; then
  want=("${ALL_ACS[@]}")
fi
for ac in "${want[@]}"; do
  case " ${ALL_ACS[*]} " in
    *" $ac "*) ;;
    *)
      printf 'dashboard-liveness-check: no such check --ac %s\n' "$ac" >&2
      usage
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# AC-1 - this script is a first-class check of scripts/check.sh
# ---------------------------------------------------------------------------
ac1_line() {
  local problems=() err out rc first
  if [ ! -f "$SELF" ]; then
    problems+=("$SELF does not exist")
  fi
  if ! err=$(bash -n "$SELF" 2>&1); then
    problems+=("bash -n rejects it: ${err//$'\n'/ }")
  fi
  # scripts/check.sh auto-discovers */tests/*-check.sh; if that glob misses
  # this file, no run in CI ever executes it.
  out=$(bash scripts/check.sh --list 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    problems+=("scripts/check.sh --list exited $rc")
  else
    case "$out" in
      *scripts/tests/dashboard-liveness-check.sh*) ;;
      *) problems+=("scripts/check.sh --list does not discover this file (it needs a */tests/*-check.sh name)") ;;
    esac
  fi
  # --ac N runs exactly the check it names.
  out=$(bash "$SELF" --ac 2 2>&1)
  rc=$?
  case "$rc" in
    0|1) ;;
    *) problems+=("--ac 2 exited $rc, not 0 or 1") ;;
  esac
  case "$out" in
    *"AC-2: "*) ;;
    *) problems+=("--ac 2 printed no AC-2 line") ;;
  esac
  # No argument runs every check and exits 0 only when all of them pass.
  # LIVENESS_NESTED keeps AC-1 from spawning another no-argument run of itself.
  if [ -z "${LIVENESS_NESTED:-}" ]; then
    out=$(LIVENESS_NESTED=1 bash "$SELF" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      first=$(printf '%s\n' "$out" | grep -m1 'FAIL')
      problems+=("no-argument run exited $rc, and it must exit 0 only with every check green: ${first:-no FAIL line printed}")
    fi
  fi
  if [ "${#problems[@]}" -eq 0 ]; then
    printf 'AC-1: PASS\n'
    return 0
  fi
  printf 'AC-1: FAIL %s\n' "$(printf '%s; ' "${problems[@]}" | cut -c1-240)"
  return 1
}

# ---------------------------------------------------------------------------
# AC-2..AC-6 - one python3 -I program: stdlib only (the Air and CI have no
# PyYAML), ConfigMaps read as JSON when the generator wrote JSON and through
# the yq v4.54.1 pinned in .github/workflows/check.yaml when they are YAML.
# ---------------------------------------------------------------------------
python_acs=()
for ac in "${want[@]}"; do
  [ "$ac" = "1" ] || python_acs+=("$ac")
done

py_out=""
py_rc=0
if [ "${#python_acs[@]}" -gt 0 ]; then
  py_out=$(python3 -I - "${python_acs[@]}" <<'PY'
import glob
import json
import os
import re
import shutil
import subprocess
import sys

WANT = sys.argv[1:]
ROOT = os.getcwd()
MANIFEST = "scripts/dashboards/manifest.json"
DASH_GLOBS = ("apps/*/*dashboard-configmap.yaml",
              "infrastructure/**/*dashboard-configmap*.yaml")
GPU_BOARD = "infrastructure/observability/dashboards/homelab-gpu-power-dashboard-configmap.yaml"
WHITEBOARD_DIR = "apps/whiteboard/"
LLM_HUB_DIR = "apps/llm-hub/"
OUTPUT_KEYS = ("output", "outputPath", "output_path", "path", "file", "filename")

CONTAINER_QUOTA = "container_spec_cpu_quota"
CPU_LIMIT_OK = re.compile(r'kube_pod_container_resource_(limits|requests)\s*\{[^}]*resource\s*=\s*"cpu"')
CPU_EXPR = re.compile(r'container_spec_cpu_|kube_pod_container_resource_')
NVIDIA = re.compile(r'nvidia_smi_')
NODE_THERMAL = re.compile(r'node_rapl_|node_hwmon_|node_thermal_')
# node-exporter series are scraped behind a job label on :9100; a per-host label
# is not on the series, so a host= matcher leaves the panel permanently empty.
HOST_LITERAL = re.compile(r'host\s*=\s*"homelab-2nd"')
HOST_ANY = re.compile(r'\bhost\s*(=|!=|=~|!~)')
NODE_METRIC = re.compile(r'\bnode_[a-z0-9_]+')
NODE_SELECTOR = re.compile(r'job\s*=\s*"node-exporter"|instance\s*=~?\s*".*:9100"')
PIPE_FILTER = re.compile(r'\|[=~]~?\s*"([^"]*)"')
TELEMETRY = re.compile(r'(?i)telemetry|otel')
NS_MATCHER = re.compile(r'namespace\s*=\s*"([^"]*)"')
PVC_MATCHER = re.compile(r'persistentvolumeclaim\s*=\s*"([^"]*)"')
CNPG_INSTANCE = re.compile(r'-[0-9]+$')

# The claim names a dashboard may select. Source: `kubectl get pvc -A` on the
# homelab-2nd cluster, refreshed 2026-11-19. CNPG instance claims (…-0/…-1/…-2)
# are allowed by pattern and are not listed. redis-data is listed because auth
# and firecrawl really have it; llm-hub does not, and the dedicated llm-hub rule
# below is what keeps a panel from selecting it there (AC-6).
PVC_ALLOWLIST = {
    "arr-stack-downloads", "arr-stack-media", "bazarr-config", "gluetun-config",
    "homepage-config", "jellyfin-config", "prowlarr-config", "qbittorrent-config",
    "radarr-config", "sonarr-config", "docs-mcp-config", "docs-mcp-data",
    "rabbitmq-data", "opengym-data", "opengym-media", "freellmapi-data",
    "ollama-models", "karakeep-meilisearch", "mailarchiver-keys",
    "nextcloud-data", "nextcloud-html", "openchamber-data",
    "openchamber-storage", "opengist-data", "pihole", "riffradar-data",
    "speaches-model-cache", "grafana", "influxdb", "node-red-data",
    "redis-data",
}


class CheckError(Exception):
    """A fact the check could not establish; reported as that AC's FAIL."""


def load_doc(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    try:
        return json.loads(text)
    except ValueError:
        pass
    yq = shutil.which("yq")
    if not yq:
        raise CheckError("%s is YAML and yq is not on PATH" % path)
    proc = subprocess.run([yq, "-o=json", ".", path], capture_output=True, text=True)
    if proc.returncode != 0:
        raise CheckError("%s could not be parsed: %s" % (path, proc.stderr.strip()[:120]))
    try:
        return json.loads(proc.stdout)
    except ValueError:
        raise CheckError("%s does not convert to one JSON document" % path)


def panels_of(doc):
    found = []

    def walk(items):
        for panel in items or []:
            if not isinstance(panel, dict):
                continue
            found.append(panel)
            walk(panel.get("panels"))

    walk(doc.get("panels"))
    return found


_docs = {}


def dashboards():
    """[(path, [dashboard, ...])] for every dashboard ConfigMap in the tree."""
    if "value" in _docs:
        return _docs["value"]
    paths = set()
    for pattern in DASH_GLOBS:
        paths.update(glob.glob(pattern, recursive=True))
    result = []
    for path in sorted(paths):
        cm = load_doc(path)
        data = cm.get("data") if isinstance(cm, dict) else None
        docs = []
        for key, value in (data or {}).items():
            if not key.endswith(".json"):
                continue
            if isinstance(value, dict):
                docs.append(value)
            else:
                try:
                    docs.append(json.loads(value))
                except ValueError:
                    raise CheckError("%s data key %s is not JSON" % (path, key))
        if not docs:
            raise CheckError("%s carries no .json dashboard" % path)
        result.append((path, docs))
    if not result:
        raise CheckError("no *dashboard-configmap*.yaml found - the check ran in the wrong tree")
    _docs["value"] = result
    return result


_panels = {}


def panels():
    """[(path, title, panel, [expr, ...])] over every panel of every dashboard."""
    if "value" in _panels:
        return _panels["value"]
    result = []
    for path, docs in dashboards():
        for doc in docs:
            for panel in panels_of(doc):
                exprs = []
                for target in panel.get("targets") or []:
                    if isinstance(target, dict):
                        exprs.append(str(target.get("expr") or ""))
                result.append((path, str(panel.get("title") or ""), panel, exprs))
    _panels["value"] = result
    return result


def is_loki(panel):
    ds = panel.get("datasource")
    if not isinstance(ds, dict):
        return False
    return ds.get("type") == "loki" or ds.get("uid") == "${loki}"


_manifest = {}


def manifest():
    if "value" in _manifest:
        return _manifest["value"]
    if not os.path.exists(MANIFEST):
        raise CheckError("%s is missing" % MANIFEST)
    try:
        raw = json.load(open(MANIFEST, encoding="utf-8"))
    except ValueError as exc:
        raise CheckError("%s is not valid JSON: %s" % (MANIFEST, exc))
    listed = raw.get("dashboards") if isinstance(raw, dict) else raw
    if not isinstance(listed, list):
        raise CheckError("%s has no dashboards list" % MANIFEST)
    _manifest["value"] = [item for item in listed if isinstance(item, dict)]
    return _manifest["value"]


def entry_path(entry):
    for key in OUTPUT_KEYS:
        value = entry.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip().lstrip("./")
    return None


def declared_namespaces():
    """output path -> namespaces the manifest declares for that dashboard."""
    declared = {}
    for entry in manifest():
        path = entry_path(entry)
        if path is None:
            continue
        names = set()
        for key in ("namespace", "k8sNamespace"):
            value = entry.get(key)
            if isinstance(value, str) and value.strip():
                names.add(value.strip())
        for service in entry.get("services") or []:
            if not isinstance(service, dict):
                continue
            for key in ("k8sNamespace", "namespace"):
                value = service.get(key)
                if isinstance(value, str) and value.strip():
                    names.add(value.strip())
        declared[path] = names
    return declared


def short(text, limit=58):
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 3] + "..."


def where(path, title):
    return '%s "%s"' % (os.path.basename(path), short(title, 34))


# ---------------------------------------------------------------------------
def ac2(reasons):
    """cAdvisor quota metrics out, kube-state-metrics CPU limits/requests in."""
    quota = [(path, title, expr) for path, title, _panel, exprs in panels()
             for expr in exprs if CONTAINER_QUOTA in expr]
    cpu_panels = 0
    cpu_bad = []
    for path, title, panel, exprs in panels():
        if panel.get("type") in ("row", "text"):
            continue
        if not re.search(r'(?i)cpu', title):
            continue
        if not any(CPU_EXPR.search(expr) for expr in exprs):
            continue
        cpu_panels += 1
        if not any(CPU_LIMIT_OK.search(expr) for expr in exprs):
            cpu_bad.append((path, title))
    if quota:
        path, title, expr = quota[0]
        reasons.append("%d exprs read container_spec_cpu_quota (want 0), e.g. %s: %s"
                       % (len(quota), where(path, title), short(expr)))
    if cpu_bad:
        path, title = cpu_bad[0]
        reasons.append("%d of %d CPU limit/request panels select no "
                       "kube_pod_container_resource_limits/requests{resource=\"cpu\"}, "
                       "e.g. %s" % (len(cpu_bad), cpu_panels, where(path, title)))
    if not cpu_panels:
        reasons.append("no CPU limit/request panel matched - the check found nothing to verify")
    if not reasons:
        return "cpu=%d quota=0" % cpu_panels
    return "quota=%d cpu_missing=%d/%d" % (len(quota), len(cpu_bad), cpu_panels)


# ---------------------------------------------------------------------------
def ac3(reasons):
    """nvidia_smi_ is gone; the GPU board keeps a node-level power reading."""
    nvidia = [(path, title, expr) for path, title, _panel, exprs in panels()
              for expr in exprs if NVIDIA.search(expr)]
    with_gpu = [entry_path(entry) or "<unnamed>" for entry in manifest()
                if entry.get("withGpu") is True]
    gpu_nvidia = [(path, title) for path, title, _panel, exprs in panels()
                  if path == GPU_BOARD and (NVIDIA.search(title) or
                                            any(NVIDIA.search(expr) for expr in exprs))]
    thermal = [(path, title) for path, title, _panel, exprs in panels()
               if any(NODE_THERMAL.search(expr) for expr in exprs)]
    if nvidia:
        path, title, expr = nvidia[0]
        reasons.append("%d exprs read nvidia_smi_ (want 0), e.g. %s: %s"
                       % (len(nvidia), where(path, title), short(expr)))
    if with_gpu:
        reasons.append('%d manifest entries carry "withGpu": true (want 0): %s'
                       % (len(with_gpu), ", ".join(short(item, 38) for item in with_gpu[:3])))
    if gpu_nvidia:
        reasons.append("%s still has %d nvidia panel(s), e.g. \"%s\""
                       % (os.path.basename(GPU_BOARD), len(gpu_nvidia),
                          short(gpu_nvidia[0][1], 40)))
    if not thermal:
        reasons.append("%s carries no node power/thermal expr (node_rapl_/node_hwmon_/"
                       "node_thermal_) - GPU load needs the node-side reading"
                       % os.path.basename(GPU_BOARD))
    if not reasons:
        return "nvidia=0 thermal=%d" % len(thermal)
    return "nvidia=%d withGpu=%d gpu_panels=%d thermal=%d" % (
        len(nvidia), len(with_gpu), len(gpu_nvidia), len(thermal))


# ---------------------------------------------------------------------------
def ac4(reasons):
    """Node-level series are selected by job/instance, never by host=."""
    host_literal = [(path, title, expr) for path, title, _panel, exprs in panels()
                    for expr in exprs if HOST_LITERAL.search(expr)]
    node_host = [(path, title, expr) for path, title, _panel, exprs in panels()
                 for expr in exprs if NODE_METRIC.search(expr) and HOST_ANY.search(expr)]
    node_exprs = 0
    node_unselected = []
    for path, title, _panel, exprs in panels():
        for expr in exprs:
            if not NODE_METRIC.search(expr):
                continue
            node_exprs += 1
            if not NODE_SELECTOR.search(expr):
                node_unselected.append((path, title, expr))
    if host_literal:
        path, title, expr = host_literal[0]
        reasons.append('%d exprs match host="homelab-2nd" (want 0), e.g. %s: %s'
                       % (len(host_literal), where(path, title), short(expr)))
    if node_host:
        path, title, expr = node_host[0]
        reasons.append("%d node_* exprs carry a host= matcher (want 0), e.g. %s: %s"
                       % (len(node_host), where(path, title), short(expr)))
    if node_unselected:
        path, title, expr = node_unselected[0]
        reasons.append('%d of %d node_* exprs select neither job="node-exporter" nor '
                       'instance=".*:9100", e.g. %s: %s'
                       % (len(node_unselected), node_exprs, where(path, title), short(expr)))
    if not node_exprs:
        reasons.append("no node_* expr found - the check found nothing to verify")
    if not reasons:
        return "host=0 node_host=0 node_exprs=%d" % node_exprs
    return "host_literal=%d node_host=%d node_unselected=%d/%d" % (
        len(host_literal), len(node_host), len(node_unselected), node_exprs)


# ---------------------------------------------------------------------------
def ac5(reasons):
    """LogQL stays on Loki, and a logs panel does not filter its telemetry away."""
    pipe_eq_tilde = [(path, title, expr) for path, title, _panel, exprs in panels()
                     for expr in exprs if "|=~" in expr]
    logql_panels = 0
    logql_wrong = []
    logs_panels = 0
    logs_without_loki = []
    telemetry = []
    for path, title, panel, exprs in panels():
        joined = " ".join(exprs)
        if "count_over_time(" in joined or "{k8s_namespace_name=" in joined:
            logql_panels += 1
            if not is_loki(panel):
                logql_wrong.append((path, title, panel.get("datasource")))
        if panel.get("type") == "logs":
            logs_panels += 1
            if not is_loki(panel):
                logs_without_loki.append((path, title))
        for expr in exprs:
            for pattern in PIPE_FILTER.findall(expr):
                if TELEMETRY.search(pattern):
                    telemetry.append((path, title, expr))
    if pipe_eq_tilde:
        path, title, expr = pipe_eq_tilde[0]
        reasons.append("%d exprs use the invalid filter operator |=~ (want 0), e.g. %s: %s"
                       % (len(pipe_eq_tilde), where(path, title), short(expr)))
    if logql_wrong:
        path, title, ds = logql_wrong[0]
        reasons.append("%d of %d LogQL panels do not declare datasource type loki "
                       "(template ${loki}), e.g. %s carries %s"
                       % (len(logql_wrong), logql_panels, where(path, title),
                          json.dumps(ds)[:50]))
    if logs_without_loki:
        path, title = logs_without_loki[0]
        reasons.append("%d of %d logs panels do not declare ${loki}, e.g. %s"
                       % (len(logs_without_loki), logs_panels, where(path, title)))
    if telemetry:
        path, title, expr = telemetry[0]
        reasons.append("%d logs targets filter telemetry|otel out of the panel's own stream, "
                       "e.g. %s: %s" % (len(telemetry), where(path, title), short(expr)))
    if not reasons:
        return "logql=%d logs=%d" % (logql_panels, logs_panels)
    return "pipe_eq_tilde=%d logql_not_loki=%d/%d logs_not_loki=%d/%d telemetry=%d" % (
        len(pipe_eq_tilde), len(logql_wrong), logql_panels,
        len(logs_without_loki), logs_panels, len(telemetry))


# ---------------------------------------------------------------------------
def ac6(reasons):
    """Namespace and PVC selectors point at things that exist."""
    declared = declared_namespaces()
    undeclared = []
    checked = 0
    for path, title, _panel, exprs in panels():
        allowed = declared.get(path)
        if allowed is None:
            continue  # hand-written cluster boards are not manifest dashboards
        for expr in exprs:
            for name in NS_MATCHER.findall(expr):
                checked += 1
                if name not in allowed:
                    undeclared.append((path, title, name, sorted(allowed)))
    if undeclared:
        path, title, name, allowed = undeclared[0]
        reasons.append('%d namespace="X" matchers name a namespace the manifest does not '
                       'declare for that dashboard, e.g. %s uses "%s" (declared: %s)'
                       % (len(undeclared), where(path, title), name,
                          ", ".join(allowed) or "none"))

    tunnel = [expr for path, _title, _panel, exprs in panels()
              if path.startswith(WHITEBOARD_DIR) for expr in exprs
              if "cloudflared" in expr or "tldraw" in expr]
    if not tunnel:
        reasons.append("%s has no cloudflared/tldraw tunnel expr - the whiteboard tunnel is "
                       "not monitored at all" % WHITEBOARD_DIR.rstrip("/"))
    else:
        missing = [expr for expr in tunnel if 'namespace="apps-tldraw"' not in expr]
        if missing:
            reasons.append('%d of %d whiteboard tunnel exprs do not select '
                           'namespace="apps-tldraw", e.g. %s'
                           % (len(missing), len(tunnel), short(missing[0])))

    pvc_total = 0
    pvc_bad = []
    for path, title, _panel, exprs in panels():
        for expr in exprs:
            for name in PVC_MATCHER.findall(expr):
                pvc_total += 1
                if CNPG_INSTANCE.search(name) or name in PVC_ALLOWLIST:
                    continue
                pvc_bad.append((path, title, name))
    if pvc_bad:
        path, title, name = pvc_bad[0]
        reasons.append('%d of %d persistentvolumeclaim="X" matchers name a claim that is '
                       'neither a CNPG instance nor in the kubectl-get-pvc allowlist, '
                       'e.g. %s uses "%s"'
                       % (len(pvc_bad), pvc_total, where(path, title), name))

    redis = [(path, title) for path, title, _panel, exprs in panels()
             if path.startswith(LLM_HUB_DIR)
             for expr in exprs if 'persistentvolumeclaim="redis-data"' in expr]
    if redis:
        path, title = redis[0]
        reasons.append('%s reads persistentvolumeclaim="redis-data" in %d panel(s), e.g. %s - '
                       'llm-hub has no redis claim'
                       % (LLM_HUB_DIR.rstrip("/"), len(redis), where(path, title)))
    if not reasons:
        return "namespaces=%d pvc=%d" % (checked, pvc_total)
    return "undeclared_ns=%d pvc_unknown=%d/%d llmhub_redis=%d" % (
        len(undeclared), len(pvc_bad), pvc_total, len(redis))


CHECKS = {"2": ac2, "3": ac3, "4": ac4, "5": ac5, "6": ac6}

failed = 0
for ac in WANT:
    fn = CHECKS.get(ac)
    if fn is None:
        print("AC-%s: FAIL this script has no check %s" % (ac, ac))
        failed += 1
        continue
    reasons = []
    try:
        summary = fn(reasons)
    except CheckError as exc:
        reasons.append(str(exc))
        summary = ""
    except Exception as exc:  # noqa: BLE001 - never lose an AC line to a crash
        reasons.append("check errored: %s: %s" % (type(exc).__name__, exc))
        summary = ""
    if reasons:
        failed += 1
        detail = " | ".join(" ".join(str(item).split()) for item in reasons)
        if len(detail) > 300:
            detail = detail[:297] + "..."
        print("AC-%s: FAIL %s" % (ac, detail))
    else:
        print("AC-%s: PASS (%s)" % (ac, summary))

sys.exit(1 if failed else 0)
PY
)
  py_rc=$?
fi

status=0
for ac in "${want[@]}"; do
  if [ "$ac" = "1" ]; then
    ac1_line || status=1
    break
  fi
done
if [ -n "$py_out" ]; then
  printf '%s\n' "$py_out"
  [ "$py_rc" -eq 0 ] || status=1
fi
if [ "$py_rc" -ne 0 ] && [ "$py_rc" -ne 1 ]; then
  printf 'AC-%s: FAIL the python check exited %d\n' "${python_acs[0]}" "$py_rc"
  status=1
fi

exit "$status"
