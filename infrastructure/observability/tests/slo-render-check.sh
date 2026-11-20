#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Red/green check for the WO-5 SLO delivery gap (GUL-1825, follow-up to GUL-1599).
#
# GUL-1599 shipped the SLO PrometheusRule, its AlertmanagerConfig and the SLO
# dashboard as files, and the SLO check passed - because that check read the
# three files off disk. None of the three was ever listed in
# infrastructure/kustomization.yaml, so the kustomization never emitted them,
# Flux reported the Kustomization healthy, and the cluster got nothing.
#
# A check that greps a file proves the file exists, not that it is delivered.
# Every assertion here therefore runs against the OUTPUT OF THE RENDERER -
# `kubectl kustomize infrastructure` (or `kustomize build infrastructure`) from
# the repo root. The one thing read off disk is infrastructure/kustomization.yaml,
# whose text AC-2 has to judge: "exactly once" and "next to the other
# observability entries" are properties of the list, not of the render.
#
# A missing renderer is a FAIL, never a SKIP: both binaries are installed on the
# Air and CI installs one (pinned in .github/workflows/check.yaml), so a silent
# skip would hide exactly the blind spot this check exists to close.
#
#   bash infrastructure/observability/tests/slo-render-check.sh        # every AC
#   bash infrastructure/observability/tests/slo-render-check.sh --ac 3 # one AC
#
# One `AC-n: PASS|FAIL` line per AC on stdout (agents/factory/CONTRACT.md point
# 2); per-assertion detail goes to stderr so stdout stays parseable, and the
# first reason recorded for an AC is the one its line reports. Exit 0 only when
# every AC passes.
#
# Bash 3.2 compatible (the Air runs macOS bash): no `declare -A`, no `${x,,}`.
# No PyYAML either (the Air and CI system python3 have none), so the rendered
# stream is split into documents and matched with anchored regexes instead.
#
# SLO_RENDER_CHECK_ROOT points the check at another tree - only the AC-4
# self-test does that. SLO_RENDER_INNER stops the child runs at one level.
# ---------------------------------------------------------------------------
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="${SLO_RENDER_CHECK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$ROOT" || exit 1

KUST="infrastructure/kustomization.yaml"
OBS="infrastructure/observability"
# resources entries are written relative to infrastructure/, not to the repo root.
OBS_REL="observability"

# The three WO5 objects, as `<kind>/<name>`, and their resources entries relative
# to infrastructure/. Kept as literals so every FAIL line names the object, never
# "one object is missing".
WP_RULE="PrometheusRule/slo-recording-and-burn-rate"
WP_AM="AlertmanagerConfig/slo-mattermost-alerts"
WP_DASH="ConfigMap/slo-dashboard"
WP_OBJECTS=("$WP_RULE" "$WP_AM" "$WP_DASH")
WP_ENTRIES=(
  "observability/slo/slo-prometheus-rules.yaml"
  "observability/slo/slo-alertmanager-config.yaml"
  "observability/dashboards/slo-dashboard-configmap.yaml"
)
# The same three as one ERE, for AC-4's strip. Written out rather than built from
# WP_ENTRIES so a path with a regex metacharacter cannot silently widen the match.
WP_ENTRY_RE='^[[:space:]]*-[[:space:]]*(observability/slo/slo-prometheus-rules\.yaml|observability/slo/slo-alertmanager-config\.yaml|observability/dashboards/slo-dashboard-configmap\.yaml)[[:space:]]*$'

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Per-AC verdict. Index 1..4 so the arrays read like the AC ids; 0 is unused.
AC_FAIL=(0 0 0 0 0)
AC_WHY=("" "" "" "" "")

ok() { printf '  ok    %s\n' "$1" >&2; }

# fail_ac <n> <reason...> - the first reason wins, it is what the AC line reports.
fail_ac() {
  local n="$1"; shift
  if [ "${AC_FAIL[$n]}" -eq 0 ]; then AC_WHY[$n]="$*"; fi
  AC_FAIL[$n]=1
  printf '  FAIL  %s\n' "$*" >&2
}

# --- the renderer ----------------------------------------------------------
#
# Resolved once. kubectl first (it carries kustomize, and CI installs kubectl),
# the standalone binary second. Empty means no renderer at all.

RENDERER=""
if command -v kubectl > /dev/null 2>&1; then
  RENDERER="kubectl"
elif command -v kustomize > /dev/null 2>&1; then
  RENDERER="kustomize"
fi

renderer_version() {
  case "$RENDERER" in
    kubectl)   kubectl version --client 2>&1 | head -1 ;;
    kustomize) kustomize version 2>&1 | head -1 ;;
    *)         printf 'none\n' ;;
  esac
}

