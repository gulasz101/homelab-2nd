#!/usr/bin/env node
// ADR-027 / H2-100: stop the browser's SSO headers from reaching the managed
// OpenCode server (:4096).
//
// OpenChamber proxies /api/* to OpenCode, which is a compiled Bun binary
// (Bun 1.4.2). Bun's HTTP parser enforces its own ~16 KiB total header limit and
// ignores Node's --max-http-header-size, so ADR-025's NODE_OPTIONS fix protects
// only the app hop (:3000). The auth cookie plus X-Auth-Request-* headers
// forwarded by oauth2-proxy breached Bun's limit, OpenCode answered HTTP 431,
// and the UI reported "agent.list failed (431)".
//
// Two changes to server/proxy-headers.js:
//   1. add 'cookie' to filteredRequestHeaders
//   2. strip every x-auth-request-* header by prefix (not just an enumeration,
//      so a future oauth2-proxy header name cannot slip through)
//
// A THIRD change is required in server/lib/opencode/proxy.js. The routes above
// (session list, SSE) go through collectForwardProxyHeaders, but the catch-all
// that serves agent.list is a plain http-proxy-middleware instance whose proxyReq
// hook forwards every browser header verbatim - it never calls the collector.
// Patching only proxy-headers.js therefore fixed /api/session but left
// /api/agent returning 431. Measured on the patched image: with a fat cookie,
// /api/session = 200 but /api/agent = 431.
//
// OpenCode needs none of these headers: the proxy injects its own auth headers
// through getOpenCodeAuthHeaders().
//
// Usage: node patch-proxy-headers.mjs <path-to-proxy-headers.js> [path-to-proxy.js>
// Exits non-zero (loudly) if the upstream shape changed and no patch can apply,
// so an OpenChamber upgrade that reshapes this file fails the build instead of
// silently shipping an unpatched image.

import { readFileSync, writeFileSync } from 'node:fs';

const target = process.argv[2];
if (!target) {
  console.error('usage: node patch-proxy-headers.mjs <path>');
  process.exit(2);
}

const MARKER = 'ADR-027';
const STRIP_ANCHOR = "  'accept-encoding',";
const COOKIE_ENTRY = "  'cookie',";
const HAS_ANCHOR = '    if (filteredRequestHeaders.has(normalizedKey)) continue;';
const PREFIX_GUARD = "    if (normalizedKey.startsWith('x-auth-request-')) continue;";

let source = readFileSync(target, 'utf8');

// Patch 1 target state. Note we deliberately do NOT exit early when
// proxy-headers.js is already patched: patch 2 lives in a different file and
// must still be applied (a re-run over a partially-patched image must converge).
const headersPatched = source.includes(MARKER);

if (headersPatched) {
  console.log(`[${MARKER}] proxy-headers.js already patched`);
} else {

// Preconditions: both anchors must be present exactly once, or we refuse to
// guess at a reshaped upstream file.
const countOf = (needle) => source.split(needle).length - 1;
const stripCount = countOf(STRIP_ANCHOR);
const hasCount = countOf(HAS_ANCHOR);
if (stripCount !== 1) {
  console.error(`[${MARKER}] expected exactly one ${JSON.stringify(STRIP_ANCHOR)}, found ${stripCount}`);
  process.exit(1);
}
if (hasCount !== 1) {
  console.error(`[${MARKER}] expected exactly one strip-test anchor, found ${hasCount}`);
  process.exit(1);
}
if (source.includes(COOKIE_ENTRY)) {
  console.error(`[${MARKER}] 'cookie' already in the strip list but no ${MARKER} marker - inspect manually`);
  process.exit(1);
}

// 1. add the browser auth cookie to the strip list
source = source.replace(
  STRIP_ANCHOR,
  `${STRIP_ANCHOR}\n  // ${MARKER}: the browser auth cookie must not reach the Bun-based OpenCode\n  // server. OpenCode authenticates via the proxy-injected headers, not this cookie.\n${COOKIE_ENTRY}`,
);

// 2. strip every x-auth-request-* header by prefix before the membership test
source = source.replace(HAS_ANCHOR, `${PREFIX_GUARD}\n${HAS_ANCHOR}`);

// Verify the result is exactly what we intended - never trust a blind write.
const checks = [
  [source.includes(COOKIE_ENTRY), "cookie missing from strip list"],
  [source.includes(PREFIX_GUARD), "x-auth-request- prefix guard missing"],
  [countOf(COOKIE_ENTRY) === 1, "cookie entry duplicated"],
  [countOf(PREFIX_GUARD) === 1, "prefix guard duplicated"],
  [countOf(HAS_ANCHOR) === 1, "original strip test lost"],
];
for (const [ok, why] of checks) {
  if (!ok) {
    console.error(`[${MARKER}] post-patch verification failed: ${why}`);
    process.exit(1);
  }
}

writeFileSync(target, source, 'utf8');
console.log(`[${MARKER}] proxy-headers.js patched and verified: cookie + x-auth-request-* stripped`);
} // end patch-1 (skipped when headers already patched)

// ---------------------------------------------------------------------------
// Patch 2: the catch-all /api proxy (server/lib/opencode/proxy.js).
// It forwards browser headers verbatim and never calls the collector, so it is
// the hop that actually serves agent.list.
// ---------------------------------------------------------------------------
const proxyPath = process.argv[3];
if (!proxyPath) {
  console.log(`[${MARKER}] proxy.js path not supplied, skipping catch-all patch`);
  process.exit(0);
}

let proxySrc = readFileSync(proxyPath, 'utf8');
if (proxySrc.includes(MARKER)) {
  console.log(`[${MARKER}] proxy.js already patched, nothing to do`);
  process.exit(0);
}

const HOOK_ANCHOR = `        proxyReq.setHeader('accept-encoding', 'identity');`;
const HOOK_REPLACEMENT = `${HOOK_ANCHOR}

        // ${MARKER}: the catch-all /api proxy forwards every browser header
        // verbatim. OpenCode is a Bun binary with a ~16 KiB TOTAL header limit
        // that NODE_OPTIONS cannot raise, so the browser's SSO cookie and
        // X-Auth-Request-* headers must not reach it. OpenCode authenticates via
        // the Authorization header injected above.
        for (const headerName of Object.keys(proxyReq.headers || {})) {
          const lower = headerName.toLowerCase();
          if (lower === 'cookie' || lower.startsWith('x-auth-request-')) {
            proxyReq.removeHeader(headerName);
          }
        }`;

const hookCount = proxySrc.split(HOOK_ANCHOR).length - 1;
if (hookCount !== 1) {
  console.error(`[${MARKER}] expected exactly one accept-encoding hook anchor in proxy.js, found ${hookCount}`);
  process.exit(1);
}

proxySrc = proxySrc.replace(HOOK_ANCHOR, HOOK_REPLACEMENT);

const proxyChecks = [
  [proxySrc.includes(MARKER), 'proxy.js marker missing'],
  [proxySrc.split("proxyReq.removeHeader(headerName)").length - 1 === 1, 'removeHeader loop missing or duplicated'],
  [proxySrc.includes(HOOK_ANCHOR), 'original accept-encoding hook lost'],
];
for (const [ok, why] of proxyChecks) {
  if (!ok) {
    console.error(`[${MARKER}] proxy.js post-patch verification failed: ${why}`);
    process.exit(1);
  }
}

writeFileSync(proxyPath, proxySrc, 'utf8');
console.log(`[${MARKER}] proxy.js patched and verified: catch-all /api strips cookie + x-auth-request-*`);