# Factory work-order contract (GUL-436, ADR-093)

This file is the law for `agents/factory/factory.py`. A script, not a model,
decides whether a factory stage passed. Everything the script reads and prints
is defined here. If code and this file disagree, the code is wrong.

Design rules:

- Python 3 standard library only, run as `python3 -I agents/factory/factory.py <subcommand>`.
  JSON, not YAML: the system `python3` on the Air and in CI has no PyYAML.
- **The script runs from a checkout of `main`, never from the work order's checkout**
  (GUL-502, ADR-096). `agents/factory/factory-run.sh` — installed as
  `~/.local/bin/factory` and `/Users/paperclip/factory/bin/factory` — force-moves the
  tooling checkout `/Users/paperclip/factory/tooling` to `refs/remotes/origin/main` on
  every call and executes the copy there. `start`, `decide` and `tick` are therefore
  always the code on `main`: a stage check fixed and merged today decides today, and no
  stage ever decides on a client frozen at the spec's `baseSha`. The work order's own
  checkout (`ledger.cwd`) still runs the checks, because every check diffs its working
  tree and the commits on its branch — it is data to the script, not the script. A
  refresh that fails (no network, dirty tooling copy) is a setup error, exit 2: running
  a stale copy silently is exactly the bug the wrapper removes. `start` refuses a
  `cwd` equal to the tooling checkout, because a branch cut there would be moved off it
  by the next call.
- `git` is called through `subprocess` with an argument list, never through a
  shell string. The one deliberate exception: AC `check` commands (point 2),
  which are defined as shell commands and run with `bash -c` from the repo
  root — a work order is human-approved text, and the spec author is on the
  hook for its checks.
- No stage check talks to Paperclip. Network use in `lint-spec`/`check-*`/
  `commit`/`open-pr` is only `gh`, only inside `check-gate` and `open-pr`. The
  `gh` binary comes from env `FACTORY_GH` (default `gh`) so tests can stub it.
  `check-gate` additionally reads the live cluster with `kubectl` (and parses
  YAML with `yq`) for the chart-pin check in point 7: that is a read of the k3s
  API on the LAN, never Paperclip, and both binaries live on the Air.
- Since GUL-439 the three orchestration subcommands — `start`, `decide`, `tick`
  — do talk to Paperclip, and only through `pc.py` next to this file (stdlib
  `urllib`). They never `git push` themselves and never read the board token
  file (GUL-297); auth is `PAPERCLIP_API_KEY` and `PAPERCLIP_RUN_ID` from the
  environment or the subcommand exits 2. Since GUL-553 `tick` also reads `gh pr
  view` — one read-only call per work order waiting on a merge, through the same
  `FACTORY_GH` binary.
  `PAPERCLIP_API_URL` is the base; when that base answers like the edge
  (Cloudflare 1010, or nothing at all) the client falls back once to
  `PAPERCLIP_API_FALLBACK_URL` (default `http://127.0.0.1:3100/api`) and stays
  there for the rest of the run (GUL-496).
- Output: every subcommand prints exactly one JSON line on stdout
  (`{"ok": true|false, "check": "<name>", "reasons": [...]"}` plus the fields
  named per subcommand) and a short human summary on stderr.
  Exit codes: 0 = pass, 1 = the stage did not pass, 2 = usage or setup error
  (the check itself could not be trusted — a spec file unreadable, a check
  command that errored outside its protocol, `git`/`gh` refusing to run).

## 1. The spec

A work order's spec is the Paperclip document `spec` on the work-order issue:
markdown for people, plus **exactly one** fenced `json` block that the script
reads. The fenced block is delimited by ``` at line start, info string exactly
`json`. Zero or two-plus such blocks are a lint failure.

```json
{"repo": "gulasz101/homelab-2nd", "base": "main",
 "kind": "docs|tests|manifest|code|agent-rules",
 "allowedPaths": ["apps/foo/**", "docs/foo.md"],
 "acs": [{"id": "AC-1", "text": "one sentence", "check": "bash apps/foo/tests/foo-check.sh"}],
 "maxDiffLines": 400}
