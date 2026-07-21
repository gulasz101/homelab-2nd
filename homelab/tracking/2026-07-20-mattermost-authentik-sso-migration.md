# 2026-07-20/21: Mattermost + Authentik SSO Migration — Execution & Blockers

Date: 2026-07-20 through 2026-07-21
Topic: mattermost + authentik + cnpg + gitops
Status: **IN PROGRESS — Authentik claim mapping fixed, awaiting final login verification for akadmin and sylwia**

## Summary

Migrated the existing self-hosted Mattermost Team Edition instance at `https://chat.voitech.dev` onto the central Authentik IdP using the GitLab-OAuth shim approach. The migration followed the approved plan and stayed GitOps-driven, but hit two major blockers on the way:

1. Mattermost CNPG backups were silently broken (the `minimal` PG image lacked `barman-cloud-check-wal-archive`). This was fixed by migrating the cluster to the Barman Cloud CNPG-I plugin before proceeding.
2. After the OAuth handshake reached Authentik, login failed with `Could not parse auth data out of gitlab user object.` because Authentik's userinfo endpoint emits OIDC claims (`sub`, `preferred_username`) while Mattermost's GitLab shim expects legacy GitLab claims (`id`, `username`, `email`, `name`). This was fixed by adding a custom Authentik scope mapping.

The final end-to-end login test for `akadmin` and `sylwia` is the remaining step.

## Approved plan and deviations

The original plan was approved in `homelab/tracking/2026-07-20-mattermost-authentik-sso-migration-plan.md`.

- ✅ Use GitLab-OAuth shim with Authentik as the IdP.
- ✅ Use native Authentik OAuth2 endpoints first.
- ✅ Keep local `admin` break-glass.
- ✅ Confirm Sylwia exists in `homelab-users`.
- ✅ Stay on `chat.voitech.dev`.
- ⚠️ Backup-before-SSO phase expanded: the pre-SSO on-demand backup revealed CNPG WAL archiving was failing, so backups were fixed before SSO work continued (with explicit Supreme Leader approval).

## Phase 1: Backup + unexpected CNPG backup fix

### 1.1 Pre-SSO on-demand backup manifest

Created a GitOps-tracked on-demand backup:

```bash
cat > /Users/wojciechgula/Projects/homelab-2nd/apps/mattermost/mattermost-on-demand-backup.yaml <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: mattermost-pre-sso-backup
  namespace: mattermost
spec:
  cluster:
    name: mattermost-db
EOF
```

Added it to `apps/kustomization.yaml`, committed, and reconciled Flux.

### 1.2 Discovered: backups were already broken

After the backup manifest reconciled, the CNPG cluster reported `walArchivingFailing`. The `mattermost-db` cluster was running `ghcr.io/cloudnative-pg/postgresql:16-minimal-trixie`, which does **not** include `barman-cloud-check-wal-archive`. All scheduled backups had been failing silently.

Decision (approved): keep PostgreSQL 16 and switch to the Barman Cloud CNPG-I plugin instead of the deprecated native `spec.backup.barmanObjectStore`.

Files changed:
- `apps/mattermost/objectstore.yaml` — new ObjectStore pointing at `s3://cnpg-backups/mattermost/`.
- `apps/mattermost/postgres-cluster.yaml` — removed `spec.backup.barmanObjectStore`, added `spec.plugins` with `barman-cloud.cloudnative-pg.io`.
- `apps/mattermost/scheduled-backup.yaml` — changed `method: barmanObjectStore` → `method: plugin`.
- `apps/mattermost/mattermost-on-demand-backup.yaml` — changed to `method: plugin`.
- `apps/kustomization.yaml` — added `objectstore.yaml`.

After reconcile and a rolling pod restart, `ContinuousArchiving=True` and WALs started uploading to OMV MinIO. The base backup had to catch up a backlog of ~7,693 WAL files.

## Phase 2: Authentik provider + application

### 2.1 Generated credentials

Used Python to generate the OAuth2 client credentials so they could be committed in SOPS:

```bash
python3 -c "import secrets; print('client_id:', secrets.token_urlsafe(32)); print('client_secret:', secrets.token_urlsafe(48))"
```

### 2.2 SOPS secret for Mattermost

Created `apps/mattermost/mattermost-oidc-client.sops.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mattermost-oidc-client
  namespace: mattermost
type: Opaque
stringData:
  client_id: "<generated>"
  client_secret: "<generated>"
  gitlab_site_url: "https://auth.voitech.dev/application/o/mattermost"
```

Encrypted with `SOPS_AGE_KEY_FILE=~/.keys/age-homelab-2nd.txt sops --encrypt --in-place` and added to `apps/kustomization.yaml`.

### 2.3 Updated Authentik blueprint

Decrypted `infrastructure/auth/authentik-blueprint-secret.sops.yaml`, added:

