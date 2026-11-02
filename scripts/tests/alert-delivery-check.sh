#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/check_alert_delivery.py must catch the label trap without a cluster.
#
# The two failures the script exists for are cheap to fake: an AlertmanagerConfig
# whose labels do not match the Alertmanager CR's selector (GUL-643), and a
# config whose receiver never reaches the generated alertmanager.yaml. Both are
# reproduced here with a fake kubectl, so CI proves the detector detects, and
# proves it stays quiet on a healthy tree.
#
# It also asserts the one thing that must never leak: the webhook URL. The
# script prints a digest, never the value.
#
# Discovered and run by scripts/check.sh, like every */tests/*-check.sh.
# Exit: 0 = every case passed, 1 = at least one failed.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/scripts/check_alert_delivery.py"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
head1() { printf '\n== %s\n' "$1"; }

[ -f "$SCRIPT" ] && ok "scripts/check_alert_delivery.py exists" || { bad "script missing"; exit 1; }
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$SCRIPT" && ok "passes a syntax check" \
  || bad "python syntax check failed"

# ---- fixture ---------------------------------------------------------------
# A fake kubectl: it answers the four queries the script makes, from fixtures
# chosen by $FIXTURE_DIR. The webhook value ends in a marker the test greps for.
cat > "$WORK/kubectl" <<'EOF'
#!/usr/bin/env python3
import base64, gzip, json, os, sys

fixture = os.environ["FIXTURE_DIR"]
args = sys.argv[1:]
MARKER = "aaaaaaaamarker"

def load(name):
    with open(os.path.join(fixture, name)) as handle:
        return handle.read()

def b64(value):
    return base64.b64encode(value.encode()).decode()

if args[:3] == ["get", "alertmanager", "-A"]:
    print(load("alertmanager.json"))
elif args[:3] == ["get", "alertmanagerconfig", "-A"]:
    print(load("configs.json"))
elif "get" in args and args[args.index("get") + 1] == "secret":
    name = args[args.index("get") + 2]
    with open(os.environ["SECRETS_FILE"]) as handle:
        secrets = json.load(handle)
    if name not in secrets:
        sys.exit(1)
    print(json.dumps(secrets[name]))
else:
    sys.exit(1)
EOF
chmod +x "$WORK/kubectl"
MARKER="aaaaaaaamarker"
HOOK="https://chat.example.invalid/hooks/${MARKER}"
export MARKER HOOK SECRETS_FILE="$WORK/secrets.json"

# gzip+base64 of a generated alertmanager.yaml, and the secret store.
python3 - "$WORK" "$HOOK" <<'PY'
import base64, gzip, json, sys
work, hook = sys.argv[1], sys.argv[2]
def b64(raw): return base64.b64encode(raw).decode()
config = "receivers:\n  - name: 'observability/app-mattermost-alerts/app-mattermost'\n"
secrets = {
    "alertmanager-am-generated": {"alertmanager.yaml.gz": b64(gzip.compress(config.encode()))},
    "app-hook": {"url": b64(hook.encode())},
}
open(f"{work}/secrets.json", "w").write(json.dumps(secrets))
empty = "receivers:\n  - name: 'observability/other-alerts/other'\n"
open(f"{work}/secrets-no-receiver.json", "w").write(json.dumps({
    "alertmanager-am-generated": {"alertmanager.yaml.gz": b64(gzip.compress(empty.encode()))},
    "app-hook": {"url": b64(hook.encode())},
}))
PY

alertmanager_json='{"items":[{"metadata":{"namespace":"observability","name":"am"},"spec":{"alertmanagerConfigSelector":{"matchLabels":{"release":"kube-prometheus-stack"}},"alertmanagerConfigNamespaceSelector":{}}}]}'

# ---- 1. the label trap -----------------------------------------------------
head1 "1. an AlertmanagerConfig the selector never loads"
mkdir -p "$WORK/trap"
printf '%s\n' "$alertmanager_json" > "$WORK/trap/alertmanager.json"
cat > "$WORK/trap/configs.json" <<'EOF'
{"items":[{"metadata":{"namespace":"observability","name":"app-mattermost-alerts",
 "labels":{"release":"prometheus-stack"}},
 "spec":{"receivers":[{"name":"app-mattermost","slackConfigs":[{"apiURL":{"name":"app-hook","key":"url"}}]}]}}]}
