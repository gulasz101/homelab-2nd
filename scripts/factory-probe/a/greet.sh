#!/bin/sh
# ---------------------------------------------------------------------------
# scripts/factory-probe/a/greet.sh — GUL-2050 engine probe (a).
#
#   sh scripts/factory-probe/a/greet.sh Wojtek  -> Hello, Wojtek!
#   sh scripts/factory-probe/a/greet.sh         -> Hello, world!
#
# Always exits 0. Hermetic: no network, no cluster, no secrets. POSIX sh only,
# because it is invoked as `sh <path>` and CI runs it on ubuntu as well.
# ---------------------------------------------------------------------------
set -u

name=${1-}
if [ -z "$name" ]; then
  name=world
fi

printf 'Hello, %s!\n' "$name"
exit 0
