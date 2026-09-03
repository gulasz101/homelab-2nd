---
title: "openviking: fix noisy OpenVikingEmbeddingFailures Loki alert"
date: 2026-09-03
llm: "kimi-k2.7-code"
tags:
  - homelab-2nd
  - openviking
  - loki
  - alertmanager
  - monitoring
---

# OpenVikingEmbeddingFailures alert fix

## Alert received

Supreme Leader (`akadmin`) forwarded a Mattermost alert at 2026-09-03:

```
OpenVikingEmbeddingFailures: openviking embedding endpoint may be failing — in namespace logged embedding-related failures in the last 5 minutes.
```

He checked the logs and found nothing worrying.

## Root cause

The `OpenVikingEmbeddingFailures` rule in `apps/openviking/openviking-loki-rule.yaml` originally used this regex:

```logql
|~ "embedding|embeddings|nomic-embed-text|ConnectTimeout|APITimeoutError|connection|timeout"
```

This matched **every log line containing the word "embedding" or "embeddings"**, including healthy embedding requests. The alert was effectively an "embedding feature exists" detector, not a failure detector.

A first fix tightened the rule to require embedding context **and** an error/timeout/HTTP-error indicator, but the `4[0-9][0-9]|5[0-9][0-9]` part still matched any three-digit number starting with 4 or 5 anywhere in the line — including response times like `/embeddings in 0.434700` and `duration_ms=5608.60` from slow-but-healthy embedding calls.

## Changes made

### `apps/openviking/openviking-loki-rule.yaml`

Final expression requires embedding context **and** an explicit error/timeout/exception indicator:

```logql
{ k8s_namespace_name="openviking" }
  |~ "embedding|embeddings|nomic-embed-text"
  |~ "Error|ERROR|ERR|FATAL|fatal|Traceback|Exception|exception|unhealthy|timeout|Timeout|connect.*refused|ConnectionError"
```

The naive `4[0-9][0-9]|5[0-9][0-9]` HTTP-status guess was removed because it matched arbitrary numeric substrings in timing values.

## Verification

- Committed and pushed: `36f9323 — fix(openviking): tighten OpenVikingEmbeddingFailures Loki rule`.
- The first fix still fired because `4[0-9][0-9]|5[0-9][0-9]` matched timing values.
- Second commit and push: `5b1d6c1 — fix(openviking): remove naive HTTP-status regex from embedding alert`.
- Flux `flux-system` GitRepository fetched new revision `main@sha1:5b1d6c108141b88ddeb4bb4eb43eceed1493c90f`.
- Flux `apps` kustomization applied revision `main@sha1:5b1d6c108141b88ddeb4bb4eb43eceed1493c90f`.
- `ConfigMap/openviking-loki-rules` in `observability` namespace updated with the final expression.
- Direct Loki query over the last 2.5 hours returned **zero** matches for the final expression.
- Loki Ruler evaluation at `2026-09-03T14:42:39Z` ran the final query with `post_filter_lines: 0`.
- Alertmanager `/api/v2/alerts` listed **zero** active OpenViking alerts.

## Commands used

```bash
cd ~/Projects/homelab-2nd

# edit apps/openviking/openviking-loki-rule.yaml

git add apps/openviking/openviking-loki-rule.yaml
git commit -m "fix(openviking): tighten OpenVikingEmbeddingFailures Loki rule

The previous regex matched any log line containing 'embedding',
'embeddings', 'nomic-embed-text', or generic timeout/connection words.
This fired on healthy embedding traffic. Now it requires an embedding
keyword AND an error/timeout/HTTP-error indicator.

Fixes noisy alert reported in chat on 2026-09-03."
git push origin main

ssh homelab-2nd 'sudo flux reconcile source git flux-system -n flux-system'
ssh homelab-2nd 'sudo flux reconcile kustomization apps -n flux-system'

ssh homelab-2nd 'sudo kubectl -n observability get cm openviking-loki-rules -o yaml'
ssh homelab-2nd 'sudo kubectl -n observability logs loki-0 -c loki --tail=80' \
  | grep -E "OpenVikingEmbeddingFailures"

ssh homelab-2nd \
  'sudo kubectl -n observability exec pod/alertmanager-prometheus-stack-kube-prom-alertmanager-0 -- wget -qO- http://localhost:9093/api/v2/alerts' \
  | python3 -c "import sys,json; al=json.load(sys.stdin); print([a['labels']['alertname'] for a in al if a['labels'].get('alertname','').startswith('OpenVikingEmbedding')])"
```

## Result

- The noisy `OpenVikingEmbeddingFailures` alert no longer fires on healthy embedding traffic or slow-but-successful embedding calls.
- The rule now detects actual embedding-related failures (errors, exceptions, connection refused, timeouts) instead of all embedding mentions or numeric timing values.

## Lesson

When writing log-based alerts, avoid matching generic feature keywords or unanchored numeric patterns. `4[0-9][0-9]|5[0-9][0-9]` matches any three-digit number starting with 4 or 5 anywhere in the line — including benign response times and durations. Anchor HTTP-status matching to the actual log format, or rely on explicit error/timeout words.
