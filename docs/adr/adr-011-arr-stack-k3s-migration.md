# ADR-011: arr-stack migrates to a dedicated k3s namespace

**Status:** Proposed  
**Date:** 2026-09-05  

## Context

The Docker Compose arr-stack (Sonarr, Radarr, Prowlarr, Bazarr, qBittorrent, Jellyfin, FlareSolverr, Homepage, Caddy, Gluetun/Mullvad) has run on `arr-box.local` (`192.168.1.162`) since early 2026. `arr-box` joined the homelab-2nd k3s cluster on 2026-09-05 as a CPU-only worker. The goal is to decommission the Docker Compose deployment and run the stack as Flux-managed workloads in their own namespace.

Key constraints:

- The stack is **LAN-only** for now. Public ingress (Cloudflare Tunnel) and Authentik gating are explicitly out of scope.
- qBittorrent and all torrent-related indexers must never expose a German IP; all outbound traffic must exit through the Mullvad/Spain VPN.
- All durable storage must live on `openmediavault` (OMV) per the homelab architecture guardrails.
- The `gulasz101/homelab-2nd` repo is public; all secrets must be SOPS-encrypted.
- Every service must be observable (logs, metrics where available, dashboards, alerts).

## Decision

We will create a new k3s namespace `arr-stack` under `apps/arr-stack/` in `gulasz101/homelab-2nd`, deployed via Flux. The deployment will:

1. **Lift-and-shift existing configs** from `/opt/arr-stack/config/*` into k3s `local-path` PVCs, preserving SQLite databases and Jellyfin metadata.
2. **Pin all pods to `arr-box`** using `nodeSelector: kubernetes.io/hostname: arr-box` so NFS mounts and `/dev/net/tun` stay local and `t460` is not involved.
3. **Use a single shared gluetun proxy** for all VPN-required outbound traffic. One gluetun pod runs with Mullvad WireGuard; qBittorrent, Sonarr, Radarr, Prowlarr, and FlareSolverr configure their HTTP/SOCKS5 proxy to route outbound traffic through it. Internal service-to-service traffic uses normal cluster DNS.
4. **Keep OMV NFS** for `/mnt/media` and `/mnt/downloads` via explicit PVs/PVCs.
5. **Expose services via NodePort** on fixed high ports bound to `192.168.1.162`. Homepage at `http://192.168.1.162:30030` serves as the clickable dashboard; no reverse proxy, subdomains, Cloudflare Tunnel, or Authentik in this phase.
6. **Drop the Docker `docker.sock` Homepage widget** and replace it with static service links / PodMonitor-based health.
7. **Keep SQLite** for Sonarr, Radarr, Bazarr, and Jellyfin on `local-path` PVCs; no CNPG databases in this phase. This is a deliberate exception recorded here.
8. **Rotate all *arr API keys and the qBittorrent password** during migration and store them in SOPS-encrypted Secrets.
9. **Stop the Docker Compose stack before cutover** to avoid two containers using the same Mullvad WireGuard key simultaneously.

## Consequences

**Positive**

- One less hand-maintained Docker Compose stack to drift out of sync with git.
- Storage stays on OMV; config PVCs are rebuildable from the lifted configs or backups.
- Fits the GitOps-first rule and gives the homelab a consistent operational model.
- LAN-only access keeps the attack surface small and avoids public ingress complexity.
- The shared gluetun proxy model avoids running five separate Mullvad tunnels.

**Negative**

- `arr-box` has only 8 GB RAM. Running both Docker Compose and k3s pods during cutover is impossible; the compose stack must be stopped before k3s pods start.
- The proxy model requires reconfiguring qBittorrent and the *arr apps to use the proxy and to use cluster DNS for internal URLs (Prowlarr ↔ Sonarr/Radarr, Bazarr ↔ Sonarr/Radarr).
- Most LinuxServer images expose no Prometheus `/metrics`, so observability will rely heavily on kubelet metrics and Loki log rules.
- Homepage loses the docker widget; the dashboard will show static links only.
- No pretty subdomains in phase 1.
- SQLite on `local-path` is less durable than CNPG; config PVCs must be treated as rebuildable from the original configs or backups.

## Alternatives considered

- **Keep Docker Compose indefinitely.** Rejected: the Supreme Leader wants to consolidate on k3s/Flux.
- **Per-pod gluetun sidecars.** Rejected: would create five separate Mullvad tunnels, is wasteful, and may violate Mullvad terms.
- **Hybrid: keep VPN apps in Docker Compose, migrate only Jellyfin/Bazarr/Homepage.** Rejected: does not achieve the goal of decommissioning the compose stack.
- **In-cluster reverse proxy with subdomains.** Rejected for phase 1 to keep the failure surface small; may be added later if remote access is needed.
- **CNPG for every *arr app.** Rejected as overkill for the default SQLite-backed apps in this phase; documented as a future revisit condition.
- **Expose via Cloudflare Tunnel + Authentik from day one.** Rejected explicitly by the user; remote access is a future decision.

