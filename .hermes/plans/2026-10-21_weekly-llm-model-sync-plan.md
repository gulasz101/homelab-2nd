# Weekly LLM model-list sync for LiteLLM hub — implementation plan

> Issue: GUL-35
> Owner: Wojciech "Wojtek" Gula
> Goal: Automate a weekly job that pulls available models from Ollama Cloud and OpenCode Go, updates the homelab LiteLLM proxy + key whitelists with `-ollama`/`-go` suffixes, and never leaves an existing Hermes profile or Open WebUI without a working "brain". The first run also repoints Bill Cipher (the default Hermes profile) to `minimax-m3.1-flash-ollama`.

---

## 1. Current state (verified live 2026-10-21)

### 1.1 LiteLLM proxy (`apps/llm-hub/litellm-helm-release.yaml`)
- **Ollama Cloud routes** (`api_base: https://ollama.com/v1`, `api_key: os.environ/OLLAMA_API_KEY`):
  - Configured: `kimi-k2.7-code` (legacy, unsuffixed), `glm-5.2/5.3/5.3-flash/5.1-ollama`, `kimi-k2.7-code/k2.6/k3-ollama`, `minimax-m2.7/m3-ollama`, `deepseek-v4-pro/v4-flash/v4-flash-0731/v4.1-flash-ollama`, `qwen3.5-397b-ollama`, `gemma4-31b-ollama`, `mistral-large-3-675b-ollama`, `nemotron-3-super/ultra/nano-30b-ollama`, `gpt-oss-20b/120b-ollama`.
  - **Live on `https://ollama.com/v1/models` today**: `beam`, `clef:27b`, `deepseek-v4-pro:0813`, `deepseek-v4.1-flash`, `deepseek-v4.1-flash:1017`, `gemma4:31b`, `glm-5.2`, `glm-5.3`, `glm-5.3-flash`, `gpt-oss:120b`, `gpt-oss:20b`, `kimi-k2.6`, `kimi-k2.7-code`, `kimi-k3`, `minimax-m2.7`, `minimax-m3`, `minimax-m3.1-flash`, `mistral-large-3:675b`, `mistral-large-4`, `muse-spark-open`, `nemotron-3-nano:30b`, `nemotron-3-super`, `nemotron-3-ultra`.
  - **Drift**: new Ollama models `beam`, `clef:27b`, `deepseek-v4-pro:0813`, `deepseek-v4.1-flash:1017`, `mistral-large-4`, `muse-spark-open`, `minimax-m3.1-flash`; removed/stale Ollama ids `glm-5.1`, `deepseek-v4-flash`, `deepseek-v4-flash:0731`, `qwen3.5:397b`.
- **OpenCode Go routes** (`api_base: https://opencode.ai/zen/go/v1`, `api_key: os.environ/OPENCODE_GO_SUBSCRIPTION_API_KEY`):
  - Configured: `deepseek-flash-go`, `deepseek-v4-flash-go`, `deepseek-v4-flash-vision-exp-go`, `deepseek-v4-pro-go`, `deepseek-v4.1-flash-go`, `glm-5.1/5.2/5.3/5.3-flash-go`, `hy3-go`, `hy4-preview-go`, `kimi-k2.6/k2.7-code/k3-go`, `longcat-2.0/2.5-preview-free-go`, `mimo-v2.5/v2.5-pro/v2.6-flash/v2.6-pro-go`, `minimax-m2.5/m3/m3.1-flash-free-go`, `hindsight-consolidation-go`, `omen-alpha-go`, `qwen3.6-plus/3.7-max/3.7-plus/3.8-flash/3.8-flash/3.8-max-go`, `space-bunny-free-go`, `deepseek-v4.1-flash` (bare, for OpenChamber), `qwen3.8-flash` (bare).
  - **Live on `https://opencode.ai/zen/go/v1/models` today**: `beam-free`, `claude-haiku-5-5`, `deepseek-v4-pro`, `deepseek-v4.1-flash`, `gemini-4-argon-contributor`, `glm-5.1`, `glm-5.2`, `glm-5.3`, `glm-5.3-flash`, `gpt-5.6-luna`, `gpt-6-luna`, `grok-4.6`, `grok-4.7`, `hy3`, `hy4-preview`, `kimi-k2.6`, `kimi-k2.7-code`, `kimi-k3`, `longcat-2.0`, `longcat-2.5-preview-free`, `mimo-v2.5`, `mimo-v2.5-pro`, `mimo-v2.6-flash`, `mimo-v2.6-pro`, `minimax-m2.5`, `minimax-m2.7`, `minimax-m3`, `minimax-m3.1-flash-free`, `muse-spark-1.2-contributor`, `muse-spark-1.3-contributor`, `omen-alpha`, `qwen3.6-plus`, `qwen3.7-max`, `qwen3.7-plus`, `qwen3.8-flash`, `qwen3.8-max`, `step-5-preview`.
  - **Drift**: new Go models `beam-free`, `claude-haiku-5-5`, `gemini-4-argon-contributor`, `gpt-5.6-luna`, `gpt-6-luna`, `grok-4.6`, `grok-4.7`, `step-5-preview`; removed/stale Go ids `deepseek-flash`, `deepseek-v4-flash`, `deepseek-v4-flash-vision-exp`, `space-bunny-free`.

