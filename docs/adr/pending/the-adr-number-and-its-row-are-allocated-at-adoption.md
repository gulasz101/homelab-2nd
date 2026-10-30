# The ADR number and its index row are allocated at adoption, never by the branch that writes the ADR

- **Status**: Pending
- **Date**: 2026-10-29
- **Issue**: GUL-582
- **Related**: ADR-093 (the owner keeps the merge button), ADR-098 (the tick reads the merge), GUL-553 (PR #87, the pull request that paid the bill)

## Context

Measured on 2026-10-29 on a single work order (GUL-553, PR #87):

- four re-syncs with `main` in eight hours, each one a branch merge, a full
  `scripts/check.sh` run and a re-run of the `check` status, because the
  `protect-main` ruleset sets `strict_required_status_checks_policy: true` and
  therefore only lets an up-to-date head merge;
- three ADR number collisions in the same day: PR #86, #91 and #93/#94 each
  filed an ADR row while #87 waited, so the work order renumbered from 098 to
  099 to 101;
- in all four merges **the only conflicting hunk was the `docs/adr/README.md`
  index row**. The code of that work order never conflicted once.

The same disease was visible again when this ADR was written: `main` carried
ADR-100, and five open PRs had already claimed 101 (three separate PRs), 102
and 103.

The cause is not review quality and not the ruleset. It is two single-writer
resources being written by every concurrent branch:

1. **the number**, a global sequence a branch cannot see the siblings of; and
2. **the index row**, one line in one file that every ADR-bearing PR appends to.

A branch that allocates either of them before the merge is guessing about work
it cannot see. The price of that guess is a full agent run per foreign merge per
waiting PR — bookkeeping, not engineering.

A factory work order is not the writer here: `never-paths.json` blocks
`newFilesUnder: docs/adr/`, so an ADR is always written by some other agent run
(Majster, the watchdog, a direct request). That is precisely why the rule has to
live in the directory and its gate rather than in one agent's brief: the writers
are many and none of them sees the others.

## Decision

An ADR is **written without a number**, and the number is allocated when the ADR
is **adopted** — a separate, single-writer step that happens after the merge.

1. The run that writes an ADR puts it at `docs/adr/pending/<slug>.md` and touches
   no other file:

   ```
   # <title>

   - **Status**: Pending
   - **Date**: <the day the decision was made>
   - **Issue**: GUL-NNN

   ## Context        ## Decision        ## Consequences
   ## Alternatives considered             ## When to revisit
   ```

   No number in the filename, none in the H1, and **no edit to
   `docs/adr/README.md` at all**. A pending ADR carries the same five sections
   as a numbered one, because an ADR is finished when it is written, not when it
   is numbered.

2. `bash scripts/adr-adopt.sh` (dry run) / `--apply` adopts every pending file,
   in filename order: number = highest existing `docs/adr/adr-NNN-*.md` + 1,
   rename to `adr-NNN-<slug>.md`, H1 becomes `# ADR-NNN: <title>`,
   `**Status**` becomes `Accepted`, and the row is appended to the end of the
   index table with the file's own date. One script, no judgement.

3. Adoption is not a special privilege and needs no ruleset change: any run that
   can open a PR runs the script and opens one PR titled
   `docs(adr): adopt N pending ADR(s)`. Several adoptions batch into that one
   PR, whose diff is a rename and one row per ADR.

4. `docs/adr/tests/adr-check.sh` (and therefore `scripts/check.sh`) accepts
   pending files — right H1 shape, no number, the five sections — and prints
   them as a `note` with their count. Numbered files keep every existing rule.
   A pending ADR is never a `check` failure: the decision is already recorded,
   and refusing the PR over bookkeeping is the failure this ADR removes.

5. Until it is adopted, an ADR is referenced by its slug
   (`docs/adr/pending/<slug>.md`), not by a number. Nothing in the repo may
   cite a number that does not exist in the index.

This ADR is written pending, like every ADR after it — the PR that introduces
the mechanism uses it. Its own history is the last piece of evidence: it was
first written as ADR-104, the next number free across `main` and the open PRs,
because the mechanism did not exist yet. While it waited for its merge, ADR-105,
106, 107, 108 and 109 landed on `main` and the branch stopped merging cleanly —
on the index row, again. It is now `pending/` like any other.

### Deviation from the option 1 sketch in GUL-582

The issue proposed writing `adr-NNN-pending-<slug>.md` with the row under a
`## Unreleased` heading. The number goes away, but **the row is still an edit to
`docs/adr/README.md`** — the one file every ADR-bearing PR touches, and the only
thing that conflicted in all four merges measured. Keeping the row keeps the
conflict. So a pending ADR has no row at all; the row is created at adoption,
by the single writer.

## Consequences

- An ADR-bearing branch touches exactly one new file, so two ADRs written on
  the same day no longer conflict, do not need a re-sync with `main`,
  and do not re-run `check` per foreign merge. That is roughly one agent run
  saved per foreign merge per waiting PR — four in eight hours on GUL-553.
- Numbers stay unique by construction: they are allocated from the tree by one
  writer, and never reused: a number, once printed, keeps its meaning forever.
- The decision is readable immediately at a predictable path; nothing about the
  ADR waits for the index.
- An ADR can stay unnumbered for as long as nobody runs the adoption. The gate's
  `note` is the reminder and the queue is visible in the directory listing; it
  is deliberately not a red `check`.
- The adoption PR still edits `README.md`, so two adoption PRs racing can
  conflict — on one five-line diff that is regenerated by re-running the script,
  not on a whole branch that has to be renumbered and re-checked.
- A pending ADR's date is the day the decision was made, not the day it was
  adopted. That is the more useful of the two and it keeps adoption mechanical.

## Alternatives considered

- **Option 2 in the issue: drop "require branches to be up to date".** Cheaper
  per merge, but it does not remove the measured conflict: when two PRs append a
  row to the same table, GitHub refuses the second merge whatever the up-to-date
  rule says, so the re-sync came back anyway. It also weakens the guarantee for
  semantic conflicts in code, which was never the problem. Revisit **after** this
  ADR lands: once ADR PRs stop touching a shared file, a behind branch can
  usually merge, and dropping strict up-to-date becomes a cheap extra win.
- **Option 3: do nothing, write the cost down.** Honest, and the cost is one
  agent run per foreign merge per waiting PR. That was four runs in eight hours
  for one branch that produced one ADR and no code.
- **Generate `README.md` from the ADR files and commit it.** Still a shared file
  rewritten by every ADR PR, so the same collision — now in a generated file,
  where a hand-merge can silently diverge from the generator.
- **Keep the number in the branch and let the owner fix the row at merge
  time.** The owner's merge button would become a manual rebase plus renumber,
  which is exactly the work this ADR moves to a script.
- **Take the number from a Paperclip counter instead of the tree.** The
  sequence would live where nobody can inspect it from git, and the index row
  would still collide.

## When to revisit

- If ADR volume and PR concurrency both fall to the point where collisions stop
  for a month, the mechanism still costs one small PR per batch — keep it, but
  stop counting the saving.
- If pending ADRs routinely sit for more than a day, run the adoption in the
  same hourly tick that already reads merges (ADR-098) and let it open the PR
  without waiting for the next PR that happens to be opened.
- If GitHub's merge queue becomes usable for a one-person repo with these
  checks, re-measure: allocation could move back into the branch and the pending
  directory could go.
- If a branch ever needs to cite an ADR number that does not exist yet
  (a cross-repo reference before the merge), revisit rule 5 rather than adding a
  reservation file.
