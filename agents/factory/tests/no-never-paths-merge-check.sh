#!/usr/bin/env bash
# A repo with no neverPaths is never auto-merged (GUL-2254, F-1 of GUL-2238):
# AC-1.
#
# AC-1  through the real step_gate, a repo with no neverPaths is never merged by
#       the App, and st['gate']['autoMerge']['why'] contains 'no never-path list'.
#
# Offline: engine.py imported in-process, `check-gate`/`gh`/App-token/subprocess
# seams stubbed, nothing written outside memory. Bare invocation runs AC-1;
# `--ac AC-1` runs one (scripts/check.sh discovery). bash 3.2-safe.
set -u
# GUL-2080: an inherited GIT_DIR made fixture repos write into the real checkout.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX GIT_CONFIG GIT_CONFIG_GLOBAL
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
exec python3 "$ROOT/agents/factory/tests/test_no_never_paths_merge.py" "$@"
