#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Render every homelab Grafana dashboard from the one manifest (GUL-1598).
#
#   scripts/render_dashboards.sh                      rewrite the tree in place
#   scripts/render_dashboards.sh --output-dir DIR     render below DIR instead
#   scripts/render_dashboards.sh --out-dir DIR        same thing
#   scripts/render_dashboards.sh DIR                  same thing (positional)
#   scripts/render_dashboards.sh --list               print the outputs, render none
#
# The generator is scripts/render_namespace_dashboard.py and the manifest is
# scripts/dashboards/manifest.json; this wrapper only exists so the standard has
# one command to remember (and so scripts/tests/dashboard-standard-check.sh can
# render into a temporary directory and diff it against the tree).
#
# Never edit a *dashboard-configmap.yaml by hand: edit the manifest, re-render.
# After a re-render the tree must be committed as-is — `git status` on a clean
# manifest is empty, which is what makes drift visible in review.
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1

output_dir=""
list=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-dir|--out-dir)
      [ "$#" -ge 2 ] || { printf 'render_dashboards: %s needs a directory\n' "$1" >&2; exit 2; }
      output_dir="$2"
      shift 2
      ;;
    --output-dir=*|--out-dir=*)
      output_dir="${1#*=}"
      shift
      ;;
    --list)
      list=1
      shift
      ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      printf 'render_dashboards: unknown option %s\n' "$1" >&2
      exit 2
      ;;
    *)
      output_dir="$1"
      shift
      ;;
  esac
done

set -- --manifest scripts/dashboards/manifest.json
if [ "$list" -eq 1 ]; then
  set -- "$@" --list
elif [ -n "$output_dir" ]; then
  set -- "$@" --output-dir "$output_dir"
fi

exec python3 scripts/render_namespace_dashboard.py "$@"
