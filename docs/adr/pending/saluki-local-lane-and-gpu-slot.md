# Saluki 27B is the only LM Studio model, and it shares the M1 Max GPU with image jobs through one slot

- **Status**: Pending
- **Date**: 2026-11-12
- **Issue**: GUL-1431
- **Related**: ADR-031 (qwen3.8-27b-mlx), ADR-036 (MLX runtime pin), ADR-044 (local model as Hermes offline fallback), ADR-106 (fleet on the paid `-ds` route)

## Context

The Ollama Cloud weekly allowance runs out around Wednesday or Thursday, and the fleet then spends
about 15 EUR a week on DeepSeek's paid API. The owner asked for a free local lane on the M1 Max
(32 GB): Underdog Saluki 27B 1.0 (ConwayResearch, a 2-bit IQ2 GGUF of Qwen3.8-27B, 7.9 GB, plus a
0.63 GB Q8 vision add-on, CC BY-NC 4.0) as the only model in LM Studio. LM Studio held five LLMs
and two embedding models before. The same Mac runs the ideogram4-local image worker, whose local
engines need about 17 GB.

Measured on 2026-11-12, LM Studio 0.4 llama.cpp Metal backend 2.71.0, 64k context, 2 parallel slots:

| what | result |
|---|---|
| RAM with the model loaded | ~12-13 GB (`lms` estimate 13.25 GiB) |
| load time | 11 s |
| output, one request | 10.4 tok/s |
| output, two at once | ~5.5 tok/s each |
| prompt reading | ~60-85 tok/s; 33k tokens took 10.7 min (with Gemma busy on the same GPU) |
| same 33k prompt again (prompt cache) | 63 s |
| thinking default (on) | "write 300 words" spent all 2,500 tokens thinking, no answer |
| `reasoning_effort: none` | thinking off, answer in 0.9 s |
| tool call | correct (`finish_reason: tool_calls`) |
| vision | correct tags for a test image, 16 s |
| no model loaded | HTTP 400 "No models loaded" in 14 ms |

## Decision

1. **LM Studio serves only Saluki**, as identifier `saluki-27b`, 64k context, 2 parallel slots.
   Gemma 4 12B (both), qwen3.8-27b-mlx, qwen3.8-9b-heretic, qwen3-vl-4b and gte-small are
   deleted from the Mac (37 GB freed). nomic-embed-text-v1.5 is bundled inside the LM Studio app
   and stays; nothing loads it. **JIT auto-load is off** (`http-server-config.json`).
2. **One GPU slot, images win.** `host/m1max/bin/gpu-slot.sh`: before a local image job
   (ideogram4, flux2-klein) the worker runs `begin`, which waits up to 90 s for running LLM
   requests and then unloads Saluki; after the job, `end` loads it again. A launchd keeper
   (`com.gulasz101.gpu-slot-keeper`, every 2 min) reloads it after a reboot or a crashed job.
   nanobanana is remote and skips the slot. The hook is in gulasz101/ideogram4-local#9.
3. **LiteLLM routes.** `saluki-27b-local` (thinking as the caller asks, timeout 1800 s) with the
   fallback chain `deepseek-v4.1-flash-1017-ollama` -> `deepseek-v4.1-flash-ollama` ->
   `deepseek-v4.1-flash-1017-ds` (owner ruling: paid DeepSeek only as the last resort).
   `saluki-27b-local-nothink` forces `reasoning_effort: none` and has no fallback; it is
   Karakeep's route.
4. **Karakeep** tags text and images with `saluki-27b-local-nothink` (job timeout 300 -> 900 s).
   **Open WebUI** defaults to `beam-free-go`. The weekly model sync drops pins with no route and
   goes red when the default loses its route; it never picks a default by itself.
5. **The fleet stays where it is for now.** The plan's gate was "a 30k prompt in under about
   5 min". It took 6-10 min, so Majster and the Pi agents are not moved to Saluki until the owner
   decides (GUL-1431).

## Alternatives considered

- **Run Saluki and image jobs at the same time** with 32k context and a higher GPU wired limit.
  Rejected: about 30 GB of 32 GB, the Mac already showed 120k pageouts, and whisper, Kokoro and
  OrbStack share the box.
- **LLM wins** (image jobs wait until the LLM is idle). Rejected by the owner: images win.
- **Keep Gemma for Karakeep** next to Saluki. Rejected: the owner wants one model in LM Studio,
  and two models on one GPU halved Saluki's speed in the test.
- **Thinking on for Karakeep.** Rejected on measurement: one tagging call can spend thousands of
  thinking tokens at ~10 tok/s.

## Consequences

- When the Ollama allowance runs out, `saluki-27b-local` is a free lane, but a slow one: one
  request at a time gets ~10 tok/s, and a cold 30k-token prompt takes minutes.
- During a local image job LLM calls on `saluki-27b-local` go to the cloud chain, and Karakeep
  calls fail and are retried by Karakeep. `KarakeepInferenceFailing` waits 30 min. Measured gaps:
  flux2-klein about 2 min, ideogram4 about 20-25 min (20 steps at ~50 s each; job `3B0xezKVwc4`
  on 2026-11-12: unload 21:23:15Z, reload 21:43:11Z). An ideogram4 job close to 30 min can trip
  that alert once.
- The fallback chain was tested live on 2026-11-12 with Saluki unloaded: LM Studio answers 400
  "No models loaded" at once, LiteLLM tries both Ollama routes and, when the Ollama weekly limit is
  used up (both 429), the call ends on the paid `deepseek-v4.1-flash-1017-ds` after about 11-12 s.
  So in the week's last days an image job makes the "free" lane cost DeepSeek tokens for its
  whole gap. `begin` waited for a running request (8 s) before it unloaded.
- With JIT off, LM Studio answers a request for any model name with the loaded model. The model id
  in the LiteLLM route is a label, not a selector.
- If the Mac's LAN IP moves, three places change: both Saluki routes and the Karakeep alert text.

## When to revisit

- A faster quant or a newer LM Studio backend that reads prompts faster (the gate above).
- If the owner moves the fleet: check every adapter timeout against 6-10 min cold prompts.
