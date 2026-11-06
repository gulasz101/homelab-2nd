# ADR-127: Hindsight reflect pays for the DeepSeek route, because the free routes are metered

- **Status**: Accepted
- **Date**: 2026-11-06
- **Issue**: GUL-806 (measurement), GUL-787 (predecessor), GUL-476, GUL-769 (the spend this reverses)
- **Approved**: the owner accepted the confirmation card `63c227c4` at 2026-11-06 14:13Z —
  *"Accept — switch to deepseek-v4.1-flash-1017-ds"*
- **Supersedes**: ADR-120 (reflect on `deepseek-v4.1-flash-1017-ollama`), and the route choice in
  ADR-094 (reflect on `gpt-oss-120b-ollama`)
- **Related**: ADR-106 (the fleet runs on DeepSeek direct), ADR-109 (the balance watchdog with its $5
  floor), ADR-036 (native provider params), GUL-866 (the reflect success-ratio alert)

## Context

Reflect has lived on three routes in five days, and each move was made on the best number available
at the time. Written once, in order, because the next person will propose one of them again:

| route | who pays | what it measured | what killed it |
|---|---|---|---|
| `gpt-oss-120b-ollama` | ollama.com free allowance | 44 × 200 / 6 × 499 / 1 × 500 in 24 h — **86 % caller success**, p50 22 s | the allowance ran out: every call answers **429 "weekly usage limit"** and Hindsight turns that into a 500 |
| `deepseek-v4.1-flash-1017-ollama` | ollama.com free allowance | p50 **16 s** per reflect, but 9 × 200 / 26 × 499 — **26 % caller success** | callers give up at ~30 s; every abort landed inside that cap while the server kept working (ADR-120) |
| `deepseek-v4.1-flash-1017-ds` | api.deepseek.com, the owner's key | 10/10 forced tool calls and a finished reflect loop at reflect size, measured in ADR-120 | nothing — no quota wall; it was rejected on **cost**, not on behaviour |

The pattern is the point. Both free routes are **metered allowances with a hard wall**, and a wall
does not announce itself in a latency graph: `gpt-oss` looked perfect for a day, then answered 429
to everything at 12:15Z on 2026-11-06, and Hindsight retried four times per LLM call into it —
**437 requests in 21 minutes**, all 429, across reflect, consolidation and mental-model refresh.
The feature was at 0 %, with an empty-looking dashboard and one 500 in the log if you were watching.

That is the same shape of failure as the 499 storm, one layer up: the number the dashboard shows is
not the number the caller experiences.

## Decision

**Reflect runs on `deepseek-v4.1-flash-1017-ds` with `{"thinking":{"type":"disabled"}}`**, and both
the route family and the extra body are enforced by `apps/hindsight/tests/render-check.sh`.

- The route is the native `deepseek/` provider on api.deepseek.com (`deepseek-flash`), so thinking is
  controlled by the `thinking` parameter — accepted here, a `400 UnsupportedParamsError` on either
  `-ollama` route through LiteLLM's `openai/` provider.
- Thinking must be **off**: `deepseek-flash` thinks by default at reflect size, and the thinking
  tokens are what push the loop past the caller's ~30 s cap.
- `HINDSIGHT_API_REFLECT_LLM_REASONING_EFFORT` stays unset. It belonged to the `-ollama` routes; two
  knobs for one behaviour is how an unmeasured parameter ends up in production.

## Consequences

- **This re-opens spend that GUL-769 closed**, deliberately. ADR-120 measured the -ds route at
  **$0.31–0.62/day, $9–19/month** at the then-current 2.17M input tokens a day. Today's reflect volume
  is ~8 calls a day at ~55 k input tokens — roughly a fifth of that, so order **$0.06–0.12/day** —
  but that is an estimate by proportion, not a measurement; the first honest number will come from
  LiteLLM spend after a week of real traffic.
- The draw lands on a DeepSeek balance of **$5.36** at the time of the decision, which is what the
  ADR-109 watchdog watches with a $5 floor. Reflect is now a standing consumer of the tightest
  resource on the platform. If the balance is not topped up, the fleet's paid fallback and reflect
  hit the floor together.
- **Free is not free if it is metered.** A subscription route is only a saving if the allowance
  outlives the workload; otherwise the saving is a deferred outage, and the outage arrives without
  any alert that can see it.
- **The mental-model refresh is still on `gpt-oss-120b-ollama`** and is therefore still answering
  429 to every call. Reflect and refresh share a provider but not a failure budget: fixing one does
  not fix the other, and the refresh needs its own decision (filed as its own issue at the time of
  this ADR's merge).
- The retry behaviour is unchanged: on a 429, Hindsight makes 4 attempts per LLM call. A route that
  can be rate-limited will always produce that storm; nothing in this ADR bounds it.

## Alternatives

1. **Stay on `gpt-oss-120b-ollama` and wait for the weekly allowance.** Free, reversible, and it
   leaves reflect at 0 % until the meter resets, then at the mercy of the next busy week. Rejected:
   the owner was already living with a 22 % route for four days; a second deferred outage is not a
   fix.
2. **Back to `-1017-ollama`.** Measured at 26 % caller success — a slower, bigger prompt against a
   30 s caller. Rejected on the ADR-120 numbers.
3. **Tune the prompt** (`reflect_search_observations_max_tokens`, `MAX_CONTEXT`). Changes prompt size;
   the failure is end-to-end time against a caller cap, and on `-ds` with thinking off there is
   nothing to tune away.
4. **Ride a different free model** (`deepseek-v4.1-flash-ollama`, the non-`:1017` sibling). Unmeasured
   for reflect, and still inside the same metered allowance family. Not rejected forever — but not
   as a fix for a quota wall.

## When to revisit

- **If the DeepSeek balance cannot hold the draw**: the honest lever is reflect volume, not route
  roulette — a nightly batch or a coarser schedule costs nothing in correctness.
- **If reflect volume grows past a few hundred calls a day**, re-measure spend from LiteLLM rather
  than scaling the estimate above.
- **If ollama.com ever sells an unmetered tier for these models**, the free-route question reopens
  with real numbers instead of an allowance.
- **If `deepseek-flash` changes its default thinking mode**, the extra body becomes a no-op or a 400
  — `render-check.sh` asserts the parameter is present, so the failure would be visible, but the
  meaning would need re-measuring.
