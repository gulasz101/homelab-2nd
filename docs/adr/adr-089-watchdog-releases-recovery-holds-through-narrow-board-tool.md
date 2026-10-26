# ADR-089: The watchdog releases recovery holds through a narrow board tool

- **Status:** Proposed
- **Date:** 2026-10-26
- **Deciders:** Wojtek (owner), Andrzej (CTO, homelab-2nd)
- **Tracked by:** GUL-220
- **Amends:** ADR-088 (the watchdog's ladder), ADR-087 (its "cannot clear a recovery hold")
- **Supersedes:** nothing

## Context

ADR-087 hired Majster as an hourly watchdog and ADR-088 made Claude Code a morning reviewer, on the
rule that the watchdog only *adds* work and never *does* it. Both left one hole: a recovery hold.
When a run dies with an unverified provider action, Paperclip parks the issue `blocked` behind an
`executionBlocker` and records every later wake as `deferred_issue_execution` with `runId: null`.
No comment, courier issue or reassignment can clear that. Only `POST
/issues/<id>/recovery-actions/resolve` as a board actor can. ADR-087 called that "the board must
resolve this", which in practice meant Wojtek.

Measured on 2026-10-26: nine holds, eight of them `legacy_execution_requires_reconciliation`, all
days old. The human check on each dead run was one man reading run logs on his phone. That is a
bottleneck, and it is exactly the kind of bottleneck an agent can absorb.

The owner's direction, 19:40Z the same day, unchanged by the time this ADR was written:

> i want majster to send them … majster should be the PM assistant that is actually quite
> independent and should be annoying to other agents to make them work and unblock them every
> time those get stuck … if majster stuck, he can always ask andrzej for help as senior CTO

So the watchdog becomes the board actor. Not by giving it a board login and free hands, but through
one narrow tool that can send exactly three calls.

## Decision

**A cheap agent sends the board's recovery calls as the owner, through a narrow tool.**

1. **The tool.** `/Users/paperclip/paperclip-agents/majster/tools/release-hold.py`, outside every
   public repo. It reads the board token from `~/.paperclip/auth.json` and never prints it. It
   allows three calls and refuses everything else without touching the network:
   `GET /issues/<id>` (+ `/runs`), `POST /issues/<id>/recovery-actions/resolve`, and
   `PATCH /issues/<id>` with exactly `{"assigneeAgentId": <executionBlocker.agentId>}` for the case
   where the assignee is not the dead run's agent.
2. **Validation against the live issue, not against the caller's intent.** A resolve body is sent
   only when `actionId` equals the live `executionBlocker.recoveryActionId`, `runId` equals the
   blocker's run, the body is strict-schema clean, `outcome` is `restored`, `sourceIssueStatus` is
   todo/done/in_review, and `outcomeEvidence` is real text. `--dry-run` prints the request and sends
   nothing, so a body can be reviewed before it lands.
3. **The evidence rule moves with the job.** The watchdog reads `/runs`, the comments, `/activity`
   and the run's own ndjson log before it writes a body. When it cannot tell what the dead run did,
   it asks Andrzej for the body instead of inventing an outcome.
4. **The rest of the ladder stays as ADR-088 left it**, with two changes the owner asked for in the
   same breath: re-nudge the same issue after 2 h when the previous nudge started no run, escalate
   to Andrzej after three nudges with no movement, and treat Andrzej — not Claude Code — as the
   helper for anything the watchdog is stuck on.

## Consequences

**Good.** Holds get cleared in the same hour the watchdog finds them, not the next time a human
reads the board. The narrow tool makes the dangerous part explicit: three calls, validated, with a
dry run, instead of a shell with a board token in it. The procedure is written into the brief, so
the next person (or agent) inherits the shape of the body rather than a story about it.

**Bad — and it is worth being blunt about all three.** The activity log will say **Wojtek** resolved
those holds. He did not; the foreman did, with his token. Every local agent on this Mac can already
read `~/.paperclip/auth.json` — GUL-206 put the server's database and S3 secrets in a transcript out
of the same environment — so the narrow tool is a guard rail, not a lock: anything running on the
Air with the right file permissions can call the API directly and skip it. And a real human check
on a dead run becomes an agent check: if the watchdog writes a confident `outcomeEvidence` for work
that never happened, the board has no second pair of eyes on it. ADR-088's human reviewer at 06:30
is the only remaining check, and only on what the watchdog chooses to write down.

**Neutral.** Claude Code loses its last board-write privilege, so its morning round is now read-only
except where the owner asks directly. The token stays where it was; nothing new is stored.

## Alternatives considered

- **Keep holds human-only and batch them into the 06:30 brief.** This is what ADR-087 did, and it
  produced nine holds in one day on a board of twenty open issues. Rejected: a queue that grows
  faster than the reviewer reads it is not a control, it is a backlog.
- **Give Majster a real board API key of its own with issue-mutation rights.** Rejected: far wider
  than the job, and it would put a second board identity in the audit trail with no owner attached.
- **Have Andrzej (CTO) clear every hold.** Rejected: it makes an expensive agent the hourly
  bottleneck and burns a 90-minute run on a JSON body. Andrzej is the fallback when the body is
  genuinely unclear, not the default path.
- **Automate the release inside Paperclip instead.** Correct long-term answer — a server-side
  reconciler that resolves `legacy_execution_requires_reconciliation` without a human — but it is
  an upstream change, and the holds exist today. Revisit when Paperclip ships one.

## When to revisit

- If a hold the watchdog released turns out to have hidden lost work, tighten the evidence rule and
  put those causes back on the human path with a named list.
- If Paperclip ships a native recovery reconciler, retire the tool and keep the brief's evidence
  section.
- If the token file's permissions widen beyond the agents that need it, this decision gets worse
  fast: fix the file, not the tool.
