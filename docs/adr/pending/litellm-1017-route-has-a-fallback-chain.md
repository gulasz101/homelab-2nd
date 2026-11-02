# ADR: the fleet's primary route carries a fallback chain, and its last hop is the paid one

- **Status**: Pending
- **Date**: 2026-11-02
- **Issue**: GUL-783
- **Related**: GUL-769 (fleet moved onto `deepseek-v4.1-flash-1017-ollama`), GUL-593 (the same hole while the fleet rode `-1017-ds`), GUL-662 (DeepSeek balance guard), ADR-091 (the free route is in no chain), ADR-106 (the fleet ran on DeepSeek direct), pending ADR GUL-690 (thinking can be turned off on DeepSeek routes)

## Context

On 2026-11-02 01:20Z the whole agent fleet (7 Hermes/OpenCode config surfaces, 7 Paperclip runners)
moved onto one route: `deepseek-v4.1-flash-1017-ollama`. That route was defined in `model_list` and
allowed on every virtual key, and it appeared in **no** `router_settings.fallbacks` entry, as a
source or as a target.

So there was nothing between "Ollama serves it" and "every agent fails its first call". The failure
modes are ordinary: the model is unloaded, the `:1017` snapshot tag moves on the next weekly model
sync, one model id goes bad, or the whole Ollama allowance is walled. LiteLLM says it plainly in the
log and in the response:

```
litellm.BadRequestError: ... model group 'deepseek-v4.1-flash-1017-ds' failed with the error
above and no fallback model group was found for it, so the request was not retried on another
deployment
```

The same hole existed while the fleet rode `-1017-ds` (GUL-593). It was tolerable then because the
paid key answered when Ollama did not; now the cheap route is the only route, so the hole is the
whole platform's availability.

## Decision

1. `deepseek-v4.1-flash-1017-ollama` gains a two-hop chain, **cheapest billing identity first**:
   `deepseek-v4.1-flash-ollama` (same Ollama allowance, unversioned tag of the same family), then
   `deepseek-v4.1-flash-1017-ds` (DeepSeek's own API, paid key, different vendor and balance).
2. `deepseek-v4.1-flash-1017-ds` gains the mirror chain, `-1017-ollama` then `deepseek-v4.1-flash-ollama`,
   so a dead or empty paid key drops the fleet back onto the allowance it was moved to in GUL-769
   instead of going dark.
3. **The paid hop is in the chain, last.** The owner is avoiding DeepSeek API spend, so this is a
   deliberate cost leak: it fires only when both Ollama routes have already failed. The GUL-662
   balance guard pages within the hour if it starts draining. A few dollars of leak beats a dead
   fleet at 09:00, and the alternative (no terminal hop) is the outage this ADR exists to remove.
4. **The free route stays out** (`gpt-oss-120b-freellmapi`, ADR-091). A free pooled relay is not a
   backstop for hour-long tool-calling runs.
5. A Loki rule (`LiteLLM1017ChainFellBack`) fires when the 1017 primary throws or a request reaches
   the paid hop, because a fleet-wide fallback was previously only visible by reading the proxy log.

Measured before writing the chain (live proxy, 2026-11-02, plain chat plus a forced `get_weather`
tool call):

| route | answers as | forced tool call |
|---|---|---|
| `deepseek-v4.1-flash-1017-ollama` | itself | works |
| `deepseek-v4.1-flash-ollama` | itself | works, same shape |
| `deepseek-v4.1-flash-1017-ds` | itself | 400 `Thinking mode does not support this tool_choice` unless `reasoning_effort: none` |

Both Ollama routes accept `reasoning_effort` and behave identically on a forced tool call, so the
first hop cannot break a tool-calling caller. PR #98 (GUL-581, `allowed_openai_params` on the 1017
route) is therefore **not** a prerequisite for this chain; it fixes the declaration for other
reasons.

## Consequences

- A single Ollama model-id failure no longer takes the fleet down: the sibling tag answers.
- An Ollama account wall now ends on the paid DeepSeek key, which costs money. Executor traffic that
  needs forced tool calls does not survive that hop unless it sends `reasoning_effort: none`
  (pending ADR GUL-690), so the practical rescue at hop 2 is plain turns.
- Two group names appear in the routing table that nothing else targets
  (`deepseek-v4.1-flash-1017-ds` as a fallback), which is what makes the new Loki rule precise
  instead of firing on the `qwen3.8-flash` chains that also end on `deepseek-v4.1-flash-ollama`.
- The chain is only as good as the weekly model sync: if a sync renames or drops the group
  `deepseek-v4.1-flash-1017-ollama` itself, the request never reaches the router. That is a separate
  failure shape (route definition, not provider) and is not covered here.

## Alternatives

- **No paid hop (Ollama-only chain).** Rejected: it rescues a bad model id but not the account wall,
  which is the failure that stops every agent at once.
- **`glm-5.3-ollama` or another family as hop 2.** Rejected for now: it is the same Ollama allowance,
  so it does not survive a wall, and it changes the model behind an executor mid-run (different tool
  behaviour) for no availability gain over the sibling tag.
- **A Go route as hop 2.** Rejected: the Go allowance is the quota the fleet was moved off in
  GUL-769, and `*-go` routes expect the OpenCode session header, so a non-Go caller is not
  guaranteed to work there.
- **Rely on the caller's own fallbacks** (Hermes `fallback_providers`, Paperclip `extraArgs`).
  Rejected: the callers are seven different programs with seven sets of config, and the proxy is the
  only place where one change covers the fleet.

## When to revisit

- The paid hop fires more than a few times a week: that is an Ollama stability problem, and the chain
  is masking it. Fix the primary instead of widening the backstop.
- A caller appears that cannot survive a model swap mid-run (a long agent session whose tool schema
  differs by family): pin that caller to hop 1 only, or give it its own key without the paid target.
- Ollama Pro is retired or repriced, which changes the cost ordering that put the paid hop last.
