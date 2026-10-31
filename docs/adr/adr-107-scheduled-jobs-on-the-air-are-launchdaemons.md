# ADR-107: Every scheduled job on the Air is a system LaunchDaemon, never a LaunchAgent

- **Status**: Accepted
- **Date**: 2026-10-30
- **Issue**: GUL-617 (daily guard self-test silent since 29 Oct)
- **Amends**: ADR-098 (one supervisor per host service on the Air) — extends its rule from
  long-running services to *scheduled* jobs
- **Related**: GUL-437 (built the self-test), ADR-093 decision 4 (the self-test itself)

## Context

The Air is not a desktop that happens to run services. It is a headless appliance on a
shelf: the only interactive user is a person who logs in occasionally, and between logins
there is no Aqua session at all.

`dev.voitech.factory-guard-selftest` was installed as a `~/Library/LaunchAgents` job, i.e.
in the `gui/501` domain. That domain only exists while somebody is logged in. On
2026-10-29 at 09:39:16 the userspace watchdog killed WindowServer
(`OS_REASON_WATCHDOG`, spin report
`WindowServer_2026-10-29-093900_paperclip.userspace_watchdog_timeout.spin`), the session was
torn down, and from then on `stat -f%Su /dev/console` answered `root` — the machine sat at
the login window. `gui/501` did not exist, so the daily 04:45 self-test simply never ran.

Nobody noticed for two days. The failure mode is the nasty one: not an error, not a crash,
just silence — and this job exists precisely to break silence when something is wrong. The
same session death also silenced the hourly memory watchdog and that night's state backup
(neither ran on 30 Oct), which is the real cost.

The services that did survive (Paperclip server, Hermes gateway, Syncthing, MinIO proxy,
Gemini tunnel) survived because ADR-098 had already moved them to root LaunchDaemons in the
system domain, with the `homelab-watchdog` supervisor restarting them headlessly. The
lesson from ADR-098 was correct; it just was not applied to the job that has no process to
supervise.

## Decision

Any job that launchd **schedules** on the Air lives in `/Library/LaunchDaemons` with
`UserName=paperclip` (or root where root is genuinely needed) and an explicit
`EnvironmentVariables` block carrying at least `PATH` and `HOME`.
`~/Library/LaunchAgents` is reserved for jobs that are meaningless without a graphical
session — GUI agents and app helpers — and nothing else.

Corollaries:

- A daemon defaults to root, so `UserName` is not optional; `HOME` must be set explicitly
  because launchd does not guarantee it for system daemons and every path in these scripts
  is `$HOME`-based.
- The drift check in a job compares the installed copy against `origin/main` at its real
  installed path. Moving a job's domain is therefore a repo change plus a reinstall, not a
  local `launchctl` nudge — otherwise the job fails its own drift check and writes `STOP`.
- Installing means `launchctl bootstrap system /Library/LaunchDaemons/<label>.plist` as
  root, and removing the old `~/Library/LaunchAgents` plist in the same step, or the job is
  scheduled twice.
- A silent job is indistinguishable from a healthy one. Any daemon whose absence matters
  should log a heartbeat that something else checks, rather than only speaking when it
  fails.

## Consequences

- Scheduled work survives a WindowServer death, a logout and a session-less boot. The
  failure that silenced the guard can no longer silence the guard.
- Scheduling lives in the system domain, so the `launchctl` verbs that manage it need root
  (`sudo`); the self-test install recipe in its plist comment carries them.
- The drift check now watches `/Library/LaunchDaemons/<label>.plist`, so a plain
  `git show > ~/Library/LaunchAgents/...` reinstall (the old recipe) fails loudly instead
  of quietly testing the wrong file. That is intended.
- Still true: a *missed* run stays invisible unless the heartbeat is checked. This ADR
  fixes "the job stopped firing", not "nobody looked at the log". A staleness check on
  `selftest.log` (alert if the newest line is older than 36 h) is the remaining gap.

## Alternatives considered

- **Keep the LaunchAgent and log back in.** Rejected: a login is a manual act, and the
  appliance is meant to run for weeks unattended. It also treats the symptom — the next
  WindowServer death starts the same clock again.
- **Have `homelab-watchdog` kickstart the agent into `gui/501`.** Rejected: there is no
  `gui/501` to kickstart into while nobody is logged in. The supervisor solves "process
  died", not "domain does not exist".
- **Fold the self-test into `homelab-watchdog`'s 120 s loop** (run it when the day changes).
  Rejected: mixes two concerns in one script, and a bug in the supervisor would disable the
  thing that is supposed to judge the supervisor. Separate daemon, separate domain entry,
  separate log.
- **A systemwide `cron`/`periodic` job.** Rejected: launchd's `StartCalendarInterval`
  already does this, is the platform idiom, and `username` support works the same way.

## When to revisit

- If the Air is ever used as a real desktop again (somebody logged in most of the day), the
  domain choice matters less — but the rule costs nothing, so leave it.
- If the remaining `~/Library/LaunchAgents` jobs on this host are migrated too (state
  backup, memory watchdog), extend the ADR's scope note rather than writing a new one.
- If macOS changes `UserName`/`HOME` behaviour for LaunchDaemons (verify with
  `sudo launchctl print system/<label>` after any OS upgrade).
