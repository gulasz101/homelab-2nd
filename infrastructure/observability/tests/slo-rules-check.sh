#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Red/green check for the SLOs and burn-rate alerts (GUL-1599 WO-5, plan G7).
#
# Offline by construction: it reads the rule file, the AlertmanagerConfig, the
# dashboard ConfigMap, the dashboard manifest and docs/adr/README.md as text.
# PromQL is not schema-validatable anyway - what matters is that every series
# name, label and window the SRE workbook depends on is actually there, that
# each alert pairs a long window with a short one, and that the routing label
# the AlertmanagerConfig matches on is the label the rules carry.
#
# Method: Google SRE workbook, "Alerting on SLOs" - multi-window,
# multi-burn-rate. Error budget = 1 - target (99.5 % -> 0.005, 95 % -> 0.05).
#   page   burn rate > 14.4  over 1h  and 5m
#   page   burn rate >  6    over 6h  and 30m
#   ticket burn rate >  3    over 1d  and 2h
#   ticket burn rate >  1    over 3d  and 6h
#
# One `AC-n: PASS|FAIL` line per acceptance criterion on stdout (the factory
# protocol, agents/factory/CONTRACT.md point 2); per-assertion detail goes to
# stderr so stdout stays parseable. Exit 0 only when every AC passes.
#
# Structural greps use `^[[:space:]]*` because re-indenting the YAML must not
# break the check; PrometheusRule bodies are parsed per `- record:` / `- alert:`
# block instead of one global grep, so a label belonging to the wrong rule
# cannot pass for another (the trap otel-pipeline-alerts-check.sh documents).
#
# Bash 3.2 compatible (the Air runs macOS bash): no `declare -A`, no `${x,,}`.
#
# SLO_CHECK_ROOT points the check at another tree (self-test only). The spec's
# check command sets nothing, so it always reads this repo.
#
# Usage: bash infrastructure/observability/tests/slo-rules-check.sh
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="${SLO_CHECK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$ROOT" || exit 1

OBS="infrastructure/observability"
RULE_FILE="$OBS/slo/slo-prometheus-rules.yaml"
AM_FILE="$OBS/slo/slo-alertmanager-config.yaml"
DASH_FILE="$OBS/dashboards/slo-dashboard-configmap.yaml"
MANIFEST="scripts/dashboards/manifest.json"
ADR_INDEX="docs/adr/README.md"
ADR_GATE="docs/adr/tests/adr-check.sh"
AM_SECRET="homelab-node-mattermost-webhook-url"

