#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-1598 (OTel work order 4a): one dashboard standard, one generator.
#
# 27 dashboards were built at different times by different models: three
# schemaVersion values, four refresh settings, mixed titles and tags,
# hardcoded Prometheus/Loki datasource UIDs, panels with no description and no
# unit, no links between dashboards, three near-empty dashboards (arr-stack,
# star-office, itsaplan) and two copies of the generator. This check is the
# standard written down as code (`docs/dashboards.md` is the prose half).
#
# It reads only files in the worktree, the manifest `scripts/dashboards/
# manifest.json` and the generator constant `SCHEMA_VERSION`; it renders
# nothing into the repo and touches no network.
#
#   AC-1: exactly one render_namespace_dashboard.py exists in the repo, and
#         scripts/render_dashboards.sh renders every manifest output into a
#         temporary directory byte-for-byte identical to the committed file.
#   AC-2: every *dashboard-configmap.yaml under apps/ and
#         infrastructure/auth/ is a manifest output, every manifest output
#         exists, and the manifest lists at least 20 dashboards.
#   AC-3: every dashboard in a manifest output has title `<namespace> — ...`,
#         tags homelab + namespace, refresh 30s, the generator's single
#         SCHEMA_VERSION, `datasource` and `loki` template variables, and the
#         homelab dashboards dropdown link.
#   AC-4: no panel (or target) hardcodes a datasource UID: every uid is a
#         ${variable} reference (or -- Mixed --), and neither of the old
#         Prometheus/Loki UIDs nor `tempo` appears as a uid anywhere.
#   AC-5: every non-row, non-text panel has a non-empty description and a
#         non-empty fieldConfig.defaults.unit.
#   AC-6: rows are Golden signals, Resources, Logs in that order, and
#         arr-stack, star-office and itsaplan carry at least 8 non-row panels.
#   AC-7: every ConfigMap labelled grafana_dashboard has data keys that are all
#         .json files, and every such value parses as dashboard JSON.
#
# Discovery: scripts/check.sh globs */tests/*-check.sh, so this runs in CI too;
# it lists no fixture files, it parses the dashboards that are in the tree.
#
# Usage: bash scripts/tests/dashboard-standard-check.sh
# Exit:  0 = all seven ACs pass, 1 = at least one fails.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT" || exit 1

# The whole check is one python3 -I program: no PyYAML on the Air or in CI, so
# ConfigMaps are read as JSON when they are JSON (the generator writes JSON)
# and through the yq v4.54.1 pinned in .github/workflows/check.yaml when they
# are YAML (arr-stack and whiteboard are today).
python3 -I - <<'PY'
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.getcwd()
MANIFEST = "scripts/dashboards/manifest.json"
GENERATOR = "scripts/render_namespace_dashboard.py"
RENDER = "scripts/render_dashboards.sh"
RAW_UID_LITERALS = ("PBFA97CFB590B2093", "P8E80F9AEF21F6940")
VARIABLE_UID = re.compile(r"^\$\{[A-Za-z0-9_:]+\}$")
ALLOWED_LITERAL_UIDS = ("-- Mixed --",)
THIN_DASHBOARDS = ("arr-stack", "star-office", "itsaplan")
ROW_ORDER = ("Golden signals", "Resources", "Logs")
MIN_MANIFEST_ENTRIES = 20
MIN_THIN_PANELS = 8
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", "venv", ".mypy_cache",
             ".paperclip-repositories"}

reasons = {("AC-%d" % n): [] for n in range(1, 8)}


class CheckError(Exception):
    """A fact the check could not establish; reported as that AC's FAIL."""


# --------------------------------------------------------------------------
# reading
# --------------------------------------------------------------------------
def load_doc(path):
    """ConfigMap file -> dict, JSON first, yq for the YAML-shaped ones."""
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
    """(entries, problems); an entry is {'path', 'namespace', 'raw'}."""
    if "value" in _manifest:
        return _manifest["value"]
    problems = []
    entries = []
    if not os.path.exists(MANIFEST):
        _manifest["value"] = ([], ["%s is missing" % MANIFEST])
        return _manifest["value"]
    try:
        raw = json.load(open(MANIFEST, encoding="utf-8"))
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
        entries.append({"path": path, "namespace": entry_namespace(item, path), "raw": item})
    _manifest["value"] = (entries, problems)
    return _manifest["value"]


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


def entry_namespace(item, path):
    if isinstance(item, dict):
        for key in ("namespace", "ns"):
            value = item.get(key)
            if isinstance(value, str) and value:
                return value.strip()
    if path.startswith("apps/"):
        return path.split("/")[1]
    if path.startswith("infrastructure/auth/"):
        return "auth"
    return None


def normalize(path):
    path = path.strip()
    while path.startswith("./"):
        path = path[2:]
    return os.path.normpath(path).replace(os.sep, "/")


def schema_version_constant():
    if not os.path.exists(GENERATOR):
        raise CheckError("%s is missing" % GENERATOR)
    source = open(GENERATOR, encoding="utf-8", errors="replace").read()
    match = re.search(r"^[ \t]*SCHEMA_VERSION[ \t]*=[ \t]*([0-9]+)[ \t]*$", source, re.M)
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


