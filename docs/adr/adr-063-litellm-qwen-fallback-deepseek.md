# ADR-063: LiteLLM Router fallback qwen3.8-flash → deepseek-v4.1-flash for runner lanes

**Date:** 2026-10-15
**Status:** Accepted
**Deciders:** akadmin (Supreme Leader), Andrzej
**Project:** llm-hub (LiteLLM) / OpenChamber Itsaplan runner lanes
**Related:** ADR-029 (OpenCode Go session normalizer — pre-call hook), ADR-028 (MCP transport conventions), SOU-104 (observed failure on the SOU board)

## Context

The OpenChamber Itsaplan sou runner lane (`openchamber-itsaplan-sou-runner`, agent
`itsaplan-worker-sou`) drives OpenCode sessions on `litellm/qwen3.8-flash`. Qwen is hosted by
Alibaba behind the OpenCode Go gateway (`https://opencode.ai/zen/go/v1`). On 2026-10-15, run
SOU-104 died mid-task: after several successful turns, an upstream 400 killed the session.

The actual error, straight from the LiteLLM proxy log:

```
litellm.BadRequestError: OpenAIException - Upstream request failed:
[data_inspection_failed] <400> InternalError.Algo.DataInspectionFailed:
Input text data may contain inappropriate content.
```

Three properties of this failure shaped the decision:

1. **It is content-filter roulette, not traffic or auth.** The task text itself tripped Alibaba's
   data-inspection filter. Retrying the same text on qwen is very likely to fail again — the only
   real cure is another model.
2. **LiteLLM does not classify it as a content-policy error.** No pattern in
   `exception_mapping_utils.py` matches `data_inspection_failed`, so the exception surfaces as
   generic `BadRequestError`. Verified against the deployed 1.85.x source: only
   `ContentPolicyViolationError` / `ContextWindowExceededError` take dedicated fallback paths;
   everything else falls through to the generic `fallbacks` mapping. `content_policy_fallbacks`
   alone would therefore never fire for this error.
3. **OpenCode has no model-fallback concept.** The client (`opencode` session in OpenChamber)
   cannot be taught to retry on another model; if the request 400s, the session dies and the
   bridge reports "produced no assistant text". The fallback must live in LiteLLM, the one
   layer that sees the failure and can re-dispatch.

## Decision

Add a LiteLLM **Router fallback** mapping in `proxy_config.router_settings`
(`apps/llm-hub/litellm-helm-release.yaml`):

```yaml
router_settings:
  fallbacks:
    - {"qwen3.8-flash": ["deepseek-v4.1-flash"]}
  content_policy_fallbacks:
    - {"qwen3.8-flash": ["deepseek-v4.1-flash"]}
```

Both mappings are deliberate:

- `fallbacks` catches the **observed** failure class (generic `BadRequestError` 400 from
  `data_inspection_failed`), and as a side effect also rescues transient upstream 5xx/429s.
- `content_policy_fallbacks` catches any **future properly-classified**
  `ContentPolicyViolationError` on the same route (mapping tables change; belt and braces).

Fallback target: `deepseek-v4.1-flash` — the bare-named OpenCode Go route that already exists in
`model_list`, same gateway and same `OPENCODE_GO_SUBSCRIPTION_API_KEY`. No new credentials, no new
provider, no cost-model change. The OpenChamber runner lanes keep their `qwen3.8-flash` model
id; the fallback is transparent to them.

Fallback session-header safety (verified against the hook source): the ADR-029 pre-call hook
injects `x-opencode-session` into the request `extra_headers` only when absent, and those kwargs
carry into the fallback call — `deepseek-v4.1-flash` is already in the hook's
`OPENCODE_GO_UNSUFFIXED` set and in `model_group_settings.forward_client_headers_to_llm_api`, so
the Go gateway accepts the fallback request with the same session identity as the original.

## Consequences

**Positive**

- Runner lanes on qwen stop dying mid-task when Alibaba's filter spooks; a "produced no assistant
  text" run becomes a rare event instead of a known failure signature.
- Same gateway + same key: no new secret, no new whitelist, no key-provisioner change (verified:
  the runner's LiteLLM key already had `deepseek-v4.1-flash` access — 200 probe from the lane's own pod).
- Scoped per-model mapping: no wildcard, no other route's behaviour changes.
- Fallback responses carry the `x-litellm-fallback-model` header; observable in logs/spend data.

**Negative**

- A fallback answer comes from a different model than the client asked for. For runner tasks that
  is acceptable resilience semantics; if a consumer ever needs strict model identity, it must
  reject on `x-litellm-fallback-model` — nothing does today.
- The generic `fallbacks` mapping also catches genuinely-bad requests (malformed payload) and
  retries them on deepseek once before failing. Cost of one extra up-stream call on a failure path.
- Alibaba's filter applies per-request; the fallback mitigates but does not change that qwen's
  effective behaviour is filtered upstream.

## Alternatives considered

- **Switch the lane to deepseek entirely.** Rejected for now: the lane was configured for qwen and
  the Supreme Leader asked for a *fallback*, not a migration. Also loses nothing — with fallback
  configured, a migration is a one-line lane change later if desired.
- **`content_policy_fallbacks` only.** Rejected: it never fires for this error class because the
  exception never maps to `ContentPolicyViolationError` (verified in the deployed source). It is
  kept *in addition to* `fallbacks`, not instead of it.
- **Retry the same model.** Rejected: `input_data_inspection` failures are deterministic on the
  same text; a retry burns quota and time only to fail again.
- **OpenCode-side fallback / prompt hardening.** Rejected: OpenCode resolves a single model id and
  has no fallback semantics; teaching the worker prompt to "avoid sensitive words" is whack-a-mole
  against a censor we do not control.
- **Static fallback mapping for all `*-go` routes.** Not done: keeps blast radius at the lanes
  that actually use bare routes; other Go aliases have no observed failure mode.

## When to revisit

- If deepseek-v4.1-flash itself starts content-filtering or the Go gateway protocol changes for
  it — pick another unsuffixed route (`OPENCODE_GO_UNSUFFIXED` grows accordingly).
- If LiteLLM later adds a `data_inspection` exception mapping (it would become
  `ContentPolicyViolationError`): mapping still works under `content_policy_fallbacks`; nothing to
  do, just drop the comment in the config.
- If SOU runner tasks are observed *always* falling back (qwen lane effectively useless), migrate
  the lane's model id to deepseek-v4.1-flash and delete the fallback.
- On any LiteLLM major upgrade, re-verify the generic-fallback-catches-BadRequestError path against
  the new source (this was verified for the deployed 1.85.x).