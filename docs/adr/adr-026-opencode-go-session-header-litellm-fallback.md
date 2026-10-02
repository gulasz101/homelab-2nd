# ADR-026: OpenCode Go session header — LiteLLM fallback strategy

## Status

Accepted — 2026-10-02

## Context

The OpenCode Go subscription endpoint (`https://opencode.ai/zen/go/v1`) enforces a
stable per-conversation `x-opencode-session` header on chat requests. Since
2026-09-06 unauthenticated-of-session requests are rejected:

```
litellm.BadRequestError: OpenAIException - Request is missing x-opencode-session
and cannot be routed efficiently.
```

Clients in the homelab and their session-header support (verified against the
vendor's validated-clients table, 2026-10-02):

| Client | Sends `x-opencode-session`? |
|---|---|
| OpenChamber worker (native `opencode-go` provider) | Yes — native |
| Updated Hermes builds (> v0.21.0, PR #101864) | Yes — on main/auxiliary requests |
| Hermes v0.21.0 (current M1 Max install) | **No** — fix merged after this release |
| Open WebUI | **No** — listed nowhere in vendor table |

The proxy runs `forward_client_headers_to_llm_api: true`, which forwards only the
headers a client actually sends. Clients that send nothing go upstream with
nothing and get 400.

The model line-up also drifted badly: the Go endpoint now exposes 36 model ids
while our LiteLLM config carried 22 from July, 7 of which no longer exist
upstream.

## Decision

Two changes, both via GitOps in `apps/llm-hub/`:

1. **Per-route `extra_headers` fallback on all `-go` suffixed routes:**

   ```yaml
   extra_headers:
     x-opencode-session: "h2-litellm-fallback-session"
   ```

   LiteLLM v1.85.7 merge order (verified in source, `litellm/main.py`):
   forwarded client headers are applied first, then config `extra_headers` on
   top. For header-less clients (Open WebUI, Hermes ≤ v0.21.0) this injects the
   session id the gateway demands. The value is a non-secret, shared, static
   identifier.

2. **Model line-up refresh**: 29 `-go` routes matching the live endpoint
   (`GET /v1/models` → 36 ids) after probing every id with a minimal chat
   completion. Deliberately excluded:

   - `gpt-6-luna`, `gpt-5.6-luna`, `grok-4.6`, `grok-4.7`, `minimax-m2.7` —
     HTTP 400 `ModelProtocolUnsupported` on plain chat-completions (streaming
     too); they need OpenCode-native request framing.
   - `muse-spark-1.2-contributor`, `muse-spark-1.3-contributor` — require
     enabling "paid endpoints that train on request data" in workspace privacy
     settings; not enabled without owner sign-off.

   The OpenChamber worker route (`deepseek-v4.1-flash`, no `-go` suffix) keeps
   NO fallback so the native client's genuine per-session header is never
   masked.

## Consequences

Positive:

- Open WebUI and current Hermes can use all 29 working `-go` models through
  `llm.voitech.dev` with zero client-side changes.
- Routing-caching trade-offs for fallback-session traffic are limited to
  clients that cannot send the header; OpenChamber keeps native routing.
- Config is public-repo-safe: the fallback id contains no secret.

Negative / risks:

- `-go` routes mask a genuine client session header (config extras merge last).
  Accepted because header-sending clients should use the unsuffixed native
  route... which currently exists only for `deepseek-v4.1-flash`. If more
  native routes are needed, the fallback must move to a pre-call hook that
  injects the header ONLY when absent.
- The vendor monitors traffic for abuse; a shared static session id across all
  homelab clients is a quality compromise (worse prompt-cache routing) and
  could look bot-like at scale. Homelab traffic volume makes this acceptable.
- Static config ages: the endpoint's model list changes without notice
  (verified: 7 of 22 July routes died quietly). Re-probe before adding tiers or
  models; a periodic availability check job is the durable answer if this
  recurs.

## Alternatives considered

1. **Upgrade every client to a session-header-capable build** (Hermes > v0.21.0,
   some OpenWebUI pipe/hack). Rejected as the only mechanism: Open WebUI has no
   native support on the vendor list at all, and Hermes is mid-flight on the
   M1 Max (update deferred, kills the active session). Clients we control get
   upgraded for their own benefits; the proxy-side fallback covers the rest.

2. **Per-request header-injecting pre-call hook in LiteLLM** (custom callback
   that sets `x-opencode-session` only when the client did not send one).
   Technically the best pattern — preserves true per-session routing for every
   client — but requires shipping and maintaining a custom callback in the
   LiteLLM pod. Rejected for now: static per-route `extra_headers` is a one-
   commit, zero-code fix. Revisit if the vendor complains about routing quality
   or if a second unsuffixed native route is needed.

3. **Drop OpenCode Go entirely, use bare Ollama Cloud / Z.AI routes.** Rejected:
   the subscription is paid for through 2026 and several -go models
   (kimi-k3, glm-5.3 family, qwen3.8 family) have no equivalent on the other
   providers at comparable cost.

## When to revisit

- The vendor formally blocks shared/static session ids.
- We need a second unsuffixed (native-header) route for a header-sending client
  other than the OpenChamber worker.
- The endpoint's model list changes again (re-probe; consider automating the
  availability check as a CronJob).
- Hermes ships the updated session-header build on the M1 Max — then re-test
  whether Hermes should migrate to an unsuffixed native route.