#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-2166 (WO-4B fix, red half): three selector defects that render empty or
# double-counted panels.
#
# 1. observability-overview "prometheus CPU" / "prometheus memory" selected
#    pod=~"prometheus-stack-kube-prom-prometheus.*". The real pod is
#    prometheus-prometheus-stack-kube-prom-prometheus-0, so all six targets
#    (usage, request, limit on both panels) matched nothing.
# 2. the same CPU panel carried a generic description that did not say the
#    Prometheus pod sets no CPU limit - the empty "limit" series looked like a
#    defect instead of the expected shape.
# 3. openchamber's "syncthing" panels invented a pod (openchamber-syncthing.*)
#    for a container that runs inside the openchamber web pod, while the web
#    panels excluded that invented pod name and therefore counted the whole
#    syncthing container into the web totals: two empty panels and a
#    double-counted sidecar.
#
#   AC-4: the prometheus CPU and memory panels select
#         pod=~"prometheus-prometheus-stack-kube-prom-prometheus.*", which the
#         real pod name matches, on all six targets, and the old prefix is gone.
#   AC-5: the prometheus CPU panel description records that the pod sets no CPU
#         limit, so an empty limit series is expected rather than a defect.
#   AC-6: the syncthing panels select the syncthing container inside the web pod
#         (pod=~"openchamber.*",container="syncthing") and the web panels exclude
#         that container, so nothing is empty and nothing is double-counted.
#
# Reads only files in the worktree - no cluster, no network, no render:
#   infrastructure/observability/dashboards/observability-overview-dashboard-configmap.yaml
#   apps/openchamber/openchamber-dashboard-configmap.yaml
#   apps/openchamber/openchamber-deployment.yaml   (ground truth for the container)
#
# Usage: bash scripts/tests/dashboard-selectors-check.sh          run AC-4..AC-6
#        bash scripts/tests/dashboard-selectors-check.sh --ac 5   run AC-5 only
# Exit:  0 = every requested AC passed, 1 = at least one failed,
#        2 = usage error.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT" || exit 2
ALL_ACS=(4 5 6)

usage() {
  printf 'usage: bash scripts/tests/dashboard-selectors-check.sh [--ac N]\n' >&2
  printf 'ACs: %s\n' "${ALL_ACS[*]}" >&2
}

want=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ac)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      want+=("$2"); shift 2 ;;
    --ac=*)
      want+=("${1#*=}"); shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      printf 'dashboard-selectors-check: unknown argument %s\n' "$1" >&2
      usage; exit 2 ;;
  esac
done
if [ "${#want[@]}" -eq 0 ]; then
  want=("${ALL_ACS[@]}")
fi
for ac in "${want[@]}"; do
  case " ${ALL_ACS[*]} " in
    *" $ac "*) ;;
    *) printf 'dashboard-selectors-check: no such check --ac %s\n' "$ac" >&2; usage; exit 2 ;;
  esac
done

python3 -I - "${want[@]}" <<'PY'
import glob
import json
import os
import re
import shutil
import subprocess
import sys

WANT = sys.argv[1:]
OBS = "infrastructure/observability/dashboards/observability-overview-dashboard-configmap.yaml"
OC = "apps/openchamber/openchamber-dashboard-configmap.yaml"
OC_DEPLOY = "apps/openchamber/openchamber-deployment.yaml"
OC_DIR = "apps/openchamber/"

# The real series identity, from `kubectl -n observability get pods`:
# prometheus-prometheus-stack-kube-prom-prometheus-0 is the only Prometheus pod.
PROM_POD = "prometheus-prometheus-stack-kube-prom-prometheus-0"
PROM_PREFIX = "prometheus-prometheus-stack-kube-prom-prometheus"
PROM_OLD_PREFIX = "prometheus-stack-kube-prom-prometheus"
PROM_TARGETS = 6

# The openchamber Deployment is named `openchamber`, so its ReplicaSet pods are
# openchamber-<rs-hash>-<suffix>. This sample name is what a pod=~ matcher on the
# web pod has to match.
OC_WEB_POD = "openchamber-5d9c7f8b9-abcde"


class CheckError(Exception):
    """A fact the check could not establish; reported as that AC's FAIL."""