EOF
out=$(FIXTURE_DIR="$WORK/trap" SECRETS_FILE="$WORK/secrets-no-receiver.json" KUBECTL="$WORK/kubectl" python3 "$SCRIPT" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "exits 1 on the trap" || bad "exit was $rc, expected 1"
printf '%s\n' "$out" | grep -q 'NEVER loaded' && ok "names the label trap" || bad "did not name the trap: $out"
printf '%s\n' "$out" | grep -q 'missing from the generated config' \
  && ok "catches the missing receiver too" || bad "did not report the missing receiver"
printf '%s\n' "$out" | grep -q "$MARKER" && bad "printed the webhook value" || ok "never prints the webhook value"

# ---- 2. a healthy config ---------------------------------------------------
head1 "2. the same config with the label corrected"
mkdir -p "$WORK/good"
printf '%s\n' "$alertmanager_json" > "$WORK/good/alertmanager.json"
sed 's/"release":"prometheus-stack"/"release":"kube-prometheus-stack"/' "$WORK/trap/configs.json" \
  > "$WORK/good/configs.json"
out=$(FIXTURE_DIR="$WORK/good" KUBECTL="$WORK/kubectl" python3 "$SCRIPT" -v 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "exits 0 on a healthy tree" || bad "exit was $rc, expected 0: $out"
printf '%s\n' "$out" | grep -q 'no delivery problem found' && ok "says so" || bad "no verdict printed"
printf '%s\n' "$out" | grep -q 'host=chat.example.invalid len=' && ok "reports the hook digest" \
  || bad "did not report the hook digest"
printf '%s\n' "$out" | grep -q "$MARKER" && bad "printed the webhook value" || ok "never prints the webhook value"

# ---- 3. a missing hook Secret ---------------------------------------------
head1 "3. a config whose hook Secret is not applied"
mkdir -p "$WORK/nosecret"
printf '%s\n' "$alertmanager_json" > "$WORK/nosecret/alertmanager.json"
sed 's/"app-hook"/"missing-hook"/' "$WORK/good/configs.json" > "$WORK/nosecret/configs.json"
out=$(FIXTURE_DIR="$WORK/nosecret" KUBECTL="$WORK/kubectl" python3 "$SCRIPT" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "exits 1 on a missing Secret" || bad "exit was $rc, expected 1"
printf '%s\n' "$out" | grep -q 'is missing' && ok "names the missing Secret" || bad "did not name it: $out"

# ---- 4. null namespace selector -------------------------------------------
head1 "4. a cross-namespace config under a null namespace selector"
mkdir -p "$WORK/nulls"
printf '%s\n' '{"items":[{"metadata":{"namespace":"observability","name":"am"},"spec":{"alertmanagerConfigSelector":{"matchLabels":{"release":"kube-prometheus-stack"}}}}]}' \
  > "$WORK/nulls/alertmanager.json"
cat > "$WORK/nulls/configs.json" <<'EOF'
{"items":[{"metadata":{"namespace":"pihole","name":"app-mattermost-alerts",
 "labels":{"release":"kube-prometheus-stack"}},
 "spec":{"receivers":[{"name":"app-mattermost","slackConfigs":[{"apiURL":{"name":"app-hook","key":"url"}}]}]}}]}
EOF
out=$(FIXTURE_DIR="$WORK/nulls" KUBECTL="$WORK/kubectl" python3 "$SCRIPT" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "exits 1 when the namespace is not eligible" || bad "exit was $rc, expected 1"
printf '%s\n' "$out" | grep -q 'namespace selector is null' && ok "explains the null selector" \
  || bad "did not explain it: $out"

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf 'alert-delivery-check: PASS\n'
  exit 0
fi
printf 'alert-delivery-check: FAIL\n'
exit 1
