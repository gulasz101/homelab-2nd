---
name: homelab-http-probes
description: >
  Use before concluding anything from an HTTP status while probing a *.voitech.dev (Cloudflare)
  host: a 403 from Python's default urllib client is a client problem until curl agrees.
---

# Probing Cloudflare-fronted hosts from an agent

**A 403 from Python's default HTTP client against a `*.voitech.dev` host is a client problem until
curl agrees.** Never turn that 403 into "the endpoint is dead", a brief or an issue.

## Why

Cloudflare's Browser Integrity Check — a zone setting, on by default — blocks non-browser
User-Agent signatures and answers `HTTP 403` with the body `error code: 1010`. `Python-urllib/<ver>`
is on that list. It is **not** TLS fingerprinting: `http.client` from the same interpreter presents
the same ClientHello and gets 200. `requests` and `httpx` also pass on their stock UAs; only
`urllib` is affected. The block is zone-wide, case-sensitive, and version-agnostic.

Measured table, verdict and the Cloudflare-side finding: `docs/cloudflare-urllib-403.md` in
`homelab-2nd`.

## Do

```sh
scripts/probe-url.sh https://chat.voitech.dev/   # curl wrapper, descriptive UA, prints status
```

```python
import urllib.request

req = urllib.request.Request(url, headers={"User-Agent": "homelab-agent/1.0 (+homelab-2nd)"})
urllib.request.urlopen(req, timeout=15)
```

## Do not

- Do not report a host as down because a Python client got 403. Run curl first; if curl also fails,
  then it is the endpoint.
- Do not disable Browser Integrity Check zone-wide to fix a client. Fix the client header.
