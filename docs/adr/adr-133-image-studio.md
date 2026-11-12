# ADR-133: Image Studio — one designer agent, three engines behind one queue, verdicts in Paperclip

- **Status**: Accepted
- **Date**: 2026-11-12
- **Issue**: GUL-29 (written under GUL-1397, after the P7a cleanup in GUL-1392)
- **Related**: ADR-123 (nano banana as the third engine), ADR-107 (system LaunchDaemons on the Air)

## Context

Image Studio is the homelab's picture pipeline: it renders the headers, diagrams and cards the
blog and the agents need, and it grew up as a set of scripts on two Macs with a Mattermost
progress channel bolted on. By the end of 2026 it had three engines, four copies of its own skill,
590+ renders in a queue file and no written record of what it is. Every agent could in principle
render, so every agent kept its own half-updated copy of the instructions.

The P7 cleanup (GUL-29) collapsed that: one skill, one owner, one queue, one review surface.
This ADR records the shape it settled into, so the next change starts from a described system
rather than from a directory listing.

Two hosts are involved and neither is the cluster. The **Air** (`paperclip`, 192.168.1.191) runs
Hermes, the agents and the backlog. The **M1 Max** (`m1max`, 192.168.1.119) has the GPUs and the
models and does the actual rendering, reached over the LAN SSH key. Nothing about Image Studio
runs in k3s, and that is deliberate (see Consequences).

## Decision

1. **Matejko is the only agent that makes images.** Matejko is a Paperclip agent with the
   `designer` role in the Image Studio project. Any other agent that needs a picture files a
   Paperclip issue, in the Image Studio project, assigned to Matejko, with the brief in the
   description — it does not render, and it does not hold a copy of the skill. The skill is
   installed in `~/.hermes/profiles/matejko/skills/image-studio/` and in no other profile.

2. **Three engines, one queue.** Ideogram 4 is the main engine (structured JSON prompts, the
   default for anything that ships). FLUX.2-klein renders fast text-prompt drafts at four steps.
   nano banana goes through the Gemini web proxy and is recorded in ADR-123 — not repeated here.
   All three submit through the same wrapper into the same queue
   (`~/image-studio/backlog/queue.json`, driven by `studio/backlog/backlog.py`), so a post's
   round, its attempts and its verdict are one record regardless of which engine made the pixels.
   The render lane holds six jobs at a time, so a batch is one post plus its re-render arcs.

3. **`imagegen` submits over SSH; there is no service and no port.** The wrapper is a stdlib-only
   client that runs on the Air and drives the renderer's CLI in `~/git/ideogram4-local` on the
   M1 Max. The commands, as the repo and the skill state them:

   ```
   studio/imagegen.py submit --prompt-json prompts/my-scene.json --name my-scene -W 1216 -H 832
   studio/imagegen.py status <job-id>
   studio/imagegen.py fetch <job-id> [--dest DIR]
   ```

   and for the drafts and the proxy engine, `imagegen submit --engine flux2-klein --prompt "…" --json`
   / `imagegen submit --engine nanobanana --prompt "…" --name header`. `IMAGEGEN_HOST` defaults
   to the SSH alias `m1max` and `IMAGEGEN_REMOTE_DIR` to `git/ideogram4-local`; both are
   overridable per call, and nothing else about the renderer is addressed directly.

4. **The review loop lives in Paperclip.** A round produces one verdict card: a
   `request_item_verdicts` interaction on a card issue in the Image Studio project, one item per
   image, each item carrying the PNG as an attachment. The owner answers `approved`, `rejected` or
   `deferred` per item; nothing is auto-approved and no agent closes a slot on its own reading.
   A post may take several rounds, and a round is only closed when every carded item has a
   verdict. The mechanics are `skill/references/verdict-and-round-mechanics.md` and the procedure
   is `skill/references/backlog-review.md` — the ADR fixes the shape, the skill holds the detail.

