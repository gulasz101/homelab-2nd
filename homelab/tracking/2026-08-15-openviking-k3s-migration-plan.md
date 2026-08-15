# OpenViking migration from MacBook host to homelab-2nd k3s — plan

Date: 2026-08-15
Status: **DRAFT — awaiting Supreme Leader approval before execution**

## Why move it at all

OpenViking has been running on the Hermes host (M1 Max MacBook Pro) as a Docker container bound to `0.0.0.0:1933`. It is only consumed by the local Hermes `andrzej` profile, so there is no public DNS / Cloudflare Tunnel requirement. The goal is to treat it like the rest of the homelab: rebuildable from the Git repo, running on `homelab-2nd`, observable through LGTM, and reachable only inside the LAN + Tailscale.

Current state:

- Image: `ghcr.io/volcengine/openviking:latest` (live digest `sha256:07b01246fda12ca9ca6b5d7e21add2d2d9673da805ca4f09ec8d026a878dc7`), version `v0.3.24`.
- Host runtime: Docker on macOS (`openviking` container, arm64 image).
- Data: mounted from `~/.openviking` on the MacBook into `/app/.openviking`.
- Live workspace on disk is tiny (~32 KiB) because the real state is in `/app/.openviking/workspace/_system/queue/queue.db`, `/app/.openviking/workspace/vectordb/...`, and the AGFS store.
- Config: `/app/.openviking/ov.conf` (JSON):
  - server: `0.0.0.0:1933`, root API key `change-me-please`.
  - storage: `workspace: /app/.openviking/workspace`.
  - embedding: in-cluster Ollama GPU embeddings on `http://192.168.1.179:30114/v1`, model `nomic-embed-text`, provider `openai`, key `local`. In k3s this becomes the cluster-internal service `http://ollama-embeddings.gpu-embedding.svc.cluster.local:11434/v1`.
  - vlm: LiteLLM proxy via public `https://llm.voitech.dev/v1`, model `mistral-3.5-middle`.
- Health endpoint: `GET /health` (no auth), readiness: `GET /ready` (no auth). `GET /metrics` returns "Prometheus metrics are disabled." — no native metrics.
- CLI config `~/.openviking/ovcli.conf` points to `http://127.0.0.1:1933`, root API key `change-me-please`, account `homelab`, user `andrzej`.
- A local `watchdog.sh` on the MacBook pings health + embedding endpoint and posts to a Mattermost webhook if anything fails.

## Decision summary

**Copy** (not move) OpenViking to `homelab-2nd` k3s in a new namespace `openviking`, expose it internally on `192.168.1.179:30193` via a `NodePort` Service, back the workspace with a `local-path` PVC (fast, rebuildable) plus an hourly backup to OMV MinIO, and point embeddings at the homelab-2nd hosted Ollama GPU embedding endpoint. No Cloudflare Tunnel, no public ingress. The Hermes host (and any Tailscale client) will point `ovcli.conf` at `http://192.168.1.179:30193` instead of `127.0.0.1:1933`. The original MacBook Docker container stays running until cutover is verified, giving a rollback path.

## ADR to write

`docs/adr/adr-013-openviking-k3s-local-nodeport.md` — local-only internal service, NodePort chosen over hostPort / LoadBalancer, `local-path` chosen for live workspace, MinIO chosen for backup durability.

## Files to add / change in the repo

### New namespace

`apps/openviking/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openviking
  labels:
    app.kubernetes.io/name: openviking
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
```

Use `baseline` (not `restricted`) because the upstream image runs as `root` and we do not control its user/FS layout. We can still drop capabilities and make root read-only.

### Secrets (SOPS-encrypted)

`apps/openviking/openviking-root-api-key.sops.yaml`

- Keep the existing root API key `change-me-please` so the running Hermes profile doesn't need a key rotation, but store it in SOPS in the repo. The repo is public; the plaintext key must never appear in any committed file.
- Keys: `root-api-key`.

`apps/openviking/openviking-vlm-api-key.sops.yaml`

- The existing VLM key used for `https://llm.voitech.dev/v1`. Pull the current value from the live `~/.openviking/ov.conf` on the MacBook, encrypt it, and mount it into the container.
- Keys: `api-key`.

`apps/openviking/openviking-mattermost-webhook-url.sops.yaml`

