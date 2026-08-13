# Speaches self-hosted voice backend — deployment plan

**Date:** 2026-08-13
**Status:** Plan / awaiting approval
**Service:** Speaches (formerly faster-whisper-server) STT backend
**Upstream:** https://github.com/speaches-ai/speaches
**Docs in docs-mcp:** library `faster-whisper-server` (job completed 2026-08-13 12:48 UTC)
**Proposed namespace:** `voice`
**Internal endpoint:** `http://speaches.voice.svc.cluster.local:8000/v1`

---

## 1. Goal

Give Open WebUI a reliable, self-hosted, GitOps-managed speech-to-text backend by deploying Speaches in its own namespace. After deployment, pressing the microphone button in Open WebUI will POST audio to Speaches instead of trying to run Whisper inside the Open WebUI pod.

## 2. Problem summary

Open WebUI at `https://ai-chat.voitech.dev` currently fails on voice input:

- Frontend calls `/api/v1/audio/transcriptions`.
- Open WebUI pod tries to run Whisper locally (`WHISPER_MODEL=base`).
- The pod has a 1Gi memory limit and a 50m CPU request; loading/running Whisper causes a restart.
- While the pod is down, the Cloudflare Tunnel returns: `The origin web server returned an invalid or incomplete response`.

The fix is to move STT to a dedicated service.

## 3. Proposed architecture

```
┌─────────────────┐     Cloudflare Tunnel      ┌──────────────────┐
│  ai-chat.voitech.dev  ◄───────────────────────┤  Open WebUI pod  │
└─────────────────┘                            │   (llm-hub ns)   │
                                               └────────┬─────────┘
                                                        │
                                                        │ AUDIO_STT_ENGINE=openai
                                                        │ AUDIO_OPENAI_API_BASE_URL=
                                                        │   http://speaches.voice.svc.cluster.local:8000/v1
                                                        │
                                                        ▼
                                               ┌──────────────────┐
                                               │  Speaches pod    │
                                               │   (voice ns)     │
                                               │  CPU-only STT    │
                                               └────────┬─────────┘
                                                        │
                                                        ▼
                                               ┌──────────────────┐
                                               │  OMV NFS PVC     │
                                               │  model cache     │
                                               └──────────────────┘
```

- **Compute:** `homelab-2nd` k3s, namespace `voice`.
- **Storage:** OMV NFS-backed PVC for HuggingFace/Speaches model cache so models survive pod restarts.
- **Database:** none.
- **Ingress:** none. Speaches is internal-only. Open WebUI reaches it via cluster DNS.
- **Secrets:** one SOPS-encrypted dummy API key secret (`voice-speaches-api-key`) for Open WebUI's OpenAI-style auth header, and one SOPS-encrypted Mattermost webhook secret for alerts.
- **Observability:** logs → OTel Collector → Loki; `/metrics` scraped by Prometheus; namespace-scoped `PrometheusRule` for resource alerts; `AlertmanagerConfig` routing to Mattermost; provisioned Grafana dashboard in folder `voice`.

## 4. Files to add to the repo

All under `apps/voice/` (new directory). They are **not** added to `apps/kustomization.yaml` until the plan is approved.

| File | Purpose |
|---|---|
| `apps/voice/namespace.yaml` | Create `voice` namespace |
| `apps/voice/speaches-api-key.sops.yaml` | Dummy API key for OpenAI-compatible auth |
| `apps/voice/speaches-model-cache-pvc.yaml` | OMV NFS PVC for model cache |
| `apps/voice/speaches-deployment.yaml` | Speaches CPU Deployment |
| `apps/voice/speaches-service.yaml` | ClusterIP service on port 8000 |
| `apps/voice/speaches-mattermost-webhook-url.sops.yaml` | Mattermost alert webhook URL |
| `apps/voice/speaches-alertmanager-config.yaml` | Route `voice` namespace alerts to Mattermost |
| `apps/voice/speaches-prometheus-rules.yaml` | CPU/memory resource alerts |
| `apps/voice/speaches-loki-rule.yaml` | Log-based error/crash alerts |
| `apps/voice/speaches-dashboard-configmap.yaml` | Provisioned Grafana dashboard |

After approval, add these lines to `apps/kustomization.yaml`:

