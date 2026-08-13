# 2026-08-13 — Speaches self-hosted STT backend for Open WebUI

**Status:** Deployed and verified
**Goal:** Fix Open WebUI voice input by moving speech-to-text processing out of the Open WebUI pod into a dedicated Speaches service.

---

## The problem

Voice input in Open WebUI (`https://ai-chat.voitech.dev`) failed with a Cloudflare error:

> The origin web server returned an invalid or incomplete response to Cloudflare. This typically indicates the origin is overloaded or misconfigured.

Root cause: Open WebUI tried to run Whisper locally inside its own pod. The pod only has a 1Gi memory limit and a 50m CPU request, so loading/running the STT model crashed the container. While the pod was restarting, the Cloudflare Tunnel saw no healthy origin and returned the above error.

---

## The fix

Deployed **Speaches** (formerly faster-whisper-server) as a dedicated, internal-only STT backend in a new `voice` namespace. Open WebUI now routes STT requests to Speaches via its OpenAI-compatible `/v1/audio/transcriptions` endpoint.

### What is STT vs TTS?

- **STT** = Speech-to-Text (microphone audio → written text). This is what we deployed.
- **TTS** = Text-to-Speech (written text → spoken audio output). Speaches also supports TTS, but it is intentionally out of scope for this change; it can be enabled later without redeploying anything.

---

## What was deployed

### New `voice` namespace

- `apps/voice/namespace.yaml`
- `apps/voice/speaches-deployment.yaml` — Speaches CPU-only pod
- `apps/voice/speaches-service.yaml` — ClusterIP on `:8000`
- `apps/voice/speaches-model-cache-pvc.yaml` — OMV NFS-backed PV/PVC for HuggingFace model cache
- `apps/voice/voice-mattermost-webhook-url.sops.yaml` — encrypted alert webhook URL
- `apps/voice/voice-alertmanager-config.yaml` — namespace-scoped alert routing
- `apps/voice/voice-prometheus-rules.yaml` — CPU/memory resource alerts
- `apps/voice/voice-loki-rule.yaml` — log-based error alert
- `apps/voice/voice-dashboard-configmap.yaml` — provisioned Grafana dashboard

### Open WebUI changes

- `apps/llm-hub/openwebui-helm-release.yaml` patched to add:
  - `AUDIO_STT_ENGINE=openai`
  - `AUDIO_OPENAI_API_BASE_URL=http://speaches.voice.svc.cluster.local:8000/v1`
  - `AUDIO_OPENAI_API_KEY` from the `openwebui-speaches-api-key` secret
- `apps/llm-hub/openwebui-speaches-api-key.sops.yaml` — SOPS-encrypted dummy API key placed in the same namespace as Open WebUI (cross-namespace secret refs do not work in Helm values).

### OMV setup

Created on `openmediavault.local`:

```bash
mkdir -p /srv/dev-disk-by-uuid-cda9bf6e-0ed1-4e61-b063-1cbab7351886/speaches/model-cache
chown -R 1000:1000 /srv/dev-disk-by-uuid-cda9bf6e-0ed1-4e61-b063-1cbab7351886/speaches
chmod -R 755 /srv/dev-disk-by-uuid-cda9bf6e-0ed1-4e61-b063-1cbab7351886/speaches
echo "/srv/dev-disk-by-uuid-cda9bf6e-0ed1-4e61-b063-1cbab7351886/speaches/model-cache  192.168.1.179(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
exportfs -ra
```

---

## Hiccups and fixes

### 1. Cross-namespace secret reference

**Problem:** First Open WebUI pod failed with `CreateContainerConfigError: secret "voice-speaches-api-key" not found`.

**Why:** Kubernetes does not allow pods in `llm-hub` to read secrets from `voice`.

**Fix:** Moved the API key secret to `llm-hub/openwebui-speaches-api-key.sops.yaml`, same pattern already used for `openwebui-firecrawl-api-key`. The Mattermost webhook secret correctly stayed in `voice` because the `AlertmanagerConfig` lives there.

### 2. CPU request saturation on the single node

**Problem:** `homelab-2nd` was at 98% CPU requests. Scheduling the new Speaches pod with high requests would have left it Pending.

**Fix:** Set Speaches requests to 100m CPU / 256Mi memory and kept limits at 2 CPU / 2Gi memory. This lets the scheduler place the pod while still allowing burst during transcription.

### 3. First model download timing

**Problem:** The model cache PVC was empty on first boot. The first STT request would download `Systran/faster-distil-whisper-small.en` before responding.

**Fix:** The OMV NFS PVC persists the cache. After the first download, restarts reuse the cached model. We pre-downloaded the model by hitting `POST /v1/models/Systran/faster-distil-whisper-small.en` from inside the cluster to warm the cache.

---

## Verification

1. **Speaches health endpoint responds:**
   ```bash
   kubectl exec -n voice deploy/speaches -- curl -s http://localhost:8000/health
   # OK
   ```

2. **Speaches model downloaded:**
   ```bash
   kubectl exec -n voice deploy/speaches -- curl -s -X POST http://localhost:8000/v1/models/Systran/faster-distil-whisper-small.en
   # Model 'Systran/faster-distil-whisper-small.en' downloaded
   ```

3. **STT endpoint returns valid JSON for a synthetic sine wave:**
   ```bash
   # Generated 1s 440Hz sine wave in the pod as /tmp/test.wav
   curl -X POST http://localhost:8000/v1/audio/transcriptions \
     -H "Authorization: Bearer not-needed-local-stt" \
     -F file=@/tmp/test.wav \
     -F model=Systran/faster-distil-whisper-small.en
   # {"text":""}  (expected for a pure tone with no speech)
   ```

4. **Open WebUI has the new env vars:**
   ```bash
   kubectl exec -n llm-hub deploy/open-webui -- env | grep AUDIO
   # AUDIO_STT_ENGINE=openai
   # AUDIO_OPENAI_API_BASE_URL=http://speaches.voice.svc.cluster.local:8000/v1
   # AUDIO_OPENAI_API_KEY=not-needed-local-stt
   ```

5. **Public URL responds:**
   - `https://ai-chat.voitech.dev/api/version` returns `{"version":"0.11.0"}`.

6. **Observability resources created:**
   - `PrometheusRule/voice-resource-alerts`
   - `AlertmanagerConfig/voice-mattermost-alerts`
   - `ConfigMap/voice-loki-rules` and `ConfigMap/voice-dashboard` in `observability`

---

## Remaining manual verification

The synthetic sine wave returned empty text, which is expected — it contains no speech. The final confirmation is to open `https://ai-chat.voitech.dev` on a real device, press the microphone button, speak, and verify text appears in the chat input box. That should be tested by the Supreme Leader from his phone/Framework/MacBook.

---

## Commits

- `00a6755` — Deploy Speaches self-hosted STT backend for Open WebUI
- `8bc34f6` — fix: move Speaches API key secret to llm-hub namespace

---

## References

- ADR-012: `docs/adr/adr-012-speaches-voice-backend.md`
- Deployment plan: `homelab/tracking/2026-08-13-speaches-voice-backend-plan.md`
- Speaches docs: https://github.com/speaches-ai/speaches (indexed as `faster-whisper-server` in docs-mcp)
