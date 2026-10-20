# ADR-074: Agent orchestration control plane on the M1 Air (Paperclip)

**Date:** 2026-10-20
**Status:** Accepted
**Deciders:** Wojtek Gula; implemented by Hermes Agent (H2-334)
**Project:** agent platform
**Related:** H2-334, ADR-073 (Hermes on the Air), `paperclip-gitops` skill

## Context

Hermes now lives on the M1 Air (`paperclip`, `192.168.1.191`) after ADR-073. The next piece is a
permanent orchestration control plane for agent work. Itsaplan still holds open tasks, but the
long-term board is Paperclip.

The Air is an always-on, low-power appliance. Durable compute and storage belong on the k3s
cluster (`homelab-2nd`) and OMV MinIO, not on the Air's local SSD.

## Decision

1. **Paperclip runs native on macOS on the Air.** It is a Node.js monorepo; adding a VM or k3s
   node on the Air would only duplicate the runtime the cluster already provides.
2. **Durable state leaves the Air.**
   - Postgres: CNPG cluster `paperclip-db` on `homelab-2nd` (PG 17, superuser access, SOPS secrets).
   - Object storage: OMV MinIO bucket `paperclip` with a dedicated user/policy.
   - WAL archiving and base backups to the same MinIO bucket from day one.
3. **Secrets are SOPS-encrypted with age.** The age private key stays in the password manager and on
   the Air at `~/.keys/age-homelab-2nd.txt`. The Paperclip master key and MinIO credentials never
   touch the repo or chat logs.
4. **Public ingress is a Cloudflare Tunnel.** `paperclip.voitech.dev` proxies to
   `http://192.168.1.191:3100`; no router ports are opened. Only `authenticated` +
   `private` deployment mode is allowed behind the tunnel.
5. **Agent bridge uses the official `hermes_gateway` adapter.** Hermes exposes its API server on
   `127.0.0.1:8642`; Paperclip wakes Andrzej on heartbeats, and Hermes posts results back to
   Paperclip's API.
6. **Itsaplan keeps running until its open tasks are drained.** No Itsaplan webhook is disabled
   prematurely; no Max gateway is restarted.

## Consequences

- The Air stays a lightweight agent host; the cluster carries the durability burden it is built for.
- A single Paperclip master key guards all encrypted secrets. Losing it means re-seeding everything;
  it lives only in the password manager and SOPS-encrypted config.
- The Netbird route from the Air to k3s services (`10.43.0.0/16`) is load-bearing. Without
  masquerade on the routing peer, Postgres replies cannot reach the Netbird overlay.
- Cloudflare Tunnel failure hides Paperclip from the internet but leaves LAN access intact.
- Hermes and Paperclip share the same host, so the `hermes_gateway` adapter can use `127.0.0.1`.
  Moving Hermes off the Air would require repointing the adapter.
- Itsaplan and Paperclip coexist; tasks must be tracked in one place at a time to avoid duplicate
  agent work.

## Alternatives considered

- **Lima / k3s on the Air.** Rejected. Paperclip is a Node app; a VM adds container runtime, node
  join, storage, and tunnel complexity with no durability gain because the state still has to leave
  the Air.
- **Staying on the M1 Max.** Rejected. The Max is a daily desktop and is intentionally retired as
  the Hermes/Paperclip host. The Air is the always-on appliance.
- **Asahi Linux on the Air.** Rejected. Linux on Apple Silicon is still a side project; macOS keeps
  Homebrew, LaunchAgent, Hermes, and the existing Apple-Silicon local-model stack working without
  porting.

## When to revisit

- If the Air is replaced or its user/path changes, re-check the Hermes symlink (ADR-073) and
  Paperclip environment paths.
- If Netbird routing to k3s becomes unreliable, fall back to a NodePort or LoadBalancer for
  Postgres and update `DATABASE_URL`.
- If Itsaplan is fully drained, remove Itsaplan webhooks and retire its agent lanes.
- If Cloudflare Tunnel is replaced by a reverse proxy on the router, revisit the `private` exposure
  setting.
