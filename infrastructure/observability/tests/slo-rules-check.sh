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
# AC-6..AC-9 (GUL-1962: the rules stopped matching their telemetry). The spec of
# that work order assigns exactly those four ids to this one command, and the
# protocol forbids printing a line for an AC the command was not assigned, so
# the earlier delivery contract above (AC-1..AC-5: the 42 series, the burn-rate
# pairs, the Mattermost routing, the dashboard standard, the ADR) now runs as
# per-assertion detail on stderr only - where it still explains a regression -
# and the verdict is AC-6..AC-9. The parts of it that matter here are re-asserted
# inside them: AC-6 checks the rule file is a PrometheusRule with the release
# label, AC-8 that the 42 series the new alert counts actually exist.
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

# Per-AC verdict. Index 1..14 so the arrays read like the AC ids; 0 is unused.
AC_FAIL=(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
AC_WHY=("" "" "" "" "" "" "" "" "" "" "" "" "" "" "")

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

# --- AC-6: the Grafana latency bucket -------------------------------------
#
# Grafana's request histogram is the one latency SLI that does not come from the
# Tempo span metrics, and its bucket boundaries are not the span-metric ones.
# `le="1"` does not name a bucket boundary the exporter publishes: the ratio is
# empty, the recording series records nothing and the Grafana burn-rate alerts
# can never fire. That is the silent-rule trap GUL-1593 forbids, so the selector
# has to say le="1.0" - the 1 s threshold, spelled the way the bucket is.
printf '\n== AC-6: Grafana latency SLI selects le="1.0", never le="1"\n' >&2

GL_DIR="$WORK/grafana-latency"
mkdir -p "$GL_DIR"
n_gl=0
n_gl_bad=0
if [ ! -f "$RULE_FILE" ]; then
  fail_ac 6 "$RULE_FILE missing"
else
  req 6 "rule file is a PrometheusRule" \
    grep -qE '^kind:[[:space:]]*PrometheusRule[[:space:]]*$' "$RULE_FILE"
  # The Prometheus CR's ruleSelector is {matchLabels: {release: prometheus-stack}}.
  req 6 "carries label release: prometheus-stack (the Prometheus ruleSelector)" \
    grep -qE '^[[:space:]]*release:[[:space:]]*prometheus-stack[[:space:]]*$' "$RULE_FILE"
  # One file per `- record:` block, numbered: the 42 series reuse seven names, so
  # a name-keyed split would keep only the last of each and hide six sevenths.
  awk -v dir="$GL_DIR" '
    /^[[:space:]]*-[[:space:]]*alert:/ { if (f != "") { close(f); f = "" } }
    /^[[:space:]]*-[[:space:]]*record:/ { if (f != "") close(f); n++; f = dir "/" n }
    f != "" { print >> f }
  ' "$RULE_FILE"
  while IFS= read -r blk; do
    [ -n "$blk" ] || continue
    [ "$(label_val "$blk" service)" = "grafana" ] || continue
    [ "$(label_val "$blk" slo)" = "latency" ] || continue
    grep -q 'grafana_http_request_duration_seconds_bucket' "$blk" || continue
    n_gl=$((n_gl + 1))
    if grep -qE 'le="1\.0"' "$blk"; then
      ok "  $(label_val "$blk" record) selects le=\"1.0\""
    else
      n_gl_bad=$((n_gl_bad + 1))
      fail_ac 6 "a grafana latency rule selects no le=\"1.0\" bucket - le=\"1\" is not a bucket Grafana's histogram publishes, so the series is empty"
    fi
  done <<EOF
$(block_files "$GL_DIR")
EOF
  if [ "$n_gl" -eq 0 ]; then
    fail_ac 6 "no grafana latency recording rule reads grafana_http_request_duration_seconds_bucket"
  elif [ "$n_gl_bad" -eq 0 ]; then
    ok "all $n_gl grafana latency rules select le=\"1.0\""
  fi
  # ...and nothing anywhere in the file may still ask for the bare `le="1"`.
  if grep -qE "le=\"1\"|le='1'" "$RULE_FILE"; then
    fail_ac 6 "the rule file still selects le=\"1\" (line $(grep -nE "le=\"1\"|le='1'" "$RULE_FILE" | head -1 | cut -d: -f1)) - the 1 s bucket boundary is 1.0"
  else
    ok "no rule selects le=\"1\""
  fi
fi

