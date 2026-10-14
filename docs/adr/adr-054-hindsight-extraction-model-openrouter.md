# ADR-054: Hindsight fact-extraction model via OpenRouter instead of Ollama Cloud

- **Status**: Accepted
- **Date**: 2026-10-14
- **Amends**: ADR-052 (Hindsight agent-memory platform) — §LLM backend only

## Context

ADR-052 chose Hindsight as the single agent-memory platform and pointed its fact-extraction
LLM at LiteLLM in front of Ollama Cloud (`nemotron-3-nano-30b-ollama`). During the
OpenViking → Hindsight migration every retain began failing:

```
429 - {'error': 'timed out waiting for a concurrent request slot'}
```

That string is emitted by **LiteLLM itself**, not Ollama Cloud: its upstream slot pool for
`ollama.com` was exhausted. A trivial `"Say OK"` request timed out at 90–120 s, and all three
models permitted by the `memory-hindsight` key failed identically. Hindsight's own background
`consolidation` jobs hit the same wall with the migration client fully stopped, proving the
contention was cluster-wide rather than client-side.

Diagnosis cost several hours and several thousand failed requests. The Supreme Leader
purchased OpenRouter credits and directed that Hindsight be repointed to `openai/gpt-oss-120b`.

## Decision

Hindsight's fact extraction runs through **OpenRouter**, exposed in LiteLLM as:

- `model_name: gpt-oss-120b-openrouter` → `openrouter/openai/gpt-oss-120b`
- `HINDSIGHT_API_LLM_MODEL: gpt-oss-120b-openrouter`

The Ollama Cloud route (`gpt-oss-120b-ollama`) is **retained** in the model list. Same slug,
different provider, deliberately kept so the two can be compared head to head.

Embeddings and reranking are **unchanged** — they stay on the in-cluster TEI pods, which were
never the bottleneck (embedding measured at 0.65 s, 1% of retain wall time).

## Consequences

**Positive**

- Migration succeeds: 25/25 verified with zero failures at 37.9 s/memory.
- OpenRouter has materially higher concurrency headroom than the shared Ollama Cloud endpoint.
- A larger model (120b vs 30b) should produce better fact extraction, though this is unmeasured.
- Provider choice becomes a one-line change — the structural fragility is fixed, not just patched.

**Negative**

- Per-request latency is higher (~38 s/memory vs ~20 s at best on nemotron) — it is a 120b model.
- Consumption now draws on paid OpenRouter credits rather than the Ollama subscription.
- Two near-identical model names exist and are easy to confuse; the `-openrouter` suffix is load-bearing.
- Extraction quality differences between the two backends are not yet quantified.

## Alternatives considered

1. **Stay on nemotron, run serial overnight.** Rejected: ~24 h projected, and it still 429s —
   going slower does not help when the slots are permanently occupied. (Note: restarting LiteLLM
   later cleared much of the wedge independently; this mitigation was discovered late.)
2. **Widen only the key, keep Ollama.** Rejected: the three key-permitted models all failed
   identically, so this addresses neither the slot contention nor the throughput.
3. **Run multiple LiteLLM replicas.** Rejected: nodes were memory-tight (arr-box 95%, t460 90%)
   and new pods could not schedule.
4. **Paired with credits on a different provider** — OpenRouter chosen for breadth of models
   under one key/API.

## Pitfalls recorded

- **`gpt-oss-120b` is a reasoning model**: it emits `reasoning_content` first, so a small
  `max_tokens` yields `content: null` that looks like a failure but is an HTTP 200 success.
- **`kubectl scale` against Flux-managed workloads is drift**: it triggered a Helm rollback that
  silently reverted the ConfigMap change. Fix the desire in Git, then
  `flux reconcile helmrelease … --force`.
- LiteLLM's `/key/list` returns opaque strings (no `key_alias` to match) and `/key/info` omits
  the key id; `POST /key/update` accepts **the key value itself** as the identifier.
- **Restart the proxy before spending money**: the LiteLLM pod had been up 2d18h and its slot
  pool was wedged; a restart returned nemotron to 1.3 s responses.

## When to revisit

- If OpenRouter costs become material relative to value.
- If extraction quality needs measuring — run a sample through both routes and compare fact yield.
- If a local GPU becomes available for extraction (would remove the per-request cost entirely).
- If Hindsight begins supporting batched or parallel retain, at which point throughput should be
  re-measured against both providers.

## Related

- ADR-052 (Hindsight agent-memory platform)
- H2-284 (root-cause ticket)
- Tracking note: `2026-10-14-openviking-hindsight-migration-throttling-wall.md`
