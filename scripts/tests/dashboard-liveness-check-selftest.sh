#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-2205 selftest for scripts/tests/dashboard-liveness-check.sh.
#
# The liveness check reads the dashboards that happen to be in the tree, which
# makes it impossible to prove a *negative* against the real tree: GUL-1758 F-2
# and F-3 are the two rules that only a mutated tree can exercise.
#
#   --case f2   F-2: AC-3 must read the GPU board only. Copy the check's inputs
#               (manifest + every dashboard ConfigMap it globs) into a temp
#               tree, then remove every node_rapl_/node_hwmon_/node_thermal_
#               panel from the GPU board and leave every other dashboard alone.
#               `--ac 3` must then FAIL with the no-node-power/thermal reason
#               on that board. While AC-3 collects thermal exprs from the whole
#               tree, the apps/gpu-embedding board's node_hwmon_ exprs keep it
#               green and this case fails.
#
#   --case f3   F-3: AC-4 must accept job="omv-node". docs/dashboards.md says
#               node-exporter is scraped behind job="node-exporter" and static
#               targets behind job="omv-node", so a panel
#               node_load1{job="omv-node"} is live and must pass `--ac 4`;
#               node_load1{host="x"} is not on the series and must still fail.
#               While NODE_SELECTOR only knows job="node-exporter" and
#               instance=".*:9100", the omv-node panel fails this case.
#
# How the mutation stays honest: the check derives its root from its own path,
# so the whole input set is copied into a `mktemp -d` tree and the *copy* of the
# check is run there. Nothing outside the repo is read, no $HOME/~/hostname, so
# the Mac and CI (another root, HOME=/home/runner) get the same answer. Every
# case first runs the same tree unmutated and requires PASS, so a broken mirror
# reports "baseline" instead of looking like the rule under test.
#
# Usage: bash scripts/tests/dashboard-liveness-check-selftest.sh --case f2|f3
# Exit:  0 = the case proves the rule, 1 = it does not (or setup broke),
#        2 = usage error.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CHECK="$ROOT/scripts/tests/dashboard-liveness-check.sh"
MANIFEST="$ROOT/scripts/dashboards/manifest.json"
# The board AC-3 is about: read from the check itself so a renamed constant does
# not leave this selftest mutating a file nothing looks at.
GPU_BOARD=$(grep -o 'GPU_BOARD *= *"[^"]*"' "$CHECK" | head -n 1 | sed 's/.*"\(.*\)"/\1/')

TREES=""
OUT=""
RC=0
TREE=""

usage() {
  printf 'usage: bash scripts/tests/dashboard-liveness-check-selftest.sh --case f2|f3\n' >&2
  printf '  f2  AC-3 reads the GPU board only (node power/thermal removed there)\n' >&2
  printf '  f3  AC-4 accepts job="omv-node" and still rejects host="x"\n' >&2
}

note() { printf 'selftest: %s\n' "$*" >&2; }
die() { printf 'selftest: %s\n' "$*" >&2; exit 1; }

cleanup() {
  local tree
  for tree in $TREES; do
    rm -rf "$tree"
  done
}
trap cleanup EXIT

want=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --case)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      want+=("$2")
      shift 2
      ;;
    --case=*)
      want+=("${1#*=}")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'selftest: unknown argument %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done
if [ "${#want[@]}" -eq 0 ]; then
  want=(f2 f3)
fi
for name in "${want[@]}"; do
  case "$name" in
    f2|f3) ;;
    *)
      printf 'selftest: no such case %s\n' "$name" >&2
      usage
      exit 2
      ;;
  esac
done

[ -f "$CHECK" ] || die "$CHECK does not exist"
[ -f "$MANIFEST" ] || die "$MANIFEST does not exist"
[ -n "$GPU_BOARD" ] || die "cannot read GPU_BOARD from $CHECK"