5. **Every render gets a record in the vault, rejected ones included.** One file per render at
   `3-resources/image-library/<YYYY-MM>/<YYYY-MM-DD>-<stem>--<job_id>.md`, with the job's own
   timestamps, the prompt, and the verdict. A rejected render keeps its record with
   `asset_present: false` and lands nowhere else — the library is the history of what was tried,
   not a gallery of what shipped. Approved images are also copied to
   `tech_blog/assets/<YYYY-MM-DD>/<slug>.png` for the post that embeds them.
   `3-resources/image-library/index.md` is regenerated from the renderer's `jobs.db` by
   `studio/library_backfill.py`, which never overwrites an existing record. As of this ADR the
   library holds 1,292 record files across five months. Format: `skill/references/library-records.md`.

6. **One canonical skill.** `skill/` in `gulasz101/ideogram4-local` (version 4.10.2) is the only
   copy. P7a deleted the stale root-level `SKILL.md` and `references/` (1.4.0 behind) and collapsed
   the per-agent copies, so a lesson learned in a round has one place to land and no second copy
   to drift. The references are split by topic because a single file hit the tool's size ceiling;
   that is a mechanical limit, not a design goal.

7. **The Mattermost path is retired.** P7a (commit `c48e357`, PR #8) removed `post_status.sh`,
   `notify_progress.py`, the `ideogram4-progress-watchdog` cron entries, the `mattermost-*.md`
   references and the watchdog prose in `SKILL.md`. Paperclip replaced them: cards, comments and
   interaction results are the status channel, and the only watcher left is the heartbeat that
   wakes an agent on an assigned issue. The deliberate leftovers are the prompt files
   `prompts/post2-mattermost-header.json` and `prompts/post2-breakglass-sql.json`, which still
   describe the Mattermost logo as an image subject — a picture of a header, not a delivery path.

## Consequences

Easier: one owner to ask for an image, one queue to inspect, one skill to fix, one place where a
verdict is recorded. The library is complete — a rejected render is a documented attempt rather
than a lost afternoon — and every approved image can be traced back from the post to the job id
that produced it.

Harder: an image request now waits for Matejko, so a busy or stopped agent stalls the whole
pipeline, and the queue is a JSON file on one Mac with no API in front of it — its state is only
visible to whoever reads that file. Rendering depends on the M1 Max being awake and reachable over
the LAN; when it is off, submissions fail rather than degrade, and there is no second render host.
Nothing here is observable in the cluster's sense: there are no Prometheus metrics, no Loki logs
and no alerts for Image Studio, so a silent stall shows up as a missing card rather than an alert.

Durability: the skill is in Git and rebuildable. The vault (records, index, approved assets) and
`~/image-studio/` (queue, cards, briefs, handoffs, audit) live on the Air outside Git, and the
renderer's `jobs.db` on the M1 Max is the origin of every record — the backup for all three is
restic to OMV MinIO, decided separately (GUL-1393). Lose the Air's disk without that backup and the
library's history is gone even though every image that shipped is still in the vault copy of the
post.

## Alternatives considered

- **Let every agent render, each with its own skill copy.** This is the state P7a ended: four
  copies, three versions behind each other, and no single answer to "how do we render". One owner
  costs queueing latency and buys a system that can be reasoned about.
- **Run the renderer in k3s.** The cluster has no usable GPU for these models (Maxwell `sm_52`,
  ADR-003) and the M1 Max already has the models, the seeds and the job database. Moving it would
  rebuild the storage path for a workload that wants a desktop GPU.
- **Keep Mattermost as the status channel.** It duplicated what Paperclip already knew, needed a
  watchdog cron to speak, and put progress in a channel nobody could answer. Retired in P7a.
- **Approve by comment instead of by card.** A comment names a file in prose; a card binds the
  verdict to the attachment id. The second one cannot approve a picture nobody was shown.

## When to revisit

- The M1 Max stops being the render host, or rendering needs to survive it being off.
- A second agent needs to render, which breaks point 1 and the single-queue assumption with it.
- `queue.json` outgrows a file read by one script per round.
- The Gemini web proxy behind nano banana disappears (ADR-123's own revisit clause).