### 1.2 Key provisioner (`apps/llm-hub/litellm-key-provisioner-configmap.yaml`)
- Runs hourly as `litellm-key-provisioner` CronJob.
- `DESIRED_MODELS` mirrors the proxy `model_list` plus a few `openai/` variants.
- Updates `WIFE_KEY`, `WOJTEK_KEY`, `HERMES_ANDRZEJ_KEY`, `MEMORY_HONCHO_KEY`, `HERMES_BILL_CIPHER_KEY`, `OPENVIKING_KEY`, `PAPERCLIP_CODERS_KEY`.

### 1.3 Open WebUI (`apps/llm-hub/openwebui-helm-release.yaml`)
- `DEFAULT_PINNED_MODELS` currently: `gemma-4-12b-uncensored,glm-5.2-zai,mistral-3.5-middle,kimi-k2.7-code,glm-5.3-ollama,glm-5.3-flash-ollama`.
- Any model removed from LiteLLM but still pinned would show as dead in the UI.

### 1.4 Bill Cipher (default Hermes profile)
- `~/.hermes/config.yaml`:
  - `model.default: deepseek-v4.1-flash-ollama`
  - `fallback_providers: [deepseek-v4.1-flash-go]`
  - `custom_providers` uses `llm.voitech.dev`.
- The target first-run model `minimax-m3.1-flash-ollama` is **not yet configured** in LiteLLM, so it cannot be swapped to until the weekly job has added it and the key provisioner has whitelisted it.

---

## 2. Decisions to make before implementing

1. **Where does the weekly job run?**
   - Option A: a CronJob inside the `llm-hub` namespace that edits the live LiteLLM ConfigMap and calls the key-provisioner API directly. Fast, but violates GitOps (repo drift).
   - Option B: a scheduled job on the M1 Max Hermes host that clones/uses `~/Projects/homelab-2nd`, edits the YAML files, commits, pushes, and triggers Flux reconciliation. Slower but GitOps-native.
   - **Recommendation**: Option B. GitOps is law in this homelab. A drift between repo and cluster is unacceptable for a recurring operation.

2. **Does the job commit directly to `main` or open a PR?**
   - Direct commit is simpler and matches the existing hourly key-provisioner pattern.
   - PR gives a human review gate before models change.
   - **Recommendation**: direct commit for *additions* of newly verified models; open a PR (or at least flag in the run log) for any *removals* because removals risk brain-death.

3. **Who holds the git credentials?**
   - The M1 Max already has `gh` authenticated as `gulasz101`. The script can use `gh` or an SSH deploy key.

4. **How do we handle Bill Cipher's model swap?**
   - Make it a one-time, idempotent action: the script checks whether `model.default` already equals the target; if not, it edits `~/.hermes/config.yaml`, backs it up, and triggers a default-profile gateway restart via the verified `osascript + nohup` escape.

---

## 3. Mapping rules (idempotent, reversible)

### 3.1 Ollama Cloud
- Source API: `GET https://ollama.com/v1/models` → `data[].id`.
- For each `id`:
  - Replace any `:` with `-`.
  - Append `-ollama`.