# --- AC-7: Open WebUI's probes, and it is still traced ---------------------
#
# The SLO rules read Open WebUI through Tempo span metrics filtered on
# span_kind="SPAN_KIND_SERVER", and a pod that is up but whose DB lane is dead
# reports healthy on /health while every request 500s. Readiness therefore has
# to watch /health/db, and the OTel env has to survive the probe patch - drop
# ENABLE_OTEL_TRACES and the SERVER spans stop arriving, which empties the
# availability SLI without a single error in Prometheus.
printf '\n== AC-7: Open WebUI probes on /health and /health/db, still traced\n' >&2

WEBUI="apps/llm-hub/openwebui-helm-release.yaml"
if [ ! -f "$WEBUI" ]; then
  fail_ac 7 "$WEBUI missing"
else
  cat > "$WORK/ac7.py" <<'PY'
import re
import sys

WEBUI = "apps/llm-hub/openwebui-helm-release.yaml"
PROBES = ("readinessProbe", "livenessProbe", "startupProbe")

lines = open(WEBUI, encoding="utf-8").read().splitlines()
problems = []


def ok(msg):
    sys.stderr.write("  ok    %s\n" % msg)


def bad(msg):
    problems.append(msg)
    sys.stderr.write("  FAIL  %s\n" % msg)


def probe_block(name):
    """The lines of one <name>: mapping, by indentation."""
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*)-?\s*%s\s*:\s*(.*?)\s*$" % name, line)
        if not m:
            continue
        indent = len(m.group(1))
        if m.group(2):                      # inline map on the same line
            return [m.group(2)]
        block = []
        for later in lines[i + 1:]:
            if later.strip() and (len(later) - len(later.lstrip())) <= indent:
                break
            block.append(later)
        return block
    return None


paths = {}
for name in PROBES:
    block = probe_block(name)
    if block is None:
        bad("%s is missing on the HelmRelease - the pod is never asked where the DB lane stands" % name)
        continue
    body = "\n".join(block)
    if not re.search(r"httpGet\s*:", body):
        bad("%s is not an httpGet probe - a tcpSocket probe cannot tell /health from /health/db" % name)
        continue
    found = [p for p in re.findall(r"path\s*:\s*[\"']?([^\"'\s]+)", body)
             if p.startswith("/health")]
    if not found:
        bad("%s probes no /health path" % name)
        continue
    if len(set(found)) > 1:
        bad("%s probes more than one path (%s)" % (name, ", ".join(sorted(set(found)))))
        continue
    if not re.search(r"port\s*:\s*\S", body):
        bad("%s has no port" % name)
        continue
    paths[name] = found[0]
    ok("%s on %s" % (name, found[0]))

covered = set(paths.values())
for wanted in ("/health", "/health/db"):
    if wanted in covered:
        ok("a probe hits %s" % wanted)
    else:
        bad("no probe hits %s - process liveness and DB readiness are different failures" % wanted)

# The env list: `- name: X` followed by `value: Y`. A valueFrom entry is left out.
values = {}
current = None
for line in lines:
    m = re.match(r"\s*-\s*name:\s*(\w+)\s*$", line)
    if m:
        current = m.group(1)
        continue
    if current:
        m2 = re.match(r"\s*value:\s*(.*?)\s*$", line)
        if m2:
            value = m2.group(1)
            value = re.sub(r"^[\"']|[\"']$", "", value)
            values[current] = value
        current = None

for flag in ("ENABLE_OTEL", "ENABLE_OTEL_TRACES"):
    if values.get(flag, "").lower() == "true":
        ok("%s=true" % flag)
    else:
        bad("%s is %r - without traces there are no SERVER spans and the availability SLI is empty"
            % (flag, values.get(flag)))
if values.get("OTEL_SERVICE_NAME") == "open-webui":
    ok("OTEL_SERVICE_NAME=open-webui (the service label the SLO rules match)")
else:
    bad("OTEL_SERVICE_NAME is %r, the SLO rules filter service=\"open-webui\""
        % (values.get("OTEL_SERVICE_NAME"),))
if "opentelemetry" in values.get("OTEL_EXPORTER_OTLP_ENDPOINT", ""):
    ok("OTEL_EXPORTER_OTLP_ENDPOINT still points at the collector")
else:
    bad("OTEL_EXPORTER_OTLP_ENDPOINT is %r - the spans never reach Tempo"
        % (values.get("OTEL_EXPORTER_OTLP_ENDPOINT"),))

