# ADR-003: GPU-accelerated embeddings run inside k3s on homelab-2nd

Date: 2026-06-27
Status: Accepted
Supersedes: nothing
Superseded by: nothing

## Context

Embeddings for homelab services (starting with the docs-mcp-server, later OpenViking/mem0/etc.) were generated on CPU, either inside k3s or on the user's M1 Max laptop. Indexing documentation sets on CPU was slow — e.g., generating embeddings for FluxCD docs took ~50 seconds on an M1 Max and far longer on the k3s node's CPU.

`homelab-2nd` has an NVIDIA GeForce GTX 970M with 3GB VRAM. This is more than enough for small embedding models such as `nomic-ai/nomic-embed-text-v1.5` (137M params, ~550MB on GPU) or `sentence-transformers/all-MiniLM-L6-v2`.

The question was: should GPU embedding inference live as a standalone daemon on the host, or as a GitOps-managed workload inside k3s requesting a GPU?

## Decision

**Run the embedding model as a k3s Deployment in a dedicated `gpu-embedding` namespace, requesting `nvidia.com/gpu: 1`, using Ollama with GPU support.**

This makes GPU embeddings a platform service that any namespace can call internally at `http://ollama-embeddings.gpu-embedding.svc.cluster.local:11434/v1`.

### Rationale

1. **Shared platform service.** Multiple future workloads (docs-mcp, OpenViking, mem0) will need embeddings. A dedicated namespace prevents tight coupling to any single consumer and respects Single Responsibility Principle.

2. **GitOps discipline.** Keeping it inside k3s means the Deployment, Service, PVC, RuntimeClass and node/containerd configuration are all version-controlled and reconciled by Flux. A host-level daemon would be a snowflake.

3. **Resource isolation.** Kubernetes GPU scheduling ensures only pods that request `nvidia.com/gpu` get the device. Ollama does not leak the GPU into arbitrary containers on the node.

4. **Observability.** Container stdout, metrics, and traces are collected by the existing LGTM/OpenTelemetry stack without extra plumbing.

5. **Sufficient hardware.** 3GB VRAM comfortably fits small embedding models such as `nomic-embed-text` (137M params, ~550MB on GPU) or `sentence-transformers/all-MiniLM-L6-v2`.

6. **Compatibility.** HuggingFace `text-embeddings-inference` (TEI) prebuilt images only support CUDA compute capability 7.5+ (Turing and newer). The GTX 970M is Maxwell (sm_52), so TEI cannot be used without building a custom image. Ollama supports Maxwell out of the box, making it the fastest reliable path to GPU embeddings today.

## Consequences

### Positive
- Embeddings become a reusable, observable, GPU-accelerated internal API.
- No extra host-level service to secure, upgrade, or restart manually.
- Existing CPU-only Ollama deployment in `docs-mcp` can be retired after migration.
- Speedup over CPU inference for batched embedding workloads.

### Negative / Risks
- Adds host-level prerequisites: proprietary NVIDIA driver, NVIDIA Container Toolkit, and k3s containerd runtime configuration. These are not themselves Flux-managed and must be documented as bootstrap steps.
- Single-GPU node: only one pod can hold the whole GPU at a time. No MIG, no time-slicing configured.
- Maxwell is old; newer TEI optimisations (Flash Attention variants) may not apply. Still faster than CPU.
- Model weights downloaded from HuggingFace on first start; network dependency and ~500MB-1GB PVC needed.

## Alternatives considered

| Option | Why rejected |
|---|---|
| Standalone host daemon (Ollama/infinity outside k3s) | Snowflake service, no GitOps, extra firewall/AuthN rules, harder to observe. |
| Keep using CPU Ollama in `docs-mcp` | Too slow for indexing documentation and RAG workloads. |
| Use `infinity` instead of TEI | TEI is lighter, Rust-based, purpose-built for embeddings, and easier to reason about for a single-model deployment. `infinity` makes more sense if we later need rerankers/classifiers/audio in the same pod. |

## When to revisit

Revisit this ADR if:
- The GTX 970M proves too slow or VRAM too small for the model we settle on.
- We need multiple concurrent GPU workloads (would require a newer multi-GPU node or time-slicing).
- TEI adds an official Helm chart and we want to migrate from raw manifests to a HelmRelease.
- A model with compute capability requirements newer than Maxwell is needed.

## References

- Tracking note: `homelab/tracking/2026-06-27-gpu-embedding-preflight.md`
- `apps/gpu-embedding/` in the homelab-2nd repo
- `infrastructure/nvidia-device-plugin/`
- `text-embeddings-inference` docs: https://github.com/huggingface/text-embeddings-inference
- `NVIDIA k8s-device-plugin` docs: https://github.com/NVIDIA/k8s-device-plugin
