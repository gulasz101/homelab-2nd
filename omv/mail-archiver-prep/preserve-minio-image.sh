#!/usr/bin/env bash
# 2026-10-07 — Preserve the UNREPLACEABLE minio/minio image.
#
# WHY: minio/minio and minio/mc were removed from every public registry (Docker Hub
# API: "object not found"; quay.io: 401). The running container on OMV is therefore
# the only copy of the image that exists anywhere. If it is ever lost — container
# recreate, docker prune, disk loss — every CNPG backup in the homelab becomes
# unrestorable, because there is no registry to pull the server back from.
#
# WHAT: docker save -> tar -> sha256, then copy to durable storage under
# /srv/<data-disk>/. No running container is stopped, recreated or modified;
# `docker save` reads the image layer store only.
#
# WHEN: run once now; re-run to verify (it is idempotent and verifies on every run).
#
# Idempotent: safe to re-run. Verifies the copy with sha256 before declaring success.
set -euo pipefail

IMG="${IMG:-minio/minio:latest}"
DEST_DIR="${DEST_DIR:-/srv/dev-disk-by-uuid-cda9bf6e-0ed1-4e61-b063-1cbab7351886/.image-archive}"
LOCAL_DIR=/root/image-archive
STAMP="$(date +%Y%m%d)"
TAR="${LOCAL_DIR}/minio-minio-latest-${STAMP}.tar"

log() { printf '\n=== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

log "confirm the image exists locally"
docker image inspect "$IMG" >/dev/null 2>&1 || die "$IMG not present locally — nothing to save"
DIGEST="$(docker image inspect "$IMG" --format '{{.Id}}')"
printf 'image %s id=%s\n' "$IMG" "$DIGEST"

log "confirm no registry can serve it any more (expected: all fail)"
for ref in "docker.io/${IMG}" "quay.io/${IMG}"; do
  if timeout 30 docker manifest inspect "$ref" >/dev/null 2>&1; then
    printf 'WARNING: %s IS pullable — the archive is a belt-and-braces copy, not the last resort\n' "$ref"
  else
    printf '%s: not pullable (expected)\n' "$ref"
  fi
done

mkdir -p "$LOCAL_DIR" "$DEST_DIR"
log "docker save (read-only; the running container is not touched)"
if [[ ! -f "$TAR" ]]; then
  docker save "$IMG" -o "$TAR"
fi
ls -lh "$TAR"

log "sha256"
sha256sum "$TAR" | tee "${TAR}.sha256"

log "copy to durable storage"
cp -n "$TAR" "${TAR}.sha256" "$DEST_DIR/"
cp -f "${TAR}.sha256" "$DEST_DIR/"          # keep the checksum current even if the tar already existed

log "verify the durable copy (this is the part that matters)"
( cd "$DEST_DIR" && sha256sum -c "$(basename "${TAR}.sha256")" ) || die "durable copy FAILED verification"

log "confirm the running container is still healthy"
docker ps --filter "name=minio" --format '{{.Names}} | {{.Status}}'

log "done. archive: ${DEST_DIR}/$(basename "$TAR")"
printf 'record these so a future restore is possible:\n  image id      %s\n  save stamp    %s\n  archive sha256 %s\n' \
  "$DIGEST" "$STAMP" "$(awk '{print $1}' "${TAR}.sha256")"
