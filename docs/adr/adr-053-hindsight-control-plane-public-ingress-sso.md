# ADR-053: The Hindsight Control Plane is published behind its Cloudflare Tunnel through in-cluster oauth2-proxy + Authentik — never bare, and without Cloudflare Access on top

## Status

Accepted — 2026-10-13. **Epic:** H2-232 (*Replace Honcho + OpenViking with self-hosted Hindsight*).
**Ticket:** H2-241. **Tracking note:** `homelab/tracking/2026-10-12-hindsight-deployment-planning.md`
(vault). **Extends ADR-052**, which booked this app's shape as "tunnel + SSO" without choosing the
gate; this ADR is that choice. **Uses ADR-032** (tunnels created via the Cloudflare API with a scoped
token).

**Correction — same day, after the operator's acceptance test failed (2026-10-13).** The first version of
this ADR claimed the CP had no authentication of its own and that oauth2-proxy was therefore the *only*
gate. That came from reading `.env[*]` and **missing `envFrom`**, and it was wrong in a way that actually
blocked the operator: the CP's UI *does* bounce an authenticated user to its own `/login`, and that page is
**unsatisfiable** — `/api/auth/login` returns `503 Access key not configured` while `HINDSIGHT_CP_ACCESS_KEY`
is unset, so no typed key can ever be accepted. What was genuinely missing is
**`HINDSIGHT_CP_DATAPLANE_API_KEY`**: without it the CP calls the API keyless, gets
`Authentication failed: Invalid API key`, and shows a login page the user cannot pass. It is now set to the
same value as the tenant key, and the CP logs `Using API key authentication`.
`HINDSIGHT_CP_ACCESS_KEY` remains **deliberately unset** — oauth2-proxy stays the single gate — so the CP's
login page is not a second lock, it is a symptom of a missing dataplane key. The lesson is worth more than
the fix: **`.env[*]` does not describe a container's environment when `envFrom` is in play, and "not in the
manifest" is not the same as "not in the process".**

## Context

The Hindsight **Control Plane** has no authentication of its own — no built-in OIDC, and no usable login.
It is a browser UI over the banks, memories, directives and mental models; anyone who can reach its port can
read and edit the whole memory platform. Its API is protected by the tenant API key, but the CP is not
protected by anything.

The one login page it *does* render is a trap rather than a gate: it appears when the CP cannot reach the
API, and it cannot be satisfied, because `/api/auth/login` answers `503 Access key not configured` unless
`HINDSIGHT_CP_ACCESS_KEY` is set — which it deliberately is not here (see the correction above). What the CP
actually needs to serve anything is `HINDSIGHT_CP_DATAPLANE_API_KEY`, a *different* variable with a
confusingly similar name.

Until this ticket the CP was reachable only on the LAN / Netbird NodePort **30240**, which was
tolerable. The epic calls for a public hostname (`hindsight.voitech.dev`) because the Supreme Leader
mostly works from his phone and from a Framework laptop outside the LAN, so a public hostname was
agreed. That converts "tolerable" into "an unauthenticated admin UI on the internet unless something is
put in front of it".

Two candidates for that "something", and a third that is not a real option:

1. **Cloudflare Access** — the documented pattern in the `homelab-cloudflare-access` skill for services
   with no native OIDC.
2. **In-cluster `oauth2-proxy` + Authentik** — the pattern already running in front of OpenChamber.
3. The CP's own `HINDSIGHT_CP_ACCESS_KEY` — never set in this homelab, and **not a usable gate**: with it
   unset the CP's `/api/auth/login` answers `503 Access key not configured`, so the page that looks like a
   lock cannot be passed by anyone (see the correction above).

A constraint that matters: the scoped Cloudflare API token this homelab holds (`~/cloudflare-api.sops.yaml`,
ADR-032) carries exactly **`Cloudflare Tunnel → Edit`** and **`DNS → Edit`**, nothing else. Access
applications and policies need a further `Access: Apps and Policies → Edit` permission.

## Decision

**The tunnel's origin is the SSO gate, never the control plane:**

```
[client] --HTTPS--> [Cloudflare edge] --tunnel--> [hindsight-oauth2-proxy:4180]
                                                    --Authentik OIDC--> [hindsight-control-plane:3000]
```

