# ADR-019: Itsaplan agent results post back as issue comments via the bridge

Date: 2026-09-15
Status: Accepted
Supersedes: (extends) ADR-018 — OpenChamber worker on t460

## Context

Delegated Itsaplan tasks run to completion in OpenChamber, but their answers never
reached the source issue. On H2-19 (2026-09-15):

- Run 4 and run 6 (agent `openchamber`, trigger mention) failed with
  `Timed out after 1800000ms` — the bridge's 30-min default while the runner-side
  `timeoutMs` had already been raised to 4h. Any timeout fix must raise both.
- Run 5 "succeeded", but its answer only reached the issue because the human
  (Administrator) copy-pasted it as a comment. That is not automation; it is the
  user acting as human FTP between two of his own systems.
- The OpenChamber worker sessions have no Itsaplan credentials or MCP tools
  (deliberately — see ADR-018), so they cannot comment on the issue themselves.
- The runner (`@itsaplan/runner` v0.5.0) does post stdout to
  `POST /agent-runs/{id}/result`, but the run feed does not surface that output
  as issue feedback; analytics showed `success` while the ticket stayed silent.
- Mention triggers fire on ANY comment that contains an agent handle — not just
  user comments (verified on H2-19: run 7 started 1.7 s after a bot-authored
  comment containing `@andrzej`). A naive "post answer including @openchamber
  handle" design would therefore re-spawn the runner from its own comment — an
  infinite self-mention loop.

## Decision

The Itsaplan bridge (`bridge.js`, in `apps/openchamber/openchamber-itsaplan-bridge-configmap.yaml`)
posts the run outcome back to the source issue itself:

1. On success: one comment — `@admin Deliverable — OpenChamber session <id>`
   followed by the assistant's final text (truncated at 12,000 chars).
2. On failure/timeout: one comment with the error head (first 4 lines, 800 chars),
   posted inside a bridge budget that sits 5 minutes under the runner lease
   (`OPENCHAMBER_TASK_TIMEOUT_MS=14100000` vs runner `timeoutMs=14400000`), so
   failure comments land before the runner reaps the process.
3. Auth: the runner pod's existing `ITSAPLAN_API_KEY` (the OpenChamber agent's own
   key, already mounted for claiming runs) against `POST /issues/{id}/comments`
   with header `x-api-key`. No new credentials, no secret spread.
4. Comment posting is strictly best-effort and try/catch-wrapped — it never
   changes the run outcome reported via stdout/result.
5. Agent handles (`@openchamber`, `@andrzej`) are neutralised with a zero-width
   space in every posted comment, preventing self-re-trigger loops.
6. The stdout → `POST /agent-runs/{id}/result` channel is unchanged; the comment
   is an addition, not a replacement.
7. The arr-box Andrzej path (`post-to-andrzej.js`) is untouched — the Hermes-side
   webhook session already reports back itself via Itsaplan MCP.

## Consequences

Positive:
- Every delegated OpenChamber task leaves a visible, attributable answer (or
  failure reason) directly on the issue; no human relay.
- Failures are as visible as successes — analytics "failed" plus a ticket comment.
- No new credentials; uses the key the runner already needs.
- Budget layering (bridge = lease − 5 min) makes timeouts self-documenting.

Negative:
- The bridge now holds a write capability toward Itsaplan issues (still scoped to
  the OpenChamber agent's key permissions).
- If Itsaplan is down at completion time, the deliverable exists only in the run
  result / OpenChamber UI (same as before; nothing lost, but no comment).
- Comment truncation at 12,000 chars may hide the tail of very long answers.

## Alternatives considered

- **Provision Itsaplan MCP tools + API key into worker sessions** (the arr-box
  pattern): rejected — spreads an API key into every OpenCode session, conflicts
  with ADR-018's credential-minimisation stance, and adds per-session tool
  wiring. The bridge is one process, one key, one place.
- **SCIM/bot token or worker token for comments**: rejected — instance-level
  shared tokens (`x-worker-token`, SCIM bearer) would overreach what a single
  agent needs to do.
- **Rely on the run feed UI**: rejected — the feed does not surface run output
  usefully and analytics-only "success" is exactly what caused the blind spot.
- **Have users poll the OpenChamber UI**: rejected — this is the human-FTP
  anti-pattern that triggered this ADR.

## When to revisit

- If Itsaplan grows native runner-output surfacing (e.g. run output rendered on
  the issue), the comment layer could become redundant.
- If per-claim env ever includes the lease timeout (`ITSAPLAN_TIMEOUT_MS` is NOT
  exported to the command child as of runner v0.5.0), the deployment-side margin
  env can be dropped in favour of deriving it in-script.
- If mention-trigger semantics change to exclude bot-authored comments, the
  handle-neutralisation can be dropped.