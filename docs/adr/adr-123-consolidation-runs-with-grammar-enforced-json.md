# ADR-123: Consolidation runs with grammar-enforced JSON, and its rejection alert needs a floor

- **Status**: Accepted
- **Date**: 2026-11-02
- **Issue**: GUL-791
- **Related**: ADR-085 (FreeLLMAPI `auto` carries retain and consolidation), ADR-099 (a consolidation-failed row is a debt), GUL-428 (retain's own FreeLLMAPI tuning), H2-306 (batch size 16 -> 8 for the same field-dropping)

## Context

Hindsight's consolidation asks the model for a constrained object
(`_ConstrainedConsolidationBatchResponse`: `creates` / `updates` / `deletes`,
each action carrying `text`, `source_fact_ids` and — for updates — an
`observation_id`). The response is validated by Pydantic. A response that fails
validation is `failure_class="fail_fast"`: re-sending the identical payload
cannot help, so consolidation halves the batch and retries. Anything bisection
cannot rescue leaves the row with `consolidation_failed_at` (see ADR-099).

Measured on 2026-11-02 on this deployment (hindsight-api 0.10.3-slim, FreeLLMAPI
`auto`, `HINDSIGHT_API_CONSOLIDATION_LLM_BATCH_SIZE` at the app default 8):

| signal | value |
| --- | --- |
| `hindsight_consolidation_batch_failures_calls_total{failure_class="fail_fast"}`, 7 d | 26 |
| `hindsight_llm_calls_total{scope="consolidation"}`, 7 d | 24,219 |
| baseline reject rate | **0.11%** (one per ~930 calls) |
| worst window | 3 rejects in 15 min (11-02 05:03Z–05:18Z), 7 in 6 h |
| rows stranded | 2 |
| consolidation backlog | 4 (drained) |

Two things were wrong, and they are independent.

**1. The alert had no floor.** The upstream docs' own query is
`sum(rate(hindsight_consolidation_batch_failures_total{failure_class="fail_fast"}[15m])) > 0`
with `for: 15m`. One rejected batch keeps that rate non-zero for ~15 minutes and
the rule then stays red for another 15, so a *single* bad batch — in a lane that
makes ~145 calls an hour — costs half an hour of `firing`. On 2026-11-02 it was
red on 3 rejects while the backlog was drained and consolidation was completing
normally. `> 0` also carries no information about whether the reject rate
matters: 7 rejects against 51 consolidation *operations* reads as 13%, while the
same 7 against 24,219 *calls* reads as 0.03%. Operations is the wrong
denominator; an operation makes tens of calls.

**2. The cause was the model, and it is fixable without changing the route.**
Every rejected call in `llm_requests` was a missing-required-field
`ValidationError` (`updates[N].observation_id`,
`creates[N].source_fact_ids`, and once a list where an object was expected).
The soft path (`response_format: json_object`) already appends the full JSON
schema to the system prompt, so the models had been told what to emit and dropped
fields anyway. `auto` had moved onto small members — in one five-minute window it
served voxtral-small-latest, mistral-code-latest, ministral-3b-latest and
poolside/laguna-xs-2.1. This is the same pathology H2-306 mitigated by dropping
the batch size from 16 to 8; the pool's membership has changed since, and the
default 8 no longer carries it.

## Decision

1. **Consolidation calls the model with `json_schema` `strict: true`.**
   `HINDSIGHT_API_LLM_STRICT_SCHEMA_CONSOLIDATION: "true"` in
   `apps/hindsight/hindsight-helm-release.yaml`. It is a per-operation knob
   (`config.py::_resolve_operation_strict_schema`), so consolidation is strict
   while **retain stays soft** — retain's failures are a different, measured
   problem (timeouts, GUL-428) and flipping it is a separate experiment.

   The evidence that this route can carry it, measured before the change with the
   real constrained model (8 fact ids, the real prompt shape) against the live
   `auto` endpoint:

   | mode | valid | served by |
   | --- | --- | --- |
   | soft (`json_object` + schema in the prompt) | 3/6 | voxtral-small, mistral-code, ministral-3b, poolside-laguna |
   | strict (`json_schema`, `strict: true`) | **5/5** | mistral-code, mistral-code-fim, voxtral-small, ministral-3b-2512, codestral |

   Strict was also faster: 2.8–6.7 s per call against 4.7–23.5 s soft, because
   the model no longer composes free-form JSON and hope.

2. **The rejection alert gets a floor and a ratio.** Both terms are required:

   ```promql
   (sum(increase(hindsight_consolidation_batch_failures_calls_total{failure_class="fail_fast"}[1h])) >= 3)
   and
   (sum(rate(...[{failure_class="fail_fast"}[1h]))
    / clamp_min(sum(rate(hindsight_llm_calls_total{scope="consolidation"}[1h])), 1e-9) > 0.02)
   ```

   `for: 10m`. The floor keeps a single blip out; the ratio (~20x the measured
   baseline) keeps a quiet hour with 3 rejects from looking like a busy hour with
   3. Replayed over the last 168 hours it selects exactly two hours — 2026-10-26
   10Z and 2026-11-02 05Z, both genuine bursts — and is silent on the other 15
   hours that contained a reject.

3. **Cause and damage are separate alerts.** This rule reports "the pool is
   degrading now". `HindsightConsolidationFailedRows` (`> 0`, zero baseline,
   ADR-099) reports "a fact will never be synthesised". Keeping them separate is
   what lets the first one be quiet.

