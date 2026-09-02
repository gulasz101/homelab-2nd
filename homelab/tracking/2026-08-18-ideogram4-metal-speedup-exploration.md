# 2026-08-18 Ideogram 4 Metal speedup exploration

**Status:** Explored, no safe gains found. Working setup restored.
**Participants:** akadmin (Supreme Leader), Andrzej

## Goal

akadmin asked whether Ideogram 4 local generation could be made faster, ideally by moving from CPU to GPU (Metal) offload. Current observed generation time on the M1 Max is ~15-21 minutes for a 1216×832, 20-step image.

## What was already true

- `ideogram4-local` runs via `stable-diffusion.cpp` (`sd-cli`) on the M1 Max.
- The wrapper `_sd_cli_cmd()` hardcodes `--offload-to-cpu` and `--diffusion-fa`.
- The skill/memory says GPU usage is "high throughout generation process" and Metal kernel compilation takes 1-2 minutes per job.

## Investigation steps

### 1. Stop the LaunchAgent worker

So a controlled, single-generation test could run without lock contention.

```bash
launchctl unload ~/Library/LaunchAgents/com.gulasz101.ideogram4-local.worker.plist
```

### 2. Verify `sd-cli` knows the `--backend` option

```bash
cd ~/sd.cpp/build/bin && ./sd-cli --help | grep -E "backend|offload|diffusion-fa"
```

Result: `--backend <string>` is present and help text lists examples like `diffusion=vulkan0`. `--offload-to-cpu` is described as "place the weights in RAM to save VRAM, and automatically load them into VRAM when needed".

### 3. Inspect current build flags

```bash
cd ~/sd.cpp/build && grep -i "SD_METAL\|GGML_METAL" CMakeCache.txt
```

Findings:

- `GGML_METAL:BOOL=ON` — the low-level ggml Metal backend is compiled in.
- `SD_METAL:BOOL=OFF` — the **stable-diffusion.cpp runtime backend named `metal` is not registered**.
- `GGML_AVAILABLE_BACKENDS:INTERNAL=ggml-cpu;ggml-blas;ggml-metal`

This is the critical finding: Metal kernels exist, but `sd-cli --backend metal` is rejected.

### 4. Run a CPU baseline to confirm current behaviour

Submitted job `Msjl64iNe9w` using the known-clean template `templates/prompt-blog-gitops-header.json`.

```bash
cd ~/git/ideogram4-local
export IDEOGRAM4_MODELS_DIR=~/sd.cpp-models
JOB_ID=$(python3 ideogram4_local.py submit \
  --prompt-json templates/prompt-blog-gitops-header.json \
  -o output/bench-cpu.png -W 1216 -H 832 -v)
```

Started worker with `--one-shot --no-wait` and timed it.

Log showed:

```text
[INFO ] model_loader.cpp:1238 - loading tensors completed, taking 9.94s
[DEBUG] model_manager.cpp:232  - model manager prepared params backend buffer (4916.71 MB, 455 tensors, RAM)
[DEBUG] model_manager.cpp:324  - model manager staged compute params (4916.71 MB, 455 tensors) to MTL0, taking 13.67s
```

So even with `--offload-to-cpu`, compute parameters are staged to `MTL0` (Apple M1 Max Metal device). The run reached step 7/20 at ~62 s/step before being killed.

Also logged:

```text
ggml_metal_device_init: GPU name:   MTL0 (Apple M1 Max)
ggml_metal_device_init: has unified memory    = true
ggml_metal_device_init: has tensor            = false
```

M1 Max does not expose tensor cores to this path, and the "tensor API" is disabled for pre-M5 devices.

### 5. Try explicit `--backend metal`

Constructed an equivalent direct `sd-cli` command replacing `--offload-to-cpu` with `--backend metal`:

```bash
~/sd.cpp/build/bin/sd-cli \
  --diffusion-model ~/sd.cpp-models/ideogram4-Q4_0.gguf \
  --uncond-diffusion-model ~/sd.cpp-models/ideogram4_uncond-Q4_0.gguf \
  --llm ~/sd.cpp-models/Qwen3VL-8B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf \
  --vae ~/sd.cpp-models/flux2-vae.safetensors \
  -p "$(cat templates/prompt-blog-gitops-header.json)" \
  -o output/bench-metal.png -W 1216 -H 832 --steps 20 \
  --diffusion-fa --backend metal -v
```

It failed immediately:

```text
[ERROR] stable-diffusion.cpp:288  - backend config failed: backend 'metal' was not found
[INFO ] main.cpp:750  - new_sd_ctx_t failed
```

Confirmed by `CMakeCache.txt`: `SD_METAL=OFF`.

### 6. Check upstream Ideogram 4 documentation

Read `~/sd.cpp/docs/ideogram4.md` and the GitHub master version:

- Official example command uses `--offload-to-cpu --diffusion-fa -v -H 1024 -W 1024`.
- No mention of `--backend metal`.
- No performance tuning section.

So the documented path for Ideogram 4 is exactly what the wrapper already does.

### 7. Considered but not attempted

- **Rebuild with `-DSD_METAL=ON`**: Would enable `--backend metal`, but changing the build of the working inference binary is a risk akadmin explicitly did not want to take. Also unknown whether it improves Ideogram 4; official docs don't use it.
- **Asahi Linux + Vulkan + k3s**: Discussed and parked. Would turn the daily-driver M1 Max into a Linux server, and the Honeykrisp Vulkan driver is still maturing. Much higher risk than the current macOS setup.
- **Reduce step count**: Not tested. Could be a future quick experiment, but would change output quality.

## Result

- No safe, verified speedup identified.
- The current configuration is already using Metal via ggml's opportunistic staging, despite the `--offload-to-cpu` name.
- Explicit `--backend metal` requires a rebuild with `SD_METAL=ON`, which is not a zero-risk change and is not endorsed by the upstream Ideogram 4 docs.
- Working setup restored; no persistent changes made.

## Cleanup / restoration

Marked the killed benchmark job as failed:

```bash
cd ~/git/ideogram4-local
rm -f .lock
python3 -c "
import sqlite3
c = sqlite3.connect('jobs.db')
c.execute(\"UPDATE jobs SET status='failed', error='killed during CPU baseline benchmark' WHERE id='Msjl64iNe9w'\")
c.commit()
"
```

Reloaded the LaunchAgent:

```bash
launchctl load ~/Library/LaunchAgents/com.gulasz101.ideogram4-local.worker.plist
```

Worker now listed as `com.gulasz101.ideogram4-local.worker`.

## Files touched

- `/tmp/run-metal-bench.sh` — temporary Metal benchmark script.
- `/tmp/ideogram4-cpu-worker.log` — CPU baseline partial log.
- `/tmp/ideogram4-metal-bench.log` — failed Metal attempt log.
- `~/git/ideogram4-local/jobs.db` — one row updated to mark benchmark job failed.
- No wrapper, plist, model, or build changes.

## References

- `ideogram4-local` skill: `~/git/ideogram4-local/SKILL.md`
- `stable-diffusion.cpp` Ideogram 4 docs: `~/sd.cpp/docs/ideogram4.md`
- GitHub version: https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/ideogram4.md
