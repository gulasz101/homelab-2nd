# Runbook: graceful full-site power-down and power-up

**Scope:** the physical homelab rack — `homelab-2nd` (k3s control plane), `t460` and `arr-box`
(k3s workers), `openmediavault` (durable NAS + MinIO S3), and optionally the OPNsense router.
**Not in scope:** the M1 Max MacBook Pro (Hermes host) — it stays up on battery so the agent is
reachable while the rack is dark.

**Why this exists:** the rack gets physically moved (2026-10-10: homelab-2nd → living room). A
pull-the-plug move risks unclean filesystems on OMV (the only durable store), a mid-checkpoint
Postgres shutdown, and torrent/session state loss on arr-box. This runbook makes the shutdown and
the bring-up boring and repeatable.

---

## Shutdown order (and why)

Dependencies decide the order. Everything ends at OMV, so OMV goes down **last**.

```
workloads ──► k3s workers ──► k3s control plane ──► OMV (NFS + MinIO)
  (drain)        (t460,          (homelab-2nd)         (durable store)
                 arr-box)
```

1. **Final CNPG backup to MinIO.** WAL archiving already covers PITR up to the last checkpoint, but
   a fresh `Backup` per cluster costs a minute and gives a clean, human-named restore point.
   → requires the cluster **and** OMV MinIO up.
2. **Cordon all nodes.** Prevents the scheduler from moving pods onto a node that is already being
   torn down. A `nodeName`-bound pod still schedules on a cordoned node, which is what makes the
   poweroff trick below work.
3. **Drain the workers.** Graceful pod termination (SIGTERM → app flush) instead of a hard stop.
   Because *every* node is cordoned, evicted pods go `Pending` rather than being rescheduled —
   no duplicate Sonarr/qBittorrent instances racing over the same files.
4. **Power off the workers.**
5. **Drain + power off the control plane.**
6. **Stop MinIO, then power off OMV.**

### The one trap: `terminationGracePeriodSeconds: 1800`

Every CNPG pod carries a **1800-second (30 min)** termination grace period. A plain
`systemctl poweroff` therefore has no idea how long to wait, and a naive `kubectl delete` looks
like it has hung. `kubectl drain --grace-period=120` overrides the pod's own value for that
deletion, so the eviction is bounded at 2 minutes per pod. Postgres does a fast shutdown + final
checkpoint in seconds, so 120s is generous.

### Reaching t460 (no SSH key, no passwordless sudo)

`t460` has neither an SSH key for `gulasz101` nor passwordless sudo; `arr-box` has SSH but no
passwordless sudo. Both are therefore shut down from **inside their own host namespace** with a
short-lived privileged pod (the pattern from ADR-018):

```yaml
spec:
  nodeName: <node>      # direct binding bypasses the scheduler → works on a cordoned node
  hostPID: true
  hostNetwork: true
  containers:
    - name: sd
      image: alpine:3.20
      securityContext: { privileged: true }
      command:
        - nsenter -t 1 -m -u -i -n -p -- sh -c
          "systemctl stop k3s-agent; sleep 3; sync; systemctl poweroff"
```

`nsenter -t 1` enters PID 1's namespaces, so the command runs as **root on the host** — no sudo,
no key, no password. Verify it works before the real thing by running `hostname` through it.

### homelab-2nd and OMV

Both have working root access: `ssh homelab-2nd 'sudo systemctl poweroff'` (passwordless sudo) and
`ssh openmediavault '…; shutdown -h now'` (root login).

```bash
ssh homelab-2nd   'sudo systemctl stop k3s; sudo sync; sudo systemctl poweroff'
ssh openmediavault 'docker stop -t 60 minio cadvisor; sleep 3; sync; shutdown -h now'
```

`docker stop -t 60` gives MinIO a full minute to flush before the OS goes down.

### The script

`docs/runbooks/site-shutdown.sh` does the whole sequence with logging, backup waiting, and
down-verification (ping loops). Run it from the Mac:

```bash
~/…/site-shutdown.sh
```

---

## Power-up order (reverse)

```
OMV ──► homelab-2nd (control plane) ──► t460 + arr-box (workers)
```

**OMV first.** Nextcloud, Karakeep, OpenGist, OpenChamber and Mail-Archiver mount OMV NFS, and
CNPG writes its backups to OMV MinIO. If k3s comes up before OMV, those pods crash-loop on
`NFS: mount program didn't pass remote address` / connection refused until OMV answers. Starting
OMV first turns a crash-loop into a non-event.

Then press the button on homelab-2nd and wait for the API server, then the two workers.

### Post-boot verification

```bash
# node state — all three Ready
kubectl get nodes -o wide

# databases — "Cluster in healthy state" for all of them
kubectl get cluster.postgresql.cnpg.io -A

# Flux — 4 kustomizations True
kubectl get kustomization -A

# if Flux is stuck on "Reconciliation in progress", force it:
kubectl -n flux-system annotate gitrepository flux-source reconcile.fluxcd.io/requestedAt="$(date -Iseconds)" --overwrite
kubectl -n flux-system annotate kustomization <name> reconcile.fluxcd.io/requestedAt="$(date -Iseconds)" --overwrite
```

Known cosmetics from previous cold boots (see `2026-07-10-first-outage-cold-boot-recovery.md`):

| Symptom | Cause | Action |
|---|---|---|
| `kubectl` fails with permission denied | `/etc/rancher/k3s/k3s.yaml` perms reset on boot | `sudo kubectl` or fix perms |
| Nextcloud pod `1/2 Running` for ~5 min | chart readiness probe `initialDelaySeconds: 300` | wait; Apache is already serving |
| `ollama` embedding pod `Pending` | CPU requests spike at boot | wait ~60s, it schedules itself |
| Nodes show `SchedulingDisabled` | they were cordoned during shutdown | `kubectl uncordon <node>` |

**`kubectl uncordon` is the one thing people forget.** The shutdown cordons all three nodes; if the
bring-up does not uncordon them, nothing new ever schedules and the cluster looks half-broken.

### No public exposure to re-create

Ingress is dedicated Cloudflare Tunnels with tokens in SOPS inside the repo — `cloudflared` pods
come back with the cluster and re-register themselves. There is no port-forwarding or cert-manager
state to restore.

---

## Router (OPNsense, `192.168.1.1`)

Out of scope for the automatic shutdown: it is a separate box and it is the LAN's DHCP/DNS gateway.
Turning it off takes the LAN (and any WiFi it serves) down with it — which would also cut the
SSH path to the Mac. If the router has to move too, power it down manually **after** everything
else is dark.

## Mac-side caveats while the rack is off

- **DNS is gone.** The Mac's resolver comes from DHCP and points at Pi-hole on `homelab-2nd`
  (`192.168.1.179`). With the rack down, name resolution times out. SSH by IP still works.
  Add `1.1.1.1` as a secondary DNS on the Wi-Fi service if internet resolution is needed.
- **The agent's primary brain is gone.** `llm.voitech.dev` is LiteLLM *inside* the cluster. The
  Hermes profile has a local `lmstudio` fallback (ADR-044) so the agent still answers.
- **MCP servers are gone.** `docs-mcp` (`192.168.1.179:6280`) and Itsaplan
  (`plan-api.voitech.dev`) live behind the cluster; agent startup eats their connect timeouts
  before answering. Budget a couple of minutes for the first reply.
- **Mattermost is gone.** Chat is dead until the cluster is back — use the Hermes CLI over SSH.
