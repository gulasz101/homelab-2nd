Date: 2026-08-16
Status: Accepted
Supersedes: nothing
Superseded by: nothing

## Context

Hermes ships multiple profiles (`default`, `andrzej`, `careerpa`, `florian`, `ideogram-promptsmith`) on the Hermes host. Previously the `default` profile used DuckDuckGo (`web.backend: ddgs`) and other profiles had no consistent default web search backend. The self-hosted Firecrawl v2 instance runs inside the homelab k3s cluster at `api.firecrawl.svc.cluster.local:3002` and was originally deployed only for Open WebUI (see ADR-010).

This ADR addresses two questions:
1. Should all Hermes profiles use the self-hosted Firecrawl instance as the default web search backend?
2. If so, how should Hermes authenticate to the public tunnel that exposes Firecrawl, given that the cluster service is not reachable directly from the Hermes host?

## Decision

**All Hermes profiles use self-hosted Firecrawl at `https://firecrawl.voitech.dev` as their default web search backend. Public access is gated by a dedicated Cloudflare Tunnel plus a Cloudflare Access `Service Auth` policy that accepts a service-token. The Hermes Firecrawl provider is patched to inject `CF-Access-Client-Id` and `CF-Access-Client-Secret` headers on every SDK request.**

### Rationale

1. **Single source of truth for web search.** Using one self-hosted Firecrawl instance for both Open WebUI and Hermes removes the need for a second hosted API key and avoids vendor lock-in.
2. **No direct LAN/VPN path is required.** The Hermes host is not on the same LAN as `homelab-2nd` and Netbird is currently misconfigured, so the only reliable path is the public Cloudflare Tunnel.
3. **Cloudflare Access protects the public endpoint.** A Cloudflare Tunnel alone exposes the hostname to the internet. Adding Cloudflare Access with a `Service Auth` policy means only holders of the service token can reach the origin, even though Firecrawl's `/v1/search` currently accepts unauthenticated requests.
4. **Header injection is the minimal Hermes-side change.** The official Firecrawl Python SDK does not natively support Cloudflare Access service tokens. Patching `plugins/web/firecrawl/provider.py` to wrap the SDK's internal `HttpClient._prepare_headers` is the smallest change that works without maintaining a separate proxy.
5. **Defense in depth.** Even if the Firecrawl self-hosted `/v1/search` endpoint does not enforce the `FIRECRAWL_API_KEY`, the Cloudflare Access layer blocks unauthorized internet traffic, while Hermes still sends the API key where endpoints do enforce it.

## Consequences

### Positive

- All Hermes profiles share one self-hosted web search backend.
- No additional third-party API subscription needed for web search.
- Public exposure is protected by Cloudflare Access, not just obscurity.
- The patch is localized to one Hermes plugin file.

### Negative / Risks

- The Hermes patch is a local modification to core plugin code. Hermes updates may overwrite it; the patch must be reapplied or upstreamed.
- Cloudflare Access misconfiguration (e.g., using `Allow` instead of `Service Auth`) silently rejects service tokens with a login-redirect HTML page, which the SDK mis-reports as an obscure `AttributeError`.
- Firecrawl `/v1/search` does not enforce the API key when `USE_DB_AUTHENTICATION=false`, so inside the cluster any pod can still call search unauthenticated. This is acceptable because the cluster is the trust boundary, but it means the API key is only partially effective.

## Alternatives considered

| Option | Why rejected |
|---|---|
| Add a tiny local proxy on the Hermes host that injects CF headers, then point Hermes at `localhost` | Adds another moving part (proxy process/container) that must stay running and be debugged. |
| Patch the Firecrawl SDK directly in site-packages | Fragile; updates wipe it and it is harder to track than a provider patch. |
| Expose Firecrawl only via Netbird | Netbird is currently misconfigured and not reliable. |
| Rotate Firecrawl `USE_DB_AUTHENTICATION=true` | Not tested yet; may break Open WebUI or require migration. Left as future hardening. |
| Skip Cloudflare Access and rely only on the tunnel + API key | `/v1/search` ignores the key, so the endpoint would be publicly usable by anyone who discovers the hostname. |

## When to revisit

Revisit this ADR if any of the following become true:
- Hermes merges native Cloudflare Access service-token support, making the local patch unnecessary.
- Firecrawl is reconfigured with `USE_DB_AUTHENTICATION=true` and all endpoints enforce the API key, weakening the case for Cloudflare Access.
- Netbird or another private mesh becomes stable, allowing Hermes to reach Firecrawl without a public tunnel.
- Cloudflare Access is replaced with a different edge-security model (e.g., Authentik forward-auth at the tunnel).

## References

- ADR-010: Firecrawl v2 self-hosting for Open WebUI web search.
- Tracking note: `homelab/tracking/2026-08-16-hermes-firecrawl-default-search-engine.md`.
- Hermes provider patch: `~/.hermes/hermes-agent/plugins/web/firecrawl/provider.py`.
- Cloudflare Access docs: https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/
