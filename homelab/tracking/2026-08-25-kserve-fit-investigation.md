---
title: "KServe fit for homelab-2nd + M1 Max as k3s node"
date: 2026-08-25
llm: "kimi-k2.7-code"
---

# KServe investigation: does it belong in homelab-2nd?

Source: Supreme Leader linked https://github.com/kserve/kserve and asked how it would fit, with Gemma/Ideogram4 and maybe k3d on the M1 Max.

## What KServe is
- CNCF incubating Kubernetes inference platform (v0.20.0 current).
- Two control planes:
  - `kserve` controller = `InferenceService` CRD for predictive + generative models.
  - `llmisvc` controller = `LLMInferenceService` CRD for generative LLMs, with Gateway API/Envoy AI Gateway routing.
- Supports model formats: HuggingFace, vLLM, Triton, TensorFlow, PyTorch, sklearn, ONNX, XGBoost, custom runtimes.
- Exposes OpenAI-compatible `/openai/v1/chat/completions` on InferenceServices.
- Standard mode uses raw Deployments + Gateway API (recommended) or Ingress. Knative mode adds scale-to-zero but pulls in Istio + Knative.

## Homelab-2nd reality check
- k3s v1.35.5 on Debian 13, single node, 8c/31GB/408GB NVMe, NVIDIA GTX 970M Mobile (Maxwell, 3GB VRAM, compute 5.2, driver 550.163.01).
- CPU requests already ~97% as of mid-August; only ~14GB RAM free before workloads start.
- Live workloads: LiteLLM proxy, Open WebUI, CNPG Postgres, GPU Ollama embeddings (nomic-embed-text), docs-mcp, Speaches, Karakeep, Firecrawl, Authentik, Nextcloud, arr stack, etc.
- Cluster topology is GitOps-only (Flux). KServe would need HelmRepository/HelmRelease + CRDs + gateway controller committed and reconciled.

## M1 Max reality check
- 32GB unified RAM, Apple Silicon, macOS 26.5.1.
- Ideogram4 currently runs via stable-diffusion.cpp on this host (Metal-capable build, ~3-7 min per 1216x832 image with Metal, ~21 min CPU).
- M1 Max has no NVIDIA GPU and no CUDA. vLLM and KServe’s GPU path are NVIDIA-first. CPU-only serving on M1 Max inside k3s/k3d is possible but eats the very same RAM the host needs for Hermes, image generation, and daily use.

## Does KServe solve a real homelab problem?

### What the homelab already has
- LiteLLM proxy already routes virtual keys, model aliases, upstreams (Ollama Cloud, z.ai, OpenRouter, LM Studio, OpenCode Go). That is the API gateway.
- For local GPU inference, there is a single NVIDIA runtime-class Ollama pod used for embeddings. It is not exposed as a general LLM backend because the card is a 3GB Maxwell from 2015 — too small for modern chat models.
- For images, the M1 Max queue via `ideogram4-local` already works and is GitOps-unmanaged only in the sense it lives on the Mac host, not in k3s.

### Where KServe would add value
1. **Standardized model serving CRDs** — instead of hand-written Ollama Deployments, define `InferenceService` objects with `storageUri: hf://...` and let KServe handle runtime selection.
2. **Autoscaling/canary** — HPA/KEDA on token throughput or queue depth for any model that actually gets traffic.
3. **Local model cache** — `LocalModelCache` keeps models on node storage instead of re-downloading on every pod start.
4. **OpenAI-compatible endpoints** — could replace or supplement the LiteLLM model-list for self-hosted models.

### Why it is mostly a bad fit right now
1. **No headroom on homelab-2nd.** The node is already CPU-request-saturated. KServe controller + gateway components + model pods would push it over immediately.
2. **Wrong GPU class.** GTX 970M 3GB cannot load Gemma 4 12B, Qwen 3.5 397B, or any useful generative model. KServe GPU examples all assume `nvidia.com/gpu` with 16GB+ VRAM.
3. **M1 Max cannot join as a k3s GPU node.** Kubernetes has no Apple Metal device plugin. You can run a CPU k3d/k3s node on the Mac via Docker/lima, but:
   - No `nvidia.com/gpu` resource.
   - No KServe runtime supports Apple Silicon GPU.
   - CPU inference of LLMs inside a k3d node would compete with Hermes itself.
