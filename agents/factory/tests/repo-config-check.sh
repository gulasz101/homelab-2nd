#!/usr/bin/env bash
# Per-repo safety settings in the factory (GUL-2238): AC-1 and AC-2.
#
# AC-1  `check-gate --never-paths-ref` reads the never-path list from the PR's
#       base commit, fails as setup when it is missing there, and behaves as
#       today without the flag (CONTRACT.md points 2 and 5).
# AC-2  the engine passes a repo's neverPaths to the gate, never auto-merges a
#       repo with no neverPaths or with autoMerge false, and skips deploy_check
#       for a repo with postMergeCheck false (ENGINE.md).
#
# Offline: stub `gh` from generated fixtures, throw-away git repos under
# TMPDIR, engine.py driven in-process. Bare invocation runs both ACs; `--ac
# AC-n` runs one (scripts/check.sh discovery). bash 3.2-safe.
set -u
# GUL-2080: an inherited GIT_DIR made fixture repos write into the real checkout.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX GIT_CONFIG GIT_CONFIG_GLOBAL
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# GUL-2091: a dead TMPDIR is a setup error, not a test result.
if [ -z "${TMPDIR:-}" ] || [ ! -d "${TMPDIR:-}" ] || [ ! -w "${TMPDIR:-}" ]; then
  echo "ENV: TMPDIR '${TMPDIR:-}' does not exist or is not writable" >&2
  exit 2
fi
exec python3 "$ROOT/agents/factory/tests/test_repo_config.py" "$@"