sys.exit(1 if problems else 0)
PY
  if python3 -I "$WORK/ac7.py"; then
    :
  else
    fail_ac 7 "the Open WebUI HelmRelease does not carry the probes and the tracing AC-7 requires (see the FAIL lines above)"
  fi
fi

# --- AC-8: the missing-series alert ---------------------------------------
#
# The 42 recording series are the whole SLO: rename a service label, drop a
# window, and every rule over it records nothing. No burn rate fires for an
# empty series - the SLO is gone and the silence looks exactly like health. The
# alert has to count the series that exist (or vector(0), so zero is a value and
# not an absent expression) and fire below 42.
printf '\n== AC-8: SLORecordingSeriesMissing fires below 42 series, including zero\n' >&2

N_SERIES=42
if [ "$have_rules" -eq 1 ]; then
  n_series=$(awk -F'\t' '$2 != "" && $3 != ""' "$REC_TSV" | wc -l | tr -d '[:space:]')
  n_pairs=$(awk -F'\t' '$2 != "" && $3 != "" { print $2 ":" $3 }' "$REC_TSV" | sort -u | wc -l | tr -d '[:space:]')
  if [ "$n_series" -eq "$N_SERIES" ]; then
    ok "the rule file defines $n_series SLO series - the threshold $N_SERIES is reality"
  else
    fail_ac 8 "the rule file defines $n_series SLO series, not $N_SERIES - an alert on < $N_SERIES would miss the point (or fire forever)"
  fi
  if [ "$n_pairs" -eq 6 ]; then
    ok "3 services x 2 SLIs = 6 service/slo pairs"
  else
    fail_ac 8 "$n_pairs service/slo pairs, expected 6 (open-webui, hindsight-api and grafana, availability and latency)"
  fi
fi

MISSING_ALERT="$ALERT_DIR/SLORecordingSeriesMissing"
if [ "$have_rules" -eq 0 ]; then
  fail_ac 8 "$RULE_FILE missing"
elif [ ! -f "$MISSING_ALERT" ]; then
  fail_ac 8 "no SLORecordingSeriesMissing alert in $RULE_FILE - a wrong service label silently empties the SLI and nothing notices"
else
  f=$(flatten "$MISSING_ALERT")
  if printf '%s' "$f" | grep -qE 'count\('; then
    ok "counts the series it expects"
  else
    fail_ac 8 "SLORecordingSeriesMissing does not count anything - use count(...)"
  fi
  if printf '%s' "$f" | grep -q 'slo:sli_error:ratio_rate'; then
    ok "counts the slo:sli_error:ratio_rate* series"
  else
    fail_ac 8 "SLORecordingSeriesMissing counts no slo:sli_error:ratio_rate* series"
  fi
  # `or vector(0)` is what makes zero an observable value: without it the
  # comparison is simply empty and the alert stays silent exactly when the SLO
  # is fully gone - which is the case it exists for.
  if printf '%s' "$f" | grep -qE 'or[[:space:]]+vector\(0\)'; then
    ok "or vector(0): zero series is a value, not an absent expression"
  else
    fail_ac 8 "SLORecordingSeriesMissing has no 'or vector(0)' - with zero series the expression is empty and the alert never fires"
  fi
  if printf '%s' "$f" | grep -qE '<[[:space:]]*42([^0-9.]|$)'; then
    ok "fires below 42 series"
  else
    fail_ac 8 "SLORecordingSeriesMissing does not compare against < 42"
  fi
  if has_label "$MISSING_ALERT" alertgroup slo; then
    ok "  carries alertgroup: slo (the routing contract)"
  else
    fail_ac 8 "SLORecordingSeriesMissing carries no alertgroup: slo - the AlertmanagerConfig routes on it"
  fi
  if [ -f "$AM_FILE" ]; then
    am_ns=$(label_val "$AM_FILE" namespace)
    a_ns=$(label_val "$MISSING_ALERT" namespace)
    if [ -n "$am_ns" ] && [ -n "$a_ns" ] && [ "$a_ns" != "$am_ns" ]; then
      fail_ac 8 "SLORecordingSeriesMissing labels namespace=$a_ns but the AlertmanagerConfig is in $am_ns - it would never route"
    fi
  fi
fi

