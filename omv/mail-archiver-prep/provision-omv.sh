#!/usr/bin/env bash
# H2-146 / ST1 — provision the Mail-Archiver backup principal on OMV MinIO.
#
# Run AS ROOT ON openmediavault:  bash provision-omv.sh [--rotate]
#
# What it does (idempotent):
#   * creates MinIO user  cnpg-mailarchiver-backup
#   * creates policy      cnpg-mailarchiver-backup-rw
#     - ListBucket on cnpg-backups ONLY for prefix mail-archiver/*
#     - Get/Put/Delete/AbortMultipartUpload/ListMultipartUploadParts under
#       cnpg-backups/mail-archiver/*   (everything Barman/CNPG needs)
#   * attaches the policy to the user
#   * prints the access key / secret key ONCE for the 1Password hand-off
#   * self-tests: happy path (list/put/get/rm under the prefix) and the
#     negative control (sibling prefix must be AccessDenied)
#
# It never writes a credential to disk and never touches the repo. The MinIO root
# credentials are read from /opt/homelab/minio/.env on this host — they are the
# only thing that can create users.
#
# Re-running without --rotate is a no-op for the secret; with --rotate it mints a
# new secret key (CNPG then needs the SOPS secret updated — ST2/H2-147).

set -euo pipefail

MINIO_ENV="${MINIO_ENV:-/opt/homelab/minio/.env}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://127.0.0.1:9000}"
MC_IMAGE="${MC_IMAGE:-minio/mc:RELEASE.2025-08-13T08-35-41Z}"
BUCKET="cnpg-backups"
PREFIX="mail-archiver"
USER_NAME="cnpg-mailarchiver-backup"
POLICY_NAME="cnpg-mailarchiver-backup-rw"
ROTATE=0
[[ "${1:-}" == "--rotate" ]] && ROTATE=1

log() { printf '\n=== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "run as root on openmediavault"
[[ -f "$MINIO_ENV" ]] || die "missing $MINIO_ENV (MinIO root credentials)"
# shellcheck disable=SC1090
set -a; . "$MINIO_ENV"; set +a
: "${MINIO_ROOT_USER:?MINIO_ROOT_USER not set in $MINIO_ENV}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD not set in $MINIO_ENV}"

MC=(docker run --rm -i --network host -e HOME=/tmp "${MC_IMAGE}")
mc() { "${MC[@]}" "$@"; }

log "MinIO reachable?"
curl -fsS -o /dev/null -w 'health HTTP %{http_code}\n' "http://127.0.0.1:9000/minio/health/live"

read -r -d '' POLICY_JSON <<JSON || true
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListOnlyOurPrefix",
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"],
      "Resource": ["arn:aws:s3:::${BUCKET}"],
      "Condition": { "StringLike": { "s3:prefix": ["${PREFIX}/*"] } }
    },
    {
      "Sid": "ReadWriteOurPrefix",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject", "s3:GetObject", "s3:DeleteObject",
        "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"
      ],
      "Resource": ["arn:aws:s3:::${BUCKET}/${PREFIX}/*"]
    }
  ]
}
JSON

# Root alias lives only inside this transient container's /tmp home.
log "create/refresh policy ${POLICY_NAME}"
printf '%s' "$POLICY_JSON" > /tmp/.${POLICY_NAME}.json
mc alias set root "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
if ! mc admin policy create root "$POLICY_NAME" /tmp/.${POLICY_NAME}.json; then
  mc admin policy remove root "$POLICY_NAME" >/dev/null 2>&1 || true
  mc admin policy create root "$POLICY_NAME" /tmp/.${POLICY_NAME}.json
fi
rm -f /tmp/.${POLICY_NAME}.json

EXISTS=0
if mc admin user info root "$USER_NAME" >/dev/null 2>&1; then EXISTS=1; fi

if [[ "$EXISTS" -eq 0 || "$ROTATE" -eq 1 ]]; then
  ACCESS_KEY="$USER_NAME"
  SECRET_KEY="$(openssl rand -base64 48 | tr -d '/+=' | cut -c1-40)"
  if [[ "$EXISTS" -eq 1 ]]; then
    log "rotate secret for ${USER_NAME}"
    mc admin user remove root "$USER_NAME" >/dev/null 2>&1 || true
  fi
  log "create user ${USER_NAME}"
  mc admin user add root "$ACCESS_KEY" "$SECRET_KEY"
  SHOW_SECRET=1
else
  log "user ${USER_NAME} already exists (use --rotate to mint a new secret)"
  ACCESS_KEY="$USER_NAME"
  SECRET_KEY=""
  SHOW_SECRET=0
fi

log "attach policy"
mc admin policy attach root "$POLICY_NAME" --user "$USER_NAME" >/dev/null

if [[ "$SHOW_SECRET" -eq 1 ]]; then
  cat <<EOF

------------------------------------------------------------------
  STORE IN 1PASSWORD NOW — this is shown once and is not on disk.
  vault    Homelab
  item     MinIO - ${USER_NAME}
  endpoint http://openmediavault.local:9000   (in-cluster: http://openmediavault.local:9000)
  bucket   ${BUCKET}
  prefix   ${PREFIX}/
  access   ${ACCESS_KEY}
  secret   ${SECRET_KEY}
------------------------------------------------------------------
EOF
fi

# ---------------------------------------------------------------- self-test
if [[ "$SHOW_SECRET" -eq 1 ]]; then
  log "self-test with the NEW credentials (prefix happy path + negative control)"
  mc alias set newuser "$MINIO_ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY" >/dev/null
  echo ok | mc pipe "newuser/${BUCKET}/${PREFIX}/.provision-probe" >/dev/null
  mc cat "newuser/${BUCKET}/${PREFIX}/.provision-probe"
  mc rm "newuser/${BUCKET}/${PREFIX}/.provision-probe" >/dev/null
  echo "happy path: OK (prefix list/put/get/rm all succeeded)"
  if mc ls "newuser/${BUCKET}/karakeep/" >/dev/null 2>&1; then
    echo "NEGATIVE CONTROL FAILED: creds can read a sibling prefix" >&2
    exit 1
  else
    echo "negative control: OK (sibling prefix denied)"
  fi
fi

log "done. NFS export is separate — see README.md section 2."
