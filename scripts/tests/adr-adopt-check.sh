#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/adr-adopt.sh does what docs/adr/pending/ promises (GUL-582).
#
# The point of the script is that no branch ever hands out an ADR number, so the
# test has to prove the number is taken from the tree, once, and that a bad
# pending ADR changes nothing at all. It runs against throwaway trees under a
# temp dir (--root), plus one dry run against this repo.
#
# Discovered and run by scripts/check.sh, like every */tests/*-check.sh.
# Exit: 0 = every case passed, 1 = at least one failed.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/scripts/adr-adopt.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
head1() { printf '\n== %s\n' "$1"; }

[ -f "$SCRIPT" ] && ok "scripts/adr-adopt.sh exists" || { bad "scripts/adr-adopt.sh missing"; exit 1; }
bash -n "$SCRIPT" && ok "passes bash -n" || bad "bash -n failed"

# ---- fixture ---------------------------------------------------------------
new_tree() { # $1 = dir
  mkdir -p "$1/docs/adr/pending"
  cat > "$1/docs/adr/README.md" <<'EOF'
# Architecture Decision Records (ADRs)

## Index

| Number | Title | Status | Date |
|---|---|---|---|
| ADR-007 | An existing accepted decision | Accepted | 2026-10-01 |

> Note: ADR-001 lives in the vault.

## Writing an ADR

Use the template.
EOF
  cat > "$1/docs/adr/adr-007-an-existing-accepted-decision.md" <<'EOF'
# ADR-007: An existing accepted decision

- **Status**: Accepted
- **Date**: 2026-10-01
EOF
  cat > "$1/docs/adr/pending/a-first-pending.md" <<'EOF'
# A first pending decision

- **Status**: Pending
- **Date**: 2026-10-28
- **Issue**: GUL-1

## Context
x
EOF
  cat > "$1/docs/adr/pending/b-second-pending.md" <<'EOF'
# A second pending decision

- **Status**: Pending
- **Date**: 2026-10-29
- **Issue**: GUL-2

## Context
x
EOF
}

# ---- 1. dry run changes nothing -------------------------------------------
head1 "1. dry run"
t="$WORK/dry"; new_tree "$t"
before=$(cd "$t" && find . -type f | sort | xargs shasum | shasum)
out=$(bash "$SCRIPT" --root "$t" 2>&1); rc=$?
after=$(cd "$t" && find . -type f | sort | xargs shasum | shasum)
[ "$rc" -eq 0 ] && ok "dry run exits 0" || bad "dry run exited $rc: $out"
[ "$before" = "$after" ] && ok "dry run wrote nothing" || bad "dry run changed the tree"
printf '%s\n' "$out" | grep -q 'adr-008-a-first-pending.md' \
  && ok "dry run plans 008 for the first pending file" || bad "dry run does not name 008: $out"
printf '%s\n' "$out" | grep -q 'adr-009-b-second-pending.md' \
  && ok "dry run plans 009 for the second pending file" || bad "dry run does not name 009: $out"
[ "$(ls "$t/docs/adr/pending" | wc -l | tr -d ' ')" = "2" ] \
  && ok "dry run left both pending files in place" || bad "dry run moved a pending file"

# ---- 2. apply -------------------------------------------------------------
head1 "2. --apply"
t="$WORK/apply"; new_tree "$t"
out=$(bash "$SCRIPT" --root "$t" --apply 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "--apply exits 0" || bad "--apply exited $rc: $out"
[ -z "$(ls -A "$t/docs/adr/pending" 2>/dev/null)" ] \
  && ok "pending/ is empty afterwards" || bad "pending/ still holds files: $(ls "$t/docs/adr/pending")"
for n in 008 009; do
  f=$(ls "$t/docs/adr"/adr-$n-*.md 2>/dev/null | head -1)
  if [ -n "$f" ]; then
    ok "adr-$n-*.md exists"
  else
    bad "adr-$n-*.md missing"; continue
  fi
  head -1 "$f" | grep -q "^# ADR-$n: " && ok "$n: H1 carries the number" \
    || bad "$n: H1 is '$(head -1 "$f")'"
  grep -qxF -- '- **Status**: Accepted' "$f" && ok "$n: status flipped to Accepted" \
    || bad "$n: status is not Accepted"
  grep -qxF -- '- **Status**: Pending' "$f" && bad "$n: Pending status survived" || true
done
grep -q '^| ADR-008 | A first pending decision | Accepted | 2026-10-28 |$' "$t/docs/adr/README.md" \
  && ok "row 008 uses the ADR's own date" || bad "row 008 missing or wrong: $(grep 'ADR-008' "$t/docs/adr/README.md")"
grep -q '^| ADR-009 | A second pending decision | Accepted | 2026-10-29 |$' "$t/docs/adr/README.md" \
  && ok "row 009 uses the ADR's own date" || bad "row 009 missing or wrong: $(grep 'ADR-009' "$t/docs/adr/README.md")"
# Row order: 007, 008, 009, then the note — never appended below the prose.
order=$(grep -n '^| ADR-00[789] ' "$t/docs/adr/README.md" | cut -d: -f1 | tr '\n' ' ')
note=$(grep -n '^> Note: ADR-001' "$t/docs/adr/README.md" | cut -d: -f1)
last_row=$(printf '%s\n' "$order" | awk '{print $NF}')
[ -n "$note" ] && [ "$last_row" -lt "$note" ] \
  && ok "new rows sit inside the table, above the notes" \
  || bad "rows landed outside the table (rows: $order, note line: $note)"
grep -q 'ADR-010' "$t/docs/adr/README.md" && bad "a number was invented" || ok "no number past 009"

# ---- 3. idempotent --------------------------------------------------------
head1 "3. second --apply is a no-op"
before=$(cd "$t" && find . -type f | sort | xargs shasum | shasum)
out=$(bash "$SCRIPT" --root "$t" --apply 2>&1); rc=$?
after=$(cd "$t" && find . -type f | sort | xargs shasum | shasum)
[ "$rc" -eq 0 ] && ok "second run exits 0" || bad "second run exited $rc: $out"
[ "$before" = "$after" ] && ok "second run changed nothing" || bad "second run rewrote the tree"

# ---- 4. a numbered pending ADR is refused, nothing moves ------------------
head1 "4. refusal"
t="$WORK/refuse"; new_tree "$t"
cat > "$t/docs/adr/pending/c-numbered.md" <<'EOF'
# ADR-010: A work order that reserved its own number

- **Status**: Pending
- **Date**: 2026-10-29
EOF
before=$(cd "$t" && find . -type f | sort | xargs shasum | shasum)
out=$(bash "$SCRIPT" --root "$t" --apply 2>&1); rc=$?
after=$(cd "$t" && find . -type f | sort | xargs shasum | shasum)
[ "$rc" -eq 1 ] && ok "refuses a pending ADR that carries a number" || bad "exit was $rc, expected 1"
printf '%s\n' "$out" | grep -q 'must not reserve one' && ok "says why" || bad "no reason printed: $out"
[ "$before" = "$after" ] && ok "refusal changed nothing (not even the valid ones)" \
  || bad "refusal half-adopted the tree"

# ---- 5. this repo, dry run ------------------------------------------------
head1 "5. this repo (dry run)"
out=$(bash "$SCRIPT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "dry run on the real tree exits 0" || bad "dry run on the real tree exited $rc: $out"

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf 'adr-adopt: PASS\n'
  exit 0
fi
printf 'adr-adopt: FAIL\n'
exit 1
