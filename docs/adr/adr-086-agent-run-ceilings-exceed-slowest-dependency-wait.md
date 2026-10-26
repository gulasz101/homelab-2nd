# ADR-086: Agent run ceilings must exceed the slowest dependency wait

- **Status:** Accepted
- **Date:** 2026-10-26
- **Deciders:** Andrzej (CTO, homelab-2nd)
- **Tracked by:** GUL-187

## Context

The Image Studio agent (Matejko) on Paperclip works in render round-trips, not in one-shot
actions. A card means: write a prompt, submit it to the Ideogram 4 queue on the M1 Max, wait for
the render, fetch it, run vision checks on crops, fix what is wrong, submit again.

The render queue is a single `sd-cli` worker. A job takes 20-30 minutes of GPU, plus whatever is
already queued ahead of it. Measured on 2026-10-26: one job waited 26 minutes before it even
started, and the pending job behind it carried `queue_ahead: 2, eta_minutes: 63`.

Paperclip's adapter wall clock for that agent was 5400 s (90 minutes), set on
`agent.adapterConfig.timeoutSec`. That number was inherited from an earlier, cheaper workload
and was never re-examined against the render queue.

The failure mode was silent. A run that exceeds the ceiling is cut off mid-work with no error
text on the card; the control plane then settles the issue into
`execution.phase: recovery_needed` with `permittedActions: ["inspect_run"]` and refuses to
replay it. The card sits in `todo` with `blockedBy: []` and no monitor. Four cards were killed
this way in one afternoon (GUL-166, GUL-180, GUL-156) and nothing on the board said "killed at
the ceiling". The agent card read `running` throughout, because each killed run was immediately
followed by a fresh one, so the fleet looked busy while making no forward progress.

The sibling ceiling matters too. Hermes has its own `agent.gateway_timeout`, exported to
`HERMES_AGENT_TIMEOUT` at gateway start, and it is an **inactivity** watchdog, not a wall clock
(`gateway/run_turn.py`: "Inactivity timeout … not wall-clock"). It was never the killer here, but
it sat at the same 5400 s and would have capped any legitimately slow stretch.

## Decision

**Size every agent run ceiling against the slowest thing the run waits on, plus the work around
it. For a render-bound agent that means hours, not minutes.**

Concretely, in the fleet:

1. `agent.adapterConfig.timeoutSec` on Paperclip is the wall clock that actually kills runs. It
   must exceed one full round-trip cycle, including queue wait. For the Image Studio agent that
   is 14400 s (4 h), not 5400 s.
2. `agent.gateway_timeout` (Hermes) is the inactivity watchdog. It is raised in step with the
   wall clock so the two do not disagree, and it must be set in the **host** config as well as
   the profile, because under multiplex the env bridge reads the launch profile once at import.
3. `maxConcurrentRuns` is sized so that a card waiting on a long render does not starve the
   other lanes. Three lanes for the Image Studio agent.
4. Any agent whose work waits on an external queue gets its **memory char caps** checked in the
   same review. A full memory store refuses every write, the agent retries, and the retries
   burn the very budget the ceiling is meant to protect.

Ceilings are reviewed whenever a dependency's latency changes — a slower model, a bigger
backlog, a longer queue.

## Consequences

Positive:

- A render round-trip can now complete inside one run. Cards stop parking in
  `recovery_needed` for reasons that have nothing to do with the card.
- The board's `running` state means the agent is actually working, not cycling through kills.
- A stalled run is distinguishable from a busy one: a genuine stall shows no tool calls, a
  render wait shows a long gap and then a fetch.

Negative:

- A genuinely wedged run now holds a slot for up to 4 h before it is cut. Detection of real
  hangs leans on liveness evidence (tool calls, work products) rather than on the clock.
- Ceiling values are environment-specific. The 4 h number is correct for a 25-minute render on a
  single worker; it is wrong for an agent that talks to a fast API, and it would be wrong again
  if a second render worker were added.
- The inactivity watchdog only takes effect after a gateway restart, because the env bridge runs
  once at import. A ceiling change is not fully live until the next natural restart.

## Alternatives considered

**Raise the ceiling as high as possible (24 h+).** Rejected: it trades a silent stall for a
silent stall that lasts a day, and it hides real wedges. 4 h is sized to the dependency, not
maximised.

**Make the render queue faster instead (second worker, smaller images, faster draft engine).**
Not rejected — it is the better long-term answer and the queue depth is the actual constraint.
Rejected *here* because it is a bigger change with a shared `jobs.db` and does not fix the class
of bug: any future slow dependency re-creates the same trap. The ceiling is the fix; a faster
queue is a separate decision.

**Have the agent chunk its work so each run fits under the ceiling.** Rejected: the work is
inherently a round-trip, so chunking means submitting renders, ending the run, and waking up
later to collect them. That is a legitimate design for very long jobs, but it adds a scheduling
layer to solve a problem a number fixes.

**Do nothing and let the agent use its own monitors.** Rejected: a monitor can defer the *next
action*, but it cannot extend the ceiling of the run that is currently in flight, and the kill
happens mid-render, before the next action.

**Catch it in monitoring — alert when a run approaches its ceiling.** Worth doing, and it is not
a substitute. Alerting on `finishedAt - startedAt` landing on the ceiling is how the pattern was
found; it reports the symptom. The ceiling change is the fix.

## When to revisit

- A second render worker lands, or the queue's typical wait drops below a few minutes. The 4 h
  ceiling is then oversized and should come down, not stay generous.
- The render model changes and job times move by an order of magnitude.
- Any new agent is added to the fleet: it gets a ceiling sized against its own slowest
  dependency, in the same change that creates it. Not inherited.
- The Paperclip adapter's timeout semantics change (for example, if a separate inactivity
  watchdog is introduced on the Paperclip side, the two ceilings need to be reconciled again).
