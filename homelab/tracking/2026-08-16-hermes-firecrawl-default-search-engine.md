# 2026-08-16 — Hermes Firecrawl as default web search engine

## Goal

Make the self-hosted Firecrawl instance on `homelab-2nd` the default web search backend for **all** Hermes profiles: `default`, `andrzej`, `careerpa`, `florian`, `ideogram-promptsmith`.

## Background

- Firecrawl v2 is self-hosted in the k3s cluster, internal service `api.firecrawl.svc.cluster.local:3002`.
- Open WebUI already uses it for web search (see `2026-08-05-firecrawl-v2-selfhost-plan.md`).
- Hermes was using DuckDuckGo (`ddgs`) in the `default` profile and had no consistent default elsewhere.
- The Hermes host is not on the homelab LAN; Netbird is misconfigured. The only reliable access path is the public Cloudflare Tunnel `firecrawl.voitech.dev`.

## What was changed

### 1. Cloudflare Tunnel for public access

Resources committed to `gulasz101/homelab-2nd` under `apps/firecrawl/`:

- `firecrawl-tunnel-token.sops.yaml` — SOPS-encrypted tunnel token secret.
- `firecrawl-tunnel-ingress-configmap.yaml` — documents hostname mapping.
- `cloudflared-firecrawl-deployment.yaml` — `cloudflared` pod (1 replica, 10m CPU request after initial 50m caused Pending due to CPU saturation).

Added to `apps/kustomization.yaml` and reconciled via Flux.

### 2. Hermes profile config updates

All five `config.yaml` files now have:

```yaml
web:
  backend: firecrawl
  search_backend: firecrawl
```

Files updated:
- `~/.hermes/config.yaml` (default)
- `~/.hermes/profiles/andrzej/config.yaml`
- `~/.hermes/profiles/careerpa/config.yaml`
- `~/.hermes/profiles/florian/config.yaml`
- `~/.hermes/profiles/ideogram-promptsmith/config.yaml`

### 3. Hermes Firecrawl provider patch

File: `~/.hermes/hermes-agent/plugins/web/firecrawl/provider.py`

Added two new env vars and logic to inject Cloudflare Access service-token headers:

```python
def _get_cloudflare_access_headers() -> Dict[str, str]:
    client_id = (os.getenv("CF_ACCESS_CLIENT_ID") or "").strip()
    client_secret = (os.getenv("CF_ACCESS_CLIENT_SECRET") or "").strip()
    if client_id and client_secret:
        return {
            "CF-Access-Client-Id": client_id,
            "CF-Access-Client-Secret": client_secret,
        }
    return {}


def _apply_cloudflare_access_headers(client: Any) -> None:
    """Patch the Firecrawl SDK's internal HttpClient(s) to send CF-Access headers."""
    ...
```

Called immediately after `_get_firecrawl_client()` constructs the client. The SDK uses `requests` and exposes `HttpClient` instances on the v1/v2 clients, so we wrap `HttpClient._prepare_headers` to add the CF headers.

Also updated the provider's `get_setup_schema()` env var list to document the new options.

### 4. `.env` configuration

`~/.hermes/profiles/andrzej/.env` updated with:

```bash
FIRECRAWL_API_URL=https://firecrawl.voitech.dev
FIRECRAWL_API_KEY=...
CF_ACCESS_CLIENT_ID=...
CF_ACCESS_CLIENT_SECRET=...
```

The Firecrawl API key was fetched from cluster secret `firecrawl/firecrawl-api-key`.

## Problems encountered and how they were solved

### Problem 1: `/v1/search` ignores the API key

**What happened:**
Unauthenticated and wrong-key curl requests to `https://firecrawl.voitech.dev/v1/search` both returned HTTP 200.

**Why:**
The Firecrawl deployment has `USE_DB_AUTHENTICATION=false`. In this mode, the app validates the `Authorization` header only on some endpoints. `/v1/search` appears to skip it.

**Fix:**
Used Cloudflare Access as the real gate. The API key is still sent for endpoints that do check it (e.g., `/v1/scrape`).

