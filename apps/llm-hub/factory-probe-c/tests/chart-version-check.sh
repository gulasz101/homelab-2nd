#!/usr/bin/env bash
# GUL-2067 AC-1 — red-stage check for apps/llm-hub/factory-probe-c/chart-version.sh
#
# Contract under test:
#   * `sh apps/llm-hub/factory-probe-c/chart-version.sh` (no arguments, run from
#     the repo root) prints exactly the chart version pinned in
#     apps/llm-hub/litellm-helm-release.yaml (spec.chart.spec.version) on
#     stdout and exits 0;
#   * the script takes an optional path argument selecting the manifest to read;
#   * given a HelmRelease file with no chart version it prints
#     `chart-version: no version in <path>` on stderr (nothing on stdout) and
#     exits 2.
#
# Protocol (agents/factory/CONTRACT.md point 2): one `AC-1: PASS|FAIL <reason>`
# line, exit 0 only when the AC passes, exit 1 when it fails.

set -u

repo_root=$(cd "$(dirname "$0")/../../../.." && pwd)
script_rel="apps/llm-hub/factory-probe-c/chart-version.sh"
release_rel="apps/llm-hub/litellm-helm-release.yaml"
script="$repo_root/$script_rel"
release="$repo_root/$release_rel"

work=$(mktemp -d) || { echo "AC-1: FAIL cannot create a temp dir"; exit 1; }
trap 'rm -rf "$work"' EXIT INT TERM

fail() {
	printf 'AC-1: FAIL %s\n' "$1"
	exit 1
}

[ -f "$script" ] || fail "missing $script_rel (the script the AC describes)"
[ -f "$release" ] || fail "missing $release_rel (the manifest the script reads)"

# Expected version, read with awk so the check needs no yq/PyYAML. The pin is
# quoted in the manifest (`version: "1.106.6"`), so strip quotes.
expected=$(awk '
	/^spec:/ { in_spec = 1; next }
	in_spec  && /^  chart:/ { in_chart = 1; next }
	in_chart && /^    spec:/  { in_chart_spec = 1; next }
	in_chart_spec && /^[[:space:]]*version:/ {
		v = $2
		gsub(/["\047]/, "", v)
		print v
		exit
	}
' "$release")
[ -n "$expected" ] || fail "cannot read spec.chart.spec.version from $release_rel"

# --- Case 1: default run prints exactly the pinned chart version, exit 0. ----
out=$(cd "$repo_root" && sh "$script_rel" 2>"$work/default.err")
rc=$?
if [ "$rc" -ne 0 ]; then
	detail=$(tr '\n' ' ' <"$work/default.err")
	fail "default run exited $rc, expected 0 (stderr: ${detail:-<empty>})"
fi
if [ "$out" != "$expected" ]; then
	fail "default run printed '$(printf '%s' "$out" | tr '\n' ' ')', expected exactly '$expected'"
fi

# --- Case 2: a HelmRelease with no chart version is an error, exit 2. -------
no_version="$work/no-version.yaml"
cat >"$no_version" <<'YAML'
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: no-version
  namespace: scratch
spec:
  interval: 1h
  chart:
    spec:
      chart: litellm-helm
      sourceRef:
        kind: HelmRepository
        name: litellm
        namespace: flux-system
YAML

out=$(cd "$repo_root" && sh "$script_rel" "$no_version" 2>"$work/no-version.err")
rc=$?
err=$(tr -d '\r' <"$work/no-version.err" | sed -e 's/[[:space:]]*$//')
if [ "$rc" -ne 2 ]; then
	fail "no-version run exited $rc, expected 2 (stderr: ${err:-<empty>})"
fi
expected_err="chart-version: no version in $no_version"
if [ "$err" != "$expected_err" ]; then
	fail "no-version run stderr was '$err', expected '$expected_err'"
fi
if [ -n "$out" ]; then
	fail "no-version run printed '$(printf '%s' "$out" | tr '\n' ' ')' on stdout, expected nothing"
fi

printf 'AC-1: PASS\n'
exit 0
