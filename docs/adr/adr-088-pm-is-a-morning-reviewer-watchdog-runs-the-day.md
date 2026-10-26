# ADR-088: The PM is a morning reviewer; the watchdog runs the day

- **Status:** Accepted
- **Date:** 2026-10-26
- **Deciders:** Wojtek (owner), Andrzej (CTO, homelab-2nd)
- **Tracked by:** GUL-197
- **Amends:** ADR-087 (the watchdog's escalation ladder only; the hire and the routine stand)
- **Amended by:** ADR-089 (the watchdog now clears recovery holds itself, through a narrow board tool)

## Context

ADR-087 hired Majster as an hourly watchdog and gave it an escalation ladder that ended at Claude
Code: a stalled issue that needed a decision became a courier issue assigned to the PM. That worked
mechanically and was wrong economically.

In Paperclip a wake *is* a run. An issue created with `assigneeAgentId` = Claude Code in `todo`
dispatches an Opus run at high effort immediately, not at a convenient moment. So every mid-day
"needs a decision" hand-off started a full PM run, out of hours, for a question that would still be
the same question at breakfast. On 2026-10-26 that ladder produced wakes at 17:03 and 17:06 for two
items that were already written down and waiting for a human.

The owner's direction, 19:30 the same day: *"make the PM assistant not wake up Claude… i want the PM
assistant to be more independent, and PM is only waking up at morning and looks up in general how
stuff is going."*

There is a mechanical detail that decides the design. Comments wake the assignee
(`shouldWakeAssigneeForIssueComment`), so a hand-off written as a comment on a PM-assigned issue
still costs a PM run — a "backlog" status does not save it. Comments written by the assignee itself
do not wake it (`selfComment` short-circuits the wake). Therefore the hand-off queue has to live on
an issue assigned to the watchdog, never to the PM.

Claude's morning routine already sweeps *"every issue that changed since yesterday's round"*, so a
standing issue that the watchdog touches each hour is discovered at 06:30 without a single wake.

## Decision

**Claude Code is a morning reviewer, not a pager. The watchdog owns the day and hands off in writing.**

The ladder for Majster, in order:

1. **Nudge the owner** of a stalled issue with a bounded continuation issue.
2. **Fix it itself** where an agent key is allowed: choose the cheaper executor, split the task,
   re-file an ambiguous brief. Not allowed: reassign, close, cancel, reprioritise, or clear a
   recovery hold (that needs a board actor).
3. **Write it into the standing issue "Morning brief for the PM"** — assigned to Majster, status
   `backlog`, append-only, one line per item, newest on top. The PM reads it at 06:30.
4. **Human-only decisions** go in that brief under `Needs Wojtek`, with a link and one sentence.
5. **Andrzej (CTO)** is the only agent Majster may wake mid-day and only for homelab, host or cluster
   work.
6. **Never** create an issue assigned to Claude Code, comment on its issues, or send it a courier.

## Consequences

**Good.** The PM costs one run a day instead of one per escalation. The owner reads the decisions in
the same 06:30 brief he already reads. The watchdog stops asking permission for ordinary triage,
which is what "more independent" meant. Every hand-off is a durable, dated record instead of a wake
that leaves no trace.

**Bad.** A genuinely urgent item now waits until morning unless Majster uses the Andrzej path. That
is a real trade and it is the owner's call, not a bug. The brief can rot into a wall of text if the
discipline slips — hence one line per item and a hard cap in the brief's own header.

**Neutral.** The PM still sees everything; it just sees it batched. Nothing is silently dropped: an
item that misses the brief still shows up in the board state the morning round reads.

## Alternatives considered

- **Keep courier issues to the PM, but only for "important" things.** Rejected: the threshold is
  exactly what a watchdog is bad at judging, and every wrong call costs an Opus run.
- **Create the hand-off as a `backlog` issue assigned to Claude Code.** Rejected on the wake
  mechanics: a comment on a PM-assigned issue wakes the PM, and a backlog issue nobody comments on
  is a queue the PM may never read.
- **Have Majster post to Mattermost.** Rejected for now: no outbound channel is wired for this
  profile, and a chat firehose is a worse record than a dated issue the morning round reads.
- **Let executors wake the PM directly when stuck.** Rejected: that is the behaviour being removed.

## When to revisit

- If the owner starts asking for afternoon PM decisions again, the brief is not visible enough —
  fix the surface, not the ladder.
- If urgent work routinely needs same-hour PM attention, add a single narrow "urgent" trigger with a
  named criterion (production down, data at risk) instead of reopening the general channel.
- If Paperclip ships routine-to-routine hand-off or a native queue, retire the standing issue.
