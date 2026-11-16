#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# A CNPG instance name ("<cluster>-<n>": the pod and its PVC) is not stable. A switchover, a
# node move or a rebuild changes <n>. The 2026-11-12 node move turned every *-db-1 into *-db-2, and
# three things that had hard-coded "-1" broke silently: the Air's pg_dump shim (paperclip-db-1),
# the Hermes memory watchdog (hindsight-db-1), and four Grafana dashboards' PVC panels (0 series).
#
# Rule: code and manifests address a CNPG instance by label (cnpg.io/cluster=<c>,
# cnpg.io/instanceRole=primary), a Service (<c>-rw), or a regex (persistentvolumeclaim=~"<c>-[0-9]+").
# Comments and Markdown may mention instance names (history, runbook prose). A line that genuinely
# needs one carries the marker `cnpg-name-ok` with a reason.
#
# Bash 3.2 compatible (runs on the Air and in CI).
# ---------------------------------------------------------------------------
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT" || exit 1

# CNPG Cluster names, from the manifests themselves (per YAML document).
names=$(git ls-files 'apps/*.yaml' 'infrastructure/*.yaml' | grep -v '\.sops\.yaml$' | xargs awk '
  FNR==1 || /^---/ { if (api && kind && name) print name; api=0; kind=0; name=""; inmeta=0 }
  /^apiVersion: postgresql\.cnpg\.io\// { api=1 }
  /^kind: Cluster[[:space:]]*$/ { kind=1 }
  /^metadata:/ { inmeta=1; next }
  inmeta && /^  name:/ { name=$2; inmeta=0 }
  /^[a-z]/ && !/^metadata:/ { inmeta=0 }
  END { if (api && kind && name) print name }' | sort -u)
[ -n "$names" ] || { echo "FAIL: found no CNPG Cluster manifests (parser broken?)"; exit 1; }
alt=$(echo "$names" | paste -sd'|' -)

hits=$(git grep -nIE "(^|[^a-z0-9-])($alt)-[0-9]+([^0-9a-z-]|\$)" -- \
    apps infrastructure host scripts agents clusters \
    ':!*.md' ':!*.sops.yaml' ':!scripts/tests/cnpg-instance-name-check.sh' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|//|"""|\*)' \
  | grep -v 'cnpg-name-ok')

if [ -n "$hits" ]; then
  echo "FAIL: hard-coded CNPG instance names (they change on switchover). Use the primary label,"
  echo "      the <cluster>-rw Service, or a regex; or mark the line 'cnpg-name-ok' with a reason:"
  echo "$hits" | cut -c1-220 | sed 's/^/  /'
  exit 1
fi
echo "ok   no hard-coded CNPG instance names ($(echo "$names" | wc -l | tr -d ' ') clusters checked)"