### Problem 2: Cloudflare Access policy `Allow` rejected the service token

**What happened:**
First curl test with service-token headers returned `HTTP/2 302` and an HTML login page. The location JWT contained `service_token_status:false`.

**Why:**
For service tokens, Cloudflare Access expects the policy **Action** to be `Service Auth`, not `Allow`. An `Allow` policy with only service-token selectors still requires an identity-provider login.

**Fix:**
Switched the `firecrawl.voitech.dev` Access policy from `Allow` to `Service Auth`.

### Problem 3: Hermes error message was misleading

**What happened:**
When the SDK received the HTML login page, it failed to parse JSON, then crashed inside its own error handler: `'NoneType' object has no attribute 'status_code'`.

**Why:**
The Firecrawl SDK's error handler does `getattr(err, "response")`, which is `None` for `requests.exceptions.JSONDecodeError`.

**Fix:**
Not fixed on the SDK side. Once the Access policy was correct, the endpoint returned JSON and the SDK worked normally.

### Problem 4: `andrzej` profile config couldn't be patched directly

**What happened:**
Patching `~/.hermes/profiles/andrzej/config.yaml` directly is blocked because it's the active profile.

**Fix:**
Used `hermes config set --profile andrzej web.search_backend firecrawl` instead.

### Problem 5: Node CPU was too saturated for the tunnel pod

**What happened:**
Initial `cloudflared-firecrawl` deployment requested 50m CPU and had 2 replicas. Pod stayed `Pending` because node CPU requests were at 99%.

**Fix:**
Reduced to 1 replica and 10m CPU request, then force-pushed the amended commit.

## Verification

1. **Tunnel pod:**
   ```bash
   ssh -q homelab-2nd 'sudo kubectl get pods -n firecrawl -l app.kubernetes.io/name=cloudflared-firecrawl'
   ```
   Result: `Running`.

2. **Public hostname resolves and routes:**
   ```bash
   curl https://firecrawl.voitech.dev
   ```
   Result: routes through tunnel (404 on `/` because no route).

3. **Direct curl with service-token headers after Service Auth fix:**
   ```bash
   curl -sS -D /tmp/fc-cf-headers2.txt -o /tmp/fc-cf-body2.bin \
     -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
     -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer $FIRECRAWL_API_KEY" \
     -d '{"query":"firecrawl self hosting","limit":2}' \
     https://firecrawl.voitech.dev/v2/search
   ```
   Result: `HTTP/2 200`, `content-type: application/json; charset=utf-8`, body is a Firecrawl search response.

4. **Hermes provider smoke test:**
   ```python
   import os, sys, json
   sys.path.insert(0, "/Users/wojciechgula/.hermes/hermes-agent")
   from plugins.web.firecrawl.provider import FirecrawlWebSearchProvider, _get_firecrawl_client

   provider = FirecrawlWebSearchProvider()
   print(provider.is_available())
   client = _get_firecrawl_client()
   print(client)
   print(json.dumps(provider.search("firecrawl self hosting", limit=2), indent=2, default=str))
   ```
   Result:
   - `provider.is_available()` → `True`
   - `_get_firecrawl_client()` → succeeds
   - `provider.search(...)` → returns `success: true` with real web results.

## Still to do

- ~~Populate the same four env vars in the remaining profile `.env` files~~ — done via `~/Sync/sync-firecrawl-env.sh`, all gateways restarted.
- Run a quick web search from each profile to confirm (user to verify).
- Consider upstreaming the Cloudflare Access header patch to Hermes, or guard against future Hermes updates overwriting the local patch.

## References

- ADR-015: `docs/adr/adr-015-hermes-firecrawl-cloudflare-access.md`
- Firecrawl v2 self-host plan: `homelab/tracking/2026-08-05-firecrawl-v2-selfhost-plan.md`
- ADR-010: `docs/adr/adr-010-firecrawl-v2-selfhost-openwebui-websearch.md`
- Cloudflare Access service tokens: https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/
