#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Every ADR the repo cites must exist.
#
#   ADR-NNN            -> docs/adr/adr-NNN-*.md, or a documented gap (below)
#   pending ADR <slug> -> docs/adr/pending/<slug>.md, or docs/adr/adr-NNN-<slug>.md once adopted
#
# Why: numbers are allocated at adoption (ADR-111, docs/adr/README.md#writing-an-adr). On 2026-11-12
# a branch cited "ADR-133/134" in manifest comments before adopting anything; another branch then
# adopted an unrelated ADR as 133. A premature number doesn't just dangle, it silently points at
# the wrong decision. Cite a pending ADR by its slug instead.
#
# Documented gaps (docs/adr/README.md notes): 001-005 and 010 are vault-era ADRs that live in the
# Obsidian vault; 006-009 were never used; 045 is reserved (H2-212); 104 is burnt.
#
# Bash 3.2 compatible (runs on the Air and in CI).
# ---------------------------------------------------------------------------
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT" || exit 1
GAPS=" 001 002 003 004 005 006 007 008 009 010 045 104 "
fail=0

for ref in $(git grep -hoIE 'ADR-[0-9]{3}' -- . ':!docs/adr/README.md' ':!scripts/tests/adr-ref-check.sh' | sort -u); do
  n=${ref#ADR-}
  ls docs/adr/adr-"$n"-*.md >/dev/null 2>&1 && continue
  case "$GAPS" in *" $n "*) continue ;; esac
  echo "FAIL: $ref is cited but docs/adr/adr-$n-*.md does not exist:"
  git grep -nIE "$ref([^0-9]|\$)" -- . ':!docs/adr/README.md' | head -5 | cut -c1-200 | sed 's/^/  /'
  fail=1
done

for slug in $(git grep -hoIE 'pending ADR `?[a-z0-9]+(-[a-z0-9]+)+' -- . ':!scripts/tests/adr-ref-check.sh' | sed -E 's/^pending ADR `?//' | sort -u); do
  [ -f "docs/adr/pending/$slug.md" ] && continue
  ls docs/adr/adr-[0-9][0-9][0-9]-"$slug".md >/dev/null 2>&1 && continue
  echo "FAIL: 'pending ADR $slug' matches neither docs/adr/pending/$slug.md nor an adopted adr-NNN-$slug.md:"
  git grep -nIF "pending ADR $slug" -- . | head -3 | cut -c1-200 | sed 's/^/  /'
  git grep -nIF "pending ADR \`$slug" -- . | head -3 | cut -c1-200 | sed 's/^/  /'
  fail=1
done

[ "$fail" = 0 ] && echo "ok   every cited ADR exists (numbers and pending slugs)"
exit $fail