4. **Gateway API conflict.** KServe Standard mode wants Gateway API. The homelab currently uses dedicated per-service Cloudflare Tunnel pods (plain HTTP inside cluster). Adding Istio/Gateway API is a large ingress architecture change just to expose one model.
5. **Gemma/Ideogram4 mismatch.**
   - Gemma models are available on HuggingFace as safetensors; KServe HuggingFace runtime could load them, but only if the hardware fits. The 970M cannot. The M1 Max can run Gemma in MLX or Ollama natively, but not inside KServe’s vLLM/HF runtime because there is no Metal backend there.
   - Ideogram4 is not a standard HuggingFace diffusers model; it is a custom stable-diffusion.cpp/Ideogram 4 GGUF workflow. KServe has no runtime for it.

## Revised architecture: k3s cluster + M1 Max as GPU inference appliance

The Supreme Leader clarified the real goal: move as much as possible off the M1 Max into k3s, leaving the Mac as a thin client + GPU inference accelerator.

### Proposed topology

| Role | Hardware | OS / stack | Responsibilities |
| --- | --- | --- | --- |
| k3s server | homelab-2nd (8c/31GB/NVMe/GTX 970M) | Debian 13, k3s | Control plane + etcd. Keep stateful/IO-heavy workloads: CNPG, observability, LiteLLM, GPU embeddings (nomic-embed-text). |
| k3s agent | Lenovo T460 (i5-6200U/8GB/SATA SSD) | Debian / lightweight Linux | CPU-only worker: Firecrawl worker/Playwright, Speaches, Karakeep, home-automation auxiliary pods. |
| k3s agent | Surface Pro 4 (i7-6650U/16GB) | Debian / lightweight Linux | CPU-only worker: Open WebUI, Authentik worker, other memory-hungry stateless pods. Use Ethernet if possible; WiFi is a liability. |
| GPU inference appliance | M1 Max (32GB unified RAM) | macOS 26.5.1 | Hermes app, LLMKube metal-agent for text LLMs, native image-generation service. Each service registers into k3s via selector-less Service + Endpoints. |
| Home-automation edge | Raspberry Pi Zero | Raspberry Pi OS / Docker | mqtt2zigbee with USB dongle. Bridge into k3s MQTT broker. |

### What this gives you
- ~8 extra low-power threads + 24GB RAM for CPU-only pods.
- M1 Max GPU stays available for text and image inference, but scheduling/routing/policy moves into k3s.
- One control plane for the whole platform.

### What it does not give you
- No extra GPU. T460 and Surface have none.
- No high-availability control plane with only one server. Surface/T460 as **agents** keeps recovery simple.
- No escape from the fact that image models need Apple Silicon GPU and therefore cannot be containerized in k3s.

## Native GPU services on the M1 Max

Two categories need two different native services:

### Text LLMs (Gemma, Qwen, etc.)
- Use **LLMKube metal-agent**.
- Runs `llama-server` natively with Metal backend.
- Registers endpoint back into k3s as a selector-less Service + Endpoints.
- LiteLLM proxy in k3s points at `http://<llmkube-service>.<namespace>.svc.cluster.local` as a provider.
- Models can be GGUF from HuggingFace or local path.

### Image generation
Ideogram 4 has two Apple-Silicon paths:
1. **mlx-ideogram4** (lyonsno/mlx-ideogram4) — native MLX/NF4 implementation.
   - 11.5 GB peak @ 512×512, 13.7 GB peak @ 1024×1024 on M4 Max.
   - Fits on 32 GB M1 Max for 512×512; 1024×1024 is tight but possible if Mac is idle.
   - Requires structured JSON prompts (same schema as the GGUF workflow already used).
   - Non-commercial license, technical demo, 2 stars, 39 commits. Risky but interesting.
