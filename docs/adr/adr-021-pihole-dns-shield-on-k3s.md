# ADR-021: Pi-hole DNS shield on k3s (family discipline layer)

Date: 2026-09-27 · Status: Accepted · Task: H2-73 (subtask of H2-72 epic)

## Context

The Supreme Leader is applying *Atomic Habits* discipline to his digital environment: porn must
be unreachable on the home network at all times, and the dopamine apps (X, Reddit, Facebook,
Instagram, YouTube) must be unreachable on his devices 24/7 and on Sylwia's devices 21:00–07:00
daily. The escape hatch must be friction by design (leave the network, or ask Andrzej for a
time-boxed unblock). Communicators (WhatsApp, Signal, Messenger, Telegram) must keep working.

The home network is a flat `192.168.1.0/24` behind OPNsense on the Samsung NP300V5A router
(DHCP + DNS for the LAN, single Huawei AX3 AP). No VLANs in v1. DNS-based enforcement was chosen
over app-level controls because it is device-agnostic, works on locked-down clients, and
funnels every resolver decision through one choke point we control.

## Decision

- **Pi-hole runs on k3s** (namespace `pihole`), chart `MoJo2600/pihole` 2.38.0, app `2026.07.2`
  (FTL v6), Flux-managed HelmRelease, SOPS-encrypted admin secret, `local-path` PVC (2Gi) on the
  homelab-2nd NVMe.
- **DNS exposure:** single mixedService `NodePort 30053` (UDP+TCP, same port) with
  `externalTrafficPolicy: Local` so Pi-hole sees real client IPs — per-device group identity
  (W/S/P) depends on it. TCP+UDP on one nodePort is legal (same number, different protocols).
- **DHCP stays on OPNsense.** The chart's DHCP service is disabled. Device identity for groups
  comes from OPNsense DHCP static leases (H2-74), not from Pi-hole.
- **Upstream resolvers:** 1.1.1.1 / 1.0.0.1 directly from FTL (no local DoH sidecar — the
  upstream-privacy tradeoff is accepted for v1; the OPNsense redirect layer is what matters).
- **Admin UI:** never exposed publicly (no Cloudflare Tunnel). oauth2-proxy + Authentik SSO
  (`Pi-hole OIDC` provider + `Pi-hole` application, declared in the homelab SSO blueprint),
  reached at `http://192.168.1.179:30810` (LAN/Netbird only). Plain HTTP on this hop is
  accepted because the NodePort is unreachable from the internet and TLS-on-LAN adds cert
  friction for zero real risk.
- **Observability:** exporter sidecar (chart-managed) + chart PodMonitor (Prometheus selects all
  PodMonitors), PrometheusRule with **critical PiholePodNotReady** (Pi-hole down = home offline),
  AlertmanagerConfig → Mattermost (namespace-local webhook secret, Pattern A), Loki ruler rule,
  provisioned Grafana dashboard.
- **Homelab infrastructure exempt from the redirect (H2-74):** homelab-2nd, OMV, arr-box, t460
  keep direct DNS so crawls, container pulls, and overnight scraping never depend on Pi-hole.
  The M1 Max rides Pi-hole in the permissive group (noporn applies, social never blocks).
- **Default group for unknown devices:** noporn + 21:00–07:00 curfew.
- **v1 is DNS-layer only.** IP-layer blocks on OPNsense are a later phase if real bypassing
  happens (shared Meta IP ranges make IP-layer risky).

## Consequences

Positive:
- One enforcement point for the whole LAN; per-device rules without client software.
- Real client IPs preserved → per-device groups and meaningful query-log forensics.
- Pi-hole admin is SSO-gated and LAN-only; the DNS control plane cannot be reached from the
  internet or from a guest device without Authentik credentials.
- Curfew flips (H2-75) run as a GitOps k3s CronJob, not a hand cron.

Negative:
- **Pi-hole down = home offline.** Mitigations: critical alert to Mattermost + break-glass
  runbook (flip OPNsense DHCP DNS to its own resolver and clear redirects).
- k3s maintenance now has a home-network blast radius (single node, single replica).
- Work laptops behind corporate VPN tunnel DNS past the shield — accepted, never fight MDM.
- Browsers with DoH, Android Private DNS, and iCloud Private Relay must be disabled per device
  (client hygiene checklist in H2-76); OPNsense blocks DoT :853 + known DoH IPs + Relay canaries.

## Alternatives considered

- **AdGuard Home instead of Pi-hole:** nicer per-client UI, but the homelab convention, docs
  familiarity, and the curfew-via-API plan favour Pi-hole; AdGuard adds no capability we need.
- **Pi-hole on OPNsense directly:** keeps DNS off k3s but pollutes the router appliance,
  couples router maintenance to list/group changes, and violates the GitOps single source of
  truth (OPNsense config is not Flux-managed).
- **NextDNS (SaaS):** no self-hosted query log sovereignty; subscription; internet dependency
  for a home-core service. Rejected.
- **VLAN-per-person with subnet-based rules:** strongest topology-based identity, but requires
  AP VLAN support and a bigger change window; deferred (flat LAN + DHCP leases is sufficient
  because OPNsense owns the leases and can pin IPs).
- **Two Pi-holes for HA:** rejected for v1 — single-node k3s already means the node is the SPOF;
  break-glass runbook is the chosen resilience story.

## When to revisit

- If OPNsense gains a Pi-hole plugin worth migrating to (simpler box, fewer hops).
- If real bypassing via IP-hardcoded clients happens → add OPNsense IP-alias phase (H2-74 note).
- If k3s flapping becomes frequent → move DNS to OPNsense-local AdGuard as the failure-mode fix,
  keeping Pi-hole groups as the policy layer or retiring them.
- If ISP provides IPv6 (unknown at planning time) → extend redirect + blocks to v6 (H2-74 check).