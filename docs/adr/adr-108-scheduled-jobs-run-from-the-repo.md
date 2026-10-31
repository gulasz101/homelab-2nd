# ADR-108: The Air's scheduled jobs run from the repo, not from `~/.hermes/scripts`

- **Status**: Accepted
- **Date**: 2026-10-30
- **Issue**: GUL-618 (state backup and memory watchdog died with the GUI session)
- **Applies**: ADR-107 (every scheduled job on the Air is a system LaunchDaemon) — this is the
  second half of it, the part ADR-107 left open: *where the script a daemon runs actually lives*
- **Related**: ADR-071 (state.db is the source of record), ADR-080 (the watchdog watches the backup
  job), AMD-079 / ADR-079 (LaunchAgents reach the LAN through loopback relays)

## Context

Two jobs died in the same way the factory self-test did (ADR-107): `com.gulasz101.hermes-state-backup`
(daily 03:30) and `com.gulasz101.hermes-memory-watchdog` (hourly) were `~/Library/LaunchAgents`
jobs, so when WindowServer was killed on 2026-10-29 and the Aqua session was torn down, they stopped
existing. The 30 Oct backup did not run and the watchdog has been silent since 08:41 on the 29th —
the job that exists to notice silence went silent.

Moving the plists to `/Library/LaunchDaemons` is mechanical. The interesting question is the one
underneath: both jobs ran a script from `~/.hermes/scripts/`, outside GitOps. Sixty-odd files sit in
that directory, half of them one-off scripts from old incidents and several `.bak-` copies of the
same script with different bugs. On this host a script's real history is in a shell directory, not
in git: it cannot be reviewed before it runs, cannot be restored onto a replacement Air, and its
warranty expires the moment the machine does. The 2026-10-29 recovery was slowed down by exactly
this: the steps existed in a shell history, not in a file anyone could read.

ADR-107 already says a daemon's drift check compares the installed copy against `origin/main` at
its real installed path. That only works if the installed copy came from the repo.

## Decision

The two scheduled jobs and their scripts are part of `host/paperclip-air`, and the scripts are
deployed out of the tree by an installer, exactly like the long-running services:

1. **Plists** live in `host/paperclip-air/launchd/daemons/`, installed to
   `/Library/LaunchDaemons/` with `UserName=paperclip` and an explicit
   `EnvironmentVariables` block carrying `PATH`, `HOME=/Users/paperclip` and
   `HERMES_HOME=/Users/paperclip/.hermes`.
2. **Scripts** live in `host/paperclip-air/bin/` and are installed to
   `/usr/local/libexec/homelab/` (root-owned, `0755`) by
   `bin/homelab-install-scheduled-jobs.sh`. The `~/.hermes/scripts/` copies are moved to
   `~/.hermes/scripts.superseded-<ts>/` when the installer runs.
3. **The labels stay `com.gulasz101.*`.** A label is a contract with ADR-071, ADR-080, the
   watchdog's own check 5b and every past tracking note; renaming it during a recovery adds a new
   failure mode (a half-renamed job is scheduled twice under two names) for cosmetics only.
4. **`HERMES_HOME` is passed explicitly** rather than inferred from `$0`, because the installed
   script no longer sits inside the Hermes tree. Both scripts still fall back to `<script>/..` so an
   old copy keeps working.
5. **The watchdog asks `system/` first, `gui/<uid>` second.** Its check 5b interrogated
   `gui/$(id -u)/<label>`, which after this move returns nothing and would have alerted
   "the backup is not scheduled at all" every hour — a false alarm louder than the failure it was
   there to catch.

## Consequences

- A scheduled job survives a WindowServer death, a logout and a session-less boot, and its script
  can be reviewed in a PR, restored on a fresh Air, and fixed through GitOps.
- The installed script is root-owned and no longer in the user's writable heredoc playground.
  Editing the running job now means editing the repo and re-running the installer — slower, and the
  point.
- The job is installed at a stable path (`/usr/local/libexec/homelab/…`) rather than a path inside a
  git checkout, so a repo checkout parked on another branch by a concurrent agent run cannot break
  a 03:30 backup. The factory self-test's plist documents that exact failure.
- Drift between the repo and the installed copy is possible until someone re-runs the installer;
  neither script drift-checks itself yet. That is a known gap, not a claim of immutability.
- `tests/host-tree-check.sh` now asserts the shape of both plists (system domain, `UserName`,
  `HOME`, a schedule key, no companion agent), so a future edit that quietly turns one back into an
  agent fails CI.
- Still true, and unchanged by this ADR: a job that never fires is invisible unless *something*
  checks. The watchdog checking the backup job is that something — which is why the watchdog
  itself had to move first.

## Alternatives considered

- **Keep the scripts in `~/.hermes/scripts/` and only move the plists.** Rejected: this is the cheap
  fix that leaves the unreviewable part unreviewable. It also puts the running copy of the backup
  script in a directory the agent runtime writes to.
- **Install the scripts into `~/.hermes/scripts/` from the repo.** Rejected: user-writable, and it
  buries the two scripts that matter among sixty stale ones. A script that can rewrite itself can
  rewrite the backup.
- **Rename the labels to `dev.voitech.homelab.*` for consistency with the services.** Rejected for
  now: real work (ADR-071/080 and past alerts reference the old labels), zero functional gain, and
  a half-finished rename schedules the job twice. Revisit as a separate cosmetic change if the
  prefix ever matters.
- **Fold both jobs into one "scheduled jobs" daemon.** Rejected: they fail differently and must
  alert differently; one supervisor per job is the same rule as one supervisor per service.

## When to revisit

- A third scheduled job appears — then the hardcoded job list in the installer becomes a table and
  this ADR grows a registry.
- The backup moves into the cluster (a `CronJob` against the MinIO bucket) and the host-side job
  disappears.
- macOS changes how a `UserName` daemon gets `HOME` or its log paths; both plists depend on it.
