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
