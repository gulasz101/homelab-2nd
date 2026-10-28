# Factory work-order contract (GUL-436, ADR-093)

This file is the law for `agents/factory/factory.py`. A script, not a model,
decides whether a factory stage passed. Everything the script reads and prints
is defined here. If code and this file disagree, the code is wrong.

Design rules:

- Python 3 standard library only, run as `python3 -I agents/factory/factory.py <subcommand>`.
  JSON, not YAML: the system `python3` on the Air and in CI has no PyYAML.
- `git` is called through `subprocess` with an argument list, never through a
  shell string. The one deliberate exception: AC `check` commands (point 2),
  which are defined as shell commands and run with `bash -c` from the repo
  root — a work order is human-approved text, and the spec author is on the
  hook for its checks.
- No stage check talks to Paperclip. Network use in `lint-spec`/`check-*`/
  `commit`/`open-pr` is only `gh`, only inside `check-gate` and `open-pr`. The
  `gh` binary comes from env `FACTORY_GH` (default `gh`) so tests can stub it.
- Since GUL-439 the three orchestration subcommands — `start`, `decide`, `tick`
  — do talk to Paperclip, and only through `pc.py` next to this file (stdlib
  `urllib`). They never call `gh`, never `git push` themselves, and never read
  the board token file (GUL-297); auth is `PAPERCLIP_API_KEY` and
  `PAPERCLIP_RUN_ID` from the environment or the subcommand exits 2.
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

AC rules:

