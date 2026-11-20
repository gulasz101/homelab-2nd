#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-1600 (OTel work order 4b, red stage): the dashboard set is complete.
#
# WO-4a (GUL-1598) shipped the standard, the manifest and the one generator.
# It left the set incomplete: four dashboards of the observability stack itself
# (infrastructure/observability/dashboards/*-dashboard-configmap.yaml —
# kube-flux-overview, observability-overview, homelab-gpu-power,
# homelab-system-load) are still hand-maintained files that no render produces,
# four apps (karakeep, riffradar, openchamber, host-watch) have no dashboard at
# all, and nothing shows the telemetry pipeline itself — the collector can be
# refusing and queueing while every app dashboard is green.
#
# This check is the machine-readable half of that work order; the prose half is
# `docs/dashboards.md`. It reads only files in the worktree: the manifest
# `scripts/dashboards/manifest.json`, the generator constant `SCHEMA_VERSION`,
# the generated ConfigMaps and each app's own `kustomization.yaml`. It renders
# nothing into the repo and touches no network.
#
#   AC-1: every *dashboard-configmap.yaml under apps/ and infrastructure/ (test
#         directories excepted) is a manifest output, the manifest lists at
#         least 28 dashboards, and every dashboard document in the set obeys the
#         standard: title `<namespace> — ...`, tags homelab + namespace, refresh
#         30s, the generator's single SCHEMA_VERSION, `datasource` and `loki`
#         template variables, the homelab dashboards dropdown, rows Golden
#         signals / Resources / Logs in that order, a description and a
#         fieldConfig.defaults.unit on every data panel, and no hardcoded
#         datasource UID.
#   AC-2: karakeep, riffradar, openchamber and host-watch each ship a real
#         generated dashboard — a manifest output in apps/<app>/ with at least
#         eight non-row panels, every one of them querying that app's namespace —
#         and, where the app directory has a kustomization.yaml, it lists the new
#         file, so Flux applies it.
#   AC-3: the observability-overview dashboard is titled
#         `Observability — Pipeline health` and reads the collector's own
#         metrics: otelcol_receiver_accepted and otelcol_exporter_sent
#         (throughput), otelcol_exporter_send_failed (failures) and
#         otelcol_exporter_queue_size (queue fill).
#   AC-4: re-rendering still reproduces every generated file: exactly one
#         copy of the generator, `--list` agrees with the manifest, and a render
#         into a temporary directory is byte-for-byte identical to every
#         dashboard ConfigMap in the repo.
#
# One deliberate reading of the WO-4a standard: the "no hardcoded datasource
# UID" rule is not applied to the platform dashboards under
# infrastructure/observability/dashboards/. GUL-1596's
# infrastructure/observability/tests/signal-correlation-check.sh (AC-1) fails
# when the dashboards of the set pin no single Prometheus/Loki uid — "the
# dashboards query 0 prometheus uids, so there is no single uid to pin" — and
# that check is not in this work order's allowedPaths, so converting all four
# platform dashboards to ${datasource} would trade one red check for another.
# The app dashboards (the other 24 entries) must still use the variables.
#
# Discovery: scripts/check.sh globs */tests/*-check.sh, so this runs in CI too.
#
# Usage: bash scripts/tests/dashboard-standard-check.sh
# Exit:  0 = all four ACs pass, 1 = at least one fails.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT" || exit 1

# The whole check is one python3 -I program: no PyYAML on the Air or in CI, so
# ConfigMaps are read as JSON when they are JSON (the generator writes JSON)
# and through the yq v4.54.1 pinned in .github/workflows/check.yaml when they
# are YAML (the four hand-maintained platform dashboards are today).
python3 -I - <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

MANIFEST = "scripts/dashboards/manifest.json"
GENERATOR = "scripts/render_namespace_dashboard.py"
RENDER = "scripts/render_dashboards.sh"
DASHBOARD_SUFFIX = "dashboard-configmap.yaml"
PLATFORM_PREFIX = "infrastructure/observability/dashboards/"
APP_DASHBOARDS = ("karakeep", "riffradar", "openchamber", "host-watch")
MIN_MANIFEST_ENTRIES = 28
MIN_SET_DOCUMENTS = 28
MIN_APP_PANELS = 8
ROW_ORDER = ("Golden signals", "Resources", "Logs")
RAW_UID_LITERALS = ("PBFA97CFB590B2093", "P8E80F9AEF21F6940")
VARIABLE_UID = re.compile(r"^\$\{[A-Za-z0-9_:]+\}$")
ALLOWED_LITERAL_UIDS = ("-- Mixed --",)
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", "venv", ".mypy_cache",
             ".paperclip-repositories"}
