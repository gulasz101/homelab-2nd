# ADR-113: The agent fleet runs on Ollama Cloud routes, not on the OpenCode Go allowance

- **Status**: Accepted (amended 2026-11-05 by GUL-971 / GUL-972; amended 2026-11-13 by GUL-1429)
- **Date**: 2026-10-29
- **Issue**: GUL-581
- **Related**: ADR-085 (LiteLLM carries paid subscriptions only), ADR-094 (Hindsight reflect on a paid Ollama route), ADR-075 (Paperclip org and agent runtimes), GUL-122 / GUL-480 (Pi sends `reasoning_effort`)

## Context

Every coding agent in the company — six `pi_local`/`opencode_local` Paperclip runners plus six
Hermes gateway profiles — pointed its primary model at an OpenCode **Go** route
(`qwen3.8-flash-go`, `qwen3.8-max-go`, `deepseek-v4.1-flash-go`, `beam-free-go`). Those routes all
bill the same weekly Go allowance, and the fleet now burns it faster than the week resets: runs
fail on 429s, agents look broken, and the owner asks "why is it rate limited again".

LiteLLM already carries a parallel set of Ollama Cloud routes (`-ollama`) on a *separate* weekly
allowance, and the OpenCode runner and Andrzej's own profile had already been living on
`deepseek-v4.1-flash-1017-ollama` without trouble. So the question was not "is Ollama good enough",
it was "which route is the default and which is the headroom".

One trap made this non-trivial: `qwen3.8-flash` and `qwen3.8-max` exist **only** on the Go
endpoint. LiteLLM's bare `qwen3.8-flash` route is the same Go upstream without the header
forwarding — not an Ollama route. A literal 1:1 rename of `-go` to `-ollama` therefore points at
routes that do not exist, so the fleet's model *families* had to change, not just their suffixes.

## Decision

1. **Executors** (Pi, Builder, Tester, Majster, OpenCode) run `deepseek-v4.1-flash-1017-ollama`.
2. **Reviewers** (Reviewer, Verifier) run `glm-5.3-ollama` — deliberately a different family from
   the executors, so a review is not the same model grading its own blind spots.
3. **Bill Cipher** (default Hermes profile) runs `beam-ollama`, the Ollama twin of its previous
   `beam-free-go`.
4. The other gateway profiles (`florian`, `matejko`, `szarik`, `andrzej`) run
   `deepseek-v4.1-flash-1017-ollama` with `deepseek-v4.1-flash-ollama` / `glm-5.3-ollama` as
   fallbacks. Fallbacks stay on the same paid relay, never on a free pool, except matejko's last
   resort FreeLLMAPI hop which predates this ADR.
5. **Go routes stay in `model_list`** as headroom and as fallback targets, but no agent's *primary*
   may be a Go route. `claude_local` (Claude Code) is untouched — it bills Anthropic, not Go.
6. **A route a client drives with thinking levels must declare it.** Ollama Cloud accepts
   `reasoning_effort`; LiteLLM rejects params the `openai/` provider does not declare, so
   `deepseek-v4.1-flash-1017-ollama` and `glm-5.3-ollama` carry
   `allowed_openai_params: [reasoning_effort]`. Where the model reasons by default (`beam-ollama`)
   the param is dropped instead, mirroring GUL-122.
7. Where a client cannot express "no reasoning param" (`pi`'s model catalog sends it whenever the
   entry says `reasoning: true`), the catalog says `reasoning: false` until the route declaration
   is deployed.

## Amendment 2026-11-05 — runners on the paid route, chat profiles on the free pool (GUL-971 → GUL-972)

The Ollama Pro weekly allowance ran dry again (`HTTP 429 ... reached your weekly usage limit`,
09:10Z and 10:40Z), so the owner split the fleet by what the workload actually needs. Decisions 1,
2 and 3 above are superseded by this split; decision 5 (Go routes as headroom) and decision 6
(`allowed_openai_params`) still stand.

| surface | route | why |
|---|---|---|
| Paperclip runners: Tester, Builder, Reviewer, Verifier, Majster, Pi (`pi_local`) | `llmhub/deepseek-v4.1-flash-1017-ds` | 30–90 minute tool-calling runs |
| Paperclip OpenCode runner + `~/.config/opencode/opencode.json` (`model`, `small_model`) | `llmhub/deepseek-v4.1-flash-1017-ds` | same work, local CLI |
| Hermes `andrzej` | `qwen3.6-35b-a3b-local` (was `-ds`) | free local lane, superseded 2026-11-13 |
| Hermes root (Bill Cipher), `florian`, `matejko`, `szarik`, `zdzislaw` | `beam-free-go` | chat-shaped work, does not hold the paid allowance |
| `claude_local` (Claude Code) | unchanged | bills Anthropic |

Why the free pool is acceptable here and was not in 2026-10-29: the profiles that move are the ones
that answer a question and stop. Nothing on them opens a PR. `beam-free-go` was checked with a
**forced** `tool_choice` before the move (HTTP 200, `tool_calls[0].function.name` =
`get_homelab_node_status`), so a tool-using turn is not the thing that breaks first.

Two traps recorded on the way, both of which cost a run:

