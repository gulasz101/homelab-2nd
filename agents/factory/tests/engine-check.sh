#!/usr/bin/env bash
# engine.py offline test suite (GUL-2037 phase 2). The contract is
# agents/factory/ENGINE.md. Everything runs against a fake HTTP server, a fake
# `gh` and throw-away git repos inside test_engine.py: no real Paperclip,
# Hindsight, docs-mcp, Lodge or GitHub call. bash 3.2-safe.
# Exit 0 only if every case passes. Picked up by scripts/check.sh's
# */tests/*-check.sh discovery.
set -u
# GUL-2080: an inherited GIT_DIR (a git hook, a parent tool) made the fixture repos
# below write into the real checkout. Drop every repo-locating git variable first.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX GIT_CONFIG GIT_CONFIG_GLOBAL
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
exec python3 "$ROOT/agents/factory/tests/test_engine.py"