- Reuse the same Mattermost webhook URL used by the watchdog. Decrypt the existing `~/.openviking/.watchdog.env` or read the live secret from the MacBook, encrypt into this namespace-local secret.
- Keys: `url`.

`apps/openviking/openviking-minio-backup-creds.sops.yaml`

- OMV MinIO backup user credentials (reuse pattern from `honcho-minio-backup-creds`).
- Keys: `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY`.

### PVC for live workspace

`apps/openviking/openviking-workspace-pvc.yaml`

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openviking-workspace
  namespace: openviking
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 20Gi
```

The live workspace is currently ~32 KiB of metadata plus small SQLite/vector files. 20 GiB is generous headroom for growth. `local-path` because OpenViking is an in-memory-ish operational database; if the node dies, we restore from MinIO backup.

### ConfigMap for non-secret config

`apps/openviking/openviking-config-configmap.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: openviking-config
  namespace: openviking
data:
  ov.conf: |
    {
      "server": {
        "host": "0.0.0.0",
        "port": 1933,
        "root_api_key": "${OPENVIKING_ROOT_API_KEY}"
      },
      "storage": {
        "workspace": "/app/.openviking/workspace"
      },
      "log": {
        "level": "INFO",
        "output": "stdout"
      },
      "embedding": {
        "dense": {
          "api_base": "http://ollama-embeddings.gpu-embedding.svc.cluster.local:11434/v1",
          "api_key": "local",
          "provider": "openai",
          "dimension": 768,
          "model": "nomic-embed-text"
        }
      },
      "vlm": {
        "api_base": "http://litellm.llm-hub.svc.cluster.local:4000/v1",
        "api_key": "${OPENVIKING_VLM_API_KEY}",
        "provider": "openai",
        "extra_headers": {
          "User-Agent": "OpenViking/1.0"
        },
        "model": "mistral-3.5-middle",
        "timeout": 3600,
        "max_concurrent": 64
      }
    }
```

**Embedding path:** uses the homelab-2nd hosted Ollama GPU embeddings service inside k3s (`http://ollama-embeddings.gpu-embedding.svc.cluster.local:11434/v1`). This is the same endpoint that backs docs-mcp-server and Honcho.

**VLM path:** switched from public `https://llm.voitech.dev/v1` to in-cluster LiteLLM (`http://litellm.llm-hub.svc.cluster.local:4000/v1`), matching Honcho. If LiteLLM is unavailable we can revert to the public endpoint without touching data.

Use env substitution or a simple shell init container to render the final config from the ConfigMap template. The container entrypoint reads `OPENVIKING_CONFIG_FILE` (default `/app/.openviking/ov.conf`). Easiest reliable path: an init container copies the template, expands env vars with `envsubst` (busybox), and writes `/app/.openviking/ov.conf`.

### Deployment

`apps/openviking/openviking-deployment.yaml`

- Single-replica Deployment.
- Strategy `Recreate` (single-node k3s + hostPort-style NodePort; avoid scheduling conflicts).
- Image: pin to the digest currently running: `ghcr.io/volcengine/openviking@sha256:07b01246fda12ca9ca6b5d7e21add2d2d9673da805ca4f09ec8d026a878dc7`.
- Security context: run as non-root if possible. Test first; the image currently runs as `root`. If it breaks, document `baseline` PodSecurity and read-only root FS with emptyDir `/tmp`.
- Env:
  - `OPENVIKING_CONFIG_FILE=/app/.openviking/ov.conf`
  - `OPENVIKING_ROOT_API_KEY` from `openviking-root-api-key` secret.
  - `OPENVIKING_VLM_API_KEY` from `openviking-vlm-api-key` secret.
- Volumes:
  - `workspace` PVC mounted at `/app/.openviking/workspace`.
  - `config` emptyDir mounted at `/app/.openviking` (init container writes `ov.conf` here; must not overwrite workspace mount — use subPath `ov.conf` so the rest of `/app/.openviking` is the emptyDir and workspace is a separate sub-mount under it).
  - `tmp` emptyDir at `/tmp`.
- Init container `render-config`:
  - image: `busybox:1.36`
  - mounts config ConfigMap template at `/tmpl/ov.conf`, emptyDir `/cfg`, runs `envsubst < /tmpl/ov.conf > /cfg/ov.conf`.
- Probes:
  - liveness `GET /health` port 1933.
  - readiness `GET /ready` port 1933.
