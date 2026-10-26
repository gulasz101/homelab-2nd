# ADR-087: An hourly watchdog agent owns board triage

- **Status:** Accepted
- **Date:** 2026-10-26
- **Deciders:** Andrzej (CTO, homelab-2nd)
- **Tracked by:** GUL-197
- **Amended by:** ADR-088 (escalation ladder), ADR-089 (the watchdog clears recovery holds itself)

## Context

The Paperclip fleet has a planner (Claude Code) and executors (Pi, OpenCode, Szarik, Andrzej).
Every executor runs one shift and exits. Nothing walks the floor between shifts, so work that dies
mid-run stays exactly where it died until a human notices and says "continue".

Two measurements made this concrete on 2026-10-26:

1. **A `blocked` status is usually a lie.** Ten issues sat in `blocked`. Eight of them had no
   dependency problem at all: a run hit the adapter wall clock or was cancelled, execution
   recovery settled the issue `blocked` with no comment and no `blockedBy` row, and the issue
   looked like a dependency that nobody was working on. The dependency graph was innocent.
2. **Nudging is theatre against a recovery hold.** The first sweep run after this decision found
   8 of 19 open issues held by `legacy_execution_requires_reconciliation`: every new assignment
   wake is recorded as `deferred_issue_execution` with `runId: null`, so no run ever starts. A
   comment saying "please continue" cannot clear that; only a board actor can.

So the fleet was not slow, it was unobserved. The human was the watchdog, and the human had other
work.

## Decision

**A dedicated cheap agent, Majster, sweeps the whole board every hour, and its entire job is
getting stalled work back in front of whoever owns it. It adds work; it never does work.**

Concretely:

1. **Agent.** `Majster`, role `pm`, reports to Claude Code, adapter `pi_local`, model
   `llmhub/deepseek-v4.1-flash-go`, `timeoutSec` 1800. No heartbeat timer — a routine drives it, so
   idle hours cost nothing.
2. **Routine.** "Hourly board sweep", `0 * * * *` Europe/Warsaw, `concurrencyPolicy:
   skip_if_active`, `catchUpPolicy: skip_missed`, `activityGatePolicy: always`. The activity gate
   stays `always` on purpose: "nothing moved" is exactly the condition a watchdog exists to catch,
   so a gate that sleeps through quiet hours defeats the job.
3. **Evidence before status.** Its brief makes it read `/runs`, `/activity`,
   `/diagnostics/wakes` and `/interactions` before believing any status field, because the status
   field is what lied in measurement 1.
4. **Action ladder, cheapest first.** A bounded continuation issue to the stalled issue's owner →
   a decision request to Claude Code → a human request routed *through* Claude Code
   (`Needs Wojtek: …`) → or report it and leave it alone. It never reassigns, closes, reprioritises
   or blocks another agent's issue.
5. **Anti-spam is architecture, not manners.** Max 5 continuation issues per sweep, never the same
   issue twice in 6 hours, one line for a quiet board. A watchdog that cries wolf gets muted, and
   a muted watchdog is worse than none.

## Consequences

**Good.** Stalls are found within an hour instead of when the owner gets bored of it. Each sweep
leaves a one-screen digest in Paperclip, so the board itself becomes the audit trail. The model
cost is in the noise (flash-tier, four minutes of work per hour), and the human is out of the loop
for everything except real decisions.

**Bad.** It is another agent with issue-create rights, so it can generate noise; that is what the
caps are for. It cannot clear a recovery hold, and it must not pretend otherwise — its honest
answer for those is "the board must resolve this", which still needs a human. Digests add rows to
the board.

**Neutral.** It duplicates a little of what the PM knows. That is fine: the PM plans, the foreman
counts.

## Alternatives considered

- **Let Claude Code run the hourly check.** Rejected: the planning agent runs Opus at high effort,
  priced for thinking, not for counting. Also the PM that wrote the plan is the worst judge of
  whether the plan is stuck.
- **A Hermes cron job posting to Mattermost.** Rejected: no board context, no ability to create a
  bounded work item against an agent, and it lives outside Paperclip's audit trail.
- **Timer heartbeats on every executor.** Rejected: turns every worker into a self-starter and
  multiplies idle wakes across the fleet, while fixing nothing at the cross-issue level where
  stalls actually live.
- **Keep asking agents to continue by hand.** This was the status quo, and the reason the issue
  exists.

## When to revisit

- If the caps fire regularly, the problem is upstream (run ceilings, recovery holds), not the
  watchdog — fix that and the sweeps go quiet again.
- If Paperclip ships a native stale-issue reconciler, retire the routine and keep the brief.
- If board triage genuinely needs a human eye more than once a day, the digest is the wrong shape
  and should become a daily summary instead of an hourly card.
