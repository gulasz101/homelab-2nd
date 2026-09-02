---
title: "openviking: tune memory alert to fire at 85% of limit for 15 minutes"
date: 2026-09-02
llm: "kimi-k2.7-code"
tags:
  - homelab-2nd
  - openviking
  - prometheus
  - alertmanager
  - monitoring
---

# OpenViking memory alert tuning

## Why we changed it

Supreme Leader noticed the existing alert `OpenVikingMemoryAboveRequest` was firing on memory usage exceeding the Kubernetes *request*, which is not a meaningful signal for capacity planning. The request is just a scheduling hint; what actually matters is how close the pod is to its hard memory *limit*, because that is where it gets OOM-killed.

The old rule:

```yaml
- alert: OpenVikingMemoryAboveRequest
  expr: |
    sum by (pod, container, namespace) (
      container_memory_working_set_bytes{namespace="openviking", container!=""}
    )
    >
    sum by (pod, container, namespace) (
      kube_pod_container_resource_requests{namespace="openviking", resource="memory", container!=""}
    )
  for: 5m
```

This produced noise without telling us anything useful about impending OOM risk.

## Decision

Replace the request-based alert with a limit-based alert that fires when OpenViking's working-set memory exceeds **85% of its container memory limit for more than 15 minutes**.

- 85% gives enough warning before the pod enters real danger.
- 15 minutes avoids transient spikes while still catching sustained pressure.

## What changed

File: `apps/openviking/openviking-prometheus-rules.yaml`

```yaml
- alert: OpenVikingMemoryAbove85PercentLimit
  expr: |
    100 * sum by (pod, container, namespace) (
      container_memory_working_set_bytes{namespace="openviking", container!=""}
    )
    /
    sum by (pod, container, namespace) (
      kube_pod_container_resource_limits{namespace="openviking", resource="memory", container!=""}
    ) > 85
  for: 15m
  labels:
    severity: warning
    namespace: openviking
  annotations:
    summary: "openviking/{{ $labels.pod }} memory above 85% of limit"
    description: "{{ $labels.pod }}/{{ $labels.container }} memory is above 85% of its limit for more than 15 minutes."
```

The existing 90%-of-limit critical alert (`OpenVikingMemoryAbove90PercentLimit`) was left untouched — it still acts as the escalated critical threshold at 5 minutes.

## Steps taken

1. Located the rule in `apps/openviking/openviking-prometheus-rules.yaml`.
2. Replaced `OpenVikingMemoryAboveRequest` with `OpenVikingMemoryAbove85PercentLimit`.
3. Committed with an explicit message and pushed to `main`.
4. Forced Flux reconciliation on the `apps` kustomization using the k3s kubeconfig:
   ```bash
   ssh -i ~/.ssh/id_ed25519.homelab-2nd gulasz101@192.168.1.179 \
     'sudo flux reconcile kustomization apps --with-source --kubeconfig=/etc/rancher/k3s/k3s.yaml'
   ```
5. Verified the live PrometheusRule now shows the new alert name:
   ```bash
   ssh -i ~/.ssh/id_ed25519.homelab-2nd gulasz101@192.168.1.179 \
     'sudo kubectl -n openviking get prometheusrules openviking-resource-alerts -o jsonpath="{.spec.groups[0].rules[1].alert}"'
   # Output: OpenVikingMemoryAbove85PercentLimit
   ```

## Commit

- `0ea0827` — `feat(openviking): alert on memory above 85% of limit for 15m, drop above-request rule`

## Result

The noisy request-based memory alert is gone. The new limit-based alert will only page the Supreme Leader when OpenViking is genuinely eating into its memory headroom for a sustained period.
