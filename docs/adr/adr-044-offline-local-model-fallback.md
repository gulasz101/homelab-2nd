# ADR-044: A local LM Studio model as the Hermes gateway's offline fallback

## Status

Accepted — 2026-10-10.

## Context

The Hermes agent that operates this homelab runs on the M1 Max MacBook Pro, but its **brain is in
the cluster**: `model.provider` is `llm.voitech.dev`, i.e. LiteLLM running as a k3s workload behind
a Cloudflare Tunnel. Every MCP server it uses is cluster-side too (`docs-mcp` on
`192.168.1.179:6280`, Itsaplan at `plan-api.voitech.dev`), and so is Mattermost.

The rack was scheduled to be physically moved and powered off (2026-10-10). The Mac stays up — it
is the only way to talk to the agent afterwards. But with the rack dark, the primary model
endpoint is a Cloudflare 502: the agent would be alive and **unable to think**, precisely when it
is needed to bring the rack back up. The gateway also had `fallback_providers: {}` — no fallback.

Two obvious non-answers:

- **A remote fallback** (OpenRouter, z.ai, …) needs working WAN + DNS. During this move the LAN's
  resolver *and* possibly the router go away, and it would put a paid credential on the critical
  path of a physical move.
- **No fallback** means the agent is dead exactly when it is the only tool available.

## Decision

Configure `fallback_providers` in the `andrzej` profile to a **local OpenAI-compatible endpoint**:

```yaml
fallback_providers:
  - provider: lmstudio
    model: qwen3.8-9b-heretic-uncensored-mtplx
    base_url: http://127.0.0.1:1234/v1
```

`lmstudio` is a first-class provider with that base URL built in, and `LM_API_KEY` (any non-empty
string; LM Studio does not enforce it locally) is already in the profile `.env`. Failover is
automatic and turn-scoped: any connection error, 429, or 5xx on the primary switches this turn's
requests to the local model and restores the primary on the next user message.

**Model choice was measured, not guessed.** Same ~9.8k-token prompt, same machine:

| Model | Wall clock | Answer |
|---|---|---|
| `qwen3.8-9b-heretic-uncensored-mtplx` | **61 s** | `READY` |
| `qwen3.8-27b-mlx` | 176 s | `""` — spent the whole completion budget in `reasoning_content` |

The 27B is the better model on paper (ADR-031 sanctioned it for scheduled jobs) but on a *cold,
long* agent prompt it is 3× slower and **returns empty content** — the reasoning-burn trap the
`local-ai-tooling-for-hermes` skill warns about, made worse by a prompt carrying the full skill
index. For an emergency brain, "slower and silent" is worse than "dumber and talking".

## Consequences

**Positive**

- The agent still answers when the homelab is off: no WAN, no DNS, no cluster required.
- Zero new secrets, zero new cost — `LM_API_KEY` was already present and is a local dummy.
- Failover is invisible when the cluster *is* up: it only fires on error, and the chain is
  restored per turn.

**Negative**

- Roughly **1 minute per turn** offline on a ~10k-token prompt, and longer once the full agent
  prompt (skills + memory) is in play. Emergency use, not daily driving.
- Correctness drops: a 9B distil is a much weaker tool-caller than the hosted primary.
- Depends on LM Studio running on the Mac with the model available. If it is not loaded, the first
  request pays a JIT cold-load.
- Agent startup offline still burns the MCP connect timeouts (~60 s each) before the first answer.
- Switching providers resets the prompt cache — expensive on a paid primary, irrelevant here.

## Alternatives considered

- **`qwen3.8-27b-mlx` as the fallback.** Rejected on measurement above (176 s, empty answer). Kept
  as the model for scheduled/unattended jobs, where quality beats latency and the prompt is small.
- **A remote provider (OpenRouter / z.ai) as the fallback.** Rejected: needs WAN + DNS, and the
  outage this exists for may include the router and the resolver.
- **Pointing the primary itself at LM Studio.** Rejected: the hosted primary is far stronger for
  daily homelab work; this is a resilience feature, not a migration.
- **A second local endpoint (llama.cpp managed provider).** Rejected for now: LM Studio is already
  running and warm on the same port.

## When to revisit

- If the Hermes host moves to (or gains) a second local runtime that is materially faster.
- If the primary is ever moved off the homelab — the whole "offline" premise changes.
- If offline turn latency above ~5 minutes makes the fallback useless in a real outage.
- If a smaller, more reliable local model with real tool-calling arrives (the 9B's reasoning-burn
  behaviour is a property of the Qwen3.8-Distill lineage, not of this quantisation).