## Consequences

- The 0.11% baseline should go to ~0 for this lane: with the grammar enforced by
  the provider, a batch is either schema-valid or the provider errored (which is
  `retry`, not `fail_fast`, and is already covered by the LLM failure-rate rule).
- The bisected re-runs disappear with it. Each reject cost a split re-send of the
  same batch, so the extra LLM calls on a free pool were the visible price; the
  invisible price was the rows in `consolidation_failed`.
- The alert now fires roughly once or twice a week at the old model quality and
  should go quiet entirely under strict schema. That is deliberate: a *warning*
  that is red a quarter of the day trains everyone to ignore the group.
- Strict schema makes a new failure mode possible: a provider that rejects
  `response_format: json_schema` outright fails the whole batch instead of the
  model's output. Five distinct routed models accepted it in the probe, and
  `_build_response_model` already strips the `maxItems` keyword that Bedrock
  refuses. If a future `auto` member 400s, the flag is the revert: one line,
  restoring exactly today's behaviour.
- Retain, reflect and the mental-model refresh are untouched.

## Alternatives considered

- **Pin consolidation to one model known to emit clean JSON.** Tried in spirit
  already (ADR-082, ADR-091): a pin on a free tier becomes a dead route when the
  provider retires the model or the key, and `auto` exists to survive exactly
  that. Strict schema fixes the *class* of failure for every member of the pool
  instead of betting on one.
- **Lower `CONSOLIDATION_LLM_BATCH_SIZE` again.** It was the H2-306 mitigation
  and it did not hold: at the default 8 the pool still drops fields. It also
  costs throughput, which is the wrong trade in a lane that is LLM-latency bound.
- **Alert-side only: set the floor and accept the rejects.** Honest and cheap,
  but 7 rejects in 6 hours means one consolidation operation in eight was
  re-sent split, and two facts stopped synthesising. Muting that is how GUL-559's
  1,633 stranded rows became invisible.
- **Model-side only: flip strict and leave `> 0`.** Then a single reject still
  costs half an hour of red, which is the exact complaint this issue was filed
  with.
- **Alert on `hindsight_consolidation_failed > 0` alone and delete this rule.**
  That reports damage, not cause, and it lands 30 minutes too late — after
  bisection has already failed. The two rules answer different questions.
- **Raise `for:` to an hour on the old expression.** Fixes the flapping, not the
  meaning: `> 0` over an hour still says nothing about whether the rate matters.

## When to revisit

- If a FreeLLMAPI `auto` member starts answering 400 on `json_schema`, the flag
  comes off and this ADR is superseded — record which member, so the pool's
  capability table stays honest.
- If retain is ever moved to strict as well, measure it separately: its prompts
  are transcript-sized and its failure mode is `timeout`, not `ValidationError`.
- If the alert is silent for a month *and* `hindsight_consolidation_failed` stays
  at zero, the threshold is doing its job; do not tighten it to "see something".
- If Hindsight ships a `fail_fast` rate metric with a denominator already in it,
  the ratio term collapses into one selector.
