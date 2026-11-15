# majster-sweep

Majster's hourly board walk, without a model. One stdlib Python script reads the
board with `GET` requests, applies the stuck rules from Majster's `AGENTS.md`,
and prints a short JSON report. A launchd wrapper looks at `actionable`: false
means the hour costs nothing, true means it starts a Majster run.

Why (GUL-1116, work order GUL-1238): Majster's hourly sweep made 103 runs and
read 85.6 M input tokens in four days, 0.83 M per run, because every board page,
per-issue `GET`, agents list and comment scan landed in the model's context and
was sent again on every model call. All of that reading is mechanical.

## Run

```bash
python3 -I agents/majster-sweep/sweep.py
```

`-I` is not optional: isolated mode keeps the run independent of the caller's
`PYTHONPATH` and user site-packages. Python 3 standard library only.

```
--fixtures DIR      read the board from JSON files in DIR instead of HTTP (tests)
--now ISO8601       clock for the age rules (tests); default: now, UTC
--stop-file PATH    default ~/paperclip-agents/majster/factory/STOP
--tick-cmd CMD      default "factory tick"; its stdout lines go into "tick"
--ps-file PATH      read `ps -axo pid=,ppid=,etime=,comm=` output from a file
```

Live mode needs `PAPERCLIP_API_URL`, `PAPERCLIP_API_KEY` and
`PAPERCLIP_COMPANY_ID` in the environment. A missing variable or an HTTP error
exits 2 with one line on stderr; the key is never printed.

## What it reads

Live mode, `GET` only:

1. `GET /api/companies/<co>/issues?status=todo,blocked,in_progress,in_review&limit=1000`
2. `GET /api/issues/<id>` for every row from (1). **The list is not evidence**
   (GUL-822 was listed `in_review` while its own `GET` said `done`). A 404 on
   this call skips the row.
3. `GET /api/issues/<id>/comments?order=desc&limit=30` and
   `GET /api/issues/<id>/interactions` for the rows a rule needs.
4. `GET /api/companies/<co>/agents`.
5. `ps -axo pid=,ppid=,etime=,comm=` — and only those arguments (GUL-206: any
   other `ps` flags print the Paperclip server's secrets from this Air).
6. `--tick-cmd`, whose stdout lines are kept verbatim.

Fixture mode reads the same data from `DIR/issues.json`, `DIR/issues/<id>.json`,
`DIR/comments/<id>.json`, `DIR/interactions/<id>.json`, `DIR/agents.json` and
`DIR/ps.txt`. A missing per-issue file means the `GET` answered 404.

## Rules

Skipped: `backlog`, `cancelled`, `done`; issues created less than 15 minutes
before `--now`; project Morning Brew (`149ae0a6-88d4-4b49-bb6d-7f605182922f`);
issues titled `Hourly board sweep`; GUL-217
(`0b22bbd4-9766-422b-87a4-f2a8e4935976`), because that is the sweep's own board.

| kind | condition (from the per-issue `GET`) | needs model |
|---|---|---|
| `hold` | `executionBlocker` is not null | yes |
| `stalled` | `in_progress`, `updatedAt` older than 60 min | yes |
| `blocker_cleared` | `blocked`, `blockedBy` non-empty and every entry `done` or `cancelled` | yes |
| `orphan_blocked` | `blocked`, `blockedBy` empty, zero comments | yes |
| `never_started` | `todo`, has `assigneeAgentId`, `updatedAt` older than 2 h, `startedAt` null | yes |
| `waiting_human` | `in_review`, an interaction `status: pending` older than 12 h | no |
| `agent_error` | agent `status: error` (never Majster itself) | yes |
| `agent_zombie` | agent `status: running`, `lastHeartbeatAt` older than 2 h | no |
| `impersonation` | a comment in the last 24 h with `authorType: user` and `createdByRunId` set | no |
| `long_child` | a `ps` row for `find`, `grep`, `sleep` or `watch` running over 5 min | yes |

Agents with status `paused`, `terminated` or `pending_approval` are ignored
entirely: parked on purpose, never reported.

## Output

Exactly one JSON object on stdout:

```json
{
  "now": "2026-11-09T18:00:00Z",
  "open": 57,
  "stop": null,
  "actionable": true,
  "items": [{"kind": "hold", "issue": "GUL-123", "id": "<uuid>", "agent": "<agentId or null>", "detail": "<one line, max 160 chars>"}],
  "truncated": 0,
  "tick": ["<factory tick line>", "..."],
  "brief_md": "<!-- sweep:2026-11-09T18:00Z -->\n## Sweep 2026-11-09 18:00Z\n- ..."
}
```

- `stop` is the STOP file's text when it exists, else `null`. When set, the first
  line of `brief_md` after the heading is `factory STOPPED: <text>`.
- `actionable` is true when at least one kept item is a "needs model: yes" kind.
- `items` holds at most 15, needs-model kinds first; the rest count in
  `truncated`.
- `brief_md` is the section Majster would post on GUL-217 for this hour: the
  marker and heading, the STOP line, one line per item, the tick lines. A board
  with no items gives the heading, `- quiet board, nothing needed` and the tick
  lines.

Exit codes: `0` nothing needs a model, `10` `actionable` is true, `2` setup
error.

The script never writes to Paperclip: no `POST`, `PATCH`, `PUT` or `DELETE`
anywhere in it. Posting the brief, nudging and hold releases stay with Majster or
the launchd wrapper.

## Checks

One script per acceptance criterion; each prints its own `AC-n: PASS|FAIL`:

```bash
bash agents/majster-sweep/tests/quiet-board-check.sh
bash agents/majster-sweep/tests/rules-check.sh
bash agents/majster-sweep/tests/per-issue-get-check.sh
bash agents/majster-sweep/tests/skip-rules-check.sh
bash agents/majster-sweep/tests/no-model-kinds-check.sh
bash agents/majster-sweep/tests/stop-and-tick-check.sh
bash agents/majster-sweep/tests/size-cap-check.sh
bash agents/majster-sweep/tests/read-only-check.sh
```