- OAuth2 provider `Mattermost GitLab OAuth`.
- Application `mattermost` bound to that provider.
- Redirect URIs:
  - `https://chat.voitech.dev/signup/gitlab/complete`
  - `https://chat.voitech.dev/login/gitlab/complete`
- `grant_types: [authorization_code, refresh_token]`
- `sub_mode: hashed_user_id` (later changed to `user_id` during debugging)
- `invalidation_flow: !Find [authentik_flows.flow, [slug, default-invalidation-flow]]`
- `signing_key: !Find [authentik_crypto.certificatekeypair, [name, homelab-signing]]`
- `property_mappings`: `openid`, `profile`, `email`, `homelab-role`.

Re-encrypted and committed.

### 2.4 Endpoint discovery: Authentik 2026.5.4 root-level OAuth2 URLs

Direct testing showed the per-application slug paths return **404** in this Authentik version:

- `https://auth.voitech.dev/application/o/mattermost/authorize/` → 404
- `https://auth.voitech.dev/application/o/mattermost/token/` → 404
- `https://auth.voitech.dev/application/o/mattermost/userinfo/` → 404

Working endpoints are root-level:

- `https://auth.voitech.dev/application/o/authorize/`
- `https://auth.voitech.dev/application/o/token/`
- `https://auth.voitech.dev/application/o/userinfo/`

The slug path still serves metadata (`/.well-known/openid-configuration`), so `IdEndpoint` remains `https://auth.voitech.dev/application/o/mattermost/`.

This finding was recorded in `references/mattermost-authentik-gitlab-oauth-live-endpoints-2026-07-20.md`.

## Phase 3: Mattermost config via GitOps mmctl Job

### 3.1 Job design

The Mattermost Team Edition image is distroless (no shell, no `cp`, no `curl`), so the Job runs in a `debian:bookworm-slim` sidecar and downloads the matching `mmctl` binary from `releases.mattermost.com`. The download needs a browser `User-Agent` header or it returns 403.

File: `apps/mattermost/mattermost-gitlab-sso-job.yaml` (final version `v6`).

Key settings applied by `mmctl`:

```bash
mmctl config set GitLabSettings.Enable true
mmctl config set GitLabSettings.Id "$MATTERMOST_OAUTH_CLIENT_ID"
mmctl config set GitLabSettings.Secret "$MATTERMOST_OAUTH_CLIENT_SECRET"
mmctl config set GitLabSettings.AuthEndpoint "https://auth.voitech.dev/application/o/authorize/"
mmctl config set GitLabSettings.TokenEndpoint "https://auth.voitech.dev/application/o/token/"
mmctl config set GitLabSettings.UserAPIEndpoint "https://auth.voitech.dev/application/o/userinfo/"
mmctl config set GitLabSettings.IdEndpoint "https://auth.voitech.dev/application/o/mattermost/"
mmctl config set EmailSettings.EnableSignUpWithEmail false
mmctl config set EmailSettings.EnableSignInWithEmail false
```

### 3.2 Iterations

- v1: tried to run `/bin/sh` inside the Mattermost image — failed (distroless).
- v2: copied `mmctl` via init container — failed (no `/bin/cp`, no shell).
- v3/v4: downloaded `mmctl` with wrong tarball URL and `alpine` image — failed (`mmctl` is glibc-linked).
- v5: used `debian:bookworm-slim`, correct URL, User-Agent, internal Service URL.
- v6: corrected endpoints to root-level Authentik URLs.

The Job was renamed each time because Kubernetes Job templates are immutable.

### 3.3 Username sign-in disabled

After email sign-in was disabled, the public `/login` page showed:

> "This server doesn't have any sign-in methods enabled"

Mattermost Team Edition does **not** render a GitLab SSO button on `/login`. The SSO entry point is the direct URL `https://chat.voitech.dev/oauth/gitlab/login`.

Also disabled username sign-in:

```bash
mmctl --local config set EmailSettings.EnableSignInWithUsername false
```

## Phase 4: First login attempt and failure

### 4.1 Symptom

The Supreme Leader opened `https://chat.voitech.dev/oauth/gitlab/login` in an incognito window, authenticated to Authentik as `akadmin`, and was redirected back to Mattermost, which showed:

```
Error
--------
Could not parse auth data out of gitlab user object.
```

URL: `https://chat.voitech.dev/error?message=Could+not+parse+auth+data+out+of+gitlab+user+object.&s=...`

### 4.2 Root cause

Mattermost's GitLab OAuth shim unmarshals the userinfo response into a `GitLabUser` struct that requires:

- `id` (int64)
- `username` (string)
- `email` (string)
- optional `name` / `login`

Authentik's default `/application/o/userinfo/` response uses OIDC standard claims:

- `sub`
- `preferred_username`
- `email`
- `name`

Because `id` was missing, `GitLabUser.Id` stayed `0` and `IsValid()` failed with `user id can't be 0`.