- `id` matches `AC-<n>` (`^AC-[0-9]+$`, no leading zeros), unique within the spec.
- `text` is one sentence for people; the script only requires it non-empty.
- `check` is exactly one command: non-empty, one line (no embedded newline).
  It runs with `bash -c` from the repo root. Several ACs may share one check
  by repeating the identical `check` string — the script then runs that
  command once for all of them.

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
| `lint-spec --spec FILE` | the spec follows point 1 (block found & parseable; a broken/unparseable JSON block is a lint **failure**, exit 1; an unreadable FILE is exit 2) |
| `check-red --repo DIR --base SHA --spec FILE` | the diff SHA→worktree touches only test paths, all inside `allowedPaths`; every AC's check runs and reports `AC-n: FAIL`; no setup errors |
| `check-green --repo DIR --red SHA --spec FILE` | every test path is byte-identical to the red commit (worktree contents; a new untracked test path is a violation); every changed path is inside `allowedPaths`; every AC reports `PASS`; if the repo has `scripts/check.sh`, it runs (`bash scripts/check.sh`, repo root) and must exit 0 |
| `check-findings --repo DIR --base SHA --findings FILE` | findings follow point 3; every `file` is in the diff SHA→worktree; every `line` exists in the new version (file readable, ≥ `line` lines) |
| `check-verdicts --findings FILE --verdicts FILE` | points 3 + 4; every finding has exactly one verdict, no extra ids. JSON adds `"blockingConfirmed": ["F-…"]` = blocking findings with verdict `confirmed` |
| `check-gate --pr OWNER/REPO#N --spec FILE` | the check run named `check` on the PR head commit has state SUCCESS; no changed path is a never path (globs, newFilesUnder, content rules on each changed YAML's new-version text at head); `additions + deletions ≤ maxDiffLines` |
| `commit --repo DIR --stage red\|green --issue GUL-N` | stages all changes and commits `factory(GUL-N): <stage>` + trailer `Co-Authored-By: Paperclip <noreply@paperclip.ing>`; refuses (exit 1) **before staging** when the change set breaks the stage scope: `red` = every touched path is a test path, `green` = no touched path is a test path. JSON adds `"sha": "<new commit sha>"`. The change set = point-6 diff vs HEAD (unborn HEAD: untracked files only) |
| `open-pr --repo DIR --issue GUL-N --title T` | current branch is not `main`/`master` (refuse, exit 1); `git push -u origin <branch>` (never `--force`); `gh pr create` with body linking the work order: `Work order: [GUL-N](https://paperclip.voitech.dev/GUL/issues/GUL-N)`. JSON adds `"url": "<PR url>"`. Repo comes from `git remote get-url origin` |
| `start GUL-N [--dry-run]` | point 9 below |
| `decide GUL-M [--apply]` | point 9 below |
| `tick` | point 9 below |

`--pr OWNER/REPO#N` splits on the last `#`.

### `check-gate` gh calls (exact, so a stub can serve them)

1. `gh pr view <N> --repo OWNER/REPO --json headRefOid,baseRefOid,additions,deletions,files`
2. `gh pr checks <N> --repo OWNER/REPO --json name,state`
3. for every changed path ending `.yaml`/`.yml`:
   `gh api "/repos/OWNER/REPO/contents/<path>?ref=<headRefOid>"` (JSON, base64 `content`)

A missing `check` run, a non-SUCCESS state, or a gh call that errors/returns
unparseable output → not a pass (gh errors are setup errors, exit 2).

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
self-contained: a stage agent may not be able to read the work order. Each brief
ends with both hand-off payloads — the full `executionPolicy` on the first
hand-off, `status` + `comment` only on a stage that already carries a
`changes_requested` decision (GUL-471).

**`start GUL-N [--dry-run]`**

1. Refuses (exit 1) when `~/paperclip-agents/majster/factory/STOP` exists
   (`FACTORY_STOP` overrides). Runs `lint-spec` on the spec; a bad spec is exit 1.
2. Refuses while another work order is open in the same project — the shared
   checkout cannot hold two diffs (ADR-094). `--dry-run` plans and creates nothing.
3. Records in the work order's `ledger` document: `baseSha` (= `origin/<spec.base>`),
   `branch` = `gul-<N>-<slug>`, `cwd`.
4. Creates 5 children: `[red]` → Tester, `[green]` → Builder, `[review]` →
   Reviewer, `[verify]` → Verifier, `[gate]` → Majster. The first is `todo`, each
   later one `blocked` by the one before. Red/green/review/verify carry
   `executionPolicy {"stages": [{"type": "review", "participants": [{"type": "agent",
   "agentId": Majster}]}]}`.
5. `start` twice creates nothing the second time (the ledger has the stages).

**Ledger** — markdown with one fenced `json` block on the work order:
`{version, workOrder, workOrderId, title, repo, base, baseSha, cwd, branch,
projectId, stages: {<stage or stage:rN>: {issueId, identifier, round, attempts,
sha}}, fixRounds, pr: {number, url} | null, outcome, escalated}`. Only `factory.py`
writes it.

**`decide GUL-M [--apply]`** — M is the stage issue; the stage comes from its
`[stage]`/`[stage rN]` title. Runs the check for that stage against the spec and
the ledger (`check-red`, `check-green` with the red sha, `check-findings`,
`check-verdicts`, `check-gate` with the ledger's PR).

- Pass → `commit`/`open-pr` where the stage calls for it, then
  `PATCH {"status": "done", "comment": …}`.
- Fail → `PATCH {"status": "in_progress", "comment": …}` (request changes;
  Paperclip routes it back to the stage agent). The comment is the check's JSON
  line plus the last 60 lines of its output.
- verify with a non-empty `blockingConfirmed` → approve it and open a fix round
  (`[green r2]` → `[review r2]` → `[verify r2]`, chained the same way), confirmed
  findings pasted into the fix issue. At most 2 fix rounds.
- gate pass → a `request_confirmation` interaction on the work order
  (`resolverPolicy: human_only`, "Merge PR #N?") plus `in_review`. Wojtek merges.
- **Escalate** on a third request-changes for one stage, or when a third fix round
  would start: work order `blocked` with `"executionPolicy": null` in the same
  PATCH (otherwise Paperclip reads `blocked` as request-changes), one sentence
  why, recorded in the ledger, no more retries.
- Without `--apply` nothing is written: it prints the decision only.

**`tick`** — changes nothing in Paperclip. One line per open work order: stage,
agent, age, rounds, and flags (`idle>2h`, `no-run`, `runs-unknown`,
`recovery-hold`, `STOP`). Config drift: every factory agent's
`adapterConfig.extraArgs` must carry the guard extension and its stage's
`--factory-role`; the agents API returns the key, so it is parsed in code and
only names and booleans are printed. Appends one line per open work order to
`~/paperclip-agents/majster/factory/ledger.jsonl`: `time, workOrder, stage,
agent, model, outcome (pass|fail|escalate|pending), round, durationSec`, plus
`tokens` when the run's usage has them. `pending` is the honest value for a work
order whose current stage has no recorded decision yet — the alternative was
lying with `pass`.

