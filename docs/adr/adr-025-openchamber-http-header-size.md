# ADR-025: OpenChamber Node.js HTTP header size limit

## Status

Accepted — 2026-10-02

## Context

OpenChamber (`openchamber.voitech.dev`) runs behind two gates:

1. Cloudflare Tunnel →
2. oauth2-proxy (Authentik OIDC) →
3. OpenChamber Node.js web app (Node 22).

On 2026-10-02 the Supreme Leader reported 503 errors from OpenChamber after logging in.
The oauth2-proxy logs showed bursts of `ReverseProxy read error during body copy: ... connection reset by peer`,
and cloudflared reported `unexpected EOF` / `Unable to reach the origin service`.
Crucially, the upstream OpenChamber app was returning **HTTP 431 Request Header Fields Too Large**
for otherwise normal requests (`/`, `/favicon.ico`, `/sw.js`).

Node 22's default `--max-http-header-size` is around 16 KiB per header block. After SSO,
oauth2-proxy forwards:

- the `_oauth2_proxy` session cookie,
- `X-Auth-Request-User`,
- `X-Auth-Request-Email`,
- `X-Auth-Request-Preferred-Username`,
- `X-Auth-Request-Groups` (comma-separated Authentik groups).

For users in several groups (e.g. `authentik`, `Admins`, `homelab-users`, `homelab-admins`),
the combined header block exceeds Node's default, the request is rejected with 431,
the TCP connection is torn down mid-body, and every downstream proxy interprets the
broken connection as a generic 503.

This is a different failure mode from the earlier 502 keepalive race (ADR-019-era fix),
which was fixed by `--disable-keep-alives` on oauth2-proxy. The `--disable-keep-alives`
flag remained in place; this was purely a header-size issue.

## Decision

Set `NODE_OPTIONS=--max-http-header-size=65536` as an environment variable on the
OpenChamber web container in `apps/openchamber/openchamber-deployment.yaml`.

This is applied via GitOps (Flux) and is the only change needed to restore service.

## Consequences

Positive:

- Authenticated users with large Authentik group memberships can load OpenChamber again.
- No changes to oauth2-proxy or Authentik are required.
- The fix is public-repo-safe (`NODE_OPTIONS` contains no secrets).

Negative / risks:

- Raising the header limit increases memory per connection slightly.
- 64 KiB is large enough to tolerate current Authentik payloads but still bounded.
- If group memberships grow significantly, we may need to raise it further or trim
  forwarded headers.

## Alternatives considered

1. **Reduce headers in oauth2-proxy** (e.g. disable `--set-xauthrequest`, or use
   `--pass-authorization-header` selectively). Rejected: OpenChamber uses the
   authenticated user identity and groups for UI authorization and the Itsaplan
   bridge; dropping headers would break features.

2. **Patch the OpenChamber application to parse large headers itself.** Rejected:
   Node's limit is enforced before the application sees the request. The standard
   knob is `NODE_OPTIONS`.

3. **Move to a reverse proxy that strips/splits cookies.** Rejected: adds complexity
   and another moving part for no benefit over the standard Node flag.

## When to revisit

- If 64 KiB is exceeded again, reconsider whether OpenChamber needs all forwarded
  Authentik groups, or split group claims into a smaller subset.
- If OpenChamber moves to a different runtime (Bun standalone, etc.), verify the
  equivalent header limit and document it.

## References

- Commit: `1742def` — `fix(openchamber): bump Node max-http-header-size to 64 KiB`
- Tracking note: `homelab/tracking/2026-10-02-openchamber-503-header-size.md`
