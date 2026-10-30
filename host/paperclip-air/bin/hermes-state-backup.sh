#!/bin/bash
# hermes-state-backup.sh — nightly sqlite3 backup of all Hermes state.db files to OMV MinIO
# H2-308. Never cp a live WAL database; use sqlite3 .backup for a consistent online copy.
#
# GUL-74: the 2026-10-21 03:30 run failed with "dial tcp 192.168.1.180:9000:
# no route to host" - the Air had not got a route to OMV yet at that hour, so the
# only durable copy of state.db was not written that night. Retry the OMV endpoint
# before giving up: a transient network failure must not silently skip the backup.
#
# GUL-87: that diagnosis was wrong, or at least incomplete. The GUL-74 wait loop
# probed with /usr/bin/nc - an Apple-signed system binary - and it passed, while
# the third-party ~/.local/bin/mc was refused by macOS Local Network privacy
# (GUL-36). The OS reports that refusal as "no route to host", so it reads exactly
# like the missing route GUL-74 assumed. The endpoint is now the 127.0.0.1:9000
# loopback relay (io.paperclip.minio-proxy), and the readiness probe is `mc`
# itself, so the thing we test is the thing we use.
set -euo pipefail

# Resolve the real Hermes home. This script is installed OUTSIDE the Hermes tree
# (/usr/local/libexec/homelab since GUL-618, a system LaunchDaemon), so an explicit
# HERMES_HOME from the daemon's EnvironmentVariables wins. Without it, fall back to
# <script>/.. which is the historical layout (~/.hermes/scripts -> ~/.hermes).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${HERMES_HOME:-}" ] && [ -d "${HERMES_HOME}" ]; then
    HERMES_HOME="$(cd "${HERMES_HOME}" && pwd)"
else
    HERMES_HOME="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi
export HERMES_HOME
LOG_DIR="${HERMES_HOME}/logs"
STATE_DIR="${HERMES_HOME}/state"
ENV_FILE="${ENV_FILE:-$HOME/.config/hermes-state-backup/minio.env}"
TODAY="$(date +%F)"
LOG_FILE="${LOG_DIR}/hermes-state-backup.log"

mkdir -p "${LOG_DIR}" "${STATE_DIR}"

# shellcheck source=/dev/null
source "${ENV_FILE}"

MC_BIN="${MC_BIN:-$HOME/.local/bin/mc}"
ALIAS_NAME="hermes-state-backup"
# Ephemeral mc config dir: otherwise `mc alias set` persists the bucket credential into
# ~/.mc/config.json — a second copy of a secret that is meant to live ONLY in ENV_FILE.
MC_CONFIG_DIR="${MC_CONFIG_DIR:-$(mktemp -d -t hermes-state-backup-mc)}"
export MC_CONFIG_DIR

# GUL-87: the endpoint comes from the environment (the LaunchAgent sets
# MINIO_ENDPOINT=http://127.0.0.1:9000 - the loopback relay) and falls back to
# the same value in the env file. macOS Local Network privacy denies LAN
# connections to launchd-spawned non-Apple binaries (GUL-36), and the loopback
# relay is the only path mc can use from a LaunchAgent.
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://127.0.0.1:9000}"

log() {
    echo "$(date -Iseconds) $*" | tee -a "${LOG_FILE}"
}

# Single cleanup trap (the loop below must not overwrite it).
tmpfile=""
probe_err=""
cleanup() {
    rm -f "${tmpfile}" "${tmpfile}.gz" "${probe_err}"
    rm -rf "${MC_CONFIG_DIR:-/nonexistent}"
}
trap cleanup EXIT

if [[ ! -x "${MC_BIN}" ]]; then
    log "ERROR: mc binary not found at ${MC_BIN}"
    exit 1
fi

log "Starting Hermes state.db backup (bucket=${MINIO_BUCKET}, endpoint=${MINIO_ENDPOINT})"

# GUL-87: wait for the endpoint to answer, and probe it the way the backup
# actually uses it. `mc alias set` performs a signed probe against the
# endpoint, so it is the real readiness test: same binary, same path, same
# credentials. The old /usr/bin/nc probe was Apple-signed and therefore
# allowed to reach the LAN - which is why it passed and the upload still
# failed, twice, silently. Up to ~10 minutes of retry, then give up loudly.
probe_err="$(mktemp -t "hermes-state-backup-probe")"
minio_ready=0
for attempt in $(seq 1 20); do
    if "${MC_BIN}" alias set "${ALIAS_NAME}" "${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" >/dev/null 2>"${probe_err}"; then
        if [ "${attempt}" -gt 1 ]; then log "MinIO endpoint reachable after ${attempt} attempt(s)"; fi
        minio_ready=1
        break
    fi
    log "MinIO endpoint ${MINIO_ENDPOINT} not usable by mc (attempt ${attempt}/20) - waiting 30s"
    # mc's error carries an ephemeral bsign probe token, not a credential - but
    # never take that on trust: if the text contains the bucket key material
    # the whole line is dropped instead of scrubbed.
    err="$(cat "${probe_err}" 2>/dev/null || true)"
    if [ -z "${err}" ]; then
        :
    elif [[ "${err}" == *"${MINIO_ACCESS_KEY}"* || "${err}" == *"${MINIO_SECRET_KEY}"* ]]; then
        log "  mc: <redacted: error output contained credential material>"
    else
        printf '%s\n' "${err}" \
            | sed -E 's#(probe-bsign-)[A-Za-z0-9]+#\1<redacted>#g' \
            | sed 's/^/  mc: /' >>"${LOG_FILE}"
    fi
    sleep 30
done
if [ "${minio_ready}" -ne 1 ]; then
    log "ERROR: MinIO endpoint ${MINIO_ENDPOINT} unusable by mc after 20 attempts - aborting, no backup written"
    exit 1
fi

failures=0
success_profiles=()

for profile in default andrzej florian szarik zdzislaw; do
    if [[ "${profile}" == "default" ]]; then
        db_path="${HERMES_HOME}/state.db"
    else
        db_path="${HERMES_HOME}/profiles/${profile}/state.db"
    fi

    if [[ ! -f "${db_path}" ]]; then
        log "SKIP: ${db_path} not found"
        ((failures++)) || true
        continue
    fi

    tmpfile="$(mktemp -t "${profile}-state-XXXXXX.db")"

    log "Backup profile=${profile} source=${db_path}"
    sqlite3 "${db_path}" ".backup '${tmpfile}'"
    gzip -n "${tmpfile}"

    size="$(stat -f%z "${tmpfile}.gz" 2>/dev/null || stat -c%s "${tmpfile}.gz")"
    remote_key="${TODAY}/${profile}.db.gz"

    "${MC_BIN}" cp "${tmpfile}.gz" "${ALIAS_NAME}/${MINIO_BUCKET}/${remote_key}"
    log "UPLOADED profile=${profile} key=${remote_key} size=${size}"
    success_profiles+=("${profile}")

    rm -f "${tmpfile}" "${tmpfile}.gz"
done

log "SUCCESS profiles=[${success_profiles[*]}] total=${#success_profiles[@]}"

if [[ ${failures} -gt 0 ]]; then
    log "WARN failures=${failures}"
    exit 1
fi