# --- AC-9: one error budget per service and per SLI -----------------------
#
# A single "error budget left" stat per service hides which SLI is spending it:
# an availability burn and a latency burn have different causes and different
# first checks. The dashboard therefore needs a budget panel per (service, SLI)
# pair - six of them, each selecting the service and the slo label.
printf '\n== AC-9: one error budget per service and per SLI on the SLO dashboard\n' >&2

if [ ! -f "$DASH_FILE" ]; then
  fail_ac 9 "$DASH_FILE missing"
else
  cat > "$WORK/ac9.py" <<'PY'
import json
import re
import sys

DASH = "infrastructure/observability/dashboards/slo-dashboard-configmap.yaml"
SERVICES = (("open-webui", r"open[-_]?webui"),
            ("hindsight-api", r"hindsight[-_]?api"),
            ("grafana", r"grafana"))
SLIS = ("availability", "latency")

problems = []


def ok(msg):
    sys.stderr.write("  ok    %s\n" % msg)


def bad(msg):
    problems.append(msg)
    sys.stderr.write("  FAIL  %s\n" % msg)


try:
    configmap = json.load(open(DASH, encoding="utf-8"))
except ValueError as exc:
    bad("%s is not JSON: %s" % (DASH, exc))
    sys.exit(1)

data = configmap.get("data") if isinstance(configmap, dict) else None
if not isinstance(data, dict) or not data:
    bad("%s has no ConfigMap data" % DASH)
    sys.exit(1)

dash = None
for key in data:
    value = data[key]
    try:
        dash = value if isinstance(value, dict) else json.loads(value)
    except ValueError:
        dash = None
    break
if not isinstance(dash, dict):
    bad("%s carries no parsed dashboard" % DASH)
    sys.exit(1)

panels = []


def walk(items):
    for panel in items or []:
        if isinstance(panel, dict):
            panels.append(panel)
            walk(panel.get("panels"))


walk(dash.get("panels"))


def panel_text(panel):
    """Title, description and every target expression - prose included."""
    parts = [panel.get("title") or "", panel.get("description") or ""]
    for target in panel.get("targets") or []:
        if isinstance(target, dict):
            parts.append(target.get("expr") or "")
    return "\n".join(parts)


def panel_query(panel):
    """Title and expressions only: the description is prose and must not decide
    what a panel *is* - every SLI stat panel's description mentions the error
    budget, and counting those would make this AC pass on nothing."""
    parts = [panel.get("title") or ""]
    for target in panel.get("targets") or []:
        if isinstance(target, dict):
            parts.append(target.get("expr") or "")
    return "\n".join(parts)


covered = set()
for panel in panels:
    if not re.search(r"budget", panel_query(panel), re.I):
        continue
    blob = panel_text(panel)
    repeat = re.sub(r"[\"'\s]", "", str(panel.get("repeat") or ""))
    for label, pattern in SERVICES:
        if not re.search(r"service\s*=~?\s*\"%s\"" % pattern, blob):
            continue
        for sli in SLIS:
            by_label = re.search(r"slo\s*=~?\s*\"%s" % sli, blob)
            by_repeat = repeat == "slo" and re.search(r"\$\{?slo\}?", blob)
            if by_label or by_repeat:
                covered.add((label, sli))
                ok("panel %r carries the %s error budget for %s"
                   % (panel.get("title"), sli, label))

missing = [(label, sli) for label, _ in SERVICES for sli in SLIS
           if (label, sli) not in covered]
for label, sli in missing:
    bad("no error-budget panel scoped to %s / %s" % (label, sli))

if missing:
    ok("detail: %d of %d service/SLI budget panels present"
       % (len(covered), len(SERVICES) * len(SLIS)))

sys.exit(1 if problems else 0)
PY
  if python3 -I "$WORK/ac9.py"; then
    :
  else
    fail_ac 9 "the SLO dashboard has no error budget for every service and SLI (see the FAIL lines above)"
  fi
fi

