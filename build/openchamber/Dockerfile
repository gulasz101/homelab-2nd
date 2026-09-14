# syntax=docker/dockerfile:1
#
# OpenChamber worker image — Ubuntu 24.04 + Node 22 + OpenCode CLI + OpenChamber web.
#
# Built by .github/workflows/build-openchamber-image.yaml and pushed to
# ghcr.io/gulasz101/openchamber-web. Pinned npm versions keep the image
# reproducible; bump the ARGs to upgrade.
FROM ubuntu:24.04

ARG OPENCHAMBER_VERSION=1.23.1
ARG OPENCODE_VERSION=1.18.30
ARG NODE_MAJOR=22

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    NODE_ENV=production \
    NPM_CONFIG_PREFIX=/home/openchamber/.npm-global \
    PATH=/home/openchamber/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Base tooling: git/ssh for workspaces, ripgrep+jq for opencode UX, tini for PID 1.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git jq less ripgrep python3 openssh-client tini \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# OpenChamber + OpenCode, installed globally as the openchamber user's prefix.
RUN npm config set prefix /home/openchamber/.npm-global \
    && mkdir -p /home/openchamber/.npm-global \
    && npm install -g \
        "@openchamber/web@${OPENCHAMBER_VERSION}" \
        "opencode-ai@${OPENCODE_VERSION}" \
    && npm cache clean --force

# UID/GID 1000 so bind-mounted volumes and PVCs line up predictably.
# Ubuntu 24.04 ships an 'ubuntu' user already holding uid/gid 1000 — drop it first.
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupdel ubuntu 2>/dev/null || true \
    && groupadd -g 1000 openchamber \
    && useradd -u 1000 -g 1000 -m -s /bin/bash openchamber \
    && mkdir -p \
        /home/openchamber/workspaces \
        /home/openchamber/.config/openchamber \
        /home/openchamber/.config/opencode \
        /home/openchamber/.local/share/opencode \
        /home/openchamber/.local/state/opencode \
        /home/openchamber/.ssh \
    && chown -R 1000:1000 /home/openchamber

COPY entrypoint.sh /usr/local/bin/openchamber-entrypoint.sh
RUN chmod +x /usr/local/bin/openchamber-entrypoint.sh

USER 1000:1000
WORKDIR /home/openchamber

# 3000 = OpenChamber web UI, 4096 = managed OpenCode server (for programme access).
EXPOSE 3000 4096

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/openchamber-entrypoint.sh"]