```yaml
  # Voice namespace
  - voice/namespace.yaml
  # SOPS-encrypted secrets
  - voice/speaches-api-key.sops.yaml
  - voice/speaches-mattermost-webhook-url.sops.yaml
  # Speaches model cache PVC (OMV NFS)
  - voice/speaches-model-cache-pvc.yaml
  # Speaches deployment + service
  - voice/speaches-deployment.yaml
  - voice/speaches-service.yaml
  # Observability
  - voice/speaches-prometheus-rules.yaml
  - voice/speaches-alertmanager-config.yaml
  - voice/speaches-loki-rule.yaml
  - voice/speaches-dashboard-configmap.yaml
```

## 5. Open WebUI changes

Patch `apps/llm-hub/openwebui-helm-release.yaml` to add these env vars to `extraEnvVars`:

```yaml
      # Route voice STT to the dedicated Speaches service.
      - name: AUDIO_STT_ENGINE
        value: "openai"
      - name: AUDIO_OPENAI_API_BASE_URL
        value: "http://speaches.voice.svc.cluster.local:8000/v1"
      - name: AUDIO_OPENAI_API_KEY
        valueFrom:
          secretKeyRef:
            name: voice-speaches-api-key
            key: api-key
```

No changes to the Open WebUI memory limit are required because the heavy audio work moves out of the pod.

## 6. Proposed manifests (draft for review)

### 6.1 Namespace

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: voice
  labels:
    app.kubernetes.io/name: voice
```

### 6.2 Speaches API key secret (to be SOPS-encrypted)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: voice-speaches-api-key
  namespace: voice
type: Opaque
stringData:
  api-key: "not-needed-local-stt"
```

Speaches ignores the key value, but Open WebUI requires a Bearer token when `AUDIO_STT_ENGINE=openai`.

### 6.3 Model cache PVC

```yaml
---
# OMV NFS-backed PVC for Speaches model cache.
# Models are downloaded on first use; keeping them on NFS avoids re-downloading on every pod restart.
apiVersion: v1
kind: PersistentVolume
metadata:
  name: speaches-model-cache-pv
  namespace: voice
spec:
  capacity:
    storage: 20Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  nfs:
    server: openmediavault.local
    path: /export/speaches-model-cache
    readOnly: false
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: speaches-model-cache
  namespace: voice
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  resources:
    requests:
      storage: 20Gi
  volumeName: speaches-model-cache-pv
```

The matching OMV NFS share `/export/speaches-model-cache` must be created on `openmediavault.local` before deployment.

### 6.4 Deployment

```yaml
---
# Speaches CPU-only STT/TTS server.
# Image: ghcr.io/speaches-ai/speaches:latest-cpu
# Exposes OpenAI-compatible endpoints on port 8000.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: speaches
  namespace: voice
  labels:
    app.kubernetes.io/name: speaches
    app.kubernetes.io/component: stt
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: speaches
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 0
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: speaches
        app.kubernetes.io/component: stt
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8000"
        prometheus.io/path: "/metrics"
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      initContainers:
        - name: ensure-model-cache-writable
          image: busybox:1.36
          command:
            - /bin/sh
            - -c
            - |
              mkdir -p /home/ubuntu/.cache/huggingface/hub
              chown -R 1000:1000 /home/ubuntu/.cache/huggingface
          volumeMounts:
            - name: model-cache
              mountPath: /home/ubuntu/.cache/huggingface
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 64Mi
      containers:
        - name: speaches
          image: ghcr.io/speaches-ai/speaches:latest-cpu
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8000
              protocol: TCP
          env:
            - name: UVICORN_HOST
              value: "0.0.0.0"
            - name: UVICORN_PORT
              value: "8000"
            - name: UVICORN_WORKERS
              value: "1"
            # Disable telemetry / analytics.
            - name: DO_NOT_TRACK
              value: "1"
            - name: GRADIO_ANALYTICS_ENABLED
              value: "False"
            - name: DISABLE_TELEMETRY
              value: "1"
            - name: HF_HUB_DISABLE_TELEMETRY
              value: "1"
            - name: PYANNOTE_METRICS_ENABLED
              value: "0"
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: "2"
              memory: 2Gi
          readinessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 30
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 60
            periodSeconds: 15
          volumeMounts:
            - name: model-cache
              mountPath: /home/ubuntu/.cache/huggingface
      volumes:
        - name: model-cache
          persistentVolumeClaim:
            claimName: speaches-model-cache
```

**Notes:**

- The image runs as UID 1000 (`ubuntu`). `fsGroup: 1000` and the init container ensure the NFS mount is writable.
- CPU-only because homelab-2nd's Maxwell GPU (sm_52) is too old for the Speaches CUDA base images.
- Requests are kept low (100m CPU, 256Mi memory) because the node is at 98% CPU requests; limits allow bursts.
- First model download will happen on the first transcription request; the readiness probe allows the server to start before models are present.

