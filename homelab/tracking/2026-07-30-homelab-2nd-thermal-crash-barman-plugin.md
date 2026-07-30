---
date: 2026-07-30
title: homelab-2nd thermal crash — fans bought time, Barman plugin was the CPU arsonist
slug: homelab-2nd-thermal-crash-barman-plugin
---

# homelab-2nd crashed again — fans bought time, Barman plugin was the CPU arsonist

## What happened

Around 22:22 CEST on 2026-07-30, `homelab-2nd` rebooted hard. The previous boot had only started at 19:40 CEST, so the machine ran for less than 3 hours before falling over.

`journalctl -b -1` showed no clean shutdown, no panic, no OOM kill, and no thermal-throttle message. The log just stops. That pattern strongly suggests a hardware-initiated shutdown — either the laptop BIOS, VRMs, or power delivery hitting a thermal/power limit under sustained load.

Supreme Leader had already fitted two large 120 mm fans. They helped: after the reboot, core temps dropped into the 70–85 °C range under load, whereas earlier the same evening they had spiked to 89–90 °C and briefly hit 92–94 °C during startup. The fans are not magic, though, and the root cause was still the sustained CPU load.

## Root cause analysis

### 1. CNPG Barman Cloud plugin was running wild

Two `barman-cloud-backup-list` (actually `barman-cloud-backup-delete`) processes were consuming ~85 % CPU each on the node. They belong to the `plugin-barman-cloud` sidecars in the LiteLLM and Open WebUI CNPG pods.

The immediate triggers were three configuration mistakes:

- **Hourly base backups** were configured for LiteLLM and Open WebUI (`0 * * * *`).
- **`retentionPolicy: "30d"` was set on the `Cluster` resource**, which the Barman Cloud plugin ignores. The plugin sidecar logged repeatedly:
  ```
  Skipping retention policy enforcement, no retention policy specified
  ```
- The **`ObjectStore` resources had no `instanceSidecarConfiguration.resources`**, so the sidecar containers were uncapped and could burn as much CPU as they could grab.

Because retention was not enforced on the ObjectStore, the backup catalogs grew over time, making every retention check and backup-listing operation heavier. On an 8-core laptop board already running a full k3s stack, this was enough to keep the node pinned at high load and temperature until it shut down.

### 2. Ollama embeddings pod left in a failed state

After the reboot, one Ollama embeddings pod was stuck with:

```
Status:  Failed
Reason:  UnexpectedAdmissionError
Message: Pod was rejected: Allocate failed due to no healthy devices present; cannot allocate unhealthy devices nvidia.com/gpu
```

This is a transient NVIDIA device plugin issue after node restart. The other pod in the same Deployment was already running fine, so the stuck pod was just dead weight.

## What was done

### Throttle CNPG Barman Cloud plugin (task 1)

Changed in `gulasz101/homelab-2nd` via Flux:

- `apps/llm-hub/litellm-db-objectstore.yaml`
- `apps/llm-hub/openwebui-db-objectstore.yaml`

Added to each ObjectStore:

```yaml
  retentionPolicy: "30d"
  instanceSidecarConfiguration:
    resources:
      requests:
        cpu: "50m"
        memory: "64Mi"
      limits:
        cpu: "200m"
        memory: "128Mi"
```

Moved `retentionPolicy` from the `Cluster` spec to the `ObjectStore` spec so the plugin actually enforces it. The default `retentionPolicyIntervalSeconds` is 1800 s (30 min), which is acceptable once the retention policy is actually doing work and the sidecar is capped.

Also reduced base backup frequency:

- `apps/llm-hub/litellm-scheduled-backup.yaml`
- `apps/llm-hub/openwebui-scheduled-backup.yaml`

From `0 * * * *` (hourly) to `0 */6 * * *` (every 6 hours). WAL archiving still runs continuously, so RPO remains in the single-digit minutes; base backups are only needed for recovery speed.

Committed and pushed:

```bash
git add apps/llm-hub/litellm-db-objectstore.yaml \
   apps/llm-hub/litellm-scheduled-backup.yaml \
   apps/llm-hub/openwebui-db-objectstore.yaml \
   apps/llm-hub/openwebui-scheduled-backup.yaml

git commit -m "Throttle CNPG Barman Cloud plugin for LiteLLM/OpenWebUI ..."
git push
```

Reconciled Flux:

```bash
sudo flux reconcile kustomization apps --with-source
```

Verified ObjectStores updated with new retention and resource limits. Then rolled the two CNPG pods so the new sidecar resources applied:

```bash
sudo kubectl delete pod -n llm-hub litellm-db-1 openwebui-db-1
```

After the restart, the sidecars showed the correct limits:

```json
{"limits":{"cpu":"200m","memory":"128Mi"},"requests":{"cpu":"50m","memory":"64Mi"}}
```

### Clean up stuck Ollama pod (task 3)

Deleted the two failed Ollama pods:

```bash
sudo kubectl delete pod -n gpu-embedding \
  ollama-embeddings-564c7955bb-k9xgl \
  ollama-embeddings-564c7955bb-nnczd \
  --force --grace-period=0
```

The Deployment left a single healthy pod:

```
ollama-embeddings-564c7955bb-tpqtn   1/1     Running
```

## Immediate result

Within minutes of the CNPG pod restart:

- Load average dropped from ~8.0 to ~1.7.
- Core package temperature dropped from ~87 °C to ~52 °C.

The two `barman-cloud-backup-delete` processes were still running, but capped at 200 m CPU each and now doing real retention cleanup rather than looping fruitlessly.

## Still to watch

- The retention policy will delete obsolete backups over the next few cycles. After cleanup, CPU from retention ops should drop further.
- If the node still crashes with temps/load now under control, the problem is likely VRM/power-delivery or the external GPU enclosure, not CPU thermal.
- OpenGist is in a separate CrashLoopBackOff due to a Postgres password mismatch. That is unrelated to the crash but adds noise and load; should be fixed next.

## Lessons

- **Put `retentionPolicy` on the `ObjectStore`**, not the `Cluster`, when using the Barman Cloud CNPG-I plugin. The Cluster field is deprecated for this plugin and silently does nothing.
- **Cap sidecar resources**. Backup sidecars should never be allowed to grab unlimited CPU on a small node.
- **Hourly base backups + WAL archive is overkill** for small home-lab databases. Every 6 hours is plenty.
- **Fans help, but they don't fix bad config.** A pair of 120 mm fans turned a 94 °C boot into a 52 °C idle, but the node still fell over because the workload was unsustainable.

## Commands for future reference

Check current barman sidecar resources:

```bash
sudo kubectl get pod -n llm-hub litellm-db-1 \
  -o jsonpath='{range .spec.initContainers[?(@.name=="plugin-barman-cloud")]}{.resources}{"\n"}{end}'
```

Force a CNPG pod restart after ObjectStore changes:

```bash
sudo kubectl delete pod -n llm-hub litellm-db-1 openwebui-db-1
```

Watch node load/temp:

```bash
watch -n 2 'uptime; sensors | grep Core'
```
