// ADR-027 test: prove the injected strip actually REMOVES headers on the wire,
// against the REAL http-proxy-middleware the image ships.
//
// Why this test exists: v1 and v2 of the patch both looked correct and both did
// nothing, because proxyReq.headers is an empty object while getHeaders() is
// populated. A textual/structural assertion cannot catch that - only a test
// that sends a real request through a real proxy and inspects what arrived can.
//
// Usage: node test-proxy-strip.mjs <path-to-patched-proxy.js>
// The patched module is NOT imported (it pulls in the whole app); instead the
// exact hook body is extracted from it and executed against a real proxyReq.

import http from 'node:http';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const proxyFile = process.argv[2];
if (!proxyFile) {
  console.error('usage: node test-proxy-strip.mjs <path-to-proxy.js>');
  process.exit(2);
}
const require = createRequire(import.meta.url);
const { createProxyMiddleware } = require(
  '/home/openchamber/.npm-global/lib/node_modules/@openchamber/web/node_modules/http-proxy-middleware',
);

const src = readFileSync(proxyFile, 'utf8');

// Pull the injected loop verbatim out of the shipped file so this test can never
// drift from what is actually deployed. Brace-matched rather than regex-matched:
// the surrounding file contains other `Object.keys(proxyReq`-shaped lines and a
// lazy regex happily swallows them.
const startMarker = 'for (const headerName of Object.keys(proxyReq';
const start = src.indexOf(startMarker);
if (start === -1) {
  console.error('FAIL: could not find the ADR-027 strip loop in', proxyFile);
  process.exit(1);
}
let depth = 0;
let end = -1;
// Find the loop BODY's opening brace precisely: scan past the `Object.keys(...)`
// call to its matching close paren, then take the next `{`. Matching from the
// first `{` would instead hit the `|| {}` fallback and close instantly.
const keysOpen = src.indexOf('Object.keys(', start);
let paren = 0;
let afterCall = -1;
for (let i = keysOpen + 'Object.keys('.length - 1; i < src.length; i += 1) {
  if (src[i] === '(') paren += 1;
  else if (src[i] === ')') {
    paren -= 1;
    if (paren === 0) { afterCall = i; break; }
  }
}
const bodyStart = afterCall === -1 ? -1 : src.indexOf('{', afterCall);
for (let i = bodyStart === -1 ? src.length : bodyStart; i < src.length; i += 1) {
  if (src[i] === '{') depth += 1;
  else if (src[i] === '}') {
    depth -= 1;
    if (depth === 0) { end = i + 1; break; }
  }
}
if (end === -1) {
  console.error('FAIL: unbalanced braces in the ADR-027 strip loop');
  process.exit(1);
}
const loopSource = src.slice(start, end);
console.log('Extracted strip loop:\n' + loopSource + '\n');

const upstream = http.createServer((req, res) => {
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify({
    cookie: req.headers.cookie ?? null,
    groups: req.headers['x-auth-request-groups'] ?? null,
    email: req.headers['x-auth-request-email'] ?? null,
    other: req.headers['x-custom-bloat'] ?? null,
    directory: req.headers['x-opencode-directory'] ?? null,
    authorization: req.headers.authorization ? 'PRESENT' : null,
  }));
});
await new Promise((r) => upstream.listen(4997, '127.0.0.1', r));

let received = null;
const mw = createProxyMiddleware({
  target: 'http://127.0.0.1:4997',
  changeOrigin: true,
  on: {
    proxyReq: (proxyReq) => {
      // eslint-disable-next-line no-new-func
      new Function('proxyReq', loopSource)(proxyReq);
      proxyReq.setHeader('Authorization', 'Bearer injected-by-proxy');
    },
  },
});
const front = http.createServer((req, res) => mw(req, res, () => { res.writeHead(502); res.end(); }));
await new Promise((r) => front.listen(4996, '127.0.0.1', r));

await new Promise((resolve) => {
  const req = http.request(
    {
      host: '127.0.0.1',
      port: 4996,
      path: '/api/agent',
      headers: {
        cookie: 'session=abcdef123456; other=zzz',
        'x-auth-request-groups': 'admins,users',
        'x-auth-request-email': 'akadmin@voitech.dev',
        'x-custom-bloat': 'must-survive',
        'x-opencode-directory': '/home/openchamber/workspace',
      },
    },
    (res) => {
      let body = '';
      res.on('data', (c) => { body += c; });
      res.on('end', () => { received = JSON.parse(body); resolve(); });
    },
  );
  req.end();
});

front.close();
upstream.close();

const expectations = [
  ['SSO cookie stripped', received.cookie === null, String(received.cookie)],
  ['x-auth-request-groups stripped', received.groups === null, String(received.groups)],
  ['x-auth-request-email stripped', received.email === null, String(received.email)],
  ['non-SSO header preserved', received.other === 'must-survive', String(received.other)],
  ['routing header preserved', received.directory === '/home/openchamber/workspace', String(received.directory)],
  ['proxy-injected auth preserved', received.authorization === 'PRESENT', String(received.authorization)],
];

let failed = 0;
for (const [label, ok, actual] of expectations) {
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}  (got: ${actual})`);
  if (!ok) failed += 1;
}
console.log(failed === 0 ? '\nALL PASS' : `\n${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);