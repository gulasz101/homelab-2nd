# ADR-022: Pi-hole Family Shield enforcement layer — group topology, whole-home noporn, and curfew-by-CronJob

Date: 2026-09-29
Status: Accepted
Supersedes: none (extends [ADR-021](adr-021-pihole-dns-shield-on-k3s.md), which covered deployment/listener model)

## Context

ADR-021 deployed Pi-hole on k3s (hostNetwork, `.179:53`) and OPNsense points clients at
it (DHCP option 6 direct; rdr as leak-plug). What was missing was the *enforcement*
layer: which domains block for whom, how Sylwia's 21:00–07:00 curfew is implemented
(FTL v6 has no native scheduling API — `/api/schedule` 404s), and how the locked family
rules ("noporn at all, non-negotiable", "communicators must survive", "INFRA exempt")
map onto Pi-hole v6 group semantics — which we had to discover live because the docs
do not state them.

Live-verified semantics that shaped this decision:

1. **Group 0 (Default) applies to ALL clients**, including grouped ones.
2. **A list/domain only affects a client if their groups intersect.** A list scoped
   `[0]` alone does NOT touch grouped clients — "everyone" means `[0,9,10,11]`
   explicitly (INFRA stays exempt).
3. **Deny-exact beats allow-exact** when both match a client.
4. FTL's cache is shared across clients; group changes require `restartdns` to be
   visible in dig tests.

## Decision

1. **Group topology (fixed ids)**: 0=Default, 9=W-wojtek-247, 10=S-sylwia-curfew,
   11=P-permissive, 12=INFRA-exempt. Clients are registered **by MAC address, not IP**
   (an IP-based entry silently went stale when DHCP re-leased a different address and
   the device fell into the unfiltered Default group for days).
2. **Whole-home noporn** = StevenBlack `alternates/porn/hosts` (151k domains) scoped
   `[0,9,10,11]`. The plain `master/hosts` list does NOT contain major porn domains
   (verified: pornhub.com absent) and is scoped `[9,10,11]` as the general
   ads/malware layer for family devices only.
3. **Dopamine list** (reddit/youtube/instagram/facebook/x/tiktok, 17 exact denies,
   comment marker `W/S block`) scoped `[9,10]` — W 24/7, S only during curfew.
4. **Communicator carve-outs** (whatsapp/messenger/fbcdn/etc., 9 exact allows on `[0]`)
   protect against future *list* blocks; they intentionally lose to the denies above
   (facebook.com is blocked for W/S, resolvable for P/INFRA — deny beats allow).
5. **Curfew = desired-state reconciler CronJobs** (`pihole-curfew-enable` 21:00 /
   `pihole-curfew-disable` 07:00, Europe/Warsaw, namespace `pihole`): each run
   converges ALL `W/S block` deny entries to `[9,10]` or `[9]`, runs gravity +
   restartdns, and verifies by read-back; non-zero exit on failure →
   `PiholeCurfewJobFailed` alert. Desired-state beats toggling: idempotent,
   drift-healing, backfills missed runs, and a missed alert-visible failure is
   strictly better than silent schedule drift.
6. **DNS path**: DHCP hands clients `.179` directly (MVC dnsmasq option 6); the pf rdr
   is leak-plug only (`from !.179 to !.179:53 → .179:53`), so no DHCP client ever
   depends on NAT-rewritten DNS — the 09-28 Android outage pattern is structurally
   impossible for family devices.

## Consequences

**Positive:** enforcement matches the locked family rules exactly; verified per-group
dig matrix; curfew is GitOps-managed, self-healing, and alertable; INFRA machines keep
clean DNS for container pulls/scraping; guests inherit noporn via group 0 membership of
the porn list.

**Negative:** two moving parts (CronJob + FTL API) — a failed curfew job leaves S
devices on the wrong schedule until fixed (mitigated by the critical alert); parked
tracker/social lists (AdguardSocial, EasyPrivacy, Android-Trackers) cannot be enabled
as-is because they contain whatsapp/messenger domains and would break communicators
(list blocks beat `[0]` allows for grouped clients); unregistered guest devices get
noporn but no social curfew (a deliberate v1 simplification); strict Android resolvers
hardcoded to the router get no DNS at all through the leak-plug (accepted friction).

## Alternatives considered

- **FTL-native group scheduling** — rejected: no `/api/schedule` API in v6; the
  feature request is upstream and unbounded.
- **Toggle a dedicated curfew blocklist on/off at 21:00/07:00** — rejected: stateful
  enable/disable drifts (a missed enable silently un-arms the curfew); the reconciler
  model converges to the desired state from any drift.
- **Separate `S-curfew` group with its own list** — rejected: duplicates the 17 deny
  entries; group-membership flipping of the SAME entries is one source of truth.
- **Block social via OPNsense firewall aliases** — rejected (v1): DNS-layer first per
  the planning decision; revisit only if bypass via hardcoded IPs becomes real.
- **Scope porn list `[0]` only** — rejected after live verification: `[0]`-only lists
  do not intersect grouped clients, so W/S/P would have had no porn block.

## When to revisit

- Upstream Pi-hole ships native per-group scheduling (replace the CronJobs).
- A second child/family profile needs different hours ( generalize the reconciler to
  N groups/schedules).
- Shadow-mode tuning (H2-75 follow-up): decide whether the parked tracker/social
  lists replace any exact denies, with a trimmed communicator allow set.