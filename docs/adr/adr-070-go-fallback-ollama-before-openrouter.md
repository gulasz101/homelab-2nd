# ADR-070: Go-lane fallback tries Ollama Cloud before OpenRouter (amends ADR-069)

**Date:** 2026-10-17
**Status:** Accepted
**Deciders:** Wojtek Gula; implemented by Claude Code
**Project:** llm-hub (LiteLLM router)
**Related:** ADR-069 (amended), ADR-068, ADR-063

## Context

ADR-069 sent every OpenCode Go lane straight to `deepseek-v4.1-flash-openrouter` when Go fails. That
hides the failure from the client: LiteLLM answers from OpenRouter and the caller sees a success.

Hermes profile Szarik runs `deepseek-v4.1-flash-go` with its own fallback to
`deepseek-v4.1-flash-ollama`, the flat-rate Ollama Cloud subscription. After ADR-069 that fallback
never fired, so during a Go weekly wall all of Szarik's traffic went to pay-per-token OpenRouter. The
owner wants OpenRouter used rarely (normally only for Hindsight). The other subscription should
carry Go walls.

ADR-069 rejected Ollama because it isn't independent for profiles whose primary is on Ollama (e.g.
Andrzej on `kimi-k2.7-code`). That is still true, but it argues for keeping OpenRouter *after*
Ollama, not for skipping Ollama.

## Decision

Insert `deepseek-v4.1-flash-ollama` ahead of OpenRouter in every Go-lane chain:

```yaml
fallbacks:
  - {"qwen3.8-flash": ["deepseek-v4.1-flash", "deepseek-v4.1-flash-ollama", "deepseek-v4.1-flash-openrouter", "gpt-oss-120b-openrouter"]}
  - {"deepseek-v4.1-flash": ["deepseek-v4.1-flash-ollama", "deepseek-v4.1-flash-openrouter", "gpt-oss-120b-openrouter"]}
  - {"deepseek-v4.1-flash-go": ["deepseek-v4.1-flash-ollama", "deepseek-v4.1-flash-openrouter", "gpt-oss-120b-openrouter"]}
  - {"qwen3.8-flash-go": ["deepseek-v4.1-flash-ollama", "deepseek-v4.1-flash-openrouter", "gpt-oss-120b-openrouter"]}
content_policy_fallbacks: same shape for the two bare names
```

The route already exists and is already in the key-provisioner `DESIRED_MODELS`. Its name doesn't
end in `-go`, so the ADR-029 session-header hook leaves it alone.

## Consequences

- A Go wall is carried by the Ollama subscription at the same model; no per-token spend.
- OpenRouter is reached only when Go and Ollama both fail.
- Clients' own Ollama fallbacks (Szarik) become redundant during a wall, which is harmless.
- A profile that falls from Ollama to Go (Andrzej) gets one extra Ollama attempt before OpenRouter.
  If Ollama is down, that costs one failed call of latency.

## When to revisit

- Ollama Cloud starts rate-limiting us during Go walls: then put OpenRouter back first for some lanes.
