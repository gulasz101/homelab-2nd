# ADR-001: Prometheus time-series storage stays on local-path (ephemeral)

Date: 2026-06-26
Status: Accepted
Supersedes: nothing
Superseded by: nothing

## Context

The homelab observability stack uses `kube-prometheus-stack` to run Prometheus inside the `observability` namespace on `homelab-2nd`. The current HelmRelease configures:

```yaml
prometheus:
  prometheusSpec:
    retention: 10d
    retentionSize: "8GB"
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 10Gi
```

The homelab storage topology is:
- `homelab-2nd` NVMe = fast, ephemeral compute storage (rebuildable from Git repo + backups).
- `openmediavault` (OMV) MinIO = durable object storage (S3) for backups, logs, and large persistent capacity.

Loki was recently migrated to store chunk/ruler data on OMV MinIO, keeping only small tsdb/index working files on `local-path` (see ADR-000 if it exists, otherwise tracking notes `2026-06-26-loki-storage-migration-to-minio-s3.md` and `2026-06-26-loki-migration-to-grafana-community-chart.md`).

This raised the question: should Prometheus time-series data also be made durable by moving it to OMV MinIO or another remote backend?

## Decision

**Keep Prometheus time-series data on `local-path` on `homelab-2nd`. Do not move it to OMV MinIO and do not deploy Thanos/Mimir/long-term remote storage for now.**

### Rationale

1. **Nature of the data.** Metrics are operational telemetry with a short time-to-live (10 days configured). Losing 10 days of Prometheus metrics is acceptable for a homelab. Unlike application logs, photos, or database state, metrics are inherently lossy and rebuildable from fresh scraping.

2. **Performance.** Prometheus performs heavy I/O during compaction, WAL replay, and query execution. `local-path` on NVMe gives low latency and high throughput. OMV MinIO over the network would add latency and complexity for hot metrics storage.

3. **Architecture alignment.** The agreed topology says live/ephemeral data belongs on `homelab-2nd`, durable data belongs on OMV. Prometheus metrics fit the ephemeral bucket.

4. **Cost/complexity trade-off.** Making Prometheus durable would require one of:
   - A Thanos sidecar + Thanos Store/Compactor/Query deployment writing to MinIO.
   - Remote-writing metrics to a durable backend such as Mimir, Thanos Receive, or cloud storage.
   - Running a second object-storage-capable Prometheus stack.
   All of these add significant moving parts for a homelab where 10-day retention is sufficient.

5. **Disaster recovery is still covered.** The node is rebuildable from the Git repo. Prometheus will re-scrape all targets after rebuild. Historical metrics are not considered critical state.

## Consequences

### Positive
- Simpler stack: no Thanos, Mimir, or remote-write backend.
- Fast local query performance on NVMe.
- 10Gi `local-path` PVC is cheap and predictable.

### Negative / Risks
- Loss of up to 10 days of metrics if the `homelab-2nd` node fails or the PVC is destroyed.
- No long-term trend analysis beyond 10 days.
- A future need for multi-year metrics or downsampling would require revisiting this decision.

## Alternatives considered

| Option | Why rejected |
|---|---|
| Thanos sidecar + MinIO | Adds 3+ extra components (Store, Compactor, Query) for data that expires in 10 days. Overkill. |
| Remote-write to cloud | Contradicts the self-hosted/de-Google motivation. |
| Mimir on k3s | Mimir is designed for multi-node clusters; single-node deployment is possible but adds unnecessary operational burden. |

## When to revisit

Revisit this ADR if any of the following become true:
- Retention needs exceed ~30 days.
- Metrics become business-critical (e.g., for SLOs, billing, or compliance).
- We deploy a workload that requires multi-year metric history.
- Storage pressure on `homelab-2nd` NVMe becomes unacceptable.

## References
- `infrastructure/observability/prometheus-stack-helm-release.yaml`
- Tracking notes: `homelab/tracking/2026-06-26-loki-storage-migration-to-minio-s3.md`
- Tracking notes: `homelab/tracking/2026-06-26-loki-migration-to-grafana-community-chart.md`
