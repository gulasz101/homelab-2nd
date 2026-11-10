# Hermes agents browse with Camofox and search/extract with Firecrawl over its LAN NodePort

- **Status**: Pending
- **Date**: 2026-11-09
- **Deciders**: Wojtek Gula (asked for browser access back, "make your best pick"); implemented by Claude Code
- **Project**: agent platform
- **Related**: [ADR-062](../adr-062-zeroclaw-firecrawl-lan-nodeport.md) (Firecrawl `firecrawl-api-lan` NodePort 30250), [ADR-073](../adr-073-hermes-runs-on-the-m1-air.md) and `pending/hermes-air-only-max-copy-retired.md` (Hermes on the M1 Air only), [ADR-079](../adr-079-launchagents-reach-lan-through-loopback-relays.md) (LaunchAgents and the LAN)

## Context

Hermes v0.22.7 moved Camofox out of core and into a catalog plugin (`hermes plugins install camofox`).
The update migration on the Air (2026-11-08 12:04) switched the core `browser` toolset off in every
profile that used Camofox, then failed to install the plugin (`uv lock exited 2: Failed to download
kittentts`). The plugin was installed later, but Szarik was left with neither the browser nor
Camofox, and the owner noticed the agents had lost the browser.

While checking that, a second fault turned up. Every profile's `FIRECRAWL_API_URL` was
`https://firecrawl.voitech.dev`, which sits behind Cloudflare Access. Machine calls got a `302` to
the Access login page instead of results, so `web_search`/`web_extract` were broken for every agent,
silently.

## Decision

The two tools do different jobs, so the agents get both:

1. **Interactive browsing (click, type, logins, JS apps, screenshots) goes through Camofox.** It's
   the `camofox` plugin toolset, served by the Camofox server on the M1 Max at
   `http://192.168.1.119:9377`. It's enabled in every profile that had it, and re-enabled for Szarik
   (`hermes -p szarik plugins enable camofox && hermes -p szarik tools enable camofox`). The default
   profile (Bill Cipher) keeps the core local browser, which works.
2. **Search and page-to-markdown extraction go through self-hosted Firecrawl, over the LAN NodePort
   from ADR-062.** `FIRECRAWL_API_URL=http://192.168.1.179:30250` in all six `.env` files, which
   bypasses Cloudflare Access. Firecrawl runs with `USE_DB_AUTHENTICATION=false`, so the
   existing key is harmless.
3. **Camofox no longer runs from Hermes's directory.** Its Node runtime was copied to
   `~/.local/share/camofox/node-26.7.0-darwin-arm64` on the Max, so the retired `~/.hermes` there
   could be removed (`pending/hermes-air-only-max-copy-retired.md`).

## Consequences

- Agents can read the web again (search, extract) and drive a real browser. Verified on 2026-11-09:
  Andrzej's `browser_navigate` reached example.com through Camofox, Szarik's did the same,
  Bill Cipher's local browser worked, and Andrzej's `web_search`/`web_extract` succeeded through
  the NodePort.
- The gateway (a LaunchAgent) reaches LAN hosts directly from Python: it got real HTTP responses
  from Camofox. The relay that ADR-079 requires for `mc` isn't needed here.
- Camofox is still a Max-side service. If the Max is off, `browser_*` fails while `web_search` and
  `web_extract` keep working. That split is deliberate.
- A future Hermes update can rerun migrations. After every `hermes update`, check
  `hermes -p <p> tools list --platform mattermost | grep -E "browser|camofox"` for each profile.

## Alternatives considered

- **Firecrawl only, with its `browser-firecrawl` cloud-browser plugin**: one dependency fewer, but
  that plugin targets Firecrawl's hosted browser product, and scrape/extract can't log in or
  click. Rejected as the only browser.
- **A Cloudflare Access service token for `firecrawl.voitech.dev`**: works from anywhere, but it
  adds a secret and a hop through Cloudflare for traffic that never leaves the LAN. Rejected while
  the Air and k3s share a LAN.
- **Run Camofox on the Air**: removes the dependency on the Max, but the Air is 16 GB and already
  runs the gateway plus Paperclip. Revisit if the Max goes away.

## When to revisit

- The Max is decommissioned or often off: move Camofox to the Air or into k3s.
- The Air leaves the LAN (travel, new site): switch Firecrawl to an Access service token.
- Hermes ships a supported browser backend that replaces the Camofox plugin.
