#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-712: the Pi-hole CLIENT ROSTER seeder + weekly audit, tested without a
# cluster. This is the "rebuild drill" in miniature: the live FTL database is
# replaced by a fake FTL API (tests/fake_ftl.py) serving the same endpoints over
# real HTTP, and the real script (extracted from pihole-curfew-configmap.yaml,
# not a copy) is run against an EMPTY database.
#
# What it proves, in order:
#   1. an empty seed file is refused (an empty roster must never be "converged")
#   2. a rebuild from nothing converges all seed rows, with their groups
#   3. a second run is a no-op — zero writes, not just zero changes
#   4. drift is repaired: a missing row comes back, a mangled row is fixed
#   5. a live row absent from Git is never deleted
#   6. the seeder never touches deny entries, gravity or restartdns
#   7. the weekly audit reports an unregistered-but-active device to Mattermost
#   8. the audit ignores pseudo-devices (ip-192.168.1.x) and stale traffic
#   9. the audit exits 2 when a required-group (curfew) member has vanished
#
# Usage:  bash apps/pihole/tests/client-seed-check.sh
# Exit:   0 = all checks passed, 1 = at least one check failed
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
DIR="$ROOT/apps/pihole"
WORK=$(mktemp -d)
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

FAIL=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3], got [$2])"; fi; }
contains() {
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1 (missing [$3] in: $(printf '%s' "$2" | tr '\n' '|' | cut -c1-300))" ;;
  esac
}
not_contains() {
  case "$2" in
    *"$3"*) bad "$1 (unexpected [$3])" ;;
    *) ok "$1" ;;
  esac
}

# --- extract the real script and the real roster from the Git manifests ----
awk '/^  pihole_curfew.py: \|$/{f=1;next} f{sub(/^    /,"");print}' \
  "$DIR/pihole-curfew-configmap.yaml" > "$WORK/pihole_curfew.py"
awk '/^  clients.json: \|$/{f=1;next} f{sub(/^    /,"");print}' \
  "$DIR/pihole-clients-seeds.yaml" > "$WORK/clients.json"

if ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d else 1)' \
      "$WORK/clients.json" >/dev/null 2>&1; then
  echo "FAIL: could not extract a non-empty JSON roster from pihole-clients-seeds.yaml"
  exit 1
fi
SEED_ROWS=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$WORK/clients.json")
echo "seed roster: $SEED_ROWS rows; script: $(wc -l < "$WORK/pihole_curfew.py" | tr -d ' ') lines"

# --- fake FTL -------------------------------------------------------------
PORTFILE="$WORK/port"
python3 "$DIR/tests/fake_ftl.py" --port 0 --portfile "$PORTFILE" 2>/dev/null &
SERVER_PID=$!
disown "$SERVER_PID" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  [ -s "$PORTFILE" ] && break
  sleep 0.2
done
PORT=$(cat "$PORTFILE" 2>/dev/null)
if [ -z "$PORT" ]; then
  echo "FAIL: fake FTL did not start"
  exit 1
fi
API="http://127.0.0.1:$PORT/api"
WEBHOOK="http://127.0.0.1:$PORT/webhook"

set_state() { curl -s -X POST --data-binary "@$1" "http://127.0.0.1:$PORT/__state" >/dev/null; }
reset_state() { curl -s -X POST -d '{}' "http://127.0.0.1:$PORT/__reset" >/dev/null; }
requests() { curl -s "http://127.0.0.1:$PORT/__requests"; }
webhooks() { curl -s "http://127.0.0.1:$PORT/__webhooks"; }
live_count() {
  curl -s "$API/clients" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["clients"]))'
}
run_seed() {
  PIHOLE_API="$API" PIHOLE_PASSWORD=fake PIHOLE_CLIENT_SEED_FILE="${1:-$WORK/clients.json}" \
    python3 "$WORK/pihole_curfew.py" seed-clients 2>&1
}
run_audit() {
  PIHOLE_API="$API" PIHOLE_PASSWORD=fake PIHOLE_CLIENT_SEED_FILE="$WORK/clients.json" \
    MATTERMOST_WEBHOOK_URL="$WEBHOOK" PIHOLE_AUDIT_REQUIRED_GROUPS=10 \
    python3 "$WORK/pihole_curfew.py" audit-clients 2>&1
}

SYLWIA="da:93:94:e7:c7:7b"     # group 10 — the curfew's last line of defence
TESTDEV="02:00:00:00:00:aa"    # a device nobody registered

# --- 1. empty seed is refused --------------------------------------------
echo "1. empty roster is refused"
: > "$WORK/corrupt.json"
OUT=$(run_seed "$WORK/corrupt.json"); RC=$?
check "unreadable seed exits 1" "$RC" "1"
contains "names the unusable file" "$OUT" "cannot read client seed file"
echo '[]' > "$WORK/empty.json"
OUT=$(run_seed "$WORK/empty.json"); RC=$?
check "empty seed exits 1" "$RC" "1"
contains "refuses to seed nothing" "$OUT" "refusing to seed nothing"
check "no rows created" "$(live_count)" "0"

