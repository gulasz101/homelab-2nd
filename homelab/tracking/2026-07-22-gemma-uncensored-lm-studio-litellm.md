---
# Tracking note: exposing LM Studio local model to LiteLLM proxy
# Date: 2026-07-22
# Slug: gemma-uncensored-lm-studio-litellm

title: Serving local LM Studio gemma-4-12b-uncensored through llm.voitech.dev

## Goal

The Supreme Leader wants the local LM Studio instance running on the Hermes host (macOS, LAN IP `192.168.1.101:1234`) to be reachable through the central LiteLLM proxy at `https://llm.voitech.dev`, so it behaves like any other model in the hub.

## Context

- LM Studio local API server is already reachable from `homelab-2nd` on `http://192.168.1.101:1234/v1`.
- Discovered model id on LM Studio: `gemma4-12b-qat-uncensored-hauhaucs-balanced`.
- Chosen user-facing LiteLLM alias: `gemma-4-12b-uncensored`.
- LiteLLM is deployed in `llm-hub` namespace via the `litellm-helm` chart (v1.85.7) and CNPG Postgres.
- Virtual-key provisioner runs hourly to sync model whitelists for `wojtek-key`, `wife-key`, `hermes-andrzej-key`, `memory-honcho-key`, and `hermes-bill-cipher-key`.

## Changes made

### 1. Add model to LiteLLM proxy config

File: `apps/llm-hub/litellm-helm-release.yaml`

```yaml
- model_name: gemma-4-12b-uncensored
  litellm_params:
    model: openai/gemma4-12b-qat-uncensored-hauhaucs-balanced
    api_base: "http://192.168.1.101:1234/v1"
    api_key: "os.environ/DUMMY_API_KEY"
```

Also added a non-secret placeholder env var:

```yaml
- name: DUMMY_API_KEY
  value: "lm-studio-local-dummy-key"
```

LM Studio ignores the Authorization header, but LiteLLM still sends one for the `openai/` provider wrapper, so a non-empty value is required.

### 2. Add alias to virtual-key provisioner

File: `apps/llm-hub/litellm-key-provisioner-configmap.yaml`

```python
"gemma-4-12b-uncensored",
```

The provisioner expands this to both bare and `openai/` prefixed names.

## Deployment steps

1. Verified LM Studio endpoint from `homelab-2nd`:

   ```bash
   ssh homelab-2nd "curl -sS --max-time 5 http://192.168.1.101:1234/v1/models | python3 -m json.tool"
   ```

   Confirmed `gemma4-12b-qat-uncensored-hauhaucs-balanced` is advertised.

2. Committed and pushed to `main`:

   ```bash
   cd ~/Projects/homelab-2nd
   git add -A
   git commit -m "Add local LM Studio gemma-4-12b-uncensored model to LiteLLM proxy"
   git push origin main
   ```

3. Forced Flux reconciliation:

   ```bash
   ssh homelab-2nd "sudo kubectl -n flux-system annotate gitrepository flux-system reconcile.fluxcd.io/requestedAt=\"$(date -Iseconds)\" --overwrite"
   ssh homelab-2nd "sudo kubectl -n flux-system annotate kustomization infrastructure reconcile.fluxcd.io/requestedAt=\"$(date -Iseconds)\" --overwrite"
   ssh homelab-2nd "sudo kubectl -n flux-system annotate kustomization apps reconcile.fluxcd.io/requestedAt=\"$(date -Iseconds)\" --overwrite"
   ssh homelab-2nd "sudo kubectl -n llm-hub annotate helmrelease litellm reconcile.fluxcd.io/requestedAt=\"$(date -Iseconds)\" --overwrite"
   ```

4. The HelmRelease reported `Ready`, but the running LiteLLM pod still had the old ConfigMap mounted. Restarted the Deployment:

   ```bash
   ssh homelab-2nd "sudo kubectl -n llm-hub rollout restart deployment litellm"
   ```

## Problems encountered

### CPU scheduling squeeze

`homelab-2nd` was at 97% CPU requests. The new pod stayed `Pending` with:

```
0/1 nodes are available: 1 Insufficient cpu.
```

The old pod had to be deleted before the new one could schedule. After deletion the new LiteLLM pod came up cleanly.

