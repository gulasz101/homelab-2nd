# ADR-099: A consolidation-failed memory is a debt, not a tombstone — requeue it and alert on the stock

- **Status**: Accepted
- **Date**: 2026-10-29
- **Issue**: GUL-559 (found while triaging GUL-556)
- **Related**: ADR-085 (FreeLLMAPI `auto` route for retain/consolidation), ADR-094 (reflect gets its own paid route), GUL-556 (consolidation backlog growth alert)

## Context

Hindsight marks a source memory `consolidation_failed_at` only after both the
retry budget and the adaptive bisection have failed: the LLM call was re-sent,
the batch was split, and still nothing usable came back. The row keeps its text
and its embedding — it stays **recallable** — but three things change:

- it leaves `hindsight_consolidation_backlog` (which counts
  `consolidated_at IS NULL AND consolidation_failed_at IS NULL`),
- it leaves the reconcile sweep's work set (`banks_needing_consolidation()`
  filters the same way), and
- no operation fails, no backlog grows, no later log line mentions it.

So the state is *self-terminating*: nothing will ever look at that row again.
The observable damage is quiet — the fact never folds into an observation, so
recall answers from raw memories and the knowledge base silently stops
synthesising that part of the corpus.

On 2026-10-29 the stock was **1,633 rows** (1,609 in `hermes-andrzej`, 1,468 of
those stamped inside one hour on 2026-10-23) — damage from the October
gpt-oss-schema / FreeLLMAPI route churn, invisible for six days. The gauge
`hindsight_consolidation_failed` already existed in 0.10.3; **no alert used it**,
which is why 1,633 permanently-stuck facts looked exactly like a clean system.

## Decision

1. **Permanently-failed consolidation is a debt with an owner, not a tombstone.**
   When the route that broke them is fixed, requeue them: clear
   `consolidation_failed_at` (and `consolidated_at`, which is already NULL) via
   `POST /v1/default/banks/{bank_id}/consolidation/recover`, and let the
   reconcile sweep re-enqueue the bank. Do not abandon rows silently, and do not
   delete them — the facts are fine, only the synthesis step failed.
2. **Batch the requeue.** Every requeued row returns to the consolidation queue,
   and consolidation is LLM-latency bound (~30-60 s per LLM call on the free
   route, ~3.8 memories per call, 100 memories per round). Measured here: the
   1,609-row requeue drained `hermes-andrzej` at roughly 500-2,000 rows/h, i.e.
   a few hours of that bank's single consolidation slot (a serial 30 s/memory
   estimate would have said 16 h, so measure before believing the model). Requeue
   in waves (400 rows ≈ 4 min apart here) and
   watch `hindsight_consolidation_backlog` and
   `hindsight_consolidation_failed` between waves. The app's recovery endpoint
   is bank-wide; a subset needs the identical `UPDATE` run directly (documented
   as break-glass in the tracking note, no `updated_at` bump).
3. **Alert on the STOCK, with a zero baseline.** `HindsightConsolidationFailedRows`
   fires on `sum(hindsight_consolidation_failed) > 0` for 30 m. A delta rule
   would have been silent on exactly this incident (a flat 1,633 for six days);
   one row in this state is already a lost synthesis, so the expected value is
   zero and any non-zero reading is a warning, not a trend.
4. Requeueing is a **deliberate trade**: while a bank drains a large requeue, its
   own fresh memories wait behind the older rows for observation-folding. Recall
   is unaffected (raw memories), so a day of synthesis lag on one bank is the
   accepted price. Check the route first: requeueing into a still-broken route
   just re-marks the rows and burns the tokens twice.

## Consequences

- Legacy damage is recoverable, and recovery is a documented one-liner per bank
  instead of an archaeology session.
- The 1,633 legacy rows cost ~430 extra consolidation LLM calls (~6.3 M tokens
  at the measured 14.7 k tokens/call) and a few hours of `hermes-andrzej`'s
  consolidation slot — during which that bank's fresh memories wait behind the
  older requeued rows before folding into observations.
- Once the stock is zero, `HindsightConsolidationFailedRows` is a clean
  ground-truth signal for "a fact will never be synthesised", which no other
  metric provides — backlog and operation counters both stay green in this state.
- A single row that fails on a transient route hiccup will page after 30 m.
  Accepted: it is a warning, it is rare, and the recovery is one HTTP call.

## Alternatives considered

- **Abandon the 1,609 rows as historical damage.** Zero cost, but the whole
  OpenViking entity/procedure corpus of one bank would never synthesise, and the
  decision would have to be re-made for every future outage. Rejected: the fix
  is cheap and idempotent.
- **Delete the rows.** They are correct facts; only consolidation failed.
  Deletion is the one irreversible option and it was never needed.
- **Requeue everything in one statement.** Simplest, and the endpoint does
  exactly that — but it removes the ability to abort after 400 rows if the route
  turns out to be broken, and it hides the load in one step.
- **Alert on `increase(hindsight_consolidation_failed[6h]) > 0`.** Silent on a
  stock that predates the alert window, which is precisely how this happened.

## When to revisit

- If Hindsight starts retrying permanently-failed rows on its own (then the
  requeue is unnecessary and the alert should follow its new counter).
- If consolidation becomes fast enough (~seconds per memory) that a full requeue
  is cheap — then one-shot recovery is fine and wave batching can go.
- If `hindsight_consolidation_failed` is ever non-zero because of a *known*
  poison document (a row that will always fail the schema), the rule needs a
  documented exception list rather than being switched off.
