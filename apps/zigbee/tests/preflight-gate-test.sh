#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Unit test for the zigbee2mqtt preflight gate (H2-214, worker-derived AC 9).
#
# The gate is a shell script that lives inside a ConfigMap
# (apps/zigbee/zigbee2mqtt-preflight-configmap.yaml) and runs as the container
# command before the bridge starts. This test extracts that exact script - it
# does not keep a second copy - and runs it against fixture data directories.
#
# The case that matters most is #4: a configuration.yaml that has a `port:`
# under `frontend:` but nothing under `serial:`. A naive `grep port:` would
# pass it and the bridge would start with autodetect, which is precisely how a
# half-migrated config starts talking to the wrong device.
#
# Usage:  bash apps/zigbee/tests/preflight-gate-test.sh
# Exit:   0 = all cases pass, 1 = at least one case failed
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
CM="$ROOT/apps/zigbee/zigbee2mqtt-preflight-configmap.yaml"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }

[ -f "$CM" ] || { echo "preflight ConfigMap not found: $CM" >&2; exit 1; }

# Extract data.preflight.sh from the ConfigMap (4-space block indentation).
awk '
  /^  preflight\.sh: \|/ { f = 1; next }
  f && /^[^ ]/ { exit }
  f { sub(/^    /, ""); print }
' "$CM" > "$WORK/preflight.sh"

[ -s "$WORK/preflight.sh" ] || { echo "could not extract preflight.sh from $CM" >&2; exit 1; }
printf 'extracted %s lines from the ConfigMap\n\n' "$(wc -l < "$WORK/preflight.sh")"

CONFIG_WITH_SERIAL='version: 4
frontend:
  enabled: true
  port: 8080
serial:
  port: /dev/ttyUSB0
  adapter: ember
  baudrate: 115200
mqtt:
  server: mqtt://mosquitto
'

# The trap this test exists for: a port under frontend, none under serial.
CONFIG_FRONTEND_PORT_ONLY='version: 4
frontend:
  enabled: true
  port: 8080
serial:
  adapter: ember
mqtt:
  server: mqtt://mosquitto
'

# port: null means autodetect, which the gate must not accept.
CONFIG_NULL_PORT='version: 4
serial:
  port: null
  adapter: ember
'

fixture() {  # fixture <name> <config content or empty>
  local dir="$WORK/$1"
  mkdir -p "$dir"
  if [ -n "${2:-}" ]; then printf '%s' "$2" > "$dir/configuration.yaml"; fi
  printf 'sqlite-ish state\n' > "$dir/database.db"
  printf '{"backup":true}\n' > "$dir/coordinator_backup.json"
  printf '%s\n' "$dir"
}

run_gate() {  # run_gate <data dir> -> prints output, returns gate exit code
  ZIGBEE2MQTT_DATA="$1" sh "$WORK/preflight.sh" 2>&1
}

expect() {  # expect <case name> <want exit 0|1> <dir> <expected substring>
  local name="$1" want="$2" dir="$3" needle="$4" out rc
  out=$(run_gate "$dir"); rc=$?
  if [ "$rc" -ne "$want" ]; then
    bad "$name: exit $rc, wanted $want"; printf '%s\n' "$out" | sed 's/^/        /'
    return
  fi
  if ! printf '%s' "$out" | grep -q "$needle"; then
    bad "$name: output does not contain '$needle'"; printf '%s\n' "$out" | sed 's/^/        /'
    return
  fi
  ok "$name (exit $rc, matches '$needle')"
}

echo "== the gate must REFUSE a half-restored data volume"
d=$(fixture empty-dir ""); rm -f "$d/configuration.yaml"
expect "missing configuration.yaml"      1 "$d" "configuration.yaml is missing or empty"

d=$(fixture empty-config ""); : > "$d/configuration.yaml"
expect "empty configuration.yaml"        1 "$d" "configuration.yaml is missing or empty"

d=$(fixture no-database "$CONFIG_WITH_SERIAL"); rm -f "$d/database.db"
expect "missing database.db"             1 "$d" "database.db is missing or empty"

d=$(fixture no-coordinator "$CONFIG_WITH_SERIAL"); rm -f "$d/coordinator_backup.json"
expect "missing coordinator_backup.json" 1 "$d" "coordinator_backup.json is missing or empty"

d=$(fixture frontend-port-only "$CONFIG_FRONTEND_PORT_ONLY")
expect "port under frontend only"        1 "$d" "no serial.port under the serial: block"

d=$(fixture null-port "$CONFIG_NULL_PORT")
expect "serial.port: null (autodetect)"  1 "$d" "no serial.port under the serial: block"

echo
echo "== the gate must ALLOW a fully restored data volume"
d=$(fixture good "$CONFIG_WITH_SERIAL")
expect "complete migrated state"         0 "$d" "serial.port = /dev/ttyUSB0"
if printf '%s' "$(run_gate "$d")" | grep -q "PREFLIGHT: migrated state present"; then
  ok "gate reports the migrated state as present"
else
  bad "gate did not report the migrated state as present"
fi

echo
printf '== result: %s\n' "$([ "$fail" -eq 0 ] && echo PASS || echo FAIL)"
exit "$fail"
