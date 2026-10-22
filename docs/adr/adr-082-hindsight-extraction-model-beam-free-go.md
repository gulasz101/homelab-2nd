# ADR-082: Hindsight fact-extraction LLM moved to beam-free-go (OpenCode Go, free)

- **Status**: Accepted
- **Date**: 2026-10-23
- **Amends**: ADR-054 (Hindsight extraction model via OpenRouter) — §LLM backend only

## Context

Hindsight's fact-extraction route (`retain_extract_facts`) and reflect tool calls were
backed by `gpt-oss-120b-hindsight` → OpenRouter `openai/gpt-oss-120b:nitro`. On
2026-10-22 the OpenRouter credit balance drained to zero (`total_credits: 100`,
`total_usage: 100.18`). Every retain and reflect call has failed with HTTP 402 since
19:39:17Z (265 failed extractions, 26 failed reflects; consolidation unaffected on the
Go plan). The route was a leaf in LiteLLM's fallback graph, so there was nowhere to
fall over (GUL-114).

Wojtek's directive (GUL-112): point Hindsight at `beam-free-go`, a fast model on the
OpenCode Go platform, instead of papering over the outage with a paid fallback.

## Decision

Hindsight's fact extraction runs through the **OpenCode Go** platform, exposed in
LiteLLM as:

- `model_name: beam-free-go` → `openai/beam-free` on `https://opencode.ai/zen/go/v1`
- `HINDSIGHT_API_LLM_MODEL: beam-free-go`

The `memory-hindsight` LiteLLM virtual key's model list was widened to include
`beam-free-go` (via `POST /key/update` with the master key; the key is not managed by
the key-provisioner, it is a manually-scoped key). Verified answering "OK" through
that key before deploying.

Consolidation is **unchanged**: `hindsight-consolidation-go` on the OpenCode Go plan
(minimax-m3.1-flash, fallback deepseek-v4.1-flash) — it was working throughout the
outage and is left alone.

Embeddings and reranking are **unchanged** (in-cluster TEI).

## Consequences

**Positive**

- Retains succeed again: 6/6 `retain_extract_facts` succeeded on `beam-free-go`
  within minutes of the rollout; a manual synchronous retain returned `success: true`.
- No per-token OpenRouter spend for fact extraction — the model is on the flat-rate
  OpenCode Go plan, removing the credit-drain failure mode for this route.
- The outage is fixed at the source (provider) rather than patched with a fallback.

**Negative**

- Consolidation still draws on the OpenCode Go subscription (minimax/deepseek); the
  Supreme Leader may want that revisited separately if subscription drain becomes a
  concern.
- Extraction quality of `beam-free` vs `gpt-oss-120b` is unmeasured.
- `beam-free-go` is a reasoning model: small `max_tokens` yields `content: null`
  (HTTP 200), same pitfall as gpt-oss.

## Alternatives considered

1. **Top up OpenRouter and keep gpt-oss-120b-hindsight.** Rejected: spends real money
   and keeps the single-provider fragility; GUL-114 covers the top-up decision
   separately.
2. **Add a fallback (gpt-oss-120b-ollama) to the route (GUL-114 Part 2).**
   Complementary, not a substitute: it papers over a drained balance with another
   provider instead of removing the paid dependency. Left to GUL-114.
3. **Move consolidation to beam-free-go too.** Rejected for now: consolidation is
   working and tuned (210 s timeout, parallelism 6); changing it risks regressions
   with no measured benefit. Revisit if subscription drain becomes a concern.

## When to revisit

- If `beam-free` extraction quality is measurably worse than gpt-oss on fact yield.
- If the OpenCode Go subscription limits become binding.
- If a genuinely free (no subscription) model with reliable structured output appears.

## Related

- ADR-052 (Hindsight agent-memory platform)
- ADR-054 (Hindsight extraction model via OpenRouter) — amended by this ADR
- GUL-112 (this change), GUL-114 (OpenRouter outage + fallback gap)
- Tracking note: `2026-10-23-gul-112-hindsight-beam-free-go.md`