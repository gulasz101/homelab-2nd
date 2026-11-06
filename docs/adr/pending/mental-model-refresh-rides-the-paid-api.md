# The mental-model refresh rides the paid DeepSeek API, with one retry

- **Status**: Pending
- **Date**: 2026-11-06
- **Issue**: GUL-1045
- **Related**: ADR-094 (reflect and the refresh leave the FreeLLMAPI pool), ADR-120 (reflect rides the
  fleet route — superseded), ADR-106 (the fleet runs on DeepSeek direct), ADR-109 (the balance is
  watched), ADR-121 (the 1017 route has a fallback chain), GUL-806 (reflect reverted to `gpt-oss`),
  GUL-787 (the refresh stayed put on 2026-10-29)

## Context

The mental-model refresh ran on `gpt-oss-120b-ollama` through llm-hub. On 2026-11-06 from about
12:15Z that model group answered **429 "you (gulasz101) have reached your weekly usage limit"**, and
it kept answering it.

The refresh is the worst place to have a walled route. Hindsight retries an LLM call four times, and
48 mental models across 10 banks are queued hourly, so one wall became a storm: **7,350 failed
refresh calls in 25 hours, ~380 an hour**, every one a 429, all from the hindsight-api pod. The
earlier measurement that put the refresh here — 0 failed of 139 on 2026-10-29 — was true when the
allowance existed. It says nothing about a route that has run dry.

Reflect was moved off this route once and moved back (ADR-120, GUL-806), because moving a *subscription*
lane to the *paid* lane is a spend decision and moving it back is not the same decision as "make the
subscription work". The refresh was deliberately left alone: that card was about reflect. This one is
about the refresh, and the answer cannot be the same, because the refresh has no HTTP caller waiting
on it and no 499 exposure — only a worker slot and a 300 s LLM budget.

## Measured first (2026-11-06, from the running api pod)

Probe: a refresh-shaped request — 13,663 characters of prompt (5,292 input tokens), the real
`get_reflect_tools(answer_as_document=True)` schema, six tools, `tool_choice: auto`, through llm-hub
with the existing `hindsight-reflect` key. One call each.

| route | result |
| --- | --- |
| `gpt-oss-120b-ollama` (what was configured) | **429** weekly usage limit |
| `glm-5.3-flash-ollama` | **429** weekly usage limit |
| `deepseek-v4.1-flash-1017-ollama` | 200 in 14.4 s, correct first tool calls |
| `deepseek-v4.1-flash-1017-ds` | 200 in 3.1 s, correct first tool call, 314 output tokens |

Two families of one Ollama account running out at the same moment is the point: the `-ollama` routes
share one weekly allowance, so the family that still answers is headroom, not headroom-to-spare.

The FreeLLMAPI pool stays out for the reasons in ADR-094, re-measured in GUL-787: at 9,328 tokens it
answers without a tool call, and the refresh is a tool loop.

## Decision

1. **The refresh runs on `deepseek-v4.1-flash-1017-ds`** — the metered DeepSeek API through
   llm-hub. It is the only candidate with no allowance that can be exhausted into a 429; when the
   balance is gone the failure is a 402 and a bill, not a silent weekly wall. Same model family the
   lane already used, so the prompt and the tool schema are unchanged.

2. **`HINDSIGHT_API_MENTAL_MODEL_REFRESH_LLM_MAX_RETRIES: "1"`.** The storm was not the wall, it was
   the ladder: 4 attempts per call, 48 models, 25 hours. One retry absorbs a blip; more than that only
   buys more 429s — or, on the paid route, more money for the same failure.

3. **`apps/hindsight/tests/render-check.sh` fails on a subscription refresh route.** Any `-ollama` or
   `-go` suffix is a FAIL, and so is any `-ds` model other than the measured one. Going back to a
   metered free route is now a deliberate edit to the test, with the reason written where the next
   person will read it.

4. **Reflect stays where it is (`gpt-oss-120b-ollama`).** Different lane, different constraint: it has
   an HTTP caller with finite patience, and ADR-120's 24 h read shows the `-1017-ollama` route loses
   74 % of its calls to 499s. That is a separate fight and it is not this decision.

