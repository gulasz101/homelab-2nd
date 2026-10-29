# ADR-097: A Helm chart pin names one exact version and never sits below the deployed one

- **Status**: Accepted
- **Date**: 2026-10-28
- **Issue**: GUL-506 (fix-forward for GUL-479 work order 1)
- **Related**: ADR-092 (pin cloudflared image tags, upgrade by explicit bump), ADR-093 (scripted gates, Wojtek keeps the merge button)

## Context

Four HelmReleases had been floating on a version range (`>=0.23.0`, `>=0.5.0`,
`>=0.104.0`, `>=69.0.0`). With a range in the spec, Flux is the upgrade decision:
the next reconcile picks up whatever chart version the `HelmRepository` now
serves, and the workload changes without anybody having read a release note.
Work order 1 (GUL-479) pinned all four to an exact version with a scripted check
(`scripts/tests/helmrelease-pin-check.sh`).

The pin for `open-webui` was written as **17.0.0**. By the time it merged at
18:12Z the cluster was already running **17.3.0** — the range had floated it
there at 17:32Z the same afternoon. Pinning below the deployed version turned an
"upgrade hygiene" change into a **downgrade**, and Flux dutifully rolled it out
at 18:14Z:

```
File "/app/backend/open_webui/config.py", line 76, in run_migrations
    command.upgrade(alembic_cfg, 'head')
alembic.util.exc.CommandError: Can't locate revision identified by '0bd252b206fb'
```

Open WebUI runs alembic against its database. The schema was at 17.3.0's head;
17.0.0's migration tree does not contain that revision, so the app died on
startup, four restarts, pod `Error`. The HelmRelease still reported `Ready:
True` — Helm had successfully installed the release, and the pod-level crash is
not part of its Ready condition. Public ingress `ai-chat.voitech.dev` was down
for about six minutes until PR #83 put the pin at 17.3.0.

## Decision

A chart pin is one exact version **and** a floor.

- Every `spec.chart.spec.version` names one exact version; ranges are rejected by
  `scripts/tests/helmrelease-pin-check.sh` (AC-1).
- The pinned version is never below the chart version the cluster is currently
  running. Writing a pin is a read-then-write: check
  `status.lastAttemptedRevision` (or the deployed release's chart label) first,
  and pin to that, not to what the range resolved to a few hours earlier.
- Want the older version? That is a downgrade, not a pin. It gets its own issue,
  its own release-note read, and — for anything with migrations — a database
  plan. Bump the pin when you mean "freeze what runs", not "go back".

## Consequences

- Pinning is now a safe operation that can be merged at any time of day: at
  worst it changes nothing, because the pin equals what is deployed.
- The stateful-app trap is documented where the check lives, so the next person
  who writes a pin reads the rule at the point of use.
- Helm's `Ready` condition cannot be trusted as "the app works". A pin change to
  a stateful app must be verified at pod and HTTP level, not at HelmRelease
  level — the same way every other release here is verified.
- Downgrades remain possible, but only deliberately and with the migration story
  written down.
- The floor is enforced where a pin is written: the factory gate runs
  `scripts/helmrelease-pin-vs-cluster.sh <base> <head>` on any PR that changes a
  HelmRelease and refuses a pin below `status.history[0].chartVersion`, and the
  same script is the by-hand command for a non-factory PR (GUL-552).

## Alternatives considered

- **Let the factory resolve the range at pin time.** That is what happened, and it
  resolved to a stale value (`17.0.0`) instead of the deployed one (`17.3.0`).
  Resolution answers "what would upgrade to", not "what is running".
- **Revert PR #81.** Would have re-floated the other three charts and thrown away
  the pin check script to fix one line. Fix-forward was cheaper and kept `main`
  honest.
- **Break-glass `kubectl` patch of the HelmRelease.** Not a deployment path in
  this house; GitOps stays the only route, including during an outage.

## When to revisit

- When Renovate/Dependabot (GUL-315) opens pin-bump PRs from the registry, in
  which case "newest published release" and "what runs" are reconciled by the
  bot rather than by hand.
- When a chart legitimately has to move backwards (vendor regression); then the
  "never below deployed" rule is replaced by an explicit rollback procedure.
