# ADR-038: Per-device scheduled curfews — the dedicated-marker pattern (Sylwia's Instagram-only evening block)

Date: 2026-10-08
Status: Accepted
Extends: [ADR-022](adr-022-pihole-family-shield-enforcement-layer.md) (group topology, whole-home noporn, curfew-by-CronJob)
Supersedes: none

## Context

The Supreme Leader asked for Instagram to be unavailable on Sylwia's Pixel every
evening from 21:00, effective immediately ("from today").

Recon found the enforcement layer in a dormant state:

- The main S curfew pair (`pihole-curfew-enable` 21:00 / `pihole-curfew-disable` 07:00)
  was still `suspend: true` — set "for the window" during the 2026-09-29 one-shot
  Instagram experiment and never switched back on. **No S curfew has run since
  2026-09-29.**
- Sylwia's Pixel (`da:93:94:e7:c7:7b`, group 10) had **zero** social-domain queries
  in the FTL log across the preceding 4 days and **zero** social blocks recorded.
- The 37 `W/S block` deny entries sat at group `[9]` (Wojtek only).

So the request was really two things: (1) restore enforcement for S without
accidentally arming a policy broader than what was asked, and (2) make the
Instagram block *scheduled*, not a one-shot.

The design tension: ADR-022's reconciler converges **every** entry carrying the
marker `W/S block`. Reusing it for an Instagram-only request would have silently
armed reddit, youtube, x/twitter, tiktok and facebook for Sylwia as well — a policy
five times broader than the ask, applied to another adult without it being stated.

## Decision

**A scheduled curfew is a (marker × schedule) pair. Never reuse an existing marker to
express a narrower policy.** A dedicated marker gives each policy its own reconciler
pair, its own hours, and independent switchability.

Concretely, for Sylwia's Instagram curfew:

1. A new dedicated marker **`S-IG`** on exactly four deny entries: `instagram.com`,
   `www.instagram.com` (exact) and `(^|\.)instagram\.com$`, `(^|\.)cdninstagram\.com$`
   (regex — the regex set is what actually survives the app's CDN/subdomain doors,
   per the 2026-09-29 leak lesson).
2. A new GitOps CronJob pair, `pihole-s-ig-enable` (`0 21 * * *`) /
   `pihole-s-ig-disable` (`0 8 * * *`), `timeZone: Europe/Warsaw`, running the
   **existing** reconciler script with `PIHOLE_MARKER=S-IG`. No new script, no new
   secret — the same SOPS `pihole-app-secrets` `password` key.
3. Desired-state semantics identical to ADR-022: enable → `[9,10]`, disable → `[9]`.
   **Group 9 is retained in both states**, so Wojtek's 24/7 Instagram block is never
   weakened by Sylwia's schedule. No `RESTORE_MARKER`, so the pair re-adopts the
   entries every night instead of renaming them back into the main marker.
4. `PiholeCurfewJobFailed` widened to `pihole-(curfew|s-ig)-(enable|disable)-.*`.
5. The spent one-shot `pihole-ig-experiment-cronjob.yaml` is dropped from
   `apps/kustomization.yaml` (kept in-tree as a recipe for day-restricted one-shot
   jobs).

Hours are 21:00 → **08:00**, not 21:00 → 07:00, because "losing access after 9pm"
reads as a sleep window and 08:00 is the gentler boundary for a phone that is
someone else's, not the operator's. This is an operator choice, recorded here so
it is a decision and not an accident. (The main S curfew, if re-armed, still uses
07:00.)

## Consequences

**Positive:** the requested policy is enforced exactly — Instagram only, for one
device, nightly — while every other social site stays reachable for Sylwia. The
main `W/S block` roster keeps its single meaning. Two policies can now be armed,
disarmed, or retimed independently. Verified end-to-end: at a simulated group-10
client with the pair armed, `instagram.com` / `www.instagram.com` → DENYLIST and
`cdninstagram.com` → REGEX (all `0.0.0.0`), while `whatsapp.com`, `google.com` and
`youtube.com` still FORWARD.

**Negative:** more CronJobs to watch (the alert covers all four). The marker becomes
part of an interface again — renaming `S-IG` orphans those entries from their
reconciler silently. And the deeper structural gap is unchanged: **nothing in the
repo declaratively seeds deny entries.** The `S-IG` four (like the 37 `W/S block`
ones) were created imperatively via the FTL API. The reconciler is a drift-healer,
not a seeder, and the `enable` guard deliberately refuses to arm an empty set — so a
cluster rebuild restores the schedules but not the entries they manage.

**Operational note:** the main S curfew remains suspended by choice-after-the-fact.
Sylwia has an Instagram-only curfew; she does **not** have the full social list. If
the intent is the broader 21:00–07:00 rule from the planning note, that is a separate
one-line change (`suspend: false`) and a policy decision, not an oversight to fix
silently.

## Alternatives considered

- **Reuse the `W/S block` marker with a one-shot pair** (the 2026-09-29 approach) —
  rejected: one-shot day-restricted schedules are for *experiments*, not standing
  policy, and they cannot repeat. It also inherits the broad-list problem.
- **Add a new Pi-hole group (`S-IG`) and scope the entries to it** — rejected:
  duplicate deny entries and a second membership axis to keep in sync, for no gain
  over marker-scoping; ADR-022 already rejected group-duplication for the same reason.
- **Re-enable the main S curfew instead** — rejected as the *first* step: it arms five
  social sites for Sylwia, which is more than was asked. Left as the Supreme Leader's
  explicit call.
- **OPNsense/`pf` time-based blocking of Instagram IP ranges** — rejected: shared Meta
  IP ranges make IP-layer social blocking a blunt instrument that also hits Messenger,
  and it splits the enforcement model across two layers (ADR-022 keeps v1 DNS-only).
- **`S-IG` entries scoped `[10]` only (drop group 9)** — rejected: it would release
  Wojtek's own Instagram block at 08:00 every day. Keeping `[9]` in both states makes
  the policy additive and safe.

## When to revisit

- The Supreme Leader decides the full 21:00–07:00 social curfew should apply to S
  (`pihole-curfew-*` → `suspend: false`, and reconcile the marker overlap).
- A declarative deny-entry seed lands in the repo (then a rebuild fully restores
  enforcement, and this ADR's "Negative" section can be dropped).
- Pi-hole ships native per-group scheduling (retire both CronJob pairs).
- Any further per-device window is requested: use this pattern — new marker, new pair,
  same script — rather than widening an existing marker.
