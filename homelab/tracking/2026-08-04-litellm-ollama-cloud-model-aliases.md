---
# Tracking note: extending LiteLLM with all Ollama Cloud -ollama model aliases
# Date: 2026-08-04
# Slug: litellm-ollama-cloud-model-aliases

title: Adding all Ollama Cloud models with -ollama suffix to LiteLLM proxy

## Goal

The Supreme Leader wants more models available through the LiteLLM proxy for Open WebUI and Hermes, specifically from Ollama Cloud, with every model carrying a `-ollama` suffix so he can distinguish them from the `-go` provider variants.

Requested families:
- minimax (all versions)
- Kimi k3 (all versions)
- DeepSeek (all versions)
- Qwen (all of them)
- all older GLM versions

## What "all versions available" actually means on Ollama Cloud

I navigated to `https://ollama.com/search?c=cloud` as requested. The page lists library/model cards, but the actual runnable model IDs come from Ollama's OpenAI-compatible `/v1/models` API.

The API returned exactly 18 cloud models:

```json
[
  "glm-5.1",
  "glm-5.2",
  "kimi-k2.6",
  "kimi-k2.7-code",
  "kimi-k3",
  "minimax-m2.7",
  "minimax-m3",
  "deepseek-v4-pro",
  "deepseek-v4-flash",
  "deepseek-v4-flash:0731",
  "qwen3.5:397b",
  "gemma4:31b",
  "mistral-large-3:675b",
  "nemotron-3-super",
  "nemotron-3-ultra",
  "nemotron-3-nano:30b",
  "gpt-oss:20b",
  "gpt-oss:120b"
]
```

