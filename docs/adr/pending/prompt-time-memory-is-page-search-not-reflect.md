# ADR: Prompt-time memory is knowledge-page search, not reflect

- **Status**: Pending
- **Date**: 2026-11-03
- **Issue**: GUL-850
- **Related**: ADR-075 (the coding-agents plugin), ADR-106 (fleet billing), GUL-143 / GUL-791 (Hindsight health — untouched here)

## Context

The `@vectorize-io/hindsight-coding-agents` plugin (0.8.4) ran its `UserPromptSubmit` hook with
`autoInject: "reflect"` — the default. Every prompt therefore called `POST
/v1/default/banks/<bank>/reflect` inside a **20 s** client-side budget and, on timeout, fell back to
`GET …/knowledge-base/search` (page search), which is what the agent actually got.

Measured on 2026-11-03, 2026-10-20 → 2026-11-03 from `~/.hindsight/coding-agents-logs/`:

| observation | value |
| --- | --- |
| prompts where reflect timed out | **499** (pi 310, claude-code 140, opencode 49) |
| reflect succeeded inside 20 s | 148 → **23 % success** |
| wall clock wasted | ≈ 166 minutes of agent start-up |
| live `POST …/reflect?budget=low`, same bank | **75 s and 80 s** (two calls) |
| page search `GET …/knowledge-base/search` | **33–144 ms** (7 banks, 20 calls) |
| recall (`POST …/memories/recall`, observations) | 3–12 s |

The timeout is not a client bug that a bigger number fixes. Even the successful reflects averaged
18 s (p50) with p95 89 s in `llm_requests`, and an interactive coding prompt cannot spend 20 s
before the model starts. Worse, aborting the client request does not abort the work: the reflect
below was aborted at 20 s and the server kept going for another 27 s, finishing 7 LLM calls and
~160 k input tokens for an answer nobody received.

```
fbd12154  reflect_tool_call  success  05:18:52 → 05:18:53   3 628 in
fbd12154  reflect_tool_call  success  05:18:53 → 05:18:54  11 759 in
fbd12154  reflect_tool_call  success  05:18:54 → 05:18:55  17 731 in
fbd12154  reflect_tool_call  success  05:19:04 → 05:19:05  37 535 in
fbd12154  reflect          success  05:19:09 → 05:19:18  44 407 in / 2 106 out
fbd12154  reflect          success  05:19:18 → 05:19:27  41 151 in / 2 659 out
fbd12154  reflect          success  05:19:27 → 05:19:38   4 286 in / 4 115 out   (caller gone)
```

So each timed-out prompt paid twice: 20 s of wall clock and a full reflect on the prepaid balance.

## Decision

**Prompt-time recall is retrieval, not synthesis.** The host config
`~/.hindsight/coding-agent.json` (600, holds the fleet token, outside GitOps per ADR-075) carries
`"autoInject": "pages"`.

- The hook injects the top knowledge pages (title + snippet, limit 10) for the prompt — 33–280 ms,
  first prompt of a session; subsequent turns get the page roster and the tool guide only, as in
  every mode.
- `reflect` stays exactly where its latency is affordable: the **explicit** path — the
  `hindsight_reflect` MCP tool, `reflectToolTimeoutMs` 330 s, `budget: high`. An agent that decides
  it needs synthesis pays for it deliberately, and nobody waits for it at a prompt boundary.
- Nothing on the server changed: routes, models, budget knobs and the health work in GUL-143 /
  GUL-791 are untouched.

Measured A/B on the same repo, same binary, one synthetic `UserPromptSubmit` each:

```
autoInject: reflect   20.45 s   reflect_failed 20 014 ms → reflect_fallback_pages 53 ms
autoInject: pages      0.61 s   inject_pages 151 ms (5 pages, 7 262 chars injected)
```

and inside the real harnesses: `pi -p` 5.52 s total with `inject_pages` 65 ms (12 343 chars
injected); Claude Code `UserPromptSubmit` hook 279 ms.

## Consequences

- **20 s → under 0.3 s** at the prompt boundary, for every coding agent on the Air, and the page
  content injected is the same content the old fallback path produced anyway — what agents saw
  changes only in that half of them used to occasionally get a synthesis instead.
- The **prepaid DeepSeek balance stops paying for aborted reflects**: ~160 k input tokens per
  timed-out prompt, 499 of them in two weeks. ADR-112's watchdog sees a smaller draw, not a
  different route.
- Reflect's **quality lever is now opt-in**: a prompt no longer silently carries a 5–6 k char
  synthesis. The tool guide in the injected roster tells the agent to search pages first and to
  reflect when the question is genuinely architectural; whether agents actually call it is a
  behaviour question we can now measure without a 20 s tax on every prompt.
- The setting lives on one host, in a file git does not see. A plugin reinstall or a manual config
  rewrite can drop it silently — detect it with `grep autoInject ~/.hindsight/coding-agent.json`
  (a missing key means `reflect` and the 20 s are back). A backup of the pre-change file sits next
  to it as `coding-agent.json.bak-gul850-*`.

## Alternatives considered

- **Raise the hook's 20 s budget to reflect's p95 (90 s).** Rejected: it trades a 20 s timeout for
  a 20–90 s *successful* wait on every prompt. No interactive agent should block on a 3.6-call,
  40 k-token synthesis before it starts thinking.
- **Make the server's reflect path fast enough for a prompt boundary.** Rejected as the fix *here*:
  it needs a materially faster model or a shorter tool loop, which is a route/quality decision
  (ADR-075's reflect lane, LiteLLM `hindsight-reflect`) and a different ticket. A 20 s budget on a
  route whose p50 is 18 s is a coin flip either way.
- **`autoInject: "recall"` (observations, no LLM).** Rejected on measurement: 3–12 s — over the
  hook's 7 s `injectTimeoutMs` on the homelab-2nd bank, and still a visible delay on every first
  prompt. It is the right knob for a small, observation-heavy bank, not for this fleet.
- **Turn reflect off entirely.** Rejected: the synthesis is genuinely better for "why did we do
  this" questions. Keeping it on the explicit tool path preserves it at zero prompt cost.

## When to revisit

- If reflect p50 drops under ~3 s end-to-end (faster model, fewer tool iterations), prompt-time
  synthesis becomes affordable again and `autoInject: reflect` deserves a re-measure.
- If agents demonstrably never call `hindsight_reflect`, the tool path is decoration and this
  becomes "reflect is for humans in the control plane".
- If the plugin ships a background/prefetch mode that fills the prompt from a prior synthesis,
  prefer that over both options — it removes the trade-off instead of choosing a side.
