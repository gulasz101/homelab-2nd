# 2026-07-29 — Mattermost native app login fix

## Problem

After the 2026-07-20 Authentik GitLab-OAuth shim migration, the Mattermost desktop/mobile app (Flatpak on Asahi Linux, and others) showed:

> "The server doesn't have any sign-in methods enabled"

The same happened when clicking the Mattermost tile in the Authentik dashboard: it landed on `https://chat.voitech.dev/login`, which also showed no sign-in methods.

Browser SSO via the direct URL `https://chat.voitech.dev/oauth/gitlab/login` still worked.

## Root cause

Mattermost **Team Edition** supports GitLab OAuth as the only free SSO path, but it does **not** expose that OAuth button to unauthenticated clients. The `/api/v4/config/client` payload only advertises GitLab sign-in when the enterprise `license.Features.OpenId` flag is present.

On 2026-07-20 we disabled email/username sign-in to enforce the "no local fallbacks" rule. That left the native app with zero discoverable sign-in methods.

## Decision

Override the 2026-07-15 "no fallbacks" rule **for Mattermost only**. Native/desktop apps need a login form, so keep email/username sign-in enabled. Browser SSO remains available via the direct `/oauth/gitlab/login` URL and the Authentik tile.

Conversation data is preserved because the existing `akadmin` user row in Mattermost is retained; we only adjusted how it authenticates.

## Changes made

### GitOps

1. **`apps/mattermost/mattermost-helm-release.yaml`**
   - Re-enabled `EmailSettings.EnableSignInWithEmail: true`.
   - Added `EmailSettings.EnableSignInWithUsername: true`.
   - Kept `EmailSettings.EnableSignUpWithEmail: false` (invite-only).
   - Removed the no-op `MM_SERVICESETTINGS_ENABLESIGNINWITHEMAIL` / `ENABLESIGNINWITHUSERNAME` env vars (they pointed at a non-existent config section).

- **`infrastructure/auth/authentik-admin-password.sops.yaml`**
  - Source of truth for the shared `akadmin` password.
  - Updated to match the new Mattermost password and removed the stale `password_hash` field.

3. **`infrastructure/auth/authentik-blueprint-secret.sops.yaml`**
   - Mattermost application `meta_launch_url` changed from `https://chat.voitech.dev` to `https://chat.voitech.dev/oauth/gitlab/login` so the Authentik tile initiates SSO directly, instead of landing on the empty `/login` page.

4. **`apps/kustomization.yaml`**
   - Commented out `mattermost/mattermost-gitlab-sso-job.yaml`. The Job is kept in the repo as a rebuild recipe, but it is no longer reconciled continuously because it would re-disable email/username sign-in.

### Runtime / break-glass

5. **Synced `akadmin` password across Authentik and Mattermost**
   - Source of truth: `infrastructure/auth/authentik-admin-password.sops.yaml`.
   - The same value is mirrored in `apps/mattermost/mattermost-initial-admin-password.sops.yaml` for the Mattermost namespace break-glass Job.
   - Removed the stale `password_hash` field from `authentik-admin-password` — Authentik bootstraps the admin via `ak shell`, not Helm.
   - Set it on Authentik `akadmin` via `ak shell`:
     ```bash
     POD=$(sudo kubectl get pod -n auth -l app.kubernetes.io/component=worker -o jsonpath='{.items[0].metadata.name}')
     sudo kubectl cp /tmp/pass.txt auth/$POD:/tmp/pass.txt
     sudo kubectl exec -n auth $POD -- ak shell -c "
     from authentik.core.models import User
     import pathlib
     u = User.objects.get(username='akadmin')
     pw = pathlib.Path('/tmp/pass.txt').read_text().strip()
     u.set_password(pw)
     u.save()
     print(u.check_password(pw))
     "
     ```
   - Set it on Mattermost `akadmin` via `mmctl --local`:
     ```bash
     POD=$(sudo kubectl get pod -n mattermost -l app.kubernetes.io/name=mattermost-team-edition -o jsonpath='{.items[0].metadata.name}')
     sudo kubectl exec -n mattermost $POD -- mmctl --local user change-password akadmin --password "$PASS"
     ```

