---
title: "Fix honcho deriver LiteLLM 403 and restore Mattermost alerting"
status: done
priority: high
created: 2026-09-01
labels:
  - honcho
  - litellm
  - alerting
  - mattermost
  - flux
  - loki
assigned: andrzej
source: user-report
---

## Context

Supreme Leader reported two problems:

1. `honcho-deriver` job was failing with a LiteLLM key / model access error.
2. He was not receiving any Mattermost alerts about it.

Both turned out to be real, independent failures that had been masking each other.

## Root cause 1: honcho-deriver could not call `nemotron-3-nano-30b-ollama`

- `honcho-config` ConfigMap sets `DERIVER_MODEL_CONFIG__MODEL: nemotron-3-nano-30b-ollama`.
- The `honcho-litellm-key` secret in the `honcho` namespace contained a valid LiteLLM virtual key.
- But that virtual key's whitelist in LiteLLM did **not** include any `nemotron-*` models.
- Every LLM call failed with:
  ```
  403 key_model_access_denied: key not allowed to access model nemotron-3-nano-30b-ollama
  ```
- `honcho-deriver` retries via tenacity until a `RetryError` exploded, leaving pods in `Error` or high restart count.

### Why the provisioner did not fix it

The `litellm-key-provisioner` CronJob's `DESIRED_MODELS` list was also missing the nemotron models. The hourly job kept "correcting" the key back to the wrong list, undoing any manual fix.

### Fix applied

1. Added all honcho-related nemotron models to the provisioner in `apps/llm-hub/litellm-key-provisioner-configmap.yaml`:
   - `nemotron-3-nano-30b-ollama` and `openai/nemotron-3-nano-30b-ollama`
   - `nemotron-3-super-ollama` and `openai/nemotron-3-super-ollama`
   - `nemotron-3-ultra-ollama` and `openai/nemotron-3-ultra-ollama`
2. Added a helper that expands each bare model name into the `openai/` prefixed form so keys work regardless of how the caller asks.
3. Manually triggered the provisioner job (`manual-provision-20260901`) to update LiteLLM immediately.
4. Restarted `honcho-deriver` and `honcho-api` pods.
5. Verified the deriver logs no longer show `PermissionDeniedError` / `key_model_access_denied`.

### File changed

- `apps/llm-hub/litellm-key-provisioner-configmap.yaml`

## Root cause 2: Loki ruler was broken by one bad rule

- The repository already had `apps/honcho/honcho-error-loki-rule.yaml` and `apps/gpu-embedding/gpu-embedding-loki-rule.yaml`.
- `gpu-embedding-loki-rule.yaml` contained a `runbook_url` annotation that URL-encoded `{{ $labels.pod }}` inside a Go template string:
  ```yaml
  runbook_url: "...%7B%7B%20$labels.pod%20%7D%7D..."
  ```
- Loki's ruler parser interpreted the unescaped `%` as a template command and failed to load the entire ruleset:
  ```
  error parsing /rules/fake/gpu-embedding-http-errors.yaml: annotation "runbook_url": template: __alert_EmbeddingNon2xxResponses:1: unexpected "%" in command
  ```
- Because the ruler refused to load the file, **neither** the gpu-embedding rule **nor** the honcho error rule were active.

### Fix applied

- Rewrote the `runbook_url` in `apps/gpu-embedding/gpu-embedding-loki-rule.yaml` to use raw `{{ $labels.pod }}` and let Grafana URL-encode at click-time.
- Broadened `apps/honcho/honcho-error-loki-rule.yaml` to match the real LiteLLM error text:
  ```yaml
  |~ "PermissionDeniedError|RetryError|maximum pending requests exceeded|InternalServerError|key_model_access_denied|key not allowed to access model"
  ```

### Files changed

- `apps/gpu-embedding/gpu-embedding-loki-rule.yaml`
- `apps/honcho/honcho-error-loki-rule.yaml`

## Root cause 3: Mattermost webhooks were using the wrong Alertmanager receiver type

- All per-namespace `AlertmanagerConfig` CRDs used `webhookConfigs` pointing at the same Mattermost Slack-compatible webhook URL.
- Alertmanager's `webhookConfigs` sends the raw alert payload shape, which Mattermost's incoming webhook rejects with HTTP 400:
  ```
  Failed to handle the payload of media type application/json for incoming webhook
  ```
- Direct `wget` posts with `application/json` and either `{ "text": "..." }` or Slack `attachments` arrays returned `ok` and appeared in chat, proving the webhook URL itself was fine.
- The working `homelab-node` config already used `slackConfigs`, which formats the payload the way Mattermost expects.

### Fix applied

Converted every per-namespace `AlertmanagerConfig` from `webhookConfigs` to `slackConfigs`, mirroring the working `homelab-node` config:

