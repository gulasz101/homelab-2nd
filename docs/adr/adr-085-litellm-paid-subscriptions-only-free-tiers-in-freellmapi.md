# ADR-085: LiteLLM carries paid subscriptions only; free tiers move to FreeLLMAPI

- **Status**: Accepted
- **Date**: 2026-10-24
- **Issue**: GUL-123
- **Supersedes**: ADR-083 (Hindsight on `free-openrouter`), ADR-042 and ADR-051
  (grey-zone Anthropic routes)
- **Amends**: ADR-068, ADR-069 and ADR-070 (the Go-lane fallback no longer ends on
  OpenRouter)
- **Amended by**: ADR-091 (named FreeLLMAPI routes in LiteLLM are allowed)

## Context

After ADR-084, the homelab had two gateways. LiteLLM held 92 routes from nine
upstreams: Ollama Cloud, OpenCode Go, z.ai, Mistral, OpenRouter, Google Gemini,
two Anthropic resellers and local LM Studio. FreeLLMAPI could already pool the
free tiers. Nothing said which gateway a given kind of traffic belonged to. Free
providers were mixed into the fallback chains of paid routes, so a "good" agent
session could quietly end up on a free model.

The owner's ruling (2026-10-24): *"this way I keep clean separation between good
quality inference and cheap stuff"*.

## Decision

- **LiteLLM** (`llm.voitech.dev`) keeps the **paid subscriptions**: Ollama Cloud
  and OpenCode Go (route lists kept current by the Paperclip routine "Weekly LLM
  model-list sync", `apps/llm-hub/scripts/weekly-model-sync.py`). It also keeps
  the **local LM Studio models**. 92 routes became 66.
- **Removed from LiteLLM**: Google Gemini (7 routes), OpenRouter (5), Mistral (1),
  z.ai (2) and the grey-zone Anthropic resellers (11). Their keys left
  `litellm-provider-keys`. The `litellm-grey-provider-keys` secret was deleted;
  its encrypted copy is in git history.
- **FreeLLMAPI** takes the free tiers: Groq, Google AI Studio, NVIDIA, Mistral
  (key moved from LiteLLM into the SOPS declarative config), OpenRouter (new key)
  and Cerebras (as a custom provider). LiteLLM gets **no** routes to FreeLLMAPI.
  Cheap consumers call it directly. Amended by ADR-091 (2026-10-26): one named
  free route, no fallback, in no paid chain.
- **Fallback chains in LiteLLM end at Ollama Cloud.** When Go and Ollama are both
  walled, the caller gets the error. LiteLLM never silently hands paid-tier
  traffic to free providers.
- **Consumers moved:**
  - Hindsight retain and consolidation use FreeLLMAPI `auto`, in-cluster.
  - Hermes default (Bill Cipher) and Matejko run `deepseek-v4.1-flash-go` →
    `deepseek-v4.1-flash-ollama` → FreeLLMAPI `auto`. The last hop is
    client-side and talks to FreeLLMAPI directly over the LAN. The owner allowed
    it while both weekly quotas were walled.
  - OpenWebUI's task model moved from `glm-5.2-zai` to `deepseek-v4.1-flash-go`.

## Consequences

**Positive**

- One question decides where traffic goes: is this good inference or cheap work?
- LiteLLM's route count and key surface shrink. Paid quotas are no longer spread
  over providers that nobody tracks.
- Free-tier churn (new free models, retired ones) is FreeLLMAPI's catalogue
  problem, not hand-edited LiteLLM YAML.

**Negative**

- When both subscriptions are walled (as on 2026-10-24: Go weekly limit and
  Ollama Pro weekly limit at the same time), LiteLLM has no working route.
  Agents without a client-side FreeLLMAPI fallback are down until a reset.
- Grey-zone Anthropic credit (OneProvider, claudeapikey) is no longer reachable.
  Recovering it means restoring the secret from git history and re-adding routes.
- FreeLLMAPI `auto` changes model from call to call. Hindsight extraction quality
  varies, and early consolidation calls got some 502s when every routed free
  model failed.
- Stale model names stay in some manually scoped LiteLLM virtual-key whitelists.
  This is harmless: the routes are gone.

## Alternatives considered

- **FreeLLMAPI behind LiteLLM as `free-*` routes.** This was proposed first and
  rejected by the owner. It puts cheap traffic back through the "good" gateway
  and blurs the line this ADR draws.
- **Keep OpenRouter as the cross-account tail (ADR-068/069).** Rejected. That
  tail is exactly the silent quality drop the split removes.
- **Keep z.ai and the grey-zone resellers as "paid, therefore good".** Rejected
  by the owner: strict rule, only Ollama Cloud and OpenCode Go (plus local models).

## When to revisit

- A third paid subscription is bought: it belongs in LiteLLM.
- Both weekly quotas keep walling at the same time: either buy capacity, or give
  more agents the client-side FreeLLMAPI fallback that Bill and Matejko have.
- FreeLLMAPI grows per-client keys or metrics. Then putting it behind LiteLLM for
  metering may be worth reconsidering.
