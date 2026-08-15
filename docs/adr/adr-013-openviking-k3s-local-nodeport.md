---
# Architecture Decision Record: OpenViking moves to k3s as a local-only NodePort service.

Date: 2026-08-15
Status: Proposed
Supersedes: nothing
Superseded by: nothing

## Context

OpenViking (the Andrzej profile's memory backend) has been running as a Docker container on the Hermes host MacBook Pro, bound to `0.0.0.0:1933`. It is only consumed by the local Hermes `andrzej` profile and an internal watchdog script, so it never needed public ingress. The rest of the homelab runs on `homelab-2nd` k3s via Flux, with per-namespace observability and SOPS-encrypted secrets. Running memory infrastructure on a laptop is fragile: it depends on Docker Desktop/OrbStack, has no GitOps representation, and its alerting is a local shell script rather than the homelab Alertmanager/Loki stack.

This ADR records the decision to migrate OpenViking into k3s on `homelab-2nd` as a local-only service.

## Decision

Run OpenViking in a dedicated `openviking` namespace on `homelab-2nd` k3s. Expose it internally via a `NodePort` Service on `192.168.1.179:30193`. Store live workspace on a `local-path` PVC for speed and rebuildability. Back up memory state hourly as an `.ovpack` to OMV MinIO under `cnpg-backups/openviking/backups/`, retaining 7 days. Route embeddings to the existing in-cluster Ollama GPU embeddings service (`http://ollama-embeddings.gpu-embedding.svc.cluster.local:11434/v1`). Route VLM calls to the existing in-cluster LiteLLM proxy (`http://litellm.llm-hub.svc.cluster.local:4000/v1`). Do not create a Cloudflare Tunnel, public DNS record, or LoadBalancer.

The original MacBook Docker container will be left running during the copy-and-verify phase, then stopped and removed only after a successful 24-hour smoke test, preserving a rollback path.

## Consequences

### Positive

- OpenViking is now managed by the same GitOps pipeline (Flux + public repo + SOPS) as every other homelab service.
- Memory durability is no longer tied to a laptop SSD / Docker volume; hourly `.ovpack` backups to OMV MinIO provide a real recovery path.
- Alerts move from a local shell script to the homelab Alertmanager/LGTM stack, with the same Mattermost routing as Honcho, voice, etc.
- Embeddings and VLM use internal cluster paths, avoiding public-ingress Cloudflare WAF for memory operations.
- The MacBook can sleep/reboot without taking down the memory backend.

### Negative / Risks

- Adds another workload to a single-node k3s cluster that is already at ~99% CPU requests. The new footprint is small (100m request / 256Mi memory), but the margin is thin.
- `local-path` PVC is still ephemeral relative to the node; a node rebuild requires restoring from MinIO backup.
- `ov backup` / `ov restore` are relatively new CLI commands; if they do not preserve vectors or account/user scoping exactly, we fall back to copying the live workspace directory.
- OpenViking image runs as root and needs `baseline` PodSecurity rather than `restricted`.
- No native Prometheus `/metrics`; dashboard and alerts are limited to pod resource metrics and logs.

## Alternatives considered

| Option | Why rejected |
|---|---|
| Keep running on MacBook | No GitOps, no durable backups, local-only watchdog, laptop dependency. |
| Run as a HelmRelease using upstream `examples/k8s-helm` | Upstream chart is a generic template and does not fit the homelab patterns (SOPS secrets, local-path + MinIO backups, per-namespace observability). Raw manifests are clearer for a single-pod service. |
| Public ingress via Cloudflare Tunnel | Unnecessary — only Hermes consumes it. Adds public attack surface for memory data. |
| MetalLB LoadBalancer instead of NodePort | MetalLB is not deployed in this cluster. NodePort is the existing pattern for local-only services (Honcho, Ollama embeddings). |
| CNPG Postgres for OpenViking storage | OpenViking has its own embedded SQLite/vector store and does not support Postgres as a backend. |

## When to revisit

Revisit this ADR if:
- OpenViking upstream adds native Prometheus metrics or a Helm chart with first-class backup support.
- The cluster gets a second node or MetalLB, making LoadBalancer preferable.
- Hourly backups prove insufficient for memory durability (e.g., frequent writes between backups).
- `homelab-2nd` CPU saturation forces removing or consolidating workloads.

## References

- `apps/openviking/` — all manifests for the k3s deployment.
- `homelab/tracking/2026-08-15-openviking-k3s-migration-plan.md` — detailed execution plan and tracking note.
- OpenViking deployment docs indexed in docs-mcp-server as libraries `openviking` and `openviking-monitoring`.
