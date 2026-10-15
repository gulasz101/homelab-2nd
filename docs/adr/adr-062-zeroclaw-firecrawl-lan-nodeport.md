# ADR-062: ZeroClaw reaches in-cluster Firecrawl over a LAN NodePort, and `http_request` is auto-approved

**Date:** 2026-10-15
**Status:** Accepted
**Deciders:** akadmin (Supreme Leader), Andrzej
**Project:** ZeroClaw (homelab agent runtime on the M1 Max)
**Related:** ADR-052 (Hindsight agent memory platform — same `<svc>-lan` exposure pattern), ADR-010 (self-host Firecrawl v2 and wire it to Open WebUI web search)

## Context

ZeroClaw runs as a container on the M1 Max, **outside** the cluster. It should be able to fetch
pages that a plain HTTP GET cannot — SPAs and client-rendered pages — instead of guessing at their
content.

The homelab already runs Firecrawl v2 in k3s, which renders JavaScript through its own Playwright
service. Two properties of that deployment decide this ADR:

1. Its API is **ClusterIP-only** (`api.firecrawl.svc:3002`), so a host outside the cluster cannot
   reach it at all.
2. Its public hostname `firecrawl.voitech.dev` sits behind **Cloudflare Access** (Zero Trust), so it
   is a human-facing door — not where machine traffic belongs.

## Decision

Expose the Firecrawl API to the LAN with a `<service>-lan` **NodePort** companion service, and let
ZeroClaw call it through its built-in `http_request` tool.

- `apps/firecrawl/firecrawl-api-lan-service.yaml` → `firecrawl-api-lan`, nodePort **30250**, selector
  copied from the existing ClusterIP Service. Defined in the repo, delivered by Flux.
- ZeroClaw: `[http_request] enabled = true`, `allow_private_hosts` stays **false** with the single
  node allowlisted via `allowed_private_hosts = ["192.168.1.179"]`, and `http_request` is added to
  `risk_profiles.homelab.auto_approve`.

This is the same shape already used for Hindsight (`hindsight-api-lan`, 30239), Honcho and
OpenViking: a fixed nodePort, no Ingress, no tunnel, LAN only.

## Consequences

**Positive**

- The agent gets real browser-grade fetching (JS rendering) without running its own Chrome on the
  Mac, and without an API key — Firecrawl runs with `USE_DB_AUTHENTICATION=false`.
- Follows an existing, understood pattern; the port is recorded in the repo alongside the nodePorts
  already claimed.
- Egress stays narrowly scoped: private hosts are still denied globally, and only this one address is
  exempted rather than flipping `allow_private_hosts` to `true`.

**Negative**

- The Firecrawl API becomes reachable by **any device on the LAN, unauthenticated**. That matches the
  posture of the other `-lan` NodePorts (qBittorrent, Jellyfin, Hindsight), and the LAN is a trusted
  home network — but it is a real widening.
- `http_request` is auto-approved, so the agent can issue HTTP requests without a human confirmation.
  Together with `allowed_domains = ["*"]` that is a potential exfiltration path for an agent reachable
  through Mattermost. Mitigated by the peer-group sender allowlist (one human UUID) and by the
  `supervised` risk profile elsewhere. Accepted knowingly.
- One more dependency: if Firecrawl is down, scraping fails and the agent must report it rather than
  silently returning junk.

## Alternatives considered

- **Cloudflare Access service token over the public hostname.** Rejected: adds a credential to manage
  and rotate, sends agent traffic out to the internet and back, and couples an internal capability to
  the public edge.
- **Reach the ClusterIP directly.** Not possible from outside the cluster without a proxy.
- **Deploy a Firecrawl MCP server in k3s.** Attractive — typed tool schemas instead of prompt-level
  HTTP — but it needs the same LAN exposure to be reachable from the Mac, so it is additive work, not
  a smaller change. Worth revisiting if prompt-level tool calling stays unreliable.
- **Run a browser inside the agent's container.** Rejected: heavy, and duplicates a capability the
  homelab already runs properly with Playwright, alerting and dashboards.
- **Bring the Firecrawl stack under this decision.** It is already Flux-managed via the `apps`
  Kustomization; nothing to change.

## Outcome (recorded same day)

**ZeroClaw cannot use this endpoint, and the exposure was kept anyway.**

Genuine 4 Argon (not just the throttled fallback) markdown-wraps every URL inside tool arguments,
and tool calling on this chain is prompt-level — so the argument never arrives intact and no browser
backend is reached. See ADR-062's related tracking note for the trace evidence.

The exposure is therefore **currently unused by its intended client**. It is retained because:

- it is not ZeroClaw-specific — any Mac-side client can use it;
- it matches the posture of the existing `-lan` NodePorts;
- tool calling may become viable if a future client uses native tool schemas (an MCP server in k3s
  would be the natural next shape, and would need the same LAN path).

If a tighter LAN is ever wanted, this is a legitimate candidate for removal — it is unused today.

## When to revisit

- Firecrawl moves to a public/SLO'd surface, or gains authentication we want agents to honour too.
- ZeroClaw moves into k3s as its own pod (a stated future goal) — the NodePort then becomes pointless
  and should be deleted in favour of the ClusterIP.
- Prompt-level tool calling proves unusable for scraping and a Firecrawl MCP server gets deployed.
- The LAN stops being treated as trusted.
