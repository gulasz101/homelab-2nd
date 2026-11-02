# ADR: Hindsight reflect rides the fleet's route, with thinking off, not the metered DeepSeek key

- **Status**: Pending
- **Date**: 2026-11-02
- **Issue**: GUL-787 (unblocks GUL-476, GUL-143)
- **Related**: ADR-094 (reflect and the refresh leave the FreeLLMAPI pool), ADR-106 (the fleet runs on
  DeepSeek direct), ADR-109 (the DeepSeek balance is watched), GUL-769 (the fleet left the paid key),
  GUL-690 / PR #116 (LiteLLM 1.106.6)

## Context

Interactive Hindsight reflect had been failing about a quarter of its calls since 22 October: the model
did not return the forced tool call, Hindsight raised, and the operation went to `failed`
([GUL-143](/GUL/issues/GUL-143)). Two candidate fixes existed.

**`deepseek-v4.1-flash-1017-ds`** — the metered DeepSeek API. It honours a forced `tool_choice` once
thinking is off (10/10 through llm-hub on LiteLLM 1.106.6, full reflect-shaped loop). It also costs
**$0.31-0.62/day, $9-19/month** at the measured 2.17M input tokens a day, on a balance of **$3.10** —
and the fleet had just moved all 14 surfaces off that key to stop paying for it ([GUL-769](/GUL/issues/GUL-769)).
The owner would have been approving the spend a night's work had just removed.

**`deepseek-v4.1-flash-1017-ollama`** — the same model family on the route the whole fleet now runs on,
served through `https://ollama.com/v1` by LiteLLM. Nothing had measured it at reflect size.

Measured 2026-11-02 from inside the `hindsight-api` pod, over the base URL and key reflect actually uses,
**20,622 input tokens**, one function, 10 runs:

| | `-1017-ollama` |
|---|---|
| forced call returns the requested tool | **10/10**, `finish_reason=tool_calls`, parseable JSON args |
| latency | 0.84-1.45 s |
| `reasoning_content` | present in 6/10 |
| `reasoning_effort: none` | 5/5 tool calls, **0/5** `reasoning_content` |
| `thinking: {"type":"disabled"}` | **HTTP 400** `UnsupportedParamsError: openai does not support parameters: ['thinking']` |
| `tool_choice: none` | 2/2 **still called a tool** |
| forced call naming a nonexistent tool | 2/2 returned the real tool anyway |
| full loop (search → read → synthesis) | completes, 0.8 / 1.3 / 4.0 s |
| which model it says it is | "Claude", an unreliable self-report; the response `model`, `x-litellm-model-name` and `x-litellm-model-api-base` headers all agree with the route it claims to be |

So the free route works, and two things are different from the `-ds` route:

1. **`thinking` is not a parameter this route accepts at all.** It runs through LiteLLM's `openai/`
   provider, which rejects an unknown request parameter with a 400 instead of dropping it. Copying the
   `-ds` extra body here would fail *every* reflect call. The knob that turns thinking off on this route
   is `reasoning_effort: none`, and Hindsight exposes it per operation.
2. **`tool_choice` is not honoured.** Ollama's OpenAI-compatible layer ignores it (ollama/ollama#17921,
   already known on 28 October). A forced call and a `tool_choice: none` call behave the same; the model
   calls the tool because the reflect prompt states the search plan, not because the API pins the turn.

## Decision

1. **Reflect moves to `deepseek-v4.1-flash-1017-ollama`**, not `-ds`. No new spend, no re-opening the
   metered key, and the change is three env vars rather than a new credential.
2. **`HINDSIGHT_API_REFLECT_LLM_REASONING_EFFORT: none`** is part of the change, not an optional extra:
   thinking is on by default on this route and 6 of 10 probes returned reasoning content without it.
3. **No `HINDSIGHT_API_REFLECT_LLM_EXTRA_BODY`.** `thinking` is the `-ds` knob and is a 400 on the
   `-ollama` route. `render-check.sh` asserts the variable stays unset, and asserts the model name does
   not carry the `-ds` suffix.
4. **The mental-model refresh stays on `gpt-oss-120b-ollama`** (0 failed of 139 measured 29 October).
   Only reflect was failing; changing a working lane would mix two variables in one change.
5. **Reflect and the fleet share a route, and that is the trade.** `-ollama` capacity is shared with 14
   fleet surfaces where `-ds` was dedicated. `-ds` remains the fallback if real reflect success does not
   improve, and that is a cost decision for the owner with a monthly number, not a default.

## Consequences

- No DeepSeek spend is re-opened; the balance stays where [GUL-769](/GUL/issues/GUL-769) left it.
- **The structural weakness of the old pin is not fixed, only re-based.** `tool_choice` is still advice
  on this route, exactly as it was on `gpt-oss-120b-ollama` when ~8 reflect operations a day were lost.
  What changed is which model decides whether to follow the prompt, and that thinking is off. A pass on
  10/10 probes is evidence, not a guarantee: the honest check is the reflect success ratio over hours of
  real traffic (`llm_requests` scope `reflect*`, and `hindsight_operation_operations_total{operation="reflect"}`).
- Extra body applies to the whole reflect operation, so the closing synthesis also runs with thinking
  off. Synthesis is a writing pass, not a reasoning one, and it finished in 4 s in the probe — but a
  thinner answer here would show up as reflect quality, not as a failure.
- The route is Ollama Cloud, so "free" means "no DeepSeek meter", not "no capacity": it draws on the same
  Ollama plan the fleet runs on.

## Alternatives

- **`-ds` with thinking off.** Works, 10/10, and is the shape [GUL-476](/GUL/issues/GUL-476) was about to
  approve. Rejected on cost alone: $9-19/month on a $3.10 balance to fix a background operation.
- **Keep `gpt-oss-120b-ollama`.** The measured failure rate (~24 %, 8 failures in 16 h) is what made this
  an issue.
- **Wait for Ollama to honour `tool_choice`.** No upstream timeline; the same bet has been running since
  28 October.

## When to revisit

- When reflect success over 24 h is not clearly better than the ~76 % baseline, or `llm_requests` shows a
  new failure shape (400s, truncated `finish_reason=length`, empty content).
- When Ollama starts rate-limiting the shared route and fleet surfaces suffer because of reflect traffic.
- If Ollama ships `tool_choice` support, the forcing assumption can be restored and this trade disappears
  — re-probe with the controls in `apps/hindsight/tests/render-check.sh`'s comment block rather than trusting
  the release note.
