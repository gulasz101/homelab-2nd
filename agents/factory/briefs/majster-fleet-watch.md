<!--
Section to add to Majster's brief (GUL-793).
Placement: after "## Executor watchdog (every sweep)", before "## Board-token rule (GUL-297)".
Majster's instructions are Paperclip-managed (`GET/PUT /api/agents/<id>/instructions-bundle/file`),
so this section goes in whole, at that path, when it is applied. Delete this comment when you paste it.
-->

## Fleet watch (every sweep — GUL-793)

The board walk only sees an agent through the issues it holds. An agent that ended a run in `error`
and has **no issue assigned** is invisible: Paperclip's Attention panel computes `agent_error_alert`
only when a person opens the panel, and nothing writes it into a durable queue. Florian sat
`status: error` with "Process lost -- server may have restarted" from 30 Oct 08:18Z to 2 Nov and
nobody noticed for three days ([GUL-793](/GUL/issues/GUL-793)).

`error` is rewritten only when the agent's next run finishes, and a `hermes_gateway` agent has no
heartbeat timer — so no work means no run, and the latch never clears. The recovery issue below *is*
the fix: the run it starts clears the latch when that run finishes.

Run these three lines once per sweep, before the board walk:

```bash
curl -s -H "$H" "$API/companies/$PAPERCLIP_COMPANY_ID/agents" > /tmp/agents.json

# red agents — always worth a line and a recovery issue
jq -r '.[] | select(.status=="error")
       | [.id,.name,(.lastHeartbeatAt // "-"),(.errorReason // "-")] | @tsv' /tmp/agents.json

# "running" but silent for 2h is a zombie run, not a slow agent
jq -r --argjson cutoff "$(( $(date +%s) - 7200 ))" '
  .[] | select(.status=="running")
  | select(((.lastHeartbeatAt // "1970-01-01T00:00:00Z") | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601) < $cutoff)
  | [.id,.name,(.lastHeartbeatAt // "-")] | @tsv' /tmp/agents.json
```

Ignore `paused`, `terminated` and `pending_approval`: parked on purpose, not red. An `idle` agent
with an old heartbeat is also normal — most of this fleet runs only when work is assigned, so the
heartbeat ages while it waits.

**A red agent gets two things, in this order.**

1. **One line in the Morning brief for the PM** ([GUL-217](/GUL/issues/GUL-217)), under the sweep
   heading: `- Fleet: <name> in error since <heartbeat> "<reason>" → recovery <GUL-NNN>`.
2. **One recovery issue assigned to that agent** — that assignment is the only thing that clears the
   latch:

```bash
curl -s -X POST -H "$H" -H "$R" -H 'Content-Type: application/json' \
  "$API/companies/$PAPERCLIP_COMPANY_ID/issues" -d @/tmp/recovery.json
```

```json
{
  "title": "Recovery check: your last run ended in error — one comment, then close",
  "description": "Your agent record says `status: error` with `<reason>`, last heartbeat <time>. Nothing is assigned to you, so no run will ever clear it: `error` is only rewritten when your next run finishes.\n\nThis issue exists to give you that run. Do this and nothing else:\n\n1. Post one comment: `alive: <the model and profile you are running as>`.\n2. Close this issue (`done`).\n\nIf you cannot start, the wake sits in `deferred_issue_execution` — that is evidence too, and the foreman reports it. Opened by the hourly sweep ([GUL-793](/GUL/issues/GUL-793)).",
  "assigneeAgentId": "<the red agent id, exactly>",
  "projectId": "4c634772-3280-4203-8fba-576368593eab",
  "status": "todo",
  "priority": "medium"
}
```

No `parentId`: a red agent usually has no issue to hang it from.

**Hard limits on recovery issues.**

* **Max 3 per sweep.** More than three red agents is a broken fleet, not three sick agents — write
  one line in the brief saying so and stop fanning out.
* **Never twice for the same agent within 6 hours.** Check first:
  `GET $API/companies/$PAPERCLIP_COMPANY_ID/issues?q=Recovery check&assigneeAgentId=<id>` — an open
  one means the wake is already out; leave it. A red agent may be broken rather than sleepy, so the
  fuse is 6h, not the 2h you use for a nudge.
* **Never for yourself**, and never for `paused`, `terminated` or `pending_approval`.

**A zombie run gets no issue.** The run is live, so an assignment would queue behind it. Write one
line in the brief with the agent, its `lastHeartbeatAt` and the run's age. If the same agent is
still `running` with the same stale heartbeat on the **next** sweep, add one line for Andrzej
(`e12b834d-5e42-491a-9cd6-f4ddef2e97f8`) — once per agent per 12 hours, not every sweep: a run that
survives two sweeps is a hang, and one line is enough to get it looked at.

**A clean fleet writes no line.** Do not report "14 agents, all fine" — that is noise, and noise is
how a watchdog gets muted.
