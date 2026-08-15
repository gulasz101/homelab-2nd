# 2026-08-15 — Switch Honcho to cheapest Ollama Cloud model

## Context

Supreme Leader's Mistral subscription expires tomorrow (2026-08-16). Honcho was routing all LLM work through `mistral-3.5-middle` via the internal LiteLLM proxy. To keep Honcho running without spending Mistral credits, we needed to move it to the cheapest available model: `nemotron-3-nano:30b` on Ollama Cloud, exposed through LiteLLM as `nemotron-3-nano-30b-ollama`.

## What was changed

File: `apps/honcho/honcho-configmap.yaml`

Swapped every `mistral-3.5-middle` reference to `nemotron-3-nano-30b-ollama`. Affected variables:

- `DERIVER_MODEL_CONFIG__MODEL`
- `SUMMARY_MODEL_CONFIG__MODEL`
- `DREAM_DEDUCTION_MODEL_CONFIG__MODEL`
- `DREAM_INDUCTION_MODEL_CONFIG__MODEL`
- `DIALECTIC_LEVELS__MINIMAL__MODEL_CONFIG__MODEL`
- `DIALECTIC_LEVELS__LOW__MODEL_CONFIG__MODEL`
- `DIALECTIC_LEVELS__MEDIUM__MODEL_CONFIG__MODEL`
- `DIALECTIC_LEVELS__HIGH__MODEL_CONFIG__MODEL`
- `DIALECTIC_LEVELS__MAX__MODEL_CONFIG__MODEL`

No secrets were touched. The existing `honcho-litellm-key` Kubernetes Secret (mapping to LiteLLM virtual key `memory-honcho-key`) already has access to `nemotron-3-nano-30b-ollama` via the key provisioner.

## Why no LiteLLM config change was needed

The LiteLLM proxy already defines `nemotron-3-nano-30b-ollama` routing to Ollama Cloud:

```yaml
- model_name: nemotron-3-nano-30b-ollama
  litellm_params:
    model: openai/nemotron-3-nano:30b
    api_base: "https://ollama.com/v1"
    api_key: "os.environ/OLLAMA_API_KEY"
```

And the `litellm-key-provisioner` CronJob already whitelists that model for all managed virtual keys, including `MEMORY_HONCHO_KEY`. So only the Honcho side needed to be retargeted.

## Commands run

```bash
cd ~/Projects/homelab-2nd
# (patch applied via patch tool)
git add apps/honcho/honcho-configmap.yaml
git commit -m "honcho: switch all LLM pipelines to nemotron-3-nano-30b-ollama (cheapest Ollama Cloud model)"
git push

# Reconcile Flux
ssh homelab-2nd 'sudo flux reconcile source git flux-system && sudo flux reconcile kustomization apps'

# Restart Honcho workloads so they pick up the new ConfigMap
ssh homelab-2nd 'sudo kubectl rollout restart deployment/honcho-api deployment/honcho-deriver -n honcho'
ssh homelab-2nd 'sudo kubectl rollout status deployment/honcho-api deployment/honcho-deriver -n honcho --timeout=120s'

# Verify env inside the API pod
ssh homelab-2nd 'sudo kubectl exec -n honcho deployment/honcho-api -- env | grep MODEL'
```

## Verification

- Flux reconciled to `main@sha1:003a0df563cab59bfc56a7ef7948b54dc6b1bacc`.
- `honcho-config` ConfigMap now shows `DERIVER_MODEL_CONFIG__MODEL: nemotron-3-nano-30b-ollama`.
- Both `honcho-api` and `honcho-deriver` pods rolled out successfully.
- Environment variables inside the API pod confirm all model names are now `nemotron-3-nano-30b-ollama`.

## Caveats / next decisions

- The `memory-honcho-key` LiteLLM virtual key still has access to the full model list (via the provisioner). If Honcho is kept long-term, we should restrict that key to only `nemotron-3-nano-30b-ollama` (and its `openai/` alias) to prevent accidental expensive model calls. That requires a small change to the key provisioner to support per-key model lists.
- This is a temporary cost-saving move while the Supreme Leader decides whether to keep Honcho running.
