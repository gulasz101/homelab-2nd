# ADR-007: Central SSO with Authentik

Date: 2026-07-15
Status: Accepted (amended 2026-07-18)
Supersedes: nothing
Superseded by: nothing

> **Amendment 2026-07-18:** LiteLLM was originally excluded from SSO because its Admin UI SSO was believed to be Enterprise-only. That was outdated: since LiteLLM v1.76.0, SSO is **free for up to 5 users**. LiteLLM was migrated to Authentik OIDC on 2026-07-18 (tracking note: `homelab/tracking/2026-07-18-litellm-sso-migration-plan.md`). Only Mattermost remains on local auth. The original text below is preserved for history; every LiteLLM exclusion mentioned in it no longer applies.

## Context

The homelab has five user-facing services, each with its own local credential store:

| Service | Namespace | Authentication before this ADR |
|---|---|---|
| Grafana | `observability` | Local admin account from SOPS secret |
| Open WebUI | `llm-hub` | Local admin + wife account, user signup disabled |
| Mattermost | `mattermost` | Username/password only |
| Nextcloud | `nextcloud` | Local admin account only |
| LiteLLM | `llm-hub` | Master-key Admin UI |

This is annoying to manage, hard to audit, and means Sylwia has to remember different passwords for different services. We already run **Authentik** in `infrastructure/auth/` as the central identity provider, but until now it only serves `tldraw`. The question is: should we migrate the other services to SSO via Authentik, and if so, how?

## Decision

**Migrate Grafana, Open WebUI and Nextcloud to OIDC/OAuth2 SSO via Authentik. Leave Mattermost and LiteLLM on their existing local authentication because SSO requires an Enterprise licence in both products. Disable local login/fallbacks on the migrated services; break-glass is a Git revert + Flux reconcile.**

### Rationale

1. **Single source of identity.** Authentik already exists, is backed by a CNPG Postgres cluster with MinIO backups, and is exposed publicly via Cloudflare Tunnel. Reusing it avoids a second identity stack.
2. **OIDC/OAuth2 is the pragmatic protocol.** All three migratable services support it. SAML would add XML certificate overhead. LDAP would require an extra schema and directory server.
3. **SOPS + age for secrets.** Every OIDC client secret lives in a SOPS-encrypted `*.sops.yaml` file, decrypted in-cluster by Flux. The public repo never sees plaintext credentials.
4. **GitOps-first, UI only for IdP configuration.** The target applications' HelmReleases, secrets, and even the Nextcloud `user_oidc` provider registration are stored in the repo. Authentik providers/applications are configured once in the Authentik UI and fully documented in the tracking note (with screenshots for the blog post).
5. **No fallbacks.** Local login forms are disabled after verification. This forces Authentik to be the only path, removes the "which password?" confusion for Sylwia, and keeps the attack surface small.
6. **Mattermost and LiteLLM stay as-is.** Mattermost Team Edition does not expose generic OIDC; only GitLab-OAuth compatibility exists, but the product itself only unlocks SSO features with an Enterprise licence. LiteLLM's Admin UI SSO is also Enterprise-only. We will not pay for Enterprise licences for a homelab.

## Consequences

### Positive

- One password for the Supreme Leader and one for Sylwia across Grafana, Open WebUI and Nextcloud.
- Centralised account lifecycle: disable one Authentik user and all three services lose access simultaneously.
- No more `changeme` or weak local admin passwords in service configs.
- GitOps-managed, auditable, rollback-friendly.

### Negative / Risks

- Authentik becomes a hard dependency for three services. If it is down, those services are unreachable for new sessions (existing sessions may persist depending on cookie TTL).
- No local fallback means a bad config locks everyone out until the Git revert reconciles.
- Nextcloud requires the `user_oidc` community app and a post-install `occ` command, wrapped in a Job. Slightly more moving parts than the other two.
- Open WebUI's `ENABLE_OAUTH_PERSISTENT_CONFIG=false` prevents later UI config changes from persisting; Flux remains the source of truth.

## Alternatives considered

| Option | Why rejected |
|---|---|
| SAML for all five services | SAML is supported by some apps but adds certificate management and is overkill for a homelab. |
| LDAP backend for all five services | Would require running an LDAP server and schema mapping. Not simpler than Authentik OIDC. |
| Cloudflare Access in front of everything | Offloads authentication to Cloudflare, but does not integrate with in-app RBAC and contradicts the self-hosted/de-cloud motivation. |
| Pay for Mattermost/LiteLLM Enterprise SSO | Not justified for a homelab with two users. |
| Keep local fallbacks on migrated services | The Supreme Leader explicitly wants no fallbacks. |

## When to revisit

- Mattermost or LiteLLM release a free-tier SSO feature.
- We add a sixth service that does not support OIDC/OAuth2.
- Authentik proves unreliable or the single-point-of-failure risk becomes unacceptable.
- We need per-service RBAC instead of the shared `homelab-admins` / `homelab-users` groups.

## References

- `docs/adr/adr-001-prometheus-storage-local-path.md` — example ADR format.
- Tracking note: `homelab/tracking/2026-07-15-sso-migration-plan.md`
- `infrastructure/auth/authentik-helm-release.yaml`
- `apps/tldraw/tldraw-oidc-client.sops.yaml` — existing SOPS OIDC client pattern.
- `infrastructure/observability/grafana-helm-release.yaml`
- `apps/llm-hub/openwebui-helm-release.yaml`
- `apps/nextcloud/nextcloud-helm-release.yaml`
