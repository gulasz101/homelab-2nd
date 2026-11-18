#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# homelab-install-agent-rules.sh — deploy the agents' rule files from git to the
# places Paperclip reads them on the Air (GUL-1572, pending ADR "Agent rule files
# are versioned in git, deployed by script and owned by Wojtek").
#
#   bash homelab-install-agent-rules.sh                    # dry run: state of every target
#   bash homelab-install-agent-rules.sh --apply            # write the safe updates
#   bash homelab-install-agent-rules.sh --apply --overwrite-drift   # also replace hand edits
#   bash homelab-install-agent-rules.sh --adopt-live       # print hand edits as diffs
#
# Targets:
#   agents/instructions/<a>/AGENTS.md -> ~/paperclip-agents/<a>/AGENTS.md     (external bundles)
#   agents/factory/briefs/<stage>.md   -> ~/.paperclip/.../agents/<id>/instructions/AGENTS.md
#                                         (managed bundles; ids from agents/factory/agents.json)
#
# A live file is overwritten only when it is known: identical to the last deploy
# (~/paperclip-agents/.deployed.sha256) or to a version once committed at that repo
# path. Anything else is a hand edit (DRIFT): it is refused and shown, never lost.
#
# Run it as the owner (ADR-093 point 6), as paperclip (never root: the files must stay
# paperclip's), and never while a guarded Pi session is live: factory-guard restores
# ~/paperclip-agents/*/AGENTS.md to its session-start snapshot when the session ends,
# which silently undid an owner fix on 2026-11-15 at 16:42:14.
#
# Exit: 0 = every target in sync or updated; 1 = a target refused (drift/missing); 2 = usage.
# Bash 3.2 (macOS) on purpose.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=homelab-lib.sh
. "$SCRIPT_DIR/homelab-lib.sh"

REPO="${AGENT_RULES_REPO:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)}"
H="${AGENT_RULES_HOME:-$HOME}"
COMPANY="${AGENT_RULES_COMPANY:-0e2eb054-4cb6-4ea1-a2e7-2b1894285d8c}"
MANAGED="$H/.paperclip/instances/default/companies/$COMPANY/agents"
MANIFEST="$H/paperclip-agents/.deployed.sha256"
TS=$(date '+%Y%m%d-%H%M%S')

MODE="dry-run"; OVERWRITE_DRIFT=0; ADOPT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)           MODE="apply" ;;
    --overwrite-drift) OVERWRITE_DRIFT=1 ;;
    --adopt-live)      ADOPT=1 ;;
    -h|--help)         sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

die() { printf 'FATAL: %s\n' "$*" >&2; exit 2; }
[ "$(id -u)" = "0" ] && die "run as paperclip, not root (the rule files must stay paperclip's)"
[ -n "$REPO" ] && [ -d "$REPO/.git" -o -f "$REPO/.git" ] || die "not inside a git checkout: $REPO"
[ -f "$REPO/agents/factory/agents.json" ] || die "missing $REPO/agents/factory/agents.json"

if pgrep -f 'factory-guard/index.ts' >/dev/null 2>&1; then
  if [ "$MODE" = "apply" ]; then
    die "a guarded Pi session is running; it would restore the old files when it ends. Wait for it, then re-run."
  fi
  printf 'WARN: a guarded Pi session is running; --apply will refuse until it ends.\n'
fi

# "<repo path>\t<live path>" for every target
targets() {
  local a
  for a in claude-code opencode pi; do
    printf 'agents/instructions/%s/AGENTS.md\t%s/paperclip-agents/%s/AGENTS.md\n' "$a" "$H" "$a"
  done
  python3 - "$REPO/agents/factory/agents.json" "$MANAGED" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
for stage in cfg.get("stages", {}).values():
    name = (stage.get("name") or "").lower()
    if name in ("tester", "builder", "reviewer", "verifier") and stage.get("agentId"):
        print(f"agents/factory/briefs/{name}.md\t{sys.argv[2]}/{stage['agentId']}/instructions/AGENTS.md")
PY
}

tilde() { printf '%s' "$1" | sed "s#^$H#~#"; }
sha() { homelab_sha256 "$1" | awk '{print $1}'; }
manifest_sha() { [ -f "$MANIFEST" ] && awk -v p="$1" '$2 == p { s = $1 } END { if (s) print s }' "$MANIFEST"; }

