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

The `OpenVikingEmbeddingFailures` rule in `apps/openviking/openviking-loki-rule.yaml` used this regex:

```logql
|~ "embedding|embeddings|nomic-embed-text|ConnectTimeout|APITimeoutError|connection|timeout"
```

This matched **every log line containing the word "embedding" or "embeddings"**, including healthy embedding requests. The alert was effectively an "embedding feature exists" detector, not a failure detector.

## Changes made

### `apps/openviking/openviking-loki-rule.yaml`

Replaced the broad single regex with two chained filters that require embedding context **and** an actual error/timeout/HTTP-error indicator:

```logql
{ k8s_namespace_name="openviking" }
  |~ "embedding|embeddings|nomic-embed-text"
  |~ "Error|ERROR|ERR|FATAL|fatal|Traceback|Exception|exception|unhealthy|timeout|Timeout|connect.*refused|ConnectionError|5[0-9][0-9]|4[0-9][0-9]"
```

This still catches genuine embedding failures (timeouts, connection errors, HTTP 4xx/5xx, exceptions) but ignores routine embedding request logs.

## Verification

- Committed and pushed: `36f9323 — fix(openviking): tighten OpenVikingEmbeddingFailures Loki rule`.
- Flux `flux-system` GitRepository fetched new revision `main@sha1:36f9323fd32508a06d1b4f0b03a97039f9693650`.
- Flux `apps` kustomization applied revision `main@sha1:36f9323fd32508a06d1b4f0b03a97039f9693650`.
- `ConfigMap/openviking-loki-rules` in `observability` namespace updated with the new expression.
- Loki Ruler reloaded the file at `2026-09-03T12:27:00.455Z` (`updating rule file /var/loki/rules-temp/fake/openviking-errors.yaml`).
- Next evaluation at `2026-09-03T12:28:39Z` ran the new query.
- Alertmanager `/api/v2/alerts` no longer listed `OpenVikingEmbeddingFailures` as active.

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

- The noisy `OpenVikingEmbeddingFailures` alert no longer fires on healthy embedding traffic.
- The rule now detects actual embedding-related failures instead of all embedding mentions.

## Lesson

When writing log-based alerts, avoid matching generic feature keywords. Anchor the regex to failure indicators (errors, exceptions, timeouts, non-2xx HTTP status codes) or the alert will page on normal operation.
