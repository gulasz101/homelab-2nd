# ADR-015: Authentik SSO providers are declared in a Blueprint, never created imperatively

**Status:** Accepted
**Date:** 2026-09-13

## Context

Karakeep (`keep.voitech.dev`) authenticates users via Authentik OIDC only (`DISABLE_PASSWORD_AUTH=true`). On 2026-09-13 login failed for everyone: `https://auth.voitech.dev/application/o/karakeep/.well-known/openid-configuration` returned **404**, and the live Authentik database contained OAuth2 providers for Grafana, Nextcloud, tldraw, LiteLLM, Mattermost and Open WebUI — but **no Karakeep provider and no `karakeep` application at all**.

The Karakeep provider had originally been created **imperatively** during the July 2026 deployment session via `ak shell` against the running Authentik pod (documented as break-glass in `references/authentik-karakeep-oidc.md`, with the explicit note "ideally codify the provider in a Blueprint in a later iteration"). That never happened. Every other provider is declared in the GitOps-managed blueprint `authentik-blueprint-homelab-sso` (`infrastructure/auth/authentik-blueprint-secret.sops.yaml`), which is why they survived the Authentik DB rebuild that followed the arr-stack/CNPG recovery — and why Karakeep did not.

So the failure was not a configuration bug: it was **state that only existed in the Authentik database**, which is not a source of truth in this homelab. A rebuild of `authentik-db` (CNPG, restored/bootstrapped) silently dropped it.

The blueprint importer upserts by `identifiers` and never deletes entries absent from a blueprint, so adding the missing provider is safe and additive.

## Decision

1. **Every OIDC/OAuth2 provider and application used by a homelab service MUST be declared in the Authentik blueprint** (`authentik-blueprint-homelab-sso`, SOPS-encrypted). Imperative `ak shell` / UI creation is break-glass only, and any break-glass provider MUST be codified into the blueprint in the same activity or an immediate follow-up.
2. **The Karakeep provider + application are now blueprint entries** (`name: Karakeep OIDC`, `slug: karakeep`), with `client_id` / `client_secret` matching `apps/karakeep/karakeep-oidc-client.sops.yaml`, redirect `https://keep.voitech.dev/api/auth/callback/custom` (strict), scopes `openid profile email homelab-role`, signing key `homelab-signing`.
3. **The blueprint is the canonical source for provider settings.** Changing a client id/secret/redirect means changing the blueprint (and the consuming app secret) and letting Flux reconcile — not editing the Authentik UI.
4. **Client secrets are rotated through Git**, not the UI: the rotated secret is written to both the blueprint and the app's SOPS secret in the same commit. The July Karakeep `client_secret` was rotated during this activity (it had been exposed); `client_id` was preserved since it is not secret and appears in URLs.

## Consequences

**Positive**

- A future Authentik database rebuild self-heals: the blueprint recreates the Karakeep provider and application automatically.
- One place to audit every SSO provider; no invisible database-only state.
- Provider settings are reviewable in a PR and covered by the public-repo secret-encryption rule (SOPS/age).
- Karakeep login is restored without touching the Karakeep app's own configuration beyond the rotated secret.

**Negative**

- The blueprint Secret is consumed by the Authentik HelmRelease; applying a change requires a Secret update and the Authentik worker to re-discover blueprints (may need a rollout restart to be immediate).
- Client secrets for apps are now duplicated in two encrypted files (blueprint + app secret) and must be changed together — a consistency check is required (automated check or a documented step).
- The blueprint applies entries in file order; the Karakeep entry relies on `homelab-signing` and `homelab-role`, which are declared earlier in the same file.

## Alternatives considered

- **Retrieve the old secret from the CNPG backup and re-create the provider imperatively via `ak shell`.** Restores service fastest but re-creates the exact hidden-state landmine and leaves the next rebuild broken. Rejected.
- **Create a separate `authentik-blueprint-karakeep` Secret.** Cleaner isolation, but introduces blueprint ordering/`!Find` dependency on `homelab-signing`/`homelab-role` from the main blueprint on a fresh DB. Rejected in favour of the single, ordered `homelab-sso` blueprint (consistent with every other provider).
- **Switch Karakeep to local auth or a second IdP.** Violates the central-SSO decision (ADR-007) and the guardrail of one identity plane. Rejected.
- **Just fix it in the Authentik UI and move on.** Fastest, but the repo remains unaware and drift recurs. Rejected.

## When to revisit

- If the number of providers grows enough that the single blueprint becomes unwieldy → split into per-service blueprint Secrets with explicit ordering.
- If Authentik gains (or we adopt) a declarative IdP-as-code tool that reconciles deletions too → migrate, and this ADR is superseded.
- If the provider list ever needs to differ between `production` and `staging` environments → revisit the blueprint layout alongside ADR-012.
