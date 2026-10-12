# ADR-050: The SOU fork lane reaches qwen3.8-flash through an explicit OpenAI-protocol LiteLLM provider

## Status

Accepted — 2026-10-12. Supersedes the implicit decision recorded in commit `123c3e6`
("run the fork lane on deepseek-v4.1-flash because qwen3.8-flash is transport-blocked"),
which is now obsolete: the block was real, but it was a *transport* choice we control,
not an upstream limitation we must live with.

## Context

Itsaplan runner lane #2 — the Star-Office-UI fork (SOU board) — is the cheap "grinder" lane
of the grey-zone pair (ADR-043): a supervisor on Opus 5.5 thinks, this lane does the work.
It was created to run **qwen3.8-flash**, and it never ran it.

The sequence of events, because the missteps are the interesting part:

1. Created (2026-10-09, `68ecb43`) on the LiteLLM **alias** `qwen3.8-flash-go`. First run died
   in 9 s with *"produced no assistant text"* and **never reached LiteLLM**.
2. Root-caused (`c68a2cd`): OpenCode resolves model ids against **its own catalogue** and
   rejects an unknown id *before* any HTTP call, so a LiteLLM-style `-go` alias can never
   resolve inside OpenChamber. A bare route `qwen3.8-flash` was added to the LiteLLM
   `model_list` to mirror the working H2 lane's bare `deepseek-v4.1-flash`.
3. Reverted to `deepseek-v4.1-flash` (`123c3e6`) on the strength of a manual probe: a
   `POST /v1/messages` (Anthropic protocol) with `qwen3.8-flash` answered
   `400 ModelProtocolUnsupported`, while `deepseek-v4.1-flash` answered `200`. Conclusion at
   the time: the OpenCode Go gateway does not offer that protocol for that model, so wait
   for upstream.

The lane has therefore been burning an expensive *worker* model on a lane whose whole point
is being cheap. Re-opened 2026-10-12 with a proper measurement, because the revert had tested
one endpoint while assuming it was the one OpenCode uses.

**What the 2026-10-12 measurement found.** Both facts below were measured from the running
pods, not from config inspection:

| fact | evidence |
|---|---|
| OpenChamber's real worker traffic rides the **OpenAI** protocol | LiteLLM `LiteLLM_SpendLogs`: 270 rows `call_type=acompletion` (i.e. `/v1/chat/completions`) from the OpenChamber pod IP over 48 h; exactly **1** `anthropic_messages` row, and that one was our own probe |
| but for the bare id `qwen3.8-flash` the **native** `opencode-go` provider picks the **Anthropic** transport | LiteLLM proxy log at the moment of the attempt: `litellm.proxy.proxy_server.anthropic_response(): Exception occured … Model Group=qwen3.8-flash` |

So the transport is chosen **per model**, and for this one the native provider picks the one
protocol the gateway cannot serve. Probing the paths directly (same pod, same key):

| endpoint | `x-opencode-session` | `qwen3.8-flash` |
|---|---|---|
| `/v1/messages` | present | ❌ `400 MissingSessionID` |
| `/v1/messages` | absent | ❌ `400 ModelProtocolUnsupported` |
| `/v1/chat/completions` | present | ✅ `200` |
| `/v1/chat/completions` | absent | ✅ `200` |

The model itself is healthy and cheap; **only the Anthropic hop is dead for it**. That is a
transport problem we own, because OpenCode lets us pin the transport in config.

Two further facts pinned down while testing, both worth keeping:

- A `-go`-suffixed id can never work in OpenChamber:
  `400 Unknown model 'litellm/qwen3.8-flash-go'` — the client rejects it before any HTTP call,
  even when the alias exists in LiteLLM.
- The OpenAI path needs **no** client-side session header: LiteLLM's session-normalizer
  callback injects `x-opencode-session` (the model is listed in `OPENCODE_GO_UNSUFFIXED`), so
  a provider that does not emit one is perfectly acceptable here.

## Decision

Declare a **second provider in the OpenChamber opencode seed**, whose transport is pinned to
the OpenAI protocol, and point the SOU lane at it:

```json
"litellm": {
  "npm": "@ai-sdk/openai-compatible",
  "name": "LiteLLM (OpenAI protocol)",
  "options": {
    "baseURL": "http://litellm.llm-hub.svc.cluster.local:4000/v1",
    "apiKey": "{env:OPENCHAMBER_LITELLM_KEY}"
  },
  "models": { "qwen3.8-flash": { "name": "Qwen3.8 Flash (LiteLLM -> OpenCode Go)" } }
}
```

