---
title: "Improve task note observability and homelab-task-executor reporting"
status: done
priority: medium
created: 2026-08-17
labels:
  - homelab
  - tasks
  - cronjob
  - observability
  - frontmatter
assigned: andrzej
---

## Context

The Supreme Leader asked for two improvements after the security scan task-list fix:

1. Better observability of task notes using their frontmatter.
2. The `homelab-task-executor` cronjob should update task note frontmatter after execution and report what was done to the Mattermost channel `mrnhuzmr63fuzrbky893j4if6c`.

## Changes

### 1. Security scan now renders open tasks as a markdown table

Updated `scripts/homelab-security-scan.sh` so that when there are critical findings and the "Open task notes" section is printed, it reads each task note's YAML frontmatter and outputs a markdown table:

| File | Title | Status | Priority | Created | Labels |
|------|-------|--------|----------|---------|--------|

The script filters for `status: open` or `status: in_progress` and extracts:
- `title`
- `status`
- `priority`
- `created`
- `labels` (list flattened to comma-separated)

If no open/in-progress tasks exist, it prints `(none)`.

Commit: `e406071`

### 2. Updated `homelab-task-executor` cronjob prompt

Cronjob ID: `e21fa9f94e97`
Schedule: `0 4 * * *`
Delivery: `mattermost:mrnhuzmr63fuzrbky893j4if6c`

The prompt now explicitly requires the executor to:
- Only act on notes with `status: open` or `status: in_progress`.
- After executing a task, update the frontmatter:
  - `status: done`
  - `completed: YYYY-MM-DD`
  - `updated: YYYY-MM-DD`
- Append a verbose `## Execution log` section with:
  - what changed,
  - why,
  - exact commands run,
  - verification output,
  - errors or dead-ends,
  - final state / commit SHA.
- For blocked tasks, set `status: blocked` and add `blocked_reason: <why>`.
- Deliver a final report to the channel (no `[SILENT]`):
  - If no open tasks: `No open homelab tasks. Executor checked N task notes, all done/blocked.`
  - If tasks were executed: a markdown summary table `| Task | Status | Outcome |`, per-task details, verification, commits, and blockers.

### 3. Manual test run

Manually triggered the executor after the prompt update. It correctly produced:

```
No open homelab tasks. Executor checked 5 task notes, all done/blocked.
```

This confirmed the new reporting format works and that there are currently no open tasks.

## Verification

- [x] `bash -n scripts/homelab-security-scan.sh` passes.
- [x] Ad-hoc Python test verified the table-rendering logic against mixed-status dummy task notes.
- [x] `homelab-task-executor` manual run produced the expected non-silent report.

## Notes

- The executor's output was generated successfully but the Mattermost plugin reported a delivery error: `Timeout context manager should be used inside a task`. This is a Hermes gateway/plugin issue, not a problem with the executor prompt or the scan script. The cronjob is still scheduled and the output is archived in `~/.hermes/profiles/andrzej/cron/output/e21fa9f94e97/`.
- Existing task notes (001–005) already use the frontmatter schema the executor and scan script expect. Future task notes should keep the same schema.

## Files changed

- `scripts/homelab-security-scan.sh`
- Hermes cronjob `e21fa9f94e97` prompt (scheduler-side, not a repo file)

## Related

- Task note template / schema: `title`, `status`, `priority`, `created`, `labels`, `assigned`, `source`, `scan_date`, `scan_commit` (optional), `completed` (added by executor), `updated` (added by executor), `blocked_reason` (added by executor when blocked).
