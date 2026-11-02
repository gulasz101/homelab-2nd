# ADR: The Pi-hole client roster is declarative in Git, and a weekly audit names the devices nobody registered

- **Status**: Pending
- **Date**: 2026-10-31
- **Issue**: GUL-712 (follow-up to GUL-711 / GUL-392)
- **Related**: ADR-022 (family shield), ADR-038 (curfew scope), the deny-entry seeder from GUL-392

## Context

The Pi-hole family shield is three facts, not one: the **lists** (deny entries), the
**schedules** (the curfew CronJobs), and the **roster** — which MAC sits in which group.
The first two were brought into Git by GUL-392 (declarative deny seeds + a 05:00 seeder).
The roster was not. All fifteen `client -> group` rows existed only in the live FTL
database, created imperatively through the API over weeks.

A cluster rebuild — or a chart reinstall, which is the same event for a service whose
database lives on `local-path` — restores the entries, the groups and the CronJobs, and
then every device falls to group 0 (Default: porn list only). Group 9 and 10 carry the
21:00-08:00 Instagram curfew, so the rebuild silently deletes the curfew for every family
device while every dashboard stays green.

The second half of the problem is that a MAC-keyed roster decays on its own. Apple
rotates private Wi-Fi MACs. The registered `ba:fe:a8:fc:fd:a2` ("Wojtek M1 Max Hermes")
was already a dead row when GUL-711 audited it; the live identity was `6e:12:b8:89:46:54`
(m1max's `en0`, confirmed over SSH and by its AirPlay banner, not guessed from an OUI).
Nothing warned anyone. The only detector is a live-traffic-vs-roster diff, and it had
been run by hand, once, three weeks apart.

## Decision

1. **The roster is a ConfigMap in Git**: `apps/pihole/pihole-clients-seeds.yaml`, one row
   per device (`client` MAC, `comment`, `groups`). It is the source of truth for
   *existence, comment and group membership*. A `pihole-client-seed` CronJob converges the
   live API to it at 05:10 daily, with the same safety rules as the deny seeder: create
   missing rows, repair drift, **never delete**, refuse to run on an empty list, then read
   every row back. No gravity and no `restartdns` — client matching is read live.

2. **Groups in the seed file are a classification, never a daytime baseline.** The curfew
   modes move the groups of *deny entries* (`enable -> [9,10]`, `disable -> [9]`); they
   never touch a client row. A device in group 10 keeps receiving the S-IG blocks for
   exactly as long as the entry carries group 10, so rewriting a client's groups at 05:10
   cannot disarm a curfew armed at 21:00. This is why the seeder is allowed to own client
   groups at all — the deny seeder is not, and still refuses to touch entry groups.

3. **A weekly audit, not a weekly hope.** `pihole-client-audit` (Monday 09:00) diffs
   `GET /api/clients/_suggestions` (the device inventory — `/api/network/devices` returns
   a much shorter list and would declare live devices non-existent) against
   `GET /api/clients`, and posts every device with traffic in the last 24h but no roster
   row to Mattermost, with vendor, LAN address and the age of its last query. A seeded row
   in a required group (default 10) that has vanished or changed groups exits 2, which
   raises `PiholeClientAuditDrift`. A device that is merely away is reported as quiet,
   never as an alarm — Sylwia's phone is not home most weekdays.

4. **The audit posts over the in-cluster Mattermost service, not the public hostname.**
   `https://chat.voitech.dev` sits behind Cloudflare, which answers 403 to a request from
   Python's TLS/UA fingerprint. The webhook token is the same; only the host changes.

5. **An unregistered device is a finding, not a default.** Registering a device changes
   nothing about filtering for groups 0/11 (same porn list); it changes whether anyone can
   reason about the roster at 21:05 when someone says "Instagram still works". Devices are
   named from evidence — DHCP reservation, AirPlay/mDNS banner, traffic shape — never from
   an OUI guess.

## Consequences

Positive: a rebuild converges the roster from Git with no hand edits, proven by a
cluster-free fake-FTL test that starts from an empty database. A rotated MAC now shows up
in a channel within a week instead of being discovered by accident. The seeder is provably
write-free on a converged roster, which makes a manual run a safe diagnostic.

Negative: the seed file is a second place to edit when a device changes group (Flux
applies it within 15 minutes, so the window is short but real). A dead row stays in Git
until a human deletes it — the seeder never deletes, so the seed file can accumulate
history (`ba:fe…` is kept there deliberately, labelled as rotated). Devices that are
registered but offline for months are invisible to the audit: it can only see MACs that
still talk to the resolver.

## Alternatives considered

- **Seed the roster from the chart values** (`FTLCONF_*` / a custom config file). Rejected:
  Pi-hole's chart does not manage client rows declaratively, and a chart upgrade would
  fight the API.
- **Register by IP instead of MAC.** Rejected: DHCP leases move, and the September
  `.152`-as-an-IP-row mess is exactly what that produces.
- **Learn the roster from traffic automatically** (auto-register anything seen). Rejected:
  it turns a security control into a rubber stamp — a guest device on the LAN would be
  enrolled into the family groups by itself.
- **Post the audit through the public hostname like every Alertmanager receiver.**
  Rejected after it returned 403 from inside the cluster; the in-cluster Service is one
  hop shorter and has no WAF in the way.
- **Delete dead rows from the seeder.** Rejected: deletion is a human decision (guardrail
  9), and a wrong MAC in a config file is cheaper to see than to silently remove.

## When to revisit

- If Pi-hole grows native client-list import/export in the chart's values.
- If the family size or device count makes a single flat JSON file unreadable (roughly
  beyond 40 rows).
- If mDNS/DHCP integration lands in OPNsense that can feed the roster with hostnames, in
  which case the seed file becomes a naming override rather than the whole truth.
- If a second site joins and the roster needs to be per-network.
