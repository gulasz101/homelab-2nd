# ADR-068: OpenCode Go lanes must terminate their fallback chain on a DIFFERENT account (gpt-oss-120b-openrouter)

**Date:** 2026-10-17
**Status:** Accepted
**Deciders:** Andrzej (break-glass, SOU project), Wojtek Gula (ticket owner)
**Project:** llm-hub (LiteLLM router) / OpenChamber Itsaplan runner lanes
**Related:** ADR-063 (qwen3.8-flash → deepseek-v4.1-flash fallback — superseded by this for the
quota case), ADR-029 (OpenCode Go session normalizer), SOU-267 (the ticket), SOU-104 (prior same-lane failure)

## Context

At 01:51:22Z on 2026-10-17 the OpenCode Zen **Go gateway** account serving every
`https://opencode.ai/zen/go/v1` route hit its provider-side quota:

```
litellm.RateLimitError: RateLimitError: OpenAIException - Go usage limit exceeded
429 - {'type': 'error', 'error': {'type': 'GoUsageLimitError',
      'message': 'Go usage limit exceeded'},
      'metadata': {'workspace': 'wrk_01KXTGFFFC4XBA5T9P8TVVQTB8', 'limitName': 'weekly'}}
```

Impact on the SOU OpenChamber runner lane (`openchamber-itsaplan-sou-runner`):

- Run 124 (SOU-223/issue 523) died **mid-task** at 01:51:41 — its last successful model call was
  01:50:57, the wall came up mid-session. Delegated S1 work started, then vanished; no branch pushed.
- Runs 125/126 failed in 16 s / 20 s: the OpenCode session dies on its FIRST model call, and the
  bridge surfaces the empty session as
  `session ses_… produced no assistant text` at `bridge.js:227`.
- The lane was dead for **5+ hours** (01:51Z → ~07:00Z) because every retry hit the same wall.

Root cause of the prolonged outage: the existing ADR-063 fallback chain is
`qwen3.8-flash → deepseek-v4.1-flash`, and **both live on the SAME Zen Go gateway under the SAME
subscription key** — one account, one weekly quota bucket. An account-level 429 defeats a
fallback that shares the account. LiteLLM's router did exactly what it was told: fell back from
qwen to deepseek, got the same 429, ran out of fallbacks, raised → OpenCode session died.

Additional defect found while reading the morning logs: the runner lane's failures ride the
**`-go`-suffixed** group (`deepseek-v4.1-flash-go` — an alias OpenCode sessions also use), and
ADR-063's mapping only covered the **bare** names (`qwen3.8-flash`, `deepseek-v4.1-flash`).
The suffixed aliases had NO fallback mapping at all.

Key asymmetry that shapes the fix: quota walls are **account-scoped**, not model-scoped or even
provider-scoped. A robust chain must end on a provider whose **billing identity** differs from
the primary. Homelab already runs exactly that: `gpt-oss-120b-openrouter`
(`openrouter/openai/gpt-oss-120b`, paid OpenRouter credits, verified serving 200s before/during/
after the wall). Also verified: OpenCode's native provider transports vary **per model**
(ADR-063 era finding) — but from LiteLLM's side every route is plain
`/v1/chat/completions`, so a LiteLLM-side fallback changes transport only upstream of
LiteLLM. OpenCode (client) never learns anything changed.

## Decision

In `apps/llm-hub/litellm-helm-release.yaml` (`proxy_config.router_settings`):

1. **Every OpenCode Go lane model — bare AND `-go`-suffixed — terminates on
   `gpt-oss-120b-openrouter`** (different vendor, different billing account, immune to a
   Zen-Go quota):

   ```yaml
   fallbacks:
     - {"qwen3.8-flash": ["deepseek-v4.1-flash", "gpt-oss-120b-openrouter"]}
     - {"deepseek-v4.1-flash": ["gpt-oss-120b-openrouter"]}
     - {"deepseek-v4.1-flash-go": ["gpt-oss-120b-openrouter"]}
     - {"qwen3.8-flash-go": ["gpt-oss-120b-openrouter"]}
   content_policy_fallbacks:
     - {"qwen3.8-flash": ["deepseek-v4.1-flash", "gpt-oss-120b-openrouter"]}
     - {"deepseek-v4.1-flash": ["gpt-oss-120b-openrouter"]}
   ```

