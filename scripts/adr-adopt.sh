#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Adopt pending ADRs (GUL-582, docs/adr/pending/).
#
# A work order writes its ADR to docs/adr/pending/<slug>.md with no number and
# never edits docs/adr/README.md — that row is the one hunk every ADR-bearing PR
# used to touch, and the only thing that conflicted in four merges on GUL-553.
# This script is the single writer that hands out the number afterwards:
#
#   rename  docs/adr/pending/<slug>.md   -> docs/adr/adr-NNN-<slug>.md
#   H1      "# <title>"                  -> "# ADR-NNN: <title>"
#   status  "- **Status**: Pending"      -> "- **Status**: Accepted"
#   index   append "| ADR-NNN | <title> | Accepted | <date from the ADR> |"
#           after the last "| ADR-NNN |" row of docs/adr/README.md
#
# NNN is the highest existing docs/adr/adr-NNN-*.md plus one, so a number is
# never reused and never allocated by a branch that cannot see its siblings.
#
# Usage:
#   bash scripts/adr-adopt.sh            # dry run, prints the plan, changes nothing
#   bash scripts/adr-adopt.sh --apply    # renames, rewrites and inserts the rows
#   bash scripts/adr-adopt.sh --root DIR # operate on DIR instead of this repo (tests)
#
# Exit: 0 = done (or nothing to adopt), 1 = a pending ADR cannot be adopted,
#       2 = usage/setup error (no index table, no docs/adr).
#
# Bash 3.2 (macOS) on purpose: no associative arrays, no ${var,,}.
# ---------------------------------------------------------------------------
set -uo pipefail

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

APPLY=0
ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --root) shift; ROOT="${1:-}" ;;
    --root=*) ROOT="${1#--root=}" ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'usage: bash scripts/adr-adopt.sh [--apply] [--root DIR]\n' >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$ROOT" ]; then
  ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fi

ADR_DIR="$ROOT/docs/adr"
INDEX="$ADR_DIR/README.md"
PENDING="$ADR_DIR/pending"

if [ ! -d "$ADR_DIR" ]; then
  printf 'adopt: %s is not a docs/adr directory\n' "$ADR_DIR" >&2
  exit 2
fi
if [ ! -f "$INDEX" ]; then
  printf 'adopt: %s has no README.md index\n' "$ADR_DIR" >&2
  exit 2
fi
if ! grep -q '^| Number | Title | Status | Date |' "$INDEX"; then
  printf 'adopt: %s has no "| Number | Title | Status | Date |" table header\n' "$INDEX" >&2
  exit 2
fi

highest=0
for f in "$ADR_DIR"/adr-*.md; do
  [ -e "$f" ] || continue
  n=$(basename "$f" | sed -E 's/^adr-([0-9]{3})-.*$/\1/')
  case "$n" in
    ''|*[!0-9]*) continue ;;
  esac
  # 10#<n> so a leading zero is decimal, not octal.
  n=$((10#$n))
  [ "$n" -gt "$highest" ] && highest=$n
done

pending_files=""
count=0
if [ -d "$PENDING" ]; then
  for f in "$PENDING"/*.md; do
    [ -e "$f" ] || continue
    pending_files="$pending_files$f
"
    count=$((count + 1))
  done
fi

if [ "$count" -eq 0 ]; then
  printf 'adopt: nothing pending in %s (highest number in use: %03d)\n' "$PENDING" "$highest"
  exit 0
fi

fail=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Validate every pending file before touching anything: a half-adopted tree is
# worse than a refused run.
next=$highest
while IFS= read -r f; do
  [ -n "$f" ] || continue
  base=$(basename "$f")
  slug="${base%.md}"
  h1=$(head -1 "$f")
  if ! printf '%s\n' "$h1" | grep -qE '^# [^ ].*'; then
    printf 'adopt: %s: first line is not a "# <title>" heading\n' "$base" >&2
    fail=1; continue
  fi
  title=${h1#\# }
  case "$title" in
    *'|'*)
      printf 'adopt: %s: the H1 contains "|" and cannot be an index row\n' "$base" >&2
      fail=1; continue ;;
  esac
  case "$title" in
    ADR-[0-9][0-9][0-9]*)
      printf 'adopt: %s: H1 already carries a number; a pending ADR must not reserve one\n' "$base" >&2
      fail=1; continue ;;
  esac
  if ! grep -qxF -- '- **Status**: Pending' "$f"; then
    printf 'adopt: %s: missing "- **Status**: Pending"\n' "$base" >&2
    fail=1; continue
  fi
  date=$(sed -n 's/^- \*\*Date\*\*: \([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)$/\1/p' "$f" | head -1)
  if [ -z "$date" ]; then
    printf 'adopt: %s: missing "- **Date**: YYYY-MM-DD"\n' "$base" >&2
    fail=1; continue
  fi
  next=$((next + 1))
  printf '%s\t%03d\t%s\t%s\t%s\n' "$f" "$next" "$title" "$date" "$slug" >> "$work/plan"
done <<EOF
$pending_files
EOF

if [ "$fail" -ne 0 ]; then
  printf 'adopt: nothing changed.\n' >&2
  exit 1
fi

printf 'adopt: %d pending ADR(s), highest number in use %03d%s\n' \
  "$count" "$highest" "$([ "$APPLY" -eq 1 ] && printf '' || printf ' (dry run: --apply to write)')"
while IFS="$(printf '\t')" read -r path num title date slug; do
  printf '  %s -> adr-%s-%s.md   ADR-%s: %s (%s)\n' \
    "${path#"$ROOT"/}" "$num" "$slug" "$num" "$title" "$date"
done < "$work/plan"

if [ "$APPLY" -ne 1 ]; then
  exit 0
fi

# One rewrite of the index at the end, so the row order equals the number order.
cp "$INDEX" "$work/README.md"

while IFS="$(printf '\t')" read -r path num title date slug; do
  dest="$ADR_DIR/adr-$num-$slug.md"
  if [ -e "$dest" ]; then
    printf 'adopt: %s already exists, refusing to overwrite\n' "$dest" >&2
    exit 1
  fi
  # H1, status: sed in place on a copy first, then move into place.
  sed -e "1s|^# .*\$|# ADR-$num: $title|" \
      -e 's|^- \*\*Status\*\*: Pending$|- **Status**: Accepted|' \
      "$path" > "$work/adr.md" || exit 1
  mv "$work/adr.md" "$dest"
  rm -f "$path"
  # Insert the row after the last "| ADR-NNN |" line of the table.
  awk -v row="| ADR-$num | $title | Accepted | $date |" '
    { lines[NR] = $0 }
    END {
      last = 0
      for (i = 1; i <= NR; i++) if (lines[i] ~ /^\| ADR-[0-9][0-9][0-9] \|/) last = i
      if (last == 0) { print "adopt: no index rows to anchor the new row" > "/dev/stderr"; exit 3 }
      for (i = 1; i <= NR; i++) { print lines[i]; if (i == last) print row }
    }' "$work/README.md" > "$work/README.next" || exit 1
  mv "$work/README.next" "$work/README.md"
done < "$work/plan"

cp "$work/README.md" "$INDEX"
printf 'adopt: wrote %s and %d file(s); commit with: git add docs/adr && git status\n' \
  "${INDEX#"$ROOT"/}" "$count"
exit 0
