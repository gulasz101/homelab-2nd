# ADR-105: DeepSeek's own API joins LiteLLM as the `-ds` family, and `deepseek-v4.1-flash-1017` is served by the upstream id `deepseek-flash`

**Date:** 2026-10-29
**Status:** Accepted
**Deciders:** Wojtek Gula
**Project:** homelab-2nd / llm-hub
**Related:** GUL-591, ADR-029 (Go session normaliser), ADR-036 (advertise the real
context window), ADR-085 (LiteLLM carries paid subscriptions only), ADR-091 (free tiers
live in FreeLLMAPI), tracking note `homelab/tracking/2026-10-29-deepseek-ds-route.md`

## Context

Every LiteLLM route so far rides a pooled subscription: `-ollama` is the Ollama Cloud
plan, `-go` is the OpenCode Go plan. A single weekly quota wall on either one takes the
same routes down at once, which is why the fallback chains end on the *other* plan rather
than on a third vendor. Wojtek bought his own DeepSeek API key to get a route that does
not sit in either weekly bucket, and to keep using the model he already runs
(`deepseek-v4.1-flash`), the build he picks in Hermes.

The naming problem is real. On Ollama Cloud the model is `deepseek-v4.1-flash:1017`; on
DeepSeek's own API (`GET https://api.deepseek.com/models`, checked live 2026-10-29) there
are exactly two ids:

- `deepseek-flash` — display name **DeepSeek-V4.1-Flash**, 1,048,576 ctx / 393,216 out
- `deepseek-v4-pro` — DeepSeek-V4-Pro

Sending `deepseek-v4.1-flash:1017`, `deepseek-v4.1-flash` or `deepseek-v4.1-flash-1017`
answers `400 The supported API model names are deepseek-flash, deepseek-v4-pro`. The
`1017` tag is an Ollama snapshot label, not a model name.

## Decision

**1. A third suffix, `-ds`, means "DeepSeek's own API, paid on Wojtek's key".**
It follows the existing rule that the suffix says which account pays. The route is
`deepseek-v4.1-flash-1017-ds`, so the model stays recognisable in Hermes and in the
weekly sync, and the suffix alone tells you the bill is not the Ollama or Go plan.

**2. It uses LiteLLM's native `deepseek/` provider, not `openai/` + `api_base`.**
`model: deepseek/deepseek-flash`, `api_key: os.environ/DEEPSEEK_API_KEY`, no `api_base`.
The native provider carries DeepSeek's own parameter handling, so `reasoning_effort`
(`low|high|max`, the levels the API advertises) maps to its thinking mode instead of
being rejected as an unknown parameter — the failure mode that `drop_params: true` was
having to paper over on the `openai/` routes.

**3. The local name and the upstream id are allowed to differ, in one documented place.**
Local `deepseek-v4.1-flash-1017` resolves to upstream `deepseek-flash`. That mapping is
written down in the route's comment block, in `DS_UPSTREAM_ALIASES` in
`apps/llm-hub/scripts/weekly-model-sync.py`, and here. `model_info` states the real
1M-input / 393k-output window (ADR-036), so Hermes does not silently assume 131k.

**4. The key arrives through the existing `environmentSecrets` injection and a pod-template bump.**
`litellm-provider-keys` is already passed wholesale into the proxy pod, so a new key in
that Secret needs no new `extraEnvVars` entry — only a bump of
`litellm.provider-keys-revision`, because env vars are read once at container start. The
route is added to the key provisioner's `DESIRED_MODELS`, so every service key can reach
it, not just a hand-scoped one.

**5. The weekly sync owns the `-ds` family.**
`weekly-model-sync.py` fetches DeepSeek's catalogue, maps local names through the alias
table, probes the route with the real key, and reports the route as dead if DeepSeek stops
serving the upstream id. Without that it would have treated `-ds` as an opaque manual
route and never looked at it again — a route nobody checks is how GUL-105 happened.

## Consequences

- A third billing relationship, on a personal card rather than a subscription. Spend is
  visible per key in LiteLLM, but nothing stops a Hermes profile burning it by default:
  the route is opt-in, it is in no fallback chain, and switching a profile to it is a
  deliberate config edit.
- Two names for one model. Anyone reading a log line has to know that
  `deepseek-v4.1-flash-1017-ds` is `deepseek-flash` upstream. The comment block and this
  ADR are the only defence; a future rename of the local route must move both.
- A `-ds` route never appears or disappears with an upstream catalogue, so it cannot be
  auto-generated. It is hand-written, preserved by the sync, and only *checked* by it.
- The key rotation path is now three providers, and a forgotten
  `provider-keys-revision` bump fails as `401` on one route while every other route
  keeps working — which looks like a DeepSeek outage.

## Alternatives considered

- **Point the `-ollama` route at DeepSeek's API.** Rejected: the suffix would then lie
  about who pays, and a quota wall on Ollama would look like a key problem.
- **Name the route `deepseek-flash-ds` / `deepseek-v4.1-flash-ds`.** Rejected: Wojtek
  runs the 1017 build in Hermes and asked for the name to keep matching. The build label
  is what he selects on; the upstream id is an implementation detail.
- **`openai/` + `api_base: https://api.deepseek.com/v1`.** Rejected: it works, but
  `reasoning_effort` then needs `allowed_openai_params`/`drop_params` per route, and the
  proxy would silently retry without the parameter — success that hides a downgrade.
- **Add the route to a fallback chain as a third hop.** Rejected for now: it turns an
  opt-in paid key into an unattended spender for every agent. If a chain needs a third
  vendor later, that is a separate decision with its own budget.
- **A second LiteLLM instance for personal keys.** Rejected: one proxy, one key table,
  one set of metrics. A second deployment doubles the surface for no routing gain.

## When to revisit

- DeepSeek publishes the `1017`-style snapshot ids on its own API: drop the alias and
  point the route straight at the real id.
- The key's spend stops being trivial against the subscription plans: either cap it with
  a LiteLLM budget on the consuming key, or retire the route.
- A `-ds` route is ever needed in a fallback chain: decide the spend policy first.
- The pending-ADR mechanism lands (ADR-111): this ADR predates it and keeps its
  hand-written number and index row; adoption allocates numbers for new ADRs only.
