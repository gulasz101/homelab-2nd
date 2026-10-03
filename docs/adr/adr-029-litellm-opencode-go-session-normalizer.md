# ADR-029: OpenCode Go session header — per-request normalization in LiteLLM

## Status

Accepted — 2026-10-03 · **supersedes [ADR-026](adr-026-opencode-go-session-header-litellm-fallback.md)**

## Context

The OpenCode Go subscription endpoint (`https://opencode.ai/zen/go/v1`) enforces a
stable per-conversation `x-opencode-session` header on every chat request.

[ADR-026](adr-026-opencode-go-session-header-litellm-fallback.md) (2026-10-02) solved
the immediate 400s with a **static** per-route fallback:

```yaml
extra_headers:
  x-opencode-session: "h2-litellm-fallback-session"
```

LiteLLM merges config `extra_headers` **after** forwarded client headers, so that
constant **masked every real per-session id**. Every client that did not itself send
the header — Open WebUI, Hermes ≤ v0.21.0, and anything generic — was resolved by the
Go gateway to the *same* upstream session. That is a real routing/prompt-cache quality
loss, and the user reported it directly: "it always uses the same value for the session
header; that should be the actual session id of Hermes, opencode, pi.dev."

ADR-026 explicitly named this as its revisit trigger and the correct long-term fix:

> A pre-call hook injecting the header only when absent is the cleaner long-term
> pattern […] Revisit if the vendor complains about routing quality or if a second
> unsuffixed native route is needed.

