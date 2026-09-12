# Itsaplan task reconstruction from saved container logs

**Date:** 2026-09-12
**Source artifact:** `/home/voitech/homelab-recovery/itsaplan-logs-arr-box.tgz`
(SHA-256 `445ea72eaafb68c6f14aca0f43a3fd3035989cbb50f6169a240cbf9ec52bfc21`, 55918 bytes)
**Machine-readable dump:** [`itsaplan-reconstruction/tasks.json`](./itsaplan-reconstruction/tasks.json)
**Status:** Analysis-only. No data was written to the Itsaplan database or API.

## TL;DR

**Zero (0) task records were recoverable.** The tarball does **not** contain pre-wipe
task data. It contains the container logs of the pods that started *after* the database
was wiped, on 2026-09-11 between 22:29:52 and 22:43:19 +02:00 — i.e. the fresh, empty
database's own startup logs. There is therefore nothing to reconstruct and nothing to
re-create.

Confidence that no task data is present: **high**. All six logs were parsed
programmatically (CRI prefix stripping, field/keyword scan, JSON & SSE extraction,
endpoint and UUID enumeration) and the current database was queried directly.

## What the logs actually are

| Pod | Lines | What it contains |
|---|---|---|
| `itsaplan-api` | 5385 | `Running migrations...` → `✅ Migrations applied`, then ~500 repeats of `[planner] unhandled error: APIError: Invalid API key.` |
| `itsaplan-worker` | 210 | `[worker] worker starting`, then `relation "webhook_delivery" does not exist` while the API was still migrating |
| `itsaplan-andrzej-runner` | 442 | 314 × `claim failed` (HTTP 500/502), 126 HTML/JSON error bodies, 1 startup banner. **No task payload was ever claimed.** |
| `itsaplan-web` | 6 | Next.js ready banner only |
| `cloudflared-plan` / `cloudflared-plan-api` | 45+131 | Tunnel startup; only proxied paths seen are `/agent-runs/claim`, `/agent-chats/claim`, `/mcp` |

Global time range: **2026-09-11T22:29:52.222936927+02:00 → 2026-09-11T22:43:19.634265402+02:00**.
The API log proves this is the post-wipe database creation (`Running migrations...` then
`Migrations applied`), not a snapshot of pre-wipe operation.

## What was searched for, and found

The parser looked for: task `title`/`description`/`status`/`assignee`/`created-at`/`id`,
webhook payloads, JSON request/response bodies, SSE records, issue numbers, e-mails,
human-readable titles, and all UUIDs.

- JSON-looking `"title"`, `"description"`, `"assignee"`, `"status"`, `"id"` fields: **0**
- Webhook / agent-run / task payloads: **0**
- Human-readable task tokens (`ABC-123`, `#123`, e-mails): **0**
- UUIDs found: 14, all infrastructure IDs (cloudflared tunnel/run IDs, CNPG/connection
  identifiers from migration `NOTICE`s). None are issue/task/project IDs.

## Current database state (read-only, via CNPG primary)

| Object | Rows |
|---|---|
| `issue` | 0 |
| `project` | 0 |
| `user` | 0 |
| `project_column` | 0 |
| `issue_activity` | 0 |
| `issue_status` | 0 |
| `issue_type` | 0 |
| `issue_attachment` | 0 |
| `agent_run` | 0 |
| `drizzle.__drizzle_migrations` | 119 (schema is at the latest migration) |

The schema is fully migrated and completely empty. Every project / board / column /
issue-type / user identifier that a task would have referenced was destroyed with the
database.

## Recovered tasks

None. See [`itsaplan-reconstruction/tasks.json`](./itsaplan-reconstruction/tasks.json)
(`recovered_tasks: []`), which additionally records provenance, the search scope, the DB
state, the API model, and the blockers.

## How tasks *would* be re-created (and why we did not)

The API shape was recovered from `scripts/itsaplan_sync.py` plus the live app logs:

- **MCP endpoint:** `https://plan-api.voitech.dev/mcp` — JSON-RPC 2.0 over HTTP POST,
  responses are `text/event-stream` (`data:` lines).
- **Auth:** `Authorization: Bearer <MCP_ITSAPLAN_API_KEY>`.
- **Tools:** `get_project {projectKey}` (returns `columns[]` with `stateType` and
  `issueTypes[]`), `list_issues {projectKey, limit}` (returns titles), and
  `create_issue {projectKey, columnId, title, description, priority, typeId?}`.
- **Idempotency pattern (from the sync script):** embed a stable fingerprint in the title,
  `list_issues` once, skip any title already present, then create only missing ones.
- **Agent runner REST:** `POST /agent-runs/claim`, `POST /agent-chats/claim`
  (the runner uses `ITSAPLAN_API_KEY` from `itsaplan-andrzej-agent-key`).

**We deliberately did not re-create anything.** Step 4 requires sufficient data and a
clearly safe path; neither condition holds:

1. **No recovered records** — nothing to create.
2. **No API key** — `MCP_ITSAPLAN_API_KEY` is not present in the `itsaplan` namespace
   secrets or in this repo (the security-scan sync that uses it runs externally, "Hermes").
   The only cluster key is the 68-char agent key in `itsaplan-andrzej-agent-key`, which is
   for the runner, not the MCP `create_issue` flow.
3. **No target IDs** — project `H2`, its board columns, issue types and the user account
   are all gone (0 rows), so `get_project`/`create_issue` have nothing to target.
4. **The app is unhealthy** — the runner currently gets HTTP 500 from
   `/agent-runs/claim` and `/agent-chats/claim`, and the API logs
   `[planner] ... APIError: Invalid API key`, so writes would fail regardless.

## Recommended next steps

To actually recover pre-wipe task data, look beyond this tarball:

1. **Loki / Grafana retention** for namespace `itsaplan` with a time window *before*
   2026-09-11T22:29 (query the `itsaplan-api`/`worker` streams for task JSON).
2. **Rotated logs on the arr-box node** — any `*.log.2026-09-1*` / compressed rotations or
   journald entries for the previous pods.
3. **OMV MinIO** — bucket `itsaplan-attachments` and any pre-prune database dump.
4. Fix the app's planner/provider API key so the runner stops failing in the meantime.
