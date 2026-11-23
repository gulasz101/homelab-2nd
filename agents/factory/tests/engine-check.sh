#!/usr/bin/env bash
# engine.py offline test suite (GUL-2037 phase 2). The contract is
# agents/factory/ENGINE.md. Everything runs against a fake HTTP server, a fake
# `gh` and throw-away git repos inside test_engine.py: no real Paperclip,
# Hindsight, docs-mcp, Lodge or GitHub call. bash 3.2-safe.
# Exit 0 only if every case passes. Picked up by scripts/check.sh's
# */tests/*-check.sh discovery.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
exec python3 "$ROOT/agents/factory/tests/test_engine.py"