6. **Re-linked the Mattermost `akadmin` account to Authentik SSO**
   - Running `mmctl user change-password` cleared `authservice` and `authdata` on the user row, which would have broken GitLab SSO login.
   - Re-linked via direct SQL on the CNPG primary:
     ```sql
     UPDATE users
     SET authservice = 'gitlab',
         authdata = '7',
         emailverified = true
     WHERE username = 'akadmin';
     ```
   - `7` is the Authentik user primary key for `akadmin` (`request.user.pk`); this matches the `sub_mode: user_id` configuration on the Mattermost OAuth2 provider.

7. **Restarted Authentik** to re-apply the updated blueprint into the database.

## Verification

```bash
# Mattermost sign-in settings are enabled
kubectl exec -n mattermost <mattermost-pod> -- mmctl --local config get EmailSettings.EnableSignInWithEmail
# true
kubectl exec -n mattermost <mattermost-pod> -- mmctl --local config get EmailSettings.EnableSignInWithUsername
# true

# Admin user exists and is linked to Authentik
kubectl exec -n mattermost <mattermost-pod> -- mmctl --local user search akadmin
# id: szj35wcy7fr7mbmfsfwy5txe9e
# username: akadmin
# email: admin@voitech.dev
# roles: system_user system_admin

# DB linkage is intact
kubectl exec -n mattermost <db-pod> -c postgres -- psql -U postgres -d mattermost -c "SELECT username, authservice, authdata FROM users WHERE username='akadmin';"
# username | authservice | authdata
# ---------+-------------+----------
# akadmin  | gitlab      | 7

# Authentik blueprint contains the direct SSO launch URL
kubectl -n auth get secret authentik-blueprint-homelab-sso -o jsonpath='{.data.homelab-sso\.yaml}' | base64 -d | grep 'meta_launch_url' | tail -1
# meta_launch_url: https://chat.voitech.dev/oauth/gitlab/login

# No failed Jobs left in mattermost namespace
kubectl -n mattermost get jobs
# No resources found
```

## How to retrieve the current password

Source of truth:

```bash
cd ~/Projects/homelab-2nd
export SOPS_AGE_KEY_FILE=~/.keys/age-homelab-2nd.txt
sops -d infrastructure/auth/authentik-admin-password.sops.yaml
```

The same value is also mirrored in `apps/mattermost/mattermost-initial-admin-password.sops.yaml` for the Mattermost namespace break-glass Job. Both must be kept in sync.

Use username `akadmin` and the decrypted password for:
- Authentik web login at `https://auth.voitech.dev`
- Mattermost local login in desktop/mobile apps
- Mattermost web login at `https://chat.voitech.dev/login`

Browser SSO still works via `https://chat.voitech.dev/oauth/gitlab/login` or the Authentik tile.

## Lessons / gotchas

- **Mattermost Team Edition will never advertise GitLab OAuth to native apps.** The only way to make the desktop/mobile login form appear is to keep email/username sign-in enabled.
- **`mmctl user change-password` clears `authservice`/`authdata`.** After changing a local admin password, always re-check the `users` table and re-link the row to the Authentik identity if SSO is expected to keep working.
- **Keep the SOPS break-glass secret aligned with the live admin account.** The original secret had `username: wojtek`, but the actual admin account was `akadmin`; leaving it would have made break-glass recovery confusing.
- **Authentik application `meta_launch_url` should point at the actual SSO initiation URL for apps with no visible login button.** Otherwise the dashboard tile sends the user to a dead `/login` page.

## Commits

- `b618f75` — fix(mattermost): enable email/username sign-in for native apps, sync akadmin password
- `10ebc5e` — fix(authentik): point Mattermost tile to /oauth/gitlab/login
- `2cfcf11` — fix(mattermost): align SOPS admin password with live Authentik/Mattermost
