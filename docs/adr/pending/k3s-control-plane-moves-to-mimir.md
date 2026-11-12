# The k3s control plane moves to mimir on embedded etcd; 192.168.1.179 becomes a front-door address, not a machine

- **Status**: Pending
- **Date**: 2026-11-12
- **Issue**: none (owner request in chat, 2026-11-11; tracking note `homelab/tracking/2026-11-11-control-plane-move-clevo-t460-to-mimir-loki.md`)
- **Related**: ADR-001 (Prometheus on local-path), ADR-018 (OpenChamber on t460), ADR-021/022 (Pi-hole shield), `docs/cnpg-backup-servername-generations.md`

## Context

The cluster had one server, `homelab-2nd`: a Clevo P640RE laptop board (8 threads, 31 GB, GTX 970M).
k3s ran on the default **SQLite** datastore, so no second server could ever join. A ThinkPad T460
(8 GB) was the second big worker. The owner bought two boxes, **mimir** (Ryzen 5 PRO 4650GE, 6c/12t,
Vega 7 iGPU, 15 GB) and **loki** (i5-6500T, 15 GB), and wanted the Clevo and the T460 retired in one
night. Odin, built from the Clevo's RAM, joins later as a second control plane.

Two facts shaped the decision:

1. The Clevo's LAN address, `192.168.1.179`, was load-bearing far beyond "the server". DHCP hands it
   out as the DNS server (Pi-hole runs hostNetwork). The repo told devices to target it: MQTT,
   Node-RED, host-watch, five Pi-hole API CronJobs, every LAN NodePort, Hermes configs, the paperclip
   kubeconfig.
2. OPNsense lets **only `192.168.1.179`** send DNS (port 53) to the internet (family-shield
   enforcement). Any other host's Pi-hole can't resolve upstream.

## Decision

1. **Convert to embedded etcd in place** (`cluster-init: true`, k3s ≥ v1.22.2 migrates SQLite →
   etcd), join **mimir as a server** with identical flags (`disable: [traefik, servicelb]`,
   `flannel-backend: vxlan`) and the cluster's exact version (`INSTALL_K3S_VERSION=v1.35.5+k3s1`),
   then remove the Clevo with `kubectl delete node` **while both members are up**, so k3s removes its
   etcd member cleanly. mimir runs as a **single-member etcd** until Odin.
2. **`192.168.1.179` becomes a secondary IP on mimir**, owned by
   `homelab-frontdoor-ip.service` (systemd oneshot): `ip addr replace 192.168.1.179/24`, a
   gratuitous ARP, and **source routes** `1.1.1.1/32` and `1.0.0.1/32` `src 192.168.1.179`, so
   Pi-hole's upstream queries leave from the one address the firewall allows. mimir's kube-apiserver
   cert carries `.179` in its SANs, so `https://192.168.1.179:6443` kubeconfigs keep working.
   **Point everything at `.179`, never at a node IP.**
3. **Every local-path workload is pinned explicitly.** CNPG clusters get `affinity.nodeSelector`
   plus `primaryUpdateMethod: switchover`, so changing the pin means "build a replica on the new node
   and switch over", never "restart the primary somewhere its PV can't follow".
4. Placement: **mimir** = control plane, Pi-hole, docs-mcp, Ollama on the iGPU, hindsight, NFS apps,
   and the DBs hindsight/openwebui/mattermost/nextcloud/paperclip. **loki** = observability,
   firecrawl, OpenChamber, and the DBs authentik/itsaplan/litellm/opengist/star-office.
5. OMV NFS exports are granted **per node IP** (`.145`, `.190`; `.120` for node-red). The kernel
   mounts from the primary address, not the alias.

## Consequences

- Positive: the cluster can now grow servers (Odin). The front door survives hardware: the next time
  the control-plane box changes, `.179` moves with a systemd unit and no client changes.
- Positive: the switchover-on-pin-change pattern makes a database's node a one-line Git change.
- Negative: **single-member etcd** until Odin, so losing mimir stops the API (pods keep running).
  **Two members (mimir + Odin) are worse than one for availability**: quorum 2 of 2. Add a third
  voter promptly, or stay at 1.
- Negative: etcd snapshots land on mimir's own disk (`/var/lib/rancher/k3s/server/db/snapshots`),
  so they're not durable. Shipping them to OMV MinIO is a follow-up.
- Negative: mimir is the tight node (memory requests ~76% after the move). Odin relieves it.
- Negative: the firewall rule "only `.179` may do DNS" is now implemented by a source route on one
  host. It's documented here because nothing else makes it visible.
- Cost paid on the night: a 6.5 h LAN DNS outage during the Pi-hole cutover. The new Pi-hole node
  had no cached image and used Pi-hole for DNS, and the orchestration hop hung on an SSO prompt.
  The runbook rule that came out of it: **pre-pull on the target, run cutovers from a host that
  can't prompt, and add a deadman revert**.

## Alternatives considered

- **Join new servers to SQLite** — impossible; SQLite is single-server.
- **Rebuild the cluster from Git on mimir and restore data** — the purest GitOps answer, but a
  full outage of every service and a restore drill for 12 databases at once. In-place conversion
  plus a join kept almost everything up.
- **Re-point clients to mimir's own IP `.145`** — dozens of devices and configs, some unknown (house
  devices, bookmarks), plus the firewall's port-53 rule keyed on `.179`. The alias is one systemd
  unit.
- **kube-vip / a floating VIP across servers** — the right answer once there are three servers;
  overkill for one, and a VIP fails over between members that don't exist yet.
- **Keep Pi-hole on another node** — would also need the firewall rule changed, which the router
  key wasn't available for that night.

## When to revisit

- When **Odin** joins: decide between 1 and 3 etcd members (never 2), and move `.179` to a VIP
  (kube-vip or keepalived) that follows a healthy server instead of one box.
- When etcd snapshots get shipped to OMV MinIO (follow-up).
- If the OPNsense port-53 rule is changed to allow a different address or a group.