## When to revisit

- Public or Netbird remote access is required.
- GPU transcode is needed for Jellyfin (would move Jellyfin to homelab-2nd).
- `arr-box` RAM is upgraded or decommissioned (would change node placement).
- Any *arr app is moved to Postgres (then CNPG applies).
- Mullvad TOS or connection limits force a different VPN model.
- Pretty subdomains become important enough to add a reverse proxy.

## Known risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **Mullvad key conflict during cutover** | Low | High (VPN down, German IP exposed if qBittorrent starts without VPN) | Stop Docker Compose gluetun before starting k3s gluetun. Verify exit IP is `ES` before allowing qBittorrent to connect. |
| **qBittorrent or *arr apps do not work with SOCKS5/HTTP proxy** | Medium | High (no downloads/indexers) | Spike a test pod before cutover. Keep Docker Compose backup ready for instant rollback. |
| **Cross-service API keys get out of sync after rotation** | Medium | High (Bazarr shows DOWN, indexers return 401) | Run `repair-cross-api-keys.py` equivalent against k3s SQLite DBs before declaring done. Verify `/api/v3/release?movieId=ID` returns results. |
| **`arr-box` runs out of RAM during cutover or normal operation** | Medium | High (OOMKills, stack instability) | Set realistic requests/limits based on `docker stats`. Pin to arr-box only; reassess after RAM upgrade. |
| **Jellyfin clients cannot reach new NodePort** | Low | Medium (family complaints) | Document new URL `http://192.168.1.162:30096`; reconfigure Android TV clients. |
| **NFS mount flakiness on arr-box affects all media apps** | Low | High (apps hang or crash) | Use existing `_netdev,nofail,soft,timeo=30,retry=3` fstab options. Add liveness probes that check NFS path readability. |
| **ConfigMap/Secret rotation does not roll pods** | Medium | Medium (stale config) | Include config hash in pod annotations or manually restart Deployments after secret changes. |
| **Rollback to Docker Compose requires old config backup** | Low | Medium | Take timestamped tar backup of `/opt/arr-stack/config` before stopping compose. Restore it if rollback needed. |
| **SQLite corruption during PVC copy** | Low | High (app fails to start) | Stop apps cleanly, copy while stopped, verify with `PRAGMA integrity_check` where possible. |
| **Homepage widget data not available without docker.sock** | Certain | Low (dashboard less pretty) | Accept static links; use PodMonitor health indicators instead. |
| **LAN-only access means no remote management** | Certain | Low | Defer remote access to future phase with Netbird or Cloudflare Tunnel. |

## Implementation prompt for next session

Use this prompt verbatim in a new session to kick off the actual migration:

```text
[akadmin] Execute the arr-stack k3s migration planned in ADR-011 and the tracking note 2026-09-05-arr-stack-k3s-migration-plan.

Decisions already made:
- Lift-and-shift existing /opt/arr-stack/config into k3s PVCs.
- All pods pinned to arr-box.
- Shared gluetun proxy model: one gluetun pod, apps route outbound through SOCKS5/HTTP proxy.
- LAN access via NodePort: Homepage 30030, Jellyfin 30096, Sonarr 30089, Radarr 30078, Prowlarr 30069, qBittorrent 30080, Bazarr 30076.
- OMV NFS for /mnt/media and /mnt/downloads; local-path PVCs for app configs/SQLite.
- Rotate all API keys and qBittorrent password during migration.
- Reuse existing Mullvad WireGuard key from ~/Projects/arr-stack/.env.sops.
- Stop Docker Compose first to avoid VPN conflict.
- No Cloudflare Tunnel, no Authentik, no reverse proxy in this phase.
- SQLite apps, no CNPG.
- Daily backup CronJob at 04:00 to OMV MinIO/NFS.

Start by:
1. Reading the tracking note and ADR-011.
2. Inspecting current docker stats on arr-box to size requests/limits.
3. Backing up /opt/arr-stack/config to OMV.
4. Generating new API keys and qBittorrent password (do not print them).
5. Writing all Flux manifests under apps/arr-stack/.
6. Updating .env.sops with rotated values.
7. Stopping Docker Compose on arr-box.
8. Copying configs into k3s PVCs and fixing UID 1100 ownership.
9. Reconciling Flux and verifying every service.
10. Running smoke tests: gluetun exit IP ES, Radarr releases >0, Bazarr Series/Movies nav visible, Jellyfin reachable, Homepage links work.

Do not proceed past step 5 without showing me the manifests and runbook for approval. Actually, show me the full runbook with exact commands after step 5, then wait for explicit go-ahead before stopping Docker Compose.
```
