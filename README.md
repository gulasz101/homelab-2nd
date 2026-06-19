# homelab-2nd

GitOps-managed homelab cluster running on k3s + Flux.

## Architecture

- **Compute:** homelab-2nd (Debian 13, k3s)
- **Storage:** openmediavault (OMV) with MinIO S3 backend
- **GitOps:** Flux CD reconciling this repo into the cluster
- **Secrets:** SOPS + age encryption (repo is public, zero plaintext secrets)

## Structure

```
├── clusters/homelab-2nd/   # Flux sync root (cluster-specific config)
│   ├── flux-system/        # Flux bootstrap manifests
│   ├── infrastructure.yaml # Kustomization: infra (CNPG, cert-manager, etc.)
│   └── apps.yaml           # Kustomization: application workloads
├── infrastructure/         # Cluster-level infrastructure definitions
│   ├── sources/            # HelmRepository definitions
│   └── controllers/        # Operators (CNPG, cert-manager, cloudflared)
└── apps/                   # Application workloads (Mattermost, etc.)
```

## Secret Management

All secrets are SOPS-encrypted with age. The age public key is in `.sops.yaml`.
The age private key is stored in the password manager and applied to the cluster
as a Kubernetes secret during bootstrap.