- Examples already in production: `qwen3.5:397b` → `qwen3.5-397b-ollama`; `gpt-oss:120b` → `gpt-oss-120b-ollama`.
- New examples: `minimax-m3.1-flash` → `minimax-m3.1-flash-ollama`; `deepseek-v4.1-flash:1017` → `deepseek-v4.1-flash-1017-ollama`; `clef:27b` → `clef-27b-ollama`.

### 3.2 OpenCode Go
- Source API: `GET https://opencode.ai/zen/go/v1/models` → `data[].id`.
- For each `id`:
  - Append `-go`.
- Preserve hard-coded **special routes** that must not be suffixed:
  - `deepseek-v4.1-flash` (bare, for OpenChamber native `opencode-go` provider).
  - `qwen3.8-flash` (bare, for OpenChamber native `opencode-go` provider).
- Preserve **derived/hard-coded purpose routes** even if the upstream id changes:
  - `hindsight-consolidation-go` currently maps to `openai/minimax-m3.1-flash-free` on the Go gateway. Keep it; update only if the owner explicitly changes the consolidation model.

---

## 4. Safety / acceptance criteria — the "no brain-death" rules

The weekly job must enforce these rules before any change lands in `main`:

1. **Probe every new model before adding it.**
   - Issue a real `POST /v1/chat/completions` through the **live proxy** using the LiteLLM master key (bypasses whitelist) or a test virtual key.
   - Prompt: `"Say exactly: <model-name> is online"`.
   - Accept only HTTP 200 with a non-empty assistant content.
   - Failed probes are logged; the model is **not added**.

2. **Never remove a model that is still referenced by a consumer.**
   - Before removing a stale `-ollama` or `-go` route, scan:
     - `~/.hermes/config.yaml` and every `~/.hermes/profiles/*/config.yaml` for `model.default`, `fallback_providers`, `auxiliary.*.model`, `custom_providers[*].model`.
     - `apps/llm-hub/openwebui-helm-release.yaml` for `DEFAULT_PINNED_MODELS` and `DEFAULT_MODELS`.
     - Any other hard-coded references discovered during implementation.
   - If a model is referenced, **skip removal**, log it prominently, and optionally open a blocker issue.

3. **Always keep at least one working brain for Bill Cipher.**
   - Before swapping `model.default` to `minimax-m3.1-flash-ollama`, verify it responds on Bill Cipher's own virtual key (`HERMES_BILL_CIPHER_KEY`) **and** that a fallback route (`deepseek-v4.1-flash-go`) remains reachable.
   - The swap is only committed after the proxy route + key whitelist are live.

4. **Key provisioner must succeed before declaring victory.**
   - After Flux reconciles the new proxy config, trigger `litellm-key-provisioner` manually and wait for `condition=complete`.
   - Verify at least Bill Cipher's key lists the new model via `/key/info`.

5. **Smoke-test a consumer after any removal.**
   - If a model was removed, run a chat completion with each affected profile's current default to prove it still works.

6. **No plaintext credentials in the script or repo.**
   - The script reads API keys from existing SOPS secrets / cluster / 1Password (via `op` or `sops`); it does not embed them.

---

## 5. Proposed weekly job architecture

### 5.1 Location and schedule
- Runs on the M1 Max Hermes host (where `~/Projects/homelab-2nd`, `gh`, `kubectl`, `sops`, and Hermes already live).
- Trigger: weekly, e.g., Sunday 04:00 UTC, via `cronjob_manage` or a launchd plist.
- Logs to a dated file and posts a summary to Mattermost / the issue tracker.

