# ADR-036: Local MLX context — pin the MLX runtime to 1.8.5 (LM Studio auto-fit override)

## Status

Accepted — 2026-10-05 · relates to and amends **ADR-031** (which capped the
`qwen3.8-27b-mlx` loaded context at 16k as a workaround). No Supersedes.

## Context

`karakeep-nightly-digest` (cron id `23c784ff743d`) pins
`model: qwen3.8-27b-mlx` and died on 2026-10-05 06:00 with:

```
litellm.BadRequestError: The number of tokens to keep from the initial prompt
is greater than the context length … Received Model Group=qwen3.8-27b-mlx
```

The job's session wanted ~28k tokens. The Supreme Leader had previously set the
model's context manually in LM Studio, but the setting "got lost". Investigation
found the cause is **not** lost config:

- The per-model default file
  `~/.lmstudio/.internal/user-concrete-model-default-config/lmstudio-community/Qwen3.8-27B-MLX-4bit.json`
  is written as `llm.load.contextLength`, and the server log confirmed the value
  was received: `configured=262,144`.
- The MLX engine's **context auto-fit** then overrode it:
  ```
  [context_fit] Model context auto-fit: family=qwen3_5 max=262,144 fitted=42,496
  working_set=24.96GiB reserve=3.00GiB safe_ceiling=21.96GiB baseline=14.95GiB
  full_kv=65536B/token
  ```
  Every load path (GUI, `lms load -c`, REST `/api/v1/models/load`, JIT) clamped
  262,144 → **42,496**. Passing `autoFitMinContextLength` failed the load
  outright: `MLX AutoFit selected 42496, below the required minimum of 262144`.
- This is a known LM Studio regression (bug-tracker #2250, #2287; mlx-engine
  #366), introduced ~the 0.4.20/0.4.21 app update, present on MLX runtimes
  **1.10.1 and 1.11.0**.

LM Studio ships several MLX runtimes side-by-side and `lms runtime select`
switches between them. On MLX runtime **1.8.5** the override is absent and the
configured context is honoured.

## Decision

On the M1 Max LM Studio host:

1. **Pin the MLX runtime to `mlx-llm-mac-arm64-apple-metal-advsimd@1.8.5`**
   (`lms runtime select`). Selection persists in
   `~/.lmstudio/.internal/backend-preferences-v1.json`.
2. Keep the per-model default at **`llm.load.contextLength = 262144`** and
   **`llm.load.numParallelSessions = 1`** (parallel sessions multiply KV memory;
   1 keeps the whole budget for one request).
3. Do **not** enable MLX KV-cache quantization on this model — the vision (VLM)
   batched path rejects it: *"The mlx-vlm batched vision path does not support KV
   cache quantization yet."*
4. Treat **42,496** as the value to alarm on: if `lms ps` shows that CONTEXT,
   auto-fit is back (a runtime re-select or app update moved us off 1.8.5).
5. **Advertise the window on the LiteLLM alias.** The `qwen3.8-27b-mlx` entry in
   `apps/llm-hub/litellm-helm-release.yaml` gains
   `model_info: {max_input_tokens: 262144, max_output_tokens: 32768}`. Without it,
   LiteLLM omits `max_input_tokens` for an `openai/` passthrough and clients
   (Hermes) fall back to a **131072** default — the second half of why the nightly
   digest reported it "could not shrink" a ~28k session. The pin and the metadata
   are one decision: the model must both *serve* and *advertise* 262k.

## Consequences

**Positive**
- `qwen3.8-27b-mlx` loads and JIT-loads at **262144** context — the ~28k-token
  karakeep job fits with room to spare. Verified end-to-end: a 24k-token prompt
  returned HTTP 200 (previously a hard failure).
- The whole chain agrees on the window: LM Studio serves 262144, LiteLLM
  `/model/info` advertises `max_input_tokens=262144` (verified live after the
  Helm rollout), so Hermes no longer falls back to 131072.
- The fix is a runtime pin + a config value + two metadata lines, no model swap,
  no code change.

**Negative**
- 262k is the *engine ceiling*, not a claim the box can hold 262k of live KV
  (f16 KV is ~64 KiB/token → the real working set saturates well before that;
  auto-fit's own estimate was ~22 GiB of KV at 256k, over the safe ceiling). At
  `numParallelSessions=1` this is a headroom ceiling that a single pathological
  request could still swap against.
- We are **pinned to a pre-1.10 MLX runtime**, frozen out of newer MLX
  performance/bug fixes until LM Studio ships an opt-out for auto-fit.
- On any LM Studio app update, re-verify both the runtime pin and the effective
  context.

## Alternatives considered

- **Set the context in the GUI only** — rejected; all four load paths clamp on
  the affected runtimes (reproduced).
- **`llm.load.mlx.autoFit: false`** — present in the app's config schema but
  ignored at load time on 1.10.1/1.11.0 (the bug).
- **MLX KV-cache quantization (8-bit) to make 256k *physically* fit** — rejected:
  the VLM path refuses the load.
- **Swap to a GGUF qwen3.8-27B (llama.cpp path)** — llama.cpp honours the
  configured context and supports KV-cache quantization, but is slower on Apple
  Silicon and means re-downloading a ~16 GB quant. Kept as the fallback if MLX
  1.8.5 ever regresses.

## When to revisit

- LM Studio ships an explicit auto-fit opt-out (or fixes #2250/#2287): un-pin
  the runtime and take the newer MLX engine.
- We move `qwen3.8-27b-mlx` off the karakeep digest path to a model with a
  smaller working set.
- The Mac gains more unified memory (64 GB+) — the auto-fit ceiling stops being
  the binding constraint.