# The 3 services, 2 SLIs and 7 windows of the spec. A service label is matched
# by regex, because `open-webui` / `openwebui` / `open_webui` are all the same
# workload and the dashboard UID already spells it two ways.
SVC_OPENWEBUI='open[-_]?webui'
SVC_HINDSIGHT='hindsight[-_]?api'
SVC_GRAFANA='grafana'
# shellcheck disable=SC2054  # regexes above are passed to awk/grep, not split
SERVICES=("$SVC_OPENWEBUI" "$SVC_HINDSIGHT" "$SVC_GRAFANA")
SERVICE_NAMES=(open-webui hindsight-api grafana)
SLIS=(availability latency)
WINDOWS=(5m 30m 1h 2h 6h 1d 3d)
N_COMBOS=$(( ${#SERVICES[@]} * ${#SLIS[@]} * ${#WINDOWS[@]} ))

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Per-AC verdict. Index 1..5 so the arrays read like the AC ids; 0 is unused.
AC_FAIL=(0 0 0 0 0 0)
AC_WHY=("" "" "" "" "" "")

ok() { printf '  ok    %s\n' "$1" >&2; }

# fail_ac <n> <reason...> - the first reason wins, it is what the AC line reports.
fail_ac() {
  local n="$1"; shift
  if [ "${AC_FAIL[$n]}" -eq 0 ]; then AC_WHY[$n]="$*"; fi
  AC_FAIL[$n]=1
  printf '  FAIL  %s\n' "$*" >&2
}

# req <n> <description> <command...> - the command must exit 0.
req() {
  local n="$1" desc="$2"; shift 2
  if "$@" > "$WORK/req.log" 2>&1; then ok "$desc"; else fail_ac "$n" "$desc"; fi
}

# --- parsing helpers -------------------------------------------------------

# label_val <file> <key> - first value of `<key>:` at any indent, unquoted.
label_val() {
  sed -n "s/^[[:space:]]*$2:[[:space:]]*//p" "$1" \
    | head -1 \
    | sed -e 's/[[:space:]]*$//' -e "s/^[\"']//" -e "s/[\"']$//"
}

# has_label <file> <key> <value> - the block declares exactly that key: value.
has_label() {
  [ "$(label_val "$1" "$2")" = "$3" ]
}

# flatten <file> - comments stripped and newlines folded to spaces, so a PromQL
# expression wrapped over several lines is matched as one string.
flatten() {
  sed -e 's/#.*$//' "$1" | tr '\n' ' ' | tr -s ' '
}

# split_blocks <file> <dir> <record|alert> - one file per `- name:` block.
split_blocks() {
  local mode="$1" file="$2" dir="$3"
  awk -v dir="$dir" -v mode="$mode" '
    $0 ~ "^[[:space:]]*-[[:space:]]*" mode ":[[:space:]]*" {
      if (f != "") close(f)
      name = $0
      sub("^[[:space:]]*-[[:space:]]*" mode ":[[:space:]]*", "", name)
      gsub(/["\047[:space:]]/, "", name)
      f = dir "/" name
      next
    }
    f != "" { print >> f }
  ' "$file"
}

# block_files <dir> - every parsed block, one path per line.
block_files() {
  local f
  for f in "$1"/*; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

# --- AC-1: 3 services x 2 SLIs x 7 windows of recording rules --------------

REC_DIR="$WORK/records"
mkdir -p "$REC_DIR"
REC_TSV="$WORK/records.tsv"
: > "$REC_TSV"
have_rules=0

if [ ! -f "$RULE_FILE" ]; then
  fail_ac 1 "$RULE_FILE missing"
  fail_ac 2 "$RULE_FILE missing"
  fail_ac 3 "$RULE_FILE missing"
else
  have_rules=1
  split_blocks record "$RULE_FILE" "$REC_DIR"
  # record<TAB>service<TAB>slo, one line per `- record:` block. Labels are only
  # collected inside the block, and the collection stops at the next record or
  # alert line, so an alert's labels can never be credited to a record.
  awk '
    /^[[:space:]]*-[[:space:]]*record:[[:space:]]*/ {
      if (rec != "") printf "%s\t%s\t%s\n", rec, svc, slo
      rec = $0
      sub(/^[[:space:]]*-[[:space:]]*record:[[:space:]]*/, "", rec)
      gsub(/["\047[:space:]]/, "", rec)
      svc = ""; slo = ""; next
    }
    /^[[:space:]]*-[[:space:]]*alert:[[:space:]]*/ { rec = ""; svc = ""; slo = ""; next }
    rec != "" && /^[[:space:]]*service:[[:space:]]*/ && svc == "" {
      svc = $0; sub(/^[[:space:]]*service:[[:space:]]*/, "", svc); gsub(/["\047[:space:]]/, "", svc)
    }
    rec != "" && /^[[:space:]]*slo:[[:space:]]*/ && slo == "" {
      slo = $0; sub(/^[[:space:]]*slo:[[:space:]]*/, "", slo); gsub(/["\047[:space:]]/, "", slo)
    }
    END { if (rec != "") printf "%s\t%s\t%s\n", rec, svc, slo }
  ' "$RULE_FILE" > "$REC_TSV"
fi

# have_combo <service-regex> <sli> <window> - the exact series name and label set.
have_combo() {
  awk -F'\t' -v want="slo:sli_error:ratio_rate$3" -v svc="$1" -v sli="$2" '
    $1 == want && $2 ~ svc && $3 == sli { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$REC_TSV"
}

printf '\n== AC-1: PrometheusRule, release label, 42 recording series\n' >&2
if [ "$have_rules" -eq 1 ]; then
  req 1 "rule file is a PrometheusRule" \
    grep -qE '^kind:[[:space:]]*PrometheusRule[[:space:]]*$' "$RULE_FILE"
  # The Prometheus CR's ruleSelector is {matchLabels: {release: prometheus-stack}}:
  # a PrometheusRule without this label is loaded by the operator and then
  # ignored by Prometheus, silently.
  req 1 "carries label release: prometheus-stack (the Prometheus ruleSelector)" \
    grep -qE '^[[:space:]]*release:[[:space:]]*prometheus-stack[[:space:]]*$' "$RULE_FILE"
  # The metrics the SLIs are defined over (spec "Read first"): WO-2 span
  # metrics for Open WebUI and Hindsight API, Grafana's own request histogram.
  req 1 "reads the trace span-metric counters" \
    grep -q 'traces_spanmetrics_calls_total' "$RULE_FILE"
  req 1 "reads the trace span-metric latency histogram" \
    grep -q 'traces_spanmetrics_latency_bucket' "$RULE_FILE"
  req 1 "reads grafana_http_request_duration_seconds" \
    grep -q 'grafana_http_request_duration_seconds' "$RULE_FILE"
  # Availability is "SERVER spans that are not STATUS_CODE_ERROR".
  req 1 "counts failed spans through STATUS_CODE_ERROR" \
    grep -q 'STATUS_CODE_ERROR' "$RULE_FILE"

  n_found=0
  missing=""
  i=0
  while [ "$i" -lt "${#SERVICES[@]}" ]; do
    sli_i=0
    while [ "$sli_i" -lt "${#SLIS[@]}" ]; do
      w=0
      while [ "$w" -lt "${#WINDOWS[@]}" ]; do
        if have_combo "${SERVICES[$i]}" "${SLIS[$sli_i]}" "${WINDOWS[$w]}"; then
          n_found=$((n_found + 1))
        else
          [ -n "$missing" ] || missing="service=${SERVICE_NAMES[$i]} slo=${SLIS[$sli_i]} window=${WINDOWS[$w]}"
          printf '  missing  service=%s slo=%s window=%s\n' \
            "${SERVICE_NAMES[$i]}" "${SLIS[$sli_i]}" "${WINDOWS[$w]}" >&2
        fi
        w=$((w + 1))
      done
      sli_i=$((sli_i + 1))
    done
    i=$((i + 1))
  done
  if [ "$n_found" -eq "$N_COMBOS" ]; then
    ok "$n_found/$N_COMBOS recording series (3 services x 2 SLIs x 7 windows)"
  else
    fail_ac 1 "found $n_found of $N_COMBOS recording series; first missing: $missing"
  fi
  # Each recording series must be a rule with an expression, not just a name.
  n_noexpr=0
  while IFS= read -r blk; do
    [ -n "$blk" ] || continue
    if [ -z "$(label_val "$blk" expr)" ] && ! grep -qE '^[[:space:]]*expr:' "$blk"; then
      n_noexpr=$((n_noexpr + 1))
      fail_ac 1 "recording rule $(basename "$blk") has no expr"
    fi
  done <<EOF
$(block_files "$REC_DIR")
EOF
  [ "$n_noexpr" -eq 0 ] && ok "every recording rule carries an expr"
fi

# --- AC-2: the four workbook burn-rate alerts ------------------------------

ALERT_DIR="$WORK/alerts"
mkdir -p "$ALERT_DIR"
if [ "$have_rules" -eq 1 ]; then
  split_blocks alert "$RULE_FILE" "$ALERT_DIR"
fi

# factor_re <n> - the comparison the workbook's factor requires, as a regex on
# the flattened expression. `> 6` must not match `> 6.5` or `> 60`.
factor_re() {
  case "$1" in
    14.4) printf '%s' '14\.4' ;;
    *)    printf '>[[:space:]]*%s([^0-9.]|$)' "$1" ;;
  esac
}

# burn_pair <n> <factor> <long-window> <short-window> <severity>
burn_pair() {
  local n="$1" factor="$2" long_w="$3" short_w="$4" sev="$5"
  local fre name f blk
  fre=$(factor_re "$factor")
  while IFS= read -r blk; do
    [ -n "$blk" ] || continue
    name=$(basename "$blk")
    f=$(flatten "$blk")
    printf '%s' "$f" | grep -qE "$fre" || continue
    case "$f" in *"slo:sli_error:ratio_rate$long_w"*) ;; *) continue ;; esac
    case "$f" in *"slo:sli_error:ratio_rate$short_w"*) ;; *) continue ;; esac
    has_label "$blk" alertgroup slo || continue
    has_label "$blk" severity "$sev" || continue
    ok "  $name: > $factor over $long_w and $short_w, severity $sev"
    printf '%s %s\n' "$factor" "$name" >> "$WORK/burn-names"
    return 0
  done <<EOF
$(block_files "$ALERT_DIR")
EOF
  fail_ac "$n" "no alert compares the burn rate with $factor over $long_w and $short_w carrying alertgroup: slo and severity: $sev"
  return 1
}

printf '\n== AC-2: page 14.4 (1h/5m), page 6 (6h/30m), ticket 3 (1d/2h), ticket 1 (3d/6h)\n' >&2
: > "$WORK/burn-names"
if [ "$have_rules" -eq 1 ]; then
  burn_pair 2 14.4 1h  5m  critical
  burn_pair 2 6    6h  30m critical
  burn_pair 2 3    1d  2h  warning
  burn_pair 2 1    3d  6h  warning

  n_burn=$(wc -l < "$WORK/burn-names" | tr -d '[:space:]')
  if [ "$n_burn" -lt 4 ]; then
    fail_ac 2 "only $n_burn of the 4 workbook burn-rate alerts exist"
  fi
  dupes=$(cut -d' ' -f2 "$WORK/burn-names" | sort | uniq -d)
  if [ -n "$dupes" ]; then
    fail_ac 2 "one alert carries more than one factor ($dupes) - each burn rate needs its own alert"
  fi
  if [ "$n_burn" -ge 4 ] && [ -z "$dupes" ]; then
    ok "4 distinct burn-rate alerts, one per workbook factor"
  fi
  # Error budget = 1 - target: every burn rate has to be a multiple of the
  # budget, so each expression divides by a budget literal (0.005 or 0.05).
  while IFS= read -r blk; do
    [ -n "$blk" ] || continue
    f=$(flatten "$blk")
    if printf '%s' "$f" | grep -qE '0\.005|0\.05|0\.995|0\.95'; then
      ok "  $(basename "$blk") divides by an error budget (target 0.995 / 0.95)"
    else
      fail_ac 2 "$(basename "$blk") has no error-budget divisor (0.005 for 99.5 %, 0.05 for 95 %)"
    fi
  done <<EOF
$(block_files "$ALERT_DIR")
EOF
fi

# --- AC-3: routed to Mattermost -------------------------------------------

printf '\n== AC-3: AlertmanagerConfig routes alertgroup=slo to Mattermost\n' >&2
if [ ! -f "$AM_FILE" ]; then
  fail_ac 3 "$AM_FILE missing"
else
  req 3 "AlertmanagerConfig exists" \
    grep -qE '^kind:[[:space:]]*AlertmanagerConfig[[:space:]]*$' "$AM_FILE"
  # Alertmanager's alertmanagerConfigSelector is {release: kube-prometheus-stack}.
  req 3 "carries label release: kube-prometheus-stack (the alertmanagerConfigSelector)" \
    grep -qE '^[[:space:]]*release:[[:space:]]*kube-prometheus-stack[[:space:]]*$' "$AM_FILE"
  # Route on alertgroup = slo, the label every burn-rate rule must carry.
  if grep -qE '^[[:space:]]*(-[[:space:]]+)?name:[[:space:]]*"?alertgroup"?[[:space:]]*$' "$AM_FILE" \
     && grep -qE '^[[:space:]]*value:[[:space:]]*"?slo"?[[:space:]]*$' "$AM_FILE"; then
    ok "  routes on alertgroup = slo"
  else
    fail_ac 3 "does not route on alertgroup = slo"
  fi
  # Same Mattermost path as the Flux alerts: the existing SOPS webhook Secret.
  req 3 "reaches Mattermost through the existing SOPS webhook secret $AM_SECRET" \
    grep -qE "^[[:space:]]*name:[[:space:]]*$AM_SECRET[[:space:]]*\$" "$AM_FILE"
  req 3 "the route names a receiver that exists" \
    grep -qE '^[[:space:]]*receiver:[[:space:]]*[a-z]' "$AM_FILE"
  # THE ROUTING TRAP (flux-gitops-alertmanager-config.yaml documents it):
  # prometheus-operator's default OnNamespace matcher injects
  # namespace="<this AlertmanagerConfig's namespace>", so an SLO rule that pins a
  # different namespace fires and then falls through to the null receiver.
  if [ "$have_rules" -eq 1 ]; then
    am_ns=$(label_val "$AM_FILE" namespace)
    if [ -z "$am_ns" ]; then
      fail_ac 3 "AlertmanagerConfig has no metadata.namespace"
    else
      while IFS= read -r blk; do
        [ -n "$blk" ] || continue
        rns=$(label_val "$blk" namespace)
        if [ -n "$rns" ] && [ "$rns" != "$am_ns" ]; then
          fail_ac 3 "$(basename "$blk") labels namespace=$rns but the AlertmanagerConfig is in $am_ns - it would never route"
        fi
      done <<EOF
$(block_files "$ALERT_DIR")
EOF
      ok "  no burn-rate rule pins a namespace other than $am_ns"
    fi
  fi
fi

# --- AC-4: the dashboard, in the manifest and on the standard --------------

printf '\n== AC-4: SLO dashboard in the manifest, standard-compliant, rendered\n' >&2
if [ ! -f "$MANIFEST" ]; then
  fail_ac 4 "$MANIFEST missing"
else
  # The dashboard half is a python3 -I program: no PyYAML on the Air or in CI,
  # and the generator writes the ConfigMap as JSON (valid YAML) for the same
  # reason. It prints its per-assertion detail on stderr and exits 1 on any
  # problem; the re-render and the repo-wide standard check run here because
  # they are shell commands.
  cat > "$WORK/ac4.py" <<'PY'
import json
import os
import re
import subprocess
import sys

DASH_FILE = "infrastructure/observability/dashboards/slo-dashboard-configmap.yaml"
MANIFEST = "scripts/dashboards/manifest.json"
TITLE = "Observability \u2014 SLOs"
ROWS = ("Golden signals", "Resources", "Logs")
SERVICES = (("open-webui", re.compile(r"open[-_]?webui", re.I)),
            ("hindsight-api", re.compile(r"hindsight[-_]?api", re.I)),
            ("grafana", re.compile(r"grafana", re.I)))

problems = []


def ok(msg):
    sys.stderr.write("  ok    %s\n" % msg)


def bad(msg):
    problems.append(msg)
    sys.stderr.write("  FAIL  %s\n" % msg)


def normalize(path):
    path = path.strip()
    while path.startswith("./"):
        path = path[2:]
    return os.path.normpath(path).replace(os.sep, "/")


def manifest_entry():
    try:
        raw = json.load(open(MANIFEST, encoding="utf-8"))
    except ValueError as exc:
        bad("%s is not valid JSON: %s" % (MANIFEST, exc))
        return None
    listed = raw.get("dashboards") if isinstance(raw, dict) else raw
    if not isinstance(listed, list):
        bad("%s has no dashboards list" % MANIFEST)
        return None
    for item in listed:
        if not isinstance(item, dict):
            continue
        for key in ("output", "outputPath", "path", "file"):
            value = item.get(key)
            if isinstance(value, str) and normalize(value) == DASH_FILE:
                return item
    bad("%s lists no entry for %s" % (MANIFEST, DASH_FILE))
    return None


entry = manifest_entry()
if entry is not None:
    ok("the manifest lists %s" % DASH_FILE)
    namespace = entry.get("namespace")
    title = entry.get("title")
    if title != TITLE:
        bad("manifest title is %r, the spec says %r" % (title, TITLE))
    elif not isinstance(namespace, str) or not namespace:
        bad("manifest entry names no namespace, so the title cannot follow '<namespace> \u2014 <What>'")
    elif not title.startswith(namespace + " \u2014 "):
        bad("title %r does not match the standard '<namespace> \u2014 <What>' for namespace %r"
            % (title, namespace))
    else:
        ok("title %r follows '<namespace> \u2014 <What>'" % title)
    if not entry.get("uid") and not entry.get("dashboards"):
        bad("manifest entry has no uid")

dash = None
if not os.path.exists(DASH_FILE):
    bad("%s does not exist" % DASH_FILE)
else:
    try:
        configmap = json.load(open(DASH_FILE, encoding="utf-8"))
    except ValueError as exc:
        bad("%s is not JSON (the generator writes JSON ConfigMaps): %s" % (DASH_FILE, exc))
        configmap = None
    if configmap is not None:
        data = configmap.get("data") if isinstance(configmap, dict) else None
        if not isinstance(data, dict) or not data:
            bad("%s has no ConfigMap data" % DASH_FILE)
        else:
            for key in data:
                if not str(key).endswith(".json"):
                    bad("%s data key %s is not a .json dashboard" % (DASH_FILE, key))
                elif dash is None:
                    value = data[key]
                    dash = value if isinstance(value, dict) else json.loads(value)
            if dash is not None:
                ok("the ConfigMap carries a parsed dashboard")

if dash is not None:
    # The dashboard standard (docs/dashboards.md): title, tags+namespace, 30s
    # refresh, the datasource variables (a hardcoded UID goes blank when the
    # datasource is re-provisioned, GUL-1693), the homelab dropdown, and the
    # reading order of rows.
    if dash.get("title") != TITLE:
        bad("dashboard title is %r, expected %r" % (dash.get("title"), TITLE))
    else:
        ok("dashboard title is %r" % TITLE)
    tags = dash.get("tags")
    if not isinstance(tags, list) or "homelab" not in tags:
        bad("tags %r lack 'homelab'" % (tags,))
    elif entry is not None and entry.get("namespace") and entry["namespace"] not in tags:
        bad("tags %r lack the namespace %r" % (tags, entry["namespace"]))
    else:
        ok("tags carry homelab and the namespace")
    if dash.get("refresh") != "30s":
        bad("refresh is %r, the standard is '30s'" % (dash.get("refresh"),))
    names = set()
    for variable in (dash.get("templating") or {}).get("list") or []:
        if isinstance(variable, dict) and isinstance(variable.get("name"), str):
            names.add(variable["name"])
    for wanted in ("datasource", "loki"):
        if wanted not in names:
            bad("no %r template variable - panels must not pin a datasource UID" % wanted)
    if "datasource" in names and "loki" in names:
        ok("carries the datasource and loki template variables")
    linked = json.dumps(dash.get("links") or [])
    if "homelab" in linked and "asDropdown" in linked:
        ok("carries the homelab dashboards dropdown")
    else:
        bad("no dashboards dropdown link tagged 'homelab'")

    panels = []

    def walk(items):
        for panel in items or []:
            if isinstance(panel, dict):
                panels.append(panel)
                walk(panel.get("panels"))

    walk(dash.get("panels"))
    rows = [p.get("title") for p in panels if p.get("type") == "row"]
    if tuple(rows[:len(ROWS)]) != ROWS:
        bad("rows are %r, the standard is %r in that order" % (rows, list(ROWS)))
    else:
        ok("rows are Golden signals, Resources, Logs")
    for panel in panels:
        if panel.get("type") in ("row", "text"):
            continue
        if not (panel.get("description") or "").strip():
            bad("panel %r has no description" % (panel.get("title"),))
        unit = ((panel.get("fieldConfig") or {}).get("defaults") or {}).get("unit")
        if not unit:
            bad("panel %r has no fieldConfig.defaults.unit" % (panel.get("title"),))

    # The spec's dashboard content: per service the current SLI over 30d, the
    # error budget left in %, burn rate 1h and 6h, and the 30-day burn-down.
    blob = json.dumps(dash)
    for label, pattern in SERVICES:
        if pattern.search(blob):
            ok("  the dashboard reads %s" % label)
        else:
            bad("the dashboard never reads %s - it must show all 3 services" % label)
    for window in ("ratio_rate1h", "ratio_rate6h"):
        if window in blob:
            ok("  a panel uses %s" % window)
        else:
            bad("no panel uses %s (burn rate 1h / 6h)" % window)
    # The 30-day SLI is not one of the seven recording windows (the longest is
    # 3d), so it is a range query or a separate series - accept either shape.
    if re.search(r"ratio_rate30d|\[30d\]|30[ -]?d(ay)?", blob, re.I):
        ok("  a panel covers the 30-day window")
    else:
        bad("no panel covers the 30-day SLI / burn-down window")
    if re.search(r"budget", blob, re.I):
        ok("  a panel shows the error budget")
    else:
        bad("no panel shows the error budget left")

# A path the spec allows but that does not exist yet is normal on the red
# stage; if a linter has appeared by the green stage, it gets a say too.
LINT = "scripts/dashboards/dashboard_lint.py"
if os.path.exists(LINT) and os.path.exists(DASH_FILE):
    proc = subprocess.run([sys.executable, "-I", LINT, DASH_FILE],
                          capture_output=True, text=True)
    if proc.returncode == 0:
        ok("%s passes %s" % (DASH_FILE, LINT))
    else:
        bad("%s fails %s: %s" % (DASH_FILE, LINT,
                                 (proc.stderr or proc.stdout).strip().splitlines()[-1:] or "no output"))

sys.exit(1 if problems else 0)
PY

  if python3 -I "$WORK/ac4.py"; then
    :
  else
    fail_ac 4 "the SLO dashboard is missing or not on the standard (see the FAIL lines above)"
  fi

  # Re-rendering from the manifest must reproduce the committed file byte for
  # byte - that is what makes the manifest the source of truth (and what the
  # repo-wide standard check's AC-1 asserts for every dashboard).
  if [ -f "$DASH_FILE" ]; then
    mkdir -p "$WORK/render"
    if bash scripts/render_dashboards.sh --output-dir "$WORK/render" > "$WORK/render.log" 2>&1; then
      rendered=""
      if [ -f "$WORK/render/$DASH_FILE" ]; then
        rendered="$WORK/render/$DASH_FILE"
      else
        rendered=$(find "$WORK/render" -name "$(basename "$DASH_FILE")" -type f 2>/dev/null | head -1)
      fi
      if [ -z "$rendered" ]; then
        fail_ac 4 "re-rendering the manifest produced no $(basename "$DASH_FILE")"
      elif cmp -s "$rendered" "$DASH_FILE"; then
        ok "re-rendering reproduces $DASH_FILE byte for byte"
      else
        fail_ac 4 "re-rendering changes $DASH_FILE - edit the manifest and re-render, never the ConfigMap"
      fi
    else
      fail_ac 4 "scripts/render_dashboards.sh exited non-zero: $(tail -1 "$WORK/render.log")"
    fi
  fi

  # The standard's own gate covers every manifest output, this dashboard
  # included. Its stdout carries its own AC-1..AC-7 lines, so it is captured:
  # this check must print only the ACs the spec assigned to it.
  if [ -x scripts/tests/dashboard-standard-check.sh ] || [ -f scripts/tests/dashboard-standard-check.sh ]; then
    if bash scripts/tests/dashboard-standard-check.sh > "$WORK/standard.log" 2>&1; then
      ok "scripts/tests/dashboard-standard-check.sh stays green with the SLO dashboard in the set"
    else
      fail_ac 4 "scripts/tests/dashboard-standard-check.sh fails: $(grep -m1 'AC-[0-9]*: FAIL' "$WORK/standard.log")"
    fi
  else
    fail_ac 4 "scripts/tests/dashboard-standard-check.sh missing - the standard cannot be verified"
  fi
fi

# --- AC-5: the observability design ADR, filed and indexed ----------------

printf '\n== AC-5: observability design ADR, numbered and indexed\n' >&2
ADR_FILE=""
n_adr=0
for candidate in docs/adr/adr-*-observability-design.md; do
  [ -f "$candidate" ] || continue
  ADR_FILE="$candidate"
  n_adr=$((n_adr + 1))
done

if [ "$n_adr" -eq 0 ]; then
  fail_ac 5 "no docs/adr/adr-<N>-observability-design.md - the design ADR is missing"
elif [ "$n_adr" -gt 1 ]; then
  fail_ac 5 "$n_adr observability-design ADRs exist, the spec allows one"
else
  base=$(basename "$ADR_FILE")
  if [[ "$base" =~ ^adr-([0-9]{3})-observability-design\.md$ ]]; then
    num="${BASH_REMATCH[1]}"
    ok "$base has a three-digit ADR number ($num)"
  else
    num=""
    fail_ac 5 "$base is not named adr-<NNN>-observability-design.md"
  fi

  if [ -n "$num" ]; then
    # A number belongs to exactly one ADR: two branches can each take the same
    # one in good faith and only collide in the tree (GUL-727).
    dup=$(ls docs/adr/adr-"$num"-*.md 2>&1 | grep -v "/$base\$" | head -1)
    if [ -n "$dup" ] && [ -f "$dup" ]; then
      fail_ac 5 "ADR-$num is already taken by $(basename "$dup") - use the next free number"
    else
      ok "ADR-$num is not claimed by another file"
    fi

    h1=$(head -1 "$ADR_FILE")
    if [ "${h1#\# ADR-$num: }" != "$h1" ] && [ -n "${h1#\# ADR-$num: }" ]; then
      ok "H1 is '${h1}'"
    else
      fail_ac 5 "H1 is '$h1', expected '# ADR-$num: <title>'"
    fi

    # The index row: | ADR-NNN | title | status | YYYY-MM-DD |
    row=$(awk -F'|' -v n=" ADR-$num " '$2 == n { print; exit }' "$ADR_INDEX" 2>&1)
    if [ -z "$row" ]; then
      fail_ac 5 "docs/adr/README.md has no '| ADR-$num | ...' index row"
    else
      ok "docs/adr/README.md lists ADR-$num"
      status=$(printf '%s' "$row" | awk -F'|' '{ v=$4; gsub(/^ +| +$/,"",v); print v }')
      date=$(printf '%s' "$row" | awk -F'|' '{ v=$5; gsub(/^ +| +$/,"",v); print v }')
      if [ -z "$status" ]; then
        fail_ac 5 "the ADR-$num index row has no status"
      else
        ok "  index row status: $status"
      fi
      if [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        ok "  index row date: $date"
      else
        fail_ac 5 "the ADR-$num index row date '$date' is not YYYY-MM-DD"
      fi
    fi
  fi

  # The ADR has to name all 3 services with their targets, and it is the
  # owner's SRE-interview document, so the SLO section is not optional.
  for label in "Open WebUI" "Hindsight API" "Grafana"; do
    if grep -qi "$label" "$ADR_FILE"; then
      ok "  names $label"
    else
      fail_ac 5 "$base never names $label"
    fi
  done
  for target in '99\.5' '\b95[[:space:]]*%'; do
    if grep -qE "$target" "$ADR_FILE"; then
      ok "  states the target matching /$target/"
    else
      fail_ac 5 "$base does not state the target /$target/"
    fi
  done
  for term in 'burn rate' 'error budget'; do
    if grep -qi "$term" "$ADR_FILE"; then
      ok "  explains $term"
    else
      fail_ac 5 "$base does not explain the $term"
    fi
  done

  # The ADR gate scripts/check.sh registers as `adr`: filename/H1 agreement,
  # index rows, duplicate numbers and the ADR-052 facts.
  if [ -f "$ADR_GATE" ]; then
    if bash "$ADR_GATE" > "$WORK/adr.log" 2>&1; then
      ok "docs/adr/tests/adr-check.sh stays green"
    else
      fail_ac 5 "docs/adr/tests/adr-check.sh fails: $(grep -m1 'FAIL' "$WORK/adr.log")"
    fi
  else
    fail_ac 5 "$ADR_GATE missing - the ADR number and index gate cannot be verified"
  fi
fi

# --- verdict ---------------------------------------------------------------
printf '\n' >&2
rc=0
for n in 1 2 3 4 5; do
  if [ "${AC_FAIL[$n]}" -eq 1 ]; then
    printf 'AC-%s: FAIL %s\n' "$n" "${AC_WHY[$n]}"
    rc=1
  else
    printf 'AC-%s: PASS\n' "$n"
  fi
done
exit "$rc"