## Phase 5: Claim-mapping fix

### 5.1 Official reference

The Authentik integration guide for Mattermost (https://integrations.goauthentik.io/chat-communication-collaboration/mattermost/) specifies creating a scope mapping named `mattermost-read-user` with scope name `read_user` and expression:

```python
username = request.user.username
return {
    "id": request.user.pk,
    "username": username,
    "login": username,
    "preferred_username": username,
    "email": request.user.email,
    "name": request.user.name or username,
}
```

### 5.2 What was changed live in Authentik

Because the existing blueprint uses `profile`/`email`/`openid` scopes, the simplest fix was to update the already-attached custom `ScopeMapping` named `Mattermost GitLab profile` (scope name `profile`) to return GitLab-shaped keys at the top level:

```python
username = request.user.username
return {"id": request.user.pk, "username": username, "login": username, "preferred_username": username, "email": request.user.email, "name": request.user.name or username}
```

Also changed the provider `sub_mode` from `hashed_user_id` to `user_id` so the `id` claim stays numeric.

Commands run via `ak shell` in `authentik-worker`:

```python
from authentik.providers.oauth2.models import ScopeMapping, OAuth2Provider
m = ScopeMapping.objects.get(name="Mattermost GitLab profile")
m.expression = """username = request.user.username
return {"id": request.user.pk, "username": username, "login": username, "preferred_username": username, "email": request.user.email, "name": request.user.name or username}"""
m.save()

p = OAuth2Provider.objects.get(name="Mattermost GitLab OAuth")
p.sub_mode = "user_id"
p.save()
```

### 5.3 GitOps follow-up still needed

The custom scope mapping and the `sub_mode: user_id` change must be reflected back into the SOPS-encrypted Authentik blueprint (`infrastructure/auth/authentik-blueprint-secret.sops.yaml`) so the configuration survives a reinstall/restore. That edit has **not** been committed yet — it is the first task for the next session.

## Current state

- `https://chat.voitech.dev` → public `/login` shows no sign-in methods (expected with email/username disabled and no GitLab button rendered).
- `https://chat.voitech.dev/oauth/gitlab/login` → redirects to Authentik and back.
- Authentik provider `Mattermost GitLab OAuth` now emits GitLab-shaped userinfo claims.
- Mattermost config (via `mmctl --local config get GitLabSettings`) shows `Enable: true` and the root-level Authentik endpoints.
- Pending: actual successful login for `akadmin` and `sylwia`.

## Verification commands

```bash
# Mattermost health
curl -sS -o /dev/null -w '%{http_code}\n' https://chat.voitech.dev/api/v4/system/ping

# Live Mattermost GitLab config
ssh homelab-2nd "sudo kubectl exec -n mattermost deployment/mattermost-mattermost-team-edition -- mmctl --local config get GitLabSettings"

# Authentik provider/userinfo state
ssh homelab-2nd "sudo kubectl exec -n auth deployment/authentik-worker -- ak shell -c 'from authentik.providers.oauth2.models import OAuth2Provider, ScopeMapping; p=OAuth2Provider.objects.get(name=\"Mattermost GitLab OAuth\"); print(p.sub_mode); print([(m.name, getattr(m,\"scope_name\",\"-\")) for m in p.property_mappings.all()])'"
```

## Files changed so far

- `apps/mattermost/objectstore.yaml`
- `apps/mattermost/postgres-cluster.yaml`
- `apps/mattermost/scheduled-backup.yaml`
- `apps/mattermost/mattermost-on-demand-backup.yaml`
- `apps/mattermost/mattermost-oidc-client.sops.yaml`
- `apps/mattermost/mattermost-gitlab-sso-job.yaml`
- `apps/kustomization.yaml`
- `infrastructure/auth/authentik-blueprint-secret.sops.yaml`
- `references/mattermost-authentik-gitlab-oauth-live-endpoints-2026-07-20.md` (new reference note)
- `homelab/tracking/2026-07-20-mattermost-authentik-sso-migration.md` (this note)

## Next steps

1. Verify login for `akadmin` and `sylwia` via `https://chat.voitech.dev/oauth/gitlab/login`.
2. If login succeeds, commit the updated scope mapping and `sub_mode: user_id` into the Authentik blueprint.
3. Clean up the mmctl Job from the cluster/repo if desired.
4. Write final summary and post to Mattermost.

## References

- `references/mattermost-authentik-gitlab-oauth-workaround.md`
- `references/mattermost-authentik-gitlab-oauth-live-endpoints-2026-07-20.md`
- `references/mattermost-mmctl-job-recipe.md`
- `references/authentik-blueprint-gitops-recipe.md`
- `references/mattermost-cnpg-backup-barman-cloud-migration.md`
- https://integrations.goauthentik.io/chat-communication-collaboration/mattermost/
- https://docs.mattermost.com/administration-guide/onboard/sso-gitlab.html