# render_tree <tree root> - print the rendered kustomization of <tree root>, which
# must contain infrastructure/. Always a real build from the root, so a manifest
# that is on disk but not listed simply is not in the output.
render_tree() {
  case "$RENDERER" in
    kubectl)   ( cd "$1" && kubectl kustomize infrastructure ) ;;
    kustomize) ( cd "$1" && kustomize build infrastructure ) ;;
    *)         return 127 ;;
  esac
}

# --- the identity assertion (shared by AC-3 and AC-4) ----------------------
#
# Reads a rendered stream and checks the three objects survive the build with
# their exact identity. Prints the missing ones (one per line) on stdout and the
# per-object detail on stderr; exits 0 only when all three are present and
# correct. AC-4 runs the very same program over a tampered tree, so the
# assertion cannot be "satisfied" by anything but the render.

CHECKER="$WORK/identity.py"
cat > "$CHECKER" <<'PY'
import re
import sys

WANT = (
    ("PrometheusRule", "slo-recording-and-burn-rate"),
    ("AlertmanagerConfig", "slo-mattermost-alerts"),
    ("ConfigMap", "slo-dashboard"),
)
NS = "observability"


def scalar(doc, key):
    m = re.search(r"(?m)^%s:[ \t]*(.*?)[ \t]*$" % re.escape(key), doc)
    return m.group(1) if m else ""


def metadata(doc):
    """metadata's own fields: the column-0 `metadata:` key, then 2-space keys."""
    out = {}
    lines = doc.splitlines()
    start = None
    for i, line in enumerate(lines):
        if re.match(r"^metadata:[ \t]*$", line):
            start = i
            break
    if start is None:
        return out
    for line in lines[start + 1:]:
        if re.match(r"^\S", line):
            break
        m = re.match(r"^  ([A-Za-z0-9_.-]+):[ \t]*(.*?)[ \t]*$", line)
        if m:
            out.setdefault(m.group(1), m.group(2).strip("\"'"))
    return out


def route_block(doc):
    """spec.route's own body, or None - the receivers: list is not part of it."""
    lines = doc.splitlines()
    for i, line in enumerate(lines):
        if re.match(r"^  route:[ \t]*$", line):
            body = []
            for nxt in lines[i + 1:]:
                if nxt.strip() == "":
                    continue
                if not nxt.startswith("    "):
                    break
                body.append(nxt)
            return body
    return None


def find(docs, kind, name):
    for doc in docs:
        if scalar(doc, "kind") != kind:
            continue
        md = metadata(doc)
        if md.get("name") == name:
            return doc, md
    return None, None


try:
    text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except OSError as exc:
    print("the render could not be read (%s)" % exc)
    sys.exit(1)

docs = re.split(r"(?m)^---[ \t]*$", text)

missing = []
found = []
for kind, name in WANT:
    ident = "%s/%s" % (kind, name)
    doc, md = find(docs, kind, name)
    if doc is None:
        missing.append("%s (not in the rendered kustomization)" % ident)
        continue
    if md.get("namespace") != NS:
        missing.append("%s (namespace %r, expected %r)"
                       % (ident, md.get("namespace"), NS))
        continue
    if kind == "AlertmanagerConfig":
        route = route_block(doc)
        if route is None:
            missing.append("%s (no spec.route)" % ident)
            continue
        body = "\n".join(route)
        problems = []
        if not re.search(r"(?m)^[ \t]+receiver:[ \t]*[\"']?slo-mattermost[\"']?[ \t]*$", body):
            problems.append("route receiver is not slo-mattermost")
        if not re.search(r"(?m)^[ \t]+-?[ \t]*name:[ \t]*[\"']?alertgroup[\"']?[ \t]*$", body):
            problems.append("no route matcher on alertgroup")
        if not re.search(r"(?m)^[ \t]+value:[ \t]*[\"']?slo[\"']?[ \t]*$", body):
            problems.append("the alertgroup matcher is not slo")
        if problems:
            missing.append("%s (%s)" % (ident, "; ".join(problems)))
            continue
    found.append("%s in namespace %s" % (ident, NS))

for line in found:
    sys.stderr.write("  ok    %s\n" % line)
for line in missing:
    sys.stderr.write("  FAIL  %s\n" % line)
if missing:
    print("; ".join(missing))
    sys.exit(1)
sys.exit(0)
PY

# assert_render <rendered file> - 0 when all three objects are there, 1 otherwise
# with the missing ones on stdout.
assert_render() { python3 -I "$CHECKER" "$1"; }

