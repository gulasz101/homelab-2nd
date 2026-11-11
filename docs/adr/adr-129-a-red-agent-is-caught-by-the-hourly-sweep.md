# ADR-129: ADR: A permanently red agent is caught by the hourly sweep, not by the Attention panel

- **Status**: Accepted
- **Date**: 2026-11-02
- **Issue**: GUL-793
- **Related**: GUL-786 (the recovery run that clears the latch), ADR-087 (an hourly watchdog owns board triage), ADR-088 (the watchdog owns the day, the PM reads a brief), ADR-093 (the factory's scripted gates; the human keeps the judgement calls)

## Context

On 2026-11-02 Florian was found with `status: error`, `errorReason: "Process lost -- server may have
restarted"` and `lastHeartbeatAt: 2026-10-30T08:18Z`. Three days red, nobody told.

Every check we had was blind to it, and each for a different reason:

- **Paperclip's Attention panel** (`services/attention.js`) does compute an `agent_error_alert` at
  severity `high` for `agents.status = 'error'` — but it computes it *on request*, when a person
  opens the panel. Its seeded decision queues are `questions`, `prs` and `plans`; there is no alert
  queue. Measured while Florian was red:
  `select count(*) from decision_queue_items where source_kind='agent_error_alert'` → **0**.
- **Majster's hourly sweep** (ADR-087) flags a *stalled issue* whose assignee is `idle` or `error`.
  An agent with no open issue has no issue to be stalled on, so the sweep could not see it.
- **A metric scrape** was the obvious third option and does not exist. Measured:
  `curl -s http://127.0.0.1:3100/metrics` returns the React shell (`<!DOCTYPE html>`, 159 non-comment
  lines of HTML — the SPA fallback), and `kubectl get all -n paperclip` shows only the
  `paperclip-db` CNPG cluster: no exporter, no `postgres_exporter` anywhere in `homelab-2nd`.

The latch is sticky by design. `error` is not an invokability blocker
(`agent-invokability.js` blocks only `paused`, `terminated`, `pending_approval`), but it is rewritten
only when the agent's next run *finishes*. With `runtime_config.heartbeat.enabled = false` on every
`hermes_gateway` agent, the next run happens only when work is assigned. No work, no heartbeat, no
clear — forever.

So the detection gap and the recovery action are the same missing thing: an assignment that nobody
makes because nobody knows.

## Decision

**The hourly sweep watches the agents themselves, and one recovery issue per red agent is both the
alert and the cure.**

In Majster's brief, once per sweep, before the board walk:

1. `GET /api/companies/<company>/agents`, then flag two states: `status = error` (a latch), and
   `status = running` with `lastHeartbeatAt` older than 2h (a zombie run).
2. **Red agent → one line in the morning brief** ([GUL-217]) plus **one recovery issue assigned to
   that agent**. The assignment wakes it; the run that finishes rewrites `status` to `idle`. That is
   the GUL-786 recovery, automated.
3. **Hard limits**: max 3 recovery issues per sweep, never the same agent twice within 6h, never for
   oneself, and never for `paused` / `terminated` / `pending_approval` — those are parked on purpose.
4. **Zombie run → no issue** (the run is live; an assignment would queue behind it): one brief line,
   and a second sweep with the same stale heartbeat adds a line for Andrzej, at most once per agent
   per 12h.
5. `idle` is never a fault, however old its heartbeat: most of this fleet runs only when work is
   assigned.

A clean fleet writes no line at all.

## Consequences

**Good.** Detection within one hour, with no change to Paperclip itself and no new component. The
record is durable and dated (a brief line plus an issue), not a panel somebody has to open. The
recovery is automatic: the same issue that reports the fault clears it.

**Bad.** The watchdog now watches itself for one class of failure, so a red Majster is still only
found by a person. The worst-case cost is 3 extra agent runs per sweep, and a genuinely broken agent
(e.g. a dead adapter) will be woken every 6h indefinitely — the fuse limits the rate, it does not
stop it. That is deliberate: a run that cannot start leaves a `deferred_issue_execution` wake, which
is the evidence we want.

**Neutral.** The brief is already the human surface for everything else the sweep finds, so this adds
a line shape, not a new inbox.

## Alternatives considered

- **Persist `agent_error_alert` into a seeded decision queue and materialize it on a timer.** The
  honest fix, and the right one long-term — but it is a change to the Paperclip server, not to
  anything we own, and it would need to survive upstream updates. Rejected as the *first* move, not
  as a bad idea.
- **Scrape agent status as a Prometheus metric and alert through Alertmanager.** Nothing exists to
  scrape: no exporter for the Paperclip DB, and `/metrics` is the SPA. It would mean a new exporter
  component (postgres_exporter with a custom query, a ServiceMonitor, a rule, a dashboard) to catch
  one boolean. Better than the sweep when it exists — file it as the follow-up, do not build it for
  this.
- **Turn `runtime_config.heartbeat.enabled` on fleet-wide.** A run per agent per hour, forever, to
  keep a field fresh. Rejected on cost: that is the single most expensive way to read one column.
- **A Grafana/Prometheus alert on "no heartbeat" from the OTel side.** The agents do not emit
  anything when they are not running. Absence of a metric is only detectable as `absent()` over a
  series that must exist — which brings us back to an exporter.

## When to revisit

- When Paperclip grows a durable alert queue (or a real `/metrics`): move detection there and let the
  sweep keep only the recovery issue.
- If the 6h fuse turns out to be too slow for a real incident, shorten it — the reason to keep it long
  is cost, not correctness.
- If Majster itself goes red, this design cannot report it. That is the residual gap and the reason
  the exporter option stays on the table.
