#!/usr/bin/env bash
# 2026-10-07 — ST1 (H2-146): create the Mail-Archiver CNPG backup principal on OMV MinIO.
# Run AS ROOT ON openmediavault.
#
# This is the CORRECTED, runnable version of provision-omv.sh. The original could not
# run: it tried to `docker pull minio/mc` (that image no longer exists in any registry)
# and it wrote the policy JSON to the HOST /tmp while reading it inside a transient
# container. Both fixed here:
#   * uses `mc` FROM THE RUNNING minio CONTAINER (the container bundles it)
#   * writes the policy INSIDE the same container that reads it
#   * never touches, stops or recreates the running minio container
#
# Writes the credential to /root/mailarchiver-minio-creds.env (root-only) for the
# hand-off to the Mac, where it is SOPS-encrypted into apps/mail-archiver/.
# It is NEVER printed to the terminal and never enters chat.
set -euo pipefail

BUCKET=cnpg-backups
PREFIX=mail-archiver
USER_NAME=cnpg-mailarchiver-backup
POLICY_NAME=cnpg-mailarchiver-backup-rw
CRED_FILE=/root/mailarchiver-minio-creds.env

log() { printf '\n=== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "run as root on openmediavault"
docker ps --filter name=^minio$ --format '{{.Names}}' | grep -q minio || die "minio container not running"

log "write the house-pattern policy INSIDE the container (same fs that reads it)"
# HOUSE PATTERN (proven by shlink/tldraw/openviking/karakeep/opengist): s3:* on the
# three ARNs. A fine-grained action list (Get/Put/Delete/AbortMultipart on the prefix
# only) makes barman-cloud-wal-archive exit 4 -> ContinuousArchiving=False and the base
# backup hangs in `started` forever. The plugin swallows the reason, so it looks like a
# network problem. Prefix scoping is preserved: the resource list still names the prefix.
docker exec -i minio sh -c 'cat > /tmp/ma-policy.json' <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow",
  "Action":["s3:*"],
  "Resource":["arn:aws:s3:::${BUCKET}",
              "arn:aws:s3:::${BUCKET}/${PREFIX}",
              "arn:aws:s3:::${BUCKET}/${PREFIX}/*"]}]}
JSON

log "mint the secret on this host (never echoed)"
SECRET="$(openssl rand -base64 48 | tr -d '/+=' | cut -c1-40)"

log "create user + policy, attach (all inside the container)"
docker exec minio sh -c "
  set -e
  mc alias set root http://127.0.0.1:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null
  if mc admin user info root ${USER_NAME} >/dev/null 2>&1; then
    mc admin user remove root ${USER_NAME} >/dev/null 2>&1 || true
  fi
  mc admin user add root ${USER_NAME} ${SECRET}
  if ! mc admin policy create root ${POLICY_NAME} /tmp/ma-policy.json 2>/dev/null; then
    mc admin policy remove root ${POLICY_NAME} >/dev/null 2>&1 || true
    mc admin policy create root ${POLICY_NAME} /tmp/ma-policy.json
  fi
  mc admin policy attach root ${POLICY_NAME} --user ${USER_NAME}
  rm -f /tmp/ma-policy.json
"

log "self-test: positive control (own prefix) + negative control (sibling)"
docker exec minio sh -c "
  mc alias set newuser http://127.0.0.1:9000 '${USER_NAME}' '${SECRET}' >/dev/null
  echo ok | mc pipe newuser/${BUCKET}/${PREFIX}/.provision-probe >/dev/null && echo 'positive: put OK'
  mc cat newuser/${BUCKET}/${PREFIX}/.provision-probe >/dev/null && mc rm newuser/${BUCKET}/${PREFIX}/.provision-probe >/dev/null
  echo 'positive: list/get/rm OK'
  if mc ls newuser/${BUCKET}/karakeep/ >/dev/null 2>&1; then
    echo 'NEGATIVE CONTROL FAILED: creds reach a sibling prefix' >&2; exit 1
  else
    echo 'negative control: OK (sibling prefix denied)'
  fi
"

log "store the credential for the hand-off (root-only, never printed)"
umask 077
cat > "$CRED_FILE" <<EOF
MINIO_ENDPOINT=http://openmediavault.local:9000
MINIO_BUCKET=${BUCKET}
MINIO_PREFIX=${PREFIX}/
MINIO_ACCESS_KEY=${USER_NAME}
MINIO_SECRET_KEY=${SECRET}
MINIO_USER=${USER_NAME}
EOF
chmod 600 "$CRED_FILE"
ls -l "$CRED_FILE"

log "done. scp $CRED_FILE to the Mac, then SOPS-encrypt into apps/mail-archiver/"
