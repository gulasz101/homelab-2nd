# 2026-07-20: Mattermost + Authentik SSO Migration Plan

Date: 2026-07-20
Topic: mattermost + authentik
Status: **PLAN APPROVED — awaiting Supreme Leader "execute" command**

## Approved decisions

| # | Decision |
|---|----------|
| 1 | Use the GitLab-OAuth shim approach with Authentik as the IdP. |
| 2 | Use **native Authentik OAuth2 endpoints** first. A reverse-proxy shim (Option B) is the fallback only if native fails. |
| 3 | Keep the existing local `admin` account as break-glass after hiding the public login form. |
| 4 | Confirm/create Sylwia in `homelab-users` **before** the migration so we can test her login immediately. |
| 5 | Stay on public hostname `https://chat.voitech.dev`; no subdomain change. |

**Non-negotiable constraint from Supreme Leader:** every change must be GitOps-driven and traceable in the `gulasz101/homelab-2nd` repo. No hand-applied `kubectl apply` or `mmctl` commands unless it's genuine break-glass, and even then it must be documented in this note.

## Context

Mattermost currently runs on Team Edition at `https://chat.voitech.dev`, backed by CloudNativePG in the `mattermost` namespace and OMV MinIO for file storage. Authentication is local username/password only. The Supreme Leader wants to move it onto the central Authentik IdP so both he and Sylwia can log in via SSO, following the same GitOps/SOPS/Cloudflare Tunnel pattern as Grafana, Open WebUI, and Nextcloud.

The wrinkle: Mattermost Team Edition does **not** expose a generic OpenID Connect provider UI. OIDC/SAML SSO are Enterprise/Professional features. The free self-hosted edition still supports OAuth2-style flows, including the legacy **GitLab SSO** integration. The community workaround is to make Authentik look like a GitLab OAuth provider to Mattermost, using Authentik's OAuth2/OpenID provider and (optionally) small reverse-proxy rewrites for the GitLab-compatible endpoints.

## Goal

- Users authenticate to `chat.voitech.dev` via Authentik (`auth.voitech.dev`).
- Existing local admin account remains available as break-glass, but the public login page defaults to SSO.
- Sylwia gets a normal Authentik user in `homelab-users` and can use Mattermost.
- All changes are GitOps-declared, SOPS-encrypted, and tracked.

## Constraints & non-negotiables

- **Public repo** → no plaintext credentials. Client ID/secret, tunnel tokens, admin passwords stay in SOPS-encrypted `*.sops.yaml` secrets.
- **CloudNativePG** for Postgres already exists; no DB changes needed.
- **Cloudflare Tunnel** ingress already exists for `chat.voitech.dev`; no new public network surface.
- **GitOps-first:** Authentik provider/application is declared via the existing blueprint; Mattermost config changes go through a GitOps Job.
- **Traceability:** every manifest change is committed to `main` and reconciled by Flux. Any runtime command used for verification only, never for persistent configuration.

## Research findings

1. **Mattermost docs confirm** OIDC/SAML are Enterprise-only. Team Edition supports OAuth2/GitLab SSO with `read_user` scope.  
   Source: https://docs.mattermost.com/administration-guide/onboard/convert-oauth20-service-providers-to-openidconnect.html

2. **Community workaround** — Authentik as fake GitLab IdP:  
   - https://ayedo.de/en/posts/mattermost-self-hosted-sso-mit-authentik/  
   - https://subinsong.com/blog/2025/configuring-gitlab-oauth-for-mattermost-with-authentik/  
   - https://blog.proxeuse.com/how-to-use-mattermost-oauth2-for-free-with-authentik/  
   These show the authentik Application + OAuth2/OpenID provider setup, redirect URIs for Mattermost's `/signup/gitlab/complete` and `/login/gitlab/complete` endpoints, and (in the Subin Song guide) Caddy reverse-proxy rewrites to adapt GitHub-compatible endpoints to GitLab-compatible ones.

3. **Mattermost GitLab SSO config fields**:  
   `System Console → Authentication → GitLab`: Application ID, Application Secret Key, GitLab Site URL.

## Decision: GitLab-OAuth shim via Authentik

Add a new OAuth2 provider to Authentik named **"Mattermost GitLab OAuth"** and bind it to a new Authentik application **"mattermost"**. Mattermost will be configured to use GitLab SSO, pointing at Authentik's OAuth2 endpoints as if Authentik were GitLab.