2. **ComfyUI with MPS** — more mature, works with SDXL/Flux checkpoints.
   - Proven pattern: native launchd + k3s selector-less Service + Endpoints (zolty.systems blog, 2026-04).
   - Open WebUI already supports ComfyUI as image-generation backend (`IMAGE_GENERATION_ENGINE: comfyui`).
   - Not Ideogram 4, but much more flexible and production-ready.

If the goal is "proper Kubernetes scheduling for image generation," neither path puts the model in a pod. The scheduling is done at the k8s Service level; the actual GPU compute is native macOS. That is the correct pattern until Apple ships a Metal device plugin for Kubernetes (unlikely).

## Sane migration order

1. **Baseline + ADR.** Document current resource usage by namespace. Decide what moves. Write ADR: expanding homelab-2nd to multi-node k3s with CPU-only workers and M1 Max as native GPU inference appliance.
2. **Prepare new nodes.** Install Debian on T460 and Surface. Join both as k3s **agents** only. Label them appropriately (e.g. `homelab.io/role=cpu-worker`, `homelab.io/gpu=false`).
3. **Migrate CPU-heavy workloads.** Add nodeAffinity to HelmReleases so Firecrawl, Speaches, Karakeep, Open WebUI can schedule on new agents. Leave LiteLLM, CNPG, observability on homelab-2nd.
4. **Verify cluster health.** Confirm pods run, DNS works, no scheduling pressure on homelab-2nd.
5. **Install LLMKube controller** in k3s (lightweight, one controller pod).
6. **Install LLMKube metal-agent on M1 Max.** Set `--host-ip` to the Mac's LAN or Netbird address. Deploy one small GGUF model as a Metal InferenceService.
7. **Wire LLMKube into LiteLLM.** Add a provider pointing at the LLMKube Service. Test end-to-end chat.
8. **(Optional) Image generation on M1 Max.**
   - Option A: experiment with `mlx-ideogram4` as a native Python service with a small REST API, then expose via selector-less k3s Service.
   - Option B: deploy ComfyUI natively with MPS and expose the same way. Replace or supplement the current ideogram4-local queue.
9. **Home automation migration.** Move non-dongle services into k3s namespace. Keep mqtt2zigbee on Pi Zero, bridge MQTT into k3s.
10. **Observability + alerts.** Ensure every moved workload keeps Prometheus metrics, Loki logs, and Alertmanager routing.

## Resource reality check

Current homelab-2nd allocated resources (live 2026-08-25):
- CPU requests: 7990m / 8000m = **99%**.
- Memory requests: 18196Mi / 31GB = **57%**.
- Actual CPU usage: 36%, memory usage: 61%.

So the node is request-saturated but not actually busy. Adding two CPU-only agents gives immediate scheduling headroom even if they are slow cores. The real win is being able to spread pods and run more replicas without manual pod deletion during rollouts.

## Risks
- Surface Pro 4 is consumer hardware: WiFi, thermal throttling, battery bloat, proprietary charger. Do not make it a k3s server.
- T460 is old DDR3/low-power CPU; fine for background workers, not for latency-sensitive workloads.
- LLMKube is young. Expect breakage.
- `mlx-ideogram4` is a 2-star demo. The existing stable-diffusion.cpp/GGUF path is more proven but uses more memory.
- Running native GPU services on the Mac means the Mac must stay on, Netbird/LAN must work, and the native agents must not crash. Adds operational surface.

## Recommendation

This is a good architecture **if** you're willing to treat it as a multi-week homelab expansion project with a strong blog post. The key insight: the M1 Max becomes a GPU inference appliance, not a k3s node. Kubernetes handles scheduling, routing, and policy; Metal inference stays native.

Do **not** try to put Hermes itself in k3s. Do **not** make the Surface a k3s server. Do **not** containerize Apple GPU workloads.

Start with the hardware expansion (T460 + Surface as agents), then add LLMKube, then experiment with image generation. Each phase is independently useful and blog-worthy.