- `apps/honcho/honcho-alertmanager-config.yaml`
- `apps/firecrawl/firecrawl-alertmanager-config.yaml`
- `apps/gpu-embedding/gpu-embedding-alertmanager-config.yaml`
- `apps/llm-hub/llm-hub-alertmanager-config.yaml`
- `apps/opengist/opengist-alertmanager-config.yaml`
- `apps/openviking/openviking-alertmanager-config.yaml`
- `apps/shlink/shlink-alertmanager-config.yaml`
- `apps/voice/voice-alertmanager-config.yaml`

Example receiver shape:
```yaml
receivers:
  - name: honcho-mattermost
    slackConfigs:
      - apiURL:
          name: honcho-mattermost-webhook-url
          key: url
        sendResolved: true
        title: "{{ .CommonAnnotations.summary }}"
        text: "{{ .CommonAnnotations.description }}"
        fallback: "honcho alert: {{ .CommonAnnotations.summary }}"
```

After reconciling, `amtool config` showed all namespace receivers using `slack_configs` and only the default `null` receiver plus `homelab-node` using `webhook_configs` (expected).

## Verification

- `honcho-deriver` pod is `Running` with 0 restarts.
- `honcho-api` pod is `Running`.
- No `403 key_model_access_denied` errors in recent deriver / api logs.
- `litellm-key-provisioner` job completed and updated the `memory-honcho-key` whitelist.
- Loki ruler logs no longer show the `unexpected "%" in command` parse error.
- Alertmanager config reloads successfully with all per-namespace receivers using `slack_configs`.
- **Real alerts started landing in Mattermost at 2026-09-01 23:30** (`llm-hub` job failure, `firecrawl` target down), confirming end-to-end notification path is working.
- Flux `apps` Kustomization reconciled to `main@sha1:fb0562750c0b5255cdfbf3a101661781021a5f63`.

## Commits

1. `fix(honcho): allow nemotron models on memory-honcho key; fix loki ruler`
2. `fix(honcho): use slackConfigs for Mattermost webhook payload`
3. `fix(alerting): use slackConfigs for all per-namespace Mattermost webhooks`

## Remaining cleanup

- Deleted stale failed jobs from `llm-hub` and `openviking` namespaces; `KubeJobFailed` alert count dropped to 0.
- Identified two `TargetDown` alerts caused by upstream images that do not expose `/metrics`:
  - `firecrawl/api` (`firecrawl-api-6c99877977-zxjr4`) — `/metrics` returns 404.
  - `karakeep` (`karakeep-0`) — `/metrics` returns 404.
- Applied long-duration Alertmanager silences for both (IDs `8f7ffa5c-...` and `fca34061-...`) with comment explaining upstream lacks metrics endpoint.
- Force-deleted a stale `honcho-api` pod stuck in `Completed` state.

## Lessons

- A log alert rule with a bad Go-template annotation can silently disable the entire Loki ruleset, not just itself.
- Alertmanager `webhookConfigs` to a Mattermost Slack webhook fails with HTTP 400; `slackConfigs` is the right receiver type.
- LiteLLM virtual-key whitelists must include both the bare model name and the `openai/` prefixed form, because clients request models both ways.
- A key-provisioner that "corrects" keys hourly will overwrite any manual whitelist change unless its source ConfigMap is updated first.

## Commands used

```bash
# Check deriver state and recent errors
ssh homelab-2nd "sudo kubectl -n honcho logs deploy/honcho-deriver --tail=40"

# Verify LiteLLM key whitelist inside litellm pod
ssh homelab-2nd "sudo kubectl -n llm-hub exec deploy/litellm -- python3 -c 'import urllib.request,json,os; ...'"

# Trigger key provisioner manually
ssh homelab-2nd "sudo kubectl -n llm-hub create job --from=cronjob/litellm-key-provisioner manual-provision-20260901"

# Restart affected pods
ssh homelab-2nd "sudo kubectl -n honcho delete pod <honcho-deriver-pod> --force --grace-period=0"
ssh homelab-2nd "sudo kubectl -n honcho delete pod <honcho-api-pod> --force --grace-period=0"

# Inspect Alertmanager generated config
ssh homelab-2nd "sudo kubectl -n observability exec alertmanager-prometheus-stack-kube-prom-alertmanager-0 -c alertmanager -- amtool config --alertmanager.url=http://localhost:9093"

# Reconcile Flux
ssh homelab-2nd "sudo flux reconcile kustomization apps --with-source"
```

## Files changed

- `apps/llm-hub/litellm-key-provisioner-configmap.yaml`
- `apps/gpu-embedding/gpu-embedding-loki-rule.yaml`
- `apps/honcho/honcho-error-loki-rule.yaml`
- `apps/honcho/honcho-alertmanager-config.yaml`
- `apps/firecrawl/firecrawl-alertmanager-config.yaml`
- `apps/gpu-embedding/gpu-embedding-alertmanager-config.yaml`
- `apps/llm-hub/llm-hub-alertmanager-config.yaml`
- `apps/opengist/opengist-alertmanager-config.yaml`
- `apps/openviking/openviking-alertmanager-config.yaml`
- `apps/shlink/shlink-alertmanager-config.yaml`
- `apps/voice/voice-alertmanager-config.yaml`
