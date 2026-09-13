# ADR-014: arr-stack API keys are owned by the apps; the SOPS secret mirrors them

**Status:** Accepted  
**Date:** 2026-09-13  

## Context

The arr-stack services (`sonarr`, `radarr`, `prowlarr`, `bazarr`) run LinuxServer.io images. Each **owns its own API key in its own persistent config**:

- Sonarr / Radarr / Prowlarr → `/config/config.xml` (`<ApiKey>`)
- Bazarr → `/config/config.yaml` (`auth.apikey`)

They also cache **each other's** keys and URLs inside their SQLite databases (Prowlarr `Applications`, Sonarr/Radarr `Indexers`). Kubernetes cannot inject these keys — the apps generate and keep them.

The repo also carries a SOPS-encrypted Secret `arr-stack-api-keys` (Git), consumed by:

- **Homepage** widgets (all five service keys plus the qBittorrent password).
- **Bazarr's liveness/readiness probe** — formerly an authenticated call to `/api/system/status`.

On 2026-09-11 the `clusters/homelab-2nd` → `clusters/production` rename triggered a Flux prune cascade (see ADR-012 and the outage postmortem) that deleted the arr-stack child Kustomizations and cascade-deleted **every arr-stack PVC**. Flux recreated the namespace; the app configs were restored from the MinIO config backup, but the SOPS secret was applied independently from Git. Result: **all four keys diverged** between the running apps and the secret.

Because only Bazarr used its key in a probe, only Bazarr broke — it answered `401`, the liveness probe failed 5×, and kubelet killed it every ~2.5 minutes (**220 restarts**, `CrashLoopBackOff`). Homepage's widgets were also silently broken. The outage postmortem had logged `arr-stack/bazarr CrashLoopBackOff` as an "unrelated oddity, ignored".

The apps are **LAN-only** (NodePort on the LAN, no public ingress). The repo is public, but all key material is SOPS/age-encrypted.

## Decision

1. **The running app config is the source of truth for arr-stack API keys.** The SOPS Secret **mirrors** them. After any restore/rebuild that repopulates the config from backup, re-sync the secret from the live apps (`scripts/arr-stack-sync-api-keys.sh`) before considering the stack healthy.
2. **Probes must never depend on an application API key.** Bazarr's `livenessProbe`/`readinessProbe` are now a plain `tcpSocket: 6767` check. Liveness tests that the process is up, not that app-level auth works.
3. **qBittorrent is the documented exception.** Its restored config had *no* persistent WebUI password (qBittorrent generates a per-session temporary one), so the secret is canonical for that credential: set the WebUI password to the secret value once via the qBittorrent API. The secret's `qbittorrent-password` is now the live password.
4. **Jellyfin's key is stable** and was left as-is (it is not rotated during rebuilds).

## Consequences

**Positive**

- A restore brings a self-consistent snapshot (keys *and* the cross-references in the SQLite DBs all come from the same backup), so no SQLite surgery is needed.
- Homepage widgets and health checks work against the restored snapshot.
- Key material stays encrypted in Git; nothing plaintext is committed.
- Bazarr can no longer be crashlooped by a stale key.

**Negative**

- The Git secret is **derived data**, not the ultimate source of truth. If a restore uses a snapshot older than the last sync, the keys drift again until re-synced — hence the mandatory post-restore sync step.
- Rotating a key now means: change it in the app first, then mirror it into the secret (and repair the partner apps' cross-references if that pair uses it).
- The Bazarr probe no longer proves the API is authenticating — only that the HTTP port is open. API health is covered by Homepage widgets and the service's own logs/Loki rules.

## Alternatives considered

- **Secret canonical; apps adopt it on startup.** Inject the key into `config.xml`/`config.yaml` with an initContainer/custom-init and repair the SQLite cross-references with a Job. Truly declarative and deterministic — but heavy (three storage locations per app pair) and it still requires the same repair after every restore. Rejected for now; kept as a future option.
- **Derive the secret at runtime (CronJob → non-Git Secret).** Kills drift permanently, but the secret would no longer be Git-sourced, bending the "GitOps is law" guardrail. Deferred.
- **Rotate every key on every rebuild and run a cross-reference repair script.** The 2026-09-08 post-migration repair already showed how error-prone this is (`config.xml` + `config.yaml` + SQLite). Rejected.
- **Keep the key-based probe and just fix the key.** Fixes today's symptom but leaves the same landmine: the next drift crashloops Bazarr again. Rejected — the probe was hardened instead.

## When to revisit

- If the stack adopts a real secrets manager / External Secrets Operator with **app-side key adoption** → the secret can become truly canonical.
- If the manual post-restore sync proves fragile in practice → implement the runtime derived-secret CronJob (alternative 2).
- If arr-stack is ever exposed beyond the LAN → revisit key rotation cadence and probe design together.
