# ADR: LiteLLM is pinned at 1.106.6 so DeepSeek routes can turn thinking off

- **Status**: Pending
- **Date**: 2026-10-31
- **Issue**: GUL-690 (unblocks GUL-476)
- **Related**: ADR-106 (the fleet runs on DeepSeek direct), ADR-052 (Hindsight is the agent-memory platform)

## Context

The `deepseek-v4.1-flash-1017-ds` route is the fleet's model, and Hindsight reflect needs to call a
tool on it. Through our LiteLLM it could not: a forced `tool_choice` came back
`400 Thinking mode does not support this tool_choice`, 10 of 10 probes at 21k input tokens. Straight
to `api.deepseek.com` with `thinking: {"type": "disabled"}` the same model answered 10/10 in 1.3-2.3 s.
The model was fine; the gateway was the problem.

We were on LiteLLM **1.85.7** (26 June 2026). Its DeepSeek transform accepts **only**
`{"type": "enabled"}` and maps `reasoning_effort: "none"` to *no thinking field at all*, which
DeepSeek reads as thinking **on**. So "thinking off" was unexpressible through our wire, and every
forced tool call died in the upstream validator. Read in `litellm/llms/deepseek/chat/transformation.py`
in both versions, not inferred.

## Decision

1. **Pin chart and image at `1.106.6`** (`apps/llm-hub/litellm-helm-release.yaml`), one bump of both
   pins. 1.106.6 accepts `thinking: {"type": "disabled"}` and maps `reasoning_effort: "none"` to it.
2. **The pin moves as a pair, always.** Chart version == image tag == the release upstream cut. The
   previous comment "chart default appVersion is fine; pin only if needed" is what let the pin rot 21
   minor versions behind; it is replaced with the rule.
3. **Version bumps are PRs, applied by Flux.** No `helm upgrade` by hand, and the rollback is a
   `git revert` of the bump commit (plus the CNPG S3 restore if the schema itself has to come back -
   Prisma migrations are forward-only).
4. **Config is not "corrected" in the upgrade.** `reasoning_effort` stays absent from the route
   definition; the caller decides. Moving reflect onto `-ds` is GUL-476's job.

## Consequences

- **Caller-visible change on DeepSeek routes:** `reasoning_effort: "none"` (and
  `thinking: {"type": "disabled"}`) now genuinely disables thinking. Before, both were silently
  ignored and the model reasoned anyway. Any client that passed `none` while relying on getting
  reasoning tokens back will now get none - that was never a documented promise, and no caller in
  this homelab does it.
- **Fallbacks that land on a DeepSeek route inherit the same semantics.** `hindsight-consolidation-go`
  falls back to `deepseek-v4.1-flash-go`, which is `openai/` against OpenCode Go, not the native
  `deepseek/` provider, so it is unaffected - the transform only runs for `deepseek/`.
- **DB migrations now use the v2 resolver by default** at pod start (1.104.0+). We keep migrations on
  boot (`DISABLE_SCHEMA_UPDATE` unset, `migrationJob.enabled: false`), which is what 1.85.7 already
  did; the v2 resolver is the one that avoids schema thrashing between two contending versions.
- **21 minor versions of drift are gone**, including 1.92.0's AES-256-GCM at-rest credential
  encryption with its re-encryption migration. Our Postgres is a CNPG cluster with S3 backups and WAL
  archiving to OMV MinIO, so the migration is recoverable.
- We owe LiteLLM a version watch: 21 minors behind at the first sign of trouble is the actual defect
  this ADR closes, not the tool_choice bug.

## Alternatives

- **Bypass LiteLLM for reflect** (call DeepSeek direct from Hindsight with its own key). Rejected:
  two places hold the provider key, spend leaves the gateway, and the next route-level fix would be
  needed twice.
- **Patch the 1.85.7 transform in a custom image.** Rejected: a forked Python package to maintain for
  a fix upstream already shipped.
- **Bump to the newest 1.99.0** (the first version with the fix, per GUL-476). Rejected: taking the
  oldest carrying version means paying the drift again in a month; 1.106.6 is the current stable.
- **`drop_params` + a proxy-side rewrite of `tool_choice`.** Rejected: hides the problem, and
  `tool_choice: none` was already proven to produce zero calls.

## When to revisit

- If a DeepSeek transform regression makes `disabled` a no-op again: run
  `apps/llm-hub/scripts/probe-gul690-deepseek-thinking.py` (needs `LITELLM_PROBE_KEY`, 5 probes) - a
  tool call must come back with no `reasoning_content`, 5 of 5.
- If LiteLLM moves past the four-supported-minor-lines window again - treat 8+ minors of drift as a
  scheduled upgrade, not a fire.
- If any caller starts relying on reasoning tokens while sending `reasoning_effort: "none"`.