- A dedicated Cloudflare Tunnel (`0d2a303a-bf06-4bfe-8c8e-03dfaa841871`, `config_src: cloudflare`) has
  its public hostname rule point at `http://hindsight-oauth2-proxy.hindsight.svc.cluster.local:4180`.
  **Pointing it at `hindsight-control-plane:3000` would publish an unauthenticated admin UI**, so the
  fallback `--url` in the cloudflared deployment is set to the proxy as well: if the remote rule were
  ever lost, the fallback must still fail closed.
- `oauth2-proxy` (v7.15.4, pinned off the saturated control-plane node onto `t460`) enforces Authentik
  OIDC against the application slug **`hindsight`**, and proxies to the CP.
- **Cloudflare Access is deliberately NOT layered on top.** One auth gate, in-cluster, the same as
  every other SSO-fronted application here. It also means no wider API token is required.
- The **API** (port 8888, NodePort 30239) stays LAN/Netbird-only. It is key-protected and Hermes runs
  on the M1 Max on the LAN; it is not published for this to work.

## Consequences

**Positive**

- One authentication pattern for the whole homelab: the operator sees the Authentik login he already
  knows, and the app needs no code change.
- No new Cloudflare permission; the existing scoped token (Tunnel + DNS) is sufficient.
- Reusable session cookie across `*.voitech.dev`, and SSO-only is verifiable on the live page (count
  credential inputs = 0), which is the standard this house holds logins to.
- The LAN NodePort 30240 survives as a break-glass path if the proxy or Authentik is down.

**Negative**

- One more moving part in the request path, and its flags are **load-bearing, not cosmetic**:
  `--scope=openid email profile offline_access` with `--cookie-refresh`, per-request CSRF cookies
  bounded by `--cookie-csrf-per-request-limit`, and `--disable-keep-alives`. Each of those was paid for
  by an incident on OpenChamber; a future tidy-up that removes one will reintroduce it.
- **oauth2-proxy authenticates but does not authorise per-user.** It passes identity headers
  (`--set-xauthrequest`) that the CP ignores, so *every* authenticated user sees the same full
  control plane. That is acceptable for a single-operator homelab and is exactly why the API, which
  does have a tenancy model, is kept off the public hostname.
- If `oauth2-proxy` or Authentik is down, the CP is unreachable publicly. Accepted: the public
  hostname is a convenience, not the only path.

## Alternatives considered

- **Cloudflare Access in front of the tunnel hostname**, with an Access `Allow` policy on an IdP and a
  `Deny Everyone` catch-all — *rejected*: it needs a broader Cloudflare token than the homelab holds,
  it adds a second gate on top of Authentik for no additional assurance, and it would make this one app
  inconsistent with every other SSO-fronted app in the house.
- **Relying on the control plane's own "access key"** — *rejected after investigation*: the CP has no
  such gate for its UI. A "lock" made of a query parameter or a shared secret in the URL is not an auth
  boundary, and it would have shipped an unauthenticated UI while looking protected.
- **Publishing the Hindsight API as well** (so external clients could hit `/mcp`) — *rejected for now*:
  the MCP endpoint is already key-authenticated, and Hermes hosts reach it over the LAN. Revisit only
  when a client genuinely lives outside the LAN.
- **A Cloudflare Access *service token* for non-browser clients** — not needed yet, and it would drag
  in the wider token permission; the skill documents the exact recipe if that changes.

## When to revisit

- **Hindsight ships native OIDC / user accounts for the CP.** Then delete the proxy and use app-native
  OIDC, as this house does for Grafana and Nextcloud — that is strictly better and this ADR becomes
  obsolete.
- **A non-browser client needs the CP from outside the LAN** (a script, a CI job, a mobile app): that
  needs an explicit service-token path, not a hole in the SSO gate.
- **Cloudflare Access becomes the house standard** for services without native OIDC (i.e. the token
  gains `Access: Apps and Policies → Edit` and oauth2-proxy is retired everywhere at once) — a
  fleet-wide decision, to be made fleet-wide.
- **The control plane gains meaningful multi-user tenancy**, at which point "everyone authenticated
  sees everything" stops being acceptable and the CP must learn identity instead of receiving it as a
  header it ignores.