Upstream still does **not** solve it: LiteLLM PR [#39549](https://github.com/BerriAI/litellm/pull/39549)
(adds an `opencode_go` provider that emits `x-opencode-session`) is **open**, and
issue [#39503](https://github.com/BerriAI/litellm/issues/39503) is unresolved. A code
search of `main` finds no `x-opencode-session`; the latest stable (v1.103.2) does not
emit it. So a version bump alone would not fix this — the fix must live in our config.

The clients in play and what they send:

| Client | Header it sends |
|---|---|
| OpenChamber worker (native `opencode-go` provider) | `x-opencode-session` (real, per session) |
| OpenCode on a generic OpenAI-compatible path | `x-session-id` / `x-session-affinity` |
| Hermes (builds after v0.21.0, PR #101864) | `x-opencode-session` |
| Open WebUI | `X-OpenWebUI-Chat-Id` |
| Claude Code / Codex / Pi / jcode / Kilo | their native session header (`x-<vendor>-session-id`, etc.) |
| Generic / unknown | nothing |

## Decision

Replace the static fallback with a **per-request pre-call hook** that normalizes
whatever session signal the client gives us into one canonical `x-opencode-session` on
the outbound call. Delivered via GitOps in `apps/llm-hub/`:

1. **New ConfigMap** `litellm-session-callbacks` holds `custom_callbacks.py`
   (`OpenCodeGoSessionNormalizer`). The litellm HelmRelease mounts it at
   **`/etc/litellm/custom_callbacks.py`** (chart `volumes`/`volumeMounts`) and
   registers it:

   ```yaml
   litellm_settings:
     callbacks:
       - "prometheus"
       - "custom_callbacks.opencode_go_session_normalizer"
   ```

   **Gotcha:** LiteLLM resolves a callback named `pkg.attr` by loading
   `dirname(config_file)/pkg.py` (`get_instance_fn` in
   `litellm/proxy/types_utils/utils.py`), and the chart mounts the proxy config at
   `/etc/litellm/config.yaml`. The module must therefore sit **next to the config
   file** — `/etc/litellm/custom_callbacks.py`. Mounting it under `/app` and setting
   `PYTHONPATH=/app` does *not* work: that loader reads the file path directly and
   raised `ImportError: Could not find module file /etc/litellm/custom_callbacks.py`.

2. **Resolution order** (first hit wins) inside the hook:
   1. inbound `x-opencode-session` — pass-through, never clobbered
   2. `x-litellm-trace-id` / `x-litellm-session-id`
   3. any `x-<vendor>-session-id`
   4. OpenCode bare `x-session-id` / `x-session-affinity`
   5. `X-OpenWebUI-Chat-Id`
   6. body/metadata `session_id`
   7. SHA-256 of the first user message (stable across a conversation's turns)
   8. random UUID (last resort)

   The hook only injects when the header is **absent**, only for models routed to
   OpenCode Go (`name.endswith("-go")` or the unsuffixed worker route), sets a
   non-generic `User-Agent` (`homelab-litellm/1.0`, as the vendor asks clients to
   identify themselves), and records `litellm_session_id` so spend logs group by
   conversation. It is wrapped in `try/except` — a hook bug logs a warning and lets
   the request proceed unchanged.

3. **Static fallback removed** from all 29 `-go` routes (the source of the constant).

4. **Header forwarding scoped, not global**: the previous global
   `general_settings.forward_client_headers_to_llm_api: true` is replaced by

   ```yaml
   litellm_settings:
     model_group_settings:
       forward_client_headers_to_llm_api:
         - "*-go"                 # every standard Go route
         - "deepseek-v4.1-flash"  # worker's unsuffixed native route
   ```

   `*-go` is a valid regex wildcard in v1.85.7 (`^.*-go$`, verified in
   `auth_checks.is_model_allowed_by_pattern`). This is belt-and-braces: the hook is the
   primary source of the header, and scoped forwarding still carries a genuine client
   header for header-sending clients. It also stops leaking every client `x-*` header to
   Ollama/Gemini/Z.AI, closing the ADR-018 "when to revisit" item.

**Version:** the hook is version-agnostic and runs on the pinned **1.85.7**. No LiteLLM
bump is part of this change; the bump is tracked separately (H2-104).

## Consequences

**Positive**

- Every client now routes to a distinct upstream session where it provides any usable
  signal; the constant is gone.
- A real client header (OpenChamber native, updated Hermes) is never masked — the hook
  injects only when absent.
- Header forwarding is scoped to the one provider that needs it.
- Config stays public-repo-safe: the hook contains no secrets and logs only the
  session id and its source.

**Negative / risks**

- Bespoke Python now lives in the LiteLLM pod (a ConfigMap, no secrets). It is a
  bridge until upstream lands native support.
- The hook's session list (`*-go` + `deepseek-v4.1-flash`) must stay in sync with
  `model_list`; both live in this repo and in the same PR.
- The first-user-message-hash fallback can collide for two conversations that start
  with identical text. Acceptable: it is strictly better than one global constant, and
  clients that send a real header never reach it.
- Resolution now runs on every Go-routed chat call (negligible CPU).

## Alternatives considered

1. **Keep the static fallback (ADR-026).** Rejected: it is exactly the bug — one shared
   session for all clients, a real prompt-cache/routing loss.
2. **Wait for upstream PR #39549.** Rejected as the mechanism: still open, not in any
   release; the pain is live now. It remains the eventual destination (see *When to
   revisit*).
3. **Upgrade every client to a session-header-capable build.** Rejected as the only
   fix: Open WebUI has no native support on the vendor list, and the proxy-side fix
   covers all clients uniformly. Client upgrades still help (Hermes is tracked in
   H2-100).
4. **Per-client pipes/plugins (e.g. an OpenCode plugin, an Open WebUI pipe).**
   Rejected: N brittle client-side fixes instead of one server-side normalizer.
5. **Bump LiteLLM and use a native provider.** Not available yet; deferred to H2-104.

## When to revisit

- **LiteLLM PR #39549 ships in a release** → migrate the `-go` routes to the native
  `opencode_go/` provider, delete this hook, and simplify. Check this during the
  H2-104 version bump.
- **Hermes is upgraded on the M1 Max** (H2-100) → confirm it sends
  `x-opencode-session`; consider an unsuffixed native route for it.
- **A new client dialect appears** whose session signal the hook does not recognise →
  add it to the resolution order (one function).
- **The vendor changes or removes the `x-opencode-session` requirement** → drop the
  hook and the scoped forwarding.
