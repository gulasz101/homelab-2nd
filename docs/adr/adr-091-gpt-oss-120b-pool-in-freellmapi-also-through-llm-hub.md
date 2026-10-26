# ADR-091: The FreeLLMAPI gpt-oss-120b pool is also a LiteLLM route

- **Status**: Accepted
- **Date**: 2026-10-26
- **Issue**: GUL-184
- **Amends**: ADR-084, ADR-085

## Context

Hindsight's `reflect` and the background mental-model refresh need a model that
can call tools. FreeLLMAPI's virtual model `auto` ranks the enabled free models
by score and fails over on 429/5xx, but it does not rank by tool support, so it
could answer a reflect call with a member that has none. On 2026-10-22 that is
what the 240 failed async operations in GUL-143 came down to: reflect asked for a
tool-calling model and `auto` did not care.

GUL-182 fixed the Hindsight side by pinning reflect to the FreeLLMAPI **model
group** `gpt-oss-120b`. A group is a different object from `auto`: every member
serves the same model, so failover can change vendor but never the model.

That left the two ADRs behind the split contradicting each other:

- ADR-084 (2026-10-24), in *Alternatives considered*: "LiteLLM stays the
  gateway; FreeLLMAPI becomes one upstream behind it." (It sits in the rejected
  "more LiteLLM routes per free provider" option, but read plainly it says
  FreeLLMAPI is an upstream of LiteLLM.)
- ADR-085 (2026-10-24), *Decision*: "LiteLLM gets **no** routes to FreeLLMAPI.
  Cheap consumers call it directly."

One day apart, opposite answers to the same question. The owner spotted it and
ruled on 2026-10-26: *"freellmapi goes through llmhub, so now we are only adding
another routing in freellmapi which is also in llmhub but just pointing only to
gptoss120b"*.

## Decision

1. **The pool is the FreeLLMAPI model group `gpt-oss-120b`** — a bare model-group
   id, no `platform:` and no `auto:` prefix. Eight catalogue rows belong to it
   (live FreeLLMAPI SQLite, 2026-10-26): groq `openai/gpt-oss-120b` (key present),
   the custom `api.cerebras.ai` endpoint `gpt-oss-120b` (key present), cloudflare
   `@cf/openai/gpt-oss-120b`, ollama `gpt-oss:120b`, ovh `gpt-oss-120b`,
   electronhub `gpt-oss-120b` (no key yet), clod `GPT OSS 120B` (no key,
   tool calling: no) and dreamprompting `groq/openai/gpt-oss-120b` (no key,
   tool calling: no). A provider joins the pool by getting a key in FreeLLMAPI,
   not by editing a manifest, so the id never changes.
2. **Hindsight `reflect` and the background mental-model refresh call the pool
   directly, in-cluster.** Retain and consolidation stay on `auto`: they build
   memory rather than reason over it, and they do not need tools.
3. **LiteLLM carries the route `gpt-oss-120b-freellmapi`** pointing at the pool
   (`http://freellmapi.freellmapi.svc.cluster.local:3001/v1`), open to every
   provisioned virtual key. This is the "also through llm-hub" half of the ruling.
4. **Rule for any future FreeLLMAPI route in LiteLLM.** Allowed only when it is
   its own named route with the `-freellmapi` suffix, has no fallback of its own,
   and appears in no paid route's fallback chain. Paid chains still end at Ollama
   Cloud (ADR-085). FreeLLMAPI already fails over between providers, so the route
   sets `num_retries: 0` — a LiteLLM retry would stack on top of FreeLLMAPI's own
   failover and multiply the wait.
5. **No keys for `clod` or `dreamprompting` while this pool serves reflect.** Both
   declare no tool calling, so a key there would put a tool-less model behind a
   route that exists precisely to guarantee tool support.

## Consequences

**Positive**

- The ADR-084/085 contradiction is resolved with one rule instead of two stories:
  LiteLLM may carry FreeLLMAPI **as a named, free, chain-less route**, and nothing
  else. The "paid traffic never silently lands on a free model" promise from
  ADR-085 is untouched, because the route has no fallback and is in no chain.
- Any consumer that speaks only LiteLLM can now reach the pool. Hindsight can move
  through llm-hub later without a new key and without a new route.
- The pool widens by adding a key in FreeLLMAPI. LiteLLM, Hindsight and the
  provisioner never change again.

**Negative**

- Two paths to the same free pool now exist (Hindsight direct, everything else via
  LiteLLM). Whoever debugs a slow reflect call has one more hop to rule out.
- LiteLLM's per-key spend and request metrics now include free traffic, so a
  dashboard that sums "llm-hub requests" no longer means "paid requests".
- `provider-keys-revision` had to go from `"1"` to `"2"`: the pod reads provider
  keys only at start, so a key added to the Secret is invisible until the pod is
  rolled by hand.
- The pool is not as redundant as its eight rows suggest. On 2026-10-26 groq was
  the only healthy key, cerebras' free tier answers 402 `payment_required`, and
  the rest have no key, so "failover inside the group" is mostly theory.

## Alternatives considered

- **Route Hindsight through llm-hub instead of calling FreeLLMAPI directly.**
  Rejected for now. It adds a hop for the one consumer that is already working,
  and Hindsight exposes its own LLM metrics, so LiteLLM would not tell us anything
  new about those calls.
- **Put all of FreeLLMAPI `auto` behind LiteLLM as a set of `free-*` routes.**
  Out of scope. That is the design ADR-085 rejected, and the failure in GUL-143 was
  `auto` itself, not the reachability of one model.
- **Leave ADR-085 as it is and keep LiteLLM free of FreeLLMAPI.** Rejected by the
  owner on 2026-10-26. It would have left the contradiction in place and made the
  pool reachable only from inside Hindsight.

## When to revisit

- **Open question, recorded because nobody measured it:** we do not know whether
  FreeLLMAPI skips tool-less members when a request carries `tools`. If it does,
  rule 5 is a nicety; if it does not, rule 5 is the only thing standing between
  reflect and a model that cannot answer. Answer this before trusting reflect —
  and absolutely before adding a key for `clod` or `dreamprompting`.
- The pool gets a second healthy key: re-measure failover inside the group
  (GUL-182 measured 20/20 calls served by groq) and update the ADR-085 note that
  free traffic is unmetered.
- FreeLLMAPI grows per-key metrics: the metering argument for keeping it outside
  LiteLLM weakens, and the rest of the free tiers may follow this route (ADR-085's
  own revisit trigger).
- The route starts appearing in a paid chain in review: rule 4 is the thing to
  point at, and it is a deliberate re-decision, not a typo.
