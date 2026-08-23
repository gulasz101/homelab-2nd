---
title: "Rename OpenCode Go and OpenWebUI LiteLLM keys"
date: 2026-08-23
llm: "kimi-k2.7-code"
---

# Rename OpenCode Go and OpenWebUI LiteLLM keys

## Context

Supreme Leader reported that models from the OpenCode Go subscription were not usable in Open WebUI. While investigating, it turned out Open WebUI itself was fine:

- LiteLLM advertises all 22 `-go` models on `/v1/models`.
- `minimax-m3-go` works end-to-end through Open WebUI.
- `deepseek-v4-flash-go` fails because OpenCode requires explicit opt-in for China-hosted models; this is an upstream policy, not a homelab wiring issue.

The real leftover task was to make two API key names more meaningful and GitOps-driven:

1. The OpenCode Go subscription provider key inside `litellm-provider-keys` was named `OPENCODE_GO_API_KEY`, which is too generic.
2. Open WebUI consumes the LiteLLM master key from a secret literally named `litellm-master-key` with key `master-key` — it is not obvious from Open WebUI's perspective what this secret is for.

## Decisions

- Rename the provider key to `OPENCODE_GO_SUBSCRIPTION_API_KEY`. This makes it explicit that it is the subscription key for the Zen Go endpoint (`https://opencode.ai/zen/go/v1`), not a generic OpenCode API key.
- Create a dedicated, consumer-scoped secret `openwebui-litellm-api-key` with key `api-key` for Open WebUI, following the same naming convention already used for `openwebui-firecrawl-api-key` and `openwebui-speaches-api-key`. The value is the same LiteLLM master key; the rename is purely for clarity.
- Keep `litellm-master-key` unchanged for LiteLLM itself and the key provisioner CronJob.

## Files changed

- `apps/llm-hub/litellm-provider-keys.sops.yaml` — key renamed from `OPENCODE_GO_API_KEY` to `OPENCODE_GO_SUBSCRIPTION_API_KEY`.
- `apps/llm-hub/litellm-helm-release.yaml` — env var and all `api_key: os.environ/...` references updated.
- `apps/llm-hub/openwebui-litellm-api-key.sops.yaml` — new SOPS-encrypted secret with `api-key`.
- `apps/llm-hub/openwebui-helm-release.yaml` — `openaiApiKeyExistingSecret` and `openaiApiKeyExistingSecretKey` point to the new secret.
- `apps/kustomization.yaml` — added the new secret to the reconciliation list.

## Commands used

```bash
cd ~/Projects/homelab-2nd
export SOPS_AGE_KEY_FILE=~/.keys/age-homelab-2nd.txt

# Rename provider key in-place with SOPS
sops --decrypt apps/llm-hub/litellm-provider-keys.sops.yaml > /tmp/litellm-provider-keys.yaml
sed -i '' 's/OPENCODE_GO_API_KEY/OPENCODE_GO_SUBSCRIPTION_API_KEY/g' /tmp/litellm-provider-keys.yaml
sops --encrypt /tmp/litellm-provider-keys.yaml > apps/llm-hub/litellm-provider-keys.sops.yaml
rm /tmp/litellm-provider-keys.yaml

# Create OpenWebUI-scoped LiteLLM API key secret from existing master key
sops --decrypt apps/llm-hub/litellm-master-key.sops.yaml > /tmp/litellm-master-key.yaml
python3 - <<'PY'
import yaml
with open('/tmp/litellm-master-key.yaml') as f:
    data = yaml.safe_load(f)
api_key = data['stringData']['master-key']
new = {
    'apiVersion': 'v1',
    'kind': 'Secret',
    'metadata': {'name': 'openwebui-litellm-api-key', 'namespace': 'llm-hub'},
    'type': 'Opaque',
    'stringData': {'api-key': api_key}
}
with open('/tmp/openwebui-litellm-api-key.yaml', 'w') as f:
    yaml.dump(new, f, default_flow_style=False)
PY
sops --encrypt /tmp/openwebui-litellm-api-key.yaml > apps/llm-hub/openwebui-litellm-api-key.sops.yaml
rm /tmp/litellm-master-key.yaml /tmp/openwebui-litellm-api-key.yaml
```

## Verification

1. Confirm both SOPS files decrypt cleanly:
   ```bash
   sops --decrypt apps/llm-hub/litellm-provider-keys.sops.yaml > /dev/null
   sops --decrypt apps/llm-hub/openwebui-litellm-api-key.sops.yaml > /dev/null
   ```
2. Push and let Flux reconcile.
3. Check that the `llm-hub` Kustomization becomes ready.
4. Confirm the Open WebUI pod restarts and still lists all LiteLLM models, including the `-go` ones.
5. Smoke-test a working `-go` model (e.g. `minimax-m3-go`) via the public UI.

## Notes

- No plaintext credentials were committed. The age private key is stored in the Supreme Leader's password manager and was referenced via `~/.keys/age-homelab-2nd.txt` locally.
- The actual LiteLLM master key value did not change; only the secret name consumed by Open WebUI changed.
- The China-hosted DeepSeek opt-in error for `deepseek-v4-flash-go` is out of scope for this change and would require action in the OpenCode workspace if the Supreme Leader wants that specific model enabled.
