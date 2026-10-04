# ADR-035: Bound oauth2-proxy per-request CSRF cookie pile (`--cookie-csrf-per-request-limit=3`)

- Status: Accepted
- Date: 2026-10-05
- Deciders: Andrzej (root-caused in H2-102), Wojciech Gula (approver by delegation)
- Supersedes/complements: ADR-027 (header-strip at the Bun boundary), ADR-025 (Node header-size bump)
- Related: Itsaplan H2-102, H2-101, H2-90

## Context

Both 2026-10-02 incidents — the morning 503/431 storm at the Node `:3000` hop (ADR-025)
and the `agent.list failed (431)` at the Bun `:4096` hop (ADR-027) — were caused by the
request header block exceeding ~16 KiB / 64 KiB. H2-102 was opened to find *why* the SSO
header block grew so large. The investigation ruled out the two original suspects and
pinned the real mechanism:

1. **The session cookie does not grow.** Measured fresh-login sizes: oauth2-proxy session
   cookie and Authentik cookies are 250–350 bytes each. `--cookie-refresh=1h` re-signs
   the same fixed-shape state; it does not accumulate claims.

2. **The Authentik claims are tiny.** `akadmin` is in 3 groups (`~45` bytes joined);
   the whole tenant has 4 groups. `X-Auth-Request-Groups` is a few hundred bytes, not KB.

3. **The actual bloat is the CSRF cookie pile.** To fix the 2026-09-15 concurrent-tab
   `CSRF token mismatch` 403s, the gates were switched to `--cookie-csrf-per-request=true`
   (commit `371fab5`). That flag makes oauth2-proxy mint a **uniquely-named** CSRF cookie
   per unauthenticated request (`_oauth2_proxy_<8-char-state-hash>_csrf`, 176-byte value,
   ~206 bytes on the wire, `Max-Age=900`). Because the names differ, cookies **never
   replace each other** — they accumulate in the browser jar and every subsequent request
   replays the whole pile. Verified live on this cluster:
   - 12 unauthenticated requests → 12 distinct Set-Cookie names, all host-scoped, 176-byte values.
   - 30 requests with a cookie jar → 30 CSRF cookies retained, zero server-side cleanup.
   - Incident-day (2026-10-02) Loki forensics: 1440–2787 `302` mints/hour from polling
     clients (PWA polling `/api/*` with a dead session mints on every poll). At a
     900-second retention, steady-state pile ≈ 360–700 cookies ≈ 75–140 KB.
   - Pile-size bisect against the live Node `:3000` (64 KiB limit): 300 cookies (62 KB)
     → 200, 350 cookies (72 KB) → **431**. The arithmetic matches the incident exactly.
   - This explains the incident shape: slow trickle from 04:00, spike when polling tabs
     multiplied, "self-fix" at 11:38 when the pile aged out and mints stopped.

Upstream anticipated precisely this failure: `--cookie-csrf-per-request-limit` exists and
its own documentation says it is *"useful if users end up with 431 Request headers too
large status codes."* The default is `0` = unbounded. We turned the per-request flag on in
September and never set the companion limit. The pile is still leaking today: 43–68 strict
431s/day on 2026-10-03/04 (the `/manifest.webmanifest` PWA poll from the Framework laptop
is the current minter).

## Decision

Set `--cookie-csrf-per-request-limit=3` on every oauth2-proxy gate in the homelab,
starting with the two that have `--cookie-csrf-per-request=true`:

- `apps/openchamber/openchamber-oauth2-proxy-deployment.yaml`
- `apps/pihole/pihole-oauth2-proxy-deployment.yaml`

Delivered via GitOps (repo commit → Flux reconcile → pod roll). Rule for future gates:
**if you enable `--cookie-csrf-per-request`, you must set `--cookie-csrf-per-request-limit`
in the same commit.**

Limit 3 keeps the concurrent-tab handshake protection that motivated the September change
(three in-flight logins tolerated) while capping the steady-state pile at ≈3 × 206 + a
transient mint ≈ 0.8 KB — two orders of magnitude below the smallest header limit in the
chain (Bun ~16 KiB).

## Consequences

Positive:
- Removes the root cause of both 431 incidents at the source, instead of only filtering
  the symptom at the Bun hop (ADR-027) or raising ceilings (ADR-025).
- Cuts browser→proxy request header volume for all users of these gates.
- One-flag change; upstream-supported semantics; trivially reversible.

Negative:
- A browser with more than 3 *simultaneously in-flight* OAuth handshakes on the same host
  could in theory see the oldest CSRF cookie cleared mid-flight. Real usage (even the
  September tab-army incident) involved a handful of tabs, and clear-on-mint only trims
  during new handshakes, so the practical window is tiny. If it bites, raise the limit —
  10 still caps the pile at ~2 KB.
- ADR-027/ADR-025 remain in force and are still needed: they protect against *other* fat
  headers (third-party cookies, user-agent stacks, future claims growth). This ADR closes
  the pile specifically.

## Alternatives considered

- **Revert `--cookie-csrf-per-request` to shared-name CSRF.** Rejected: reintroduces the
  2026-09-15 concurrent-tab `CSRF token mismatch` 403s — the reason it was set.
- **Remove `--cookie-refresh=1h`.** Rejected: measured, it is innocent; the session cookie
  does not accumulate. Refresh keeps 7-day sessions alive without hourly logins.
- **Shorten `--cookie-csrf-expire` (15 min → e.g. 5 min).** Helps the decay tail but does
  not cap the pile while minting is hot; the limit flag is the structural fix. Not needed
  once bounded.
- **Raise header limits further (Node 256 KiB, sidecar in front of Bun).** Rejected:
  treats symptoms, increases DoS surface, and Bun's ~16 KiB wall is not configurable.
- **Strip CSRF cookies at oauth2-proxy→upstream hop.** The proxy doesn't offer per-header
  upstream filtering; ADR-027 already strips `Cookie` before Bun. The pile also bloated
  the *browser→proxy* direction (cloudflared/Node saw it), which only the client-side cap
  can fix.

## When to revisit

- New oauth2-proxy gate with per-request CSRF and no limit → this ADR was not followed.
- `CSRF token mismatch` 403s return with limit ≥ 3 → raise the limit (10, 20), not remove it.
- Another unexplained 431 with the pile capped → suspect a *different* accumulating header;
  re-run the H2-102 forensic sequence (mint count vs pile arithmetic vs bisect).
- oauth2-proxy ≥ v7.16 changes CSRF clearing semantics → re-verify `ClearExtraCsrfCookies`
  is invoked per mint.
