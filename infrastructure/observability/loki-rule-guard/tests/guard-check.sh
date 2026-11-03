#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-805 / loki-rule-guard: prove the code that ships, not a second copy.
#
# Renders infrastructure/observability/loki-rule-guard the way Flux does, pulls
# `loki_rule_guard.py` out of the generated ConfigMap, compiles it, and runs the
# unittest suite against that file.
#
# The interesting assertions are the boring ones: the canary rule must carry a
# stamp, must never fire (a canary that alerts is a self-inflicted outage), and
# must never be reported as a rule the sidecar should have collected.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APP=$(cd "$HERE/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if ! kubectl kustomize "$APP" > "$WORK/render.yaml" 2> "$WORK/err"; then
  printf 'FAIL: kubectl kustomize infrastructure/observability/loki-rule-guard:\n'
  sed 's/^/    /' "$WORK/err"
  exit 1
fi

yq eval 'select(.kind == "ConfigMap") | select(.metadata.name | test("^loki-rule-guard-script")) | .data["loki_rule_guard.py"]' \
  "$WORK/render.yaml" > "$WORK/loki_rule_guard.py" 2> "$WORK/yq.err" || {
    printf 'FAIL: yq could not read loki_rule_guard.py out of the rendered ConfigMap:\n'
    sed 's/^/    /' "$WORK/yq.err"
    exit 1
}

if [ ! -s "$WORK/loki_rule_guard.py" ]; then
  printf 'FAIL: no ConfigMap data["loki_rule_guard.py"] in the render (the guard has to ship as a ConfigMap)\n'
  exit 1
fi
if ! grep -q 'if __name__ == "__main__":' "$WORK/loki_rule_guard.py"; then
  printf 'FAIL: the guard must be importable (main() behind a __main__ guard) so the tests can load it\n'
  exit 1
fi
printf 'extracted %s lines of loki_rule_guard.py from the rendered ConfigMap\n' \
  "$(wc -l < "$WORK/loki_rule_guard.py" | tr -d ' ')"

# The CronJob must reference the generated ConfigMap by the same (hashed) name the
# generator produced, or the pod mounts nothing and crashloops on a missing script.
script_cm=$(yq eval 'select(.kind == "ConfigMap") | select(.metadata.name | test("^loki-rule-guard-script")) | .metadata.name' "$WORK/render.yaml")
mounted=$(yq eval 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec.volumes[] | select(.name == "script") | .configMap.name' "$WORK/render.yaml")
if [ "$script_cm" != "$mounted" ]; then
  printf 'FAIL: the CronJob mounts ConfigMap %s but the generator produced %s\n' "$mounted" "$script_cm"
  exit 1
fi

printf '\n-- python syntax --\n'
python3 -m py_compile "$WORK/loki_rule_guard.py" || { printf 'FAIL: the guard does not compile\n'; exit 1; }

printf '\n-- unittest --\n'
GUARD_MODULE="$WORK/loki_rule_guard.py" python3 -m unittest discover -s "$HERE" -p 'test_*.py' -v
rc=$?
if [ $rc -ne 0 ]; then
  printf 'FAIL: the guard unit tests failed\n'
  exit $rc
fi
printf '\nPASS: loki-rule-guard renders, compiles and passes its unit tests\n'
