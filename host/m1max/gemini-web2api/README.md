# gemini-web2api on the Max — pinned, restartable, watched

The Gemini proxy (`ghcr.io/zexadev/gemini-web2api-go`) is the provider behind the `gemini4`
model alias. Every agent that needs Gemini goes through it, so it is not a toy container.
It runs under OrbStack on `m1max`, bound to `127.0.0.1:8083`; the Air reaches it through an
SSH local forward on the same port.

## Why this file exists

On 2026-11-03 the proxy was hung for ~34 hours and nothing noticed (GUL-896). Three causes:

1. the container had `restart=no`, so it did not come back like `zeroclaw` does;
2. it ran `:latest`, a moving target on a service the whole fleet depends on;
3. `zeroclaw_cookie_guard.py` decided health through `docker`, so a wedged daemon looked
   exactly like "nothing to do".

`docker-compose.yml` here is the source of truth for the container's runtime shape. Apply it
on the Max with:

```bash
cd ~/gemini2api && docker compose up -d
```

The live copy sits in `~/gemini2api/` (0700) with `container.env` (0600, `ADMIN_TOKEN` only,
copied from the 0600 credential file — never in this file, never in argv).

## Upgrading the pin

```bash
docker pull ghcr.io/zexadev/gemini-web2api-go:<new tag>
docker inspect --format '{{json .RepoDigests}}' ghcr.io/zexadev/gemini-web2api-go:<new tag>
# paste the sha256 into image: below, then
cd ~/gemini2api && docker compose up -d
```

Pin the **newest published release**, by digest. Before jumping several minors, read the
release notes; the proxy's own SQLite schema lives in the `gemini2api-data` volume, so take a
copy first (`docker cp gemini-web2api:/data ~/gemini2api-backup-$(date +%Y%m%d-%H%M%S)/data`).

## What "restart: unless-stopped" does and does not do

It brings the container back when the Docker/OrbStack engine restarts, and when the process
itself exits. It does **not** restart a container that was *manually* stopped — that is the
documented behaviour of every restart policy
(https://docs.docker.com/engine/containers/start-containers-automatically/), and it is why
`docker kill` looks like a policy failure. The watchdog covers that case explicitly: if the
container is `exited`, it runs `docker start` and says so.

## The watchdog

`~/.hermes/profiles/andrzej/scripts/zeroclaw_cookie_guard.py` (source on the Air, copied to the
Max; run from the Max over SSH by the `zeroclaw-gemini-cookie-guard` cron every 30 min). It is
silent while healthy and speaks on change:

- `docker info` with a 15 s ceiling — "cannot ask the engine" is reported as its own fault, and
  an unresolved fault is repeated every 6 h instead of going quiet after one message;
- one plain `GET /` with a 10 s ceiling, plus a restart attempt and a re-probe;
- runtime drift — warns if the live container is back on a moving tag or lost its restart policy;
- cookie pool re-import, paid-tier canary, and a canary attributed by request-log id (the `ts`
  field in that log drifts behind the host clock, so it is useless as a key).

## Health checks must use `GET /`

`GET /` is answered by the container itself: it proves the process is alive and asks Google
nothing. **Never put a chat completion on a timer.** A `POST /v1/chat/completions` probe costs a
real Google request and a cookie slot, and while the exit IP is blocked it *is* the thing that
re-blocks it — every probe resets the 120-min cooldown. Anything that ticks on a schedule (host
heartbeat, Uptime Kuma/Gatus, cron, a monitor in `homelab-2nd`) probes `GET /` and stops there.
This is not theory: a single 60 s chat probe, running from 2026-10-15 to 2026-11-09, produced
3 196 of the 3 257 `/sorry` blocks measured in GUL-1244. The one exception is the guard's canary
above — it runs on change, not on a clock.

## Reading a failure — three classes, and only one of them is Google's

`/admin/api/requests` (admin token) is the only honest source. Match on `model`, `status`,
`total_ms` and **`upstream_model`** — nothing else discriminates.

| what you see | what it means |
| --- | --- |
| `upstream_model: Nano Banana 2.1`, `200`, 10–44 s | a real image, generated and parsed correctly |
| `upstream_model: 3.5 Flash-Lite`, `502` | the account was served the **free tier**; no image was ever generated |
| no `upstream_model`, `502`, `total_ms: 0` | `direct IP slot full: concurrent limit reached` — the proxy refused it locally |

The third class is not Google and not the container. `/admin/api/config` has
`per_ip_concurrent: 2` (also `per_ip_rpm: 10`, `per_ip_rph: 80`), so two in-flight requests from
the exit IP block everything else instantly. One image render holds its slot for 20–43 s, which
means **two concurrent renders starve the whole fleet**, chat included. Clients that submit image
work concurrently should run that lane at concurrency 1.

### Two traps when reading this log

- **Duration proves nothing.** `total_ms` includes the artifact step's retry loop (~12 s of polling,
  six tries, 2 s apart) which only runs when the response carried no image. Failures log 3–28 s and
  real renders log 10–44 s: the bands overlap. A long job is not evidence that a picture was made.
