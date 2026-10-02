# ADR-027: Strip browser SSO headers before the internal OpenCode hop

- **Status:** Accepted
- **Date:** 2026-10-02
- **Relates to:** ADR-025 (Node header size), ADR-023/024 (OpenChamber 2 / OpenCode 2 upgrade)

## Context

On 2026-10-02 OpenChamber's UI failed with `agent.list failed (431)` and the
page reported "OpenCode could not load agents". Earlier the same day, ADR-025 had
fixed a 503 by raising the Node header limit to 64 KiB on the app container.

ADR-025 fixed only one hop. The request path has two:

```
Browser -> Cloudflare Tunnel -> oauth2-proxy :4180 -> openchamber :3000 (Node 22)
        -> proxy /api/* -> managed OpenCode :4096 (compiled Bun binary)
```

`opencode` 2.x ships as `@opencode/cli`, a **Bun 1.4.2** binary. Bun's HTTP
parser enforces its own ~16 KiB total header limit and ignores Node's
`--max-http-header-size`. Measured in the live pod:

| Hop | 8 KiB header | 12 KiB | 16 KiB | 32 KiB | 64 KiB |
|---|---|---|---|---|---|
| `:3000` Node (post ADR-025) | 200 | 200 | 200 | 200 | 431 |
| `:4096` Bun | 200 | 200 | **431** | **431** | **431** |

A minimal `node:http` server launched by the same Bun binary returned 431 for a
16 KiB header *with* `NODE_OPTIONS=--max-http-header-size=65536` exported —
proving the knob does not apply to this runtime. No Bun environment variable in
the binary governs header size.

The headers that breach it are ours: oauth2-proxy forwards the Authentik session
cookie and `X-Auth-Request-*` headers. OpenChamber's
`server/proxy-headers.js` strips `authorization`, `host`, and hop-by-hop headers
before proxying to OpenCode, but not `cookie` and not `x-auth-request-*`, so the
whole browser SSO header block was relayed verbatim to Bun. Reproduced with a
real in-pod session: `GET /api/agent` returned 200 with normal headers and 431
once the header block passed ~16 KiB.

## Decision

Patch OpenChamber's proxy header filter **in the image we build**
(`build/openchamber/patch-proxy-headers.mjs`, applied by the Dockerfile).
Two files are patched, and **both are required** — this was found the hard way,
after the first patch shipped in `2.1.0-r2` and still returned 431:

1. **`server/proxy-headers.js`** — add `cookie` to `filteredRequestHeaders` and
   strip every `x-auth-request-*` header by **prefix**, not by enumeration, so a
   future oauth2-proxy header name cannot slip past a fixed list. This covers the
   specialised routes (`/api/session`, the SSE streams).

2. **`server/lib/opencode/proxy.js`** — the catch-all `/api` proxy, which is the
   one that actually serves `agent.list`, is a plain `http-proxy-middleware`
   instance whose `proxyReq` hook forwards **every** browser header verbatim and
   never calls `collectForwardProxyHeaders`. A header-removal loop is injected
   next to the existing `accept-encoding` line so `cookie` and `x-auth-request-*`
   are dropped there too.

Measured on the partially-fixed image: with a fat cookie, `/api/session` returned
200 while `/api/agent` still returned 431 — which is precisely the reported
symptom. Patching only the collector looked correct and fixed nothing visible.

### The second trap: `proxyReq.headers` is an EMPTY object

Even with both files patched, `/api/agent` still returned 431. `http-proxy-middleware`
hands the `proxyReq` hook a request object whose header **accessors** work
(`setHeader`, `getHeader`, `removeHeader` — upstream uses those itself) but whose
`.headers` **property is an empty object**. A loop over `Object.keys(proxyReq.headers)`
therefore iterates nothing and strips nothing — no error, no warning, nothing in the logs.

Measured directly in the pod:

```
keysOfHeaders:    []                                <- empty
getHeadersSample: [connection, host, x-other,
                   x-auth-request-groups, cookie]    <- populated
```

The loop must iterate `proxyReq.getHeaders()` (with a `.headers` fallback):

