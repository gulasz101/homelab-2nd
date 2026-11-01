# ADR: RiffRadar's game is public on purpose, its admin panel is not

- **Status**: Pending
- **Date**: 2026-11-01
- **Issue**: GUL-757 (parent GUL-749 — "drop Cloudflare auth" for the demo)
- **Supersedes**: decision 2 of ADR-102 (hostname-wide Cloudflare Access in front of the demo). Decisions 1 (SQLite on `local-path` + nightly MinIO backup), 3 (private image) and 4 (observability) of ADR-102 stand.
- **Related**: ADR-101/ADR-103 (private image, platform pull credential), ADR-032 (tunnels created via the Cloudflare API), ADR-005 (per-namespace observability), `apps/riffradar/riffradar-tunnel-ingress-configmap.yaml`, `apps/riffradar/riffradar-deployment.yaml`, tracking note `homelab/tracking/2026-11-01-riffradar-public-game-admin-gated.md`

## Context

ADR-102 put Cloudflare Access in front of the whole hostname and said out loud that "a 200 on
the hostname without an Access session counts as a bug, not a feature". It was written for two
people and one copyrighted song tab.

The owner changed that on 2026-11-01: his wife cannot get past the Access login, and he does not
mind strangers seeing the game. "Open the game" is therefore the new requirement, not an accident.

Three measured facts shaped the decision:

1. **The admin panel lives on the same hostname.** `apps/api/src/index.ts`:28 mounts the admin API
   at `/api/admin` and `:39` serves the admin SPA at `/admin/*`. Removing Access from the hostname
   would publish an admin login form to the internet.
2. **The admin credential was the seeded demo password, and it re-armed itself.** `admin_users`
   held one row, `admin` with `must_reset_password = 1`. Worse: the Deployment set
   `SEED_ON_START=true`, `scripts/start.sh`:22 runs `seed.ts` on every container start, and
   `apps/api/src/db/seed.ts`:214-228 upserts `admin-001` with the built-in password and
   `must_reset_password = 1`. Every pod restart put the published password back.
3. **Access path scoping is real and measurable.** The `kid` in the Access login redirect is the
   application's `aud` tag, so a single `curl -D -` names the application that gated the request.
   Measured on 2026-11-01 with two path-scoped apps in place: `/admin`, `/admin/`, `/admin/settings`
   → the `/admin` app; `/api/admin`, `/api/admin/songs`, `/api/admin/login` → the `/api/admin` app;
   `/`, `/adminfoo`, `/administrator`, `/api/adminx` → the hostname-wide app. Matching is per whole
   path segment and subpaths inherit the parent app, so a `*` wildcard is unnecessary and a loose
   prefix cannot leak the panel.

A demonstration of the content risk ended up being smaller than ADR-102 assumed: no public route
serves a `.gp` file. The only handler that touches `TAB_FILES_DIR` is
`POST /api/admin/songs/upload` (`apps/api/src/routes/admin.ts`:109-131) — the tab files are written
to the PVC and parsed into the database, never served back as files.

## Decision

**1. No hostname-wide Access application. The game at `/` is public on purpose.**

The `Riff Radar demo` application (`43a7cbc6-…`) is deleted through the Cloudflare API with the
scoped token from ADR-032. The tunnel, its DNS record and the ingress rule are untouched: this
decision is about one Access application, not about re-plumbing ingress. A `200` on `/` is now the
expected answer, and ADR-102's sentence is retired.

**2. Two path-scoped Access applications hold the admin surface shut.**

| Application | Domain | Policies |
| --- | --- | --- |
| `RiffRadar admin panel` (`fb2e672d-…`) | `riffradar.voitech.dev/admin` | allow `gula.wojciech@gmail.com`, `gulasz101@gmail.com`, `sylw.kosmala@gmail.com` (precedence 1), deny `everyone` (precedence 2) |
| `RiffRadar admin API` (`827c5ca8-…`) | `riffradar.voitech.dev/api/admin` | same two policies, same precedence |

`/admin` or `/api/admin` answering `200` without an Access session is a bug — the one half of
ADR-102's rule that survives.

**3. The demo password stops re-arming, and the admin password is rotated.**

`seed.ts` is destructive to the admin row, so it no longer runs on container start:
`SEED_ON_START=false`, and a `seed-if-empty` init container runs migration plus seed **only when
`/app/data/db/riffradar.db` does not exist**. An empty PVC still comes up demo-ready (ADR-102's
property), an existing database is never re-seeded, and a restored backup is not re-seeded either.
The admin password itself is replaced once through the application's own reset path and stored
SOPS-encrypted; no password, hash or fragment of one appears in a comment, a commit or a chat.

