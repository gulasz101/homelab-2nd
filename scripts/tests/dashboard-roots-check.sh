#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-2166 (WO-4B fix, red half): a dashboard ConfigMap only reaches the cluster
# if the ROOT kustomization reaches it.
#
# Flux reconciles `apps/kustomization.yaml` (clusters/*/apps.yaml points at that
# directory), so a ConfigMap that the root does not include is never applied -
# however correct the file itself is. WO-4B found exactly that: karakeep was
# enumerated file-by-file in the root kustomization and `apps/karakeep/` got a
# nested kustomization of its own (GUL-1600) that the root never referenced, so
# `karakeep-dashboard-configmap.yaml` rendered nowhere while the other 28
# dashboards arrived. 28 of 29 dashboards were reachable; the karakeep one was
# not, and it was the only one.
#
# The standard dashboard check (scripts/tests/dashboard-standard-check.sh)
# missed it because its AC-2 trusted each app's own kustomization.yaml instead
# of walking from the root: `apps/karakeep/kustomization.yaml` lists the
# dashboard, so it looked applied.
#
#   AC-1: apps/kustomization.yaml reaches apps/karakeep/kustomization.yaml and
#         `kubectl kustomize apps` renders the karakeep-dashboard ConfigMap.
#   AC-2: no *-dashboard-configmap.yaml under apps/ is orphaned from
#         apps/kustomization.yaml, and the standard dashboard check walks from
#         the root kustomization - proved by breaking the root in a throwaway
#         copy of the tree and requiring the standard check to notice.
#
# Reads only files in the worktree, plus `kubectl kustomize` when kubectl is on
# PATH (CI pins kubectl v1.37.1; the Air has the same major version). Nothing
# is written into the repo: the AC-2 probe copies apps/, infrastructure/ and
# scripts/ into a mktemp directory and mutates the copy.
#
# Usage: bash scripts/tests/dashboard-roots-check.sh          run AC-1 and AC-2
#        bash scripts/tests/dashboard-roots-check.sh --ac 2   run AC-2 only
# Exit:  0 = every requested AC passed, 1 = at least one failed,
#        2 = usage error.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT" || exit 2
SELF="$ROOT/scripts/tests/dashboard-roots-check.sh"
ALL_ACS=(1 2)

usage() {
  printf 'usage: bash scripts/tests/dashboard-roots-check.sh [--ac N]\n' >&2
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
      printf 'dashboard-roots-check: unknown argument %s\n' "$1" >&2
      usage; exit 2 ;;
  esac
done
if [ "${#want[@]}" -eq 0 ]; then
  want=("${ALL_ACS[@]}")
fi
for ac in "${want[@]}"; do
  case " ${ALL_ACS[*]} " in
    *" $ac "*) ;;
    *) printf 'dashboard-roots-check: no such check --ac %s\n' "$ac" >&2; usage; exit 2 ;;
  esac
done

python3 -I - "${want[@]}" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

WANT = sys.argv[1:]
ROOT_KS = "apps/kustomization.yaml"
KARA_KS = "apps/karakeep/kustomization.yaml"
KARA_DASH = "apps/karakeep/karakeep-dashboard-configmap.yaml"
KARA_CM = "karakeep-dashboard"
DASHBOARD_SUFFIX = "dashboard-configmap.yaml"
TEST_SEGMENTS = ("tests", "test", "__pycache__")
SKIP_DIRS = (".git", "node_modules", ".venv", "__pycache__")
PROBE_DIRS = ("apps", "infrastructure", "scripts")
STANDARD_CHECK = "scripts/tests/dashboard-standard-check.sh"


class CheckError(Exception):
    """A fact the check could not establish; reported as that AC's FAIL."""


def read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def write(path, text):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def normalize(path):
    path = path.strip()
    while path.startswith("./"):
        path = path[2:]
    return os.path.normpath(path).replace(os.sep, "/")


def resources(path):
    """The `resources:` list of one kustomization.yaml (block or flow style)."""
    items = []
    in_resources = False
    for raw in read(path).splitlines():
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
        if not token or "://" in token or token.startswith("git@"):
            continue
        items.append(token)
    return items


def root_reach():
    """Every kustomization and every manifest reachable from apps/kustomization.yaml."""
    if not os.path.isfile(ROOT_KS):
        raise CheckError("%s is missing, so Flux has no app tree to reconcile" % ROOT_KS)
    kustomizations = set()
    files = set()
    queue = [ROOT_KS]
    while queue:
        current = normalize(queue.pop())
        if current in kustomizations:
            continue
        if not os.path.isfile(current):
            raise CheckError("the root render includes %s, which does not exist" % current)
        kustomizations.add(current)
        base = os.path.dirname(current)
        for item in resources(current):
            target = normalize(os.path.join(base, item))
            if os.path.isdir(target):
                nested = normalize(os.path.join(target, "kustomization.yaml"))
                if os.path.isfile(nested):
                    queue.append(nested)
                    continue
                for dirpath, dirnames, filenames in os.walk(target):
                    dirnames[:] = sorted(dirnames)
                    for name in filenames:
                        files.add(normalize(os.path.join(dirpath, name)))
                continue
            if os.path.basename(target) == "kustomization.yaml":
                queue.append(target)
            else:
                files.add(target)
    return kustomizations, files


