# ADR-094: Hindsight reflect rides the paid `gpt-oss-120b-ollama` route; retain stays free

- **Status**: Accepted
- **Date**: 2026-10-27
- **Issue**: GUL-263
- **Amends**: ADR-091 (the pool stops being reflect's route), ADR-085 (the split
  is now literal: paid routes for reasoning, free route for memory building)

## Context

Hindsight's `reflect` and the background mental-model refresh need a
tool-calling model, several iterations per operation, and a prompt that is
**large**. Measured over the seven days before the GUL-182 pin: 285 successful
reflect calls, **average 12,001 input tokens, largest 55,692**. That is the
number the route has to carry, and it is the number a 130-token smoke test
hides.

GUL-182 pinned reflect to the FreeLLMAPI model group `gpt-oss-120b`. Measured
after the pin (2026-10-26): 1 success in 54 calls in the first hour, then 0 in
78, queue 43 → 64 pending. It failed on capacity, not on tool support:

- groq, the only healthy group member, allows **8,000 TPM** — one reflect call
  does not fit in a minute.
- the Cloudflare key added during GUL-189 answered `context_too_large`
  (HTTP 413, the free tier's input + `max_tokens` ceiling) **153 times** and
  then exhausted its daily quota; its chat template also rejects the `system`
  role.
- five group members still hold no key, and the two that declare no tool
  calling must not get one (ADR-091).

Pre-pin, on FreeLLMAPI `auto`, the same workload had been succeeding 20–30
times a busy hour. So the pool *can* serve this model at this size when a
big-context member is among the routes; it cannot when groq is the only key.

The owner was offered three options and chose the third: split the routes —
`auto` (retain, consolidation) stays free, reflect goes paid.

## Decision

1. **Reflect and the mental-model refresh move to LiteLLM's paid route
   `gpt-oss-120b-ollama`** (`https://ollama.com/v1`, gpt-oss:120b). Measured at
   workload size through llm-hub: 14,912 input tokens with a tool definition →
   valid `tool_calls` in 1.8 s; 20,427 tokens → 1.5 s. Billing is $0.15/M in and
   $0.60/M out, ≈ $0.0018 per call, ≈ $8–16/month at the measured rate, paid out
   of the Ollama usage credits already on the plan. It is the **same model** as
   the pin, so this is a capacity change, not a quality change.
2. **Retain and consolidation do not move.** They stay on FreeLLMAPI `auto`:
   small prompts, no tools, working, free.
3. **The split is per-operation configuration, not a chart change.** Hindsight
   exposes `HINDSIGHT_API_REFLECT_LLM_{BASE_URL,MODEL,API_KEY,…}` and the same
   set for `MENTAL_MODEL_REFRESH` (`config.py`; the provider and key fall back
   to the global ones). The HelmRelease sets the base URL and model; the key
   arrives through `hindsight-secrets` via `envFrom`.
4. **A dedicated virtual key, `hindsight-reflect`**, created against the LiteLLM
   master key and stored in `litellm-user-keys.sops.yaml`, is registered in the
   key provisioner (`HINDSIGHT_REFLECT_KEY`) so its model list stays
   GitOps-managed like every other service key. The same value is mirrored into
   `hindsight-secrets` as `HINDSIGHT_API_REFLECT_LLM_API_KEY` and
   `HINDSIGHT_API_MENTAL_MODEL_REFRESH_LLM_API_KEY` — no plaintext in the
   HelmRelease, and the public repo stays clean.
5. **`render-check.sh` asserts the split**: the four per-operation values, the
   llm-hub Service the base URL names, the absence of a literal key in the
   render, and the presence of both key entries in the SOPS secret. A future
   edit that drops a knob would otherwise silently fall back to the FreeLLMAPI
   base URL and its 8k-TPM route.

## Consequences

**Positive**

- Reflect and refresh work again at the size they actually run, on the model the
  metrics were calibrated on.
- The expensive path is now a metered, measurable one: LiteLLM logs the tokens,
  so the bill for reasoning is visible monthly instead of hiding inside a free
  pool's cooldowns.
- Retain keeps its free lane — the bulk token consumer stays at zero marginal
  cost, which is the point of the split.
- No chart fork, no vendor SDK: LiteLLM already speaks the OpenAI API and the
  route already existed.

**Negative**

- Reflect now depends on a paid account's credit balance. When the Ollama
  credits run dry, reflective memory stops, and Hindsight will report 402/401
  rather than a 429 with a reset time — a different failure to alert on.
- One more hop to debug (Hindsight → LiteLLM → Ollama) when a reflect call is
  slow. LiteLLM's per-key logs make it traceable, but it is not free.
- The stale `memory-hindsight` key still exists in LiteLLM's DB with no SOPS
  entry (it predates ADR-085). It is unused and unrotated; it should be revoked
  rather than reused.
- ADR-091's rule that the pool route appears in no paid chain still holds, but
  the pool is now off the critical path for reflect — a future reader will find
  the pin comments in the HelmRelease's history explaining a state that no
  longer exists.

## Alternatives considered

- **Give the pool more keys** (GUL-189 outcome: Groq, Cloudflare, CLōD). Rejected
  by measurement: the Cloudflare key arrived and answered 413 (size) and
  exhausted its daily quota; groq is 8k TPM; CLōD declares no tool calling. Keys
  add routes, not token budgets.
- **Put reflect on the OpenCode Go plan** (`deepseek-v4.1-flash-go` answered a
  15,428-token tool-call probe in 3.0 s). Rejected: the Go subscription has a
  *weekly* bucket shared with every agent session, and background reflect
  traffic would starve interactive work — the GUL-112 failure in reverse. It is
  also a different model, so the reflect prompt would need re-validation.
- **Run reflect on the local 27B** (`qwen3.8-27b-mlx`, 262k context, no TPM, no
  cost). Rejected: it crashed the MLX backend at ~16k tokens after 285 s, and it
  would compete with Hermes itself for the M1 Max.
- **Move all of Hindsight's LLM traffic to llm-hub.** Simpler to explain, but it
  pays for the bulk retain/consolidation tokens and gives up the working free
  lane. Cheapest in total is the split.
- **Keep the pin and wait for a big-context free key.** Measured dead; the queue
  grew for six hours.

## When to revisit

- FreeLLMAPI gains a healthy member with ≥32k context and a real TPM allowance
  for this model — then re-measure the pool at 12k tokens and decide whether
  reflect's paid lane is still worth it.
- Ollama's credit usage for `gpt-oss:120b` stops being a rounding error against
  the monthly plan, or the plan lapses.
- A cheaper or faster route to the same model appears in LiteLLM (another
  provider, or a local model that survives a 20k-token tool call).
- Reflect's prompt size changes materially (consolidation batching, mental-model
  redesign): the 12k figure is the input to this decision and should be re-taken
  before trusting it again.
