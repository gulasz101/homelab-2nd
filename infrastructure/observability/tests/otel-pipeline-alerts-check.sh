#!/usr/bin/env bash
# Red/green check for the telemetry-pipeline alerting (GUL-1597 WO-3).
#
# Modeled on flux-gitops-alerts-check.sh, but strictly offline: it reads the two
# manifests as text, so it needs no kubectl, no kubeconform, no chart download
# and no cluster. PromQL cannot be validated by a schema anyway - what matters
# is that each rule names a metric that exists, carries the labels the routing
# depends on, and is not a rule that loads with health=ok and can never fire.
#
# One `AC-n: PASS|FAIL` line per acceptance criterion on stdout (the factory
# protocol, agents/factory/CONTRACT.md point 2); the per-assertion detail goes
# to stderr so stdout stays parseable. Exit 0 only when every AC passes.
#
# Structural greps use `^[[:space:]]*` because a re-indent of the YAML must not
# break the check; alert bodies are parsed per `- alert:` block instead of
# matched with one global grep, so a label belonging to the wrong rule cannot
# pass for another.
#
# OTEL_ALERTS_ROOT points the check at another tree (self-test only). The spec's
# check command sets nothing, so it always reads this repo.
#
# Usage: bash infrastructure/observability/tests/otel-pipeline-alerts-check.sh
set -uo pipefail

ROOT="${OTEL_ALERTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
OBS="infrastructure/observability"
RULE_FILE="$ROOT/$OBS/otel-pipeline-prometheus-rules.yaml"
AM_FILE="$ROOT/$OBS/otel-pipeline-alertmanager-config.yaml"
AM_SECRET="homelab-node-mattermost-webhook-url"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ALERT_DIR="$WORK/alerts"
mkdir -p "$ALERT_DIR"

# The seven alerts, in the order the spec's table lists them.
ALERTS=(OtelCollectorDown OtelCollectorRefusingData OtelExporterSendFailed
        OtelExporterQueueFilling LokiIngestErrors TempoIngestErrors
        PrometheusRuleEvaluationFailures)

# Per-AC verdict. Index 1..4 so the arrays read like the AC ids; 0 is unused.
AC_FAIL=(0 0 0 0 0)
AC_WHY=("" "" "" "" "")

ok()  { printf '  ok    %s\n' "$1" >&2; }

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
  if "$@" > /dev/null 2>&1; then ok "$desc"; else fail_ac "$n" "$desc"; fi
}

# --- parsing helpers -------------------------------------------------------

# Split a PrometheusRule into one file per `- alert:` block, named after the
# alert. Comments before the first alert stay in the preamble and are dropped.
split_alerts() {
  local file="$1" dir="$2"
  awk -v dir="$dir" '
    /^[[:space:]]*-[[:space:]]*alert:[[:space:]]*/ {
      if (f != "") close(f)
      name = $0
      sub(/^[[:space:]]*-[[:space:]]*alert:[[:space:]]*/, "", name)
      gsub(/["\047[:space:]]/, "", name)
      f = dir "/" name
      next
    }
    f != "" { print >> f }
  ' "$file"
}

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

# duration_seconds <prometheus duration> - prints seconds; exit 1 if unparseable.
duration_seconds() {
  local rest="$1" total=0 n u
  while [ -n "$rest" ]; do
    if [[ "$rest" =~ ^([0-9]+)([smhdwy])(.*)$ ]]; then
      n="${BASH_REMATCH[1]}"
      u="${BASH_REMATCH[2]}"
      rest="${BASH_REMATCH[3]}"
      case "$u" in
        s) total=$((total + n)) ;;
        m) total=$((total + n * 60)) ;;
        h) total=$((total + n * 3600)) ;;
        d) total=$((total + n * 86400)) ;;
        w) total=$((total + n * 604800)) ;;
        y) total=$((total + n * 31536000)) ;;
      esac
    else
      return 1
    fi
  done
  printf '%s\n' "$total"
}