# --- AC-10..AC-14: SLO validity (GUL-2165) --------------------------------
#
# Five defects that make the SLO numbers describe something other than the
# user's experience:
#
#   AC-10/11  the Open WebUI SLI is the Tempo span metrics for
#             service=open-webui, and since GUL-1962 the kubelet probes arrive
#             as SERVER spans on /health and /health/db (~4 100 samples/day,
#             0.048 req/s). They are almost always fast and almost always 200,
#             so they both dilute the error ratio and set the latency
#             denominator: 100 consecutive user-visible 500s moved availability
#             by 0.03 % instead of breaching the 99.5 % target. Every
#             open-webui recording rule therefore has to drop those spans from
#             BOTH sides of the ratio - numerator and denominator - because
#             removing them from one side only turns the ratio into nonsense.
#   AC-12     a 30-day SLI is not the average of 30 daily ratios: averaging
#             ratios weights a quiet day like a busy one, so a burst of errors
#             on a busy day disappears. Pooled SLO arithmetic sums the errors
#             and the totals over the window and divides once.
#   AC-13     the coverage alert counted all 42 recorded series, so a short
#             window that is simply idle (no span in the last 5m) never dropped
#             the count - but a missing service/SLI pair does. Counting the six
#             pairs on the 1d and 3d windows is the shape that tells those two
#             apart.
#   AC-14     the README is the runbook: whoever reads a 99.5 % figure has to be
#             able to see what the denominator is, and that probes are not in
#             it.
#
# The judgement is a python3 -I program for the same reason AC-4/AC-9 are: no
# PyYAML on the Air or in CI, and PromQL selectors need real parsing rather
# than a grep (a `span_name!~"/health.*"` and a `span_name=~"/chat.*"` both
# have to count as "probes excluded", and a mangled regex must fail loudly).
printf '\n== AC-10..AC-14: probe-free Open WebUI SLI, pooled budgets, coverage over 6 pairs, README\n' >&2

AC1014_TSV="$WORK/ac10-14.tsv"
: > "$AC1014_TSV"

cat > "$WORK/gul2165.py" <<'PY'
import json
import re
import sys

RULES = "infrastructure/observability/slo/slo-prometheus-rules.yaml"
DASH = "infrastructure/observability/dashboards/slo-dashboard-configmap.yaml"
README = "infrastructure/observability/slo/README.md"
OUT = sys.argv[1]

AC_IDS = (10, 11, 12, 13, 14)
WINDOWS = ("5m", "30m", "1h", "2h", "6h", "1d", "3d")
SERIES = tuple("slo:sli_error:ratio_rate" + w for w in WINDOWS)
PROBES = ("/health", "/health/db")
USER_PATH = "/api/chat/completions"     # real user traffic, must stay in the SLI

fails = {}
verified = set()


def ok(n, msg):
    sys.stderr.write("  ok    AC-%s  %s\n" % (n, msg))


def bad(n, msg):
    fails.setdefault(n, msg)
    sys.stderr.write("  FAIL  AC-%s  %s\n" % (n, msg))


def prom_match(pattern, value):
    """Prometheus label regexes are fully anchored; an unparseable one is
    treated as matching so a broken matcher can never pass as an exclusion."""
    try:
        return re.fullmatch(pattern, value) is not None
    except re.error:
        return True


MATCHER_RE = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)\s*(=~|!~|!=|=)\s*"((?:[^"\\\\]|\\\\.)*)"')
SELECTOR_RE = re.compile(
    r"(traces_spanmetrics_calls_total|traces_spanmetrics_latency_bucket)\s*\{([^{}]*)\}")


# --- rule-file parsing -----------------------------------------------------

def strip_comments(text):
    return re.sub(r"#[^\n]*", "", text)


def flat(body):
    return re.sub(r"\s+", " ", strip_comments(body)).strip()


def first_label(body, key):
    m = re.search(r"^[ \t]*%s:[ \t]*(\S+)[ \t]*$" % key, body, re.M)
    return m.group(1).strip("\"'") if m else ""


def record_blocks(text):
    """One entry per `- record:` block, with the labels that belong to it."""
    blocks = []
    current = None
    for line in text.splitlines():
        if re.match(r"^\s*-\s*record:\s*", line):
            name = re.sub(r"^\s*-\s*record:\s*", "", line).strip(" \t\"'")
            current = {"name": name, "lines": []}
            blocks.append(current)
            continue
        if re.match(r"^\s*-\s*alert:\s*", line):
            current = None
            continue
        if current is not None:
            current["lines"].append(line)
    for block in blocks:
        body = "\n".join(block["lines"])
        block["body"] = body
        block["flat"] = flat(body)
        block["service"] = first_label(body, "service")
        block["slo"] = first_label(body, "slo")
    return blocks


