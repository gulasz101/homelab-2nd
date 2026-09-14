#!/usr/bin/env bash
set -euo pipefail

HOME_DIR="/home/openchamber"
export HOME="${HOME_DIR}"
export OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-${HOME_DIR}/.config/opencode}"

# Bind to all interfaces; the pod is only reachable inside the cluster.
export OPENCHAMBER_HOST="${OPENCHAMBER_HOST:-0.0.0.0}"
export OPENCHAMBER_PORT="${OPENCHAMBER_PORT:-3000}"
# Managed OpenCode server — pin port + host so the Itsaplan bridge can reach it.
export OPENCODE_PORT="${OPENCODE_PORT:-4096}"
export OPENCHAMBER_OPENCODE_HOSTNAME="${OPENCHAMBER_OPENCODE_HOSTNAME:-0.0.0.0}"

# A stable JWT secret keeps UI sessions valid across pod restarts.
if [ -n "${OPENCODE_JWT_SECRET:-}" ]; then
  export OPENCODE_JWT_SECRET
fi

# Generate an SSH keypair on first start (used if a workspace is cloned via SSH).
SSH_DIR="${HOME_DIR}/.ssh"
mkdir -p "${SSH_DIR}" 2>/dev/null || true
if [ ! -f "${SSH_DIR}/id_ed25519" ]; then
  ssh-keygen -t ed25519 -N "" -f "${SSH_DIR}/id_ed25519" >/dev/null 2>&1 || true
fi

if [ -z "${OPENCHAMBER_UI_PASSWORD:-}" ]; then
  echo "[entrypoint] WARNING: OPENCHAMBER_UI_PASSWORD is not set — UI will be unauthenticated" >&2
fi

# GitHub access for the worker. The token comes from the environment and is
# never written to disk (the credential helper reads $GITHUB_TOKEN); GH_TOKEN
# additionally enables the `gh` CLI for PR workflows.
if [ -n "${GITHUB_TOKEN:-}" ]; then
  export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN}}"
  git config --global credential."https://github.com".helper git-credential-github || true
  echo "[entrypoint] GitHub token present — git push and gh CLI are enabled"
else
  echo "[entrypoint] WARNING: GITHUB_TOKEN is not set — the worker cannot push to GitHub" >&2
fi
git config --global user.name "${GIT_AUTHOR_NAME:-OpenChamber Worker}" || true
git config --global user.email "${GIT_AUTHOR_EMAIL:-openchamber@voitech.dev}" || true
git config --global init.defaultBranch main || true
git config --global --add safe.directory '*' || true

echo "[entrypoint] starting openchamber on ${OPENCHAMBER_HOST}:${OPENCHAMBER_PORT} (opencode :${OPENCODE_PORT})"

# --foreground keeps the server attached so tini/containerd manage it as PID 1's child.
set -- openchamber --host "${OPENCHAMBER_HOST}" --port "${OPENCHAMBER_PORT}" --foreground
if [ -n "${OPENCHAMBER_UI_PASSWORD:-}" ]; then
  set -- "$@" --ui-password "${OPENCHAMBER_UI_PASSWORD}"
fi
if [ "${OPENCHAMBER_API_ONLY:-false}" = "true" ]; then
  set -- "$@" --api-only
fi

exec "$@"
