# ADR-031: Qwen3.8-27B MLX 4-bit replaces the ≤12B local-model cap

## Status

Accepted — 2026-10-03 · supersedes the "≤12B local models only" working rule
(a convention, not a numbered ADR) · relates to the LM Studio local-provider
pattern used by `gemma-4-12b-uncensored` and `qwen3.8-9b-heretic-uncensored`.

## Context

Local (M1 Max / LM Studio) model choices were capped at ~12B as a proxy for
"will fit in 32 GB and won't be a weirdo". The cap forced us onto small Qwen3.8
distills: `qwen3.8-9b-heretic-uncensored` (a fine-tune of
`empero-ai/Qwen3.8-9B-Distill`) spent a whole afternoon in runaway-think loops
— `content:""` with every token burned in `reasoning_content`.

Reading the lineage proved the failure is structural, not the heretic's fault:

- The 9B-Distill card documents that *every* answer opens with a thinking block
  inherited from the 2.4T teacher, "including occasional over-long
  deliberation", and has **no mention of `enable_thinking`** anywhere.
- There is no official Qwen3.8 model at or below 12B. Every sub-12B option is a
  distill from that same family. Buying the "clean" parent buys the same trap.

The official `Qwen/Qwen3.8-27B` ships a real escape hatch in its chat template:

```
chat_template_kwargs: {"enable_thinking": false}   # pre-emits an EMPTY think block
reasoning_effort: "low" | "medium" | "xhigh"
preserve_thinking: false                            # stop reasoning-trace accumulation
```

Verified from `chat_template.jinja` (8.9 KB) pulled from the quant repo before
any bytes were downloaded: with `enable_thinking:false` the template closes the
think block for the model at the generation boundary, so a deliberation cannot
open. On 32 GB of unified memory, the 4-bit MLX quant of the 27B lands at
16.08 GB — 50% of the machine, ~16 GB headroom for KV cache and OS.

## Decision

Host `lmstudio-community/Qwen3.8-27B-MLX-4bit` (official weights, 4.2M
downloads, apache-2.0) in LM Studio on the M1 Max and expose it through
LiteLLM as **two aliases**:

- `qwen3.8-27b-mlx` — passthrough; clients that send their own
  `chat_template_kwargs` control thinking per request.
- `qwen3.8-27b-mlx-nothink` — route-side default
  `chat_template_kwargs: {enable_thinking: false, preserve_thinking: false}`
  for clients (Open WebUI, agents, humans) that don't think about kwargs.

The heretic alias is marked deprecated in the HelmRelease comment (kept routed
for now — no dangling clients). Sampling rule for this family: never
greedy-decode (documented repetition loops); temp 0.7, top_p 0.8, top_k 20,
presence_penalty 1.5. Keep the LiteLLM→LM Studio hop on the direct LAN
(pf-forward to `192.168.1.129:1234`), never through the Cloudflare edge, whose
~100 s timeout will 524 a 27B cold load.

## Consequences

**Positive**
- A model with a documented, template-enforced non-thinking path replaces one
  that structurally cannot stop deliberating.
- Live verification on this box: loop-trap prompt with 4000 max_tokens returns
  `finish=stop` with clean numbered content in ~130 s — no burn, no bail.
  Small prompts answer in 4–10 s — "quite responsive" per the Supreme Leader's
  own LM Studio chat.
- The ≤12B rule's real intent (fit + sanity) is better served at 50% RAM than
  at 17% RAM with a broken model.

**Negative**
- ~2× slower per token than a 9B; cold load ~27 s.
- 16 GB resident means the big GGUF companions (gemma-12b etc.) share less
  headroom — one fat model at a time on this Mac.
- Multimodal (`image-text-to-text`) checkpoint — harmless for text, but LM
  Studio reports `max_context_length` 262144; we cap loaded context at 16k.
- `chat_template_kwargs` is a vLLM-ism; whether LM Studio's MLX engine honours
  it per-request is quantified in the tracking note, not assumed here.

**Alternatives considered**
- `empero-ai/Qwen3.8-9B-Distill` (the "clean" parent) — same lineage trap,
  rejected.
- `unsloth/Qwen3.8-27B-GGUF` UD-Q4_K_M (16.46 GB) — fine llama.cpp fallback if
  MLX ever misbehaves on this arch; MLX preferred for LM Studio on Apple
  Silicon.
- `Qwen3.8-Flash-Next` 125B MoE (111.5 GB 4-bit) — hard no on a 32 GB Mac.
- Keeping ≤12B literally — the only compliant members are exactly the family
  that failed.

## When to revisit

- We add a GPU box or a 64 GB+ Mac — bigger/faster local serving changes the
  size calculus.
- LM Studio adds first-class thinking-control config for this family (then the
  nothink alias kwargs can be replaced by an engine-level setting).
- The 27B proves too slow for the workloads we actually run it for → retarget
  the alias to a GGUF or a smaller official model that *does* document a
  non-thinking mode.