## Consequences

- **The refresh works again.** Verified on the live pod after the change, from the log and from
  `mental_models.last_refreshed_at` moving — not from a HelmRelease reading Ready. After the cutover:
  `[REFRESH_MENTAL_MODEL_TASK] Completed for bank_id=coding-agent::homelab-2nd,
  mental_model_id=mm-7824f5df18764658b9576ba9e8de8c51` at 14:53:44Z, and four models advanced in the
  same quarter hour (`Key decisions and rationale`, `Model rewire…`, `Core concepts`, `Initiatives and
  enhancements`), the oldest of which had been stuck at 2026-11-05 05:50.
- **It costs money, and the number is measured, not guessed.** A refresh on `-ds` runs the reflect
  loop: 5-10 LLM calls, ~22-30 k input tokens each (the loop re-sends its own transcript), ~30 k
  output tokens in total. The catch-up run that proved the route — 7 refresh ops against a 25-hour
  delta — billed **98 calls / 2.64 M input / 226 k output for $0.266 through llm-hub: ~$0.038 per
  refresh, split evenly between input (prefix cache absorbs most of it) and output at $0.60/M.** A
  small-delta refresh is two calls and about **$0.003** — the one that finished in 17 s did exactly
  that. The DeepSeek balance on the day was **$4.55** against ADR-109's **$5 floor**: already under it
  before this change spent anything.
- **So the daily bill follows bank activity, not the 48 hourly crons.** Hindsight only queues a model
  whose scope moved: the live maintenance line reads `scheduled 7 model(s), 36 up-to-date` after 25
  hours of downtime. At that rate, at the catch-up price, the refresh adds **~$0.25 an hour, ~$6 a
  day**; with small deltas it is a tenth of that. That is real money on a prepaid balance, and it is
  the price of a lane that cannot 429. If the owner will not pay it, the lever is refresh volume (see
  "When to revisit"), not this route.
- **The route is slower per call** (3-13 s against ~2 s on the subscription). A refresh takes 3-6
  minutes instead of under one, and the worker's 8 shared slots can hold only a handful of them. The
  hourly schedule still fits, but a large backlog is now visible as slot pressure instead of 429s.
- **The balance is the new single point of failure** for this lane. It is watched (ADR-109), so it
  fails loudly, but it fails in a day if the owner does not top up.
- Restarting the api pod while refreshes are in flight kills them and burns one of their three
  recovery attempts; four quick restarts parked seven models as `failed`. Break-glass restarts are not
  a free way to test a route change.

## Alternatives

- **`deepseek-v4.1-flash-1017-ollama`** — free, and it answered. Rejected because it is the same
  Ollama weekly allowance that had just run out on two sibling families; picking it buys days, not a
  fix, and the retry ladder would eat the rest of the allowance while it lasts.
- **Stay on `gpt-oss-120b-ollama` and wait for the weekly window to reset** — the refresh is then
  broken until it does, and it breaks again the next time the account is busy. This is the third
  walled-route incident in three weeks; waiting is what produced the storm.
- **FreeLLMAPI pool** — ADR-094 and GUL-787 both measured it unfit for tool-loop work at this size.
- **Pause the refresh entirely** — mental models quietly go stale, and a stale mental model looks
  exactly like a current one to every agent that reads it.

## When to revisit

- **If the daily bill is not acceptable**, the lever is refresh volume, not the route: the per-model
  `refresh_cron` (hourly on 49 models) or `HINDSIGHT_API_MENTAL_MODEL_MIN_REFRESH_INTERVAL_SECONDS`
  (default 0, i.e. no cap). Cutting hourly to every 6 h divides the bill by six and costs at most six
  hours of staleness.
- **If the Ollama allowance resets and the owner wants the spend gone**, the honest move is back to
  `deepseek-v4.1-flash-1017-ollama` with this test changed on purpose — not a quiet edit of one line.
- **If a route appears that is both free and unlimited** (a local model with reliable tool calling on
  this hardware), it wins on cost, and this ADR is the thing to supersede.