TEST_SEGMENTS = {"tests", "test", "fixtures"}
# Metric families verified against the live Prometheus (GUL-1597): the collector
# is scraped on :8888 and its counters carry no Prometheus `_total` suffix.
PIPELINE_OUTPUT = ("infrastructure/observability/dashboards/"
                   "observability-overview-dashboard-configmap.yaml")
PIPELINE_TITLE = "Observability \u2014 Pipeline health"
PIPELINE_METRICS = (
    ("otelcol_receiver_accepted", "collector throughput in"),
    ("otelcol_exporter_sent", "collector throughput out"),
    ("otelcol_exporter_send_failed", "export failures"),
    ("otelcol_exporter_queue_size", "exporter queue fill"),
)

reasons = {("AC-%d" % n): [] for n in range(1, 5)}


class CheckError(Exception):
    """A fact the check could not establish; reported as that AC's FAIL."""


# --------------------------------------------------------------------------
# reading
# --------------------------------------------------------------------------
def read_text(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def load_doc(path):
    """ConfigMap file -> dict, JSON first, yq for the YAML-shaped ones."""
    text = read_text(path)
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


_dashboards = {}


def dashboards_of(path):
    """All Grafana dashboard documents carried by one ConfigMap file."""
    if path in _dashboards:
        return _dashboards[path]
    if not os.path.exists(path):
        raise CheckError("%s is listed in the manifest but does not exist" % path)
    cm = load_doc(path)
    data = cm.get("data") if isinstance(cm, dict) else None
    if not isinstance(data, dict) or not data:
        raise CheckError("%s has no ConfigMap data" % path)
    found = []
    for key, value in data.items():
        if not key.endswith(".json"):
            continue
        if isinstance(value, dict):
            found.append((key, value))
        else:
            try:
                found.append((key, json.loads(value)))
            except ValueError:
                raise CheckError("%s data key %s is not JSON" % (path, key))
    if not found:
        raise CheckError("%s has no .json dashboard key" % path)
    _dashboards[path] = found
    return found


_manifest = {}


def manifest():
    """(entries, problems); an entry is {'path', 'namespace', 'k8sNamespace', 'raw'}."""
    if "value" in _manifest:
        return _manifest["value"]
    problems = []
    entries = []
    if not os.path.exists(MANIFEST):
        _manifest["value"] = ([], ["%s is missing" % MANIFEST])
        return _manifest["value"]
    try:
        raw = json.loads(read_text(MANIFEST))
    except ValueError as exc:
        _manifest["value"] = ([], ["%s is not valid JSON: %s" % (MANIFEST, exc)])
        return _manifest["value"]
    listed = raw.get("dashboards") if isinstance(raw, dict) else raw
    if not isinstance(listed, list):
        _manifest["value"] = ([], ["%s has no dashboards list" % MANIFEST])
        return _manifest["value"]
    for index, item in enumerate(listed):
        try:
            path = normalize(entry_output(item))
        except CheckError as exc:
            problems.append("entry %d: %s" % (index, exc))
            continue
        namespace = entry_field(item, ("namespace", "ns"))
        if not namespace:
            namespace = default_namespace(path)
        entries.append({"path": path, "namespace": namespace,
                        "k8sNamespace": entry_field(item, ("k8sNamespace",)) or namespace,
                        "raw": item})
    _manifest["value"] = (entries, problems)
    return _manifest["value"]


def default_namespace(path):
    if path.startswith("apps/"):
        return path.split("/")[1]
    if path.startswith("infrastructure/auth/"):
        return "auth"
    if path.startswith("infrastructure/observability/"):
        return "observability"
    return None


OUTPUT_KEYS = ("output", "outputPath", "output_path", "path", "file", "filename",
               "configmap", "configMap")


def entry_output(item):
    if isinstance(item, str):
        return item
    if isinstance(item, dict):
        for key in OUTPUT_KEYS:
            value = item.get(key)
            if isinstance(value, str) and value:
                return value
    raise CheckError("no output path (expected one of %s)" % ", ".join(OUTPUT_KEYS))


def entry_field(item, keys):
    if isinstance(item, dict):
        for key in keys:
            value = item.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
    return None


def normalize(path):
    path = path.strip()
    while path.startswith("./"):
        path = path[2:]
    return os.path.normpath(path).replace(os.sep, "/")


def discover_dashboard_files():
    """Every dashboard ConfigMap in the repo, test directories excepted.

    A fixture under a `tests/` directory is not a dashboard that ships, so the
    walk skips those segments: this check must never demand that a fixture be a
    manifest output.
    """
    found = []
    for base in ("apps", "infrastructure"):
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames
                                 if d not in SKIP_DIRS and d not in TEST_SEGMENTS)
            for name in filenames:
                if name.endswith(DASHBOARD_SUFFIX):
                    found.append(os.path.relpath(os.path.join(dirpath, name), os.getcwd())
                                 .replace(os.sep, "/"))
    return sorted(found)