def all_dashboards():
    """Every dashboard document in every manifest output, plus manifest problems.

    A check that reads an empty set reports green over nothing (the same trap
    helmrelease-pin-check.sh guards against), so callers compare the count with
    MIN_MANIFEST_ENTRIES before judging.
    """
    entries, problems = manifest()
    pairs = []
    for entry in entries:
        for key, dash in dashboards_of(entry["path"]):
            pairs.append(("%s[%s]" % (entry["path"], key), entry["path"],
                          entry["namespace"], dash))
    return pairs, problems


def read_floor(pairs):
    if len(pairs) < MIN_MANIFEST_ENTRIES:
        return ["read %d dashboards; at least %d is expected, so this check "
                "refuses to judge an almost empty set" % (len(pairs), MIN_MANIFEST_ENTRIES)]
    return []


# --------------------------------------------------------------------------
# AC-1 — one generator, and re-rendering reproduces every generated file
# --------------------------------------------------------------------------
def ac1():
    found = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        if os.path.basename(GENERATOR) in filenames:
            found.append(os.path.relpath(os.path.join(dirpath, os.path.basename(GENERATOR)), ROOT))
    found.sort()
    if len(found) != 1:
        yield "%d copies of render_namespace_dashboard.py exist (%s), the standard allows one" % (
            len(found), ", ".join(found) or "none")
    elif found[0] != GENERATOR:
        yield "the only generator is %s, not %s" % (found[0], GENERATOR)

    entries, problems = manifest()
    for problem in problems:
        yield "manifest: %s" % problem
    if not entries:
        yield "nothing to render"
        return
    if not os.path.exists(RENDER):
        yield "%s is missing" % RENDER
        return

    outputs = [entry["path"] for entry in entries]
    workdir = tempfile.mkdtemp(prefix="dashboards-render-")
    try:
        produced = []
        errors = []
        for argv in (["--output-dir", workdir], ["--out-dir", workdir], [workdir]):
            for name in os.listdir(workdir):
                target = os.path.join(workdir, name)
                shutil.rmtree(target) if os.path.isdir(target) else os.remove(target)
            proc = subprocess.run(["bash", RENDER] + argv, cwd=ROOT, capture_output=True, text=True)
            produced = [path for path in outputs if locate(workdir, path)]
            if produced:
                break
            if proc.returncode != 0:
                errors.append("'%s' exited %d: %s" % (
                    " ".join(argv), proc.returncode,
                    (proc.stderr or proc.stdout).strip().splitlines()[-1:] or ""))
        if not produced:
            yield "%s wrote nothing into the output directory it was given (%s)" % (
                RENDER, "; ".join(errors[:2]) or "no files found")
            return
        for path in outputs:
            rendered = locate(workdir, path)
            if not rendered:
                yield "re-rendering produced no file for %s" % path
                continue
            if not os.path.exists(path):
                yield "re-rendering produced %s, which is not in the worktree" % path
                continue
            produced_bytes = open(rendered, "rb").read()
            committed_bytes = open(path, "rb").read()
            if produced_bytes != committed_bytes:
                yield "re-rendering changed %s (%d bytes rendered, %d committed)" % (
                    path, len(produced_bytes), len(committed_bytes))
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def locate(workdir, path):
    """Find the rendered file for a repo-relative output path in workdir."""
    for candidate in (os.path.join(workdir, path), os.path.join(workdir, os.path.basename(path))):
        if os.path.isfile(candidate):
            return candidate
    for dirpath, _dirnames, filenames in os.walk(workdir):
        if os.path.basename(path) in filenames:
            return os.path.join(dirpath, os.path.basename(path))
    return None


# --------------------------------------------------------------------------
# AC-2 — every app and auth dashboard is in the manifest
# --------------------------------------------------------------------------
def ac2():
    entries, problems = manifest()
    for problem in problems:
        yield "manifest: %s" % problem
    outputs = {entry["path"] for entry in entries}
    if len(entries) < MIN_MANIFEST_ENTRIES:
        yield "the manifest lists %d dashboards, the standard requires at least %d" % (
            len(entries), MIN_MANIFEST_ENTRIES)
    on_disk = sorted(glob.glob("apps/*/*dashboard-configmap.yaml") +
                     glob.glob("infrastructure/auth/*dashboard-configmap.yaml"))
    if not on_disk:
        yield "no *dashboard-configmap.yaml found under apps/ or infrastructure/auth/"
    for path in on_disk:
        if normalize(path) not in outputs:
            yield "%s is not a manifest output" % path
    for path in sorted(outputs):
        if not os.path.exists(path):
            yield "manifest output %s does not exist" % path