def selector_matchers(body):
    """Every span-metric selector in an expression, as its raw matcher text.
    A selector written without braces selects everything and yields ''."""
    found = []
    for name in ("traces_spanmetrics_calls_total", "traces_spanmetrics_latency_bucket"):
        for m in SELECTOR_RE.finditer(body):
            if m.group(1) == name:
                found.append((name, m.group(2)))
        # A selector with no braces (e.g. `rate(metric[5m])`) has no matchers at
        # all, so nothing excludes a probe span - it is reported as `""`.
        for _ in re.finditer(re.escape(name) + r"(?!\s*\{)", body):
            found.append((name, ""))
    return found


def selects(matchers, path):
    """True when `path` passes every span_name matcher in the selector.
    No span_name matcher selects everything, so probes are not excluded."""
    ms = [m for m in MATCHER_RE.finditer(matchers) if m.group(1) == "span_name"]
    for m in ms:
        op, value = m.group(2), m.group(3)
        if op == "=":
            if path != value:
                return False
        elif op == "!=":
            if path == value:
                return False
        elif op == "=~":
            if not prom_match(value, path):
                return False
        elif op == "!~":
            if prom_match(value, path):
                return False
    return True


def check_sli(n, sli, metric):
    text = open(RULES, encoding="utf-8").read()
    blocks = [b for b in record_blocks(text)
              if b["service"] == "open-webui" and b["slo"] == sli]
    if not blocks:
        bad(n, "no open-webui %s recording rule in %s" % (sli, RULES))
        return
    n_sel = 0
    for block in blocks:
        sels = [matchers for name, matchers in selector_matchers(block["flat"])
                if name == metric]
        if len(sels) < 2:
            bad(n, "%s selects %s %d time(s); an SLI needs two sides - the %s and the total"
                % (block["name"], metric, len(sels), sli))
            continue
        for matchers in sels:
            n_sel += 1
            for path in PROBES:
                if selects(matchers, path):
                    bad(n, "%s: the selector {%s} still admits the probe span %s - probes are not user traffic"
                        % (block["name"], matchers.strip(), path))
            if not selects(matchers, USER_PATH):
                bad(n, "%s: the selector {%s} also drops a real user request (%s) - the exclusion has to be narrow"
                    % (block["name"], matchers.strip(), USER_PATH))
    if n not in fails:
        ok(n, "%d %s selectors over %d open-webui %s rules exclude /health and /health/db and keep %s"
           % (n_sel, metric, len(blocks), sli, USER_PATH))
    verified.add(n)


# --- AC-12: the dashboard ------------------------------------------------

def dashboard_panels():
    configmap = json.load(open(DASH, encoding="utf-8"))
    data = configmap.get("data") if isinstance(configmap, dict) else None
    if not isinstance(data, dict) or not data:
        raise ValueError("%s has no ConfigMap data" % DASH)
    dash = None
    for value in data.values():
        dash = value if isinstance(value, dict) else json.loads(value)
        break
    if not isinstance(dash, dict):
        raise ValueError("%s carries no parsed dashboard" % DASH)
    panels = []

    def walk(items):
        for panel in items or []:
            if isinstance(panel, dict):
                panels.append(panel)
                walk(panel.get("panels"))

    walk(dash.get("panels"))
    return panels


def expressions(panel):
    return [t.get("expr") or "" for t in panel.get("targets") or []
            if isinstance(t, dict)]


def ac12():
    panels = dashboard_panels()
    if not panels:
        bad(12, "the SLO dashboard has no panels")
        return
    n_expr = 0
    for panel in panels:
        for expr in expressions(panel):
            n_expr += 1
            if "avg_over_time" in expr:
                bad(12, "panel %r averages a recorded ratio (avg_over_time) - a 30d SLI is pooled, not averaged"
                    % (panel.get("title"),))
    budget = []
    for panel in panels:
        title = panel.get("title") or ""
        text = " ".join([title] + expressions(panel))
        # A budget-LEFT panel, not a burn-rate panel (whose title also says
        # "error budget" - "... burn rate - how fast the error budget is going").
        is_budget = re.search(r"budget", text, re.I) and (
            re.search(r"budget[^a-z]*(left|remaining)", title, re.I)
            or re.search(r"(left|remaining)[^a-z]*budget", title, re.I))
        if is_budget:
            budget.append((panel, text))
    if not budget:
        # A green stage that renamed the panels still has to be judged, so fall
        # back to every panel whose title mentions the budget at all.
        for panel in panels:
            title = panel.get("title") or ""
            text = " ".join([title] + expressions(panel))
            if re.search(r"budget", text, re.I):
                budget.append((panel, text))
    if not budget:
        bad(12, "no error-budget-left panel on the SLO dashboard")
        return
    for panel, text in budget:
        title = panel.get("title")
        before = len(fails)
        if "[30d]" not in text:
            bad(12, "budget panel %r does not pool a 30d window (no [30d] range)" % (title,))
        pooled = re.findall(r"sum\s*(?:by\s*\([^)]*\)\s*)?\(\s*increase\s*\(", text)
        if len(pooled) < 2:
            bad(12, "budget panel %r pools %d summed increase(s); it needs summed errors over summed total"
                % (title, len(pooled)))
        if not re.search(r"\)\s*/\s*", text):
            bad(12, "budget panel %r is no ratio - the pooled errors have to be divided by the pooled total"
                % (title,))
        if len(fails) == before:
            ok(12, "  budget panel %r pools [30d] as summed increase of errors over summed increase of total"
               % (title,))
    if 12 not in fails:
        ok(12, "%d panel expressions, none averaging a ratio; %d budget panels pool the 30d window"
           % (n_expr, len(budget)))
    verified.add(12)