def schema_version_constant():
    if not os.path.exists(GENERATOR):
        raise CheckError("%s is missing" % GENERATOR)
    match = re.search(r"^[ \t]*SCHEMA_VERSION[ \t]*=[ \t]*([0-9]+)[ \t]*$",
                      read_text(GENERATOR), re.M)
    if not match:
        raise CheckError("%s defines no integer SCHEMA_VERSION constant" % GENERATOR)
    return int(match.group(1))


def iter_panels(dash):
    stack = list(dash.get("panels") or [])
    while stack:
        panel = stack.pop(0)
        if not isinstance(panel, dict):
            continue
        yield panel
        stack = list(panel.get("panels") or []) + stack


def iter_uid_values(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "uid" and isinstance(value, str):
                yield value
            else:
                for inner in iter_uid_values(value):
                    yield inner
    elif isinstance(node, list):
        for value in node:
            for inner in iter_uid_values(value):
                yield inner


def panel_label(panel):
    return "panel %s %r" % (panel.get("id", "?"), panel.get("title", ""))


def panel_exprs(panel):
    exprs = []
    for target in panel.get("targets") or []:
        if not isinstance(target, dict):
            continue
        for key in ("expr", "query", "expression"):
            value = target.get(key)
            if isinstance(value, str) and value.strip():
                exprs.append(value.strip())
    return exprs


def dashboard_exprs(dash):
    exprs = []
    for panel in iter_panels(dash):
        exprs.extend(panel_exprs(panel))
    return exprs


def data_panels(dash):
    return [panel for panel in iter_panels(dash)
            if panel.get("type") not in ("row", "text", None)]


def all_dashboards():
    """Every dashboard document in every manifest output, plus manifest problems."""
    entries, problems = manifest()
    pairs = []
    for entry in entries:
        if not os.path.exists(entry["path"]):
            continue
        for key, dash in dashboards_of(entry["path"]):
            pairs.append(("%s[%s]" % (entry["path"], key), entry["path"],
                          entry["namespace"], entry["k8sNamespace"], dash))
    return pairs, problems


def set_floor(pairs):
    if len(pairs) < MIN_SET_DOCUMENTS:
        return ["read %d dashboard documents; at least %d is expected, so this "
                "check refuses to judge an almost empty set" % (len(pairs), MIN_SET_DOCUMENTS)]
    return []


# --------------------------------------------------------------------------
# kustomize reachability — what Flux actually applies
# --------------------------------------------------------------------------
def kustomization_entries(path):
    """Resources listed by one kustomization.yaml (block or flow style)."""
    items = []
    in_resources = False
    for raw in read_text(path).splitlines():
        line = raw.split("#", 1)[0].rstrip()
        stripped = line.strip()
        if not stripped:
            continue
        indent = len(line) - len(line.lstrip())
        if indent == 0 and re.match(r"^[A-Za-z]", stripped):
            in_resources = stripped.startswith("resources:")
            if in_resources:
                rest = stripped[len("resources:"):].strip()
                if rest.startswith("["):
                    for token in rest.strip("[]").split(","):
                        token = token.strip().strip("\"'")
                        if token:
                            items.append(token)
            continue
        if not in_resources or not stripped.startswith("- "):
            continue
        token = stripped[2:].strip().strip("\"'")
        if not token or "://" in token or token.startswith("git@") or ":" in token:
            continue
        items.append(token)
    return items


# --------------------------------------------------------------------------
# the standard, one dashboard document at a time
# --------------------------------------------------------------------------
def standard_reasons(where, path, namespace, dash, constant):
    title = dash.get("title")
    if not namespace:
        yield "%s: the manifest entry names no namespace and the path gives none" % where
    elif not isinstance(title, str) or not re.match(
            "^" + re.escape(namespace) + " \u2014 .+", title or "", re.IGNORECASE):
        yield "%s: title %r does not match '%s \u2014 <What>'" % (where, title, namespace)
    tags = dash.get("tags") or []
    if not isinstance(tags, list) or "homelab" not in tags:
        yield "%s: tags %r lack 'homelab'" % (where, tags)
    if namespace and (not isinstance(tags, list) or not any(
            isinstance(tag, str) and tag.lower() == namespace.lower() for tag in tags)):
        yield "%s: tags %r lack the namespace %r" % (where, tags, namespace)
    if dash.get("refresh") != "30s":
        yield "%s: refresh is %r, the standard is '30s'" % (where, dash.get("refresh"))
    if constant is not None and dash.get("schemaVersion") != constant:
        yield "%s: schemaVersion is %r, the generator's SCHEMA_VERSION is %d" % (
            where, dash.get("schemaVersion"), constant)
    names = set()
    for variable in (dash.get("templating") or {}).get("list") or []:
        if isinstance(variable, dict) and isinstance(variable.get("name"), str):
            names.add(variable["name"])
    for wanted in ("datasource", "loki"):
        if wanted not in names:
            yield "%s: no %r template variable" % (where, wanted)
    if not has_homelab_link(dash):
        yield "%s: no dashboards link tagged 'homelab' with asDropdown true" % where
    rows = [panel.get("title") for panel in dash.get("panels") or []
            if isinstance(panel, dict) and panel.get("type") == "row"]
    if len(rows) < len(ROW_ORDER):
        yield "%s has %d rows %r, the standard wants at least %d" % (
            where, len(rows), rows, len(ROW_ORDER))
    else:
        for index, wanted in enumerate(ROW_ORDER):
            if rows[index] != wanted:
                yield "%s: row %d is %r, the standard order is %r" % (
                    where, index + 1, rows[index], list(ROW_ORDER))
                break
    for panel in iter_panels(dash):
        if panel.get("type") in ("row", "text", None):
            continue
        description = panel.get("description")
        if not isinstance(description, str) or not description.strip():
            yield "%s %s has no description" % (where, panel_label(panel))
        unit = ((panel.get("fieldConfig") or {}).get("defaults") or {}).get("unit")
        if not isinstance(unit, str) or not unit.strip():
            yield "%s %s has no fieldConfig.defaults.unit" % (where, panel_label(panel))
    if path.startswith(PLATFORM_PREFIX):
        return
    for panel in iter_panels(dash):
        label = panel_label(panel)
        for uid in iter_uid_values(panel):
            if uid in RAW_UID_LITERALS:
                yield "%s %s hardcodes datasource uid %s" % (where, label, uid)
            elif uid == "tempo":
                yield "%s %s hardcodes datasource uid 'tempo'" % (where, label)
            elif not VARIABLE_UID.match(uid) and uid not in ALLOWED_LITERAL_UIDS:
                yield "%s %s uses the raw datasource uid %r" % (where, label, uid)
        blob = json.dumps(panel, sort_keys=True)
        for literal in RAW_UID_LITERALS:
            if literal in blob:
                yield "%s %s contains the raw datasource uid %s" % (where, label, literal)


def has_homelab_link(dash):
    for link in dash.get("links") or []:
        if not isinstance(link, dict):
            continue
        tags = link.get("tags") or []
        if (link.get("type") == "dashboards" and isinstance(tags, list)
                and "homelab" in tags and link.get("asDropdown") is True):
            return True
    return False


# --------------------------------------------------------------------------
# AC-1 — every dashboard is in the manifest, and the whole set obeys the standard
# --------------------------------------------------------------------------
def ac1():
    entries, problems = manifest()
    for problem in problems:
        yield "manifest: %s" % problem
    listed = {entry["path"] for entry in entries}
    if len(entries) < MIN_MANIFEST_ENTRIES:
        yield ("the manifest lists %d dashboards; at least %d is expected, so this "
               "check refuses to judge an almost empty set" % (len(entries), MIN_MANIFEST_ENTRIES))
    on_disk = discover_dashboard_files()
    if not on_disk:
        yield "no *dashboard-configmap.yaml found under apps/ or infrastructure/"
    for path in on_disk:
        if path not in listed:
            yield ("%s is a dashboard in the repo but not a manifest output, so it is "
                   "maintained by hand and nothing enforces the standard on it" % path)
    for path in sorted(listed):
        if not os.path.exists(path):
            yield "manifest output %s does not exist" % path
    constant = None
    try:
        constant = schema_version_constant()
    except CheckError as exc:
        yield str(exc)
    pairs, problems = all_dashboards()
    for problem in problems:
        yield "manifest: %s" % problem
    for reason in set_floor(pairs):
        yield reason
    for where, path, namespace, _k8s, dash in pairs:
        for reason in standard_reasons(where, path, namespace, dash, constant):
            yield reason


# --------------------------------------------------------------------------
# AC-2 — the four missing app dashboards, and Flux applies them
# --------------------------------------------------------------------------
def ac2():
    entries, _problems = manifest()
    by_path = {entry["path"]: entry for entry in entries}
    on_disk = discover_dashboard_files()
    for app in APP_DASHBOARDS:
        candidates = [path for path in on_disk if path.startswith("apps/%s/" % app)]
        if not candidates:
            yield ("apps/%s/ carries no *dashboard-configmap.yaml, so %s has no "
                   "dashboard at all" % (app, app))
            continue
        kustomization = "apps/%s/kustomization.yaml" % app
        applied = None
        if os.path.isfile(kustomization):
            try:
                applied = {normalize(os.path.join("apps/%s" % app, item))
                           for item in kustomization_entries(kustomization)}
            except OSError:
                applied = None
        for path in candidates:
            entry = by_path.get(path)
            if entry is None:
                yield ("%s is not a manifest output, so it is a hand-written stub and "
                       "not a generated dashboard" % path)
            if applied is not None and path not in applied:
                yield ("%s/kustomization.yaml does not list %s, so Flux never applies it"
                       % ("apps/%s" % app, os.path.basename(path)))
            try:
                documents = dashboards_of(path)
            except CheckError as exc:
                yield str(exc)
                continue
            namespace = ((entry or {}).get("k8sNamespace")
                         or (entry or {}).get("namespace") or app)
            for key, dash in documents:
                where = "%s[%s]" % (path, key)
                non_row = [panel for panel in iter_panels(dash)
                           if panel.get("type") != "row"]
                if len(non_row) < MIN_APP_PANELS:
                    yield ("%s has %d non-row panels, a real dashboard needs at least %d"
                           % (where, len(non_row), MIN_APP_PANELS))
                empty = [panel_label(panel) for panel in data_panels(dash)
                         if not panel_exprs(panel)]
                if empty:
                    yield ("%s has %d panel(s) with no query at all (%s)"
                           % (where, len(empty), ", ".join(empty[:2])))
                exprs = dashboard_exprs(dash)
                markers = ('namespace="%s"' % namespace,
                           'namespace=~"%s' % namespace,
                           'k8s_namespace_name="%s"' % namespace)
                if not any(marker in expr for expr in exprs for marker in markers):
                    yield ("%s never selects the %r namespace: no panel query carries "
                           "namespace=\"%s\"" % (where, namespace, namespace))


# --------------------------------------------------------------------------
# AC-3 — the telemetry pipeline itself is on a dashboard
# --------------------------------------------------------------------------
def ac3():
    pairs, _problems = all_dashboards()
    documents = [(where, dash) for where, path, _ns, _k8s, dash in pairs
                 if path == PIPELINE_OUTPUT]
    if not documents:
        on_disk = [path for path in discover_dashboard_files()
                   if path.startswith(PLATFORM_PREFIX)]
        yield ("%s is not a manifest output (%d platform dashboard file(s) exist under "
               "%s), so the pipeline health dashboard is not part of the generated set"
               % (PIPELINE_OUTPUT, len(on_disk), PLATFORM_PREFIX))
        return
    for where, dash in documents:
        title = dash.get("title")
        if title != PIPELINE_TITLE:
            yield ("%s is titled %r, the pipeline health dashboard must be %r"
                   % (where, title, PIPELINE_TITLE))
            continue
        blob = "\n".join(dashboard_exprs(dash))
        missing = [(metric, label) for metric, label in PIPELINE_METRICS if metric not in blob]
        if missing:
            yield ("%s shows no %s: no panel query reads %s"
                   % (where, " and no ".join(label for _metric, label in missing),
                      ", ".join(metric for metric, _label in missing)))


# --------------------------------------------------------------------------
# AC-4 — re-rendering reproduces every generated file
# --------------------------------------------------------------------------
def generator_copies():
    found = []
    for dirpath, dirnames, filenames in os.walk(os.getcwd()):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        if os.path.basename(GENERATOR) in filenames:
            found.append(os.path.relpath(os.path.join(dirpath, os.path.basename(GENERATOR))))
    return sorted(path.replace(os.sep, "/") for path in found)


def ac4():
    copies = generator_copies()
    if len(copies) != 1:
        yield ("%d copies of render_namespace_dashboard.py exist (%s), the standard "
               "allows one" % (len(copies), ", ".join(copies) or "none"))
    elif copies[0] != GENERATOR:
        yield "the only generator is %s, not %s" % (copies[0], GENERATOR)
    entries, problems = manifest()
    for problem in problems:
        yield "manifest: %s" % problem
    outputs = [entry["path"] for entry in entries]
    on_disk = discover_dashboard_files()
    if not outputs:
        yield "the manifest lists nothing to render"
        return
    if not os.path.exists(RENDER):
        yield "%s is missing" % RENDER
        return

    proc = subprocess.run(["bash", RENDER, "--list"], capture_output=True, text=True)
    if proc.returncode != 0:
        yield ("'%s --list' exited %d: %s" % (
            RENDER, proc.returncode,
            (proc.stderr or proc.stdout).strip().splitlines()[-1:] or "no output"))
    else:
        printed = [line.strip() for line in proc.stdout.splitlines()
                   if line.strip().startswith(("apps/", "infrastructure/"))]
        listed_printed = sorted(normalize(line) for line in printed)
        if listed_printed != sorted(outputs):
            extra = sorted(set(listed_printed) - set(outputs))
            absent = sorted(set(outputs) - set(listed_printed))
            yield ("'%s --list' prints %d outputs, the manifest lists %d (prints but "
                   "not in the manifest: %s; in the manifest but not printed: %s)"
                   % (RENDER, len(listed_printed), len(outputs),
                      ", ".join(extra[:2]) or "none", ", ".join(absent[:2]) or "none"))

    workdir = tempfile.mkdtemp(prefix="dashboards-render-")
    try:
        proc = subprocess.run(["bash", RENDER, "--output-dir", workdir],
                              capture_output=True, text=True)
        rendered_any = False
        for path in outputs:
            if locate(workdir, path):
                rendered_any = True
                break
        if not rendered_any:
            yield ("'%s --output-dir <tmp>' wrote no manifest output (exit %d: %s)"
                   % (RENDER, proc.returncode,
                      (proc.stderr or proc.stdout).strip().splitlines()[-1:] or "no output"))
            return
        for path in outputs:
            rendered = locate(workdir, path)
            if not rendered:
                yield "re-rendering produced no file for the manifest output %s" % path
                continue
            if not os.path.exists(path):
                yield "re-rendering produced %s, which is not in the worktree" % path
                continue
            produced_bytes = open(rendered, "rb").read()
            committed_bytes = open(path, "rb").read()
            if produced_bytes != committed_bytes:
                yield ("re-rendering changed %s (%d bytes rendered, %d committed)"
                       % (path, len(produced_bytes), len(committed_bytes)))
        for path in on_disk:
            if path in outputs:
                continue
            if locate(workdir, path):
                yield ("re-rendering produces %s, but the manifest does not list it, so "
                       "the committed file and the manifest disagree" % path)
            else:
                yield ("re-rendering the manifest does not reproduce %s: it is not a "
                       "generated file" % path)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def locate(workdir, path):
    """Find the rendered file for a repo-relative output path in workdir."""
    candidate = os.path.join(workdir, path)
    if os.path.isfile(candidate):
        return candidate
    for dirpath, _dirnames, filenames in os.walk(workdir):
        if os.path.basename(path) in filenames:
            return os.path.join(dirpath, os.path.basename(path))
    return None


# --------------------------------------------------------------------------
# run
# --------------------------------------------------------------------------
CHECKS = (("AC-1", ac1), ("AC-2", ac2), ("AC-3", ac3), ("AC-4", ac4))

for ac, check in CHECKS:
    try:
        reasons[ac].extend(check())
    except CheckError as exc:
        reasons[ac].append(str(exc))
    except Exception as exc:  # noqa: BLE001 - never lose an AC line to a crash
        reasons[ac].append("check errored: %s: %s" % (type(exc).__name__, exc))

failed = 0
for ac, _check in CHECKS:
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

sys.stderr.write("dashboard-standard-check: %d of %d ACs fail\n" % (failed, len(CHECKS)))
sys.exit(1 if failed else 0)
PY