# --- kustomization.yaml helpers (AC-2 only) --------------------------------

# entry_index - every `- observability/...` resources entry as
# "<line><TAB><path relative to infrastructure/>", in file order.
entry_index() {
  [ -f "$KUST" ] || return 0
  awk -v prefix="$OBS_REL/" '
    /^[[:space:]]*-[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (index(line, prefix) == 1) printf "%d\t%s\n", NR, line
    }
  ' "$KUST"
}

# count_entry <path relative to infrastructure/> - how many entries name exactly it.
count_entry() {
  entry_index | awk -F'\t' -v p="$1" '$2 == p { c++ } END { print c + 0 }'
}

# entry_line <path relative to infrastructure/> - its first line number, empty when absent.
entry_line() {
  entry_index | awk -F'\t' -v p="$1" '$2 == p { print $1; exit }'
}

# --- AC-1: the check itself ------------------------------------------------

ac1() {
  printf '\n== AC-1: the check exists, compiles, is discovered, and reports per AC\n' >&2

  if [ -n "$RENDERER" ]; then
    ok "renderer available: $RENDERER ($(renderer_version))"
  else
    fail_ac 1 "neither kubectl nor kustomize is on PATH - a renderer is required and a missing tool is a FAIL, never a skip"
  fi

  if [ ! -f "$SELF" ]; then
    fail_ac 1 "slo-render-check.sh is missing"
    return 0
  fi
  if bash -n "$SELF" 2> "$WORK/n.log"; then
    ok "bash -n"
  else
    fail_ac 1 "bash -n fails: $(head -1 "$WORK/n.log")"
  fi

  # scripts/check.sh discovers every */tests/*-check.sh under infrastructure/, so
  # the name alone is the registration - prove it by listing, not by assuming.
  case "/$SELF" in
    */tests/*-check.sh) ok "filename matches */tests/*-check.sh" ;;
    *) fail_ac 1 "filename does not match */tests/*-check.sh, so scripts/check.sh will not discover it" ;;
  esac
  if [ -f "$ROOT/scripts/check.sh" ]; then
    if ( cd "$ROOT" && bash scripts/check.sh --list ) > "$WORK/list.log" 2>&1; then
      if grep -qF "$OBS/tests/slo-render-check.sh" "$WORK/list.log"; then
        ok "scripts/check.sh --list registers it with no edit to that file"
      else
        fail_ac 1 "scripts/check.sh --list does not register $OBS/tests/slo-render-check.sh"
      fi
    else
      fail_ac 1 "scripts/check.sh --list exited non-zero, so discovery cannot be confirmed"
    fi
  else
    fail_ac 1 "scripts/check.sh is missing, so discovery cannot be confirmed"
  fi

  # Provenance: the assertion must follow the render, not the disk. A minimal tree
  # whose kustomization emits one unrelated ConfigMap renders without any SLO
  # object, so the assertion has to FAIL there even though the three files still
  # sit in this checkout. This is the behaviour AC-4 leans on.
  mkdir -p "$WORK/provenance/infrastructure"
  cat > "$WORK/provenance/infrastructure/probe.yaml" <<'YAML'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: provenance-probe
  namespace: observability
data:
  probe: "1"
YAML
  cat > "$WORK/provenance/infrastructure/kustomization.yaml" <<'YAML'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - probe.yaml
YAML
  if [ -z "$RENDERER" ]; then
    fail_ac 1 "no renderer, so the render cannot be shown to drive the assertion"
  elif render_tree "$WORK/provenance" > "$WORK/provenance.yaml" 2> "$WORK/provenance.log"; then
    if ! grep -q 'name: provenance-probe' "$WORK/provenance.yaml"; then
      fail_ac 1 "the renderer did not emit the probe ConfigMap, so the render is not what is being asserted on"
    elif assert_render "$WORK/provenance.yaml" > "$WORK/provenance.out"; then
      fail_ac 1 "a render without the three SLO objects PASSES the identity assertion - it is not reading the render"
    else
      ok "the identity assertion is driven by the render: a tree without the manifests FAILs it"
    fi
  else
    fail_ac 1 "the renderer could not build a minimal tree: $(head -1 "$WORK/provenance.log")"
  fi

  # The protocol: no argument covers every AC, --ac N covers exactly one, and the
  # exit code follows from the AC lines. The child runs carry SLO_RENDER_INNER,
  # which is what stops the recursion - an inner run never spawns children.
  if [ -z "${SLO_RENDER_INNER:-}" ]; then
    if SLO_RENDER_INNER=1 bash "$SELF" > "$WORK/all.log" 2>&1; then
      missing=""
      for n in 1 2 3 4; do
        grep -qE "^AC-$n: PASS\$" "$WORK/all.log" || missing="$missing AC-$n"
      done
      if [ -z "$missing" ]; then
        ok "no argument runs every AC and exits 0"
      else
        fail_ac 1 "no argument exits 0 without a PASS line for:$missing"
      fi
    else
      fail_ac 1 "no argument exits non-zero on this tree: $(grep -m1 -E '^AC-[0-9]+: FAIL' "$WORK/all.log")"
    fi
    for n in 1 2 3 4; do
      SLO_RENDER_INNER=1 bash "$SELF" --ac "$n" > "$WORK/one.log" 2>&1
      got=$(grep -cE '^AC-[0-9]+: (PASS|FAIL)' "$WORK/one.log" || true)
      if [ "$got" -eq 1 ] && grep -qE "^AC-$n: (PASS|FAIL)" "$WORK/one.log"; then
        ok "--ac $n prints exactly one AC-$n line"
      else
        fail_ac 1 "--ac $n printed $got AC lines, expected exactly one AC-$n line"
      fi
    done
  fi
  return 0
}

# --- AC-2: the three entries in kustomization.yaml -------------------------

ac2() {
  printf '\n== AC-2: the three manifests are resources entries, once each, among the observability ones\n' >&2
  if [ ! -f "$KUST" ]; then
    fail_ac 2 "$KUST is missing"
    return 0
  fi

  # An entry before `resources:` or outside the observability block is not "next
  # to the other observability entries": the list would grow a second, parallel
  # region that the next reader (or the next kustomization) does not see.
  kust_res=$(grep -nE '^resources:[[:space:]]*$' "$KUST" | head -1 | cut -d: -f1)
  first_obs=$(grep -nE "^[[:space:]]*-[[:space:]]*$OBS_REL/" "$KUST" | head -1 | cut -d: -f1)
  last_obs=$(grep -nE "^[[:space:]]*-[[:space:]]*$OBS_REL/" "$KUST" | tail -1 | cut -d: -f1)

  for rel in "${WP_ENTRIES[@]}"; do
    n=$(count_entry "$rel")
    case "$n" in
      0)
        fail_ac 2 "$rel is not a resources entry in $KUST"
        ;;
      1)
        line=$(entry_line "$rel")
        if [ -z "$kust_res" ] || [ "$line" -lt "$kust_res" ]; then
          fail_ac 2 "$rel is listed before the resources: key (line $line)"
        elif [ -n "$first_obs" ] && { [ "$line" -lt "$first_obs" ] || [ "$line" -gt "$last_obs" ]; }; then
          fail_ac 2 "$rel is listed outside the observability block (line $line)"
        else
          ok "$rel listed once, among the observability entries (line $line)"
        fi
        ;;
      *)
        fail_ac 2 "$rel is listed $n times in $KUST, expected once"
        ;;
    esac
  done

  # The edit must not break the build - a dangling or duplicated entry leaves
  # Flux on the previous revision and the drift is invisible.
  if [ -z "$RENDERER" ]; then
    fail_ac 2 "no renderer on PATH, so 'the kustomization still builds' cannot be shown"
  elif render_tree "$ROOT" > "$WORK/ac2.yaml" 2> "$WORK/ac2.log"; then
    ok "the renderer still builds infrastructure/ ($(wc -l < "$WORK/ac2.yaml" | tr -d '[:space:]') rendered lines)"
  else
    fail_ac 2 "the renderer exits non-zero after the edit: $(head -1 "$WORK/ac2.log")"
  fi
  return 0
}

# --- AC-3: the rendered identity -------------------------------------------

ac3() {
  printf '\n== AC-3: the render carries the three WO5 objects with their exact identity\n' >&2
  if [ -z "$RENDERER" ]; then
    fail_ac 3 "no renderer on PATH, so the identity of the rendered objects cannot be shown"
    return 0
  fi
  if ! render_tree "$ROOT" > "$WORK/ac3.yaml" 2> "$WORK/ac3.log"; then
    fail_ac 3 "the renderer could not build $ROOT/infrastructure: $(head -1 "$WORK/ac3.log")"
    return 0
  fi
  if assert_render "$WORK/ac3.yaml" > "$WORK/ac3.missing"; then
    ok "rendered: $WP_RULE, $WP_AM (route slo-mattermost, matcher alertgroup=slo) and $WP_DASH, all in namespace observability"
  else
    fail_ac 3 "missing from the rendered kustomization: $(cat "$WORK/ac3.missing")"
  fi
  return 0
}

# --- AC-4: the assertion bites ---------------------------------------------

ac4() {
  printf '\n== AC-4: the assertion FAILs once the entries are stripped, and passes on the real tree\n' >&2
  if [ -z "$RENDERER" ]; then
    fail_ac 4 "no renderer on PATH, so the matching pair cannot be produced"
    return 0
  fi

  # Real half first: stripping entries from a tree that already lacks them proves
  # nothing, so the baseline has to be green before the tampered copy means
  # anything.
  real_ok=0
  if render_tree "$ROOT" > "$WORK/ac4-real.yaml" 2> "$WORK/ac4-real.log" \
     && assert_render "$WORK/ac4-real.yaml" > "$WORK/ac4-real.missing"; then
    real_ok=1
  fi

  if [ ! -f "$KUST" ]; then
    fail_ac 4 "$KUST is missing, so there is nothing to strip"
    return 0
  fi

  # A whole copy of infrastructure/, not just observability/: the kustomization
  # references cnpg/, auth/ and the rest, and a partial copy fails to build for a
  # reason that has nothing to do with the SLO entries.
  tmp="$WORK/stripped"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  if ! cp -R "$ROOT/infrastructure" "$tmp/infrastructure" 2> "$WORK/ac4-cp.log"; then
    fail_ac 4 "could not copy infrastructure/: $(head -1 "$WORK/ac4-cp.log")"
    return 0
  fi

  # Strip exactly the three entries, touching nothing else - the rest of the tree
  # is byte-identical, so any difference in the verdict comes from the render.
  grep -vE "$WP_ENTRY_RE" "$tmp/infrastructure/kustomization.yaml" > "$tmp/k.yaml" || true
  mv "$tmp/k.yaml" "$tmp/infrastructure/kustomization.yaml"

  stripped_ok=1
  if ! render_tree "$tmp" > "$WORK/ac4-stripped.yaml" 2> "$WORK/ac4-stripped.log"; then
    stripped_ok=0
    fail_ac 4 "the copy with the entries stripped no longer builds: $(head -1 "$WORK/ac4-stripped.log")"
  elif assert_render "$WORK/ac4-stripped.yaml" > "$WORK/ac4-stripped.missing"; then
    stripped_ok=0
  else
    named=0
    for want in "${WP_OBJECTS[@]}"; do
      grep -qF "$want" "$WORK/ac4-stripped.missing" && named=$((named + 1))
    done
    if [ "$named" -ne "${#WP_OBJECTS[@]}" ]; then
      stripped_ok=0
      fail_ac 4 "the tampered render FAILs but names only $named of ${#WP_OBJECTS[@]} objects: $(cat "$WORK/ac4-stripped.missing")"
    fi
  fi

  if [ "$real_ok" -eq 1 ] && [ "$stripped_ok" -eq 1 ]; then
    ok "the assertion passes on this tree and FAILs, naming all three objects, once the entries are stripped"
  elif [ "$real_ok" -ne 1 ]; then
    if [ "$stripped_ok" -eq 1 ]; then
      fail_ac 4 "this tree already FAILs the assertion, so the self-test proves nothing; the render is missing: $(cat "$WORK/ac4-real.missing")"
    fi
  else
    fail_ac 4 "a copy with the three entries stripped still PASSES the assertion - it is satisfied by YAML on disk, not by the render"
  fi
  return 0
}

# --- dispatch ---------------------------------------------------------------

only=""
case "${1:-}" in
  "") ;;
  --ac)
    only="${2:-}"
    case "$only" in
      1|2|3|4) ;;
      *) printf 'usage: %s [--ac 1|2|3|4]\n' "$(basename "$SELF")" >&2; exit 2 ;;
    esac
    ;;
  *) printf 'usage: %s [--ac 1|2|3|4]\n' "$(basename "$SELF")" >&2; exit 2 ;;
esac

if [ -z "$only" ] || [ "$only" = "1" ]; then ac1; fi
if [ -z "$only" ] || [ "$only" = "2" ]; then ac2; fi
if [ -z "$only" ] || [ "$only" = "3" ]; then ac3; fi
if [ -z "$only" ] || [ "$only" = "4" ]; then ac4; fi

printf '\n' >&2
rc=0
for n in 1 2 3 4; do
  if [ -n "$only" ] && [ "$only" != "$n" ]; then continue; fi
  if [ "${AC_FAIL[$n]}" -eq 1 ]; then
    printf 'AC-%s: FAIL %s\n' "$n" "${AC_WHY[$n]}"
    rc=1
  else
    printf 'AC-%s: PASS\n' "$n"
  fi
done
exit "$rc"
