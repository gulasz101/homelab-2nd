# ADR-077: Speech-to-text lives in k3s (Speaches + NodePort), not on each host

**Date:** 2026-10-21
**Status:** Accepted
**Deciders:** Wojtek Gula; implemented by Andrzej (GUL-74)
**Project:** homelab-2nd / agent platform
**Related:** ADR-071 (Hermes `state.db` source of record), ADR-073 (Hermes runs on the
M1 Air), ADR-076 (Paperclip is the record for chat requests)

## Context

The M1 Max → M1 Air move (ADR-073) left the speech-to-text path undefined on the Air:

- Hermes `stt.provider: local` is broken on **both** hosts — `faster_whisper` is not
  installed anywhere in the estate, so the "default/free" local provider cannot load.
- The VoiceMode whisper server (`:2022`, `com.voicemode.whisper` launchd job with
  `ggml-base.bin`) still runs **on the M1 Max**, bound to `127.0.0.1`. It was never
  migrated; it is reachable from the Air over LAN today, but the Max is a **standby**
  machine until 2026-11-03, and a standby host must not be a runtime dependency.
- The k3s `voice` namespace already runs **Speaches** (`ghcr.io/speaches-ai/speaches:latest-cpu`),
  serving `Systran/faster-distil-whisper-small.en` over an OpenAI-compatible API on
  port 8000. It is healthy and reachable from the Air via ClusterIP
  (`10.43.186.230:8000`). It has **no NodePort**, so the house pattern for
  Mac → cluster services (a `<service>-lan` companion NodePort, as used by
  `hindsight-api-lan`, `firecrawl-api-lan` and `sou-ingest-lan`) was missing for it.
- The Air also has brew `whisper.cpp` 1.9.5 and `parakeet-cli` (with `yt-dlp` and
  `ffmpeg`) — strictly more local ASR tooling than the Max ever had. The Air even has
  a `parakeet-cli` binary with no model file and no server wrapper.

So there were three plausible answers and the estate had picked none of them.

## Decision

1. **One STT service: Speaches in k3s.** The `voice` namespace's Speaches deployment
   is the single STT backend for the whole estate. No whisper server on a laptop, no
   `faster_whisper` install on a host, no per-host model cache.
2. **Expose it with a `speaches-api-lan` NodePort** (nodePort **30274**, port 8000),
   defined in the repo at `apps/voice/speaches-service-lan.yaml` and applied through
   the existing `apps/kustomization.yaml`. Reachable at `192.168.1.179:30274` and on
   the node's Netbird address `100.96.90.128:30274`. Same shape as
   `apps/hindsight/hindsight-service.yaml` and `apps/star-office/sou-ingest-service.yaml`.
3. **Never publish it publicly.** No Ingress, no Cloudflare tunnel, no public hostname.
   An OpenAI-compatible API with a static API key has no business on the public
   internet, and the house rule is one dedicated tunnel per *public* service.
4. **Hermes points at the NodePort**, not at a ClusterIP (the hosts are outside the
   cluster) and not at the Max. `stt.provider` moves off `local` — which cannot work
   without `faster_whisper` — to the OpenAI-compatible path against Speaches, with
   `STT_OPENAI_BASE_URL` pointed at the NodePort.
5. **The `parakeet-cli` / `whisper.cpp` binaries on the Air stay as tools, not servers.**
   They are useful for one-shot CLI transcription of a local file (`whisper-cli` with a
   downloaded ggml model) and for `yt-dlp` workflows. They are not a service: no
   daemon, no API, no port, nothing to keep alive.

## Consequences

**Positive**

- The Air no longer depends on the standby Max for speech. When the Max is retired
  (2026-11-03) or asleep, STT keeps working.
- One model (`faster-distil-whisper-small.en`) is cached once, on the OMV NFS-backed
  PVC, and is shared by every client.
- The NodePort is the same pattern as the rest of the estate, so the address is stable
  across rebuilds (no ephemeral NodePort) and lives in the repo, which is the source
  of truth for the port list.
- The CPU-only Speaches image runs on `homelab-2nd` (the NFS export for the model cache
  is only exported to that node, so the pod is already pinned there) — no GPU needed.

**Negative**

- STT is now a network hop for the Air. The model is `small.en` on CPU: fine for
  voice notes, not for long-form dictation.
- Speaches is a single replica on one node. It is not HA; the ClusterIP and the
  NodePort both go away if `homelab-2nd` is down.
- The `voice` namespace now has a LAN-reachable port. It is firewalled from the
  internet but it is on the LAN, and it carries a static API key in a SOPS secret.

## Alternatives considered

- **Keep the VoiceMode whisper server (`:2022`) on the Max and expose it over LAN.**
  Rejected: it makes a standby laptop a runtime dependency, and it is bound to
  `127.0.0.1` anyway, so it would need the same rebinding work.
- **Run `whisper.cpp` / `parakeet-cli` as a daemon on the Air** (the "Air has more
  tooling" argument).
  Rejected: it is exactly the per-host-server shape this ADR avoids. The binaries stay
  as one-shot tools. A second STT implementation is a second thing to keep alive,
  update and observe.
- **Install `faster_whisper` in the Hermes venv and keep `stt.provider: local`.**
  Rejected: it pins a heavyweight ML dependency to the agent's Python environment on
  every host, and the model cache would land in a user directory instead of the shared
  PVC. It also leaves two STT stacks in the estate with different model sets.
- **A dedicated `voice`-namespace Ingress or a Cloudflare tunnel.** Rejected for
  security: public speech API with a static key.

## When to revisit

- Speaches needs HA (more than one replica, or a spread across nodes) — then the
  NodePort should move behind a proper `Service`/Ingress decision, and the
  model-cache NFS constraint (pinned to `homelab-2nd`) must be solved first.
- The Max is retired (2026-11-03) and the VoiceMode job is deleted — that removes the
  last per-host whisper server, confirming this ADR in practice.
- A local, offline, high-accuracy STT need appears (e.g. large-v3 for long dictation)
  that the CPU `small.en` model cannot serve — then re-open the question of an
  accelerated per-host path, but keep the k3s service as the default.
