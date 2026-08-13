# ADR-012: Self-hosted voice backend for Open WebUI

Date: 2026-08-13
Status: Proposed
Supersedes: nothing
Superseded by: nothing

## Context

The Supreme Leader reported that voice input in Open WebUI (`https://ai-chat.voitech.dev`) fails with a Cloudflare error: "The origin web server returned an invalid or incomplete response". Investigation showed:

1. Open WebUI has no external STT/TTS backend configured.
2. When the microphone is pressed, the browser sends a POST to `/api/v1/audio/transcriptions`.
3. Open WebUI's default local Whisper path (`WHISPER_MODEL=base`) tries to load/run Whisper inside the Open WebUI pod.
4. The Open WebUI pod has a 1Gi memory limit and 50m CPU request; loading/running Whisper causes the pod to restart.
5. While the pod is down, the Cloudflare Tunnel returns the observed "invalid/incomplete response" error.

The homelab guardrails require GitOps, SOPS-encrypted secrets, observability, and a single-responsibility architecture. Running speech recognition inside the chat frontend pod violates SRP and creates resource contention.

Two questions arose:

1. Should the STT (and future TTS) service live in `llm-hub` or a dedicated namespace?
2. Which self-hosted STT/TTS server should we deploy?

## Decision

Deploy **Speaches** (`ghcr.io/speaches-ai/speaches`, formerly `faster-whisper-server`) as a dedicated voice backend in a new `voice` namespace, and rewire Open WebUI to use it for STT via the OpenAI-compatible `/v1/audio/transcriptions` endpoint.

### Rationale

1. **SRP / namespace isolation.** Voice processing is a separate concern from the chat frontend, LiteLLM proxy, and embedding service. It gets its own namespace, secrets, resource budget, alerts, and dashboard.
2. **Speaches is the right tool.** It is OpenAI-compatible, supports both STT (faster-whisper) and TTS (piper/Kokoro), has CPU and GPU image variants, and is actively maintained.
3. **No public ingress needed.** Speaches is an internal service. Open WebUI reaches it at `http://speaches.voice.svc.cluster.local:8000/v1`. No Cloudflare Tunnel, no DNS record.
4. **No database needed.** Speaches is stateless except for the HuggingFace model cache, which we will persist on an OMV NFS-backed PVC for faster restarts.
5. **TTS is future-proofed.** Speaches already supports TTS. The same deployment can be extended later by setting Open WebUI's `AUDIO_TTS_ENGINE=openai` and `AUDIO_OPENAI_API_BASE_URL` to the same endpoint. This ADR scopes STT first.

## Consequences

### Positive

- Open WebUI no longer tries to run Whisper locally, eliminating the pod-restart loop.
- Voice processing is isolated and observable as a first-class tenant.
- Speaches' dynamic model loading lets us start with a small STT model and add TTS later without redeploying.
- No public ingress keeps the attack surface small.

### Negative / Risks

- Speaches uses `latest-cpu` (and other `latest-*` tags). We must pin by digest after the first successful run to avoid surprise updates.
- The `latest-cpu` image runs as UID 1000 (`ubuntu` user). The PVC must be writable by that UID or we need an init container to fix permissions.
- CPU-only transcription is slower than GPU. On a single-node homelab with 98% CPU requests already committed, long voice messages may queue/throttle.
- Model download on first boot can take 30–60s; health probes must account for this.
- Speaches' default model aliases may not match Open WebUI's expected `whisper-1` model name. We may need to configure `model_aliases.json` or set `AUDIO_STT_MODEL` explicitly.

## Alternatives considered

| Option | Why rejected |
|---|---|
| Bump Open WebUI memory limit and keep local Whisper | Violates SRP; voice still competes with chat frontend resources; first transcription still blocks the pod. |
| Route Open WebUI audio to LiteLLM providers | LiteLLM providers (ZAI, OpenRouter, etc.) do not expose STT/TTS endpoints, and OpenAI audio proxying through LiteLLM is unsupported/untested in this homelab. |
| Deploy `rhasspy/wyoming-openai-compatible` for STT only | Wyoming stack is Home Assistant-centric and less flexible than Speaches; Speaches already covers both STT and TTS. |
| Put Speaches in `llm-hub` namespace | Makes the namespace a grab-bag; voice has distinct resource, observability, and lifecycle needs. |
| Use GPU variant on homelab-2nd's Maxwell GPU | Maxwell (sm_52) is too old for current CUDA base images and ctranslate2 wheels; CPU variant is the pragmatic path. |

## When to revisit

Revisit this ADR if:

- The Supreme Leader wants TTS enabled (same Speaches instance can do it).
- homelab-2nd gets a newer GPU that supports the Speaches CUDA image.
- Speaches releases stable semver tags, removing the need for digest pinning.
- CPU transcription latency becomes unacceptable and we need GPU offload or a separate worker pool.

## References

- Speaches repo / docs: https://github.com/speaches-ai/speaches (indexed as `faster-whisper-server` in docs-mcp)
- Proposed manifests: `apps/voice/` (to be created after plan approval)
- Tracking note: `homelab/tracking/2026-08-13-speaches-voice-backend-plan.md`
- `apps/kustomization.yaml`
- `apps/llm-hub/openwebui-helm-release.yaml`

## Open decision

This ADR is in **Proposed** status. Approve it to proceed with the `voice` namespace deployment and the Open WebUI STT rewire.
