# LAN DNS fails over off mimir: a standby Pi-hole on loki and a keepalived VIP on 192.168.1.179

- **Status**: Pending
- **Date**: 2026-11-16
- **Issue**: none (owner request in chat, 2026-11-16; tracking note `homelab/tracking/2026-11-16-mimir-down-breakglass-dns-on-loki.md`)
- **Related**: pending `k3s-control-plane-moves-to-mimir` (made `.179` a front-door alias on mimir),
  ADR-021/022 (Pi-hole family shield), ADR-013 (NetBird firewall off on k3s nodes)

## Context

On 2026-11-16 at 02:37 mimir **hard-reset**. Its journal stops mid-stream at 02:36:26, with no
shutdown and no panic. It wasn't under load: Prometheus showed 3.8 GB free, load 1.3, 59 °C, no OOM
kills. loki stayed up, so it wasn't the house power. The kernel came back within a minute, then
**waited at the LUKS passphrase prompt for 16 hours** until the owner typed it in over JetKVM at
18:59. From the LAN, that looks exactly like a dead box: no ARP, and WoL does nothing because the
box is already on. mimir holds three things
at once: the only k3s server, Pi-hole (hostNetwork), and `192.168.1.179`, the DNS address DHCP gives
every device. OPNsense lets **only `.179`** send port 53 to the internet (family-shield enforcement).
So one hung box took the whole house off DNS. Plain IP traffic kept working the whole time.

DNS came back about 7 hours later through a hand-made break-glass on loki: `.179` added as a
secondary IP, the 1.1.1.1/1.0.0.1 source routes, a Python forwarder on `:53`, and a watcher that hands
`.179` back when mimir answers. That proved the idea works, but it had no filtering, no family
shield, no local records, and it only happened because someone noticed and had a way in. It was the
second house-wide DNS outage in four days (the first was 6.5 h during the 2026-11-12 cutover).

When mimir did boot, DNS **still** didn't work. `homelab-frontdoor-ip.service` ran before DHCP had
a gateway. `ip route replace 1.1.1.1/32 via 192.168.1.1` failed with `Nexthop has invalid gateway`,
and a trailing `|| true` hid the error, so systemd reported the unit as finished. `.179` was up,
Pi-hole answered, but it had no route to upstream. Fixed the same evening: the unit is now
`host/mimir/homelab-frontdoor-ip.{sh,service}`, waits for the default route, checks the routes
exist, and retries on failure.

Two constraints shape the fix:

1. **Failover must not depend on the control plane.** With mimir dead, Kubernetes can't reschedule
   anything. Whatever takes over must already be running on another node, and the address has to
   move without the API.
2. **`.179` stays the only DNS address.** The OPNsense rule and every DHCP lease already point at it.
   Moving the address is cheaper than changing what clients and the firewall trust.

## Decision

1. **A second Pi-hole, `pihole-standby`, runs on loki all the time**: a second HelmRelease in
   `apps/pihole/` with the same chart and version, hostNetwork, `nodeSelector:
   kubernetes.io/hostname: loki`, and its own local-path PVC. It is hot, not cold: it answers on
   loki's `:53` all the time, so taking over is just moving the address.
2. **Config parity comes from Git, not from syncing one instance to the other.** The existing seed
   CronJobs (`pihole-client-seed`, `pihole-deny-seed`, curfew enable/disable) loop over both API
   endpoints and alert if either one drifts. Anything changed only in the primary's web UI won't
   reach the standby. That's on purpose: if it isn't in Git, it doesn't exist.
3. **keepalived on mimir and loki owns `192.168.1.179` over VRRP**, as a host systemd service in
   `host/k3s-node/` and not a pod, so it keeps working when the cluster can't. Unicast peers
   `.145` ↔ `.190`, password set, mimir priority 150, loki 100. A `track_script` runs
   `dig +time=1 @127.0.0.1 pi.hole` every 2 s. If the local Pi-hole stops answering, that node drops
   out. The `notify_master` / `notify_backup` scripts add or remove the `1.1.1.1/32` and `1.0.0.1/32`
   source routes `src 192.168.1.179`, so whichever node holds the VIP can reach upstream through the
   firewall. keepalived **replaces** `homelab-frontdoor-ip.service`.
