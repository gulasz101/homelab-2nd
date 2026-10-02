# ADR-024: OpenChamber 2.1.0 and the in-pod OpenCode CLI self-upgrade

## Status

Accepted — 2026-10-02 · amends ADR-023 (same worker, same runtime line)

Amends rather than supersedes: ADR-023's decision to move the worker onto
OpenCode 2 stands and is unchanged. What this ADR corrects is one *factual
assumption* inside ADR-023 — that the worker "is pinned and does not
self-update".

## Context

OpenChamber released **v2.1.0** on 2026-10-01. It is a routine feature
release: local full-text search across conversations, a rebuilt file editor,
background-command visibility, per-message share links, and large-message
performance fixes. It carries **no breaking changes and no OpenCode floor
change**, and `@openchamber/web@2.1.0` pins its bundled protocol packages
(`@opencode/client`, `@opencode/schema`) at **2.0.21**.

The 2.0.4 upgrade (ADR-023) was the risky one: a new distribution
(`opencode-ai` → `@opencode/cli`), a one-way SQLite migration, and a bespoke
integration surface (native `opencode-go` provider → LiteLLM with the
`x-opencode-session` header, the Itsaplan bridge calling OpenChamber HTTP
routes directly, split storage). 2.0.4 → 2.1.0 is a bump on the same line,
and the two-commit GitOps pattern from ADR-023 applies unchanged.

### The finding that made this ADR necessary

Planning this upgrade surfaced something ADR-023 had explicitly flagged as a
future risk but assumed was not happening. On **2026-10-02**, the worker pod
— running image `ghcr.io/gulasz101/openchamber-web:2.0.4-r1`, which pins
`@opencode/cli@2.0.20` — **upgraded its own OpenCode CLI, twice, to 2.0.22**.
From `/home/openchamber/.local/share/opencode/log/opencode.log`:

```
2026-10-02T05:11:52Z run=821bf1cc message="cli starting" version=2.0.21 args="[\"--version\"]" role=cli
2026-10-02T05:14:58Z run=c63c92a8 message="cli starting" version=2.0.21 args="[\"upgrade\"]"   role=cli
2026-10-02T05:15:20Z run=783f9402 message="cli starting" version=2.0.22 args="[\"--version\"]" role=cli
2026-10-02T05:16:01Z run=66b6d3f7 message="cli starting" version=2.0.22 args="[\"upgrade\"]"   role=cli
2026-10-02T05:16:24Z run=77734a6e message="cli starting" version=2.0.22 args="[\"upgrade\"]"   role=cli
2026-10-02T05:17:41Z run=7b782ed2 message="cli starting" version=2.0.22 args="[\"serve\",\"--hostname\",\"0.0.0.0\",\"--port\",\"4096\"]" role=cli
```

Corroborated by `npm ls -g --depth=0` reporting `@opencode/cli@2.0.22` and by
the filesystem mtime of
`/home/openchamber/.npm-global/lib/node_modules/@opencode/cli/package.json`
being `2026-10-02T05:15:07Z`.

The mechanism is OpenChamber's own upgrade route. `server/lib/opencode/DOCUMENTATION.md`
("CLI upgrades") documents `POST /api/opencode/upgrade`, which runs the
host-resolved CLI with the `upgrade` subcommand via
`server/lib/opencode/cli-upgrade.js`; the ownership policy in
`server/lib/opencode/upgrade-capability.js` permits it for managed,
non-bundled runtimes. A `showOpenCodeUpdateNotifications` settings key exists.

This matters because the image tag is our immutability guarantee. It no
longer describes the running container. ADR-023 §"When to revisit" listed
exactly this condition — *"If OpenChamber self-update is ever enabled in the
pod → revisit the pinning (an in-pod updater would fight the immutable
image)"* — and it fired, unprompted, on its own. It is tracked as **H2-93**.

## Decision

1. **Upgrade to OpenChamber 2.1.0 + `@opencode/cli@2.0.22` + `bun@1.4.2`**,
   same image (`ghcr.io/gulasz101/openchamber-web`), same two-commit ordering
   from ADR-023 §2: commit 1 rebuilds and pushes `2.1.0-r1`, and only once
   the tag exists in GHCR does commit 2 flip the Deployment.

2. **Pin `OPENCODE_CLI_VERSION` to 2.0.22, not 2.0.20 and not 2.0.21.**
   2.0.22 is what the pod is provably running and healthy on, and it is above
   the 2.0.21 protocol OpenChamber 2.1.0 bundles. Pinning 2.0.20 would
   deliberately *downgrade* the running CLI and hand the in-pod updater a
   reason to fire again on first boot.

3. **Treat the Dockerfile `ARG` as a floor, not a ceiling.** OpenChamber may
   move the managed CLI forward inside a live pod. The ARG is the version we
   guarantee the image *starts* at; it is not a promise about what the pod
   runs an hour later. After any observed in-pod upgrade, re-baseline the ARG.

