# Ollama embeddings run on mimir's Radeon iGPU through Vulkan, scheduled via the AMD device plugin

- **Status**: Pending
- **Date**: 2026-11-12
- **Issue**: none (owner suggestion in chat: "maybe we can do embeddings on apu?"; tracking note `homelab/tracking/2026-11-11-control-plane-move-clevo-t460-to-mimir-loki.md`)
- **Related**: ADR-003 (GPU embeddings via Ollama on the GTX 970M), ADR-026 (Ollama is the embeddings backend), pending ADR `k3s-control-plane-moves-to-mimir`

## Context

`ollama-embeddings` (`nomic-embed-text`) ran on the Clevo's GTX 970M (Maxwell, 3 GB) through the
NVIDIA runtime class. The Clevo was retired on 2026-11-12, and no remaining node has an NVIDIA GPU.
mimir has an AMD Ryzen 5 PRO 4650GE with a **Radeon Vega 7 iGPU** ("Renoir", gfx90c). ROCm doesn't
officially support gfx90c, but Mesa's RADV Vulkan driver does, and Ollama has a Vulkan backend.

Measured on mimir, same pod, `ollama/ollama:0.40.12`, CPU limit 4:

| backend | single embed | batch of 64 |
|---|---|---|
| CPU | 101.4 ms | 10.2 embeds/s |
| Vega 7 via Vulkan | **36.6 ms** | **35.4 embeds/s** |

All 13 layers offload (`Vulkan0 model buffer size = 216 MiB`).

## Decision

1. Ollama `0.3.14 → 0.40.12`, `OLLAMA_VULKAN=1`, and **`OLLAMA_IGPU_ENABLE=1`**. Ollama ≥ 0.40
   ignores integrated GPUs by default (`dropping integrated GPU; to enable, set OLLAMA_IGPU_ENABLE=1`).
2. The GPU is handed to the pod by the **AMD GPU device plugin** (`ROCm/k8s-device-plugin`, Helm
   chart `amd-gpu` 0.22.0, `infrastructure/amd-gpu-device-plugin/`), selected on NFD's
   `feature.node.kubernetes.io/pci-1002.present`. The pod requests `amd.com/gpu: 1`. It's **not
   privileged** and mounts no host `/dev`.
3. Pinned to mimir (`kubernetes.io/hostname: mimir`), where its model volume lives.

## Consequences

- Positive: embeddings run ~2.8× faster than on CPU (single) and ~3.5× (batch), and the GPU is
  scheduled like any other resource.
- Positive: the 12 CPU threads stay free for hindsight's TEI reranker and the databases.
- Negative: the iGPU shares system RAM (GTT). Embedding memory comes out of mimir's 15 GB, the
  tightest node.
- Negative: one consumer per iGPU (`amd.com/gpu: 1`). A second GPU workload on mimir would have to
  share Ollama.
- Negative: NFD is deployed by the **NVIDIA** device-plugin chart. With no NVIDIA node left, that
  chart is now only an NFD carrier. Removing it would remove the label the AMD plugin selects on;
  NFD needs its own release first.

## Alternatives considered

- **CPU only** — works, 3× slower, and burns cores mimir needs.
- **ROCm image with `HSA_OVERRIDE_GFX_VERSION=9.0.0`** — unofficial for gfx90c, a 2+ GB image, and
  ROCm on APUs is sensitive to the BIOS UMA carve-out. Vulkan worked first time.
- **Privileged pod with hostPath `/dev/dri`** — what the benchmark used, rejected for production:
  a network-facing pod running privileged for a device plugin's job.
- **Hosted embeddings API** — external dependency and data leaving the house for a 137M-param model.

## When to revisit

- Odin arrives with its own iGPU: a second Ollama replica, or move it there.
- Ollama's Vulkan backend regresses, or ROCm gains official gfx90c support.
- When the NVIDIA chart is removed: install NFD as its own HelmRelease first.
