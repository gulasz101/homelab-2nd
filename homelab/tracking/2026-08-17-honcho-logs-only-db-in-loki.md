---
date: 2026-08-17
service: honcho
namespace: honcho
loki: true
otel: true
---

# Honcho logs in Loki only show `honcho-db-1`

## Report

User (`akadmin`) asked why the Grafana honcho dashboard shows logs only from `honcho-db-1` and nothing from `honcho-api`, `honcho-deriver`, or `honcho-redis`.

## Diagnosis

1. **Dashboard queries are correct.**
   The generated honcho dashboard logs panel uses OTel-style labels:
   ```logql
   {k8s_namespace_name="honcho"}
   ```
   and the five toggle filters all use `k8s_namespace_name="honcho"`. Verified from `apps/honcho/honcho-dashboard-configmap.yaml`.

2. **Loki has honcho namespace data, but only from `honcho-db-1`.**
   Direct Loki query:
   ```bash
   ssh homelab-2nd "sudo kubectl -n observability exec deploy/loki-gateway -- curl -sG 'http://loki.observability.svc.cluster.local:3100/loki/api/v1/query_range' --data-urlencode 'query={k8s_namespace_name=\"honcho\"}' --data-urlencode 'start=1786340130000000000' --data-urlencode 'end=1786944930000000000' --data-urlencode 'limit=5'"
   ```
   Returned two streams, both `k8s_pod_name="honcho-db-1"` (CloudNativePG checkpoint logs).

3. **The other pods exist but are log-silent.**
   | Pod | Last log file mtime | Contents |
   |---|---|---|
   | `honcho-api-6fcbc8cc65-cm44f` | `0.log` 2026-08-15 23:05 | Uvicorn startup only |
   | `honcho-deriver-54fd78c68c-4b8qj` | `0.log` 2026-08-16 23:05 | Queue cleanup every ~12 h |
   | `honcho-redis-cc9db64cc-th2jz` | `8.log` 2026-07-30 22:22 | Redis startup only |
   | `honcho-db-1` | `9.log` actively written | Continuous PostgreSQL logs |

   `kubectl logs` confirms the same — api/deriver/redis emit almost nothing after startup.

4. **OTel filelog receiver is `start_at: end` with no checkpoint storage.**
   The OpenTelemetry Collector `filelog` receiver (from the `logsCollection` preset) starts at the **end** of each log file. That means:
   - startup logs emitted before the receiver first sees the file are **never** ingested;
   - if a pod is quiet after startup, Loki stays empty for that pod.

   Live collector config confirmed:
   ```yaml
   file_log:
     start_at: end
     include:
       - /var/log/pods/*/*/*.log
     operators:
       - type: container
   ```

5. **`k8s_attributes` enrichment is working.**
   The Loki stream for `honcho-db-1` includes correct `k8s_namespace_name`, `k8s_pod_name`, `k8s_container_name`, `container_image_tag`, etc. So the pod-association path in the collector is fine.

## Root cause

No observability bug. The non-DB honcho pods are simply not emitting logs, and the filelog receiver's `start_at: end` + lack of persistent checkpointing means even their startup logs are gone from Loki's point of view.

## Options to improve visibility

1. **Enable filelog checkpoint storage** in the OpenTelemetry Collector HelmRelease.
   - Add a `file_storage` extension.
   - Reference it from the `filelog` receiver `storage` field.
   - Change `start_at: beginning` so the first time a file is seen it is read from the top; the checkpoint prevents re-ingestion after that.
   - This would capture future pod startup/restart logs, not backfill the current silent pods.

2. **Enable uvicorn/FastAPI access logs** in the honcho-api deployment.
   - Currently honcho-api logs only startup. With request logging it would produce a continuous stream and show up in Loki.
   - This is an application-level change, not an observability change.

3. **Use a wider Grafana time range.**
   - The deriver logs roughly twice per day. With "Last 7 days" it would appear. Default "Last 1 hour" hides it.

## Verification commands

```bash
# What pods are in honcho namespace
ssh homelab-2nd "sudo kubectl -n honcho get pods"

# Direct Loki query
ssh homelab-2nd "sudo kubectl -n observability exec deploy/loki-gateway -- curl -sG 'http://loki.observability.svc.cluster.local:3100/loki/api/v1/query_range' --data-urlencode 'query={k8s_namespace_name=\"honcho\"}' --data-urlencode 'start=$(python3 -c "import time; print(int(time.time()-7*24*3600)*10**9)")' --data-urlencode 'end=$(python3 -c "import time; print(int(time.time())*10**9)")' --data-urlencode 'limit=20' | python3 -m json.tool"

# Raw pod logs on node
ssh homelab-2nd "sudo ls -lt /var/log/pods/honcho_honcho-api-*/api/"
ssh homelab-2nd "sudo ls -lt /var/log/pods/honcho_honcho-deriver-*/deriver/"
ssh homelab-2nd "sudo ls -lt /var/log/pods/honcho_honcho-redis-*/redis/"
```

## References

- `infrastructure/observability/opentelemetry-collector-helm-release.yaml`
- `apps/honcho/honcho-dashboard-configmap.yaml`
- OpenTelemetry filelog receiver docs (not indexed in docs-mcp yet).

## Follow-up

Pending decision from Supreme Leader on whether to:
- add filelog checkpoint storage, and/or
- enable access/request logging in honcho-api.
