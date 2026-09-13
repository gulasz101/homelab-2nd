# arr-stack recovery runbook

How to bring the `arr-stack` namespace back after a rebuild/restore, and the
one extra step that is easy to miss: **re-syncing the API-keys secret**.

- Namespace: `arr-stack` (pinned to `arr-box`).
- App config (including API keys) lives on `local-path` PVCs, backed up daily to
  MinIO by the `arr-stack-config-backup` CronJob under `configs/<service>/`.
- Live databases are SQLite on those same PVCs.
- Key ownership decision and rationale: `docs/adr/adr-014-arr-stack-api-keys-owned-by-apps.md`.

## After restoring app config from backup

The restored configs carry the API keys of the **snapshot**, which are not
necessarily the keys currently in Git (`arr-stack-api-keys.sops.yaml`). They
must be re-synced, or Homepage widgets break — and, pre-ADR-014, Bazarr
CrashLoopBackOff'd because its health probe used the key.

1. **Restore each service's config** from the MinIO `configs/<service>/` backup
   into its PVC (or let the app come up and restore manually).

2. **Re-sync the secret from the live apps** (never prints key values):

   ```bash
   ./scripts/arr-stack-sync-api-keys.sh --dry-run   # preview
   ./scripts/arr-stack-sync-api-keys.sh             # writes the SOPS file
   git -C "$(pwd)" add apps/arr-stack/arr-stack-api-keys.sops.yaml
   git commit -m "fix(arr-stack): re-sync api keys after restore"
   git push
   ```

3. **Reconcile Flux** (or wait for the poll):

   ```bash
   kubectl -n flux-system annotate gitrepository flux-system \
     reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
   kubectl -n flux-system annotate kustomization apps \
     reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
   ```

4. **Restart Homepage** so it reloads the secret (env vars are read at start):

   ```bash
   kubectl -n arr-stack rollout restart deploy/homepage
   ```

5. **qBittorrent** (only if its config was restored empty): it has no persistent
   WebUI password, so set it to the secret value via its API. See ADR-014.

## Verify

```bash
kubectl get pods -n arr-stack
# every pod 1/1; bazarr must not be CrashLoopBackOff

kubectl -n arr-stack get pod -l app.kubernetes.io/name=bazarr \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount'

# from the Homepage pod, confirm each widget's credential works
POD=$(kubectl get pod -n arr-stack -l app.kubernetes.io/name=homepage -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n arr-stack "$POD" -- node -e '
  const s=process.env; const h=k=>k;
  fetch("http://sonarr-nodeport:8989/api/v3/system/status",{headers:{"X-Api-Key":s.HOMEPAGE_VAR_SONARR_API_KEY}}).then(r=>console.log("sonarr",r.status));
  fetch("http://radarr-nodeport:7878/api/v3/system/status",{headers:{"X-Api-Key":s.HOMEPAGE_VAR_RADARR_API_KEY}}).then(r=>console.log("radarr",r.status));
  fetch("http://prowlarr-nodeport:9696/api/v1/system/status",{headers:{"X-Api-Key":s.HOMEPAGE_VAR_PROWLARR_API_KEY}}).then(r=>console.log("prowlarr",r.status));
  fetch("http://bazarr-nodeport:6767/api/system/status",{headers:{"X-API-KEY":s.HOMEPAGE_VAR_BAZARR_API_KEY}}).then(r=>console.log("bazarr",r.status));
  fetch("http://jellyfin-nodeport:8096/System/Info",{headers:{"X-Emby-Token":s.HOMEPAGE_VAR_JELLYFIN_API_KEY}}).then(r=>console.log("jellyfin",r.status));
'
```

**Hard rule:** qBittorrent must always egress via the Mullvad exit (currently
Spain). After any arr-stack restart, confirm:

```bash
kubectl exec -n arr-stack deploy/gluetun -c qbittorrent -- python3 -c \
  "import urllib.request,json;print(json.loads(urllib.request.urlopen('https://am.i.mullvad.net/json').read())['country'])"
# -> Spain
```
