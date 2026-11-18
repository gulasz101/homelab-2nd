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

`host/m1max/gemini-web2api/guard.py` in this repo — the tracked copy; the copy that actually runs
is `~/homelab/gemini-web2api-guard/guard.py` on the Max, together with its state
(`cookie_guard_state.json`) and its admin-token file (`gemini2api.env`, mode 0600, holding
`ADMIN_TOKEN` and `GEMINI_WEB_API_KEY`; neither value is ever in this repo). The
`zeroclaw-gemini-cookie-guard` cron on the Air runs `zeroclaw_cookie_guard_remote.sh`, which SSHes
to the Max and executes that file. It is silent while healthy and speaks on change:

- `docker info` with a 15 s ceiling — "cannot ask the engine" is reported as its own fault, and
  an unresolved fault is repeated every 6 h instead of going quiet after one message;
- one plain `GET /` with a 10 s ceiling, plus a restart attempt and a re-probe;
- runtime drift — warns if the live container is back on a moving tag or lost its restart policy;
- cookie pool re-import, paid-tier canary, and a canary attributed by request-log id (the `ts`
  field in that log drifts behind the host clock, so it is useless as a key).

**Do not move it back under `~/.hermes`.** ADR-128 retired Hermes on the Max, and `~/.hermes`
there is a read-only tombstone *file*: the guard ran from that path for 30 ticks and failed with
`[Errno 20] Not a directory` (GUL-1279). `host/m1max/tests/gemini-guard-check.sh` now fails CI if
any non-comment line reaches under `~/.hermes`, so a silent 30-tick outage cannot happen that way
again. `GUARD_DIR` still overrides the directory for tests, as do `GUARD_STATE`, `GUARD_DOCKER`,
`GUARD_PROXY` and `GUARD_SKIP_COOKIES`.

Run it by hand (from the Air, or on the Max directly):

```
ssh m1max 'python3 ~/homelab/gemini-web2api-guard/guard.py'    # empty output = healthy
GUARD_SKIP_COOKIES=1 ssh m1max 'python3 ~/homelab/gemini-web2api-guard/guard.py'   # availability only
```

The guard deliberately **pauses cookie re-import while the account is `degraded`**: a throttled
account answers `429`, the candidate gets deleted again, and that churn feeds the throttle. When a
human has just logged in again in Firefox and does not want to wait for the cooldown, use the
hand-import helper, which is the same add -> `/check` -> keep-or-drop flow without the pause:

```
scp host/m1max/gemini-web2api/manual-import.py m1max:~/homelab/gemini-web2api-guard/   # after editing
ssh m1max 'python3 ~/homelab/gemini-web2api-guard/manual-import.py --list'   # pool only
ssh m1max 'python3 ~/homelab/gemini-web2api-guard/manual-import.py'          # import + retire older
```

It prints cookie counts, entry ids and the `/check` verdict — never a cookie or a token. Exit `0`
imported and validated, `2` candidate failed `/check` (dropped, old pool untouched), `1` nothing to
import.

## Health checks must use `GET /`

`GET /` is answered by the container itself: it proves the process is alive and asks Google
nothing. **Never put a chat completion on a timer.** A `POST /v1/chat/completions` probe costs a
real Google request and a cookie slot, and while the exit IP is blocked it *is* the thing that
re-blocks it — every probe resets the 120-min cooldown. Anything that ticks on a schedule (host
heartbeat, Uptime Kuma/Gatus, cron, a monitor in `homelab-2nd`) probes `GET /` and stops there.
This is not theory: a single 60 s chat probe, running from 2026-10-15 to 2026-11-09, produced
3 196 of the 3 257 `/sorry` blocks measured in GUL-1244. The one exception is the guard's canary
above — it runs on change, not on a clock.

## Verdicts — ok, degraded, unknown, and why inconclusive is a fault

The canary has exactly three verdicts, and `entitlement` must be one of them:

- **ok** — the newest canary request was served by a paid model (`4 Argon`, `3.1 Pro`,
  `3.8 Flash`). This is the only state that may stand as green.
- **degraded** — the request was served, but by a cheaper model (usually `3.5 Flash-Lite`). The
  account is being rate-limited; the guard starts the cumulative degraded clock and escalates on
  capacity, not on the cookie.
- **unknown** — the sample produced **no verdict**: the chat request failed or timed out, the log
  row never arrived, or the log named a cause that makes a live probe pointless. `unknown` is a
  fault, not a neutral placeholder. It refreshes `checked_at` and `last_sample_at`, drops
  `healthy_since`, and never leaves a previous `ok` standing. It deliberately does **not** credit
  or clear `degraded_accum_s`, because an inconclusive sample is evidence of neither degradation
  nor recovery.