# --------------------------------------------------------------------------
# AC-3 — title, tags, refresh, schema, variables, links
# --------------------------------------------------------------------------
def ac3():
    pairs, problems = all_dashboards()
    for problem in problems:
        yield "manifest: %s" % problem
    for reason in read_floor(pairs):
        yield reason
    constant = None
    try:
        constant = schema_version_constant()
    except CheckError as exc:
        yield str(exc)
    for where, _path, namespace, dash in pairs:
        if not namespace:
            yield "%s: the manifest entry names no namespace and the path gives none" % where
            continue
        title = dash.get("title")
        if not isinstance(title, str) or not re.match(
                "^" + re.escape(namespace) + " \u2014 .+", title or ""):
            yield "%s: title %r does not match '%s \u2014 <What>'" % (where, title, namespace)
        tags = dash.get("tags") or []
        if not isinstance(tags, list) or "homelab" not in tags:
            yield "%s: tags %r lack 'homelab'" % (where, tags)
        if not isinstance(tags, list) or namespace not in tags:
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
# AC-4 — no panel hardcodes a datasource UID
# --------------------------------------------------------------------------
def ac4():
    pairs, problems = all_dashboards()
    for problem in problems:
        yield "manifest: %s" % problem
    for reason in read_floor(pairs):
        yield reason
    for where, _path, _namespace, dash in pairs:
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


# --------------------------------------------------------------------------
# AC-5 — every data panel has a description and a unit
# --------------------------------------------------------------------------
def ac5():
    pairs, problems = all_dashboards()
    for problem in problems:
        yield "manifest: %s" % problem
    for reason in read_floor(pairs):
        yield reason
    for where, _path, _namespace, dash in pairs:
        for panel in iter_panels(dash):
            if panel.get("type") in ("row", "text", None):
                continue
            description = panel.get("description")
            if not isinstance(description, str) or not description.strip():
                yield "%s %s has no description" % (where, panel_label(panel))
            unit = ((panel.get("fieldConfig") or {}).get("defaults") or {}).get("unit")
            if not isinstance(unit, str) or not unit.strip():
                yield "%s %s has no fieldConfig.defaults.unit" % (where, panel_label(panel))


# --------------------------------------------------------------------------
# AC-6 — row order, and the three thin dashboards rebuilt
# --------------------------------------------------------------------------
def ac6():
    pairs, problems = all_dashboards()
    for problem in problems:
        yield "manifest: %s" % problem
    for reason in read_floor(pairs):
        yield reason
    for where, _path, _namespace, dash in pairs:
        rows = [panel.get("title") for panel in dash.get("panels") or []
                if isinstance(panel, dict) and panel.get("type") == "row"]
        if len(rows) < len(ROW_ORDER):
            yield "%s has %d rows %r, the standard wants at least %d" % (
                where, len(rows), rows, len(ROW_ORDER))
        for index, wanted in enumerate(ROW_ORDER):
            if index < len(rows) and rows[index] != wanted:
                yield "%s: row %d is %r, the standard order is %r" % (
                    where, index + 1, rows[index], list(ROW_ORDER))
                break
    for name in THIN_DASHBOARDS:
        matched = [(where, dash) for where, path, namespace, dash in pairs
                   if namespace == name or ("/%s/" % name) in ("/" + path + "/")]
        if not matched:
            yield "%s has no manifest dashboard" % name
            continue
        for where, dash in matched:
            count = len([p for p in iter_panels(dash) if p.get("type") != "row"])
            if count < MIN_THIN_PANELS:
                yield "%s has %d non-row panels, rebuilt dashboards need at least %d" % (
                    where, count, MIN_THIN_PANELS)


# --------------------------------------------------------------------------
# AC-7 — dashboard ConfigMaps carry only dashboard JSON
# --------------------------------------------------------------------------
def ac7():
    paths = sorted(glob.glob("apps/*/*dashboard-configmap.yaml") +
                   glob.glob("infrastructure/auth/*dashboard-configmap.yaml"))
    entries, _problems = manifest()
    for entry in entries:
        if entry["path"] not in paths:
            paths.append(entry["path"])
    if not paths:
        yield "no dashboard ConfigMap found under apps/ or infrastructure/auth/"
    for path in paths:
        if not os.path.exists(path):
            continue
        cm = load_doc(path)
        metadata = cm.get("metadata") if isinstance(cm, dict) else None
        labels = (metadata or {}).get("labels") or {}
        if "grafana_dashboard" not in labels:
            continue
        data = cm.get("data") or {}
        if not isinstance(data, dict):
            yield "%s: data is not a map" % path
            continue
        for key, value in data.items():
            if not key.endswith(".json"):
                yield "%s carries the non-JSON data key %r" % (path, key)
                continue
            try:
                json.loads(value) if isinstance(value, str) else None
            except ValueError:
                yield "%s data key %r is not JSON" % (path, key)


# --------------------------------------------------------------------------
# run
# --------------------------------------------------------------------------
CHECKS = (("AC-1", ac1), ("AC-2", ac2), ("AC-3", ac3), ("AC-4", ac4),
          ("AC-5", ac5), ("AC-6", ac6), ("AC-7", ac7))

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
        if len(detail) > 300:
            detail = detail[:297] + "..."
        print("%s: FAIL %s" % (ac, detail))
    else:
        print("%s: PASS" % ac)

sys.stderr.write("dashboard-standard-check: %d of %d ACs fail\n" % (failed, len(CHECKS)))
sys.exit(1 if failed else 0)
PY