### Why this approach

- Keeps Team Edition free.
- Reuses the existing Authentik blueprint + SOPS secret pattern.
- No new ingress or tunnel needed.
- Follows the documented community workaround.

### Risks / trade-offs

- It's a workaround, not a first-class OIDC integration. Some OIDC niceties (e.g., proper logout flow, advanced claim mapping) may be limited.
- Mattermost expects GitLab OAuth semantics; we must ensure Authentik exposes endpoints that Mattermost can consume.
- If we want "true" OIDC later, we'll need Mattermost Professional/Enterprise or a license — a future decision, not today's.

## Implementation plan (GitOps-only)

### Phase 1: Preparation (all read-only / verification)

1. **Back up Mattermost CNPG database** via an on-demand `Backup` manifest. The backup itself is a GitOps-tracked manifest:
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
   Add it to `apps/kustomization.yaml`, commit, push, reconcile. Verify:
   ```bash
   ssh homelab-2nd "sudo kubectl -n mattermost get backup mattermost-pre-sso-backup -o jsonpath='{.status.phase}'"
   ```
   Once completed, remove it from `kustomization.yaml` and delete the manifest to avoid clutter, or keep it for audit trail. **(Decision point for Supreme Leader: keep or delete after success?)**

2. **Verify public Mattermost health.**
   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' https://chat.voitech.dev/api/v4/system/ping
   ```
   Expected: `200`.

3. **Confirm Sylwia exists in Authentik and is in `homelab-users`.** Use `ak shell` through the worker pod:
   ```bash
   ssh homelab-2nd "sudo kubectl exec -n auth deployment/authentik-worker -- ak shell -c '
