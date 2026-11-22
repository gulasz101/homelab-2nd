#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-1993 (red stage): every dashboard ConfigMap under apps/ is applied, and
# "applied" means reached from the ONE root kustomization Flux reconciles.
#
# The defect: apps/karakeep/kustomization.yaml exists (a nested kustomization
# that lists karakeep-dashboard-configmap.yaml), but apps/kustomization.yaml
# never references karakeep/ — it still enumerates karakeep's files flat, and
# the dashboard is not among them. So the file is on disk, listed by a
# kustomization nothing reaches, and Flux never applies it: the karakeep
# dashboard silently does not exist in Grafana.
#
# AC-1  apps/kustomization.yaml reaches apps/karakeep/kustomization.yaml, so
#       apps/karakeep/karakeep-dashboard-configmap.yaml is part of the root
#       render.
# AC-2  No *-dashboard-configmap.yaml under apps/ is orphaned from
#       apps/kustomization.yaml, AND scripts/tests/dashboard-standard-check.sh
#       walks from the root kustomization instead of trusting the nested file
#       list. The second half is proved behaviourally, not by grepping the
#       check: a copy of the tree in which the root stops referencing an app
#       (openchamber) must make the standard check FAIL. Today it does not: the
#       standard check reads apps/<app>/kustomization.yaml directly, so a
#       dashboard reachable from nothing is still reported as applied.
#
# Reads only files in the worktree, writes only into a temporary directory,
# touches no network.
#
# Usage: bash scripts/tests/dashboard-roots-check.sh
# Exit:  0 = both ACs pass, 1 = at least one fails.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT" || exit 1

python3 -I - <<'PY'
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT_KUSTOMIZATION = "apps/kustomization.yaml"
DASHBOARD_SUFFIX = "dashboard-configmap.yaml"
KARAKEEP_KUSTOMIZATION = "apps/karakeep/kustomization.yaml"
KARAKEEP_DASHBOARD = "apps/karakeep/karakeep-dashboard-configmap.yaml"
STANDARD_CHECK = "scripts/tests/dashboard-standard-check.sh"
# The app whose root reference the behavioural half of AC-2 removes.
PROBE_APP = "openchamber"
PROBE_DASHBOARD = "apps/openchamber/openchamber-dashboard-configmap.yaml"
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", "venv",
             ".mypy_cache", ".paperclip-repositories"}
TEST_SEGMENTS = {"tests", "test", "fixtures"}

reasons = {"AC-1": [], "AC-2": []}


