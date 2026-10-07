# ADR-032: Public-ingress tunnels are created through the Cloudflare API, not the Zero Trust dashboard

## Status

Accepted — 2026-10-07 · Epic H2-106 (openGym, `gym.voitech.dev`), work item
H2-112. Relates to guardrail 8 (per-service Cloudflare Tunnel, TLS at the edge,
SOPS-encrypted tunnel tokens in the repo) and guardrail 5 (SOPS + age, never a
plaintext credential in the public repo). No Supersedes.

Numbering note: three fitness manifests previously cited "ADR-032" for an
openGym deployment-design decision that was never written down. This file takes
the number for the tunnel decision; those citations were corrected in the same
change (H2-191), and the openGym design rationale lives in the H2-106 tracking
note.

## Context

Public ingress in this homelab is Cloudflare Tunnel only: TLS terminates at the
Cloudflare edge, no router ports are opened, and there is no cert-manager and no
Kubernetes Ingress (guardrail 8). That model is cheap at runtime and expensive at
onboarding, because every public service needs a **new dedicated tunnel** — a
tunnel object, an ingress rule, and a proxied DNS record.

Until 2026-10-07 all 15 tunnels in the account had been created by hand in the
Cloudflare Zero Trust dashboard, one token at a time. Each new public service
therefore cost a human dashboard session: a permanent bottleneck on a workflow
that is otherwise fully automated. It bit hard on openGym — `gym.voitech.dev`
(H2-108) sat blocked for three days with the app deployed, healthy and
internally verified, waiting only for someone to click a tunnel into existence.

The dashboard is a UI over the public API. Nothing about the work needed a
human; what was missing was a scoped credential an agent could hold.

Facts verified live on 2026-10-07 against the account:

- `GET /accounts/$ACCT/cfd_tunnel` returned HTTP 200 with `success: true` and all
  15 existing tunnels listed.
- A token scoped to exactly `Account -> Cloudflare Tunnel -> Edit` and
  `Zone voitech.dev -> DNS -> Edit` can create a tunnel, set its
  remotely-managed configuration and create the DNS record — and nothing else of
  consequence.
- The Account ID is not something the user has to look up: it is embedded in
  every cloudflared tunnel token (JWT payload field `a`).
- The Zone ID is not in the token, but `GET /zones?name=voitech.dev` succeeds
  with this token, which the docs suggest a `DNS:Edit` token should not be able
  to do. Fallback if that ever stops working: the dashboard's
  Overview -> API panel.
- The endpoints below were re-confirmed against upstream documentation:
  "Create a tunnel (API)" (updated 2026-04-17, `developers.cloudflare.com`) and
  the API token permissions reference.

## Decision

1. **Tunnel creation for public ingress moves to the Cloudflare API**, performed
   by the agent rather than hand-clicked. One worked example already exists: the
   `fitness` tunnel `c876f33e-3f81-4545-956e-73bfaf8a62e8`, ingress
   `gym.voitech.dev -> http://opengym.fitness.svc.cluster.local:80`, DNS
   proxied, built entirely through the API.
2. **The credential is an account-owned API token** with an expiry date set and
   an entry on the rotation backlog.
3. **Its scopes are exactly two, and no more**: `Account -> Cloudflare Tunnel ->
   Edit` and `Zone voitech.dev -> DNS -> Edit`. The permission groups have been
   renamed upstream and both spellings are current: the tunnel scope is now
   `Cloudflare One Connectors Write` / `Cloudflare One Connector: cloudflared
   Write` (older name `Cloudflare Tunnel Write`); the DNS scope is `DNS Write`.
   Never `All zones`. Never anything under Access / Zero Trust write.
4. **The token lives outside the repo**, at `~/cloudflare-api.sops.yaml`, mode
   `0600`, age-encrypted to the repository recipient, and is never committed.
   Rationale: the repo is public; an account-grade token inside it, plus a
   leaked age key, would hand over tunnel **and** DNS control of the whole zone
   — a strictly bigger blast radius than any single service.
5. **Per-service tunnel tokens still go into the repo as SOPS-encrypted
   Secrets** (guardrail 8 unchanged). Only the account-grade key stays out;
   `apps/fitness/fitness-tunnel-token.sops.yaml` (commit `6f76d9d`) is the
   pattern.
