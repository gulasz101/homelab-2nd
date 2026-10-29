# ADR-102: A demo of one app is not a database platform — Riff Radar runs SQLite on local-path with a nightly MinIO backup, behind Cloudflare Access

**Date:** 2026-10-29
**Status:** Accepted
**Deciders:** Wojtek Gula
**Project:** homelab-2nd / riffradar demo environment
**Related:** GUL-550, GUL-262 (why the demo exists), GUL-549 + ADR-101 (the private image),
ADR-005 (per-namespace observability), ADR-032 (tunnels created via the Cloudflare API),
tracking note `homelab/tracking/2026-10-29-riffradar-demo.md`

## Context

Riff Radar is a personal tab-learning app: a Bun API with a React SPA, one demo
challenge, and a wife who wants to click through it. The code lives in its own
repository and keeps **all** its state in a SQLite file (`data/db/riffradar.db`)
plus generated tab files in `data/tabs`. There is no Postgres support and there is
no plugin interface to add one.

The house rule for data is CloudNativePG with S3 backups and WAL archiving
(guardrail 3), and most of this cluster follows it. This service cannot: forcing a
database the app does not speak would mean running a shadow copy and a
synchroniser that nobody asked to maintain, for a demo whose entire dataset is a
few hundred kilobytes.

The second question is exposure. The demo is one copyrighted song tab. It is meant
for two people, not for the open internet, and it must survive a `homelab-2nd`
rebuild without anybody remembering a manual step.

## Decision

**1. Storage: SQLite on a `local-path` PVC, plus a nightly backup to OMV MinIO.
No Postgres.**

- The PVC (`riffradar-data`, 2Gi, `local-path`) holds `data/db` and `data/tabs`.
  `local-path` and not OMV NFS because SQLite wants low-latency random writes and
  the volume has exactly one writer; the disk is a cache, never the durability
  story (no node in this cluster is durable).
- The Deployment is `replicas: 1` with `strategy: Recreate`. SQLite is
  single-writer: a rolling update would briefly run two pods, two migration runs
  and two writers on one file. Recreate costs a few seconds of 502 at the edge and
  buys a guarantee.
- The `riffradar-backup` CronJob (03:30 daily) copies the database with SQLite's
  **online backup API** (`sqlite3.Connection.backup`), never `cp` — the DB is in
  WAL mode, so a file copy can capture a torn page plus a `-wal` a reader will not
  replay. Tabs go up as a tar.gz in the same run. Both land in
  `s3://riffradar-backups/riffradar/` on OMV MinIO under a dedicated
  `riffradar-backup` user whose policy covers that bucket only (SRP: no shared
  backup credential). Retention 30 days, pruned by the job itself.
- The PVC is mounted read-only into the job, and both the Deployment and the job
  pin `kubernetes.io/hostname: homelab-2nd` because a `local-path` volume is
  node-local.

**2. Access: a dedicated Cloudflare Tunnel with Cloudflare Access (email
allowlist) in front of it, not a public hostname.**

- One tunnel per service (guardrail 5); `riffradar.voitech.dev` is its only
  hostname. Ingress is remote-managed (`config_src=cloudflare`), created with the
  scoped API token from ADR-032, so the origin rule is readable from the Cloudflare
  API and not from a click somebody made eighteen months ago.
- Cloudflare Access sits in front with an allow policy for two email addresses and
  a deny-everything default. The app has no OIDC support, so Authentik OIDC is not
  available; Access is the cheapest way to make "not for the public" true instead
  of aspirational. A `200` on the hostname without an Access session counts as a
  bug, not a feature.
- The alternative — oauth2-proxy in front of the app — would add a whole second
  deployment and an Authentik application to protect one demo. Rejected as
  disproportionate here, and noted below as the thing to revisit if Access ever
  needs replacing.

**3. The image is private, and so is the credential.**

`ghcr.io/gulasz101/riff_radar` is a private package (ADR-101). The cluster pulls
it with a SOPS-encrypted `kubernetes.io/dockerconfigjson` Secret present twice —
in `riffradar` for the kubelet and in `flux-system` for
image-reflector-controller, which can only read a `secretRef` from its own
namespace. The token is a GitHub PAT with `read:packages` and nothing else
(verified from the `x-oauth-scopes` header), minted by the owner and encrypted in
place, never pasted into a file, a comment or a chat.