Note: Ollama Cloud does **not** expose every variant the model families have elsewhere. There is no `glm-4.7` on Ollama (that's z.ai only), and qwen only shows the `qwen3.5:397b` tag. The OpenCode Go subscription still covers qwen3.5/3.6/3.7-plus/max variants, so those remain available via `-go` suffix.

## Changes made

### 1. Add Ollama Cloud aliases to LiteLLM proxy config

File: `apps/llm-hub/litellm-helm-release.yaml`

Added 17 new `-ollama` entries (keeping the existing `glm-5.2-ollama` and the legacy non-suffixed `kimi-k2.7-code` for backward compatibility):

```yaml
- model_name: glm-5.1-ollama
  litellm_params:
    model: openai/glm-5.1
    api_base: "https://ollama.com/v1"
    api_key: "os.environ/OLLAMA_API_KEY"
- model_name: kimi-k2.7-code-ollama
  litellm_params:
    model: openai/kimi-k2.7-code
    api_base: "https://ollama.com/v1"
    api_key: "os.environ/OLLAMA_API_KEY"
- model_name: kimi-k2.6-ollama
  litellm_params:
    model: openai/kimi-k2.6
    api_base: "https://ollama.com/v1"
    api_key: "os.environ/OLLAMA_API_KEY"
- model_name: kimi-k3-ollama
  litellm_params:
    model: openai/kimi-k3
    api_base: "https://ollama.com/v1"
    api_key: "os.environ/OLLAMA_API_KEY"
- model_name: minimax-m2.7-ollama
  litellm_params:
    model: openai/minimax-m2.7
    api_base: "https://ollama.com/v1"
    api_key: "os.environ/OLLAMA_API_KEY"
- model_name: minimax-m3-ollama
  litellm_params:
    model: openai/minimax-m3
    api_base: "https://ollama.com/v1"
    api_key: "os.environ/OLLAMA_API_KEY"
- model_name: deepseek-v4-pro-ollama
  litellm_params:
    model: openai/deepseek-v4-pro
    api_base: "https://ollama.com/v1"
    api_key: "os.environ/OLLAMA_API_KEY"
- model_name: deepseek-v4-flash-ollama
  litellm_params:
    model: openai/deepseek-v4-flash
    api_base: "https://ollama.com/v1"
    api_key: "os.environ/OLLAMA_API_KEY"
- model_name: deepseek-v4-flash-0731-ollama
  litellm_params:
    model: "openai/deepseek-v4-flash:0731"
    api_base: "https://ollama.com/v1"
    api_key: "os.environ/OLLAMA_API_KEY"
- model_name: qwen3.5-397b-ollama
  litellm_params:
    model: "openai/qwen3.5:397b"
    api_base: "https://ollama.com/v1"
    api_key: "os.environ/OLLAMA_API_KEY"
- model_name: gemma4-31b-ollama
  litellm_params:
    model: openai/gemma4:31b
    api_base: "https://ollama.com/v1"
    api_key: "os.environ/OLLAMA_API_KEY"
- model_name: mistral-large-3-675b-ollama
  litellm_params:
    model: openai/mistral-large-3:675b
    api_base: "https://ollama.com/v1"
    api_key: "os.environ/OLLAMA_API_KEY"
- model_name: nemotron-3-super-ollama
  litellm_params:
    model: openai/nemotron-3-super
    api_base: "https://ollama.com/v1"
    api_key: "os.environ/OLLAMA_API_KEY"
- model_name: nemotron-3-ultra-ollama
  litellm_params:
    model: openai/nemotron-3-ultra
    api_base: "https://ollama.com/v1"
    api_key: "os.environ/OLLAMA_API_KEY"
- model_name: nemotron-3-nano-30b-ollama
  litellm_params:
    model: openai/nemotron-3-nano:30b
    api_base: "https://ollama.com/v1"
    api_key: "os.environ/OLLAMA_API_KEY"
- model_name: gpt-oss-20b-ollama
  litellm_params:
    model: openai/gpt-oss:20b
    api_base: "https://ollama.com/v1"
    api_key: "os.environ/OLLAMA_API_KEY"
- model_name: gpt-oss-120b-ollama
  litellm_params:
    model: openai/gpt-oss:120b
    api_base: "https://ollama.com/v1"
    api_key: "os.environ/OLLAMA_API_KEY"
```

Naming convention: dash notation, colons in upstream IDs replaced by dashes in the alias (e.g., `qwen3.5:397b` → `qwen3.5-397b-ollama`).

### 2. Update key provisioner model whitelist

File: `apps/llm-hub/litellm-key-provisioner-configmap.yaml`

Added the same 17 new aliases to `DESIRED_MODELS`. The provisioner's `expand_models()` function automatically adds `openai/<model>` variants, so both bare and prefixed names work for every client.

### 3. Commit and push

```bash
cd ~/Projects/homelab-2nd
git add apps/llm-hub/litellm-helm-release.yaml apps/llm-hub/litellm-key-provisioner-configmap.yaml
git commit -m "Add Ollama Cloud -ollama model aliases to LiteLLM proxy..."
git push origin main
```

Commit: `2efa1bdcaa1a9cc702e71aa64c0d21334a6df34b`

## Deployment steps

1. Force Flux reconciliation:

   ```bash
   ssh homelab-2nd "sudo kubectl -n flux-system annotate gitrepository flux-system reconcile.fluxcd.io/requestedAt=\"$(date -Iseconds)\" --overwrite"
   ssh homelab-2nd "sudo kubectl -n flux-system annotate kustomization apps reconcile.fluxcd.io/requestedAt=\"$(date -Iseconds)\" --overwrite"
   ssh homelab-2nd "sudo kubectl -n llm-hub annotate helmrelease litellm reconcile.fluxcd.io/requestedAt=\"$(date -Iseconds)\" --overwrite"
   ```

2. The new pod could not schedule because the node was at 98% CPU requests:

   ```
   0/1 nodes are available: 1 Insufficient cpu.
   ```

   Force-deleted the old pod to free CPU:

   ```bash
   ssh homelab-2nd "sudo kubectl -n llm-hub delete pod litellm-675448f894-x6dhj --grace-period=0 --force"
   ```

3. Verified HelmRelease ready:

   ```bash
   ssh homelab-2nd "sudo kubectl -n llm-hub get helmrelease litellm"
   # True Helm upgrade succeeded for release llm-hub/litellm.v27
   ```

4. Config inside the pod shows 46 model entries, including 18 `-ollama` aliases.

## Problems encountered

### CPU scheduling squeeze on single-node k3s

The new LiteLLM pod stayed `Pending` with `Insufficient cpu`. The node had 7880m CPU requested out of 8000m (98%). This is a recurring pattern in this homelab: rolling a 1-replica Deployment with non-trivial CPU requests often requires manually evicting the old pod first.

Lesson: don't assume Kubernetes will preempt the old pod gracefully on a single-node cluster when requests are nearly exhausted. A forced deletion is sometimes the only way to unblock the rollout.

## Verification

### LiteLLM advertises all new aliases

```bash
ssh homelab-2nd "sudo kubectl -n llm-hub exec deploy/litellm -- python3 -c 'import os,json,urllib.request; req=urllib.request.Request(\"http://localhost:4000/v1/models\", headers={\"Authorization\":\"Bearer \"+os.environ[\"PROXY_MASTER_KEY\"]}); models=[m[\"id\"] for m in json.loads(urllib.request.urlopen(req,timeout=30).read()).get(\"data\",[])]; print(\"Total:\", len(models)); print(\"\\n\".join(sorted([m for m in models if \"-ollama\" in m])))'"
```

Result: 46 total models, 18 `-ollama` aliases listed:

```
deepseek-v4-flash-0731-ollama
deepseek-v4-flash-ollama
deepseek-v4-pro-ollama
gemma4-31b-ollama
glm-5.1-ollama
glm-5.2-ollama
gpt-oss-120b-ollama
gpt-oss-20b-ollama
kimi-k2.6-ollama
kimi-k2.7-code-ollama
kimi-k3-ollama
minimax-m2.7-ollama
minimax-m3-ollama
mistral-large-3-675b-ollama
nemotron-3-nano-30b-ollama
nemotron-3-super-ollama
nemotron-3-ultra-ollama
qwen3.5-397b-ollama
```

### Virtual keys updated

Ran the provisioner manually:

```bash
ssh homelab-2nd "sudo kubectl -n llm-hub create job --from=cronjob/litellm-key-provisioner litellm-key-provisioner-manual-$(date +%s)"
```

Logs confirmed all five keys (`wife-key`, `wojtek-key`, `hermes-andrzej-key`, `memory-honcho-key`, `hermes-bill-cipher-key`) were updated with the full 46-model whitelist (including both bare and `openai/` prefixed variants).

## Current state

- LiteLLM proxy now exposes 46 models total.
- 18 models route to Ollama Cloud with `-ollama` suffix.
- All existing `-go` models, z.ai models, local LM Studio model, and legacy aliases remain available.
- Every managed virtual key has access to the expanded list.
- Open WebUI should pick up the new models on its next model-list refresh (or after Redis cache expires / pod restart if `BYPASS_MODEL_ACCESS_CONTROL=true` is already set).

## Caveats

- The upstream model availability is bound to the Ollama API key in `litellm-provider-keys`. If the subscription does not include a given cloud model, LiteLLM will pass through the provider error.
- `glm-4.7` is not available on Ollama Cloud; the existing `glm-4.7-zai` alias remains the way to reach it.
- `qwen3.5:397b` is the only qwen model currently on Ollama Cloud; qwen 3.6/3.7 remain `-go` only.

## References

- `apps/llm-hub/litellm-helm-release.yaml`
- `apps/llm-hub/litellm-key-provisioner-configmap.yaml`
- `apps/llm-hub/litellm-key-provisioner-cronjob.yaml`
- `https://ollama.com/search?c=cloud`
- `https://ollama.com/v1/models`
