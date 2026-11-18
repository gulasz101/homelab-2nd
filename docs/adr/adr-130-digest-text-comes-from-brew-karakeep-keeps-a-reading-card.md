# ADR-130: The digest text comes from Brew; Karakeep keeps a reading card

- **Status**: Accepted
- **Date**: 2026-11-10
- **Issue**: GUL-1183 (decided), recorded by GUL-1251
- **Related**: GUL-372 (the Morning Brew epic), GUL-1242 (the one-shot Job that converges the prompt), `apps/karakeep/`, `Projects/morning-brew/pipeline/brew.py`

## Context

Two systems can write the text a reader sees about a saved bookmark:

- **Karakeep** (`keep.voitech.dev`) summarises a bookmark with the local Gemma 12B behind
  LiteLLM and shows the result on the card. It also accepts **custom prompts** per user: rows in
  `customPrompts` (`text`, `appliesTo`, `enabled`, `userId`), managed in Settings → AI Settings.
- **The Morning Brew pipeline** (`brew.py`) already writes a daily digest from the same bookmarks,
  over the Karakeep REST API, into a structured record (`in_short`, `key_points`, `details`,
  `ideas[]`, `project_links[]`).

GUL-1183 asked whether one of them should be dropped: make Karakeep the only summariser, with a
custom prompt shaped to emit the digest. Three things were measured before deciding.

1. **The prompt template is hard-coded, not user-editable.** `packages/shared/prompts.ts` builds the
   request with `constructSummaryPrompt` / `constructTaggingPrompt`; a custom prompt is *appended*
   as extra bullets after the hard-coded instruction tail ("Summary must be in 3-4 sentences").
   A custom prompt that contradicts the tail wins only by being the last instruction the model
   reads. That is obedience, not a contract — a model swap or an upstream template tweak flips it.
2. **There is no output contract.** Karakeep asks for free text. No JSON schema
   (`INFERENCE_OUTPUT_SCHEMA=structured` applies to the tagger, not to the summary), no validation,
   no retry on a malformed answer, no notion of "which of these candidate links is the right one".
3. **It is slow, and it truncates.** A 12B local model took **~405 s per bookmark** for an article
   the Brew pipeline summarises in **11.9 s** through its own writer. A long `LINKS:` section was
   cut mid-URL at ~2.1k characters with no warning, because the response ceiling is invisible to the
   caller. The prompt/content budget at 8192 context is ~134 template tokens plus ~8,058 content
   tokens (≈ 32k characters) — generous for reading, irrelevant for a program.

## Decision

**Option (a). Two engines, two jobs, no overlap:**

- **Karakeep keeps a stock custom summary prompt** and uses it for one thing only: the human reading
  card on the bookmark page. It stays a *reading aid*, so free text is the right output.
- **`brew.py` owns the digest.** It calls the model itself with a structured prompt and validates
  what comes back. The Morning Brew text is never produced by Karakeep.
- **The custom prompt text lives in GitOps**, in a ConfigMap, and is converged into `customPrompts`
  by a one-shot Job over tRPC. Rows are keyed by user and live in the SQLite PVC, so a UI paste is
  a chore after every rebuild — and a rebuild we cannot automate is a rebuild that loses the text.

Machine consumers get machine output from a program that owns the schema; human readers get prose
from the thing that renders prose.

## Consequences

- The card prompt can be tuned freely for readability. Nothing downstream parses it, so there is no
  contract to break.
- Anything that needs fields (`ideas[]`, `project_links[]`, candidate-link filtering) goes through
  `brew.py`, not through Karakeep. The next agent that wants structured bookmark data must not
  reach for a custom prompt.
- Prompt changes are a Git commit, not a UI edit. The convergence Job overwrites what the UI holds;
  that is the point, and it must be said in the Job's docs so nobody "fixes" it by hand at 23:00.
- Two inference paths to keep healthy, both through LiteLLM. The 405 s figure is a cost we accept on
  the card path and refuse on the digest path.
- The digest's prompt and schema stay in one repo with the pipeline that validates them, which is
  also the repo whose failure is visible in the Brew's own logs.

## Alternatives considered

- **(b) Karakeep becomes the only summariser** — a custom prompt shaped to emit the digest JSON, and
  `brew.py` reads it off the bookmark. Rejected: the template is hard-coded, so the shape depends on
  the model obeying the last instruction; no schema validation, no retry, no candidate-link
  filtering; truncation at the response ceiling is silent; and 405 s per item makes a daily digest a
  35-minute job instead of a two-minute one.
- **(c) Fork Karakeep, or send an upstream prompt-template PR**, so templates are file-backed and a
  ConfigMap can mount them. Attractive shape — the `promptTemplates` tRPC endpoint is exactly our
  GitOps pattern — but rejected *for now*: we would own an image or wait on an upstream merge, and it
  fixes neither the latency nor the missing output contract. Revisit if upstream ships it.
- **(d) Paste the prompt in the UI and be done.** Rejected: per-user rows in the SQLite PVC are lost
  on the rebuild that the whole architecture assumes is routine. A manual step after every rebuild is
  not a design.

## When to revisit

- Upstream Karakeep ships structured/JSON output or file-backed per-user prompt templates — then (c)
  becomes cheap and the card path could carry a contract.
- Local inference drops under ~20 s per bookmark (faster hardware, smaller model, or batching) and one
  summariser is genuinely enough.
- The digest needs a field Karakeep already computes (its own tags, its own embeddings), and calling
  it twice starts to cost more than the split saves.
- A second consumer appears for bookmark prose. Two humans reading cards is the same job; two programs
  parsing the same free text is the start of a contract nobody wrote down.
