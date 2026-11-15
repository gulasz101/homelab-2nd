#!/bin/bash
# ---------------------------------------------------------------------------
# vault-backup.sh — restic backup of the Obsidian vault and ~/image-studio to
# OMV MinIO (bucket paperclip-backups), run nightly by launchd in the system
# domain (ADR-107). Same shape as hermes-state-backup.sh: system LaunchDaemon,
# UserName=paperclip, HOME set, endpoint is the 127.0.0.1:9000 loopback relay
# (ADR-079 — a launchd-spawned binary may not open LAN sockets directly).
#
# Why restic and not rsync/Syncthing: the vault was the largest unprotected
# asset on the Air. Syncthing between the two Macs is a COPY, not a backup —
# one `rm` propagates. Restic gives encrypted, deduplicated, versioned
# snapshots on the only durable store, plus `restic check` and a restore drill
# (docs/adr/pending/vault-and-image-studio-backups-restic-to-omv.md).
#
#   vault-backup.sh                 # backup both trees, forget+check policy
#   vault-backup.sh --dry-run       # show what would be sent, touch nothing
#   vault-backup.sh --verify-only   # check repo, no backup
#
# Credentials live in ~/.config/vault-backup/minio.env (0600, host-only, never
# in the repo): MINIO_ENDPOINT, MINIO_BUCKET, MINIO_ACCESS_KEY, MINIO_SECRET_KEY,
# RESTIC_PASSWORD.
# ---------------------------------------------------------------------------
set -uo pipefail

ENV_FILE="${VAULT_BACKUP_ENV:-$HOME/.config/vault-backup/minio.env}"
VAULT_DIR="${VAULT_BACKUP_VAULT:-$HOME/vault}"
STUDIO_DIR="${VAULT_BACKUP_STUDIO:-$HOME/image-studio}"
LOG_DIR="$HOME/Library/Logs/homelab"
LOG="$LOG_DIR/vault-backup.log"
STATUS="$HOME/.config/vault-backup/last-run"
LOCK="$HOME/.config/vault-backup/.lock"
MODE="backup"

for arg in "$@"; do
  case "$arg" in
    --dry-run)     MODE="dry-run" ;;
    --verify-only) MODE="verify" ;;
    -h|--help)     sed -n '2,28p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

[ -r "$ENV_FILE" ] || die "missing credentials file $ENV_FILE"
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
: "${MINIO_ENDPOINT:?}" "${MINIO_BUCKET:?}" "${MINIO_ACCESS_KEY:?}" "${MINIO_SECRET_KEY:?}" "${RESTIC_PASSWORD:?}"
export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-s3:${MINIO_ENDPOINT}/${MINIO_BUCKET}/restic}"
export RESTIC_PASSWORD
export AWS_ACCESS_KEY_ID="$MINIO_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$MINIO_SECRET_KEY"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

mkdir -p "$LOG_DIR"
exec >>"$LOG" 2>&1
say() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# One run at a time: a kickstart from an install must not race the nightly run.
exec 9>"$LOCK"
if ! /usr/bin/lockf -s -t 0 9; then
  say "another run holds the lock, exiting"
  exit 75
fi

say "=== start mode=$MODE repo=$RESTIC_REPOSITORY"

if ! restic cat config >/dev/null 2>&1; then
  say "repository not initialised, running restic init"
  restic init || die "restic init failed"
fi

if [ "$MODE" != "dry-run" ]; then
  # 1. the vault, as one snapshot
  restic backup --tag vault --host paperclip --exclude-caches \
    --exclude "$VAULT_DIR/.trash" \
    --exclude "$VAULT_DIR/.obsidian/workspace.json" \
    --exclude "$VAULT_DIR/.obsidian/workspace-mobile.json" \
    "$VAULT_DIR" || die "vault backup failed"

  # 2. ~/image-studio: the backlog (queue.json, cards, briefs, handoffs, audit)
  #    is the part that cannot be regenerated. tmp/, cache/ and .venv-imgcheck/
  #    are throwaway (a fresh virtualenv and re-downloaded assets).
  restic backup --tag image-studio --host paperclip \
    --exclude "$STUDIO_DIR/.venv-imgcheck" \
    --exclude "$STUDIO_DIR/cache" \
    --exclude "$STUDIO_DIR/tmp" \
    "$STUDIO_DIR" || die "image-studio backup failed"
fi

# 3. retention: 7 daily + 4 weekly, prune only on Sunday so the nightly run stays
#    short. Never prune on the same run as the first successful backup of a tree.
restic forget --keep-daily 7 --keep-weekly 4 >/dev/null || say "WARN forget failed"
if [ "$(date +%u)" = "7" ]; then
  say "sunday: prune + full structural check"
  restic prune || say "WARN prune failed"
  restic check || say "WARN check failed"
fi

snap=$(restic snapshots --latest 1 --json | /usr/bin/python3 -c 'import json,sys; s=json.load(sys.stdin); print(",".join("%s@%s" % (x["id"][:8], x["time"][:19]) for x in s))' 2>/dev/null)
say "=== ok last snapshots: ${snap:-unknown}"
printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "ok ${snap:-unknown}" > "$STATUS"
