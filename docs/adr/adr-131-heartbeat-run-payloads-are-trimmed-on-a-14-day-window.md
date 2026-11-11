# ADR-131: Heartbeat run payloads are trimmed on a 14-day window

- **Status**: Accepted
- **Date**: 2026-11-10
- **Issue**: GUL-1288
- **Related**: ADR-107 (host jobs run as system LaunchDaemons), ADR-032 (Cloudflare tunnels), the CNPG cluster in `apps/paperclip/postgres-cluster.yaml`

## Context

`heartbeat_runs` held 3,035 rows in **441 MB**. Every agent run writes the agent's entire raw
`stdout` into `result_json -> 'stdout'`: that single key is ~1.7 GB of JSON content, and it is
written again into `stdout_excerpt`. The table therefore grows ~20 MB/day on a 10 Gi volume.

The performance problem was not the size, it was one query on the board path:

```sql
select jsonb_build_object('paperclipSecretRedactions', context_snapshot -> 'paperclipSecretRedactions')
from heartbeat_runs
where company_id = $1
  and (context_snapshot ->> 'issueId' = $2 or context_snapshot -> 'paperclipIssue' ->> 'id' = $3);
```

It was 75% of all active samples in `pg_stat_activity`. The app already ships an expression index
for the `issueId` branch, but none for the `paperclipIssue -> id` branch, so the `OR` could not be
satisfied by an index and Postgres seq-scanned the whole table and detoasted 110 MB of
`context_snapshot` per execution — 1,602 ms, 53,875 buffers — to return 2 rows.

## Decision

Two things, both owned by one daily CronJob in `apps/paperclip/heartbeat-retention.yaml`:

1. **One expression index**, `heartbeat_runs_ctx_paperclip_issue_idx` on
   `(company_id, ((context_snapshot -> 'paperclipIssue' ->> 'id')))`. The job creates it with
   `if not exists`, so it is a no-op after the first run and a fresh cluster gets it too.
   The query drops to a 45-buffer bitmap scan, 0.76 ms.
2. **Payload retention at 14 days**, applied only to terminal runs (`succeeded`, `failed`,
   `cancelled`, `interrupted`, `timed_out`). It strips `result_json -> 'stdout'`, `-> 'output'`,
   and both excerpt columns. It does not delete rows: 60 foreign keys reference `heartbeat_runs`,
   and row deletion would either fail or cascade into unrelated tables.

The row keeps its status, timestamps, summary, usage and identity keys, so board history and cost
reporting still work. What goes away is the raw transcript of runs older than two weeks.

## Consequences

- Table is bounded instead of growing forever: ~360 MB and flat, rather than +20 MB/day.
- Old runs (>14 days) no longer show raw stdout in the UI. Summaries remain.
- The index is a workaround for an upstream query shape; the real fix is for Paperclip to store
  raw stdout in its log store instead of in `result_json`. That is a code change in
  `gulasz101/paperclip` and belongs to the factory, not to this repo.
- The first pass freed 81 MB (`vacuum full`); routine passes only run `vacuum (analyze)`, so the
  file stops growing rather than shrinking to the theoretical minimum.

## Verified after merge

Flux `apps` is at `main@sha1:1d26676`; both the ConfigMap and the CronJob carry
`kustomize.toolkit.fluxcd.io/name: apps`, all four kustomizations `Ready`. First scheduled run
04:30 CET, job `Complete 1/1` in 9 s.

Board path: `GET /api/issues/<id>/heartbeat-context` **0.15 s** — it was 1.60 s of Postgres CPU
per call before the expression index, and 14.7 s while an unfiltered `SELECT * FROM heartbeat_runs`
was in flight. `heartbeat_runs` sits at 391 MB / 3,226 rows, of which only **206 MB of `result_json`
is inside the 14-day window**: that is the steady state this policy holds, about 15 MB/day of new
payload.

## Alternatives

- **Delete old rows.** Cheapest on disk, but 60 FKs and a cascade audit make it a data-loss
  decision rather than a retention rule. Rejected.
- **30-day window.** Matches `backup.retentionPolicy: 30d` and keeps more history, but the table
  only spans 21 days today, so it would trim nothing and defer the problem. 14 days is the
  compromise between history and a flat table.
- **Compress the blobs (`pg_column_compression: lz4`).** Keeps every byte of stdout, costs CPU on
  every write and read. Storage is not the constraint here; the constraint is not carrying
  transcripts forever.
- **Do nothing and buy more disk.** A 10 Gi volume and a daily backup to MinIO would absorb it for
  a year, and then the backup window and `pg_dump`-shaped work get slower for no reason.

## When to revisit

- If the factory fixes the storage of raw stdout in `gulasz101/paperclip`, this job reduces to the
  retention half and the index goes away.
- If anyone needs to read a transcript older than 14 days for debugging or a blog post, the source
  is the MinIO backup (30 days of base backups + WAL) — restore elsewhere, do not widen the window.
- If `heartbeat_runs` gains cascade-delete children, revisit whether row deletion is safe.