def app_dashboards():
    """Every *-dashboard-configmap.yaml under apps/, test fixtures excepted."""
    found = []
    for dirpath, dirnames, filenames in os.walk("apps"):
        dirnames[:] = sorted(d for d in dirnames
                             if d not in SKIP_DIRS and d not in TEST_SEGMENTS)
        for name in filenames:
            if name.endswith(DASHBOARD_SUFFIX):
                found.append(normalize(os.path.join(dirpath, name)))
    return sorted(found)


def rendered_by_kubectl():
    """The `kubectl kustomize apps` output, or None when kubectl is absent."""
    kubectl = shutil.which("kubectl")
    if not kubectl:
        return None
    proc = subprocess.run([kubectl, "kustomize", "apps"], capture_output=True, text=True)
    if proc.returncode != 0:
        detail = " ".join((proc.stderr or proc.stdout or "").split())
        raise CheckError("`kubectl kustomize apps` exited %d: %s"
                         % (proc.returncode, detail[:200] or "no output"))
    return proc.stdout


# ---------------------------------------------------------------------------
def ac1(reasons):
    """karakeep is a nested kustomization of the root, and its dashboard renders."""
    kustomizations, files = root_reach()
    if KARA_KS not in kustomizations:
        reasons.append(
            "%s is not reachable from %s: the karakeep directory is enumerated "
            "file-by-file in the root kustomization instead of being included as a "
            "nested kustomization" % (KARA_KS, ROOT_KS))
    if KARA_DASH not in files:
        reasons.append(
            "%s is not part of the root render, so Flux never applies the karakeep "
            "dashboard (expected it reached through %s)" % (KARA_DASH, KARA_KS))
    rendered = rendered_by_kubectl()
    if rendered is not None:
        documents = [doc for doc in re.split(r"^---\s*$", rendered, flags=re.M)
                     if re.search(r"^kind:\s*ConfigMap\s*$", doc, re.M)]
        named = [doc for doc in documents
                 if re.search(r"^\s+name:\s*%s\s*$" % re.escape(KARA_CM), doc, re.M)]
        if not named:
            reasons.append(
                "`kubectl kustomize apps` renders %d ConfigMaps and 0 of them is %s "
                "(want 1)" % (len(documents), KARA_CM))
    if not reasons:
        return "nested=true kubectl=%s" % ("checked" if rendered is not None else "absent")
    return "nested=%s reachable=%s" % (KARA_KS in kustomizations, KARA_DASH in files)


# ---------------------------------------------------------------------------
def ac2(reasons):
    """No orphaned app dashboard, and the standard check walks from the root."""
    kustomizations, files = root_reach()
    orphans = [path for path in app_dashboards() if path not in files]
    if orphans:
        reasons.append(
            "%d of %d *-dashboard-configmap.yaml under apps/ are orphaned from %s "
            "(not in the root render, so nothing applies them): %s"
            % (len(orphans), len(app_dashboards()), ROOT_KS, ", ".join(orphans[:3])))
    if not os.path.isfile(STANDARD_CHECK):
        reasons.append("%s is missing, so no check walks the root at all" % STANDARD_CHECK)
        return "orphans=%d" % len(orphans)

    work = tempfile.mkdtemp(prefix="dashboard-roots-")
    try:
        for name in PROBE_DIRS:
            if os.path.isdir(name):
                shutil.copytree(name, os.path.join(work, name),
                                ignore=shutil.ignore_patterns(*SKIP_DIRS))
        probe_std = os.path.join(work, STANDARD_CHECK)
        probe_ks = os.path.join(work, ROOT_KS)
        if not (os.path.isfile(probe_std) and os.path.isfile(probe_ks)):
            reasons.append("the throwaway copy is missing %s or %s"
                           % (STANDARD_CHECK, ROOT_KS))
            return "orphans=%d" % len(orphans)
        original = read(probe_ks).splitlines()
        kept = [line for line in original
                if not re.match(r"^\s*-\s*karakeep(?:/|\s|$)", line)]
        if len(kept) == len(original):
            reasons.append("the probe could not orphan karakeep: %s lists no karakeep "
                           "resource to drop" % ROOT_KS)
            return "orphans=%d" % len(orphans)
        write(probe_ks, "\n".join(kept) + "\n")

        proc = subprocess.run(["bash", probe_std], cwd=work, capture_output=True, text=True)
        output = (proc.stdout or "") + (proc.stderr or "")
        named = "karakeep-dashboard-configmap.yaml" in output
        if proc.returncode == 0:
            reasons.append(
                "the standard dashboard check still trusts the nested file list: with "
                "karakeep dropped from %s in a throwaway copy it exited 0 instead of "
                "reporting %s as unreachable" % (ROOT_KS, KARA_DASH))
        elif not named:
            first = next((line for line in output.splitlines() if "FAIL" in line), "no FAIL line")
            reasons.append(
                "the standard dashboard check failed but never named "
                "karakeep-dashboard-configmap.yaml as unreachable from %s (first: %s)"
                % (ROOT_KS, " ".join(first.split())[:160]))
    finally:
        shutil.rmtree(work, ignore_errors=True)

    if not reasons:
        return "orphans=0 root-walk=proved"
    return "orphans=%d" % len(orphans)


CHECKS = {"1": ac1, "2": ac2}

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