**This per-service Secret is a stop-gap.** ADR-103 (GUL-579, in review) moves the
platform to one shared `ghcr-pull` credential; when that lands, riffradar consumes
that Secret (`scripts/ghcr-pull-credential.sh add riffradar`) and this file plus
its kustomization entry are deleted. One credential, N namespaces — not N
credentials.

**4. Observability is honest about what does not exist.**

The app exposes `/health` and no `/metrics`. Therefore: PrometheusRules for
"single replica not Ready for 10 minutes", "backup job failed", "backup stale",
"restart loop"; a Loki rule for error lines, fed by the existing OTel Collector
DaemonSet (container logs, cluster-wide, no per-service wiring needed); and **no
ServiceMonitor**, because scraping a non-existent endpoint is theatre. App-level
metrics are a later work order, not part of this deploy.

## Consequences

- **A rebuild is a re-deploy.** New node, empty PVC, Flux applies the manifests,
  `SEED_ON_START=true` seeds the demo challenge, and the app is demo-ready in
  under a minute. Nothing manual, nothing to remember.
- **Recovery point is up to 24 hours.** The last successful backup is the best
  copy we have. That is acceptable for a demo and is exactly why the ADR says so
  out loud instead of implying point-in-time recovery.
- **One writer, by construction.** Scaling the Deployment past one replica is not
  a knob to turn; it is a bug that corrupts the data. The `Recreate` strategy and
  the pinned node make that hard to do by accident.
- **The pull secret is a manual, one-time credential.** It is the only step in
  this package a human must perform, and it must be repeated if the token expires
  or is revoked. That is the price of a private image; the alternative is a public
  package.
- **Backups are only proven by a restore.** A backup job that uploads objects is
  not a backup. The tracking note records an actual restore-of-the-object check;
  anything less is optimism.
- **No app metrics means no app SLI.** We can tell you the pod is up and the demo
  answers through the tunnel. We cannot tell you a specific API route got slower.

## Alternatives considered

- **Postgres via CloudNativePG with a sync job from SQLite.** The app has no
  Postgres driver and no abstraction to hang one on. The synchroniser would be
  our code, our bug surface and our on-call page, for a demo. Rejected.
- **SQLite on OMV NFS (like Karakeep's data PVC).** NFS gives durability the
  cluster does not otherwise have, but SQLite over NFS is a well-known way to
  corrupt a database (locking and `-wal` semantics across clients), and this app
  writes on every request. Rejected in favour of local-path plus an explicit
  backup.
- **No PVC at all, data in an `emptyDir`.** Every pod restart wipes the demo and
  the generated tabs. Cheap, and wrong: the demo is shared with another person who
  will not accept "it reset again".
- **Public hostname, no Access.** Simplest click-through, and it publishes a
  copyrighted tab to the internet under the owner's domain. Rejected on the
  content, not on the technology.
- **`oauth2-proxy` + Authentik in front of the app.** Correct for a service with
  real users; for two email addresses it is a second deployment, a second OIDC
  client and a second thing to debug. Rejected as disproportionate, and recorded
  as the fallback if Access is ever dropped.
- **Flux `ImageUpdateAutomation` vs Renovate-only pinning.** The reference
  service (star-office) uses Flux image automation, and the issue asked for the
  same shape; the semver range is capped below `1.0.0` so a major bump can never
  arrive by robot. Renovate remains the mechanism for charts and everything else.

## When to revisit

1. **The app grows a Postgres driver, or the factory work order to add one
   lands.** Then this becomes a CNPG cluster with S3 base backups and WAL
   archiving, and the CronJob is deleted. This is the named trigger, not a vague
   "someday".
2. **More than two or three people need access.** The email allowlist stops
   scaling; move to Authentik OIDC (or oauth2-proxy) and drop Access.
3. **The data stops being disposable.** If tabs or progress become something
   people would be upset to lose, the 24-hour recovery point is no longer good
   enough: raise the cadence, or move to a database with WAL archiving.
4. **The demo goes public.** If the copyrighted content question is resolved,
   Access is one policy deletion away — but that is the owner's call, not a
   default.
5. **The app emits `/metrics`.** Add a ServiceMonitor, an SLI and a dashboard;
   until then the PrometheusRule set here is the whole truth.