# The commit (short) whose version of <rel> is byte-identical to <live>, if any.
repo_version_of() {
  local rel="$1" live="$2" blob c
  blob=$(git -C "$REPO" hash-object --no-filters -- "$live" 2>/dev/null) || return 0
  git -C "$REPO" log --format=%H -- "$rel" 2>/dev/null | while IFS= read -r c; do
    if [ "$(git -C "$REPO" rev-parse -q --verify "$c:$rel" 2>/dev/null)" = "$blob" ]; then
      printf '%s\n' "${c:0:9}"; break
    fi
  done
}

rc=0
new_manifest=$(mktemp "${TMPDIR:-/tmp}/agent-rules-manifest.XXXXXX")
trap 'rm -f "$new_manifest"' EXIT
[ -f "$MANIFEST" ] && cp "$MANIFEST" "$new_manifest"
record() {  # record <sha> <live> in the new manifest
  awk -v p="$2" '$2 != p' "$new_manifest" > "$new_manifest.t"; mv "$new_manifest.t" "$new_manifest"
  printf '%s  %s\n' "$1" "$2" >> "$new_manifest"
}

printf 'agent rules: repo %s (%s) -> %s   mode=%s\n' "$REPO" "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)" "$H" "$MODE"
managed_targets=""
while IFS="$(printf '\t')" read -r rel live; do
  [ -n "$rel" ] || continue
  managed_targets="$managed_targets $live"
  src="$REPO/$rel"
  short=$(tilde "$live")
  if [ ! -f "$src" ]; then printf 'MISSING repo  %s\n' "$rel"; rc=1; continue; fi
  if [ ! -f "$live" ]; then printf 'MISSING live  %s  (not created: the adapter must already point at it)\n' "$short"; rc=1; continue; fi
  rs=$(sha "$src"); ls_=$(sha "$live")
  if [ "$rs" = "$ls_" ]; then
    printf 'in sync       %s\n' "$short"; record "$rs" "$live"; continue
  fi
  why=""; ms=$(manifest_sha "$live")
  if [ -n "$ms" ] && [ "$ms" = "$ls_" ]; then
    why="live is the last deploy"
  else
    c=$(repo_version_of "$rel" "$live")
    [ -n "$c" ] && why="live is the repo version from $c"
  fi
  if [ -z "$why" ]; then
    printf 'DRIFT         %s  (hand edit: matches neither the last deploy nor any committed version)\n' "$short"
    if [ "$ADOPT" = "1" ]; then
      printf -- '--- to bring this edit into git, apply to %s:\n' "$rel"
      diff -u --label "a/$rel" --label "b/$rel" "$src" "$live" | sed 's/^/    /'
    else
      diff -u "$live" "$src" | sed -n '3,14p' | sed 's/^/    /'
    fi
    if [ "$MODE" = "apply" ] && [ "$OVERWRITE_DRIFT" = "1" ]; then
      why="hand edit, overwritten on request"
    else
      rc=1; continue
    fi
  fi
  if [ "$MODE" != "apply" ]; then
    printf 'would update  %s  (%s)\n' "$short" "$why"; continue
  fi
  cp -p "$live" "$live.bak-agent-rules-$TS" || { printf 'FAILED backup %s\n' "$short"; rc=1; continue; }
  cat "$src" > "$live"
  if [ "$(sha "$live")" = "$rs" ]; then
    printf 'updated       %s  (%s; backup .bak-agent-rules-%s)\n' "$short" "$why" "$TS"; record "$rs" "$live"
  else
    printf 'FAILED write  %s  (restore from .bak-agent-rules-%s)\n' "$short" "$TS"; rc=1
  fi
done < <(targets)

# Managed bundles with no repo source: covered by the restic snapshot and watchdog check 10 only.
for f in "$MANAGED"/*/instructions/AGENTS.md; do
  [ -f "$f" ] || continue
  case " $managed_targets " in *" $f "*) continue ;; esac
  printf 'not in git    %s  (backup + drift alert only)\n' "$(tilde "$f")"
done

if [ "$MODE" = "apply" ]; then
  mkdir -p "$(dirname "$MANIFEST")" && cp "$new_manifest" "$MANIFEST"
  printf 'manifest      %s\n' "$(tilde "$MANIFEST")"
else
  printf 'dry run only: re-run with --apply to write.\n'
fi
exit $rc