### 5.2 High-level flow
```text
1. Fetch https://ollama.com/v1/models and https://opencode.ai/zen/go/v1/models
2. Build candidate model_name sets using the mapping rules
3. Load current litellm-helm-release.yaml model_list
4. Detect:
   - additions: candidate models not currently in model_list
   - removals: current -ollama/-go models not in candidate sets (and not special/derived)
5. For each addition:
   - construct the litellm_params block
   - probe via live proxy (master key or test key)
   - if OK, append to model_list
6. For each removal:
   - check consumer references (Hermes configs, Open WebUI defaults)
   - if referenced, skip and flag
   - if not referenced, remove from model_list and DESIRED_MODELS
7. Update key-provisioner DESIRED_MODELS to match the new model_list (plus openai/ variants)
8. Update Open WebUI DEFAULT_PINNED_MODELS if any pinned model was removed or if owner wants new pinned models (optional; default: do not auto-pin new models)
9. If changes exist:
   - git commit with a descriptive message listing added/removed models and probe results
   - git push origin main
   - force Flux reconcile (gitrepository + kustomization)
   - wait for HelmRelease Ready
   - trigger key-provisioner job and wait for completion
   - verify via /v1/models and /key/info
10. First-run only: if Bill Cipher's model.default is not yet minimax-m3.1-flash-ollama:
    - ensure minimax-m3.1-flash-ollama is in model_list and whitelisted for HERMES_BILL_CIPHER_KEY
    - edit ~/.hermes/config.yaml (backup first)
    - restart default gateway via osascript+nohup
    - verify Bill Cipher responds
```

### 5.3 Script design
- Language: Python 3 (stdlib only for the core diff/probe; `ruamel.yaml` or `PyYAML` for YAML editing if available, otherwise fall back to a templated string approach that preserves comments where possible).
- Idempotency: running twice with no upstream changes produces no commit.
- Locking: use a simple PID file to prevent overlapping runs.
- Dry-run mode: `--dry-run` prints the diff and probe plan without committing.
- Config file: a small JSON/YAML config next to the script listing special routes, derived routes, consumer config paths, and pinning policy.

---

## 6. Step-by-step implementation tasks

### Task 1: Create the weekly sync script skeleton
- File: `scripts/weekly-llm-model-sync.py` in `gulasz101/homelab-2nd` (or `apps/llm-hub/scripts/`).
- Include:
  - argparse for `--dry-run`, `--repo`, `--bill-cipher-swap`.
  - fetch functions for Ollama and Go endpoints.
  - mapping functions.
  - diff logic against current `litellm-helm-release.yaml`.
  - logging to stdout + dated log file.

### Task 2: Add a model-probe harness
- Reuse the LiteLLM master key or a dedicated test virtual key.
- Probe function: `POST https://llm.voitech.dev/v1/chat/completions` with a minimal prompt.
- Collect per-model pass/fail and latency.
- Gate additions on probe success.

### Task 3: Build consumer-reference scanner
- Scan paths:
  - `~/.hermes/config.yaml`
  - `~/.hermes/profiles/*/config.yaml`
  - `apps/llm-hub/openwebui-helm-release.yaml`
- Extract every model string referenced in default, fallback, auxiliary, custom_providers, pinned models.
- Return a set of "protected" model names that must not be removed.

### Task 4: Implement YAML mutation helpers
- For `litellm-helm-release.yaml`: insert/remove entries under `proxy_config.model_list` while keeping comments.
- For `litellm-key-provisioner-configmap.yaml`: update the `DESIRED_MODELS` Python list in the embedded `provision.py` script.
- For `openwebui-helm-release.yaml`: update `DEFAULT_PINNED_MODELS` only when removing a pinned model (replace with the newest verified `-ollama`/`-go` flash model, or leave a TODO).

### Task 5: Add GitOps commit/push/reconcile logic
- `git status --short` to detect changes.
- Commit message template: `feat(llm-hub): weekly model sync — added N, removed M (drift from Ollama/Go)`.
- Push to `origin main`.
- Annotate `flux-system/gitrepository` and `flux-system/apps` kustomization.
- Poll HelmRelease until Ready or timeout.

### Task 6: Integrate key-provisioner trigger and verification
- `kubectl -n llm-hub create job --from=cronjob/litellm-key-provisioner ...`
- Wait `condition=complete --timeout=120s`.
- Verify `/v1/models` advertises the new model.
- Verify `HERMES_BILL_CIPHER_KEY` can see it via `/key/info`.

### Task 7: First-run Bill Cipher swap
- Edit `~/.hermes/config.yaml`:
  - `model.default: minimax-m3.1-flash-ollama`
  - Keep fallback `deepseek-v4.1-flash-go`.
