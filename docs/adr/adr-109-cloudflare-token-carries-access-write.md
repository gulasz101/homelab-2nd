# ADR-109: The Cloudflare token carries Access write, so ingress is API-only

- **Status**: Accepted
- **Date**: 2026-10-29
- **Issue**: GUL-580
- **Related**: ADR-032 (the tunnel recipe whose scope rule this amends), GUL-550 (Riff Radar), GUL-579 (the same wall on a private image pull)

## Context

ADR-032 fixed the account token at `~/cloudflare-api.sops.yaml` to two scopes and wrote the
rule in bold: *Never anything under Access / Zero Trust write.* That was right for the job it
was solving — creating tunnels and DNS records — and wrong for the next job.

The gap showed up on every service that needed Cloudflare Access in front of it. The token
could **read** Access applications (`GET /accounts/{id}/access/apps` → 200) and could not
**create** one (`POST` on the same path → `403 {"code":1010,"error":"auth.forbidden"}`). So the
last step of every public exposure was a Zero Trust click by the owner, which is the same class
of wall GUL-579 removes on the image side: a credential that is enough to inspect the platform
and not enough to change it.

The read returned 200 the whole time, which is exactly why nobody noticed: a successful GET on a
collection hides a 403 on the same path. The probe that tells the truth sends a body that cannot
succeed (`{}`) — an authorised call answers `400 name required` and creates nothing, an
unauthorised one answers `403/1010`.

On 2026-10-29 the owner added **`Access: Apps and Policies` → Edit** to the existing token in the
dashboard. The secret value did not change (the file's mtime did not move), so there was no
rotation event and no old token to revoke.

## Decision

1. **The one account token carries Access write.** Scopes are now: Cloudflare Tunnel Edit/Read,
   DNS Edit (zone `voitech.dev`), Zone Read, Access: Apps and Policies Read **and Edit**. This
   amends ADR-032 §3; the "never Access write" clause is retired.
2. **The capability is proven, not assumed.** `scripts/cf-access-proof.sh --proof` creates a
   throwaway `andrz-proof-<ts>` self-hosted app, reads it back, deletes it, and only passes when
   the API answers `404` afterwards. Cloudflare answers `202 Accepted` to the delete, so the
   passing condition is the disappearance, never the status code. Run it after every rotation.
3. **The token definition is checked by behaviour, not by reading it.** Nothing in the token set
   grants `API Tokens: Read`, so the scope list cannot be listed from here; the probe is the
   audit.

## Consequences

- **The whole ingress path is now API-only**: tunnel, ingress config, DNS record, and the Access
  application. One script, no dashboard clicks, and a new public service is a GitOps change plus
  one command.
- **The proof is repeatable evidence.** Two real applications were created and deleted on
  2026-10-29 (`2d4793a9…`, `5ab1cdf8…`), both confirmed gone.
- **The single secret now covers the whole ingress.** A leak means someone can create a tunnel,
  a hostname and an Access app. That was already true for tunnels and DNS; the blast radius grew
  by one step, not by a class.
- **The "two narrow scopes" mitigation in ADR-032 is gone.** The honest replacement is that the
  secret lives only in SOPS outside the repo, with an age identity on one machine and an expiry
  date on the token.
- **`Access: Service Tokens` Edit is still missing** (`403 1010` on `/access/service_tokens`,
  measured the same day). A new non-browser client through Access — the
  `CF-Access-Client-Id/Secret` path — still costs a dashboard click. Batch it into the next
  rotation instead of opening a separate sitting.
- **A wider token widens what a bug can do.** Any future script that takes a token from this file
  can now change who may reach a public hostname. Anything that writes Access from a schedule
  needs the same review as a deployment.

## Alternatives considered

- **A second, Access-only token.** Narrower per file: a leak of the DNS token cannot touch
  Access. Rejected because both secrets would sit on the same host behind the same age identity,
  so a leak of the Mac takes both anyway, while rotation work doubles and the second file gets
  forgotten. One secret with a written scope list is easier to keep honest.
- **Keep the dashboard step.** Rejected: it is the wall this issue exists to remove, and it is the
  same wall the Riff Radar demo hit twice in one day.
- **A global API key.** Rejected: no scoping, no expiry, and it can do far more than ingress.

## When to revisit

- **At the token's expiry.** Mint the fresh token with `Access: Service Tokens` Edit included, so
  rotation is one sitting for every scope we know about.
- **If Cloudflare ships per-application scoping**, which would let the token touch one Access app
  rather than the whole account.
- **If a second host ever holds this secret.** Two holders is the point where the "one secret,
  one rotation" argument in favour of a single token breaks.
- **If an automated job starts writing Access from a schedule**, which turns this credential into
  a production path that needs its own monitoring.