def read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def load_dashboards(path):
    """[(data key, dashboard dict)] for one dashboard ConfigMap."""
    if not os.path.isfile(path):
        raise CheckError("%s is missing" % path)
    text = read(path)
    try:
        doc = json.loads(text)
    except ValueError:
        yq = shutil.which("yq")
        if not yq:
            raise CheckError("%s is YAML and yq is not on PATH" % path)
        proc = subprocess.run([yq, "-o=json", "."], input=text,
                              capture_output=True, text=True)
        if proc.returncode != 0:
            raise CheckError("%s could not be parsed: %s"
                             % (path, " ".join((proc.stderr or "").split())[:160]))
        try:
            doc = json.loads(proc.stdout)
        except ValueError:
            raise CheckError("%s does not convert to one JSON document" % path)
    data = (doc.get("data") if isinstance(doc, dict) else None) or {}
    found = []
    for key, value in data.items():
        if not str(key).endswith(".json"):
            continue
        if isinstance(value, dict):
            found.append((key, value))
            continue
        try:
            found.append((key, json.loads(value)))
        except ValueError:
            raise CheckError("%s data key %s is not JSON" % (path, key))
    if not found:
        raise CheckError("%s carries no .json dashboard" % path)
    return found


def iter_panels(dash):
    stack = list(dash.get("panels") or [])
    while stack:
        panel = stack.pop(0)
        if not isinstance(panel, dict):
            continue
        yield panel
        stack = list(panel.get("panels") or []) + stack


def exprs(panel):
    found = []
    for target in panel.get("targets") or []:
        if not isinstance(target, dict):
            continue
        for key in ("expr", "query", "expression"):
            value = target.get(key)
            if isinstance(value, str) and value.strip():
                found.append(value.strip())
    return found


def label(panel):
    return '"%s"' % " ".join(str(panel.get("title") or "<untitled>").split())[:44]


def matchers(expr, name):
    """[(operator, literal)] for pod= / container= matchers in one PromQL expr."""
    pattern = re.compile(r'\b%s\s*(=~|!~|!=|=)\s*"([^"]*)"' % re.escape(name))
    return [(op, value) for op, value in pattern.findall(expr)]


def fullmatches(expr, name, sample):
    """True when one *selecting* (non-negated) matcher for `name` matches `sample`."""
    for op, value in matchers(expr, name):
        if op in ("!=", "!~"):
            continue
        pattern = value if op == "=~" else re.escape(value)
        if re.fullmatch(pattern, sample):
            return True
    return False


def short(expr, limit=80):
    text = " ".join(expr.split())
    return text if len(text) <= limit else text[:limit - 3] + "..."


def titled(dash, pattern):
    return [panel for panel in iter_panels(dash)
            if panel.get("type") not in ("row", "text", None)
            and re.search(pattern, str(panel.get("title") or ""), re.I)]


# ---------------------------------------------------------------------------
def ac4(reasons):
    """The prometheus CPU and memory panels select the pod that exists."""
    docs = load_dashboards(OBS)
    cpu = []
    memory = []
    for key, dash in docs:
        cpu.extend(titled(dash, r"\bprometheus\s+cpu\b"))
        memory.extend(titled(dash, r"\bprometheus\s+memory\b"))
    if not cpu:
        reasons.append('%s has no "prometheus CPU" panel' % os.path.basename(OBS))
    if not memory:
        reasons.append('%s has no "prometheus memory" panel' % os.path.basename(OBS))

    total = 0
    wrong = []
    for panels in (cpu, memory):
        for panel in panels:
            panel_exprs = exprs(panel)
            if len(panel_exprs) < 3:
                reasons.append("%s carries %d target(s), the usage/request/limit trio "
                               "is expected" % (label(panel), len(panel_exprs)))
            for expr in panel_exprs:
                total += 1
                if not fullmatches(expr, "pod", PROM_POD):
                    wrong.append(expr)
    if total and total != PROM_TARGETS:
        reasons.append("%d targets across the prometheus CPU and memory panels, expected "
                       "%d (three per panel)" % (total, PROM_TARGETS))
    if wrong:
        reasons.append('%d of %d prometheus CPU/memory targets do not select pod=~"%s.*", '
                       'which %s matches, e.g. %s'
                       % (len(wrong), total, PROM_PREFIX, PROM_POD, short(wrong[0])))

    stale = []
    for _key, dash in docs:
        for panel in iter_panels(dash):
            for expr in exprs(panel):
                if 'pod=~"%s' % PROM_OLD_PREFIX in expr:
                    stale.append(expr)
    if stale:
        reasons.append('%d expr(s) still select the pod prefix "%s", which matches no '
                       'pod (the real pod is %s), e.g. %s'
                       % (len(stale), PROM_OLD_PREFIX, PROM_POD, short(stale[0])))

    if not reasons:
        return "targets=%d pod=%s" % (total, PROM_POD)
    return "targets=%d wrong=%d stale=%d" % (total, len(wrong), len(stale))