# --- 2. rebuild from an empty database -----------------------------------
echo "2. rebuild drill: empty FTL -> full roster"
reset_state
OUT=$(run_seed); RC=$?
check "exit code" "$RC" "0"
contains "created every row" "$OUT" "$SEED_ROWS created, 0 repaired"
check "live rows" "$(live_count)" "$SEED_ROWS"
SYL_GROUPS=$(curl -s "$API/clients" | python3 -c "
import sys, json
c = {r['client']: r['groups'] for r in json.load(sys.stdin)['clients']}
print(c.get('$SYLWIA'))")
check "Sylwia's row landed in group 10" "$SYL_GROUPS" "[10]"

# --- 3. idempotent, and provably write-free ------------------------------
echo "3. second run is a no-op"
reset_state2=$WORK/state.json
curl -s "$API/clients" \
  | python3 -c 'import sys,json;json.dump({"clients":json.load(sys.stdin)["clients"]},sys.stdout)' \
  > "$reset_state2"
set_state "$reset_state2"
OUT=$(run_seed); RC=$?
check "exit code" "$RC" "0"
contains "nothing created or repaired" "$OUT" "0 created, 0 repaired"
WRITES=$(requests | python3 -c "
import sys, json
r = json.load(sys.stdin)['requests']
print(len([x for x in r if x[0] in ('PUT', 'POST') and x[1].startswith('/api/clients')]))")
check "client writes on a converged run" "$WRITES" "0"

# --- 4. drift is repaired ------------------------------------------------
echo "4. drift: one row missing, one mangled"
curl -s "$API/clients" | python3 -c "
import sys, json
rows = json.load(sys.stdin)['clients']
rows = [r for r in rows if r['client'] != '$SYLWIA']
for r in rows:
    if r['client'] == 'c8:5b:76:20:60:d9':
        r['comment'] = 'mangled'
        r['groups'] = [0]
json.dump({'clients': rows}, sys.stdout)" > "$WORK/drifted.json"
set_state "$WORK/drifted.json"
OUT=$(run_seed); RC=$?
check "exit code" "$RC" "0"
contains "1 created, 1 repaired" "$OUT" "1 created, 1 repaired"
OUT2=$(curl -s "$API/clients" | python3 -c "
import sys, json
c = {r['client']: r for r in json.load(sys.stdin)['clients']}
print(c.get('$SYLWIA', {}).get('groups'), c['c8:5b:76:20:60:d9']['groups'],
      c['c8:5b:76:20:60:d9']['comment'])")
contains "row restored to its seeded groups/comment" "$OUT2" "[10] [12] t460"

# --- 5. a live row absent from Git is never deleted ----------------------
echo "5. unseeded live row is left alone"
curl -s "$API/clients" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['clients'].append({'client': '02:00:00:00:00:99', 'comment': 'someone else', 'groups': [12]})
json.dump(d, sys.stdout)" > "$WORK/extra.json"
set_state "$WORK/extra.json"
OUT=$(run_seed); RC=$?
check "exit code" "$RC" "0"
contains "reports the unseeded row" "$OUT" "not in the seed, left alone"
check "row still present" "$(live_count)" "$((SEED_ROWS + 1))"

# --- 6. the seeder stays out of the deny/curfew path --------------------
echo "6. seeder touches no deny entries, no gravity, no restartdns"
SIDE=$(requests | python3 -c "
import sys, json
bad = [x for x in json.load(sys.stdin)['requests']
       if '/domains/' in x[1] or '/action/' in x[1]]
print(len(bad))")
check "deny/gravity/restartdns calls during seeding" "$SIDE" "0"

# --- 7. weekly audit reports an unregistered active device --------------
echo "7. audit reports an unregistered device that queried recently"
NOW=$(date +%s)
curl -s "$API/clients" | python3 -c "
import sys, json, time
d = json.load(sys.stdin)
d['suggestions'] = [
    {'hwaddr': '$TESTDEV', 'macVendor': 'Fake Devices Ltd',
     'lastQuery': int(time.time()) - 600,
     'addresses': 'fe80::1,192.168.1.222', 'names': None},
    {'hwaddr': 'ip-192.168.1.179', 'macVendor': None,
     'lastQuery': int(time.time()), 'addresses': '192.168.1.179', 'names': 'pi.hole'},
    {'hwaddr': '02:00:00:00:00:bb', 'macVendor': 'Old',
     'lastQuery': int(time.time()) - 3 * 86400,
     'addresses': '192.168.1.223', 'names': None},
]
d['devices'] = [{'hwaddr': c['client'], 'lastQuery': int(time.time())} for c in d['clients']]
json.dump(d, sys.stdout)" > "$WORK/suggest.json"
set_state "$WORK/suggest.json"
OUT=$(run_audit); RC=$?
check "exit code" "$RC" "0"
contains "test device listed" "$OUT" "$TESTDEV"
contains "its ip shown" "$OUT" "192.168.1.222"
not_contains "pseudo-device filtered" "$OUT" "ip-192.168.1.179"
not_contains "stale traffic filtered" "$OUT" "02:00:00:00:00:bb"
POSTS=$(webhooks | python3 -c "
import sys, json
w = json.load(sys.stdin)['webhooks']
print(len(w), 'yes' if w and '$TESTDEV' in w[-1]['text'] else 'no')")
check "mattermost post carried the report" "$POSTS" "1 yes"

# --- 8. audit alerts when the curfew's group-10 member is gone ----------
echo "8. audit exits 2 when a required-group member vanished"
curl -s "$API/clients" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['clients'] = [r for r in d['clients'] if r['client'] != '$SYLWIA']
json.dump(d, sys.stdout)" > "$WORK/lost.json"
set_state "$WORK/lost.json"
OUT=$(run_audit); RC=$?
check "exit code" "$RC" "2"
contains "drift is named" "$OUT" "$SYLWIA"
contains "alarm marker" "$OUT" ":rotating_light:"

# --- 9. audit does not mutate the roster --------------------------------
echo "9. audit is read-only"
WRITES=$(requests | python3 -c "
import sys, json
r = json.load(sys.stdin)['requests']
print(len([x for x in r if x[0] in ('PUT', 'POST', 'DELETE') and x[1].startswith('/api/clients')]))")
check "client writes during the audit" "$WRITES" "0"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "all checks passed"
  exit 0
fi
echo "$FAIL check(s) failed"
exit 1