6. **The creation sequence is three calls**, in this order:
   1. `POST /accounts/$ACCT/cfd_tunnel` with
      `{"name": "<service>", "config_src": "cloudflare"}` -> `result.id` plus a
      one-time `result.token`.
   2. `PUT /accounts/$ACCT/cfd_tunnel/$ID/configurations` with ingress
      `[{"hostname": "<host>", "service": "http://<svc>.<ns>.svc.cluster.local:<port>", "originRequest": {}}]`
      **plus a mandatory trailing catch-all `{"service": "http_status:404"}`** —
      the API rejects the configuration without it.
   3. `POST /zones/$ZONE/dns_records` with
      `{"type": "CNAME", "proxied": true, "name": "<host>", "content": "<tunnel-id>.cfargotunnel.com"}`.

   `config_src: "cloudflare"` makes the tunnel remotely managed: ingress rules
   live in Cloudflare, and a `--url` flag on the cloudflared Deployment is
   ignored at runtime.
7. **Read the response body, not the status code.** The API can answer HTTP 200
   with `success: false` on a validation error; curl's exit code proves nothing.
8. **Recover the Account ID from any existing tunnel token** (JWT field `a`)
   instead of asking the user; take the Zone ID from
   `GET /zones?name=voitech.dev`.

## Consequences

**Positive.**
- A new public service is three API calls. `gym.voitech.dev` went from a
  three-day stall to a same-session deploy, and the next service
  (`mail-archive.voitech.dev`) reused the recipe without a new hand-made tunnel.
- The step is reproducible and recorded, so a rebuild does not depend on anyone
  remembering what was clicked in a dashboard.
- Non-secret identifiers (tunnel IDs, hostnames, origin service URLs) can be
  recorded in the repo, which is what makes the rebuild reproducible at all.
- **Tunnel read access is a monitoring win**: the same token can list every
  tunnel and its connection state, so connector flap can be alerted on instead
  of discovered by the user.

**Negative / risks.**
- An account-grade credential now lives in the user's home directory. If it
  leaks *together with* the age key, the holder controls tunnels and DNS for the
  whole zone. Mitigations: two narrow scopes, an expiry, a rotation-backlog
  entry, `0600`, and never in the repo.
- **The token cannot satisfy a passkey and cannot bypass Cloudflare Access.** It
  can create a hostname; it cannot make a public hostname private. An Access
  application still needs a human in the dashboard (or a token with `Access:
  Apps and Policies Edit`, deliberately not granted yet). Tunnel automation
  shortens the deployment, not the security review.
- **Remotely-managed ingress is not in Git.** The repo holds a human-readable
  reminder ConfigMap (`apps/fitness/fitness-tunnel-ingress-configmap.yaml`), not
  the routing truth. Losing Cloudflare state means re-running the three calls,
  and editing a hostname by hand in the dashboard creates drift the repo cannot
  see.
- Permission groups get renamed: this ADR was written the same week the tunnel
  scope gained its "Cloudflare One Connectors" names. Instructions and token
  screenshots rot faster than code.
- The token expires, and an expired token does not fail loudly — it fails on the
  next new service, at the worst time. Hence the rotation-backlog entry is part
  of the decision, not a nicety.

## Alternatives considered

- **Keep clicking the dashboard (status quo).** Rejected: a per-service human
  bottleneck on an otherwise automated pipeline, and exactly what stalled
  openGym for three days. The dashboard is a UI over the same API the agent can
  call.
- **Origin certificate via `cloudflared tunnel login`.** Narrower (zone-scoped)
  and it needs no account-grade token, but it requires an interactive browser
  step *and* the `cloudflared` binary on the user's Mac, and it produces a
  locally-managed tunnel whose credentials have to be moved into the cluster.
  Rejected: it trades a credential risk for a hands-on step on the wrong
  machine — the same bottleneck wearing a different hat.
- **A user-owned API token** (created under the personal account rather than the
  account resource). Rejected: it is tied to one person's login and membership,
  so it dies on login changes, 2FA resets or role changes, and it is not clear
  which account it acts for. An account-owned token with two scopes is both
  narrower and longer-lived.

## When to revisit

- **Cloudflare renames the permission groups again.** The scope names in this
  ADR already have two spellings; if a third appears, the token-creation
  instructions need a re-check.
- **We decide to automate Cloudflare Access policies.** That needs `Access: Apps
  and Policies Edit`, deliberately not granted today, and it would move the
  whole public-ingress flow — hostname *and* protection — into the agent's
  hands.
- **The token expires or is rotated.** Re-verify the three calls on the new
  token (create, configure, DNS) before trusting it, and update the rotation
  record.