**4. The admin login gets a second lock at the edge.**

A Cloudflare rate-limiting rule on `POST /api/admin/login`, 10 requests per minute per IP. It sits
behind Access, so it is the second lock and not the first — which is exactly why it is allowed to
wait for a token scope rather than blocking the cut-over.

**5. The content question is answered by the gate, not by luck.**

The tab file is copyrighted material. It stays unreachable because the only route that touches it
is behind Access, and because the game itself only exposes parsed challenge data the owner chose to
publish. If a future change adds a public download route for tab files, this decision is void.

## Consequences

- **The game is reachable by anyone**, including a wife who does not want to learn what an
  Access one-time PIN is. That was the whole point.
- **The admin panel keeps a real identity gate** for three addresses, with a deny-everything
  default, on two paths and nowhere else.
- **An Access mistake is now visible as a public game, not as a locked one.** The failure mode
  inverted: before, a broken policy locked two people out; now, a broken policy could expose an
  admin login. That is why the rate limit and the path-scoped deny exist, and why the panel is
  never widened "just for a minute".
- **A pod restart no longer resets the admin password.** Rotation survives restarts and deploys;
  the cost is that the seed only ever runs against a missing database file.
- **First boot on a fresh PVC is still automatic**, so ADR-102's "a rebuild is a re-deploy" holds.
  The difference: the seed now runs in an init container that skips a present database, so a
  half-seeded database is not retried either — deleting `riffradar.db` is the documented way to
  re-seed.
- **The rate limit is a rule in Cloudflare, not in the repo.** It is invisible to GitOps, so the
  only record of it is the issue comment and this ADR; a lost Cloudflare rule would not show up in
  a `git log`.
- **Monitoring does not cover the inverted failure mode.** Containers and the tunnel are watched;
  "the admin panel answered 200 without a session" has no metric — Access sits in front of the
  origin, the pod cannot see it. A scheduled external probe is the honest answer, and it is listed
  as a revisit.

## Alternatives considered

- **Keep the hostname-wide app and give the wife a service token or a passcode.** She asked for a
  game, not for a credential; a passcode on a phone is the same friction that made her give up on
  the Access login. Rejected by the owner's requirement.
- **Delete Access entirely, admin panel included.** One API call instead of three, and a published
  admin login with a known default credential and no rate limit on a domain anybody can find.
  Rejected on the credential alone.
- **`/admin` on its own hostname (`riffradar-admin.voitech.dev`) with its own tunnel.** Cleaner
  separation, and the app would need to serve its SPA at `/` for that host — an application-code
  change, which this work order forbids. Recorded as the better long-term shape.
- **`oauth2-proxy` + Authentik in front of `/admin` only.** A second deployment, a second OIDC
  client and a proxy that has to do path-based routing in front of a single-origin app, in exchange
  for SSO that three people already have through Access. Rejected as disproportionate, per ADR-102.
- **HTTP basic auth at the ingress.** `cloudflared` does not implement it; it would need a proxy
  anyway, and it would put a static shared secret in front of one panel. Rejected.
- **Fix `seed.ts` in the app (upsert nothing, or take the password from the environment).** The
  correct permanent fix, and explicitly out of scope for GUL-757 (`riff_radar` code is frozen for
  this work order). The init container is the honest homelab-side interim; a follow-up on the app
  repo is the real answer.

## When to revisit

1. **`riff_radar` gains an `onConflictDoNothing` seed or an env-supplied admin password.** Drop the
   `seed-if-empty` init container and go back to a plain `SEED_ON_START` — the workaround exists
   only because the app clobbers its own admin row.
2. **The admin surface grows a second entry point** (a `/moderator` panel, an upload UI on another
   path). Every new public-by-default path needs its own Access application in the same change, or
   it is exposed the day it ships.
3. **More than a handful of people need the panel.** Move to Authentik OIDC or the dedicated
   hostname above instead of growing an email allowlist.
4. **A public route ever serves a `.gp`, `.gp3/.gp4/.gp5/.gpx` or a raw MIDI file.** The copyright
   argument for keeping the panel gated collapses; resolve the content question before shipping it.
5. **Cloudflare's free tier stops including one rate-limiting rule**, or the rule is found missing.
   The second lock is cheap; paying for it or losing it silently are both decisions.
6. **A scheduled probe for "admin answered 200 unauthenticated" exists.** Then this ADR's
   monitoring gap closes and the inverted failure mode is watchable instead of remembered.
