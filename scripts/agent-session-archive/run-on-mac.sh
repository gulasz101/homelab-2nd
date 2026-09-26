#!/usr/bin/env bash
#
# Agent session archive — M1 Max side (H2-45).
#
# Run this ON the Mac that owns the session history. It never deletes anything:
# not from the source, not from the destination, not from staging. rsync runs
# without any delete or source-removal flag, and there is no destructive shell
# command anywhere in this file (a unit test enforces that).
#
# What it does, per tool:
#   1. build an immutable staging tree (live SQLite DBs are snapshotted with the
#      online-backup API first, never copied raw)
#   2. manifest the staging tree  -> <tool>.source.manifest
#   3. rsync staging -> OMV (<OMV_HOST>:<OMV_DEST>/<tool>/source/)
#   4. manifest what actually landed on OMV -> destination.manifest
#   5. verify: zero differences required, otherwise the run stops
#   6. pack the staging tree (zstd when available, else gzip) and upload it to
#      MinIO s3://<bucket>/<tool>/ (bucket created if missing)
#
# Usage:
#   MINIO_ACCESS_KEY=... MINIO_SECRET_KEY=... ./run-on-mac.sh
#   ./run-on-mac.sh --dry-run          # plan only, no writes, no creds needed
#   TOOLS="opencode" ./run-on-mac.sh   # one tool only
#
# Exit codes: 0 all verified · 1 a verification difference · 2 usage/IO error

set -euo pipefail

OMV_HOST="${OMV_HOST:-omv.local}"
OMV_DEST="${OMV_DEST:-/srv/dev-disk-by-uuid-cda9bf6e-0ed1-4e61-b063-1cbab7351886/openchamber/data/agent-session-archive}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://openmediavault.local:9000}"
MINIO_BUCKET="${MINIO_BUCKET:-agent-session-archive}"
TOOLS="${TOOLS:-claude-code opencode codex mistral-vibe}"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
STAGE="${STAGE:-${TMPDIR:-/tmp}/agent-session-archive-${STAMP}}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL_PY="$HERE/agent_archive.py"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '1,26p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '%s  %s\n' "$(date -u '+%H:%M:%S')" "$*"; }
die() { printf 'ERROR  %s\n' "$*" >&2; exit 2; }

command -v python3 >/dev/null 2>&1 || die "python3 is required (macOS: xcode-select --install)"
command -v rsync   >/dev/null 2>&1 || die "rsync is required"
[ -f "$TOOL_PY" ] || die "missing $TOOL_PY — run this from a homelab-2nd checkout"
[ -d "$HERE/tests" ] || log "note: no tests/ next to this script"

RSYNC_EXTRA=""
if rsync --help 2>&1 | grep -q -- '--info='; then RSYNC_EXTRA="--info=stats2"; fi

# Must mirror DEFAULT_EXCLUDES in agent_archive.py, so the bytes on OMV are
# exactly the files the manifest verifies (and no macOS junk rides along).
RSYNC_NOISE="--exclude .DS_Store --exclude *.tmp --exclude *.temp \
--exclude *-wal --exclude *-shm --exclude __pycache__ --exclude *.pyc \
--exclude .Trashes --exclude .Spotlight-V100 --exclude .fseventsd"

mkdir -p "$STAGE"
log "staging directory: $STAGE"
log "target:            ${OMV_HOST}:${OMV_DEST}"
log "minio:             ${MINIO_ENDPOINT} bucket=${MINIO_BUCKET}"

# Staging return codes.
RC_OK=0
RC_ABSENT=10   # source directory does not exist -> skip, not a failure
RC_ERROR=11    # staging failed -> a hard failure, never silently skipped

# --------------------------------------------------------------------------
# Staging
# --------------------------------------------------------------------------

stage_tree() {
  # $1 = tool, $2 = source directory
  local tool="$1" src="$2"
  if [ ! -d "$src" ]; then
    log "SKIP $tool: $src does not exist"
    return "$RC_ABSENT"
  fi
  mkdir -p "$STAGE/$tool"
  # -a --no-D: archive mode, no device/special files, no delete flag.
  rsync -a --no-D $RSYNC_NOISE "$src/" "$STAGE/$tool/" >/dev/null || return "$RC_ERROR"
  return "$RC_OK"
}

stage_opencode() {
  # The live OpenCode DB is SQLite in WAL mode: a raw copy can be torn, so the
  # live DB and its sidecars are excluded and a consistent snapshot is put back
  # at the same relative path. Never archive a database you cannot snapshot.
  local src="$HOME/.local/share/opencode"
  if [ ! -d "$src" ]; then
    log "SKIP opencode: $src does not exist"
    return "$RC_ABSENT"
  fi
  mkdir -p "$STAGE/opencode"
  rsync -a --no-D $RSYNC_NOISE \
    --exclude opencode.db --exclude opencode.db-wal --exclude opencode.db-shm \
    "$src/" "$STAGE/opencode/" >/dev/null || return "$RC_ERROR"
  if [ ! -f "$src/opencode.db" ]; then
    log "FAIL opencode: no opencode.db at $src — nothing consistent to archive"
    return "$RC_ERROR"
  fi
  python3 "$TOOL_PY" sqlite-snapshot \
    --src "$src/opencode.db" \
    --out "$STAGE/opencode/opencode.db" || return "$RC_ERROR"
  [ -f "$STAGE/opencode/opencode.db" ] || return "$RC_ERROR"
  return "$RC_OK"
}

