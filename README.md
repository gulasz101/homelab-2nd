# homelab-2nd

GitOps-managed homelab cluster running on k3s + Flux.

## Architecture

- **Compute:** homelab-2nd (Debian 13, k3s)
- **Storage:** openmediavault (OMV) with MinIO S3 backend
- **GitOps:** Flux CD reconciling this repo into the cluster
- **Secrets:** SOPS + age encryption (repo is public, zero plaintext secrets)

## Structure

```
├── clusters/production/   # Flux sync root (cluster-specific config)
│   ├── flux-system/        # Flux bootstrap manifests
│   ├── infrastructure.yaml # Kustomization: infra (CNPG, cert-manager, etc.)
│   └── apps.yaml           # Kustomization: application workloads
├── infrastructure/         # Cluster-level infrastructure definitions
│   ├── sources/            # HelmRepository definitions
│   └── controllers/        # Operators (CNPG, cert-manager, cloudflared)
├── apps/                   # Application workloads (Mattermost, etc.)
└── omv/                    # OpenMediaVault services (Docker, outside k8s)
    └── minio/              # MinIO S3 backend (docker-compose + encrypted creds)
```

## Secret Management

All secrets are SOPS-encrypted with age. The age public key is in `.sops.yaml`.
The age private key is stored in the password manager and applied to the cluster
as a Kubernetes secret during bootstrap.

## Checks

`scripts/check.sh` is the one entry point for every deterministic check in this
repo: it renders and validates each Flux root, audits that every `Secret` is
SOPS-encrypted, runs gitleaks over the commits of the change, and executes the
per-service test gates. Exit code 0 means everything passed. Run it before
opening a PR:

    scripts/check.sh          # run everything (kubectl, kubeconform, helm, yq, gitleaks)
    scripts/check.sh --list   # show what would run, run nothing

Adding a check: drop a `*-check.sh` into your service's `tests/` dir — `apps/`,
`infrastructure/`, `docs/`, `agents/` and `scripts/` are auto-discovered, no edit
to `check.sh` needed. Checks that need the live cluster, SSH, the OMV host or
decrypted secrets can't run in CI: they go on the SKIP list inside `check.sh`
with a one-line reason. The same script runs in CI (`.github/workflows/check.yaml`),
so local and CI cannot drift.
