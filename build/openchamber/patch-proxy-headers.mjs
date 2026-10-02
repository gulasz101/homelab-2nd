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
// OpenCode needs none of them: the proxy injects its own auth headers through
// getOpenCodeAuthHeaders(). This script is idempotent - re-running it is a
// no-op and still exits 0, so it is safe to layer onto repeated builds.
//
// Usage: node patch-proxy-headers.mjs <path-to-proxy-headers.js>
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

if (source.includes(MARKER)) {
  console.log(`[${MARKER}] already patched, nothing to do`);
  process.exit(0);
}

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