A single inconclusive sample speaks one fault message. **Two consecutive** inconclusive samples
escalate once, naming the count — waiting for a verdict that never comes is how the guard stayed
silent through a full outage.

Classification is **log-first**: the guard reads `/admin/api/requests` before it sends anything.
If the newest canary row already names the cause, no chat request goes out:

| newest canary row says | verdict |
| --- | --- |
| `no SNlM0e in page (cookie expired or not signed in)` | cookie is dead — re-export it in Firefox; `unknown` |
| `Client.Timeout`, `context deadline exceeded`, `request canceled` | model is slow — patience, not a re-login; `unknown` |
| `direct IP slot full` / a local refusal | the lane is saturated, not Google; retry later |
| anything ambiguous or absent | fall back to one live chat probe |

**Timeouts: the wrapper and the canary.** The canary's own `POST /v1/chat/completions` has a
**120 s** ceiling. The Hermes cron wrapper that SSHes to the Max kills the whole guard run, so its
outer ceiling must be **longer** than the guard's 120 s canary timeout plus the rest of the
checks. If the wrapper kills at the same 120 s, a slow but working model looks inconclusive and a
healthy session produces a false alarm. Keep the two in agreement: either raise the wrapper above
the guard's own ceiling, or have the guard report its partial result before it is killed — never
both.

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

## Rotation model — who owns `__Secure-1PSIDTS`

Measured 2026-11-11 on `4.28.0` (digest `sha256:9aaab38e…`) from the container log and from
`internal/app/rotate.go`. This is the section that answers "why does the session die at ~90 min".

**The proxy rotates by itself, unconditionally.** `rotateAllAccounts` walks every `enabled`
account on a ~10-minute timer. There is **no config switch to turn rotation off**: `Config` has
`gemini_bl_auto`, `firefox_fingerprint`, `web_channel` and no rotate field at all. "Disable proxy
rotation" therefore means patching and rebuilding the image — a fork, not a setting.

Each round does two independent things:

| path | request | renews |
| --- | --- | --- |
| sentinel | `POST accounts.google.com/RotateCookies` with `[000,"-0000000000000000000"]` | `__Secure-1PSIDTS`, `__Secure-3PSIDTS` — the ~30-minute ticket (the success line also lists `__Secure-1PSIDCC`) |
| iframe | `GET RotateCookiesPage` → `init('<id>',658,…,600)` → `POST [658,"<id>"]` | the `SIDCC` family |

Only the first one keeps the login alive. Live evidence, account `#12370`, imported
2026-11-10 23:00:31:

- sentinel path: succeeded on **every** round for 8 h+ (`刷新了 __Secure-1PSIDTS, __Secure-3PSIDTS, __Secure-1PSIDCC`), tier stayed `4 Argon`;
- iframe path: **HTTP 429 on every round** since 23:08, still 429 eight hours later, and the account never degraded.

So a 429 on the `SIDCC` path is **noise, not the death rattle**. GUL-1313's timeline read the
11:38 `RotateCookies → 429` as the start of the death; the log says that path 429s permanently and
the account is fine anyway. The real signature is the *sentinel* path returning **HTTP 401
(device-bound)** — that is what happened to `#12368` at 13:18 and `#12369` at 22:45 on 2026-11-10,
with the downgrade following inside the hour.

**The rule that follows: one owner of the pair.** The proxy is the owner — it is the component that
survives, and rotation is exactly what it is designed to do. The Firefox profile is a *login
source*, not a co-owner: it is opened to sign in, the guard imports its current pair, and from that
moment the proxy's rotated copy is the live one. A second live Google session on the same pair (the
profile sitting on `gemini.google.com`, or any Google property that rotates the same cookies)
creates the divergence, and Google punishes divergence with 401 and then a downgrade.

Open, and being measured: whether a running-but-idle Firefox profile still rotates. The 2026-11-10
23:06 → 2026-11-11 07:14 window (8 h, Firefox running, `entitlement: ok`, `degraded_accum_s: 0`)
suggests it does not. 24 h of that window is the acceptance test for GUL-1315.

Two supporting facts, both cheap:

- the guard's cookie fingerprint excludes `__Secure-1PSIDTS` and `__Secure-1PSIDCC` on purpose — a
  rotation changes them without meaning "a fresh session is available", so hashing the whole string
  re-imports on every tick and burns a `/check`;
- `gemini_bl_auto: true` lets the BL token follow Google's build. The BL auto-update at
  2026-11-10 11:34:52 sits four minutes before that day's tier drop. Unexcluded suspect, not proof;
  pinning it (`false`, BL `…20261007.01_p0`) removes the variable at the cost of a stale-client
  failure if Google retires that build.