Lesson: a single-node k3s cluster with tight CPU requests needs an eviction/manual cleanup step when rolling any workload that already has a pending replacement.

## Verification

1. Config in pod:

   ```bash
   ssh homelab-2nd "sudo kubectl -n llm-hub exec deploy/litellm -- grep -A 8 'gemma-4-12b-uncensored' /etc/litellm/config.yaml"
   ```

2. Model advertised by LiteLLM:

   ```bash
   ssh homelab-2nd "sudo kubectl -n llm-hub exec deploy/litellm -- python3 -c 'import os,json,urllib.request; req=urllib.request.Request(\"http://localhost:4000/v1/models\", headers={\"Authorization\":\"Bearer \"+os.environ[\"PROXY_MASTER_KEY\"]}); print(\"\\n\".join([m[\"id\"] for m in json.loads(urllib.request.urlopen(req,timeout=30).read()).get(\"data\",[]) if \"gemma\" in m[\"id\"].lower()]))'"
   ```

   Result: `gemma-4-12b-uncensored`.

3. Virtual-key provisioner updated all keys:

   ```bash
   ssh homelab-2nd "sudo kubectl -n llm-hub create job --from=cronjob/litellm-key-provisioner litellm-key-provisioner-manual-$(date +%s)"
   ```

   Logs showed every key gaining `gemma-4-12b-uncensored` and `openai/gemma-4-12b-uncensored`.

4. Chat completion test:

   ```bash
   ssh homelab-2nd "sudo kubectl -n llm-hub exec deploy/litellm -- python3 -u -c '...POST /v1/chat/completions with model gemma-4-12b-uncensored...'"
   ```

   First attempt failed with `HTTP 400` from LM Studio:

   ```
   Failed to load model "gemma4-12b-qat-uncensored-hauhaucs-balanced".
   Model loading was stopped due to insufficient system resources.
   Requires approximately 45.26 GB of memory.
   ```

5. After the Supreme Leader removed LM Studio's memory guardrails, a second test succeeded:

   ```bash
   ssh homelab-2nd "sudo kubectl -n llm-hub exec deploy/litellm -- python3 -u -c '
   import os, json, urllib.request
   url = \"http://localhost:4000/v1/chat/completions\"
   body = json.dumps({
       \"model\": \"gemma-4-12b-uncensored\",
       \"messages\": [{\"role\": \"user\", \"content\": \"Just say hello.\"}],
       \"max_tokens\": 100,
       \"temperature\": 0.7
   }).encode()
   req = urllib.request.Request(url, data=body, headers={
       \"Content-Type\": \"application/json\",
       \"Authorization\": \"Bearer \" + os.environ[\"PROXY_MASTER_KEY\"]
   }, method=\"POST\")
   resp = urllib.request.urlopen(req, timeout=180)
   data = json.loads(resp.read())
   print(repr(data[\"choices\"][0][\"message\"][\"content\"].strip()))
   print(data[\"choices\"][0][\"finish_reason\"])
   '
   ```

   Result:

   ```
   content: 'Hello!'
   finish_reason: stop
   ```

   The model also responds directly from LM Studio at `http://192.168.1.101:1234/v1/chat/completions`.

## Current state

- LiteLLM advertises `gemma-4-12b-uncensored` and routes requests to `http://192.168.1.101:1234/v1`.
- All virtual keys have the model in their whitelist.
- Chat completions through the LiteLLM proxy now return real output from the local LM Studio model.

## Note on model behaviour

This `gemma4-12b-qat-uncensored-hauhaucs-balanced` variant emits `reasoning_content` (visible in direct LM Studio calls) and sometimes returns empty `content` for short literal-repeat prompts because all generated tokens go into reasoning. Normal conversational prompts like `"Just say hello."` return content as expected.

## Next step

Model is live. Use alias `gemma-4-12b-uncensored` in Open WebUI, Hermes, or any other LiteLLM client.

## References

- `apps/llm-hub/litellm-helm-release.yaml`
- `apps/llm-hub/litellm-key-provisioner-configmap.yaml`
- `apps/llm-hub/litellm-key-provisioner-cronjob.yaml`
- Skill reference: `homelab-gitops/references/lm-studio-litellm-local-provider.md`
