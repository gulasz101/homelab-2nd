#!/bin/sh
# GUL-2067 — print the chart version pinned in the litellm HelmRelease.
#
# Usage:
#   sh apps/llm-hub/factory-probe-c/chart-version.sh [manifest]
#
# With no argument it reads apps/llm-hub/litellm-helm-release.yaml (resolved
# relative to this script, so it works from any cwd); an argument selects
# another HelmRelease-shaped manifest.
#
#   * a chart version is found  -> print it on stdout, exit 0
#   * the file has no
#     spec.chart.spec.version   -> `chart-version: no version in <path>` on
#                                  stderr, nothing on stdout, exit 2
#   * the file cannot be read   -> `chart-version: cannot read <path>` on
#                                  stderr, exit 2
#
# POSIX sh only, and awk rather than yq/PyYAML: this runs in CI and on the Air,
# where neither is guaranteed. The awk walks keys by indentation so a `version:`
# elsewhere in the document (image tag, apiVersion, ...) is never mistaken for
# the chart pin.

set -u

here=$(dirname "$0")
default="$here/../litellm-helm-release.yaml"
manifest=${1:-$default}

if [ ! -f "$manifest" ]; then
	printf 'chart-version: cannot read %s\n' "$manifest" >&2
	exit 2
fi

version=$(awk '
	{
		line = $0
		sub(/#.*/, "", line)
		if (line ~ /^[ \t]*$/) next

		match(line, /^[ ]*/)
		indent = RLENGTH
		rest = substr(line, indent + 1)
		if (rest !~ /^[^:]+:/) next

		key = rest
		sub(/:.*/, "", key)
		val = rest
		sub(/^[^:]*:[ \t]*/, "", val)
		sub(/[ \t]+$/, "", val)

		while (depth > 0 && ind[depth] >= indent) depth--
		depth++
		ind[depth] = indent
		key_at[depth] = key

		if (val == "") next

		path = key_at[1]
		for (i = 2; i <= depth; i++) path = path "." key_at[i]
		if (path != "spec.chart.spec.version") next

		gsub(/^["\047]|["\047]$/, "", val)
		print val
		exit
	}
' "$manifest")

case $version in
\"*\") version=${version#\"}; version=${version%\"} ;;
\'*\') version=${version#\'}; version=${version%\'} ;;
esac

if [ -z "$version" ]; then
	printf 'chart-version: no version in %s\n' "$manifest" >&2
	exit 2
fi

printf '%s\n' "$version"