from authentik.core.models import User, Group
try:
    u = User.objects.get(username=\"sylwia\")
    print(\"exists\", u.email, \"superuser=\", u.is_superuser)
except User.DoesNotExist:
    print(\"MISSING\")
g, _ = Group.objects.get_or_create(name=\"homelab-users\")
print(\"homelab-users members:\", list(g.users.values_list(\"username\", flat=True)))
'"
   ```
   If Sylwia is missing, create her via `ak shell` and set her password from the existing SOPS secret `sylwia-authentik-password`. That creation is also documented in this note and committed via no files (runtime-only user creation), but the *configuration* of her group membership is part of the blueprint.

### Phase 2: Add Authentik provider + application (blueprint + SOPS secret)

1. **Generate client credentials** locally (do not let Authentik auto-generate):
   ```bash
   python3 -c "import secrets; print('client_id:', secrets.token_urlsafe(32)); print('client_secret:', secrets.token_urlsafe(48))"
   ```

2. **Create the SOPS-encrypted per-service secret** for Mattermost:
   ```bash
   cat > /tmp/mattermost-oidc-client.sops.yaml <<'EOF'
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
   EOF
   SOPS_AGE_KEY_FILE=~/.keys/age-homelab-2nd.txt sops --encrypt --in-place /tmp/mattermost-oidc-client.sops.yaml
   mv /tmp/mattermost-oidc-client.sops.yaml /Users/wojciechgula/Projects/homelab-2nd/apps/mattermost/mattermost-oidc-client.sops.yaml
   ```

3. **Add the new provider + application to the Authentik blueprint** (`infrastructure/auth/authentik-blueprint-secret.sops.yaml`). Decrypt, edit, re-encrypt.
   - Provider name: `Mattermost GitLab OAuth`
   - Application slug: `mattermost`
   - Application name: `Mattermost`
   - Redirect URIs:
     - `https://chat.voitech.dev/signup/gitlab/complete`
     - `https://chat.voitech.dev/login/gitlab/complete`
   - `grant_types: [authorization_code, refresh_token]`
   - `sub_mode: hashed_user_id`
   - Property mappings: `openid`, `profile`, `email`, plus shared `homelab-role`.
   - `invalidation_flow: !Find [authentik_flows.flow, [slug, default-invalidation-flow]]`
   - `signing_key: !Find [authentik_crypto.certificatekeypair, [name, homelab-signing]]`

4. **Wire the secret and blueprint into Flux**:
   - Add `mattermost/mattermost-oidc-client.sops.yaml` to `apps/kustomization.yaml`.
   - The updated blueprint is already listed in `infrastructure/kustomization.yaml`.

5. **Commit and push**, then reconcile:
   ```bash
   cd /Users/wojciechgula/Projects/homelab-2nd
   git add -A
   git commit -m "feat(auth): add Mattermost GitLab-OAuth provider via Authentik blueprint

   - Adds mattermost-oidc-client SOPS secret in mattermost namespace
   - Adds 'Mattermost GitLab OAuth' provider + application to authentik blueprint
   - Redirect URIs target chat.voitech.dev GitLab SSO callback paths"
   git push origin main

   ssh homelab-2nd "sudo kubectl annotate -n flux-system gitrepository flux-system reconcile.fluxcd.io/requestedAt=\"$(date -Iseconds)\" --overwrite"
   ssh homelab-2nd "sudo kubectl annotate -n flux-system kustomization infrastructure reconcile.fluxcd.io/requestedAt=\"$(date -Iseconds)\" --overwrite"
   ssh homelab-2nd "sudo kubectl annotate -n flux-system kustomization apps reconcile.fluxcd.io/requestedAt=\"$(date -Iseconds)\" --overwrite"
   ```

6. **Verify Authentik picked up the blueprint.**
   ```bash
   ssh homelab-2nd "sudo kubectl exec -n auth deployment/authentik-worker -- ak shell -c '
from authentik.providers.oauth2.models import OAuth2Provider
from authentik.core.models import Application
print(\"providers:\", [p.name for p in OAuth2Provider.objects.filter(name__contains=\"Mattermost\")])
print(\"apps:\", [a.slug for a in Application.objects.filter(slug=\"mattermost\")])
'"
   ```

### Phase 3: Configure Mattermost for GitLab SSO (GitOps Job)

Mattermost stores auth config in the database. Since the deployment already exists, we use a **GitOps-tracked Kubernetes Job** to apply the config via `mmctl`. The Job is idempotent: if the config already matches, `mmctl config set` is a no-op.

1. **Create `apps/mattermost/mattermost-gitlab-sso-job.yaml`**.
   - Use the official Mattermost image (`mattermost/mattermost-team-edition:<same tag as HelmRelease>`) so `mmctl` is available and versions match.
   - Load `MATTERMOST_OAUTH_CLIENT_ID` and `MATTERMOST_OAUTH_CLIENT_SECRET` from the `mattermost-oidc-client` secret.
   - Load `MATTERMOST_ADMIN_USERNAME` and `MATTERMOST_ADMIN_PASSWORD` from `mattermost-initial-admin-password` so `mmctl auth login` can run.
   - Run:
     ```bash
     mmctl auth login https://chat.voitech.dev --username "$MATTERMOST_ADMIN_USERNAME" --password "$MATTERMOST_ADMIN_PASSWORD"
     mmctl config set GitLabSettings.Enable true
     mmctl config set GitLabSettings.Id "$MATTERMOST_OAUTH_CLIENT_ID"
     mmctl config set GitLabSettings.Secret "$MATTERMOST_OAUTH_CLIENT_SECRET"
     mmctl config set GitLabSettings.AuthEndpoint "https://auth.voitech.dev/application/o/mattermost/authorize/"
     mmctl config set GitLabSettings.TokenEndpoint "https://auth.voitech.dev/application/o/mattermost/token/"
     mmctl config set GitLabSettings.UserAPIEndpoint "https://auth.voitech.dev/application/o/mattermost/userinfo/"
     mmctl config set GitLabSettings.IdEndpoint "https://auth.voitech.dev/application/o/mattermost/"
     mmctl config set EmailSettings.EnableSignUpWithEmail false
     mmctl config set EmailSettings.EnableSignInWithEmail false
     ```
   - Set `restartPolicy: OnFailure` and appropriate resource requests.
   - Add a note in the Job manifest: "Run once after the Authentik blueprint reconciles. Remove from kustomization after success if desired, or leave for drift detection."

2. **Add the Job to `apps/kustomization.yaml`.**

3. **Commit and push**, then reconcile and watch:
   ```bash
   git add -A
   git commit -m "feat(mattermost): configure GitLab SSO pointing at Authentik via Job

   Uses mmctl to set GitLabSettings.* to Authentik's OAuth2 endpoints.
   Disables email sign-up/sign-in so GitLab (Authentik) is the public path.
   Loads client credentials from mattermost-oidc-client SOPS secret."
   git push origin main

   ssh homelab-2nd "sudo kubectl annotate -n flux-system kustomization apps reconcile.fluxcd.io/requestedAt=\"$(date -Iseconds)\" --overwrite"
   ssh homelab-2nd "sudo kubectl wait -n mattermost --for=condition=complete job/mattermost-gitlab-sso-setup --timeout=180s"
   ssh homelab-2nd "sudo kubectl logs -n mattermost job/mattermost-gitlab-sso-setup"
   ```

4. **If `mmctl` proves unreliable inside the Job**, fall back to a SQL Job that updates the active `configurations` row directly. That Job is also GitOps-tracked. The fallback manifest will be created only if needed.

### Phase 4: Verify native Authentik endpoints work

1. Open `https://chat.voitech.dev` in an incognito window.
2. Click the "GitLab" sign-in button (or whatever Mattermost labels it).
3. Confirm redirect to `auth.voitech.dev/application/o/mattermost/authorize/...`.
4. Log in as Supreme Leader (`akadmin` or mapped user), approve consent if asked, return to Mattermost.
5. Check that the user exists in Mattermost with the correct email.
6. Repeat for Sylwia.

**If this fails**, we pivot to **Option B** (reverse-proxy shim). That also becomes a GitOps manifest: a small nginx/Caddy Deployment in the `mattermost` namespace that rewrites GitLab-shaped requests to Authentik endpoints, and the Mattermost Job is updated to point at the shim Service instead of Authentik directly.

### Phase 5: Hide public username/password login

After SSO is proven working for both users:

1. **Update the existing Job** (or create a second one) to disable the public login form:
   ```bash
   mmctl config set EmailSettings.EnableSignInWithEmail false
   mmctl config set EmailSettings.EnableSignUpWithEmail false
   # GitLabSettings.Enable is already true
   ```
   Mattermost Team Edition does not have a single "disable local login form" switch, but hiding email auth and presenting only GitLab effectively makes SSO the public path. The local `admin` account can still be used via direct `/api/v4` basic auth or a documented break-glass URL.

2. **Verify the login page** in incognito shows only the GitLab/SSO option.
3. **Verify break-glass** still works with local `admin` credentials via a non-SSO path.

### Phase 6: Observability and final checks

1. Confirm Mattermost pod is `1/1 Running` and HelmRelease Ready.
2. Confirm logs still appear in Grafana/Loki under the `mattermost` namespace.
3. Confirm `GET /api/v4/system/ping` returns 200.
4. Update this tracking note with the actual commands, outputs, and any surprises.

## Files expected to change

- `apps/mattermost/mattermost-oidc-client.sops.yaml` — new SOPS secret.
- `apps/mattermost/mattermost-gitlab-sso-job.yaml` — new GitOps Job.
- `apps/mattermost/mattermost-on-demand-backup.yaml` — new on-demand Backup manifest (temporary).
- `infrastructure/auth/authentik-blueprint-secret.sops.yaml` — add Mattermost provider + application.
- `apps/kustomization.yaml` — add new Mattermost secret + Job + backup manifest.
- `infrastructure/kustomization.yaml` — updated blueprint secret (already listed; content changes only).
- `homelab/tracking/2026-07-20-mattermost-authentik-sso-migration.md` — this note.

## Rollback plan

If SSO breaks Mattermost and we cannot recover quickly:

1. Revert the Job's config by committing a follow-up Job that sets:
   ```bash
   mmctl config set GitLabSettings.Enable false
   mmctl config set EmailSettings.EnableSignInWithEmail true
   mmctl config set EmailSettings.EnableSignUpWithEmail true
   ```
   (Or use a SQL update if `mmctl` is unavailable.)
2. Reconcile Flux.
3. Remove the Mattermost provider/application from the blueprint and reconcile again.
4. Verify local login works and `chat.voitech.dev` is accessible.

## References

- `references/mattermost-deployment.md`
- `references/authentik-sso-service-recipe.md`
- `references/authentik-blueprint-gitops-recipe.md`
- `references/authentik-sso-service-debugging-2026-07-16.md`
- https://docs.mattermost.com/administration-guide/onboard/sso-gitlab.html
- https://docs.mattermost.com/administration-guide/onboard/convert-oauth20-service-providers-to-openidconnect.html
- https://ayedo.de/en/posts/mattermost-self-hosted-sso-mit-authentik/
- https://subinsong.com/blog/2025/configuring-gitlab-oauth-for-mattermost-with-authentik/
- https://blog.proxeuse.com/how-to-use-mattermost-oauth2-for-free-with-authentik/
