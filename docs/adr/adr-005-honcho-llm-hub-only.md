# ADR-005: Honcho must only use models offered by the internal LiteLLM hub

## Context

Honcho is deployed as a memory layer for Hermes and other agents in the `honcho` namespace on homelab-2nd. It was originally wired to the in-cluster LiteLLM proxy (`http://litellm.llm-hub.svc.cluster.local:4000`) and a dedicated virtual key (`memory-honcho`).

The initial Flux manifest only overrode a subset of Honcho's model configuration:

- `DERIVER_MODEL_CONFIG__MODEL`
- `DIALECTIC_LEVELS__{LOW,MEDIUM,HIGH}__MODEL_CONFIG__MODEL`

Honcho's built-in defaults remained active for:

- `SUMMARY_MODEL_CONFIG`
- `DREAM_MODEL_CONFIG`
- `DIALECTIC_LEVELS__{MINIMAL,MAX}__MODEL_CONFIG`

Those defaults point at `openai/gpt-5.4-mini`. Our LiteLLM hub does not expose `gpt-5.4-mini` (or any OpenAI-hosted model), so every Dream cycle and any minimal/max dialectic request failed with LiteLLM error `key_model_access_denied`:

```text
Error code: 403 - {'error': {'message': "key not allowed to access model. This key can only access models=[...]. Tried to access gpt-5.4-mini", 'type': 'key_model_access_denied', 'param': 'model', 'code': '403'}}
```

This was intermittent because only Dream and the rarely-used dialectic levels hit the unmapped model, but it meant memory reasoning was silently degraded.

## Decision

Override **every** Honcho LLM feature to a model that is actually offered by our internal LiteLLM hub. Pin all generative features to `mistral-3.5-middle` (the same model already proven for deriver and dialectic low/medium/high) and explicitly set:

- `*_MODEL_CONFIG__TRANSPORT=openai`
- `*_MODEL_CONFIG__MODEL=mistral-3.5-middle`
- `*_MODEL_CONFIG__OVERRIDES__BASE_URL=http://litellm.llm-hub.svc.cluster.local:4000/v1`

This applies to:

- `DERIVER_MODEL_CONFIG`
- `SUMMARY_MODEL_CONFIG`
- `DREAM_MODEL_CONFIG`
- `DIALECTIC_LEVELS__{MINIMAL,LOW,MEDIUM,HIGH,MAX}__MODEL_CONFIG`

Embeddings remain on the local Ollama `nomic-embed-text` endpoint and are unchanged.

## Consequences

### Positive

- No Honcho feature can fall back to OpenAI's `gpt-5.4-mini` or any external model not in our hub.
- A single, well-known model simplifies troubleshooting and spend tracking.
- Dream cycles no longer fail with 403 model-access errors.
- The in-cluster LiteLLM endpoint avoids Cloudflare WAF issues that hit the public `llm.voitech.dev` tunnel.

### Negative

- `mistral-3.5-middle` is used for everything, including tasks that might benefit from a heavier reasoning model for Dream or max dialectic. We can later add a heavier model to the hub and selectively repoint those features.
- If `mistral-3.5-middle` has an outage, all Honcho reasoning features are affected simultaneously.

## Alternatives considered

1. **Add `gpt-5.4-mini` to the LiteLLM hub.** Rejected. There is no OpenAI API key in the homelab budget, and the policy is that the hub only serves models we actually provision.
2. **Map `gpt-5.4-mini` to a different provider in LiteLLM.** Rejected. It would hide the real model from Honcho and make debugging harder; also no provider slug in our hub answers to that name.
3. **Use different models per feature from the existing hub.** Considered but rejected for now because `mistral-3.5-middle` is already working and has tool-calling support. We can revisit per-feature tiering once we add a heavier model to the hub.

## When to revisit

- When a heavier model (e.g. `glm-5.2-zai`, a local large model, or an OpenRouter tier) is added to the hub and we want Dream / max dialectic to use it.
- If `mistral-3.5-middle` becomes unreliable or too expensive for high-volume deriver work.
- When Honcho adds new features that need their own model config env vars.

## References

- `apps/honcho/honcho-configmap.yaml`
- `apps/llm-hub/litellm-helm-release.yaml`
- `apps/llm-hub/litellm-key-provisioner-configmap.yaml`
- `references/honcho-k3s-runtime-fixes-2026-07-03.md`
- `references/litellm-provider-model-mapping-gotchas.md`
- Honcho docs: https://honcho.dev/docs/v3/contributing/configuration.md (indexed in docs-mcp as "Honcho configuration guide")