- The `itsaplan-worker-sou` agent model becomes `litellm/qwen3.8-flash`; the runner lane's
  `OPENCHAMBER_PROVIDER`/`OPENCHAMBER_MODEL` become `litellm` / `qwen3.8-flash` (bare id — the
  seed declares exactly that id, and the alias is unresolvable anyway).
- The native `opencode-go` provider is **left alone** and keeps serving the H2 lane's
  `deepseek-v4.1-flash`. The experiment does not go near the lane that works.
- opencode seed `6` → `7`, with the matching pod-template annotation
  `homelab.voitech.dev/opencode-seed-version: "7"` on the openchamber Deployment, so the
  re-seed is declarative rather than a hand restart.
- The `qwen3.8-flash` route and its header-forwarding entry stay in LiteLLM as they are
  (ADR-029): they are correct and are what makes the headerless OpenAI path work.

## Consequences

**Positive**

- The cheap grinder lane finally runs the cheap model: one intent (cheap fork worker) now
  matches one line of config, and the H2 lane's costly model is no longer spent on fork work.
- Verified end-to-end before committing, on the live cluster: a session created through
  OpenChamber's own API with `providerID=litellm`, `modelID=qwen3.8-flash` and the real
  `itsaplan-worker-sou` agent answered `PONG`, and LiteLLM recorded
  `openai/qwen3.8-flash | acompletion | success` from the OpenChamber pod.
- No new secret, no new vendor, no router change: the same `OPENCHAMBER_LITELLM_KEY` and the
  same LiteLLM base URL, only a different declared transport.
- The failure mode is loud and diagnosable: a wrong id fails with `Unknown model` immediately,
  and a wrong transport shows up as an endpoint name in the LiteLLM proxy log.

**Negative**

- A custom provider means OpenCode installs `@ai-sdk/openai-compatible` from npm at runtime
  (it landed in `/storage/opencode-config/node_modules/@ai-sdk` on first use). A cluster
  without registry egress would break this lane — the native provider never needed it.
- The custom provider must **declare every model** it serves; there is no catalogue fallback.
  `litellm/deepseek-v4.1-flash` answers `Unknown model` today, by design of the models map.
- The per-conversation session id now comes from LiteLLM's normalizer hook rather than from
  the client's native provider header. Removing or narrowing that hook (its
  `OPENCODE_GO_UNSUFFIXED` set) would resurrect `MissingSessionID` on this lane.
- Two providers to keep coherent, and the seed must stay byte-comparable with the live file
  before every bump — the existing seed-bump discipline, now with more surface.
- No `limit.context`/`limit.output` metadata is declared for the custom model, so OpenCode's
  context accounting for this lane is a default rather than the true window.

## Alternatives considered

- **Stay on `deepseek-v4.1-flash`.** Rejected: it is the answer to "qwen cannot work here",
  and that turned out to be false — the block was a transport choice, not an upstream gap.
- **Keep the native provider and just use the bare `qwen3.8-flash` id.** Rejected on
  measurement: that is exactly the combination that produces
  `400 ModelProtocolUnsupported` / `MissingSessionID`.
- **Use the `qwen3.8-flash-go` alias.** Rejected: the client rejects it before any HTTP call
  (`Unknown model`). The alias exists in LiteLLM for other consumers and stays there.
- **Wait for the OpenCode Go gateway to add Anthropic-protocol support for this model.**
  Rejected: no timeline, no need, and the workaround is one config block we control.
- **Override the npm package per model under the existing native provider.** The docs hint at
  per-model npm overrides for mixed setups; rejected because it would put an experiment inside
  the provider that serves the healthy H2 lane, and the blast radius of getting it wrong is a
  broken production lane instead of a broken experiment.
- **Route qwen through a LiteLLM alias that OpenCode resolves as an OpenAI model** (e.g. reuse
  the id of some model OpenCode already knows as OpenAI-protocol). Rejected: it depends on
  undocumented client catalogue internals; the explicit provider states the transport once,
  in our own config.

## When to revisit

- If OpenCode's native `opencode-go` provider starts emitting the OpenAI transport for
  `qwen3.8-flash` — collapse back to one provider and delete the custom block.
- If OpenChamber migrates to a native LiteLLM/OpenAI-compatible provider with a catalogue, or
  if OpenCode gains an explicit per-model `api`/transport field in the provider config.
- If the cluster ever loses npm registry egress, or the pod's provider cache is wiped on every
  rollout (the custom provider then needs vendoring or a bundled SDK).
- If LiteLLM's `OPENCODE_GO_UNSUFFIXED` set or the session-normalizer hook changes (ADR-029).
- If the fork lane needs a model other than `qwen3.8-flash` — remember the models map is the
  allow-list, and the id in it must be bare.
