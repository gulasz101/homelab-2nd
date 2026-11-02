# ADR-106: The whole agent fleet runs on `deepseek-v4.1-flash-1017-ds` (DeepSeek's own API) while subscription quotas are walled

- **Status**: Accepted — **amended 2026-11-02**: the fleet is back on `deepseek-v4.1-flash-1017-ollama` (see "Amendment 2026-11-02" at the end; the `-ds` decision below still describes *why* the `-ds` route exists and when to go back to it)
- **Date**: 2026-10-29
- **Issue**: GUL (record filed from Mattermost, agent-fleet repoint)
- **Amends**: ADR-085 (paid subscriptions only), ADR-069 (Go fallback), ADR-094 (paid Ollama route for reflect)
- **Depends on**: ADR-105 (the `-ds` route family itself, added to LiteLLM the same day)
- **Related**: GUL-581 (previous fleet move)

## Context

Every model the fleet used came from one of two weekly subscriptions: **OpenCode Go**
(`*-go` routes, `https://opencode.ai/zen/go/v1`) and **Ollama Pro** (`*-ollama` routes,
`https://ollama.com/v1`). LiteLLM in front, one virtual key per consumer.

On 2026-10-29 both walls arrived: the Go weekly quota was already exhausted, and the Ollama
Pro token allowance was nearly gone. Every Hermes profile and every Paperclip runner sat on
one of those two families, so the next run would have died on a 429 — in the middle of the
Paperclip issue sweep, not at a convenient moment.

Probing the Go route with a real key during this work showed the second problem: a request
for `qwen3.8-flash-go` came back with `model: deepseek-v4.1-flash` in the response body. The
route was **silently substituting** — the caller thinks it is on Qwen, the bill and the
behaviour say otherwise. A quota wall you can see is better than a model swap you cannot.

The proxy already carried a route that spends a **third, independent** budget: the DeepSeek
platform API (`deepseek/deepseek-flash`, `DEEPSEEK_API_KEY`, 1M in / 393k out), published as
`deepseek-v4.1-flash-1017-ds`. Pay-per-token, no weekly allowance, no silent substitution.

## Decision

`deepseek-v4.1-flash-1017-ds` becomes the **default model for every Hermes profile** (default
profile / Bill Cipher, andrzej, florian, matejko, szarik, zdzislaw) and for every Paperclip
runner whose model is set in `adapterConfig` (Builder, Majster, Reviewer, Verifier, Tester,
OpenCode, Pi). The standalone OpenCode CLI is pinned to `llmhub/deepseek-v4.1-flash-1017-ds`
as both `model` and `small_model`. The `pi` catalog gains a matching entry with
`reasoning: false`.

Two exclusions, deliberate:

- **Claude Code** (`claude_local`, `claude-opus-5-5`) is untouched. It spends the Anthropic
  subscription, not a LiteLLM quota; repointing it would break the only reviewer that is paid
  from a different pocket.
- **Fallback chains** keep their Ollama hop plus the FreeLLMAPI last resort. The primary is
  what had to move.

## Consequences

- The fleet keeps working with zero subscription allowance, at pay-per-token prices. Cost is
  now proportional to usage instead of capped by an allowance — that is the trade: an agent
  fleet that stalls at a random hour versus a bill that scales.
- One family everywhere means **correlated blind spots**: the Reviewer and the Builder now
  come from the same model. Review quality loss here is real and accepted for the duration of
  the quota wall (the previous split family was `glm-5.3-ollama`, which is out of budget).
- A single vendor is now a single point of failure for the whole fleet. The FreeLLMAPI
  fallback is the only route that does not depend on DeepSeek's balance.
- `pi` runs with `reasoning: false` on this entry: the route does not declare
  `reasoning_effort`, and `pi` sends it whenever the catalog says `reasoning: true` — that
  combination is a hard `400 UnsupportedParamsError`, not a retry.
- The OpenCode CLI needs the model **enumerated** in `~/.config/opencode/opencode.json`
  under `provider.llmhub.models`. Setting `model` to an unlisted id fails with an opaque
  `UnknownError` from the local server, which reads like a proxy fault.

## Alternatives

- **Stay on Ollama until it runs dry**: rejected — the wall arrives mid-run, and a Paperclip
  run that dies at minute 40 leaves an issue parked with no comment.
- **FreeLLMAPI as primary**: rejected — measured in ADR-094 at 1 success in 54 calls under
  load. Fine as a last resort, useless as a fleet default.
- **Local MLX routes (`qwen3.8-27b-mlx` on the Air, `.119:1234`)**: free and unlimited, but
  ~27B on a laptop against a 25k-token agent prompt is a latency problem, and the Air is also
  the Hermes host. Kept as a fallback idea, not a default.
- **Wait for the weekly reset and do nothing**: rejected — two days of dead agents.

## When to revisit

- The Go or Ollama allowance resets and the cost per run on DeepSeek is worse than the
  subscription to date.
