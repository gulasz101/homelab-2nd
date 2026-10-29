#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# H2-336 / AC3+AC4: unit-test the exporter/receiver that actually ships.
#
# Renders apps/host-watch the way Flux does, pulls `server.py` out of the
# generated ConfigMap, and runs the unittest suite against that file. Testing a
# second copy of the code would prove nothing about what runs in k3s.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APP=$(cd "$HERE/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if ! kubectl kustomize "$APP" > "$WORK/render.yaml" 2> "$WORK/err"; then
  printf 'FAIL: kubectl kustomize apps/host-watch:\n'; sed 's/^/    /' "$WORK/err"; exit 1
fi

# yq is already a hard dependency of scripts/check.sh; PyYAML is not.
yq eval 'select(.kind == "ConfigMap") | select(.metadata.name | test("^host-watch-server")) | .data["server.py"]' \
  "$WORK/render.yaml" > "$WORK/server.py" 2> "$WORK/yq.err" || {
    printf 'FAIL: yq could not read server.py out of the rendered ConfigMap:\n'; sed 's/^/    /' "$WORK/yq.err"; exit 1; }

if [ ! -s "$WORK/server.py" ]; then
  printf 'FAIL: no ConfigMap data["server.py"] in the render (the exporter has to ship as a ConfigMap)\n'
  exit 1
fi
if ! grep -q 'if __name__ == "__main__":' "$WORK/server.py"; then
  printf 'FAIL: server.py must be importable (main() behind a __main__ guard) so the tests can load it\n'
  exit 1
fi
printf 'extracted %s lines of server.py from the rendered ConfigMap\n' "$(wc -l < "$WORK/server.py" | tr -d ' ')"

printf '\n-- python syntax --\n'
python3 -m py_compile "$WORK/server.py" || { printf 'FAIL: server.py does not compile\n'; exit 1; }

printf '\n-- unittest --\n'
HOSTWATCH_MODULE="$WORK/server.py" python3 -m unittest discover -s "$HERE" -p 'test_*.py' -v
rc=$?
[ "$rc" -eq 0 ] && printf '\nPASS: host-watch exporter/receiver logic\n' || printf '\nFAIL: host-watch exporter/receiver logic\n'
exit "$rc"
