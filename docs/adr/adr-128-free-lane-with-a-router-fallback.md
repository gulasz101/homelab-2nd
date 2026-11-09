# ADR-128: The refresh and reflect ride the free lane, with a free fallback behind the router

- **Status**: Accepted
- **Date**: 2026-11-09
- **Issue**: GUL-1045 (with GUL-806 / ADR-127 reversed)
- **Related**: ADR-094 (both lanes leave the FreeLLMAPI pool), ADR-120 (reflect on the fleet route),
  ADR-127 / GUL-806 (reflect moved to the paid DeepSeek API — **reversed here**), ADR-085 / GUL-123
  (never route paid-tier traffic into free providers — **narrowed here**), ADR-091 / GUL-184
  (`gpt-oss-120b-freellmapi` in no chain — **narrowed here**), ADR-109 (the balance is watched),
  GUL-787 (the FreeLLMAPI pool at 9,328 tokens)

## Context

`gpt-oss-120b-ollama` answered **429 "weekly usage limit reached"** from about 12:15Z on 2026-11-06.
The refresh has 48 mental models across 10 banks queued hourly and the app retried each LLM call four
times, so the wall became a storm: **7,350 failed calls in 25 hours**. The first fix (2026-11-06,
merged as PR #170 on 2026-11-08) moved the refresh — and, in ADR-127 before it, reflect — to the
metered `deepseek-v4.1-flash-1017-ds`. That fix worked and was proven from the pod log: 98 calls,
2.64 M input, 226 k output, **$0.266** for seven refreshes, and reflect at $0.31–0.62/day.

On **2026-11-09 the owner ruled the paid lane out**: these calls must run on the free route with a
free fallback behind it, not on a prepaid balance. That reverses ADR-127 and the paid half of
GUL-1045, and it makes the merged config, the pending ADR and the render-check guard all wrong in
the same direction.

## Measured before choosing (2026-11-09, from the running api pod)

Probe: 18,225 characters of prompt (**5,579 input tokens**), the real
`get_reflect_tools(answer_as_document=True)` schema — six tools — `tool_choice: auto`, through
llm-hub with the existing `hindsight-reflect` key. One call each.

| route | result |
| --- | --- |
| `gpt-oss-120b-ollama` | **200 in 0.9 s**, called `search_observations` |
| `gpt-oss-120b-freellmapi` | **200 in 0.9 s**, called `search_observations` (42 reasoning tokens) |

Two things follow, and the second is the important one:

- The Ollama weekly wall **resets** (12:15Z Monday is consistent with a weekly window). A route that
  answers today is headroom, not a route without a wall — which is exactly why the fallback exists.
- **The FreeLLMAPI pool did the tool call at refresh size.** ADR-094 / GUL-787 excluded it on a
  9,328-token prompt where it answered *without* a tool call. That finding is not repeated here as a
  fact: it is contradicted at 5,579 tokens. Recorded honestly — the pool is **proven at ~5.6 k and
  unproven above ~9 k**, and groq, its one healthy member, allows about **8,000 TPM**. A refresh fits.
  A 12,001-token reflect call may still be refused there; a refused fallback is no worse than the 429
  it replaces.

## Decision

1. **Both lanes are pinned to `gpt-oss-120b-ollama`** in `apps/hindsight/hindsight-helm-release.yaml`
   — reflect (`HINDSIGHT_API_REFLECT_LLM_MODEL`) and the refresh
   (`HINDSIGHT_API_MENTAL_MODEL_REFRESH_LLM_MODEL`). No paid route, no second model family.
2. **The wall is answered in the router, not in the app.** `apps/llm-hub` gets one new entry in
   `router_settings.fallbacks`: `{"gpt-oss-120b-ollama": ["gpt-oss-120b-freellmapi"]}`, and both
   sides carry `num_retries: 0` so a 429 on the primary hands over on the first attempt instead of
   retrying into the same wall.
3. **The app keeps `MAX_RETRIES: "1"`.** The 2026-11-06 storm was 7,350 calls from ~96 real ones; one
   retry for a blip, then the router does the hop. The app never builds a retry ladder.
4. **No `EXTRA_BODY`, no reasoning knob.** `{"thinking":{"type":"disabled"}}` and
   `..._REASONING_EFFORT` were parameters of the paid/fleet lane; on ollama.com they are unsupported
   and 400 the call. The 2026-11-09 measurement ran without either.
5. **The guard asserts the whole fix**, in `apps/hindsight/tests/render-check.sh`: the pinned primary
   for both lanes, retry cap 1, the chain entry, **and the absence of a `-ds` target in that chain**.
   Both a dropped chain and a paid hop are FAILs, in opposite directions. Dropping the `-ds` ban means
   the bill can come back silently; dropping the chain means the 2026-11-06 outage comes back.
6. **ADR-085 / ADR-091 are narrowed, not deleted.** Their rule is that a route the owner *pays by the
   token* must not be silently downgraded into a free pool. `gpt-oss-120b-ollama` is not paid — it
   lives on the Ollama subscription allowance — so a hop from it into the free pool is the free lane
   rescuing the free lane. Only that one source gets the hop, and no paid route may appear as a target
   anywhere in it.

## Consequences

- **No bill.** The refresh and reflect cost nothing per token; the failure mode is a 429, not a 402.
- **The failure mode is honest but real:** when ollama.com walls the account *and* the pool is at its
  8,000 TPM, the call fails. It fails with one retry instead of a four-deep ladder, and reflect still
  has the 499-instead-of-429 behaviour ADR-120 measured — this does not make reflect reliable, it
  makes it free.
- **The pool is a fallback, not a home.** Its measured rate limit is the reason the primary stays on
  the subscription route; a 12,001-token reflect call is above what groq will take.
- **The guard now protects a chain, not just a string.** `apps/llm-hub` is part of the Hindsight
  contract: editing the fallback block can break the refresh, and the render-check runs on every PR
  that touches the apps tree, so it will say so.
- **Break-glass is not a test method.** Restarting the api pod mid-refresh burns a recovery attempt;
  four restarts parked seven models as `failed` during the 2026-11-06 work.

## Alternatives

- **`deepseek-v4.1-flash-1017-ds` (the merged, measured, working fix)** — rejected by the owner on
  cost, not on merit. It is the answer if the budget ruling ever changes; the numbers are in PR #170
  and in this ADR's context.
- **`deepseek-v4.1-flash-1017-ollama` or `glm-5.3-flash-ollama`** — free, but they are the *same*
  weekly allowance that walled `gpt-oss-120b`. Two families 429ing in the same minute on 2026-11-06 is
  the evidence. Moving to a sibling bucket buys days, not a fix.
- **Wait for the reset** — the refresh is broken until it comes, and it comes back the next time the
  account is busy. This was the third walled-route incident in three weeks.
- **Pause the refresh** — mental models go stale silently, and a stale mental model looks exactly like
  a fresh one to every agent that reads it.

## When to revisit

- **If the pool starts failing at refresh size**, measure it again at the real prompt size before
  blaming the chain; the 5,579 / 9,328 token boundary is measured at both ends, not in between.
- **If a walled Ollama account becomes routine**, the lever is refresh volume (`refresh_cron`,
  `HINDSIGHT_API_MENTAL_MODEL_MIN_REFRESH_INTERVAL_SECONDS`), not another route — 48 hourly models
  is what turns one wall into a storm.
- **If the owner ever authorises a paid lane again**, this ADR is the thing to supersede and the
  guard's `-ds` ban is the line to change on purpose, with the measured cost next to it.
- **If a local model with reliable tool calling appears on this hardware**, it beats every route here
  on both cost and wall-freedom.