# alert_blocks - every parsed alert block, one path per line.
alert_blocks() {
  local f
  for f in "$ALERT_DIR"/*; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

have_rules=0
if [ -f "$RULE_FILE" ]; then
  have_rules=1
  split_alerts "$RULE_FILE" "$ALERT_DIR"
else
  fail_ac 1 "otel-pipeline-prometheus-rules.yaml missing"
  fail_ac 2 "otel-pipeline-prometheus-rules.yaml missing"
  fail_ac 3 "otel-pipeline-prometheus-rules.yaml missing"
fi

printf '\n== AC-1: rule file, selector label, the seven alerts\n' >&2
if [ "$have_rules" -eq 1 ]; then
  req 1 "rule file is a PrometheusRule" \
    grep -qE '^kind:[[:space:]]*PrometheusRule[[:space:]]*$' "$RULE_FILE"
  # The Prometheus CR's ruleSelector is {matchLabels: {release: prometheus-stack}}:
  # a PrometheusRule without this label is loaded by the operator and then
  # ignored by Prometheus, silently.
  req 1 "carries label release: prometheus-stack (the Prometheus ruleSelector)" \
    grep -qE '^[[:space:]]*release:[[:space:]]*prometheus-stack[[:space:]]*$' "$RULE_FILE"
  n_alerts=$(alert_blocks | wc -l | tr -d '[:space:]')
  if [ "$n_alerts" -eq 0 ]; then
    fail_ac 1 "no '- alert:' rules parsed from the rule file"
  fi
  for a in "${ALERTS[@]}"; do
    if [ -f "$ALERT_DIR/$a" ]; then ok "rule $a"; else fail_ac 1 "missing alert $a"; fi
  done
fi

printf '\n== AC-2: labels, annotations and for: on every alert\n' >&2
if [ "$have_rules" -eq 1 ]; then
  n_seen=0
  while IFS= read -r blk; do
    [ -n "$blk" ] || continue
    n_seen=$((n_seen + 1))
    name=$(basename "$blk")
    # severity - what the Mattermost message title and any paging rule key on.
    sev=$(label_val "$blk" severity)
    if [ -n "$sev" ]; then ok "  $name severity: $sev"; else fail_ac 2 "$name has no severity label"; fi
    # alertgroup - the label the otel-pipeline AlertmanagerConfig matches on.
    if has_label "$blk" alertgroup "otel-pipeline"; then
      ok "  $name alertgroup: otel-pipeline"
    else
      fail_ac 2 "$name has no alertgroup: otel-pipeline label"
    fi
    # summary and description - an alert nobody can read is not an alert.
    if [ -n "$(label_val "$blk" summary)" ]; then
      ok "  $name summary"
    else
      fail_ac 2 "$name has no summary annotation"
    fi
    if [ -n "$(label_val "$blk" description)" ]; then
      ok "  $name description"
    else
      fail_ac 2 "$name has no description annotation"
    fi
    # for: - a rule that can fire on a single scrape is noise; 5m is the floor.
    fv=$(label_val "$blk" for)
    if [ -z "$fv" ]; then
      fail_ac 2 "$name has no for: (needs 5m or more)"
    elif secs=$(duration_seconds "$fv"); then
      if [ "$secs" -ge 300 ]; then
        ok "  $name for: $fv (5m or more)"
      else
        fail_ac 2 "$name for: $fv is under 5m"
      fi
    else
      fail_ac 2 "$name for: '$fv' is not a duration"
    fi
  done <<EOF
$(alert_blocks)
EOF
  [ "$n_seen" -eq 0 ] && fail_ac 2 "no alerts parsed - every alert must carry the labels"
fi

printf '\n== AC-3: the queue ratio and the refused/send-failed rates\n' >&2
if [ "$have_rules" -eq 1 ]; then
  # Queue fill: size divided by capacity compared with 0.7 - not a raw size, and
  # not a bare size-vs-capacity comparison.
  q="$ALERT_DIR/OtelExporterQueueFilling"
  if [ -f "$q" ]; then
    qf=$(flatten "$q")
    if printf '%s' "$qf" | grep -qE 'otelcol_exporter_queue_size.*/.*otelcol_exporter_queue_capacity'; then
      ok "  OtelExporterQueueFilling divides queue_size by queue_capacity"
    else
      fail_ac 3 "OtelExporterQueueFilling does not divide otelcol_exporter_queue_size by otelcol_exporter_queue_capacity"
    fi
    if printf '%s' "$qf" | grep -q '0\.7'; then
      ok "  OtelExporterQueueFilling compares the ratio with 0.7"
    else
      fail_ac 3 "OtelExporterQueueFilling does not compare the ratio with 0.7"
    fi
  else
    fail_ac 3 "OtelExporterQueueFilling is missing, so the queue ratio is unchecked"
  fi

  # Refused and send-failed: a rate over the counter and a greater-than-zero
  # comparison. A raw counter comparison stays true forever once it has moved.
  check_rate_rule() {
    local alert="$1" metric="$2" blk="$ALERT_DIR/$1" f
    if [ ! -f "$blk" ]; then
      fail_ac 3 "$alert is missing, so it cannot rate() $metric"
      return 0
    fi
    f=$(flatten "$blk")
    if printf '%s' "$f" | grep -qE 'rate[[:space:]]*\('; then
      ok "  $alert uses rate("
    else
      fail_ac 3 "$alert does not use rate() over $metric"
    fi
    if printf '%s' "$f" | grep -q "$metric"; then
      ok "  $alert reads $metric"
    else
      fail_ac 3 "$alert does not read $metric"
    fi
    # Strictly greater than zero: `>= 0` would be true always and fire forever.
    if printf '%s' "$f" | grep -qE '>[[:space:]]*0([^0-9.]|$)'; then
      ok "  $alert compares the rate with greater-than-zero"
    else
      fail_ac 3 "$alert does not compare the rate with greater-than-zero"
    fi
    return 0
  }
  check_rate_rule OtelCollectorRefusingData otelcol_receiver_refused
  check_rate_rule OtelExporterSendFailed otelcol_exporter_send_failed
fi

printf '\n== AC-4: routed to Mattermost like the Flux alerts\n' >&2
if [ ! -f "$AM_FILE" ]; then
  fail_ac 4 "otel-pipeline-alertmanager-config.yaml missing"
else
  req 4 "AlertmanagerConfig exists" \
    grep -qE '^kind:[[:space:]]*AlertmanagerConfig[[:space:]]*$' "$AM_FILE"
  # Alertmanager's alertmanagerConfigSelector is {release: kube-prometheus-stack}.
  req 4 "carries label release: kube-prometheus-stack (the alertmanagerConfigSelector)" \
    grep -qE '^[[:space:]]*release:[[:space:]]*kube-prometheus-stack[[:space:]]*$' "$AM_FILE"
  # Route on alertgroup = otel-pipeline, the label every rule above must carry.
  # The matcher may be written as `- name: alertgroup` or `name: alertgroup`.
  if grep -qE '^[[:space:]]*(-[[:space:]]+)?name:[[:space:]]*"?alertgroup"?[[:space:]]*$' "$AM_FILE" \
     && grep -qE '^[[:space:]]*value:[[:space:]]*"?otel-pipeline"?[[:space:]]*$' "$AM_FILE"; then
    ok "  routes on alertgroup = otel-pipeline"
  else
    fail_ac 4 "does not route on alertgroup = otel-pipeline"
  fi
  req 4 "reaches Mattermost through the existing SOPS webhook secret $AM_SECRET" \
    grep -qE "^[[:space:]]*name:[[:space:]]*$AM_SECRET[[:space:]]*\$" "$AM_FILE"
  # THE ROUTING CONTRACT (the trap flux-gitops-alertmanager-config.yaml
  # documents): prometheus-operator's default OnNamespace matcher strategy
  # injects namespace="<this AlertmanagerConfig's namespace>" into the generated
  # route, so a rule that pins a different namespace label fires and then falls
  # through to the top-level null receiver - nothing reaches Mattermost. If a
  # rule pins a namespace at all, it must be this AlertmanagerConfig's.
  if [ "$have_rules" -eq 1 ]; then
    am_ns=$(label_val "$AM_FILE" namespace)
    if [ -z "$am_ns" ]; then
      fail_ac 4 "AlertmanagerConfig has no metadata.namespace"
    else
      while IFS= read -r blk; do
        [ -n "$blk" ] || continue
        rns=$(label_val "$blk" namespace)
        if [ -n "$rns" ] && [ "$rns" != "$am_ns" ]; then
          fail_ac 4 "$(basename "$blk") labels namespace=$rns but the AlertmanagerConfig is in $am_ns - it would never route"
        fi
      done <<EOF
$(alert_blocks)
EOF
      ok "  no rule pins a namespace other than $am_ns"
    fi
  fi
fi

printf '\n' >&2
rc=0
for n in 1 2 3 4; do
  if [ "${AC_FAIL[$n]}" -eq 1 ]; then
    printf 'AC-%s: FAIL %s\n' "$n" "${AC_WHY[$n]}"
    rc=1
  else
    printf 'AC-%s: PASS\n' "$n"
  fi
done
exit "$rc"
