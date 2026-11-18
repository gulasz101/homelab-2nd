# The LiteLLM Admin UI is SSO-only, and the master key is not a UI password

- **Status**: Pending
- **Date**: 2026-11-18
- **Related**: ADR-029 (OpenCode Go session normalizer), ADR-068 (cross-account fallback)

## Context

The LiteLLM Admin UI on `https://llm.voitech.dev` had a working local login that nobody
configured. `general_settings` carried no `UI_USERNAME`/`UI_PASSWORD`, and the HelmRelease
comment read "combined with no UI_USERNAME/UI_PASSWORD this hides the local login form,
leaving only the SSO button". That is wrong. `get_ui_credentials()`
(`litellm/proxy/auth/login_utils.py`) falls back to the **master key** as the UI password for the
username `admin` when `UI_PASSWORD` is unset — so `admin` + master key authenticated as a proxy
admin. LiteLLM's own Admin UI banner reported it: "Environment-credential login is enabled".

Authentik SSO (generic OIDC, `AUTO_REDIRECT_UI_LOGIN_TO_SSO=true`, `ui_access_mode: admin_only`)
was already the intended path, and the only human user, `akadmin`, is a `proxy_admin` bound by
`sso_user_id` with no password. `default_user_id` is the password-less row the env-credential
login created.

## Decision

1. **`general_settings.disable_env_credential_login: true`.** The `UI_USERNAME`/`UI_PASSWORD` /
   master-key fallback login is off unconditionally. This is the flag that actually closes the
   shared static secret; a UI password only ever comes from a DB user's own password.
2. **`general_settings.disable_password_login_when_sso_enabled: true`.** SSO-only, as the house
   rule for Authentik-fronted services. It is conditional on a complete SSO setup, which is why
   it does not replace point 1 — together, a half-configured SSO provider cannot quietly reopen
   the env-credential path.
3. **No break-glass UI password user.** The UI's only human login is Authentik. Lockout recovery
   is: the master key still administers the proxy over the API (that path never calls
   `authenticate_user`), and removing the flag + letting Flux roll the pod restores the form —
   a reviewable change in Git, not a shared credential on a sticky note.
4. `apps/llm-hub/tests/auth-config-check.sh` asserts both flags, the absence of a
   `UI_USERNAME`/`UI_PASSWORD` env credential, and the SSO auto-redirect, so the line cannot be
   dropped silently.

## Consequences

- Verified live 2026-11-18: `/sso/key/generate` answers `303` to `auth.voitech.dev`, and
  `authenticate_user` is called only from the password login routes
  (`proxy_server.py` ~17635/17728/17800), never from the SSO flow — so SSO cannot be locked out
  by these flags.
- If Authentik or its OIDC client breaks, the Admin UI is unreachable until either SSO is fixed
  or the flag is reverted in Git. LLM traffic is unaffected: virtual keys, the key provisioner and
  the router never authenticate through the UI.
- `default_user_id` stays in `LiteLLM_UserTable` as an unreachable, password-less `proxy_admin`.

## Alternatives

- **Create a proxy admin with its own password first, then disable the flag** (the vendor's
  recipe). Rejected here: it re-adds a password login path to a service whose documented posture
  is SSO-only, and the lockout it guards against is already covered by SSO plus API access.
- **`DISABLE_ADMIN_UI=True`.** Rejected: the UI is the spend/key console, and disabling it is a
  bigger change than closing the login path.
- **Keep the master key as the UI password and rotate it.** Rejected: the finding is the shared
  static secret itself, not its value.

## When to revisit

- A second human needs the UI (then they get an Authentik account, not a LiteLLM password).
- LiteLLM changes `get_ui_credentials()`'s fallback or the flag's semantics.
- The SSO provider is replaced, or `disable_password_login_when_sso_enabled` starts refusing a
  login that has to work.
