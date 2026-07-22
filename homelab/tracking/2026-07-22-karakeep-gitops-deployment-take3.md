# 2026-07-22 Karakeep GitOps Deployment — Take 3

## Goal
Finish the Karakeep deployment on the homelab-2nd k3s cluster, fix the remaining SSO/secret/inference issues, and bring it to a working, observable, SSO-only state.

## Cluster Topology (non-negotiable)
- **homelab-2nd** — k3s + Flux + workloads; live SQLite DB PVC on `local-path` (NVMe).
- **openmediavault** — durable NAS; MinIO on OMV is the S3 backend for assets and backups.
- Public ingress only via Cloudflare Tunnel to `https://keep.voitech.dev`.

## State at the start of the session
- HelmRelease `karakeep` v0.32.0 reconciled.
- `karakeep-0` pod Running.
- `meilisearch-0` and `cloudflared` pods Running.
- Chrome sidecar disabled (CPU conservation on single-node 8-core cluster).
- `karakeep-minio-assets` secret fixed in the previous session (boolean → string).
- SSO reached the Authentik login screen but failed with `OAuthSignin` / `invalid_request`.

## Fixes applied

### 1. OIDC secret key names
The `karakeep-oidc-client` SOPS secret had keys `client_id` and `client_secret`, but NextAuth expects `OAUTH_CLIENT_ID` and `OAUTH_CLIENT_SECRET`. We already had `OAUTH_WELLKNOWN_URL` as a plain env var.

- Renamed secret keys in `apps/karakeep/karakeep-oidc-client.sops.yaml`.
- Committed, pushed, reconciled Flux.
- Restarted `karakeep-0`.

Result: the OAuth callback reached Authentik, but then failed with:

```
OAuth login failed: Signups are disabled in server config
```

### 2. Allow OAuth-only signups
`DISABLE_SIGNUPS` was `"true"`. Because this was the first login for `akadmin`, Karakeep refused to create the account. Local/password auth was already disabled (`DISABLE_PASSWORD_AUTH=true`), so signups can only happen via OAuth.

- Changed `DISABLE_SIGNUPS: "false"` in `apps/karakeep/karakeep-helm-release.yaml`.
- Committed, pushed, reconciled.

Result: user logged in successfully.

### 3. Meilisearch OOM
`karakeep-meilisearch-0` was in `CrashLoopBackOff` with exit code 137 / `OOMKilled`. The Helm chart defaults requested only 64Mi and limited to 256Mi.

- Bumped Meilisearch resources to `requests: 512Mi`, `limits: 2Gi`.
- Committed, pushed, reconciled.

Result: Meilisearch stable at ~33Mi idle (headroom for indexing).

### 4. Missing chrome controller causing Helm failures
Disabling `chrome.enabled: false` at the top level left chart default `persistence.chrome-tmp` referencing a non-existent `chrome` controller. Helm upgrades failed with:

```
No enabled controller found with this identifier. (persistence item: 'chrome-tmp', controller: 'chrome')
```

- Removed the chart default persistence by setting `persistence: {}`.
- Added an explicit `chrome: enabled: false` controller block inside `controllers`.
- Committed, pushed, reconciled.

Result: Helm upgrades succeed; no chrome deployment is created.

### 5. Crawler stuck trying to reach missing Chrome
Even with chrome disabled, the chart injected `BROWSER_WEB_URL=http://karakeep-chrome:9222`. The crawler kept retrying to connect to the missing chrome service (`ECONNREFUSED 10.43.50.248:9222`), so bookmarks were not being fully crawled and inference had no clean text to tag.

- Set `BROWSER_WEB_URL: ""` in the HelmRelease env block.
- Per Karakeep docs, an empty browser URL makes the crawler fall back to plain HTTP requests (no JS, no screenshots).
- Committed, pushed, reconciled.

Result: crawler starts without browser errors; inference worker can process text.

### 6. AI summary confirmed working
After the above fixes, the Supreme Leader confirmed that AI summaries appeared for submitted articles.

### 7. AI auto-tagging still under verification
Tagging depends on the same inference path as summarization, but may require a successful plain-HTTP crawl first. After the `BROWSER_WEB_URL` fix, new bookmarks should be crawled and tagged. This needs a fresh bookmark test to confirm.

## Files changed
- `apps/karakeep/karakeep-helm-release.yaml`
- `apps/karakeep/karakeep-oidc-client.sops.yaml`

## Secrets
- No plaintext credentials exposed in chat or repo.
- OIDC secret keys renamed and re-encrypted with SOPS/age.

## Break-glass actions
- Direct `kubectl set env statefulset karakeep DISABLE_SIGNUPS=false` was used once before the GitOps commit landed, then immediately superseded by Flux reconciliation. Documented as temporary unblocking only.
- Direct `kubectl delete deployment karakeep-chrome` used to remove the deployment recreated by the Helm chart during intermediate upgrades.

## Verification commands
```bash
ssh -i ~/.ssh/id_ed25519.homelab-2nd gulasz101@homelab-2nd \
  "sudo KUBECONFIG=/root/.kube/config kubectl get pods -n karakeep"

ssh -i ~/.ssh/id_ed25519.homelab-2nd gulasz101@homelab-2nd \
  "sudo KUBECONFIG=/root/.kube/config kubectl get helmrelease karakeep -n karakeep"
```

## Known remaining work
1. Submit a fresh bookmark and confirm AI auto-tags appear.
2. Check S3 asset upload in the `karakeep-assets` MinIO bucket.
3. Confirm Prometheus is scraping `/api/metrics` and Loki has Karakeep logs.
4. Write the corresponding Obsidian vault tracking note at `~/wojtek.second.brain.obsidian.vault/homelab/tracking/2026-07-22-karakeep-gitops-deployment-take3.md`.

## Lessons
- Chart defaults matter: `persistence.chrome-tmp` and `BROWSER_WEB_URL` defaults assume the chrome sidecar is enabled. When you disable it, you must explicitly null/override those defaults.
- `envFrom` with `secretKeyRef` is not what the official chart expects for `applicationSecretKey`/`meilisearchMasterKey`; it treats them as raw string defaults for generated secrets. Use `envFrom` with keys named exactly like the env vars Karakeep reads.
- Meilisearch needs more memory than the chart default 256Mi limit even for a small personal instance.
- `DISABLE_SIGNUPS` must be `false` for the first OIDC login, but `DISABLE_PASSWORD_AUTH=true` keeps local signup disabled.