- Resources: start with `requests: cpu 100m, memory 256Mi; limits: memory 1Gi`. Current Docker usage is ~210 MiB. Monitor and right-size after migration.

### Service

`apps/openviking/openviking-service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: openviking
  namespace: openviking
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: openviking
  ports:
    - name: http
      port: 1933
      targetPort: 1933
      nodePort: 30193
```

NodePort `30193` on the node IP `192.168.1.179`. Internal k3s service name: `openviking.openviking.svc.cluster.local:1933`.

### Backup CronJob

`apps/openviking/openviking-backup-cronjob.yaml`

Use the OpenViking CLI's `ov backup` to produce a `.ovpack` file and upload it to OMV MinIO. Container image can be the same pinned OpenViking image (has `ov` binary) plus a small sidecar script, or a separate `mc` (MinIO client) image. Simpler: run a CronJob with the OpenViking image that:

1. Renders the CLI config (`ovcli.conf`) pointing at `http://openviking.openviking.svc.cluster.local:1933` with the root API key.
2. Runs `ov backup /tmp/openviking-$(date +%Y%m%d-%H%M%S).ovpack --include-vectors`.
3. Uses `mc` to mirror the resulting `.ovpack` to the `cnpg-backups` bucket under `openviking/backups/`.

Schedule: every hour (`0 * * * *`). Retention: keep last 7 days of `.ovpack` backups on MinIO (168 backups), prune older ones with `mc rm --older-than 7d`. Memory data is essential; frequent backups are the durability layer.

### Observability package

`apps/openviking/openviking-prometheus-rules.yaml`

Resource alerts labelled `release: prometheus-stack` and `namespace: openviking`, copied from the `voice`/`honcho` template, plus pod-health alerts:

- `OpenVikingPodNotReady` — `kube_pod_status_ready{namespace="openviking", pod=~"openviking.*"} != 1` for >3m.
- `OpenVikingContainerRestarting` — `rate(kube_pod_container_status_restarts_total{namespace="openviking"}[15m]) > 0`.

`apps/openviking/openviking-alertmanager-config.yaml`

AlertmanagerConfig in `openviking` namespace routing namespace-labelled alerts to the Mattermost webhook secret.

`apps/openviking/openviking-loki-rule.yaml`

ConfigMap in `observability` namespace with `loki_rule: "true"` label. This replaces the old MacBook watchdog logic:

- `OpenVikingErrorsOrCrashes` — logs in `{k8s_namespace_name="openviking"}` matching `Error|ERROR|ERR|FATAL|fatal|Traceback|ConnectTimeout|APITimeoutError|UNHEALTHY`.
- `OpenVikingEmbeddingFailures` — logs matching embedding endpoint failures (`embedding`, `embeddings`, `nomic-embed-text`, `timeout`, `connection`).

This gives parity with the previous watchdog checks (health, embedding model availability, embedding inference) without running a custom shell script on the MacBook.

`apps/openviking/openviking-dashboard-configmap.yaml`

Per-namespace Grafana dashboard generated from the standard template (`render_namespace_dashboard.py`) for `openviking`. No native app metrics, so the dashboard shows pod resource usage + logs.

**No ServiceMonitor / PodMonitor.** OpenViking has no `/metrics` endpoint; metrics are skipped per Supreme Leader decision.

### Watchdog replacement

The current MacBook `~/.openviking/watchdog.sh` checks OpenViking health, embedding model list, and embedding inference, then posts to Mattermost. After migration this is replaced by:

- Kubernetes probes on `/health` and `/ready`.
- Prometheus pod-health alerts (`OpenVikingPodNotReady`, `OpenVikingContainerRestarting`).
- Loki error alerts (`OpenVikingErrorsOrCrashes`, `OpenVikingEmbeddingFailures`) — direct replacements for the watchdog's health/embedding checks.
- Resource alerts.
- Hourly backup CronJob `ov status` output, which can alert on failure.

After cutover is verified, disable/remove `~/.openviking/watchdog.sh` and `.watchdog.env` from the MacBook. Also disable the cron job or launchd agent that currently runs the watchdog, so it stops posting duplicate alerts alongside the k3s Alertmanager rules.

### Kustomization updates

`apps/kustomization.yaml`: add the new `openviking` resources in a block after `shlink` (alphabetical-ish order).