def read_text(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def resources_of(path):
    """The `resources:` entries of one kustomization.yaml (block or flow style).

    Hand-parsed on purpose: neither the Air nor CI has PyYAML, and a check about
    reachability must not depend on a YAML library being installed.
    """
    items = []
    in_block = False
    for raw in read_text(path).splitlines():
        line = raw.split("#", 1)[0].rstrip()
        stripped = line.strip()
        if not stripped:
            continue
        indent = len(line) - len(line.lstrip())
        if indent == 0 and re.match(r"^[A-Za-z]", stripped):
            in_block = stripped.startswith("resources:")
            if in_block:
                rest = stripped[len("resources:"):].strip()
                if rest.startswith("["):
                    for token in rest.strip("[]").split(","):
                        token = token.strip().strip("\"'")
                        if token:
                            items.append(token)
            continue
        if not in_block or not stripped.startswith("- "):
            continue
        token = stripped[2:].strip().strip("\"'")
        if token:
            items.append(token)
    return items


def walk_from_root():
    """Every file reachable from apps/kustomization.yaml, following nested dirs."""
    reachable = set()
    seen = set()
    stack = [ROOT_KUSTOMIZATION]
    while stack:
        kfile = stack.pop()
        if kfile in seen:
            continue
        seen.add(kfile)
        reachable.add(kfile)
        if not os.path.isfile(kfile):
            continue
        base = os.path.dirname(kfile)
        for item in resources_of(kfile):
            if "://" in item or item.startswith("git@") or item.startswith("github.com/"):
                continue
            target = os.path.normpath(os.path.join(base, item)).replace(os.sep, "/")
            if item.endswith("/") or os.path.isdir(target):
                nested = os.path.normpath(os.path.join(target, "kustomization.yaml"))
                nested = nested.replace(os.sep, "/")
                if os.path.isfile(nested):
                    stack.append(nested)
                continue
            reachable.add(target)
    return reachable


def dashboard_files():
    """Every shipped dashboard ConfigMap under apps/, test fixtures excepted."""
    found = []
    for dirpath, dirnames, filenames in os.walk("apps"):
        dirnames[:] = sorted(d for d in dirnames
                             if d not in SKIP_DIRS and d not in TEST_SEGMENTS)
        for name in filenames:
            if name.endswith(DASHBOARD_SUFFIX):
                found.append(os.path.relpath(os.path.join(dirpath, name), os.getcwd())
                             .replace(os.sep, "/"))
    return sorted(found)


# --------------------------------------------------------------------------
# AC-1 — the karakeep dashboard is part of the root render
# --------------------------------------------------------------------------
def ac1(reachable):
    if not os.path.isfile(ROOT_KUSTOMIZATION):
        yield "%s is missing, so nothing under apps/ is reconciled" % ROOT_KUSTOMIZATION
        return
    if not os.path.isfile(KARAKEEP_KUSTOMIZATION):
        yield "%s is missing, so there is no nested karakeep kustomization to reach" % (
            KARAKEEP_KUSTOMIZATION)
    elif KARAKEEP_KUSTOMIZATION not in reachable:
        yield ("%s does not reach %s, so the karakeep file list is not applied as one "
               "group from the root" % (ROOT_KUSTOMIZATION, KARAKEEP_KUSTOMIZATION))
    if not os.path.isfile(KARAKEEP_DASHBOARD):
        yield "%s does not exist" % KARAKEEP_DASHBOARD
    elif KARAKEEP_DASHBOARD not in reachable:
        yield ("%s is not reachable from %s, so the karakeep dashboard ConfigMap is "
               "never applied by Flux and the dashboard does not exist in Grafana"
               % (KARAKEEP_DASHBOARD, ROOT_KUSTOMIZATION))


# --------------------------------------------------------------------------
# AC-2 — nothing orphaned, and the standard check walks from the root
# --------------------------------------------------------------------------
def copy_tree(destination):
    packed = subprocess.run(["tar", "-cf", "-", "--exclude=./.git", "."],
                            capture_output=True)
    if packed.returncode != 0:
        raise OSError("tar could not read the worktree: %s"
                      % packed.stderr.decode("utf-8", "replace")[:120])
    unpacked = subprocess.run(["tar", "-xf", "-", "-C", destination], input=packed.stdout,
                              capture_output=True)
    if unpacked.returncode != 0:
        raise OSError("tar could not unpack the copy: %s"
                      % unpacked.stderr.decode("utf-8", "replace")[:120])


def orphan_probe():
    """Does the standard check notice a dashboard the root no longer reaches?

    A copy of the tree with every openchamber reference deleted from
    apps/kustomization.yaml is exactly that shape: apps/openchamber/ is on disk,
    its own kustomization lists the dashboard, and the root applies none of it.
    A check that walks from the root reports the dashboard as unapplied; one
    that trusts apps/openchamber/kustomization.yaml stays green.
    """
    if not os.path.isfile(STANDARD_CHECK):
        yield "the standard dashboard check %s is missing" % STANDARD_CHECK
        return
    workdir = tempfile.mkdtemp(prefix="dashboard-roots-")
    try:
        copy_tree(workdir)
        root_file = os.path.join(workdir, ROOT_KUSTOMIZATION)
        lines = read_text(root_file).splitlines(keepends=True)
        kept, dropped = [], 0
        for line in lines:
            token = line.split("#", 1)[0].strip()
            if token.startswith("- ") and token[2:].strip().strip("\"'").startswith(
                    PROBE_APP + "/"):
                dropped += 1
                continue
            kept.append(line)
        if not dropped:
            yield ("%s references no %s/ entries, so this check cannot build the "
                   "orphan fixture it needs" % (ROOT_KUSTOMIZATION, PROBE_APP))
            return
        with open(root_file, "w", encoding="utf-8") as handle:
            handle.writelines(kept)
        try:
            run = subprocess.run(["bash", os.path.join(workdir, STANDARD_CHECK)],
                                 cwd=workdir, capture_output=True, text=True, timeout=900)
        except subprocess.TimeoutExpired:
            yield "%s did not finish within 900 s on the orphan fixture" % STANDARD_CHECK
            return
        output = run.stdout or ""
        mentions_probe = re.search(re.escape(PROBE_APP), output, re.I) is not None
        if run.returncode == 0:
            yield ("with every %s/ entry removed from %s the standard check "
                   "(dashboard-standard-check.sh) still exits 0: it trusts "
                   "apps/%s/kustomization.yaml instead of walking from the root, so a "
                   "dashboard reached by nothing is reported as applied"
                   % (PROBE_APP, ROOT_KUSTOMIZATION, PROBE_APP))
            return
        if not mentions_probe:
            yield ("the standard check fails on the orphan fixture (exit %d) without "
                   "reporting %s as unreachable from %s (it printed: %s)"
                   % (run.returncode, PROBE_DASHBOARD, ROOT_KUSTOMIZATION,
                      " | ".join(line.strip() for line in output.splitlines()[:2])[:160]))
    except OSError as exc:
        yield "could not build the orphan fixture: %s" % exc
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def ac2(reachable):
    if not os.path.isfile(ROOT_KUSTOMIZATION):
        yield "%s is missing, so reachability cannot be judged" % ROOT_KUSTOMIZATION
    else:
        files = dashboard_files()
        if not files:
            yield "no *%s found under apps/" % DASHBOARD_SUFFIX
        for path in files:
            if path not in reachable:
                yield ("%s is orphaned: no kustomization reachable from %s lists it, so "
                       "it is a file on disk that Flux never applies"
                       % (path, ROOT_KUSTOMIZATION))
    for reason in orphan_probe():
        yield reason


# --------------------------------------------------------------------------
# run
# --------------------------------------------------------------------------
try:
    reachable = walk_from_root()
except OSError as exc:
    reachable = None
    for ac in reasons:
        reasons[ac].append("could not read the kustomizations: %s" % exc)
if reachable is not None:
    reasons["AC-1"].extend(ac1(reachable))
    reasons["AC-2"].extend(ac2(reachable))

failed = 0
for ac in ("AC-1", "AC-2"):
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

sys.stderr.write("dashboard-roots-check: %d of 2 ACs fail\n" % failed)
sys.exit(1 if failed else 0)
PY
