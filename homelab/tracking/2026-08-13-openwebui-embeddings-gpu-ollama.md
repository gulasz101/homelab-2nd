# 2026-08-13 Open WebUI file uploads hit OpenAI 401 — fixed by routing RAG embeddings to the in-cluster GPU Ollama service

## Symptom

While attaching a file to a message in Open WebUI, the UI showed:

```
401, message='Unauthorized', url='https://api.openai.com/v1/embeddings'
```

The request was leaking out to the public OpenAI API instead of staying inside the homelab.

## Root cause

Open WebUI's HelmRelease set:

```yaml
- name: RAG_EMBEDDING_ENGINE
  value: "openai"
- name: RAG_EMBEDDING_MODEL
  value: "text-embedding-3-small"
```

But it never set `RAG_OPENAI_API_BASE_URL`. With `RAG_EMBEDDING_ENGINE=openai` and no base URL, Open WebUI falls back to the real `https://api.openai.com/v1/embeddings`, which obviously 401'd without a valid OpenAI key.

The homelab already had a shared GPU Ollama embedding service running in the `gpu-embedding` namespace (`ollama-embeddings` Deployment, NodePort `30114`, ClusterIP alias `gpu-embedding`), but Open WebUI wasn't pointed at it.

## What already existed

- `apps/gpu-embedding/namespace.yaml`
- `apps/gpu-embedding/ollama-models-pvc.yaml` (20 Gi, `local-path`)
- `apps/gpu-embedding/ollama-deployment.yaml` (`ollama/ollama:0.3.14`, `runtimeClassName: nvidia`, `nvidia.com/gpu: 1`)
- `apps/gpu-embedding/ollama-service.yaml` (NodePort `30114`)
- `apps/gpu-embedding/gpu-embedding-service.yaml` (ClusterIP alias)

The pod was Running and `nomic-embed-text` was loaded 100% on the GTX 970M GPU.

## Fix

Edited `apps/llm-hub/openwebui-helm-release.yaml` to route RAG embeddings to the internal Ollama OpenAI-compatible endpoint:

```yaml
      # Embeddings via the shared GPU-accelerated Ollama service in gpu-embedding.
      # Ollama exposes an OpenAI-compatible /v1/embeddings endpoint on the same port.
      - name: RAG_EMBEDDING_ENGINE
        value: "openai"
      - name: RAG_OPENAI_API_BASE_URL
        value: "http://ollama-embeddings.gpu-embedding.svc.cluster.local:11434/v1"
      - name: RAG_EMBEDDING_MODEL
        value: "nomic-embed-text"
```

Also removed the stale comment claiming embeddings went via LiteLLM.

## Why this approach

- No new infrastructure needed — the GPU Ollama service was already deployed and healthy.
- Keeps file content and embeddings entirely inside the homelab; nothing goes to OpenAI.
- Uses internal Kubernetes service DNS (`ollama-embeddings.gpu-embedding.svc.cluster.local`) instead of a hardcoded LAN IP, so it works regardless of node IP changes.
- `ENABLE_PERSISTENT_CONFIG=false` is already set in the same HelmRelease, so the environment variables win over any previously persisted DB config.

## Commands executed

```bash
cd ~/Projects/homelab-2nd
# edit apps/llm-hub/openwebui-helm-release.yaml
git add apps/llm-hub/openwebui-helm-release.yaml
git commit -m "fix(openwebui): route RAG embeddings to shared GPU Ollama service"
git push origin HEAD

# Force reconciliation
ssh homelab-2nd "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
sudo -E kubectl -n flux-system annotate --overwrite gitrepository/flux-system reconcile.fluxcd.io/requestedAt=\"$(date -Iseconds)\"
sudo -E kubectl -n flux-system annotate --overwrite kustomization/apps reconcile.fluxcd.io/requestedAt=\"$(date -Iseconds)\"
sudo -E kubectl -n llm-hub annotate --overwrite helmrelease/open-webui reconcile.fluxcd.io/requestedAt=\"$(date -Iseconds)\"
"
```

## Verification

1. HelmRelease reconciled and rolled the pod:

```bash
kubectl -n llm-hub get helmrelease open-webui -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# True
```

2. New pod has the correct env:

```bash
kubectl -n llm-hub exec deploy/open-webui -- printenv RAG_OPENAI_API_BASE_URL RAG_EMBEDDING_MODEL RAG_EMBEDDING_ENGINE
# http://ollama-embeddings.gpu-embedding.svc.cluster.local:11434/v1
# nomic-embed-text
# openai
```

3. Connectivity test from the Open WebUI pod to the GPU Ollama service returned a valid embedding vector.

4. GPU Ollama model is loaded on the GPU:

```bash
kubectl -n gpu-embedding exec deploy/ollama-embeddings -- ollama ps
# NAME                    ID              SIZE    PROCESSOR   UNTIL
# nomic-embed-text:latest 0a109f422b47    849 MB  100% GPU    4 minutes from now
```

## Follow-up for the Supreme Leader

Please try attaching a file to a chat in Open WebUI again at `https://ai-chat.voitech.dev`. The `api.openai.com` 401 should be gone. If you see a different error, paste it here and I'll dig further.

## References

- `apps/llm-hub/openwebui-helm-release.yaml`
- `apps/gpu-embedding/ollama-deployment.yaml`
- `apps/gpu-embedding/ollama-service.yaml`
- `apps/gpu-embedding/gpu-embedding-service.yaml`
- `references/gpu-embeddings-in-k3s.md`
- `references/gpu-ollama-driver-version-pin.md`
- Open WebUI env docs: `RAG_EMBEDDING_ENGINE`, `RAG_OPENAI_API_BASE_URL`, `RAG_EMBEDDING_MODEL`

## Commit

- `gulasz101/homelab-2nd@b6f8893` — `fix(openwebui): route RAG embeddings to shared GPU Ollama service`