`infrastructure/coredns/coredns-custom-homelab.yaml`: no change. CoreDNS alias skipped per Supreme Leader decision — Hermes will point directly at `192.168.1.179:30193`.

## Hermes host reconfiguration

After the k3s deployment is live, update the Andrzej profile on the MacBook:

1. **Stop and remove the local Docker container:** NOT during the copy/verification phase. The MacBook container stays running until k3s cutover is verified. After verification, run:
   ```bash
   docker stop openviking && docker rm openviking
   ```
2. Update `~/.openviking/ovcli.conf`:
   ```json
   {
     "url": "http://192.168.1.179:30193",
     "api_key": "change-me-please",
     "root_api_key": "change-me-please",
     "account": "homelab",
     "user": "andrzej"
   }
   ```
3. Remove or disable `~/.openviking/watchdog.sh` and `.watchdog.env` after cutover is verified.
4. Keep `~/.openviking/docker-compose.yml` and `ov.conf` as offline backups until the migration is verified, then archive them out of the live path.

## Migration procedure (execution steps after approval)

### Phase 0 — prepare the repo

1. Write the ADR (`docs/adr/adr-013-openviking-k3s-local-nodeport.md`).
2. Create all new YAML files under `apps/openviking/`.
3. Encrypt secrets with the homelab-2nd age key:
   - `openviking-root-api-key.sops.yaml`
   - `openviking-vlm-api-key.sops.yaml`
   - `openviking-mattermost-webhook-url.sops.yaml`
   - `openviking-minio-backup-creds.sops.yaml`
4. Update `apps/kustomization.yaml`.
5. Update CoreDNS alias if desired.
6. Commit, push, wait for Flux reconciliation.

### Phase 1 — export existing memory from the MacBook

1. Ensure the local container is healthy: `curl http://127.0.0.1:1933/health`.
2. Run a backup from inside the running container:
   ```bash
   docker exec openviking /app/.venv/bin/ov backup /tmp/openviking-migration.ovpack --include-vectors --account homelab --user andrzej
   ```
   Verify the file size; if it is unexpectedly small, the vector snapshot may not be included and we should instead copy the live workspace directory.
3. Copy the backup out:
   ```bash
   docker cp openviking:/tmp/openviking-migration.ovpack ~/openviking-migration-$(date +%Y%m%d-%H%M%S).ovpack
   ```
4. Optionally also tarball the live workspace for belt-and-suspenders:
   ```bash
   docker exec openviking tar czf /tmp/workspace.tar.gz -C /app/.openviking workspace
   docker cp openviking:/tmp/workspace.tar.gz ~/openviking-workspace-$(date +%Y%m%d-%H%M%S).tar.gz
   ```

### Phase 2 — seed data on k3s

Option A (preferred if `ov restore` works correctly):

1. Copy the `.ovpack` to `homelab-2nd`.
2. Run a one-off Kubernetes Job in the `openviking` namespace that mounts the workspace PVC, the config secret, and restores:
   ```bash
   ov restore /seed/openviking-migration.ovpack --on-conflict overwrite --vector-mode require
   ```
3. Verify with `ov status` from the same Job or an ephemeral debug pod.

Option B (fallback if `ov restore` mangles vectors or account/user scopes):

1. Copy `workspace.tar.gz` to `homelab-2nd`.
2. Extract it into the mounted PVC before the OpenViking Deployment starts (e.g., an init container or a one-off Job that writes to the PVC).
3. Start the Deployment and verify `ov status` shows the same vector count / queue stats as the source.

### Phase 3 — start the k3s deployment and verify

1. `kubectl get pods -n openviking` — Running and Ready.
2. `curl http://192.168.1.179:30193/health` — `{"status":"ok"}`.
3. `curl http://192.168.1.179:30193/ready` — `{"status":"ready", ...}`.
4. `ov status -o json --account homelab --user andrzej` from a pod with the CLI config — matches source stats (vector count ~930, queue processed ~3572, etc.).
5. Run a `viking_search` from a Hermes test session against the new endpoint and confirm it returns expected memories.

### Phase 4 — cut over the Hermes host