- Backup to `~/.hermes/config.yaml.bak-<timestamp>`.
- Trigger default-gateway restart via `osascript + nohup` script.
- Verify with `hermes -p default chat -q "ping"` or direct curl through `llm.voitech.dev`.

### Task 8: Packaging as a recurring job
- Choose scheduler (launchd plist on M1 Max or Hermes `cronjob_manage`).
- Add a run script wrapper that sets `SOPS_AGE_KEY_FILE`, `PATH`, and working dir.
- Test a dry-run manually.

### Task 9: Documentation
- ADR: why the job exists, why it runs on the M1 Max, the mapping rules, and the safety criteria.
- Update `docs/adr/README.md`.
- Tracking note for the implementation session.

---

## 7. Verification plan

1. **Dry run**: execute the script with `--dry-run` and confirm the diff matches the expected additions/removals from section 1.
2. **First-run probe**: manually probe `minimax-m3.1-flash-ollama` and `deepseek-v4.1-flash:1017-ollama` before the script adds them; expect the probe to fail today because the routes do not exist (confirms the harness can detect a bad route).
3. **Live first run**: run the script for real; expect it to add the new Ollama/Go models, skip removals of referenced models, commit, push, reconcile, provision keys, and swap Bill Cipher's brain.
4. **Post-run checks**:
   - `curl https://llm.voitech.dev/v1/models` lists `minimax-m3.1-flash-ollama` and other new routes.
   - Bill Cipher's key `/key/info` includes `minimax-m3.1-flash-ollama`.
   - A chat completion through Bill Cipher's key with model `minimax-m3.1-flash-ollama` returns `200` and non-empty content.
   - Bill Cipher's `~/.hermes/config.yaml` shows `model.default: minimax-m3.1-flash-ollama`.
   - The default gateway is running and the profile responds.
5. **Weekly regression**: run the script a second time; expect no changes and no commit.

---

## 8. Risks and mitigations

| Risk | Mitigation |
|------|------------|
| New model probes pass on master key but fail on virtual keys | Verify with a real virtual key after key-provisioner runs. |
| Removing a referenced model leaves a profile brain-dead | The scanner blocks removal; stale whitelist entries are harmless. |
| YAML round-trip destroys comments/formatting in HelmRelease | Use targeted string edits or `ruamel.yaml`; validate with `git diff --check` and a YAML linter. |
| Bill Cipher gateway restart kills an active session | Schedule the swap only when the default profile is idle; use osascript+nohup; verify afterwards. |
| Ollama or Go API changes shape / auth | Script validates JSON shape and fails loudly with the raw response in logs. |
| Git push fails / Flux reconcile hangs | Script aborts and alerts; does not perform the brain swap unless GitOps is reconciled. |
| A new model name collides with an existing alias | Mapping is deterministic; collisions are flagged and skipped for human review. |

---

## 9. Open questions for the Supreme Leader

1. **Schedule**: Is Sunday 04:00 UTC acceptable, or do you prefer a different day/time?
2. **PR vs. direct commit**: Direct commit for additions, PR/flag for removals — OK?
3. **Open WebUI pinning**: Should newly added flash/affordable models be auto-pinned, or should pinning remain manual?
4. **Bill Cipher swap confirmation**: Are you happy for the first automated run to change Bill Cipher's default to `minimax-m3.1-flash-ollama`, keeping `deepseek-v4.1-flash-go` as fallback?
5. **Scheduler preference**: launchd plist on the M1 Max, or a Hermes `cronjob_manage` entry? (launchd is more robust for host-level scripts; Hermes cron ties the job to an agent wake.)

---

## 10. What "done" looks like

- [ ] Script committed to `gulasz101/homelab-2nd` under a sensible path.
- [ ] Script runs in `--dry-run` mode and produces a correct diff.
- [ ] First real run adds `minimax-m3.1-flash-ollama` and other live models, commits, pushes, reconciles, and provisions keys.
- [ ] Bill Cipher's default model is `minimax-m3.1-flash-ollama` and he answers a chat ping.
- [ ] Weekly schedule is active and a second run produces no diff.
- [ ] ADR and tracking note are written.
