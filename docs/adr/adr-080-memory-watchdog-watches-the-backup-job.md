# ADR-080: The memory watchdog reads the backup JOB's exit status, not just its log

**Date:** 2026-10-22
**Status:** Accepted
**Deciders:** Wojtek Gula; implemented by Andrzej (Hermes agent)
**Project:** hermes / agent memory (epic H2-232)
**Related:** GUL-89, GUL-87, ADR-071 (state.db backup and its watchdog), ADR-079 (LaunchAgents and the LAN), ADR-073 (Hermes on the Air)
**Tracking note:** `homelab/tracking/2026-10-22-memory-watchdog-watches-the-backup-job.md` (vault)

## Context

ADR-071 §6 enumerates the conditions under which the memory watchdog alerts to Mattermost.
That list was written against a watchdog that read the backup **log** and asked one question
of it: *does the log contain a `SUCCESS profiles=` line listing all five profiles?*

On 2026-10-21 and 2026-10-22 the nightly backup failed both times (GUL-87). The log looked
perfectly healthy:

```
2026-10-20T03:34:00+02:00 SUCCESS profiles=[default andrzej florian szarik zdzislaw] total=5
2026-10-22T03:30:00+02:00 Starting Hermes state.db backup (...)     <- the run that died
```

The `SUCCESS` line was a day stale and still listed all five profiles, so the check stayed
green. The truth was one command away and in a place the watchdog never looked:

```
$ launchctl list | grep hermes-state-backup
-	1	com.gulasz101.hermes-state-backup      <- last exit status 1
```

Two nights of the only durable copy of every agent conversation (ADR-071) went unwritten
and unreported. ADR-079 recorded the root cause of the failures and noted the reporting gap
explicitly: *"The failure took two nights to surface because the watchdog reports on the
backup log's contents, and 'the job exited 1' is not one of its conditions."*

A second, quieter defect surfaced while fixing the first. The watchdog parsed YAML with
`/usr/bin/python3`, which has no PyYAML — so its memory-provider check was reporting a
**parser failure as five broken profiles**, every day, and its Gemma tripwire (an owner rule
since 2026-10-19) was not running at all. A tripwire that reports the wrong subject is
worse than no tripwire: five false alarms a day train the reader to ignore the channel that
the real alarm would have used.

## Decision

1. **The backup watchdog watches the backup JOB, not only the backup LOG.** It reads
   `launchctl print gui/$(id -u)/com.gulasz101.hermes-state-backup` and treats a non-zero
   `last exit code` as an alert condition, alongside a log-side check for a run that started
   and never wrote a `SUCCESS` line. Both signals are kept because each has a blind spot
   the other does not: launchd's exit code is the ground truth for the *schedule* and
   survives a truncated or missing log, while the log timeline also catches manual runs and
   works when launchctl cannot be read.
2. **A missed run is a separate condition with its own grace.** No run for more than 26 h
   (the 24 h schedule plus 2 h of slack) is its own alert, and a missing LaunchAgent is a
   third. The text says plainly that a Mac asleep at 03:30 runs nothing until it wakes and
   that the watchdog cannot wake a sleeping laptop (ADR-071) — the alarm reports what it can
   see and does not pretend to be more capable than it is.
3. **A run in flight is not a failed run.** A started-but-unfinished run is only counted as
   failed after an hour, because the `mc` readiness probe alone can burn 20 × 30 s and a
   healthy backup legitimately takes minutes.
4. **The watchdog uses two Python interpreters, split by what each is allowed to do.**
   `PYTHON_BIN` (`/usr/bin/python3`, Apple-signed) does everything that touches the network;
   `YAML_PY` does everything that only parses local config files. The split is forced by
   macOS Local Network privacy (ADR-079): a launchd-spawned process that is not Apple-signed
   cannot open a LAN connection, and the Apple-signed system python has no PyYAML, while the
   yaml-capable venv python is ad-hoc signed.
5. **The yaml-capable interpreter is discovered by probing, not hardcoded.** The watchdog
   tries candidates for an actual `import yaml` and uses the first that works, so a venv
   rebuild cannot silently re-break the checks.
6. **A missing capability is reported once, as itself.** If no interpreter has PyYAML, the
   watchdog raises one condition (`watchdog-yaml-unavailable`) saying which checks could not
   run. It never reports a broken *tool* as a broken *subject*.