1. Stop the MacBook Docker container.
2. Update `~/.openviking/ovcli.conf` to point at `http://192.168.1.179:30193`.
3. Restart Hermes (or reload the Andrzej profile) so it picks up the new endpoint.
4. Trigger a memory operation in chat and confirm it hits the new endpoint (check OpenViking pod logs).
5. Keep the MacBook container stopped for 24 hours as a rollback window. If anything fails, revert `ovcli.conf` to `127.0.0.1:1933` and `docker start openviking`.

### Phase 5 — clean up and document

1. If 24-hour smoke test passes, `docker rm openviking` and archive `~/.openviking/docker-compose.yml`, `ov.conf`, `watchdog.sh`, and `.watchdog.env` to a migration subfolder.

   **Decommission the MacBook alert:** ensure the cron/launchd job running `watchdog.sh` is disabled so it stops posting to Mattermost.

   **Rollback:** If the k3s instance fails, revert `~/.openviking/ovcli.conf` to `http://127.0.0.1:1933` and restart the MacBook Docker container. Data remains intact on the MacBook until explicitly removed.
2. Verify the first scheduled backup lands in MinIO under `cnpg-backups/openviking/backups/`.
3. Verify Grafana dashboard is visible under folder `openviking`.
4. Update this tracking note with final status and any deviations.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| `ov backup` / `ov restore` doesn't preserve all state or scopes. | Keep workspace tarball fallback; run `ov status` comparison before/after. |
| Root API key is trivial (`change-me-please`). | It is still internal-only. Schedule a follow-up to rotate to a strong key and update Hermes profile. |
| Single-node k3s CPU is 99% requested. | New workload asks only 100m CPU / 256Mi memory. No Cloudflare tunnel container, so net footprint is small. |
| Image runs as root and may not tolerate read-only root FS. | Use PodSecurity `baseline`, read-only root with emptyDir `/tmp`, test during Phase 2. |
| VLM over in-cluster LiteLLM fails. | The LiteLLM service already serves `mistral-3.5-middle` to Honcho. If it fails, fall back to public `llm.voitech.dev` in the config. |
| Embedding endpoint `192.168.1.179:30114` unreachable from inside k3s pods. | Use the in-cluster Ollama service instead: `http://ollama-embeddings.gpu-embedding.svc.cluster.local:11434/v1`. |
| NodePort conflicts with another service on `30193`. | Verify `kubectl get svc -A` before committing; pick a free high port if needed. |

## Open questions before approval

1. Keep root API key `change-me-please`, stored in SOPS (never plaintext in repo).
2. Backup every hour with 7-day MinIO retention.
3. Skip CoreDNS alias; Hermes points directly at `192.168.1.179:30193`.
4. Skip native metrics / ServiceMonitor.
5. Add Prometheus pod-health alerts and Loki-based error/embedding-failure rules that replace the old MacBook watchdog.
6. Decommission the MacBook `watchdog.sh` alert after k3s cutover is verified: stop the cron/launchd job, remove `~/.openviking/watchdog.sh` and `.watchdog.env`, and post a final test to Mattermost from the k3s path to confirm the new alert channel works.

**Status:** awaiting Supreme Leader approval to execute.

## Verification checklist

- [ ] `curl http://192.168.1.179:30193/health` returns 200.
- [ ] `curl http://192.168.1.179:30193/ready` returns ready.
- [ ] `ov status` from inside the cluster shows the same vector/resource counts as the source.
- [ ] A Hermes memory search returns expected results through the new endpoint.
- [ ] Grafana shows the `openviking` dashboard.
- [ ] Loki returns `{k8s_namespace_name="openviking"}` logs.
- [ ] First `.ovpack` backup appears in MinIO under `openviking/backups/`.
- [ ] No plaintext credentials in the repo.
- [ ] MacBook Docker container removed or stopped.

## References

- `~/.openviking/docker-compose.yml` — current host deployment.
- `~/.openviking/ov.conf` — current host config.
- `apps/docs-mcp/docs-mcp-deployment.yaml` — prior art for local-only `hostPort` service on k3s.
- `apps/honcho/honcho-service.yaml` — prior art for LAN-only `NodePort` service.
- `apps/voice/*` — current smallest per-namespace observability package template.
- `docs/adr/adr-002-docs-mcp-server-local-deployment.md` — related local-only service ADR.
- OpenViking docs: `volcengine-openviking.mintlify.app/guides/deployment` and `/guides/monitoring` (indexed in homelab docs-mcp-server as `openviking` and `openviking-monitoring`).