```

Fields (all required, no extra keys anywhere — unknown keys are a lint
failure so a typo cannot silently widen or narrow a gate):

| Field | Rule |
|---|---|
| `repo` | `OWNER/REPO`, one slash, both halves non-empty |
| `base` | non-empty string, the base branch name |
| `kind` | one of `docs`, `tests`, `manifest`, `code`, `agent-rules` |
| `allowedPaths` | list, ≥1 entry, each a non-empty glob (see glob rules) |
| `acs` | list, ≥1 entry, each exactly `{id, text, check}` |
| `maxDiffLines` | integer > 0 |
| `liveChecks` | optional; list, each exactly `{id, check}`: `id` is `LIVE-<n>` (unique), `check` one single-line command. The engine runs them from the repo root at the merge commit after Flux reports Ready (ENGINE.md, deploy_check); exit 0 = pass |
| `builderTestPaths` | optional (GUL-2204); list of >=1 exact repo-relative files (no glob, no `..`). Each must be a test path inside `allowedPaths`, and no AC `check` may name it. Green (and the Builder's guard) may change these files; red may not; every other test path stays frozen after red. Use it when the fix lives in a check script under `tests/`. `lint-spec` also refuses a spec whose `allowedPaths` are all test paths and that has no `builderTestPaths`: green could never change anything |

AC rules:

- `id` matches `AC-<n>` (`^AC-[0-9]+$`, no leading zeros), unique within the spec.
- `text` is one sentence for people; the script only requires it non-empty.
- `check` is exactly one command: non-empty, one line (no embedded newline).
  It runs with `bash -c` from the repo root. Several ACs may share one check
  by repeating the identical `check` string — the script then runs that
  command once for all of them.
- `check` must be able to **report**, or `lint-spec` refuses the spec (GUL-853).
  A command that prints no `AC-<n>: PASS|FAIL` line is a setup error in every
  stage: `check-red` answers `setup error: no AC line for AC-n`, the Tester
  cannot fix it, and the work order escalates without a single red run that
  could ever pass. So a check must either name every AC id it covers —
  `sh -c 'if test -f apps/a.txt; then echo "AC-1: PASS"; else echo "AC-1: FAIL missing"; exit 1; fi'`
  — or be a delegation to a script that does:
  `bash apps/api/tests/static-serving-check.sh` (`bash`, `sh`, `dash`, `zsh`,
  `python3`, `node`, `deno`, `bun`, `tsx` + optional flags + a path ending
  `.sh|.bash|.py|.js|.mjs|.cjs|.ts|.mts`). Anything else — a bare `test`/`grep`
  chain, `npx <tool> validate`, `bash -c '<something>'` — is refused with a
  reason naming the fix.
  **Do not use `test -f x && echo "AC-1: PASS" || echo "AC-1: FAIL x"`**: when
  the test fails that line prints FAIL and exits **0**, and point 2 makes
  "exit 0 with a FAIL line" a setup error — a different silence. The `if …
  then … else … exit 1; fi` shape is the one that satisfies both halves.
  This rule is static and lint-only: bash cannot be proven to print from its
  text, so the lint rejects the shapes that structurally cannot rather than
  claiming to prove the ones that can. `check-red` (which must see `FAIL`) and
  `check-green` (which must see `PASS`) are still the proof. `load_spec`, and
  therefore `check-red|green|gate|findings|verdicts|commit|open-pr`, do not
  apply this rule — a spec that slips past lint is still judged by its checks.

### Glob rules (`allowedPaths`, never-path globs)

Patterns match repo-relative POSIX paths. Translated to regex:

- `**/` matches zero or more leading path segments (`**/x` matches `x`, `a/x`, `a/b/x`);
- a trailing `/**` matches everything below (`apps/foo/**` matches `apps/foo/a/b` but not `apps/foo` itself);
- `**` elsewhere matches any characters including `/`;
- `*` matches within one segment (no `/`); `?` matches one non-`/` character;
- everything else is literal. Matching is case-sensitive.

## 2. AC check protocol

A check prints one line per AC it covers:

```
AC-<n>: PASS
AC-<n>: FAIL <reason>
```

- Exit 0 = every AC it covers passes. Exit 1 = at least one covered AC FAILs.
- A line for an AC the command was not assigned to, a missing `AC-` line for a
  covered AC, a contradiction (exit 0 with a FAIL line, exit 1 with only PASS
  lines), a forbidden exit code (anything but 0/1), or a check command the
  spec never names — all of these are a **setup error**, never a PASS/FAIL.
  A setup error makes the calling subcommand exit 2.
- `PASS`/`FAIL` parsing is case-sensitive; anything else on stdout is ignored.
  Stderr of a check passes through to the subcommand's stderr for debugging.

## 3. Findings (Reviewer output, document `findings`)

Markdown with exactly one fenced `json` block, same fence rule as the spec:
a list, possibly empty (empty list = no findings). Each element is exactly:

```json
{"id": "F-1", "file": "path", "line": 12, "severity": "blocking|minor", "claim": "one sentence"}
```

- `id` matches `^F-[0-9]+$`, unique; `file` is a non-empty repo-relative path;
  `line` is an integer ≥ 1; `claim` non-empty.

## 4. Verdicts (Verifier output, document `verdicts`)

One fenced `json` block, a list of exactly:

```json
{"id": "F-1", "verdict": "confirmed|rejected|unproven", "evidence": "the command run and the output line, or file:line"}
```

- ids unique, `evidence` non-empty. Every finding gets exactly one verdict;
  no extra ids.

## 5. Never paths (`agents/factory/never-paths.json`)

ADR-093 decision 6. A changed path matching any rule below can never be
touched by a factory work order; no gate waives it. Shapes:

- `globs`: paths matching (glob rules above) are never paths, any status.
- `newFilesUnder`: path prefixes; a **newly added** file under one is a never
  path (edits of existing files are not). This is `docs/adr/` — a new ADR is
  Wojtek's.
- Content rules on changed YAML/JSON text files (any indent, line start `kind:`):
  - `forbiddenKinds`: `Secret`, `Cluster`, `ScheduledBackup`, `PersistentVolumeClaim`
    (CNPG clusters/backups, PVCs);
  - `forbiddenSopsKey`: a file whose new version has a root-level `sops:` map is
    SOPS-encrypted — never path ("anything SOPS-encrypted").
  Files whose new version does not exist (deleted) are judged on their text in
  the base commit. The tunnel manifests are covered by
  `**/cloudflared-*.yaml` and `**/*tunnel*` (tokens, configmaps, namespaces).

## 6. Diff and path classification

"The diff from SHA to the working tree" always means the union of:

- `git diff --name-status <SHA>` (committed + staged + unstaged vs the SHA),
- `git ls-files --others --exclude-standard` (untracked, .gitignored excluded).

Rename entries count both sides as touched. Statuses: `A` = added (new),
`M` = modified, `D` = deleted, `R` = renamed.

**Test paths** use exactly `looksLikeTestPath` in
`agents/factory-guard/policy.ts`: a path segment `tests` or `test` (case
insensitive) that is not the last segment, or a basename matching
`.test.<ext>`, `_test.<ext>`, or `test_*.py`. `factory.py` reimplements it and
`agents/factory/tests/` runs both implementations over ≥20 sample paths and
asserts they agree — a drift fails CI.

## 7. Subcommands

Every subcommand prints the one JSON line + stderr summary, exits 0/1/2.

| Subcommand | Passes (exit 0) when |
|---|---|
| `lint-spec --spec FILE` | the spec follows point 1 (block found & parseable; a broken/unparseable JSON block is a lint **failure**, exit 1; an unreadable FILE is exit 2), including the reporting rule for every `check` |
| `check-red --repo DIR --base SHA --spec FILE` | the diff SHA→worktree touches only test paths, all inside `allowedPaths`; every AC's check runs and reports `AC-n: FAIL`; no setup errors |
| `check-green --repo DIR --red SHA --spec FILE` | every test path is byte-identical to the red commit (worktree contents; a new untracked test path is a violation); every changed path is inside `allowedPaths`; every AC reports `PASS`; if the repo has `scripts/check.sh`, it runs (`bash scripts/check.sh`, repo root) and must exit 0. **Main's own work is not stage work (GUL-1801):** for each touched path, when the stage's diff red→worktree for that path is identical to `git diff <red> origin/main -- <path>` (same status, same content), it came from `main` and is dropped before the `allowedPaths` check and before the test-path byte comparison; the JSON lists those paths under `fromMain`. A path the stage really changed still fails, and a test path main touched while the stage also changed it fails too |
| `check-findings --repo DIR --base SHA --findings FILE` | findings follow point 3; every `file` is in the diff SHA→worktree; every `line` exists in the new version (file readable, ≥ `line` lines) |
| `check-verdicts --findings FILE --verdicts FILE` | points 3 + 4; every finding has exactly one verdict, no extra ids. JSON adds `"blockingConfirmed": ["F-…"]` = blocking findings with verdict `confirmed`, and `"blockingFindings"`: the same findings in order, each as `{id, file, line, claim, evidence}` (evidence = the verifier's own words). The ids are for logic; the detail is for the fix-round brief, so the next round does not have to go and find it (GUL-1929) |
| `check-gate --pr OWNER/REPO#N --spec FILE` | the check run named `check` on the PR head commit has state SUCCESS; no changed path is a never path (globs, newFilesUnder, content rules on each changed YAML's new-version text at head); `additions + deletions ≤ 3 × maxDiffLines` (between 1× and 3× the gate still passes and the JSON carries `"sizeNote": "size note: N lines > maxDiffLines M"`; only above 3× is it a failure, GUL-1730); every HelmRelease the PR changes pins a chart version at or above the one the cluster runs (ADR-097, below). On a pass it takes the PR out of draft (`gh pr ready`), so a passing gate is what makes a PR mergeable (GUL-1801) |
| `commit --repo DIR --stage red\|green --issue GUL-N` | stages all changes and commits `factory(GUL-N): <stage>` + trailer `Co-Authored-By: Paperclip <noreply@paperclip.ing>`; refuses (exit 1) **before staging** when the change set breaks the stage scope: `red` = every touched path is a test path, `green` = no touched path is a test path. JSON adds `"sha": "<new commit sha>"`. The change set = point-6 diff vs HEAD (unborn HEAD: untracked files only). A second run on a clean tree whose HEAD is already `factory(GUL-N): <stage>` is not an error: it passes and returns that HEAD sha, so a `decide` that died after its commit can be re-run (GUL-497) |
| `push --repo DIR --issue GUL-N` | pushes the checkout's branch to origin (`git push -u origin <branch>`, never `--force`); refuses (exit 1) on `main`/`master`. JSON adds `"branch"` and `"sha"`. Used by `decide` when the PR already exists, so a later round's commit reaches the PR head (GUL-1267 F-1) |
| `open-pr --repo DIR --issue GUL-N --title T [--ready]` | current branch is not `main`/`master` (refuse, exit 1); `git push -u origin <branch>` (never `--force`); `gh pr create` with body linking the work order: `Work order: [GUL-N](https://paperclip.voitech.dev/GUL/issues/GUL-N)`. Creates the PR **as a draft** — the draft is the guard that stops a merge landing a round the factory has not passed, because the merge card is only raised after the gate and the gate marks it ready (GUL-1801). `--ready` creates a normal PR for a caller that already knows the round is over. JSON adds `"url": "<PR url>"` and `"draft": true|false`. Repo comes from `git remote get-url origin` |
| `start GUL-N [--dry-run\|--recut]` | point 9 below |
| `decide GUL-M [--apply]` | point 9 below |
| `tick` | point 9 below |

`--pr OWNER/REPO#N` splits on the last `#`.

A PR between 1× and 3× `maxDiffLines` passes with one line of honesty instead of a
block (GUL-1730): `decide` prepends that `size note: N lines > maxDiffLines M` to
the gate stage comment **and** to the work order's `in_review` comment, where the
merge is decided. A cap that stopped a green, reviewed, verified PR over 59 lines
(GUL-1597: 559 against 500, the PM raised the spec by hand) bought nothing and
cost a morning; a PR nobody could review in one sitting is still a hard stop.

### `check-gate` gh calls (exact, so a stub can serve them)

1. `gh pr view <N> --repo OWNER/REPO --json headRefOid,baseRefOid,additions,deletions,files`
2. `gh pr checks <N> --repo OWNER/REPO --json name,state`
3. for every changed path ending `.yaml`/`.yml`:
   `gh api "/repos/OWNER/REPO/contents/<path>?ref=<headRefOid>"` (JSON, base64 `content`)

A missing `check` run, a non-SUCCESS state, or a gh call that errors/returns
unparseable output → not a pass (gh errors are setup errors, exit 2).

### `check-gate` local check: chart pin vs cluster (GUL-552, ADR-097)

A chart pin is a floor as well as a ceiling: `17.0.0` merged while the cluster
ran `17.3.0` downgraded Open WebUI into an unusable database. So when the PR
changes a HelmRelease document (column-0 `kind: HelmRelease` at head, test paths
and never-path globs excluded), the gate also runs, from the tooling checkout:

```
bash scripts/helmrelease-pin-vs-cluster.sh <base-sha> <pr-head-ref>
```

- The script owns the judgement and the wording; it is also the documented way
  for a human to run the same check by hand on an ordinary PR (ADR-097).
- `check-gate` fetches the PR head into `refs/factory/pr-N` and the base tip
  before calling it, because the tooling checkout only carries `main`. A head
  that does not resolve to the sha `gh pr view` reported is a setup error, not
  a pass: a stale ref would diff the wrong commits.
- Exit 0 → no reason added. Exit 1 → each `FAIL …` line on stdout becomes one
  gate reason. Anything else (2 = cluster unreachable, no `kubectl`/`yq`,
  unreadable YAML, unknown ref) is a **setup error, exit 2** — the check never
  passes when it could not read the cluster.
- It is not part of `scripts/check.sh`: CI has no cluster access. The gate runs
  on the Air, which has `kubectl` and `yq`. `FACTORY_GATE_REPO` points the check
  at another checkout (the self-test uses it with a `kubectl` stub).

## 8. Exit-code recap

| Code | Meaning |
|---|---|
| 0 | stage passed |
| 1 | stage did not pass (a real violation, or a refused operation) |
| 2 | usage/setup error: inputs unreadable, git/gh broken, check protocol violated |

## 9. `start`, `decide`, `tick` — the script drives Paperclip (GUL-439)

A **work order** is an issue with a `spec` document (point 1), assigned to
Majster, open in its project. Stage issues are its **children** — they inherit
its execution workspace and a finished child wakes Majster, not the PM.

`agents/factory/agents.json` holds Majster's id, the stage agent ids and the
`--factory-role` each stage needs; `agents/factory/templates/<stage>.md` holds
the stage briefs (`red`, `green`, `review`, `verify`, `gate`). Templates are
self-contained: a stage agent may not be able to read the work order. The four
stage briefs (`red`, `green`, `review`, `verify`) end with both hand-off payloads
— the full `executionPolicy` on the first hand-off, `status` + `comment` only on a
stage that already carries a `changes_requested` decision (GUL-471). The hand-off
is always the last call of the run: it reassigns the issue and Paperclip cancels
the sending run, so the stage report rides in its `comment` and nothing may follow
it (GUL-472). `gate.md` ends with the one `decide` command instead: the gate has no
review stage to hand off to.

**`start GUL-N [--dry-run]`**

1. Refuses (exit 1) when `~/paperclip-agents/majster/factory/STOP` exists
   (`FACTORY_STOP` overrides). Runs `lint-spec` on the spec; a bad spec is exit 1.
2. Refuses while another work order is open in the same project — the shared
   checkout cannot hold two diffs (ADR-095). A work order parked as `blocked`
   before it ever started holds no branch and no checkout, so it does not count;
   one that already carries a `ledger` does, because its diff may be the one in
   the checkout (GUL-951). Without that split, a work order waiting on another
   deadlocks the project for good. One exception: a ledger whose `outcome` is
   `escalate` is parked on a **person's** decision, not on the checkout, and does
   not count either (GUL-1888). Counting it froze a whole project for a night
   twice — GUL-1599 (cleared by hand in GUL-1811) and GUL-1749 (GUL-1886) — while
   the escalated order waited for a review that could not happen until morning.
   `--dry-run` plans and creates nothing.
   Before the refusal returns, the work order is **parked itself** (GUL-1730):
   one PATCH sets `status: blocked` with `blockedByIssueIds` = the open work
   orders that actually hold the checkout, plus one comment naming them. That
   blocker edge is the whole mechanism — Paperclip emits
   `issue.blockers_resolved` when the last one closes and Majster wakes, so
   nobody sets the edge by hand (GUL-1597 needed it twice in one morning, and the
   first time had no wake path at all). Exit 1 and the `start` JSON line stay.
   Two cases are never parked that way: `--dry-run` (writes nothing at all) and a
   work order whose ledger already has `stages` (it has started, so its diff may
   be the one in the checkout — parking it would hide a half-cut ledger behind a
   block).
3. Takes the shared checkout back from a parked work order (GUL-1888). An
   escalated order is left with its diff still in the working tree, so letting the
   next order in blindly would carry those hunks onto the next order's branch,
   silently, under the wrong issue. When the checkout is dirty **and** the checked
   out branch is the one an escalated ledger records in this `cwd`, `start`
   commits the diff as `wip(<N>): parked diff kept on escalation` on that branch,
   pushes `<branch>:<branch>`, and only then checks out `base` — the diff is where
   it belongs and nothing is lost. A push that fails is exit 1 with nothing thrown
   away. Dirt on any other branch is still the operator's: untouched, and refused
   by the dirty check below. The `start` JSON then carries
   `cleared: {issue, branch, sha}` and the work order's comment says it took the
   checkout back from which order.
4. Cuts the work order's own branch, which is what `open-pr` needs: runs
   `git fetch origin`, refuses (exit 1) when `git status --porcelain` is not empty,
   resolves `baseSha` = `origin/<spec.base>` and runs
   `git switch -c gul-<N>-<slug> <baseSha>` — or switches to that branch when it
   already exists at that sha. `--dry-run` does none of it.
5. Records in the work order's `ledger` document: `baseSha` (= `origin/<spec.base>`),
   `branch` = `gul-<N>-<slug>`, `cwd`.
6. Creates 5 children: `[red]` → Tester, `[green]` → Builder, `[review]` →
   Reviewer, `[verify]` → Verifier, `[gate]` → Majster. The first is `todo`, each
   later one `blocked` by the one before. Red/green/review/verify carry
   `executionPolicy {"stages": [{"type": "review", "participants": [{"type": "agent",
   "agentId": Majster}]}]}`.
7. `start` twice creates nothing the second time (the ledger has the stages).

**`start GUL-N --recut`** (GUL-1455) — moves a misfiled work order: one whose
stages were cut against a checkout the spec's repo does not resolve to any more
(GUL-1340's chain was cut in an `ideogram4-local` checkout because that project
came first; `work_order_cwd` then answered a different cwd for the same spec).
It re-cuts the chain in the repo the spec names, without ever discarding work:

1. Refuses (exit 1, nothing written) unless every stage in the ledger has
   `sha: null` and the ledger has neither `pr` nor `merge` — a re-cut must never
   throw away pushed work. The refusal names the stages that committed.
2. Refuses when the ledger already carries `recut` and no stage has committed
   since: the chain on the board *is* the re-cut, so a second run would only
   supersede it with itself. Recover a half-finished re-cut by starting again
   from the ledger that has no `recut` note (the archive keeps it).
3. Archives the old ledger **verbatim** to
   `var/<WO>-ledger-<UTC stamp>.json` (next to `factory.py`; `FACTORY_VAR`
   overrides), and records that path in the new ledger.
4. Cancels the superseded stage issues **before** minting anything, each with the
   issue's own `executionPolicy` re-sent with its stage `id`s stripped: a bare
   `{"status": "cancelled"}` is dissolved by the server, which re-arms the stage
   agent (measured on GUL-1381 — `cancelled` went in, `in_progress` with a fresh
   run came back). Every cancel is read back; one that is still live stops the
   re-cut before the new stages exist.
5. Refuses when every stage it holds is already cancelled or gone: nothing is
   left to supersede.
6. Re-mints the five stages from the spec on the same code path `start` uses,
   cwd and base resolution included, then writes the ledger.

**Ledger** — markdown with one fenced `json` block on the work order:
`{version, workOrder, workOrderId, title, repo, base, baseSha, cwd, branch,
projectId, stages: {<stage or stage:rN>: {issueId, identifier, round, attempts,
sha}}, fixRounds, pr: {number, url} | null, outcome, escalated,
recut: {at, archive, previousCwd, previousBranch, previousBaseSha,
superseded: [{stage, issue, status}]} | absent}`. Only `factory.py`
writes it, and every write carries the document's `latestRevisionId` as
`baseRevisionId` — Paperclip answers `409 Document update requires
baseRevisionId` without it (GUL-496). A 409 on the write means a concurrent
writer: the client re-reads the revision and retries once.

**`decide GUL-M [--apply]`** — M is the stage issue; the stage comes from its
`[stage]`/`[stage rN]` title. Runs the check for that stage against the spec and
the ledger (`check-red`, `check-green` with the red sha, `check-findings`,
`check-verdicts`, `check-gate` with the ledger's PR).

- **A settled merge is `already settled` only if it landed (GUL-1801).** When the
  ledger has a merge record and the PR's merge commit does not contain the work
  order's branch head, `decide` answers `ok: false`, decision `unlanded`, naming the
  head sha and the one action — *land `<head>` on main, then re-run* — and parks the
  work order `blocked`. It never answers `already settled` for work that is not on
  main (GUL-1598's round 2 died behind that sentence). An `unlanded` record is not
  terminal either: the next `decide` re-reads the PR (or, if the head reached main
  another way, settles it from `main`).
- Pass → `commit`/`open-pr` where the stage calls for it, then **the ledger write,
  and only then** `PATCH {"status": "done", "comment": …}`. The order is part of
  the contract (GUL-497): a stage marked `done` whose ledger write then fails
  never runs again — the board looks fine, the ledger keeps `sha: null`, and the
  next stage refuses with *no red commit recorded in the ledger*. So a failed
  write exits 2 as a setup error and leaves the stage `in_progress` with its
  work already in git; the same `decide` is re-runnable because `commit` hands
  back HEAD for this stage and a recorded `pr` is reused instead of opening a
  second PR. A reused PR is **pushed, not skipped**: round 1 opened it and
  pushed then, and a later round commits on the same branch, so the green pass
  of a fix round runs `push` and records the sha on the PR head in `pr.head`
  (GUL-1267 F-1). Without that push the gate would read the round-1 head, pass
  round-1 code and re-arm its merge monitor on a head nobody re-reviewed. Side effects that are not the record — the green stage's work
  product, the gate's merge monitor and the work order's `in_review` — run after
  the `done` PATCH. Request-changes writes the ledger before its `in_progress` PATCH
  for the same reason: the `attempts` counter that escalates on the third
  failure lives there.
- Fail → `PATCH {"status": "in_progress", "comment": …}` (request changes;
  Paperclip routes it back to the stage agent). The comment is the check's JSON
  line plus the last 60 lines of its output.
- verify with a non-empty `blockingConfirmed` → approve it and open a fix round
  (`[green r2]` → `[review r2]` → `[verify r2]` → `[gate r2]`, chained the same
  way), confirmed findings pasted into the fix issue, and the gate recorded in
  the ledger as `gate:r2`. At most 2 fix rounds. Opening the round **supersedes
  the previous round's gate**: that gate issue is cancelled with a comment naming
  the new round, and the work order's merge monitor is cleared in a policy-only
  PATCH (`{"executionPolicy": null}`, no `status`), so no live offer to merge a
  head the fix round is rewriting is left behind (GUL-1267 G3). The round's green
  stage then commits **and pushes** that commit to the branch of the round-1 PR
  (`pr.head`), so `check-gate` in gate r2 reads the fixed head and not round 1's
  (GUL-1267 F-1). A gate that runs while a later round is still open is a
  **setup error** (exit 2) naming the open
  stage and the round it is superseded by, and it writes nothing: no ledger, no
  stage PATCH, no comment (GUL-1267 G1). The same ledger still decides once every
  later-round stage is `done` or `cancelled`.
  **The green brief of a fix round carries the findings themselves** (GUL-1929):
  the round's `green` description gets a `findingsBlock` listing every confirmed
  blocking finding as `id`, `file:line`, the `claim` and the verifier's
  `evidence`, plus the identifier of the verify issue the detail came from. Ids
  alone are not a brief — GUL-1922's green r2 spent its whole 40-turn cap
  re-deriving three findings out of another issue's document and committed
  nothing. Claim and evidence are collapsed to one line and capped at 400
  characters each so a rambling finding cannot break the description, and when
  the check output carries no detail the block falls back to the ids plus the
  issue name.
- **latest gate round**: because a fix round carries a gate of its own, "the gate
  stage" is whichever `gate` / `gate:rN` row has the highest round, and every
  reader uses that one. The round-1 `gate` row is the latest gate round only
  while no fix round has opened.
- gate pass → **no card** (GUL-553). The work order goes `in_review` with a
  comment that names the PR and says merge it on GitHub, plus an issue monitor
  (`executionPolicy.monitor`: `kind: external_service` — the only accepted value —
  `serviceName: github pull request`, `nextCheckAt` as `YYYY-MM-DDTHH:MM:SSZ` (the
  API rejects an ISO `+00:00` offset with a 422), `maxAttempts` 72). The server
  redacts `externalRef` before storing it, so the PR number rides in `notes` and
  the link is the green stage's `pull_request` work product. That monitor is what
  makes `in_review` a real wait; the old `request_confirmation` card merged
  nothing and only looked like a button. Wojtek merges on GitHub, `tick --apply`
  notices it.
- **A failed gate escalates at once** (GUL-1706). The gate has no fix round and
  its agent can change nothing: the PR already exists, and re-running the same
  check on the same head yields the same verdict. So one `request_changes` on the
  `gate` stage goes straight to **Escalate** (below) with the check's own reasons
  plus "the gate has no fix round: a failed gate goes to the PM's 05:30 review,
  never back to the stage" (GUL-1730: a never-path hit still says Wojtek). Counting to three handed the stage to an agent that could only repeat
  itself and left the work order `in_progress` with no card, no blocker edge and
  nobody woken. The `attempts` counter therefore stays at 0 for a gate row; three
  rounds still applies to `red`, `green`, `review` and `verify`.
- **Escalate** on a third request-changes for one stage, or when a third fix round
  would start: work order `blocked` with `"executionPolicy": null` in the same
  PATCH (otherwise Paperclip reads `blocked` as request-changes), one sentence
  why, recorded in the ledger, no more retries. Since GUL-1730 that sentence
  names **the PM** ("the PM decides in the 05:30 review"), not Wojtek: a failed
  gate, a third request-changes or a missing stage document is a factory call he
  reads in the morning brief. The one exception is a **never-path hit** (ADR-093
  point 6 — `agents/factory/**`, `clusters/`, SOPS keys, public exposure): that
  reason starts with `never path` and the sentence names Wojtek, because it is
  his call. Only the name changes — the blocked state, the ledger write and the
  no-retry rule are untouched. The **stage issue** is parked a
  different way (GUL-889, GUL-1128, GUL-1760): `blocked`, a self-owned
  `unblockDescriptor`, the comment, and an `executionPolicy` whose stages carry
  participants but not the stage id the state points at. Never
  `"executionPolicy": null`, never a policy whose `stages` list is empty, and never
  a PATCH that leaves the key out while the issue still carries a stage. Paperclip
  resolves the PATCH against the *stored* policy before it applies the requested
  status: a null or stage-less policy is a policy removal, which dissolves a live
  review back to its return assignee — `in_progress`, stage agent reassigned,
  `blocked` overwritten — so the failed write re-arms the agent, the stage hands
  back `in_review`, and the next foreman wake escalates again. Leaving the key off
  looks safer and is not: the server applies the stored policy, finds the stage
  `executionState.currentStageId` still names, and refuses the same write —
  `422 unblockDescriptor requires blocked status` on a spent round,
  `422 Only the escalated reviewer can advance the current execution stage` on an
  escalated hold. Only a policy whose stage id no longer resolves takes the branch
  that clears `executionState` and keeps `blocked`, which is why the factory drops
  the stage ids (GUL-969).

  The stage issue the park is built from has to come from `GET /issues/{id}`. The
  company issue list masks `executionPolicy` and `executionState` to null and
  `decide` resolves its stage through that list, so a park built from the list copy
  believes the stage never named a reviewer. `_fresh_issue` re-reads it, and
  `_park_policy` falls back to whoever the issue still names — the state's
  `currentParticipant`, its `returnAssignee`, then `assigneeAgentId` /
  `assigneeUserId` — when the stored policy has no participant-bearing stage. The
  key is left out only when the issue names nobody at all.

  A `decide --apply` that finds the ledger
  already at `outcome: escalate` **and** the stage issue settled (`blocked`,
  `done`, `cancelled`) writes nothing and exits 1 with `already escalated` — one
  bad write must never become a wake loop. A **missing stage document**
  escalates the same way and for the same reason (GUL-868): a review with no
  `findings`, or a verify missing its `verdicts` or the review's `findings`, is a
  stage nobody can judge. It used to `return 1` before any board write, so the
  stage parked with no blocked, no comment and no wake — indistinguishable from a
  quiet refusal. Now both issues are `blocked`, each comment names the missing
  document, and the ledger records `outcome: escalate`.
- Without `--apply` nothing is written: it prints the decision only.

**`tick [--apply]`** — read-only without `--apply`. One line per open work order: stage,
agent, age, rounds, and flags (`idle>2h`, `no-run`, `runs-unknown`,
`recovery-hold`, `stage-missing`, `STOP`, `pr-open`, `pr-merged`, `pr-closed`, `merge-unknown`,
`unlanded`). A ledger row whose
`issueId` the API no longer returns is `stage-missing`: the id and the 404 go to
stderr, that one work order is flagged, and the sweep reads the rest (GUL-557).
Config drift: every factory agent's
`adapterConfig.extraArgs` must carry the guard extension and its stage's
`--factory-role`; the agents API returns the key, so it is parsed in code and
only names and booleans are printed. An entry whose `factoryRole` is `null` runs
without the guard — in phase 2 that is the `gate` entry, because Majster has no
`extraArgs` and the `readonly` role would refuse `python3 … decide` — so `tick`
skips the drift check there and prints `guard: not required` instead of reporting
Majster as drift on every sweep.

**`tick --apply` — the merge watch (GUL-553).** For every open work order whose
ledger has a `pr.number` and no `merge` record, and whose **latest gate round**
(`gate`, `gate:r2`, … — the highest `round` in the ledger, GUL-1267 G4) stage
issue is `done` **or** the work order is escalated (GUL-1888), `tick` reads
`gh pr view <n> --repo OWNER/REPO --json state,mergedAt,mergeCommit` and settles it:

- **An escalated work order is watched too (GUL-1888).** Its gate is parked
  `blocked`, not `done`, because a failed gate escalates at once (GUL-1706) — and
  the PR it opened is still the thing a person merges on GitHub. Requiring a `done`
  gate meant that merge was never read and the work order stayed `blocked` for
  ever, until someone fixed it by hand (GUL-1749). While the PR is **open** nothing
  is touched: the escalation owns the block, and `--apply` refuses to settle a
  still-open PR even if a caller insists.
- `MERGED` → withdraw any leftover "Merge PR #N?" card, cancel the work order's
  parked stage issues, write `merge: {state, sha, at}` and `outcome: merged` to the
  ledger, **then** PATCH the work order `{"status": "done", "executionPolicy":
  null, "comment": "PR #N is merged in `<sha>` (<mergedAt>)"}`. Ledger first,
  status second, same rule as `decide`. If that PATCH fails the ledger already says
  `merged` while the work order still waits, so the tick prints `unsettled` (never a
  bare `pr-merged`), re-arms the merge monitor and retries the write next sweep.
- `OPEN` → re-arm the monitor (`nextCheckAt` = now + 1h) and change nothing else.
- `CLOSED` without a merge → ledger `outcome: closed`, work order `blocked` with
  one sentence: *PR #N was closed without a merge, so nothing shipped.*
- **`MERGED` is not `landed` (GUL-1801).** A merge commit only settles the work
  order when it contains the work order's branch head. When it does not, the round
  that head carries never reached `main` (GUL-1598: the merge took round 1 and the
  finished fix round was stranded on a local branch), so `tick` parks the work
  order `blocked` with `merge: {state: unlanded, sha, head, at}` and one sentence:
  *PR #N is merged in `<merge>`, but the work order's branch head `<head>` is not in
  that merge: land `<head>` on main, then re-run.* It never says merged and never
  says done. Every later sweep re-checks the park with `head` against `main`
  (`origin/main` first): once the head is on main — however it got there — the
  normal settle runs and the ledger says `merged`. A work order that is already
  `done` is left alone.
- **A squash merge counts (GUL-1888).** Equal trees are too strict once the branch
  takes `main` in after the squash (or `main` moves on after it): the trees differ
  for ever although the round landed. So when the trees differ, the merge commit's
  own patch (`<merge>^..<merge> --name-only`) is the set of hunks that landed, and
  the round is landed when **every file that patch touches** holds the same content
  at the branch head and in the merge. A merge that rewrote one of those files, or
  never touched them, is still unlanded.
- `gh` errors → the line carries `merge-unknown`, the reason goes to stderr, and
  nothing is written. One unreadable PR never stops the sweep. A `gate` row whose
  issue is gone is `stage-missing` and the merge is not settled, for the same
  reason: an unknown gate is not a passed gate.

`--apply` is ignored while the STOP flag exists: a stopped factory writes nothing.

Appends one line per open work order to
`~/paperclip-agents/majster/factory/ledger.jsonl`: `time, workOrder, stage,
agent, model, outcome (pass|fail|escalate|pending|merged|closed), round,
durationSec`, plus `tokens` when the run's usage has them and `merge` when the
work order was settled in this sweep. `pending` is the honest value for a work
order whose current stage has no recorded decision yet — the alternative was
lying with `pass`.