# --------------------------------------------------------------------------
# Per-tool pipeline
# --------------------------------------------------------------------------

TOOLS_DONE=""
TOOLS_SKIPPED=""
TOOLS_FAILED=""

for tool in $TOOLS; do
  log "── $tool ─────────────────────────────────────────────"
  rc="$RC_OK"
  case "$tool" in
    claude-code)  stage_tree claude-code  "$HOME/.claude/projects"   || rc=$? ;;
    opencode)     stage_opencode                                     || rc=$? ;;
    codex)        stage_tree codex        "$HOME/.codex/sessions"    || rc=$? ;;
    mistral-vibe) stage_tree mistral-vibe "$HOME/.vibe/logs/session" || rc=$? ;;
    *) die "unknown tool in TOOLS: $tool" ;;
  esac
  if [ "$rc" = "$RC_ABSENT" ]; then
    TOOLS_SKIPPED="$TOOLS_SKIPPED $tool"
    continue
  fi
  if [ "$rc" != "$RC_OK" ]; then
    log "FAILED $tool: staging failed (rc=$rc) — refusing to archive a partial tree"
    TOOLS_FAILED="$TOOLS_FAILED $tool"
    continue
  fi

  local_manifest="$STAGE/$tool.source.manifest"
  remote_dir="$OMV_DEST/$tool"
  remote_manifest="$remote_dir/manifests/destination.manifest"

  # 2. manifest the staging tree — this is the source of truth being verified.
  manifest_out="$(python3 "$TOOL_PY" manifest "$STAGE/$tool" -o "$local_manifest")"
  printf '%s\n' "$manifest_out"
  staged_files="$(printf '%s\n' "$manifest_out" | sed -n 's/^manifest: \([0-9][0-9]*\) files.*/\1/p')"
  if [ -z "$staged_files" ] || [ "$staged_files" -eq 0 ]; then
    log "FAILED $tool: staged manifest is empty — an empty tree always verifies, so this is treated as a failure"
    TOOLS_FAILED="$TOOLS_FAILED $tool"
    continue
  fi

  if [ "$DRY_RUN" = "1" ]; then
    rsync -a --no-D -n $RSYNC_EXTRA "$STAGE/$tool/" "$OMV_HOST:$remote_dir/source/"
    log "DRY-RUN: skipped remote manifest, verify and upload for $tool"
    TOOLS_DONE="$TOOLS_DONE $tool"
    continue
  fi

  # 3. copy to OMV.
  ssh "$OMV_HOST" "mkdir -p '$remote_dir/source' '$remote_dir/manifests'"
  rsync -a --no-D $RSYNC_EXTRA "$STAGE/$tool/" "$OMV_HOST:$remote_dir/source/"

  # 4. manifest what actually landed, computed on OMV itself (not over NFS and
  #    not from the local staging tree — otherwise this proves nothing).
  ssh "$OMV_HOST" "command -v python3 >/dev/null 2>&1" \
    || die "python3 is required on $OMV_HOST to hash the destination"
  ssh "$OMV_HOST" "python3 - manifest '$remote_dir/source' -o '$remote_manifest'" \
    < "$TOOL_PY" >/dev/null
  ssh "$OMV_HOST" "cat '$remote_manifest'" > "$STAGE/$tool.destination.manifest"

  # 5. the gate.
  if python3 "$TOOL_PY" verify "$local_manifest" "$STAGE/$tool.destination.manifest"; then
    log "VERIFIED $tool: source and destination manifests match with zero differences"
    TOOLS_DONE="$TOOLS_DONE $tool"
  else
    log "FAILED $tool: manifest difference — nothing is considered archived for $tool"
    TOOLS_FAILED="$TOOLS_FAILED $tool"
    continue
  fi

  # Keep the source manifest alongside the data at both ends.
  ssh "$OMV_HOST" "cat > '$remote_dir/manifests/source.manifest'" < "$local_manifest"

  # 6. cold copy to MinIO.
  if [ -z "${MINIO_ACCESS_KEY:-}" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
    log "SKIP minio cold copy for $tool: no MINIO_ACCESS_KEY / AWS_ACCESS_KEY_ID in the environment"
    continue
  fi
  pack="$STAGE/$tool-$STAMP.tar.gz"
  if command -v zstd >/dev/null 2>&1; then
    pack="$STAGE/$tool-$STAMP.tar.zst"
    tar -cf - -C "$STAGE/$tool" . | zstd -19 -T0 -q -o "$pack"
  else
    tar -czf "$pack" -C "$STAGE/$tool" .
  fi
  python3 "$TOOL_PY" minio-put \
    --endpoint "$MINIO_ENDPOINT" --bucket "$MINIO_BUCKET" \
    --key "$tool/$(basename "$pack")" --file "$pack" --create-bucket
done

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------

log "════ SUMMARY ═══════════════════════════════════════"
log "archived + verified:${TOOLS_DONE:- none}"
log "skipped (not present):${TOOLS_SKIPPED:- none}"
if [ -n "$TOOLS_FAILED" ]; then
  log "NOT VERIFIED:${TOOLS_FAILED}"
  log "Nothing was deleted. Re-run for the tools above before any cleanup."
  exit 1
fi
if [ "$DRY_RUN" = "1" ]; then
  log "dry run: no remote manifests, no verification, no uploads were performed"
fi
log "Staging trees are left in $STAGE (read-only documentation of this run)."
log "Local cleanup on the Mac stays out of scope: it needs verified manifests"
log "plus Wojtek's explicit go-ahead, as a separate issue."
exit 0