# ---------------------------------------------------------------------------
def ac5(reasons):
    """The CPU panel says the empty limit series is expected, not a defect."""
    docs = load_dashboards(OBS)
    cpu = []
    for key, dash in docs:
        cpu.extend(titled(dash, r"\bprometheus\s+cpu\b"))
    if not cpu:
        reasons.append('%s has no "prometheus CPU" panel' % os.path.basename(OBS))
    for panel in cpu:
        description = " ".join(str(panel.get("description") or "").split()).lower()
        if not description:
            reasons.append("%s has no description" % label(panel))
            continue
        if "limit" not in description:
            reasons.append("%s description does not mention the CPU limit at all: %r"
                           % (label(panel), description[:120]))
            continue
        absent = re.search(r"\b(no|not|never|without|unset|absent|does not set|sets no)\b",
                           description)
        expected = re.search(r"\b(empty|blank|expected|not a defect|rather than)\b",
                             description)
        if not absent:
            reasons.append("%s description does not record that the pod sets no CPU "
                           "limit: %r" % (label(panel), description[:160]))
        if not expected:
            reasons.append("%s description does not record that an empty limit series is "
                           "expected: %r" % (label(panel), description[:160]))
    if not reasons:
        return "description=documented"
    return "panels=%d" % len(cpu)


# ---------------------------------------------------------------------------
def ac6(reasons):
    """syncthing is a container of the web pod, and the web panels exclude it."""
    deployment = read(OC_DEPLOY) if os.path.isfile(OC_DEPLOY) else ""
    if not os.path.isfile(OC_DEPLOY):
        reasons.append("%s is missing, so the syncthing container cannot be placed" % OC_DEPLOY)
    elif not re.search(r"^\s*-\s*name:\s*syncthing\s*$", deployment, re.M):
        reasons.append("%s declares no container named syncthing, so the dashboard's "
                       "selectors would point at nothing" % OC_DEPLOY)
    invented = []
    for path in sorted(glob.glob(OC_DIR + "*.yaml")):
        text = read(path)
        if not re.search(r"^kind:\s*(Deployment|StatefulSet|DaemonSet)\s*$", text, re.M):
            continue
        if re.search(r"^\s+name:\s*openchamber-syncthing\s*$", text, re.M):
            invented.append(path)
    if invented:
        reasons.append("%s defines an openchamber-syncthing workload, so the pod-level "
                       "selector would be right and the container selector wrong"
                       % ", ".join(os.path.basename(p) for p in invented[:2]))

    docs = load_dashboards(OC)
    sync_panels = []
    web_panels = []
    for key, dash in docs:
        sync_panels.extend([(key, panel) for panel in titled(dash, r"syncthing")])
        web_panels.extend([(key, panel) for panel in titled(dash, r"openchamber\s+web\s+(cpu|memory)")])
    if not sync_panels:
        reasons.append('%s has no "syncthing" panel' % os.path.basename(OC))
    if not web_panels:
        reasons.append('%s has no "openchamber web CPU/memory" panel' % os.path.basename(OC))

    no_web_pod = []
    no_container = []
    sync_targets = 0
    for _key, panel in sync_panels:
        for expr in exprs(panel):
            sync_targets += 1
            if not fullmatches(expr, "pod", OC_WEB_POD):
                no_web_pod.append(expr)
            if not any(op == "=" and value == "syncthing"
                       for op, value in matchers(expr, "container")):
                no_container.append(expr)
    if no_web_pod:
        reasons.append('%d of %d syncthing targets do not select the web pod '
                       '(pod=~"openchamber.*", which %s matches), e.g. %s - the '
                       'syncthing container runs inside it, there is no separate pod'
                       % (len(no_web_pod), sync_targets, OC_WEB_POD, short(no_web_pod[0])))
    if no_container:
        reasons.append('%d of %d syncthing targets do not select container="syncthing", '
                       'e.g. %s' % (len(no_container), sync_targets, short(no_container[0])))

    double = []
    web_targets = 0
    for _key, panel in web_panels:
        for expr in exprs(panel):
            web_targets += 1
            excluded = any(op in ("!=", "!~") and "syncthing" in value
                           for op, value in matchers(expr, "container"))
            if not excluded:
                double.append(expr)
    if double:
        reasons.append('%d of %d openchamber web CPU/memory targets do not exclude '
                       'container="syncthing", so the sidecar is counted into the web '
                       'totals as well as its own panels, e.g. %s'
                       % (len(double), web_targets, short(double[0])))

    if not reasons:
        return "syncthing_targets=%d web_targets=%d" % (sync_targets, web_targets)
    return "sync_empty=%d sync_nocontainer=%d web_double=%d" % (
        len(no_web_pod), len(no_container), len(double))


CHECKS = {"4": ac4, "5": ac5, "6": ac6}

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
        if len(detail) > 320:
            detail = detail[:317] + "..."
        print("AC-%s: FAIL %s" % (ac, detail))
    else:
        print("AC-%s: PASS (%s)" % (ac, summary))

sys.exit(1 if failed else 0)
PY