## Consequences

- The GUL-87 failure mode is now caught: a run that dies before writing a single `UPLOADED`
  line raises `backup-job-failed` within the hour, from the exit code and the log timeline
  together.
- The five daily false "memory.provider is unreadable" alerts are gone, and the Gemma
  tripwire runs for the first time. The pre-existing self-test
  (`hermes-memory-watchdog-selftest.sh`) now passes for the right reason — it reports the
  injected fault (`EMPTY`) rather than the parser failure (`unreadable`).
- A new self-test (`hermes-memory-watchdog-selftest-backupjob.sh`) proves all three new
  conditions fire and that a healthy backup raises nothing, using a fake `launchctl` and a
  throwaway tree. The `hermes send` in it is faked, so a self-test never spams the channel.
- The watchdog's alert channel is now trustworthy enough to be the alarm for ADR-071's
  source-of-record claim — which is the whole point of the check.
- Two interpreters is one more moving part, and they can drift: a future Python upgrade
  that drops PyYAML from the venv would break checks 1 and 7 again. Mitigated by the probe
  and by the honest one-condition report, not eliminated.
- The `hermes` CLI that carries the alert is *not* Apple-signed, and that is fine: it posts
  to `chat.voitech.dev`, which resolves to Cloudflare public addresses, and Local Network
  privacy does not apply to public destinations. A launchd-spawned alert was observed
  delivering successfully (2026-10-21 17:00, `openrouter-low`).
- The watchdog remains host-side, not GitOps — the same ruling as ADR-071 and ADR-079. The
  data only exists on the Mac; the *decision* lives here.

## Alternatives considered

- **Keep the log-content check and add only a staleness check on the `SUCCESS` line.**
  Rejected: it catches a job that never ran, but not a job that ran and failed. The 03:30
  run on 2026-10-22 wrote a `Starting` line and then died; a `SUCCESS`-age check would
  still have found yesterday's fresh-enough `SUCCESS` line and stayed quiet.
- **Alert on any non-zero exit code, with no log-side check.** Rejected as the only signal:
  it cannot tell a failed run from a log that was rotated or never written, and it says
  nothing about a job that never ran at all.
- **Have the backup script write a sentinel file on success and check for its absence.**
  Rejected: a second piece of state to keep in sync with the log, and the failure mode
  becomes "the sentinel is stale" — the same bug one layer down.
- **Run the backup from a different scheduler with its own failure reporting.** Rejected:
  ADR-071 already ruled the cluster out for this job (the data is on the Mac), and the
  watchdog is the alarm regardless of who runs the job.
- **Give the watchdog the venv python for everything, and route the LAN reads through the
  `127.0.0.1` relay like the backup does (ADR-079).** Rejected for now: the LAN reads are
  read-only SSH plus a direct Hindsight API call, and moving them onto a relay is a larger
  change than the gap warrants. The two-interpreter split keeps the working path untouched
  and is reversible.
- **Fix the yaml problem by adding PyYAML to the system python.** Rejected: the system
  python is Apple's and must not be modified; it is also the interpreter that is *allowed*
  to reach the LAN, so it stays exactly as the OS ships it.
- **Let the watchdog post to Mattermost over the relay instead of shelling out to
  `hermes send`.** Rejected: `hermes send` works from launchd and reaches a public
  destination, so it is not the problem. Replacing a working delivery path during a
  reporting-gap fix adds risk without removing any.

## When to revisit

- The Air stops being a host that reaches the LAN (everything moves into the cluster): then
  the two-interpreter split collapses into one, and decision 4 is obsolete.
- The owner grants Local Network access to the relevant binaries (System Settings →
  Privacy & Security → Local Network). Then the ad-hoc-signed venv python may touch the LAN
  and one interpreter can serve both roles — the same trigger as ADR-079.
- The watchdog moves off the Mac (a container, a cluster-side cron). Then launchd's exit
  code is no longer available and the job-state signal must be replaced by whatever the
  new scheduler exposes.
- A second scheduled job needs the same "did the job run and exit cleanly" treatment. Then
  the launchctl reading belongs in a shared helper rather than inside the memory watchdog
  script, and this ADR's decision 1 generalises.