```js
for (const headerName of Object.keys(proxyReq.getHeaders ? proxyReq.getHeaders() : proxyReq.headers || {})) {
  const lower = headerName.toLowerCase();
  if (lower === 'cookie' || lower.startsWith('x-auth-request-')) {
    proxyReq.removeHeader(headerName);
  }
}
```

This also explains why the *specialised* routes were never affected: they read
`req.headers` off the real Express request, not `proxyReq.headers`.

**Both traps were invisible to text-based tests.** The patch script's assertions
(text present, no duplicates, module parses) passed on both broken versions. Only
a test that pushes a real request through a real `http-proxy-middleware` and
inspects what arrived upstream can catch either one.

### Build-time proof: `test-proxy-strip.mjs`

`build/openchamber/test-proxy-strip.mjs` runs inside the image build. It extracts
the injected loop **verbatim** from the patched `proxy.js` (brace-matched, so it
cannot drift from what ships), executes it against a real `proxyReq`, sends a real
request through a real proxy to a real upstream, and asserts what arrived:

```
PASS  SSO cookie stripped  (got: null)
PASS  x-auth-request-groups stripped  (got: null)
PASS  x-auth-request-email stripped  (got: null)
PASS  non-SSO header preserved  (got: must-survive)
PASS  routing header preserved  (got: /home/openchamber/workspace)
PASS  proxy-injected auth preserved  (got: PRESENT)
```

If the strip regresses — including reverting to `.headers` — the **image build
fails** rather than shipping a silently broken proxy.

OpenCode needs none of these headers: the proxy injects its own auth headers via
`getOpenCodeAuthHeaders()`, and the patch's functional test asserts `Authorization`,
`accept`, and `x-opencode-directory` still arrive.

The patch is intentionally strict. It asserts each upstream anchor occurs exactly
once, applies anchored replacements, re-verifies its own output, and exits
non-zero if anything does not match — an OpenChamber upgrade that reshapes either
file **fails the build** rather than shipping an unpatched image. It is
idempotent per file, and converges on a partially-patched image (patching file A
does not skip file B). ADR-025's `NODE_OPTIONS=--max-http-header-size=65536`
stays: it correctly protects the public hop and is the right first line of
defence.

## Consequences

**Positive**

- Fixes the failure at its cause: OpenCode never sees headers it does not need.
- Immune to header-name drift, unlike an enumerated list.
- Silent upstream breakage becomes a build failure, not a 12:00 incident.
- Scoped to our own image build; no runtime config, no new env var, no CRD.

**Negative**

- A maintained patch layer over a vendored file. Every OpenChamber upgrade must
  re-run the patch; the build failure is the reminder.
- If a future OpenChamber version legitimately needs a forwarded `cookie` or
  `x-auth-request-*` for OpenCode, this patch must be revisited.
- The root cause of the growing SSO header block is **not** addressed here (see
  follow-up). This fix removes the symptom's trigger at this hop; the same
  growth can still pressure other services behind oauth2-proxy.

## Alternatives considered

- **Raise the limit on the Bun hop.** No knob exists in Bun 1.4.2 for header
  size; rejected as impossible, not merely unattractive.
- **Stop OpenChamber proxying to a separate OpenCode process** (in-process
  server). Removes the hop entirely, but is an upstream architecture change far
  beyond a homelab's control.
- **Slim the SSO header block** (trim Authentik group claims, or configure
  oauth2-proxy to forward fewer `X-Auth-Request-*` headers). Correct at the root,
  but it touches every service behind oauth2-proxy and would change behaviour
  for apps that read those headers. Tracked as a follow-up, not as this fix.
- **Patch the Deployment env only** (e.g. raise `NODE_OPTIONS` further). Already
  proven ineffective: the app hop is not the hop that fails.

## When to revisit

- On any OpenChamber upgrade: confirm the patch still applies (the build enforces
  this) and re-run the bloat probe through `:3000`.
- If the Authentik claim set or group count grows again, revisit the SSO block
  size itself — the follow-up that asks *why* it grew.
- If OpenChamber gains a supported setting for the forwarded-header filter,
  replace the patch with that setting and delete `patch-proxy-headers.mjs`.