2. **Keep the ADR-063 same-account first hop** (qwen → deepseek): it remains the right rescue for
   Alibaba's content-filter roulette (SOU-104), which is per-model, does not burn the weekly
   bucket, and keeps the cheaper/more-capable provider in play. OpenRouter is the TERMINAL hop.

3. **Session-header safety**: `gpt-oss-120b-openrouter` is NOT in the ADR-029 hook's
   `OPENCODE_GO_UNSUFFIXED` set and does not end in `-go`, so the session normalizer makes no
   attempt to inject `x-opencode-session` into the fallback hop — no `MissingSessionID` risk.
   The hook is fallback-safe by design (inject-only-when-absent; existing kwargs carry through).

4. **Scope unchanged from ADR-063**: plain per-lane mappings, no wildcard. Other routes' routing
   behaviour is untouched. Fallback traffic rides Wojtek's OpenRouter credits and is rare by
   definition (it fires only when the primary path is already failing).

## Consequences

**Positive**

- A Zen-Go account-level wall no longer kills runner lanes outright: sessions complete their turn
  on gpt-oss-120b (quality drop, no session death) until the weekly window resets.
- Suffixed `-go` lane failures (the actual observed failure path from the SOU runner) now have a
  fallback for the first time — closing the ADR-063 coverage gap found during this incident.
- Fallback fires are observable: `litellm_deployment_successful_fallbacks_total` /
  `litellm_deployment_failed_fallbacks_total` (labels collapsed in this install — dimensionless
  counters), plus `x-litellm-fallback-model` response header and SpendLogs rows.

**Negative**

- When both Zen Go models are hard-failing, affected turns are served by a smaller open-weight
  model until the quota resets — visible quality dip, worth tolerating in a homelab runner.
- Rare-but-real spend on OpenRouter credits during Zen outages.
- The Go workspace weekly bucket is exhausted: **all Go-gateway traffic stays walled until the
  provider's weekly window resets** (provider-side clock, outside our control). This fix makes
  the lane resilient to the NEXT wall; it cannot un-wall the current one — the ADR-063-style
  first hop (qwen→deepseek) is unusable until reset, so effective rescue path today IS openrouter.

**Neutral / follow-ups**

- `deepseek-v4.1-flash` (bare) also got a direct openrouter mapping — it had none before; that
  route is the openchamber app pod's native model id (10.42.1.75 traffic), so its sessions gained
  the same protection.
- The runner-lane outage itself (bridge "produced no assistant text" for a quota 429) is a
  known-shape limitation; LiteLLM remains the right layer per ADR-063 finding #3 (OpenCode has no
  fallback concept).

## Alternatives considered

- **Wait for the weekly window to reset.** Rejected: provider-side clock, unknown reset point
  (weekly buckets often rollover on Mondays UTC); SOU chain blocked indefinitely; no durable
  lesson captured.
- **Add a second Zen Go workspace key for deepseek.** Rejected: needs an owner (Wojtek) to create
  a new workspace/subscription upstream — slower, still same single point of failure by vendor,
  and deepseek-v4.1-flash may not even be offered on a different workspace tier.
- **Point the SOU lane's runner at a non-Go model** (e.g. `gpt-oss-120b-openrouter` as PRIMARY).
  Rejected for now: changes the lane's primary model identity mid-chain (workers are mid-task on
  S1 work), loses the Go subscription "unlimited within tier" economics, and the openrouter hop
  as a fallback gives the same resilience without touching primary quality. Worth revisiting if
  Zen walls become frequent — see When to revisit.
- **Grafana dashboard + retry-later watcher.** Partially adopted: incident detection worked (the
  existing `LiteLLMUpstreamRateLimited` Loki alert fired on the window), but a lane-ops
  dashboard would have shown "who is dying what way" faster. The metrics exist; not part of the
  hot fix.

## When to revisit

- If the Zen Go workspace walls again within the same weekly window ⇒ escalate to a
  **multi-account Zen setup** (second workspace key as a separate deployment in the same
  model group) or a non-Go primary for the SOU lane.
- If `gpt-oss-120b-openrouter` itself starts failing while Go is walled (openrouter credits dry),
  the terminal hop needs a third identity — candidate: `gemini-3.5-flash-lite` (different vendor
  again, already in model_list).
- If LiteLLM ships per-deployment fallback metrics with real labels, replace the Loki
  log-count alert with a metric-based one.
- When the SOU chain is unblocked, file the follow-up ADR task: "SOU lane primary model review"
  in Backlog.