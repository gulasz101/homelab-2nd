---
title: "firecrawl: fix false-positive playwright down and noisy memory alerts; bump rabbitmq memory"
date: 2026-09-02
llm: "kimi-k2.7-code"
tags:
  - homelab-2nd
  - firecrawl
  - prometheus
  - alertmanager
  - monitoring
---

# Firecrawl alert fix

## Alert received

Supreme Leader (`akadmin`) forwarded a Mattermost alert at 2026-09-02:

```
Firecrawl Playwright pod is down — No playwright-service pod has been reported as up for more than 2 minutes.
FirecrawlMemoryAboveRequest: Firecrawl container memory is above its request — firecrawl-api-6c99877977-zxjr4/api memory usage exceeds its requested memory for more than 5 minutes.
FirecrawlMemoryAboveRequest: Firecrawl container memory is above its request — rabbitmq-57dfdf4d64-bxhcn/rabbitmq memory usage exceeds its requested memory for more than 5 minutes.
FirecrawlErrorLogs: Firecrawl component logging errors (resolved)
```

## Root causes

### 1. `FirecrawlPlaywrightPodDown` was a permanent false positive

The alert used:

```promql
absent(up{namespace="firecrawl", pod=~"playwright-service.*"}) == 1
```

The only `ServiceMonitor` in the firecrawl namespace targets `firecrawl-api` on `/metrics`. `playwright-service` is not scraped, so `up{pod=~"playwright-service.*"}` never exists, making `absent(...)` always true.

### 2. `FirecrawlMemoryAboveRequest` was noise

Request-based memory alerts fire whenever normal working-set usage exceeds a scheduling hint. Firecrawl API requests 1 GiB but normally runs ~3 GiB; RabbitMQ requests 256 MiB but normally runs ~380 MiB. This matches the same anti-pattern fixed for OpenViking on 2026-09-02.

### 3. RabbitMQ was near its memory limit and had been OOM-killed

Live inspection showed `rabbitmq-57dfdf4d64-bxhcn` had `lastState.terminated.reason: OOMKilled` with exit code 137. Its limit was 512 MiB and working set was ~380 MiB, leaving almost no headroom.

## Changes made

### `apps/firecrawl/firecrawl-prometheus-rules.yaml`

- Replaced `FirecrawlPlaywrightPodDown` with `FirecrawlPlaywrightPodNotReady` using `kube_pod_status_ready` (excludes Job pods):

```promql
kube_pod_status_ready{namespace="firecrawl", pod=~"playwright-service.*", condition="true"} != 1
unless on (pod) kube_pod_owner{namespace="firecrawl", owner_kind="Job"}
```

- Removed `FirecrawlCPUAboveRequest` and `FirecrawlMemoryAboveRequest`.
- Added `FirecrawlMemoryAbove85PercentLimit`:

```promql
100 * sum by (pod, container) (
  container_memory_working_set_bytes{namespace="firecrawl", container!=""}
) / sum by (pod, container) (
  kube_pod_container_resource_limits{namespace="firecrawl", resource="memory", container!=""}
) > 85
```

with `for: 15m` and `severity: warning`.

- Kept the existing `FirecrawlCPUAbove90PercentLimit` and `FirecrawlMemoryAbove90PercentLimit` critical alerts.

### `apps/firecrawl/rabbitmq-deployment.yaml`

Bumped RabbitMQ resources to give it headroom after the OOMKill:

```yaml
resources:
  requests:
    cpu: 50m
    memory: 512Mi
  limits:
    cpu: 500m
    memory: 1Gi
```

## Verification

- Committed and pushed: `72d198c — fix(firecrawl): replace noisy request-based alerts with limit-based readiness checks; bump rabbitmq memory`.
- Flux `apps` kustomization reconciled to `main@sha1:72d198c128b03d1fc62a0c304cbce38976a1f581`.
- New RabbitMQ pod `rabbitmq-cdc9b777f-pvtsj` rolled out with limits `{cpu: 500m, memory: 1Gi}` and requests `{cpu: 50m, memory: 512Mi}`.
- Prometheus config reloaded at `2026-09-02T21:17:57Z`.
- Re-checked `/api/v1/alerts`: no Firecrawl alerts remain firing.
- Re-checked `/api/v1/rules`: only the new rule names are present in the firecrawl group.

## Commands used

```bash
cd ~/Projects/homelab-2nd
git add apps/firecrawl/firecrawl-prometheus-rules.yaml apps/firecrawl/rabbitmq-deployment.yaml
git commit -m "fix(firecrawl): replace noisy request-based alerts with limit-based readiness checks; bump rabbitmq memory"
git push origin main

ssh -i ~/.ssh/id_ed25519.homelab-2nd gulasz101@192.168.1.179 \
  'sudo flux reconcile kustomization apps --with-source --kubeconfig=/etc/rancher/k3s/k3s.yaml'

ssh -i ~/.ssh/id_ed25519.homelab-2nd gulasz101@192.168.1.179 \
  'sudo kubectl -n firecrawl get deployment rabbitmq -o jsonpath="{.spec.template.spec.containers[0].resources}"'

PROM=$(ssh -i ~/.ssh/id_ed25519.homelab-2nd gulasz101@192.168.1.179 \
  'sudo kubectl -n observability get svc prometheus-stack-kube-prom-prometheus -o jsonpath="{.spec.clusterIP}"')
ssh -i ~/.ssh/id_ed25519.homelab-2nd gulasz101@192.168.1.179 \
  "curl -s 'http://${PROM}:9090/api/v1/alerts'" | grep -o '"alertname":"Firecrawl[^"]*"' | sort -u
```

## Result

- The permanent false-positive `FirecrawlPlaywrightPodDown` alert is gone.
- The noisy request-based CPU/memory alerts are gone.
- A meaningful 85%-of-limit memory warning is now in place, matching the OpenViking pattern.
- RabbitMQ has 1 GiB of memory limit and 512 MiB request, reducing OOMKill risk.

## References

- `homelab/tracking/2026-09-02-openviking-memory-alert-tuning.md` — same limit-based pattern applied earlier today.
- `apps/firecrawl/service-monitor.yaml` — only scrapes `firecrawl-api`, which is why `up` was absent for playwright.