# --- AC-13: the coverage alert -------------------------------------------

def alert_block(text, name):
    body = []
    inside = False
    for line in text.splitlines():
        if re.match(r"^\s*-\s*alert:\s*", line):
            got = re.sub(r"^\s*-\s*alert:\s*", "", line).strip(" \t\"'")
            inside = got == name
            if inside:
                body = []
            continue
        if re.match(r"^\s*-\s*record:\s*", line):
            inside = False
            continue
        if inside:
            body.append(line)
    return "\n".join(body) if body else None


def selected_names(expr):
    """Union of the recording-series names the alert's selectors actually read."""
    selected = set()
    for m in re.finditer(r"slo:sli_error:ratio_rate(5m|30m|1h|2h|6h|1d|3d)", expr):
        before = expr[:m.start()].rstrip()
        if before.endswith("~") or before.endswith('"'):
            continue                    # part of a regex, handled by __name__ below
        selected.add(m.group(0))
    for m in re.finditer(r'__name__\s*(=~|!~|!=|=)\s*"([^"]*)"', expr):
        op, value = m.group(1), m.group(2)
        for name in SERIES:
            if op == "=" and name == value:
                selected.add(name)
            elif op == "!=" and name != value:
                selected.add(name)
            elif op == "=~" and prom_match(value, name):
                selected.add(name)
            elif op == "!~" and not prom_match(value, name):
                selected.add(name)
    return selected


def ac13():
    text = open(RULES, encoding="utf-8").read()
    body = alert_block(text, "SLORecordingSeriesMissing")
    if body is None:
        bad(13, "no SLORecordingSeriesMissing alert in %s" % RULES)
        return
    expr = flat(body)
    if not re.search(r"\bcount\s*(?:by\s*\([^)]*\)\s*)?\(", expr):
        bad(13, "SLORecordingSeriesMissing does not count the pairs (no count(...))")
    names = selected_names(expr)
    wanted = {"slo:sli_error:ratio_rate1d", "slo:sli_error:ratio_rate3d"}
    if names != wanted:
        bad(13, "the coverage alert reads %s; it has to count the six pairs over the 1d and 3d windows only, so an idle 5m window cannot fire it"
            % (sorted(names) or "no slo:sli_error:ratio_rate series",))
    if not re.search(r"<\s*6(?![0-9.])", expr):
        bad(13, "SLORecordingSeriesMissing does not compare against a threshold of 6 (the six service/SLI pairs)")
    if re.search(r"[<>]\s*=?\s*42(?![0-9.])", expr):
        bad(13, "SLORecordingSeriesMissing still compares against 42 series - the coverage is six pairs, not 42 windows")
    if not re.search(r"or\s+vector\(0\)", expr):
        bad(13, "SLORecordingSeriesMissing has no 'or vector(0)' - losing every pair would make the expression empty and silent")
    if 13 not in fails:
        ok(13, "counts the six service/SLI pairs on the 1d and 3d windows against < 6, with or vector(0)")
    verified.add(13)


# --- AC-14: the README --------------------------------------------------

SERVICES = (("open-webui", re.compile(r"open[-_ ]?webui", re.I), True),
            ("hindsight-api", re.compile(r"hindsight[-_ ]?api", re.I), True),
            ("grafana", re.compile(r"grafana", re.I), False))


