# ADR-051: A grey-zone profile falls back to the *other* reseller's copy of the same model

## Status

Accepted — 2026-10-12. **Amends ADR-042** ("the grey routes have no fallback by design", Consequences
→ Reliability, and When to revisit). Does not supersede it: the 11 routes, their suffix scheme, the
separate SOPS secret and the trust boundary all stand. This ADR adds a *profile-level* fallback
between two of those routes. Related: ADR-044 (the same `fallback_providers: {}` trap, on a different
profile), ADR-050 (the SOU lane szarik supervises).

## Context

The `szarik` profile — the grey-zone supervisor that runs on Opus 5.5 through the OneProvider reseller
route and supervises the Qwen 3.8 Flash OpenChamber worker — had:

- `model.default: claude-opus-5-5-oneprovider` (a single route, on a provider with no SLA), and
- `fallback_providers: {}` — which normalises to **zero** routes
  (`hermes_cli/fallback_config.py::_iter_fallback_entries` drops a bare dict with no
  `provider`/`model`).

On 2026-10-12 at 22:27 the Supreme Leader gave szarik an overnight goal. `api.oneprovider.dev`
returned `400 {"error":{"message":"The requested model is not available"}}` for about **20 seconds**.
The consequences were disproportionate to the outage:

1. Every main-model turn failed. Failing turns still consume the budget — **5 turns burned in 25
   seconds** — so a few minutes of outage would exhaust `max_turns: 20` and pause the goal anyway.
2. The **goal judge died with it**, because `auxiliary.goal_judge` was unset and therefore inherited
   the main model. Five consecutive judge transport failures is the hard stop
   (`DEFAULT_MAX_CONSECUTIVE_TRANSPORT_FAILURES = 5`) → the goal auto-paused **permanently**, 25
   seconds into an eight-hour run, and stayed paused after the reseller recovered.

The balance was never the issue: `GET /v1/usage` showed **$230.76 of $250 remaining**, `isValid: true`.

ADR-042 anticipated this trade-off and chose the opposite answer — "the grey routes have no fallback
by design; remove rather than paper over". That rule exists to stop a *chronically* bad provider from
being propped up indefinitely. It does not cover a 20-second catalogue blip, and it says nothing
about an unattended overnight agent whose failure mode is "silently does nothing all night".

The key constraint that shapes the fix: **szarik's LiteLLM virtual key is deliberately scoped to the
11 grey-zone Claude routes only** (verified via `GET /key/info`; `deepseek-v4.1-flash-ollama` and
`claude-sonnet-5-5-claudeapikey` both correctly 403). So a fallback to a first-party model is not
available without widening the key — and widening it would undo the scoping that makes the experiment
legible.

## Decision

1. Configure `fallback_providers` in the **`szarik` profile** to the *other* reseller's copy of the
   *same* model — the twin route ADR-042 deliberately created:

   ```yaml
   fallback_providers:
     - provider: llm.voitech.dev
       model: claude-opus-5-5-claudeapikey
       base_url: https://llm.voitech.dev/v1
       api_mode: chat_completions
       key_env: LM_API_KEY
   ```

   `key_env`, never `api_key: ${LM_API_KEY}` — Hermes does not env-expand `${…}` in
   `fallback_providers` entries, and the literal string ships to LiteLLM as a 401.

2. The fallback is **same-model, cross-reseller, and only that**. It does not switch model class, so
   "Opus 5.5 supervises" remains true for every turn of the experiment; only the intermediary
   changes. This is precisely the head-to-head comparison ADR-042 wired the `-oneprovider` /
   `-claudeapikey` suffixes for.

3. Separately, pin the profile's goal judge off the main model's route (see note below) — but note
   that **the fallback is the load-bearing fix**. Re-routing the judge stops the *pause*; it does not
   stop a dead primary from burning the turn budget.

## Consequences

**Positive**

- A single reseller outage no longer kills an unattended run. The two routes are independent
  endpoints, so their availability is uncorrelated in the common case.
- The experiment's premise is preserved: same model, same whitelist, no new credentials, no widened
  key, no new secrets, no cost increase.
- Reversible in one config key. Nothing in the cluster, the repo or LiteLLM changes.

**Negative**

- The trust boundary is unchanged and still applies to both routes — and a fallback means a request
  can now land on a provider the operator did not pick for that turn. The spend also becomes split
  across two balances, which makes "how much is left on szarik's routes" a two-endpoint question.
- It partially contradicts the letter of ADR-042's "no fallback by design". Accepted deliberately:
  that rule guards against propping up a *chronically* bad provider, not against surviving a blip.
  If `claudeapikey` starts failing *consistently*, the rule applies again — remove it, do not chain
  deeper.
- Latency and prompt-cache behaviour differ between resellers, so a turn that has failed over is not
  a perfectly clean experimental data point. Recorded, not corrected.

## Alternatives considered

1. **Do nothing; keep the single route.** Rejected: that is the configuration that just failed. It
   converts a 20-second upstream blip into an eight-hour silent no-op.
2. **Fall back to a first-party model (Ollama / Gemini / Z.AI).** Rejected as impossible without
   widening szarik's virtual key, and widening it would erase the deliberate scoping that makes this
   profile an experiment rather than a generic agent. Worth revisiting if the scoping is ever
   relaxed.
3. **Fall back to a cheaper Claude on the same reseller** (e.g. `claude-haiku-4-5-oneprovider`).
   Rejected: it keeps the correlated-failure property — the outage that motivates the fallback takes
   the fallback down with it. Same-reseller fallback is decoration.
4. **Add an intra-route `model_group_alias`/deployment fallback inside LiteLLM's `model_list`.**
   Rejected: it changes the *route* semantics and muddies the per-provider suffix scheme that
   ADR-042 uses for head-to-head comparison. The profile layer is the right place for a
   profile-level resilience decision.
5. **Chain a third and fourth entry for depth.** Rejected: two grey routes do not become more
   trustworthy by being listed three times, and a long chain hides which route actually served the
   turn.

## When to revisit

- `claudeapikey` starts failing *consistently* — then ADR-042's rule applies in full: remove the
  route, do not paper over it. A one-entry chain whose entry is dead is worse than an honest failure.
- Either reseller's `/v1/usage` reports `isValid: false`, hits zero balance, or the key expires
  (OneProvider: 2027-01-07).
- szarik's virtual key is ever brought under the GitOps key provisioner — at that point a
  first-party fallback becomes possible and alternative 2 should be re-evaluated.
- The goal judge is ever re-pointed at the main model again. The two fixes in this incident are
  independent, and reverting either one alone re-opens half the failure.
