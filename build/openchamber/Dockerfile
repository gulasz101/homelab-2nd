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

# Base tooling: git/ssh for workspaces, gh for PRs, ripgrep+jq for opencode UX,
# tini for PID 1.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git jq less ripgrep python3 openssh-client tini \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs gh \
    && rm -rf /var/lib/apt/lists/*

# GitOps validation tooling. The itsaplan-tasks skill renders and validates
# manifests before commit (kubectl/kustomize/helm/kubeconform), decrypts and
# smoke-checks SOPS secrets, and scans for leaked secrets (gitleaks). Versions
# are pinned for reproducible builds; bump an ARG to upgrade.
ARG KUBECTL_VERSION=v1.31.1
ARG HELM_VERSION=v3.16.2
ARG KUSTOMIZE_VERSION=v5.5.0
ARG KUBECONFORM_VERSION=v0.6.7
ARG SOPS_VERSION=v3.9.1
ARG GITLEAKS_VERSION=v8.21.2
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "${arch}" in \
      amd64) k8s_arch=amd64; helm_arch=amd64; gitleaks_arch=x64;; \
      arm64) k8s_arch=arm64; helm_arch=arm64; gitleaks_arch=arm64;; \
      *) echo "unsupported arch ${arch}" >&2; exit 1;; \
    esac; \
    curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${k8s_arch}/kubectl"; \
    chmod 0755 /usr/local/bin/kubectl; \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${helm_arch}.tar.gz" -o /tmp/helm.tgz; \
    tar -xzf /tmp/helm.tgz -C /tmp; \
    install -m 0755 "/tmp/linux-${helm_arch}/helm" /usr/local/bin/helm; \
    curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_${k8s_arch}.tar.gz" -o /tmp/kustomize.tgz; \
    tar -xzf /tmp/kustomize.tgz -C /usr/local/bin kustomize; \
    chmod 0755 /usr/local/bin/kustomize; \
    curl -fsSL "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-${k8s_arch}.tar.gz" -o /tmp/kubeconform.tgz; \
    tar -xzf /tmp/kubeconform.tgz -C /usr/local/bin kubeconform; \
    chmod 0755 /usr/local/bin/kubeconform; \
    curl -fsSL "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.${k8s_arch}" -o /usr/local/bin/sops; \
    chmod 0755 /usr/local/bin/sops; \
    curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION#v}_linux_${gitleaks_arch}.tar.gz" -o /tmp/gitleaks.tgz; \
    tar -xzf /tmp/gitleaks.tgz -C /usr/local/bin gitleaks; \
    chmod 0755 /usr/local/bin/gitleaks; \
    rm -rf /tmp/helm.tgz /tmp/kustomize.tgz /tmp/kubeconform.tgz /tmp/gitleaks.tgz /tmp/linux-${helm_arch}

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
COPY git-credential-github.sh /usr/local/bin/git-credential-github
RUN chmod +x /usr/local/bin/openchamber-entrypoint.sh /usr/local/bin/git-credential-github

USER 1000:1000
WORKDIR /home/openchamber

# 3000 = OpenChamber web UI, 4096 = managed OpenCode server (for programme access).
EXPOSE 3000 4096

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/openchamber-entrypoint.sh"]