4. **The tag flip is executed from outside the worker pod.** The worker agent
   runs in the very pod that the `Recreate` strategy destroys, so it cannot
   perform its own deploy or post its own deploy evidence. This is the same
   boundary ADR-023 identified; it is recorded here because it is now a
   standing property of the setup (H2-94), not a one-off.

5. **No storage, ingress, or secret change.** `/storage` stays on OMV NFS,
   `/var/lib/openchamber` stays on local NVMe, the bridge routes and the seed
   `opencode.json` carry over unchanged. All six routes the Itsaplan bridge
   calls were re-verified against the published 2.1.0 tarball before any
   change was made.

### Why the message-search index is called out

2.1.0's headline feature — "search across your conversations" — is a new,
opt-in **local index** over session history. It is the first 2.x feature to
introduce a new storage consumer, so its location is load-bearing: the index
must land under a path the hourly `openchamber-backup` CronJob already
archives (`/storage` or `/var/lib/openchamber`). If it lands elsewhere it is
backed up by nobody. This is verified as part of H2-89 rather than assumed.

## Consequences

**Positive**

- One Flux app, one image, one node selector — still rebuildable from Git.
- No SQLite migration risk this time: the DB has been on OpenCode 2 since
  2026-10-01, and 2.0.4 → 2.1.0 introduces no announced schema change.
- The bridge HTTP surface was proven intact from the real tarball, not from
  release notes. A renamed route would have broken delegated task runs
  silently; now that class of failure is ruled out for this upgrade.
- The pin now matches reality, so the image tag tells the truth about its
  pod at the moment of deploy.

**Negative**

- **Tag/pod drift is now a known behaviour, not an impossibility.** A rollback
  to `2.0.4-r1` does not reproduce the state the pod was actually in
  (2.0.22 CLI), and any version quoted from a tag alone may be wrong.
- **A future deploy can silently downgrade the CLI**, then the in-pod updater
  may move it forward again. Churn nobody asked for, and a support surface
  where "what version are you on?" has two answers.
- The upgrade is not fully delegatable to the worker. Build and docs can run
  in-pod; the flip and its verification must run outside. Every future
  operation pays this hand-off tax until H2-94 resolves it.
- The search index adds disk and memory pressure to a pod whose 3Gi limit is
  already watched by `openchamber-resources`.

## Alternatives considered

- **Pin 2.0.21 to match the bundled protocol exactly.** Rejected: it is a
  downgrade from what runs today, and OpenChamber tolerates 2.0.22 (it was the
  updater that chose it). Matching the bundled protocol buys alignment on
  paper at the cost of a pointless downgrade-then-upgrade cycle.
- **Keep 2.0.20, the original ADR-023 pin.** Rejected: it deliberately
  regresses the running CLI and invites the self-updater to fire the moment
  the pod returns.
- **Make `/home/openchamber/.npm-global` non-writable so an in-pod upgrade
  fails closed.** The strongest lock, and the most likely eventual fix — but
  not adopted here blind. It needs a check that OpenChamber treats a failed
  upgrade as recoverable rather than fatal, and that is real risk to take on
  a live worker for a cosmetic guarantee. Filed under H2-93 for evaluation.
- **`OPENCODE_DISABLE_AUTOUPDATE=1` in the Deployment env.** OpenChamber's own
  spaces code documents the 2.0.15 binary as honouring this. Likely
  insufficient: the observed calls were *explicit* `upgrade` subcommand
  invocations, not update checks, and that variable gates the check. Verify
  empirically before relying on it (H2-93).
- **Flip the tag from inside the worker.** Rejected: the `Recreate` strategy
  destroys the pod performing the flip, so the deploy cannot be verified or
  evidenced by the agent that performed it. This is the constraint that
  shaped the original H2-81 hand-off.
- **Skip verification of the bridge routes because 2.1.0 "is only a feature
  release".** Rejected: release notes do not enumerate route removals, and a
  renamed route breaks delegated Itsaplan runs at the worst possible moment.
  Cost of checking: one `npm pack` and a grep.

## When to revisit

- **If H2-93 lands a lock** (read-only npm prefix, or a supported disable),
  the Dockerfile ARG becomes authoritative again and decision 3 is retired.
- **If OpenChamber ships a supported way to disable the upgrade route**, pin
  the CLI properly and drop the "floor, not a ceiling" framing.
- **If the message-search index grows** toward the 30Gi `openchamber-storage`
  PVC or starts pressuring the 3Gi memory limit, revisit index placement or
  clear it from the backup set deliberately rather than by accident.
- **If H2-94 grants the worker a narrow namespace Role**, the deploy could
  move back inside the pod and this ADR's decision 4 would be retired.
- **If OpenChamber changes the bridge routes** (`/auth/session`,
  `/api/openchamber/sessions*`, `/api/permission-auto-accept/sessions/:id`,
  `/api/session/:id/message`, `/api/sessions/:id/status`), revisit the
  Itsaplan bridge (ADR-019) before anything else.