- `longcat-2.5-preview-free-go` and `space-bunny-free-go` are published in `GET /v1/models` but the
  upstream answers `Model is unavailable` — a model group in the list is not a served model. The
  fallback order in this ADR is therefore `beam-free-go` only; check with a real request, not the
  catalogue.
- `deepseek-v4.1-flash-1017-ds` rejects a *forced* `tool_choice` (`Thinking mode does not support
  this tool_choice`). `tool_choice: "auto"` works and returns `tool_calls`. A probe that forces the
  tool call will report the paid route as broken when it is fine.

## Amendment 2026-11-13 — the chat profiles stay on the free pool, andrzej on the local lane (GUL-1428 → GUL-1429)

On 2026-11-12 five chat profiles were moved wholesale to `deepseek-v4.1-flash-1017-ds` after three
free routes hit their walls. The owner reverted it the same night: a profile that answers a question
and stops belongs on the free pool while it lasts, and paying for that turn is waste. So
`beam-free-go` (root, `florian`, `matejko`, `szarik`) and `glm-5.3-ollama` (`zdzislaw`) stay primary,
`-ds` remains the last resort in `fallback_providers`, and the config comments say so — a stale
"moved to -ds" comment above a `beam-free-go` pin is worse than no comment at all.

The one durable change from that pair of issues: **`andrzej` runs the free local lane on the M1 Max,
not the paid route.** The owner's words were "andrzej stays on saluki"; Saluki 27B became
Qwen3.6-35B-A3B the same day (GUL-1431), so the pin is `qwen3.6-35b-a3b-local`. Measured before the
pin: 10.0 s for a 294-token prompt that answers with a `tool_calls` turn. The route carries its own
LiteLLM fallback chain (local → `deepseek-v4.1-flash-1017-ollama` →
`deepseek-v4.1-flash-ollama` → `deepseek-v4.1-flash-1017-ds`), so a local image job holding the GPU
slot costs a slow turn, not a dead run.

Two things the attempt taught, worth more than the move itself:

- A model pin is a preference, not a fix. The owner reverted it the same night it was applied, which
  is the strongest argument for editing files instead of pipelines.
- `~/.hermes/profiles/<own>/config.yaml` is closed to the agent whose profile it is (the tool refuses
  it as security-sensitive). Own-profile changes go through `hermes -p <profile> config set
  model.default <route>`, which is the supported path and still lands without a gateway restart.

## Consequences

- The whole fleet draws on one weekly allowance (Ollama Pro) instead of two. That is the point —
  one quota wall, one thing to watch — but it also means a single exhausted allowance now stops
  everything, Go included only as a manual fallback, not as automatic failover.
- Anyone who wants a `qwen3.8` model is back on the Go allowance. The fleet's default family is
  DeepSeek Flash for execution and GLM for review.
- Model names live in four places that must agree: Paperclip `adapterConfig.model` (with the
  `llmhub/` prefix), `~/.pi/agent/models.json` (pi needs a catalog entry or it cannot resolve the
  model), `~/.config/opencode/opencode.json` (`model` + `small_model`), and each Hermes profile's
  `config.yaml` (`model.default`, `custom_providers[].model`, `fallback_providers[]`).
- Reviewers and executors are different families now, which raises the cost of a same-model
  blind spot and slightly raises the chance of style disagreement between them.
  **After the 2026-11-05 amendment** all seven runners share one route, so that separation is gone
  and a same-model blind spot is back. If a review starts missing what a build missed, the fix is a
  different family for Reviewer/Verifier, not a different quota.
- `pi_local` agents whose instructions bundle is `external` cannot have `adapterConfig` changed by
  an agent key at all (`Board access required`), so their model is a manual board step.

## Alternatives considered

- **Keep Go as primary, Ollama as fallback.** Rejected: the weekly Go wall is the actual failure
  being fixed; a fallback only fires after the primary has already failed the run.
- **Literal `-go` → `-ollama` rename.** Impossible for `qwen3.8-flash`/`qwen3.8-max`: no Ollama
  upstream is published for them. Inventing a route name pointing at a model the vendor does not
  serve would fail at the first call.
- **Local LM Studio models on the M1 Air (`qwen3.8-27b-mlx`).** Rejected for executors: an
  agent run is 30–90 minutes of tool calling, and the laptop's GPU is also serving the gateway,
  the browser and the docs index.
- **FreeLLMAPI free pool as the fleet primary.** Rejected: the free pool is for last-resort
  chat, not for hour-long coding runs with tool schemas (ADR-084, ADR-085).
- **`litellm_settings.drop_params: true` globally.** Rejected as too blunt: it would silently
  swallow genuinely unsupported params on every route, including future ones, and GUL-480 already
  chose per-route declarations for exactly that reason.

## When to revisit

- Ollama Pro's weekly allowance starts failing runs the way Go did — then it is time to split the
  fleet across both allowances by role instead of moving it wholesale.
- A `qwen3.8`-class model becomes the only one that can do a job (e.g. a long-context review task),
  which would force a deliberate Go-route exception per agent.
- Ollama Cloud changes its `reasoning_effort` handling, making `allowed_openai_params` unnecessary.
