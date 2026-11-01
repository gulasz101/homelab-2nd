# ADR-112: The memory watchdog guards the prepaid balance of the provider the fleet actually uses

- **Status**: Accepted
- **Date**: 2026-10-30
- **Renumbered**: 109 → 112 when this landed on `main`; ADR-109 is the Cloudflare Access token
  decision, and ADR-111 is exactly the rule that says the number is allocated at adoption.
- **Issue**: GUL-620 (`openrouter-unreadable` every hour since before 2026-10-29)
- **Supersedes**: the balance half of ADR-080's check list and H2-306's "OpenRouter is the
  silent-failure risk" reading
- **Depends on**: ADR-085 (paid subscriptions only, OpenRouter left LiteLLM), ADR-106 (the fleet
  runs on DeepSeek's own API), ADR-108 (the watchdog script lives in this repo)
- **Related**: GUL-112 / GUL-114 (the OpenRouter credit exhaustion that started this whole thread)

## Context

The memory watchdog's check 8 watched **OpenRouter's** credit balance and alerted when it fell
below `OPENROUTER_FLOOR_USD`. The reason was real at the time: Hindsight retain and consolidation
ran on paid OpenRouter credit, and at zero balance every agent's *live* memory write failed
silently (H2-306, GUL-112/114).

By the time anyone looked at it, that check had been alerting `openrouter-unreadable` every hour
and nobody had read it for a day, because it was also being suppressed hourly. Two independent
faults:

1. **The header was the literal string `Authorization: Bearer ***`.** A redaction, made while
   writing a tracking note, was committed into the script. With a real key that call is a 401.
2. **There was no key to send at all.** OpenRouter left LiteLLM on 2026-10-24 (GUL-123 /
   ADR-085) and the `OPENROUTER_API_KEY` field is gone from `llm-hub/litellm-provider-keys`.
   The jsonpath returns an empty string, so the pipeline could never have worked regardless of
   the header.

So the guard against fleet-wide silent memory failure had been reporting a *false* fault, which
is worse than reporting nothing: it trained the reader to ignore the one alert that names the
condition it exists for. Meanwhile the balance that can actually kill the fleet moved to
**DeepSeek's platform API** on 2026-10-29 (ADR-106) — the same day the `-ds` family became the
default for every Hermes profile and every Paperclip runner. Nothing watched it.

## Decision

Check 8 becomes a **provider balance guard over a fixed table of providers**, one row each:

| provider     | credential (in `llm-hub/litellm-provider-keys`) | endpoint                              |
|--------------|--------------------------------------------------|---------------------------------------|
| `deepseek`   | `DEEPSEEK_API_KEY`                               | `https://api.deepseek.com/user/balance` |
| `openrouter` | `OPENROUTER_API_KEY`                             | `https://openrouter.ai/api/v1/credits`  |

- DeepSeek is **the guarded balance**: it is the route every agent session and every Hindsight
  call now spends. Floor `DEEPSEEK_FLOOR_USD`, default 5.
- OpenRouter stays in the table and **auto-skips** when the secret has no key for it:
  `check8 openrouter=skipped:no-key-in-llm-hub/litellm-provider-keys`. No alert. Re-adding the
  credential arms the check again with no code change.
- A **missing key is never "unreadable"**. `unreadable` is reserved for a live provider whose
  balance the watchdog could not read — that is a fault in the watcher, and it alerts once a day.
- The key is read on `homelab-2nd` from the Kubernetes secret, used in `Authorization: Bearer
  $KEY` inside the remote shell, and `unset`. Only the remaining USD crosses the wire; the key
  never appears in the script, the log, or an alert.
- The HTTP call is `curl -sf`, so a 4xx/5xx is a read failure, not a `0.00` balance presented as
  a real number — the old pipeline piped the error body straight into the parser.

## Consequences

- The fleet has a real budget alarm again, on the bill that can actually stop it. First reading
  after the fix: `check8 deepseek_remaining_usd=7.22`. It is also load-bearing already: measured
  while this was being fixed the balance went $7.27 → $7.19 in under five minutes of a busy
  Paperclip morning (~$1/h), so the $5 floor is roughly two hours of that pace away, not weeks.
  Pay-per-token is cheap per call; a fleet of hourly agents is not.
- One more place that fails if the secret is renamed: renamed keys now surface as `nokey`
  (silent) rather than `unreadable` (loud). The log line names the namespace and secret it
  looked in, so the cause is one grep away.
- The provider table is code, not configuration. Adding a third provider is a three-line patch,
  deliberately: a balance guard that is configured from a file the guard cannot read is how we
  got here.
- OpenRouter can be re-armed by whoever holds the credential, without touching this repo.
- Alert conditions are renamed (`deepseek-low`, `deepseek-unreadable`). The old
  `openrouter-unreadable` entries stay in `watchdog-alerts.state` as history and expire on
  their own.

## Alternatives considered

- **Re-add an OpenRouter key so the original AC reads a number.** Rejected: nothing spends
  OpenRouter credit any more, so the number would be a museum exhibit, and the guard would still
  not cover the balance that can stop the fleet. It also needs a credential from the owner to
  satisfy a check that protects nothing.
- **Delete check 8.** Rejected: the risk it was built for is real and simply moved provider.
  Deleting it would leave the fleet with no budget alarm at all.
- **Alert on `nokey` too.** Rejected: a retired route is not an incident. It would reproduce
  exactly the false-alarm pattern that made this issue invisible for a day.
- **Trust `is_available` from DeepSeek's response instead of a dollar floor.** Rejected as the
  only signal: it flips only at exactly zero, which is the moment memory writes start failing.
  The floor is the point.

## When to revisit

- When the fleet's default model moves off DeepSeek (quota walls end, Ollama Pro balance returns,
  a new provider wins on price). The guarded provider follows the default model, every time.
- If DeepSeek introduces a spend cap or a subscription that makes a prepaid balance meaningless.
- If a second provider becomes load-bearing *in parallel* rather than as a fallback: the table
  then needs a floor per provider and one alert that names the cheapest rescue route.