def ac14():
    text = open(README, encoding="utf-8").read()
    # One entry per service: a bullet or a paragraph, not a hard-wrapped line -
    # an 80-column wrap must not decide whether the runbook documents the
    # denominator. Blocks are separated by a blank line; a block starting a new
    # service is where its numerator/denominator sentence lives.
    blocks = []
    current = []
    first = 1
    for number, line in enumerate(text.splitlines(), 1):
        if line.strip():
            if not current:
                first = number
            current.append(line.strip())
        elif current:
            blocks.append((first, " ".join(current)))
            current = []
    if current:
        blocks.append((first, " ".join(current)))

    for label, pattern, span_metric in SERVICES:
        hits = [(number, block) for number, block in blocks
                if pattern.search(block)
                and re.search(r"denominator", block, re.I)
                and re.search(r"availability", block, re.I)
                and re.search(r"latency", block, re.I)]
        if not hits:
            bad(14, "%s states no denominator of the availability and latency SLIs of %s - one entry per service, naming both denominators"
                % (README, label))
            continue
        number, block = hits[0]
        if not span_metric:
            ok(14, "  line %d states the %s denominators" % (number, label))
            continue
        if label == "open-webui":
            required = PROBES
        else:
            required = tuple(re.findall(r"/health[\w/.-]*", block))[:1]
        if not required:
            bad(14, "the %s denominator entry (line %d) names no probe path - the span-metric SLI excludes one"
                % (label, number))
            continue
        for path in required:
            if path not in block:
                bad(14, "the %s denominator entry (line %d) does not name the excluded probe path %s"
                    % (label, number, path))
                break
        else:
            ok(14, "  line %d states the %s denominators and names %s"
               % (number, label, ", ".join(required)))
    if 14 not in fails:
        ok(14, "%s states one denominator entry per service, naming the excluded probe paths" % README)
    verified.add(14)


for n, fn in ((10, lambda: check_sli(10, "availability", "traces_spanmetrics_calls_total")),
              (11, lambda: check_sli(11, "latency", "traces_spanmetrics_latency_bucket")),
              (12, ac12),
              (13, ac13),
              (14, ac14)):
    try:
        fn()
    except Exception as exc:            # a broken read is a FAIL, never a silent pass
        bad(n, "setup error: %s: %s" % (type(exc).__name__, exc))

with open(OUT, "w", encoding="utf-8") as handle:
    for n in AC_IDS:
        if n in fails:
            reason = fails[n].replace("\t", " ").replace("\n", " ")
            handle.write("%d\tFAIL\t%s\n" % (n, reason))
        elif n in verified:
            handle.write("%d\tPASS\t\n" % n)
        else:
            handle.write("%d\tFAIL\tthe AC-10..AC-14 check did not run - setup error\n" % n)
PY

if python3 -I "$WORK/gul2165.py" "$AC1014_TSV"; then
  :
else
  printf '  note  the AC-10..AC-14 program exited non-zero; its FAIL lines above say why\n' >&2
fi

if [ -s "$AC1014_TSV" ]; then
  while IFS="$(printf '\t')" read -r ac_n ac_state ac_why; do
    [ -n "$ac_n" ] || continue
    if [ "$ac_state" = "FAIL" ]; then
      if [ -z "${AC_WHY[$ac_n]}" ]; then AC_WHY[$ac_n]="$ac_why"; fi
      AC_FAIL[$ac_n]=1
    fi
  done < "$AC1014_TSV"
else
  for n in 10 11 12 13 14; do
    AC_FAIL[$n]=1
    AC_WHY[$n]="the AC-10..AC-14 program produced no verdict - setup error"
  done
fi

# --- verdict ---------------------------------------------------------------
#
# Only the ACs this work order's spec assigns to this command: a line for any
# other id is a setup error (CONTRACT.md point 2). GUL-2165 assigns the failing
# checks AC-10..AC-14 to this one command, so AC-1..AC-9 - this script's own
# earlier deliveries - keep running as per-assertion detail on stderr where they
# still catch a regression, and print nothing on stdout.
printf '\n' >&2
rc=0
for n in 10 11 12 13 14; do
  if [ "${AC_FAIL[$n]}" -eq 1 ]; then
    printf 'AC-%s: FAIL %s\n' "$n" "${AC_WHY[$n]}"
    rc=1
  else
    printf 'AC-%s: PASS\n' "$n"
  fi
done
exit "$rc"
