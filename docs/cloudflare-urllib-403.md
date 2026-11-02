# Cloudflare 403s Python's `urllib`, and it is not a dead endpoint

**Rule: a 403 from an agent's Python client against a `*.voitech.dev` host is a client problem
until curl agrees.** Do not file, brief or conclude anything about the endpoint from that 403.
(GUL-785; the mistake already cost one wrongly-framed issue, [GUL-726], and one wrong premise in a
morning brief, [GUL-712].)

## What actually happens

Measured 2026-11-02 05:08 UTC, `GET /` against `chat.voitech.dev` (Cloudflare-fronted, same zone as
`paperclip.voitech.dev`), one request per client:

| Client | Status |
|---|---|
| `curl` 8.7.1, stock UA | 200 |
| Python `urllib.request` (UA `Python-urllib/3.15`) | **403** |
| `urllib` + `User-Agent: curl/8.7.1` | 200 |
| `requests` 2.34.2 (stock UA `python-requests/2.34.2`) | 200 |
| `httpx` 0.28.1 (stock UA `python-httpx/0.28.1`) | 200 |
| `http.client`, no `User-Agent` header at all | 200 |
| `curl -A 'Python-urllib/3.15'` | 403 |
| `curl -A 'Python-urllib/2.7'` / `'3.12'` | 403 |
| `curl -A 'python-urllib/3.15'` (lowercase `p`) | 200 |
| `curl -A 'libwww-perl/6.0'` | 403 |
| `curl -A 'homelab-probe/1.0 (+homelab-2nd http probe)'` | 200 |

The 403 body is Cloudflare's, not the app's: `server: cloudflare`, `content-type: text/plain`,
body `error code: 1010`.

## Verdict: the User-Agent string, not TLS, and not "Python"

- **Not TLS fingerprinting.** `http.client` and `urllib` run the same OpenSSL in the same
  interpreter and present the same ClientHello (same JA3/JA4). One gets 403, the other 200; the
  only difference is the header `urllib` adds.
- **Not Python.** `requests` and `httpx` are Python, use the same TLS stack and the same CA store,
  and both get 200 on their stock UAs.
- **The trigger is the literal signature `Python-urllib`** — matched case-sensitively (lowercase
  passes) and version-agnostically (2.7, 3.12, 3.15 all blocked). `libwww-perl` is blocked the same
  way; `Python/3.15`, `python`, `Go-http-client/1.1` and an empty UA are not.
- Zone-wide, not per-hostname: the same split reproduces on `paperclip.voitech.dev`,
  `grafana.voitech.dev` and `status.voitech.dev`.

## Which Cloudflare feature it is

`error code: 1010` is documented as *"the owner of this website has banned your access based on
your browser's signature"*, and Cloudflare's own troubleshooting page names this exact case:

> Browser Integrity Check … treats as a non-browser client (for example, the default Python
> `urllib` user agent).

Browser Integrity Check (BIC) is a **zone setting, enabled by default**, not a rule written in this
repo — this repo contains no Cloudflare zone/WAF configuration at all, so there is nothing here to
point at. To date the setting has not been read back from the API: the account token
(`~/.cloudflare-api.sops.yaml`, scopes: Tunnel, DNS Edit on `voitech.dev`, Zone Read, Access Apps and
Policies) answers

- `403 9109 Unauthorized to access requested resource` on `/zones/<id>/settings/*`,
- `403 10000 Authentication error` on `/zones/<id>/rulesets`,
- `authz` on GraphQL `firewallEventsAdaptive`.

Confirmation needs a token with **Zone Settings: Read** and **Zone WAF: Read** (or one dashboard
look at Security → Settings → Browser integrity check). Until then the evidence above is
behavioural: only a UA signature block produces this split, and 1010 is BIC's error code.

**Recommendation: leave BIC on.** It protects the public hostnames, and disabling it to save agents
one header is the wrong trade. Fix the client instead. If a future host genuinely needs to serve
non-browser clients, add a *skip* custom rule scoped to that hostname — that is a zone change and
needs the owner.

## The fix

Preferred — use the helper, which sends a descriptive UA:

```sh
scripts/probe-url.sh https://chat.voitech.dev/
UA='my-app/1.0' scripts/probe-url.sh https://paperclip.voitech.dev/
```

If you must use Python's standard library, name the client:

```python
import urllib.request

req = urllib.request.Request(url, headers={"User-Agent": "homelab-agent/1.0 (+homelab-2nd)"})
urllib.request.urlopen(req, timeout=15)
```

Either way: read `curl`'s answer before you conclude the service is down. `requests` and `httpx`
need no changes — they were never affected.

## Reproducing it

```sh
curl -s -o /dev/null -w '%{http_code}\n' https://chat.voitech.dev/                      # 200
curl -s -o /dev/null -w '%{http_code}\n' -A 'Python-urllib/3.15' https://chat.voitech.dev/  # 403
scripts/probe-url.sh https://chat.voitech.dev/                                          # 200
```

[GUL-712]: https://paperclip.voitech.dev/GUL/issues/GUL-712
[GUL-726]: https://paperclip.voitech.dev/GUL/issues/GUL-726