### 6.5 Service

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: speaches
  namespace: voice
  labels:
    app.kubernetes.io/name: speaches
    app.kubernetes.io/component: stt
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 8000
      targetPort: http
      protocol: TCP
  selector:
    app.kubernetes.io/name: speaches
```

### 6.6 Observability package

Reuse the homelab's per-namespace observability pattern:

- `speaches-prometheus-rules.yaml` — CPU/memory above request / 90% of limit, labelled `release: prometheus-stack` (the live Prometheus CR selector).
- `speaches-alertmanager-config.yaml` — route `namespace: voice` alerts to a Mattermost webhook in the same namespace.
- `speaches-loki-rule.yaml` — ConfigMap in `observability` namespace labelled `loki_rule: "true"`, matching `{k8s_namespace_name="voice"}`.
- `speaches-dashboard-configmap.yaml` — generated with `scripts/render_namespace_dashboard.py --namespace voice --services speaches --pvcs "speaches:speaches-model-cache"`.

## 7. OMV steps required before deployment

1. SSH to `openmediavault.local`.
2. Create an NFS share at `/export/speaches-model-cache` (or update path to match the live OMV export root).
3. Set permissions so UID 1000 can write to it.
4. Note the exact export path for the PV manifest.

## 8. Cloudflare / DNS steps

None. Speaches is internal-only. Open WebUI continues to use the existing `ai-chat.voitech.dev` tunnel.

## 9. Verification steps

After Flux reconciles:

1. Check pods:
   ```bash
   kubectl get pods -n voice
   ```
2. Check Speaches health internally:
   ```bash
   kubectl run -n voice --rm -it speaches-test --image=curlimages/curl -- sh
   curl -s http://speaches.voice.svc.cluster.local:8000/health
   curl -s http://speaches.voice.svc.cluster.local:8000/v1/models
   ```
3. Test STT with a sample audio file:
   ```bash
   # From inside the cluster
   curl -X POST http://speaches.voice.svc.cluster.local:8000/v1/audio/transcriptions \
     -H "Authorization: Bearer not-needed-local-stt" \
     -F file=@/tmp/sample.wav \
     -F model=Systran/faster-distil-whisper-small.en
   ```
4. Test Open WebUI voice from the public URL:
   - Open `https://ai-chat.voitech.dev`.
   - Start a new chat.
   - Press the microphone icon and speak.
   - Text should appear in the input box.
5. Check Grafana:
   - Logs in Loki for namespace `voice`.
   - Dashboard in folder `voice`.
   - Alerts route to the configured Mattermost channel.

## 10. Risks and gotchas

| Risk | Mitigation |
|---|---|
| `latest-cpu` tag is a moving target | Pin by digest after first successful run |
| Node CPU request saturation (98%) | Keep requests low; rely on limits for bursts |
| Model cache permissions on NFS | `fsGroup: 1000` + init container `chown` |
| First transcription downloads model and may timeout | Pre-download model via init container or warm the cache with a test request after deploy |
| Open WebUI may expect `whisper-1` model alias | Configure `AUDIO_STT_MODEL` or Speaches `model_aliases.json` if needed |
| Speaches also supports TTS; scope creep | Document TTS as Phase 2; only STT is enabled in Open WebUI initially |

## 11. Phase 2 (future, not in this plan)

Enable TTS by adding to Open WebUI:

```yaml
- name: AUDIO_TTS_ENGINE
  value: "openai"
- name: AUDIO_OPENAI_API_BASE_URL
  value: "http://speaches.voice.svc.cluster.local:8000/v1"
- name: AUDIO_TTS_MODEL
  value: "tts-1"   # Speaches alias for Kokoro
```

This reuses the same Speaches instance; no extra deployment needed.

## 12. Approval checklist

Before I deploy, confirm:

- [ ] Approve ADR-012 (`docs/adr/adr-012-speaches-voice-backend.md`).
- [ ] Approve this plan.
- [ ] Create the OMV NFS share `/export/speaches-model-cache` (or tell me the correct path).
- [ ] Provide a Mattermost incoming webhook URL for `voice` namespace alerts, or tell me which existing webhook/channel to reuse.
- [ ] Confirm STT-only scope (TTS in Phase 2).

After approval I will create the manifests, SOPS-encrypt the secrets, add everything to `apps/kustomization.yaml`, patch the Open WebUI HelmRelease, commit/push, and verify end-to-end.
