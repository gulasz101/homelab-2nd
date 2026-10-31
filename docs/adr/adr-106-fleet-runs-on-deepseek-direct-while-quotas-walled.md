# ADR-106: The whole agent fleet runs on `deepseek-v4.1-flash-1017-ds` (DeepSeek's own API) while subscription quotas are walled

- **Status**: Accepted
- **Date**: 2026-10-29
- **Issue**: GUL (record filed from Mattermost, agent-fleet repoint)
- **Amends**: ADR-085 (paid subscriptions only), ADR-069 (Go fallback), ADR-094 (paid Ollama route for reflect)
- **Depends on**: ADR-105 (the `-ds` route family itself, added to LiteLLM the same day)
- **Related**: GUL-581 (previous fleet move)

## Context

Every model the fleet used came from one of two weekly subscriptions: **OpenCode Go**
(`*-go` routes, `https://opencode.ai/zen/go/v1`) and **Ollama Pro** (`*-ollama` routes,
`https://ollama.com/v1`). LiteLLM in front, one virtual key per consumer.

On 2026-10-29 both walls arrived: the Go weekly quota was already exhausted, and the Ollama
Pro token allowance was nearly gone. Every Hermes profile and every Paperclip runner sat on
one of those two families, so the next run would have died on a 429 — in the middle of the
Paperclip issue sweep, not at a convenient moment.

Probing the Go route with a real key during this work showed the second problem: a request
for `qwen3.8-flash-go` came back with `model: deepseek-v4.1-flash` in the response body. The
route was **silently substituting** — the caller thinks it is on Qwen, the bill and the
behaviour say otherwise. A quota wall you can see is better than a model swap you cannot.

The proxy already carried a route that spends a **third, independent** budget: the DeepSeek
platform API (`deepseek/deepseek-flash`, `DEEPSEEK_API_KEY`, 1M in / 393k out), published as
`deepseek-v4.1-flash-1017-ds`. Pay-per-token, no weekly allowance, no silent substitution.

## Decision

`deepseek-v4.1-flash-1017-ds` becomes the **default model for every Hermes profile** (default
profile / Bill Cipher, andrzej, florian, matejko, szarik, zdzislaw) and for every Paperclip
runner whose model is set in `adapterConfig` (Builder, Majster, Reviewer, Verifier, Tester,
OpenCode, Pi). The standalone OpenCode CLI is pinned to `llmhub/deepseek-v4.1-flash-1017-ds`
as both `model` and `small_model`. The `pi` catalog gains a matching entry with
`reasoning: false`.

Two exclusions, deliberate:

- **Claude Code** (`claude_local`, `claude-opus-5-5`) is untouched. It spends the Anthropic
  subscription, not a LiteLLM quota; repointing it would break the only reviewer that is paid
  from a different pocket.
- **Fallback chains** keep their Ollama hop plus the FreeLLMAPI last resort. The primary is
  what had to move.

## Consequences

- The fleet keeps working with zero subscription allowance, at pay-per-token prices. Cost is
  now proportional to usage instead of capped by an allowance — that is the trade: an agent
  fleet that stalls at a random hour versus a bill that scales.
- One family everywhere means **correlated blind spots**: the Reviewer and the Builder now
  come from the same model. Review quality loss here is real and accepted for the duration of
  the quota wall (the previous split family was `glm-5.3-ollama`, which is out of budget).
- A single vendor is now a single point of failure for the whole fleet. The FreeLLMAPI
  fallback is the only route that does not depend on DeepSeek's balance.
- `pi` runs with `reasoning: false` on this entry: the route does not declare
  `reasoning_effort`, and `pi` sends it whenever the catalog says `reasoning: true` — that
  combination is a hard `400 UnsupportedParamsError`, not a retry.
- The OpenCode CLI needs the model **enumerated** in `~/.config/opencode/opencode.json`
  under `provider.llmhub.models`. Setting `model` to an unlisted id fails with an opaque
  `UnknownError` from the local server, which reads like a proxy fault.

## Alternatives

- **Stay on Ollama until it runs dry**: rejected — the wall arrives mid-run, and a Paperclip
  run that dies at minute 40 leaves an issue parked with no comment.
- **FreeLLMAPI as primary**: rejected — measured in ADR-094 at 1 success in 54 calls under
  load. Fine as a last resort, useless as a fleet default.
- **Local MLX routes (`qwen3.8-27b-mlx` on the Air, `.119:1234`)**: free and unlimited, but
  ~27B on a laptop against a 25k-token agent prompt is a latency problem, and the Air is also
  the Hermes host. Kept as a fallback idea, not a default.
- **Wait for the weekly reset and do nothing**: rejected — two days of dead agents.

## When to revisit

- The Go or Ollama allowance resets and the cost per run on DeepSeek is worse than the
  subscription to date.
- The DeepSeek balance itself gets low: at that point the fleet has no paid route left and
  the answer is FreeLLMAPI-primary plus a smaller default model, which is a different ADR.
- Review quality measurably drops with Builder and Reviewer on one family — then split the
  reviewer onto a genuinely different paid route rather than a different name for the same
  weights.