4. **`.179` means DNS and NodePorts, not the k3s API.** NodePorts work on any node, so they survive
   the VIP moving. The API doesn't: with the VIP on loki, `.179:6443` goes nowhere. API clients
   (kubeconfigs, the paperclip kubeconfig, the `server:` line in mimir's `config.yaml`) target
   `https://192.168.1.145:6443` until Odin gives us a real control-plane VIP.
5. **mimir unlocks its disk without a human, but only at home**: clevis with a **tang** server on OMV
   (network-bound disk encryption). The LUKS passphrase slot stays as the fallback, typed over
   JetKVM. A stolen mimir can't reach tang and stays locked. Only after that does mimir get a
   hardware watchdog (`RuntimeWatchdogSec=30s`, AMD `sp5100_tco`, `kernel.panic=10`): a watchdog in
   front of a passphrase prompt just turns a hang into a 16-hour wait at the prompt. The same goes
   for loki and every future encrypted node. mimir's MAC (`04:7b:cb:45:f9:00`) goes in
   `host/mimir/README.md`.
6. The loki break-glass recipe is kept as a runbook (`docs/runbooks/dns-breakglass.md`) for the case
   where both Pi-holes are broken.

## Consequences

- Positive: losing mimir, or just its Pi-hole pod, costs about 3–6 s of DNS (VRRP advert 1 s, three
  missed checks). The family shield keeps working, because the standby runs the same groups and the
  same curfew.
- Positive: the OPNsense rule, DHCP and every client stay as they are. Only the host that owns `.179`
  changes.
- Positive: unattended unlock turns "rebooted at 2 a.m." into a 2-minute blip for everything on
  mimir: Paperclip's and Mattermost's DBs, docs-mcp, the API. Not just DNS.
- Negative: clevis/tang makes OMV a boot dependency. If OMV is down too, the node waits at the
  prompt as it does today (no worse). The tang key on OMV must be backed up, or every node falls
  back to the passphrase.
- Negative: two Pi-holes means two sets of query logs and stats. Grafana gets a per-instance panel;
  the long-term history after a failover is split.
- Negative: the seed CronJobs get more complicated, and one more PVC on loki (small, gravity db only).
- Negative: VRRP is one more moving part on the LAN. If keepalived is misconfigured on both nodes
  (both MASTER, a split-brain), the same IP lives on two MACs and DNS flaps. Mitigation: unicast
  peers, `nopreempt` off, a Prometheus alert on `.179` being held by more than one MAC (node-exporter
  textfile from each node's `ip addr`).
- Negative: anything still pointing at `.179:6443` breaks during a failover. Item 4 has to be done
  first: grep the repo and the hosts for `179:6443`.
- Negative: while the VIP is on loki, NodePort traffic for pods on mimir still dies with mimir.
  That's expected; this ADR is about DNS only.

## Alternatives considered

- **DHCP hands out two DNS servers (`.179` and `.190`).** Clients fail over their own way: Android
  and iOS query both, some resolvers wait 5 s per timeout, Windows sticks to whichever answered
  last. OPNsense would have to let a second host do upstream DNS. That doubles the hole the family
  shield relies on, and a device could pick whichever Pi-hole is behind on config. Rejected.
- **A 2-replica Pi-hole behind a Kubernetes VIP (MetalLB / kube-vip).** That puts DNS failover inside
  the system that just failed. It adds a load balancer stack we don't otherwise need (`servicelb` is
  disabled), and the upstream source-route rule would still need host-level work. Rejected. kube-vip
  comes back when Odin brings a real control-plane VIP (see revisit).
- **OPNsense Unbound as a fallback resolver in DHCP.** Simple and always up, but it bypasses Pi-hole,
  so no family shield and no curfew. That breaks a promise made in ADR-021/022. Rejected as an
  automatic path; it's still a valid manual last resort.
- **Pi-hole in Docker on OMV.** OMV is always on, but it's another snowflake outside Flux, it still
  needs a VIP to move `.179`, and OMV's job is storage. Rejected.
- **Only the watchdog and the break-glass runbook.** The cheapest option. It covers hangs but not a
  dead PSU, a bad disk, a kernel that won't boot, or a planned mimir reboot. Kept as layers on top
  (items 5 and 6), not as the whole answer.
- **TPM-bound LUKS unlock instead of tang.** No TPM device is visible on mimir (fTPM probably off
  in BIOS), and a TPM unlocks a stolen box just as happily. tang ties the unlock to the house LAN.
- **Remove disk encryption from the nodes.** The nodes hold kubeconfigs, SOPS-decrypted Secrets in
  etcd and DB files. Rejected.
- **A dedicated DNS box (Raspberry Pi).** More hardware, and it's still a single box unless there
  are two of them. Not worth it while two nodes can already do VRRP.

## When to revisit

- **Odin joins as a control plane.** Then give the k3s API its own VIP (kube-vip or keepalived on the
  servers), and consider a third VRRP member for `.179`.
- **OPNsense rule changes**, e.g. the upstream allow moves to a group alias or DoH is enforced
  differently. The source-route trick might no longer be needed.
- **Pi-hole gets native HA or config sync** that's simpler than the seed CronJobs (e.g. nebula-sync
  reaching feature parity for groups/clients).
- **The standby drifts or flaps** more than once a quarter. Then active/standby VRRP is the wrong
  model and DNS should move to dedicated hardware.
