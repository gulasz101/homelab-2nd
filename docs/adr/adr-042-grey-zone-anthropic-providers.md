# ADR-042: "Grey-zone" Anthropic reseller keys are wired through a dedicated LiteLLM secret + per-provider routes

## Status

Accepted — 2026-10-09 · Standalone (no parent issue). Applies the homelab SOPS-only
credential rule to two evaluation keys that do not come from a first-party provider.

## Context

The Supreme Leader dropped a single SOPS file (`~/anthropic-api.250.sops.yaml`) containing
two API keys for unofficial Anthropic resellers — "grey-zone" providers that resell
Claude API access. The ask: find out what the keys are worth, whether Claude Opus 5.5 can
be exercised on them, and roll both into LiteLLM to compare them.

A direct probe (before any config change) established:

| Key | Endpoint | Balance | Mode | Expiry |
|---|---|---|---|---|
| `anthropic-api-250-key` | `https://api.oneprovider.dev` | USD 250.00 (used 0.00) | `quota_limited` | 2027-01-07 |
| `anthropic-api-100-key` | `https://claudeapikey.dev` | USD 99.98 of 100 | `unrestricted` | — |

Both speak the **Anthropic-native Messages API** (`POST /v1/messages` → 200) and both also
expose an OpenAI-compatible `/v1/chat/completions`. Both expose a `GET /v1/usage`
endpoint that returns live quota/balance plus per-model token stats. `claude-opus-5-5`
answered 200 on both.

These providers are fundamentally different from every other provider in the stack
(Google, Z.AI, Mistral, Ollama, OpenRouter): they have **no contract, no SLA, no billing
relationship, and no guarantee of existence tomorrow**. They may be reselling stolen or
harvested capacity, and they can vanish mid-request. That combination — real money on an
untrustworthy endpoint — is a decision worth recording.

## Decision

1. Store the two reseller keys in their **own SOPS secret**, `litellm-grey-provider-keys`
   (`ONEPROVIDER_API_KEY`, `CLAUDEAPIKEY_API_KEY`), separate from
   `litellm-provider-keys`. Both are loaded as pod env vars via the HelmRelease's
   `environmentSecrets` list.
2. Route each provider through LiteLLM's `anthropic/` provider with an `api_base`
   override — LiteLLM appends `/v1/messages`, which is exactly the endpoint both
   resellers implement. (Confirmed against the LiteLLM docs, not guessed.)
3. Expose a **curated** set of 11 routes — the Claude flagships per provider — suffixed
   `-oneprovider` / `-claudeapikey`, so the two can be compared head-to-head and never
   silently shadow the first-party routes. The resellers' full catalogues (≈60 and ≈35
   model ids, incl. GPT/Grok/Gemini/Kimi on OneProvider) are deliberately **not** exposed;
   adding one is a two-line change to `model_list` + the provisioner list.
4. Register every new route in the `litellm-key-provisioner` `DESIRED_MODELS` list so the
   existing virtual keys get whitelisted automatically.

**Separate secret, not merged into `litellm-provider-keys`:** a reseller key is far more
likely to need rotation (leak, ban, provider death) than a first-party key. Keeping it
isolated means rotating it never risks the core provider keys' ciphertext, and deleting
the whole experiment later is "drop one file + its three references".

## Consequences

**Positive**

- Head-to-head comparison of the same model across two resellers is one model-name suffix
  apart — both usable from every Hermes profile and Open WebUI once the provisioner runs.
- Zero plaintext in the public repo: keys are SOPS/age-encrypted, verified by round-trip
  checksum, never by rendering.
- The experiment is reversible and well-scoped: removing `litellm-grey-provider-keys.sops.yaml`,
  its `apps/kustomization.yaml` entry, the 11 `model_list` entries, the `environmentSecrets`
  line and the 11 provisioner entries fully reverts it.
- `GET /v1/usage` on both endpoints gives real balance numbers — usable for a future
  balance-monitoring job, unlike providers that only show usage in a web dashboard.

**Negative**

- **Trust boundary:** requests sent through these routes traverse an unknown third party
  that can read prompts and completions. They must never be used for anything sensitive —
  no credentials, no private repo content, no personal data. This is a hard rule, not a
  preference.
- **Reliability:** no SLA. A route can 500/429/timeout with no recourse, and the balance
  can evaporate without notice. Do not make these the default model for any profile or
  workflow that matters.
- Two more moving parts in `model_list`, and 11 more names to keep in sync between the
  HelmRelease and the provisioner ConfigMap.
- Spend through these routes is **not** tracked in LiteLLM's spend tables with correct
  pricing (unknown model ids), so LiteLLM-side cost figures for them are indicative only;
  the providers' own `/v1/usage` is the truth.

## Alternatives considered

1. **One shared secret merged into `litellm-provider-keys`.** Rejected: couples a volatile
   credential to stable ones; a reseller rotation would re-encrypt the whole core key file.
2. **Use the OpenAI-compatible `/v1/chat/completions` route instead of `anthropic/`.**
   Rejected: claudeapikey's OpenAI shim injects a large hidden system prompt (≈2000 prompt
   tokens for a 4-word reply) and returns a `reasoning_content` field — the Anthropic-native
   path is cleaner and gives accurate token counts.
3. **Expose the resellers' entire model catalogue.** Rejected: ≈95 model ids would flood
   the dropdown with duplicated, unverified routes; the point is to test Claude Opus 5.5,
   not to mirror someone else's aggregator.
4. **Test ad-hoc with `curl` only, no LiteLLM wiring.** Rejected: the Supreme Leader asked
   for them in LiteLLM, and GitOps-only means the wiring belongs in the repo, not in shell
   history.
5. **Skip the ADR** ("it's just two test keys"). Rejected: real money on a trust-unknown
   endpoint is exactly the kind of decision that needs a written blast radius.

## When to revisit

- Either provider's balance hits zero or `GET /v1/usage` starts reporting `isValid: false`
  — remove that provider's routes.
- A provider starts failing or timing out consistently — the grey routes have no fallback
  by design; remove rather than paper over.
- The keys are needed for anything beyond evaluation — this ADR's "never for sensitive
  content" rule would have to be revisited by the Supreme Leader explicitly.
- A first-party Claude route (or a vetted reseller) becomes available — retire the whole
  grey-zone block.