- The DeepSeek balance itself gets low: at that point the fleet has no paid route left and
  the answer is FreeLLMAPI-primary plus a smaller default model, which is a different ADR.
- Review quality measurably drops with Builder and Reviewer on one family — then split the
  reviewer onto a genuinely different paid route rather than a different name for the same
  weights.

## Amendment 2026-11-02 — the fleet moved back to `-ollama`

**Decision.** On 2026-11-02 at 01:20 UTC (02:20 CET) the whole fleet moved from
`deepseek-v4.1-flash-1017-ds` back to `deepseek-v4.1-flash-1017-ollama`: the six Hermes
profiles (default / Bill Cipher plus `andrzej`, `florian`, `matejko`, `szarik`, `zdzislaw`),
the seven Paperclip runners (Builder, Majster, Reviewer, Verifier, Tester, Pi, OpenCode), and
the standalone OpenCode CLI's `model` + `small_model`. **15 values across 14 surfaces**, one
script, one log. Claude Code stays on `claude-opus-5-5` for the ADR-106 reason: it spends the
Anthropic subscription, not this relay.

**Why.** Cost. `-ds` is pay-per-token against a prepaid DeepSeek balance; `-ollama` spends the
Ollama Pro weekly allowance that is already paid for. The `-ds` route existed because both
subscription families were walled on 2026-10-29; that wall is a weekly condition, so the right
answer on 2026-11-02 was to move back rather than keep buying tokens for work the subscription
covers. This is the "When to revisit" trigger one paragraph above, firing on schedule.

**Two trade-offs, accepted knowingly.**

- **Context: 128k, not 1M.** `-ds` served 1M in; `-ollama` serves 128k. Today's agent prompts
  sit around 25k, so nothing is broken now. The first place this bites is a *long Pi session* —
  a factory run that keeps reading diffs and never compacts can cross 128k and fail on the
  request rather than on the task. If a Pi run starts dying with a context-length error, that
  is this, not a bug in the issue.
- **No fallback chain on the Paperclip runners.** Their model is a single value in
  `adapterConfig.model`; Hermes profiles have a `fallback_providers` chain, the runners have
  nothing. If the Ollama route gets rate-limited mid-week the seven runners fail outright —
  they do not degrade to another route, they stop. The recovery is a human running the escape
  hatch below, which is why it is a script in the repo and not a paragraph of instructions.

**Escape hatch (installed, tested, one command).** On the Air:

```bash
sudo /usr/local/libexec/homelab/repin-fleet-model.sh --to-ds      # undo: back to the paid API
sudo /usr/local/libexec/homelab/repin-fleet-model.sh --to-ollama  # forward: probes the route first
sudo /usr/local/libexec/homelab/repin-fleet-model.sh --dry-run    # plan only
```

`--to-ds` never probes and never waits: it is the escape hatch, and an escape hatch that
refuses to run because a *paid* route looks unwell is not an escape hatch. `--to-ollama` probes
first and exits `2` if the route is walled, leaving the fleet where it was. Exit `1` means a
partial move — the fleet is split across two billing models; read the log, do not re-run blind.
Log and last outcome: `~/Library/Logs/homelab/repin-fleet-model.log` and
`…/repin-fleet-model.status.json` (ADR-108: the script runs from the repo's `host/paperclip-air/bin`).

**Two tooling gotchas, both found by running the script rather than reading it.**

- **PyYAML is not installed on the Air.** Neither `/usr/bin/python3` (Apple's) nor the Homebrew
  `python3` can `import yaml`, so the `python3 -c 'import yaml; yaml.safe_load(...)'` validation
  the `hermes` skill documents fails on a perfectly good edit — and a check that cannot tell
  "no parser" from "bad file" silently blocks the change. The script tries PyYAML, then falls
  back to macOS ruby's psych (`/usr/bin/ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]))'`),
  and reports a missing parser as a missing parser. Flagged in the skill; do not trust a
  PyYAML command on this host, check the parser first.
- **`python3 -c`, never `python3 - <<EOF`, when filtering a piped listing.** A heredoc *is*
  stdin, so it shadows the pipe: `… | python3 - <<'PY'` reads the script, not the JSON, and the
  filter silently returns nothing — a "no agents matched" answer that looks like an API problem.
  Pass the data as `argv`, or keep the filter on `-c`.

**Cleanup finding: the one-shot did not clean up after itself.** The scheduled job's last act
was meant to boot itself out and delete its plist and wrapper. It ran as `UserName: paperclip`
while the plist (root:wheel, 0644) and the wrapper (root:wheel, 0755) are root-owned, so the
`rm` failed with `Permission denied`, logged to `repin-fleet-model.launchd.log` while the job
still exited 0 — a tidy-looking success with the landmine still installed. Removal is manual and
needs sudo (GUL-782). The plist's own comment also says the
`StartCalendarInterval` recurs monthly; with a `Month` *and* `Day` key launchd matches that
calendar date once a year, so the next fire would have been 2027-11-02, not 2026-12-02 — the
self-delete mattered less than the comment assumed, and it never worked anyway.
