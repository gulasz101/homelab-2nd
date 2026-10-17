# ADR-069: Go-lane cross-account fallback keeps the model (`deepseek-v4.1-flash-openrouter` before gpt-oss)

**Date:** 2026-10-17
**Status:** Accepted
**Deciders:** Wojtek Gula; implemented by Claude Code
**Project:** llm-hub (LiteLLM router)
**Related:** ADR-068 (cross-account terminal hop, refined by this), ADR-063 (same-account qwen → deepseek hop)

## Context

ADR-068 made every OpenCode Go lane end its fallback chain on `gpt-oss-120b-openrouter`, so a Zen Go
weekly wall no longer kills sessions. The Go workspace hit that wall again on 2026-10-17
(`Go usage limit exceeded`, from ~07:50Z), and in the following hours 18 requests were rescued by
gpt-oss-120b. Sessions survived, but agent work (Hermes profiles falling back to
`deepseek-v4.1-flash-go`, OpenChamber lanes) ran on a smaller open-weight model for the whole wall.

The same model, `deepseek/deepseek-v4.1-flash`, is sold on OpenRouter at $0.15 / $0.60 per M tokens
(in / out) on the account we already use. Probed from the LiteLLM pod with the cluster key on
2026-10-17: HTTP 200, served model `deepseek/deepseek-v4.1-flash` (provider DeepInfra), no silent
substitution.

## Decision

1. New route `deepseek-v4.1-flash-openrouter` → `openrouter/deepseek/deepseek-v4.1-flash`
   (`OPENROUTER_API_KEY`).
2. Every Go-lane chain tries it before gpt-oss:

   ```yaml
   fallbacks:
     - {"qwen3.8-flash": ["deepseek-v4.1-flash", "deepseek-v4.1-flash-openrouter", "gpt-oss-120b-openrouter"]}
     - {"deepseek-v4.1-flash": ["deepseek-v4.1-flash-openrouter", "gpt-oss-120b-openrouter"]}
     - {"deepseek-v4.1-flash-go": ["deepseek-v4.1-flash-openrouter", "gpt-oss-120b-openrouter"]}
     - {"qwen3.8-flash-go": ["deepseek-v4.1-flash-openrouter", "gpt-oss-120b-openrouter"]}
   content_policy_fallbacks: same shape for the two bare names
   ```

3. The route is added to the key-provisioner `DESIRED_MODELS`, like `gpt-oss-120b-openrouter`.
4. Session-header safety as in ADR-068: the new name doesn't end in `-go` and isn't in
   `OPENCODE_GO_UNSUFFIXED`, so the ADR-029 hook leaves it alone.

## Consequences

- During a Go wall, Go-lane traffic keeps the same model family; quality no longer drops.
- OpenRouter spend during walls is a bit higher per token than gpt-oss-120b. It's still cents at
  homelab volume, and it only happens while Go is failing.
- gpt-oss-120b stays as the last hop if OpenRouter's DeepSeek providers fail.
- Qwen lanes get DeepSeek on OpenRouter rather than Qwen on OpenRouter. This is deliberate: Qwen
  content filtering (ADR-063) is upstream-side, and DeepSeek is the better agentic model.

## Alternatives considered

- **Keep ADR-068 as is.** Rejected by the owner: gpt-oss is too weak for agent sessions that run
  for a whole wall.
- **`qwen3.8-flash-openrouter` as the hop.** Rejected: likely served by the same Alibaba filter
  that ADR-063 works around, and weaker than DeepSeek for agentic work.
- **Ollama Cloud `deepseek-v4.1-flash-ollama`.** Not chosen: Ollama Cloud already carries the
  primary models of several Hermes profiles (e.g. Andrzej on `kimi-k2.7-code`), so it isn't an
  independent account for those lanes.

## When to revisit

- OpenRouter DeepSeek availability or price changes.
- Go walls become frequent: then consider a second Go workspace or moving lanes off Go.
