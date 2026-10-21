---
name: deadline-bound-task-scope
description: "Use when a run has a hard wall-clock budget (Paperclip issue run, cron, any timed task) and the work could drift into investigation."
version: 1.0.0
author: Andrzej
license: MIT
metadata:
  hermes:
    tags: [paperclip, scope, time-budget, video, notes, research]
    related_skills: [paperclip, paperclip-chat-intake]
---

# Deadline-bound task scope

A run with a wall-clock limit is not a research session. When the budget is known, the
**deliverable comes first** and curiosity is rationed.

## The failure this prevents

On 2026-10-21, Paperclip issue [GUL-67](/GUL/issues/GUL-67) asked for a YouTube video to be
transcribed, reduced to key facts, and filed as a PARA note. The run had a 1800 s ceiling
(`effectiveTimeoutSec: 1800`, `timeoutSource: "config"`).

- The caption track downloaded at **t+20 s**; a clean 463-line transcript existed at **t+47 s**.
- At **t+322 s** the run decided to *verify a quantitative claim from the video* ("roughly 52
  billion potential vaults") and started brute-forcing combinatorics.
- It used the **wrong model**: self-avoiding walks (no cell revisits) instead of "any pattern
  opens a vault" (an ordered sequence, repeats allowed — trivial: `cells^L`).
- Six scripts were written, patched and re-run. Two `terminal` calls alone consumed ~1390 s.
  The last one, `timeout 500 python3 pattern_total.py`, was still running when the ceiling
  killed the run.
- The run died at 15:02:44 with **no PARA note in the vault**. Paperclip then parked the issue
  `blocked` with `replay: "not_authorized"`, so the good transcript was never picked up.
- A manual re-run at 16:32 repeated the pattern and was interrupted by the user.

**The transcript was ready in 47 seconds. The note never existed.**

## Rules

1. **Deliver the requested artifact before investigating anything.** The request names an
   artifact ("a PARA note", "a summary", "a PR"). Write it first, with what you already have.
   Investigate only what the artifact needs.
2. **Content is not evidence.** A number, a statistic or a claim *inside* a video, article or
   post is material to report, not a fact to prove. Write "the founder claims ~52 billion" and
   move on. If a claim materially changes the deliverable's accuracy, note it as unverified.
3. **Cap verification explicitly.** If you do verify something, give it a hard cap (a couple of
   minutes) and say so in your own reasoning before you start. A `timeout 550` around a
   computation you already suspect is too big is not a cap — it is a bet.
4. **Check your model before your compute.** "What is the actual number of X?" is usually
   `cells^L` or `combinations(...)`. If you find yourself memoising a *visited-set* or a
   *permutation*, check whether the real problem is closed-form. Reaching for brute force first
   is what burns the budget.
5. **Reuse what a previous run already produced.** A prior run's artefacts (transcripts,
   downloads, caches in `~/.hermes/cache/scratch/`) are the cheapest possible input. Look before
   you download, and look before you write a script.
6. **Budget the run, don't just respect it.** Divide the wall clock up front: fetch, transform,
   deliver, verify. If a step threatens the budget, cut the *step*, not the deliverable.
7. **When a run is resumed after a timeout, the previous work is the starting point.** Do not
   restart the pipeline from zero.

## Deadlines are often config, not law

Before assuming a budget is fixed, check the run record. In Paperclip:

```bash
curl -s "$PAPERCLIP_API_URL/api/issues/{issueId}/runs" -H "Authorization: Bearer $PAPERCLIP_API_KEY" \
  | jq '.[].resultJson'
# { "stopReason": "timeout", "timeoutSource": "config", "effectiveTimeoutSec": 1800 }
```

`timeoutSource: "config"` means a human set it and a human can raise it. If the task genuinely
needs longer, say so and request a bigger budget — do not silently burn the ceiling and fail.

## Where the per-run log actually is

`~/.hermes/logs/agent.log` only carries turns the gateway ran **in a named profile**. A run
owned by the root/`default` profile (e.g. Bill Cipher) lands in the Paperclip per-run NDJSON:

```bash
~/.paperclip/instances/default/data/run-logs/<companyId>/<agentId>/<runId>.ndjson
```

Each line is `{seq, stream, chunk, ts, attemptId}`. Tool calls appear as
`event=tool.started data={... "tool":"terminal","preview":"..."}` — the `preview` is the command.
Build a timeline from it (`timestamp` minus run start) to see exactly where the budget went.

## Where the line to draw is

The `youtube-video-to-para-note` skill has a "verify frames with a LOCAL VLM" step. That is
fine — it is verification of *the deliverable's own content*, on a bounded input (one video's
frames), with a known cost. It is not the same as going off to independently verify a market
claim the video makes about the world. A skill that encourages verification must also state a
budget, or a deadline-bound run will spend its whole life verifying.