# ---------------------------------------------------------------------------
# The temp tree: exactly the inputs the check's dashboards() globs, at their
# own repo-relative paths.
# ---------------------------------------------------------------------------
mirror() {  # $1 = destination root
  local dest=$1 rel file
  mkdir -p "$dest/scripts/tests" "$dest/scripts/dashboards" ||
    die "cannot create $dest/scripts"
  cp "$CHECK" "$dest/scripts/tests/dashboard-liveness-check.sh" ||
    die "cannot copy the check into $dest"
  cp "$MANIFEST" "$dest/scripts/dashboards/manifest.json" ||
    die "cannot copy the manifest into $dest"
  for file in "$ROOT"/apps/*/*dashboard-configmap.yaml; do
    [ -f "$file" ] || continue
    rel=${file#"$ROOT"/}
    mkdir -p "$dest/$(dirname "$rel")" || die "cannot create $(dirname "$rel") in $dest"
    cp "$file" "$dest/$rel" || die "cannot copy $rel into $dest"
  done
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    mkdir -p "$dest/$(dirname "$rel")" || die "cannot create $(dirname "$rel") in $dest"
    cp "$ROOT/$rel" "$dest/$rel" || die "cannot copy $rel into $dest"
  done < <(cd "$ROOT" && find infrastructure -type f -name '*dashboard-configmap*.yaml')
  [ -f "$dest/$GPU_BOARD" ] ||
    die "$GPU_BOARD is missing from the tree - cannot build the F-2/F-3 mutation"
}

new_tree() {
  TREE=$(mktemp -d) || die "mktemp -d failed"
  TREES="$TREES $TREE"
  mirror "$TREE"
}

run_ac() {  # $1 = tree, $2 = ac id; sets OUT and RC
  OUT=$(bash "$1/scripts/tests/dashboard-liveness-check.sh" --ac "$2" 2>&1)
  RC=$?
}

mutate() {  # $1 = mode, $2 = path to the GPU board copy
  python3 -I - "$1" "$2" <<'PY'
import json
import re
import shutil
import subprocess
import sys

MODE, PATH = sys.argv[1], sys.argv[2]
NODE_THERMAL = re.compile(r'node_rapl_|node_hwmon_|node_thermal_')
NODE_LOAD = re.compile(r'node_load1')
NEW_EXPR = {"f3-omv": 'node_load1{job="omv-node"}',
            "f3-host": 'node_load1{host="x"}'}


def load(path):
    """The ConfigMap file, as JSON or through the yq the check itself uses."""
    try:
        return json.load(open(path, encoding="utf-8"))
    except ValueError:
        pass
    yq = shutil.which("yq")
    if not yq:
        sys.exit("%s is YAML and yq is not on PATH" % path)
    proc = subprocess.run([yq, "-o=json", ".", path], capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit("%s could not be parsed: %s" % (path, proc.stderr.strip()[:120]))
    return json.loads(proc.stdout)


def walk(items):
    for panel in items or []:
        if not isinstance(panel, dict):
            continue
        yield panel
        for child in walk(panel.get("panels")):
            yield child


def exprs(panel):
    out = []
    for target in panel.get("targets") or []:
        if isinstance(target, dict):
            out.append(str(target.get("expr") or ""))
    return out


def prune(items, removed):
    kept = []
    for panel in items or []:
        if not isinstance(panel, dict):
            kept.append(panel)
            continue
        if any(NODE_THERMAL.search(expr) for expr in exprs(panel)):
            removed.append(str(panel.get("title") or ""))
            continue
        panel["panels"] = prune(panel.get("panels"), removed)
        kept.append(panel)
    return kept


cm = load(PATH)
data = cm.get("data") if isinstance(cm, dict) else None
if not isinstance(data, dict):
    sys.exit("the GPU board has no data block")

removed = []
changed = 0
for key, value in list(data.items()):
    if not key.endswith(".json"):
        continue
    doc = json.loads(value) if isinstance(value, str) else value
    if MODE == "f2-thermal":
        doc["panels"] = prune(doc.get("panels"), removed)
    else:
        for panel in walk(doc.get("panels")):
            for target in panel.get("targets") or []:
                if not isinstance(target, dict):
                    continue
                expr = str(target.get("expr") or "")
                if not NODE_LOAD.search(expr) or expr == NEW_EXPR[MODE]:
                    continue
                target["expr"] = NEW_EXPR[MODE]
                changed += 1
                break
            if changed:
                break
    data[key] = json.dumps(doc)

with open(PATH, "w", encoding="utf-8") as handle:
    json.dump(cm, handle, indent=2)
    handle.write("\n")

if MODE == "f2-thermal" and not removed:
    sys.exit("no node power/thermal panel was removed - the mutation proves nothing")
if MODE != "f2-thermal" and changed != 1:
    sys.exit("mutation rewrote %d node_load1 exprs (want 1)" % changed)
PY
}

baseline() {  # $1 = tree: the unmutated mirror must pass, or the case proves nothing
  local ac
  for ac in 3 4; do
    run_ac "$1" "$ac"
    [ "$RC" -eq 0 ] ||
      die "baseline: --ac $ac does not pass on an unmutated mirror (rc=$RC): $OUT"
    case "$OUT" in
      *"AC-$ac: PASS"*) ;;
      *) die "baseline: --ac $ac printed no PASS line: $OUT" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# F-2: AC-3 must judge the GPU board, not the whole tree.
# ---------------------------------------------------------------------------
case_f2() {
  new_tree
  baseline "$TREE"
  mutate f2-thermal "$TREE/$GPU_BOARD" ||
    die "cannot remove the node power/thermal panels from the GPU board copy"
  run_ac "$TREE" 3
  [ "$RC" -ne 0 ] ||
    die "F-2: --ac 3 PASSES after the GPU board lost every node_rapl_/node_hwmon_/" \
        "node_thermal_ expr - AC-3 still reads thermals from every other dashboard: $OUT"
  case "$OUT" in
    *"AC-3: FAIL"*) ;;
    *) die "F-2: --ac 3 did not report an AC-3 FAIL line: $OUT" ;;
  esac
  case "$OUT" in
    *"check errored"*|*"not valid JSON"*|*"carries no .json dashboard"*)
      die "F-2: --ac 3 failed while reading the mutated board, not on the rule: $OUT"
      ;;
  esac
  case "$OUT" in
    *"node power/thermal"*|*node_rapl_*|*node_hwmon_*|*node_thermal_*) ;;
    *) die "F-2: --ac 3 failed for another reason than the missing node power/thermal expr: $OUT" ;;
  esac
  note 'f2: PASS - --ac 3 fails when the GPU board alone loses its node power/thermal expr'
}

# ---------------------------------------------------------------------------
# F-3: AC-4 must accept job="omv-node" and still refuse a host= matcher.
# ---------------------------------------------------------------------------
case_f3() {
  new_tree
  baseline "$TREE"
  mutate f3-omv "$TREE/$GPU_BOARD" ||
    die "cannot rewrite a node_load1 expr to job=\"omv-node\" in the GPU board copy"
  run_ac "$TREE" 4
  [ "$RC" -eq 0 ] ||
    die 'F-3: --ac 4 rejects node_load1{job="omv-node"} - docs/dashboards.md says static' \
        "targets are scraped behind job=\"omv-node\", so that panel is live: $OUT"
  case "$OUT" in
    *"AC-4: PASS"*) ;;
    *) die "F-3: --ac 4 printed no AC-4 PASS line: $OUT" ;;
  esac

  new_tree
  baseline "$TREE"
  mutate f3-host "$TREE/$GPU_BOARD" ||
    die 'cannot rewrite a node_load1 expr to host="x" in the GPU board copy'
  run_ac "$TREE" 4
  [ "$RC" -ne 0 ] ||
    die 'F-3: --ac 4 accepts node_load1{host="x"} - a host= matcher is not on the' \
        "node-exporter series and leaves the panel empty: $OUT"
  case "$OUT" in
    *"AC-4: FAIL"*) ;;
    *) die "F-3: --ac 4 did not report an AC-4 FAIL line: $OUT" ;;
  esac
  case "$OUT" in
    *"host"*) ;;
    *) die "F-3: --ac 4 rejected host=\"x\" for another reason than the host= matcher: $OUT" ;;
  esac
  note 'f3: PASS - --ac 4 accepts job="omv-node" and still rejects host="x"'
}

status=0
for name in "${want[@]}"; do
  case "$name" in
    f2) case_f2 ;;
    f3) case_f3 ;;
  esac
done
exit "$status"