- **The container clock is wrong, and it moves.** Its `ts` runs 200 s to 6 188 s behind the host and
  resyncs in steps (4 570 s at the last measurement). Re-measure before correlating a timeline:
  send one free `gemini-3.5-flash-lite` request, compare its `ts` with the host clock.

### The "two hour refill" is a bench, not a bucket

`proxy_cooldown_min: 120` in `/admin/api/config`. When Google rate-limits the direct IP, this proxy
parks that IP for 120 minutes and will not retry it until the bench expires. Every recovery that
looked like "~2 h of quiet refills the quota" is the bench expiring. So quiet time matters because
the proxy refuses to try — not because a bucket fills. Probing inside the bench both fails and
delays the answer; the watchdog fires one image probe when the tier returns.

## Avoiding `/sorry` — what the log showed on 2026-11-10

Measured over 7 days (`2026-11-03 23:52 → 2026-11-10 00:12`, 6 110 requests in `/admin/api/requests`):

| class | count | share |
| --- | --- | --- |
| `302 → google.com/sorry/index` | 3 257 | 53 % |
| `per_ip_rph` (our own 80/h cap) | 2 109 | 35 % |
| HTTP 200 | 605 | 10 % |
| `concurrent limit` (local slot) | 83 | 1 % |
| image artifact retrieval | 51 | 1 % |

Of the 605 `200`s, **395 (65 %) were canned error sentences** of 31, 54, 58 or 103 characters
("Sorry, something went wrong…", "I seem to be encountering an error…") — i.e. real answers were
about 3 % of all traffic. 4.27.1 detects those and retries instead of returning them; that alone
changes the numbers a lot more than any tuning does.

Two distinct causes produced the 3 257 blocks:

1. **A 1/minute health probe, not a client.** 5 585 requests with a ≤6-character prompt on
   `gemini-4-argon`, exactly one per minute, `2026-11-03 23:52 → 2026-11-09 10:09`. It accounts for
   **3 196 of the 3 257** `/sorry` hits (98 %) and 2 084 of the 2 109 `per_ip_rph` rejects. Because
   it never backed off, it re-blocked the IP every time the 120-minute bench expired: on 11-06 and
   11-07 the log shows an identical **40 hits / 48 minutes** cycle for 20 hours straight, ending in
   one 52.8-hour block. It stopped on 11-09 10:09 and the IP has been clean since.
2. **One genuine burst.** 19 `gemini-4-argon` requests in 6 minutes on 11-05 06:45–06:51
   (prompts 226–773 chars, the morning pipeline) with the IP fresh — first `/sorry` at 06:51:28.
   That is the one place upstream's "burst" rule fits.

Rules that follow, in order of value:

- **Never health-check by calling a real model.** `GET /` is free and does not touch the IP's
  request budget. A chat probe at 1/min is 1 440 requests/day of pure risk.
- **Treat a `302` as IP-level and stop.** It clears in ~106–121 min; anything sent inside it is
  wasted and re-arms the block. Back off for `proxy_cooldown_min` and do not retry earlier.
- **Count the canned `200`s, not just the non-`200`s.** A reply of 31/54/58/103 characters is a
  failure with a smiling face.

Image generation did **not** work at all in that window: 164 `gemini-image` attempts, 85 of them
logged `200`, but 83 of those were the 103-character canned sentence and 51 more died in artifact
retrieval — zero real renders. On 4.28.0 the same attempt now returns
`502 upstream returned a failure reply (inner[31] set)` after 3 retries, which is the honest
version of the same upstream failure: the image lane is broken account-side, not in this container.
It fails with `firefox_fingerprint` on and off, and with `web_channel` on and off, so neither the
fingerprint nor the protocol is the cause.


