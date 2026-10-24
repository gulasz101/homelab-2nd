# ADR-083: Hindsight LLM (retain + consolidation) moved to free-openrouter

- **Status**: Accepted
- **Date**: 2026-10-24
- **Supersedes**: ADR-082 (Hindsight fact-extraction LLM on beam-free-go)

## Context

After ADR-082 and its GUL-112 follow-up, both Hindsight LLM roles ran on
`beam-free-go` (`openai/beam-free` on OpenCode Go). The consolidation backlog then
ran at about 420–480 calls/h with ~20k tokens per call. From 2026-10-24 ~04:30Z,
**every** `beam-free-go` call came back `429 Rate limit exceeded` upstream:
29,827 failures on 2026-10-23 and 3,153 on 2026-10-24 by 13:30Z, with no
success since 04:29Z. Fact extraction was stuck retrying every 60 s.

Beam's quota is shared. The owner wants every Paperclip agent on `beam-free-go`
(GUL-122), so Hindsight on beam would keep starving them, which is the "waiting
for timeouts" problem the move was meant to solve.

By then consolidation was finished, and steady-state Hindsight traffic is tens of
calls per hour.

## Decision

Both `HINDSIGHT_API_LLM_MODEL` and `HINDSIGHT_API_CONSOLIDATION_LLM_MODEL` point at
the LiteLLM route **`free-openrouter`** (`openrouter/openrouter/free`, OpenRouter's
free-model router, on the rotated key from GUL-121).

- The route gets `timeout: 120`, below Hindsight's 210 s consolidation budget.
- The route has **no fallback**, on purpose: falling back to `beam-free-go` would
  put Hindsight back on the agents' quota. When the free tier is exhausted,
  Hindsight's queue waits and retries; memory may lag, but agents never do.
- The `memory-hindsight` virtual key's model list gets `free-openrouter` via
  `POST /key/update`. The key is manually scoped, not provisioned from the repo
  (same as ADR-082).
- The owner explicitly accepted that free OpenRouter providers may log or train on
  the transcripts Hindsight sends.

Smoke test before the switch: 4/4 strict `json_schema` fact-extraction calls
through `free-openrouter` returned valid JSON in 9–13 s.

## Consequences

**Positive**

- Beam's whole quota is left to the agents.
- No subscription or per-token spend for memory building.
- The existing alerts (`hindsight_llm_calls_total` per scope and success, and the
  consolidation schema-rejection rule) make this a measurable experiment.

**Negative**

- `openrouter/free` picks a different underlying model per call, so extraction
  quality and latency vary from call to call.
- The free tier has per-minute and daily request caps. A large backlog (like the
  2026-10-23 one) will exceed them and drain slowly.
- Privacy: transcripts leave the homelab for third-party free providers.

## Alternatives considered

1. **Stay on beam-free-go.** Rejected: it is the shared, currently exhausted quota
   the agents need.
2. **free-openrouter with a fallback to beam-free-go.** Rejected: under load the
   fallback would move Hindsight's traffic straight back onto the agents' quota.
3. **Local model in LM Studio on the M1 Max** (for example qwen3.8-27b, a 35B-A3B
   MoE, or Underdog-Saluki-27B). Deferred: the Max has 32 GB and also runs
   Ideogram 4 and FLUX.2-klein (~15 GB of weights). LM Studio's on-demand loading
   would load an LLM mid-render. Worth revisiting as an optional route that gives
   way to image jobs.
4. **Paid OpenRouter model (gpt-oss-120b / deepseek-v4.1-flash).** Rejected for
   now: the owner prefers free and flat-rate routes. The rotated key has only a
   $5 limit.

## When to revisit

- Fact yield or consolidation schema-rejection rate on `free-openrouter` is
  clearly worse than on beam (Grafana: `hindsight_llm_calls_total{success="false"}`).
- The free tier's daily cap becomes binding in steady state, not just during
  backlogs.
- A local model route becomes viable (an image-job-aware LM Studio setup, or
  another box).
- Beam stops being free, or the agents move off it.

## Related

- ADR-082 (superseded), ADR-054, ADR-052
- GUL-122 (this change), GUL-121 (OpenRouter key + `free-openrouter` route fix), GUL-114
- Tracking note: `homelab/tracking/2026-10-24-gul-122-model-rewire.md`
