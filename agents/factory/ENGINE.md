# Factory engine contract (GUL-2037 phase 2)

This file is the law for `agents/factory/engine.py`. If the code and this file disagree, the code
is wrong. `CONTRACT.md` still rules the stage **checks** (`lint-spec`, `check-*`, `commit`, `push`,
`open-pr`): the engine calls them, it does not re-implement them. The old orchestration in
`factory.py` (`start`, `decide`, `tick`) stays in place, untouched, until the burn-in (phase 6)
passes.

## Why a new engine

The old one uses Paperclip as its state machine: a pre-made chain of 5 `blocked` stage issues per
work order, review stages, `executionPolicy` hand-offs, one shared checkout, and an LLM (Majster)
that runs `decide`/`tick`. Every Paperclip trap hit it (CONTRACT.md point 9 is mostly scar tissue).
The engine keeps its own state, creates a stage issue only when that stage starts, gives every work
order its own git worktree, and runs from launchd with no model.

Rules:

- Python 3 standard library only, `python3 -I agents/factory/engine.py <subcommand>`. JSON, no YAML.
- Every subcommand prints exactly one JSON line on stdout (`{"ok": bool, "check": "engine-<sub>",
  "reasons": [...], ...}`) and a short human summary on stderr. Exit 0 ok, 1 refused/not passed,
  2 setup error (same meaning as CONTRACT.md point 8).
- Stage checks run as subprocesses of the `factory.py` next to `engine.py`:
  `python3 -I <dir>/factory.py check-red --repo <worktree> --base <baseSha> --spec <file>` etc.
  The engine parses their JSON line and keeps the last 60 lines of output for the brief.
- Paperclip only through `pc.py`. Hindsight, docs-mcp, the Lodge and `gh` through stdlib `urllib` /
  `subprocess` with argument lists, never a shell string. No secret is ever printed, logged,
  written to state, to a document or to a comment.
- **No stage issue is ever `blocked`.** The engine never sets `executionPolicy` on a stage issue and
  never sets a stage issue to `blocked`. A failed stage gets a **new** issue (the next attempt);
  the old one stays `done` with one comment pointing to the new one.

## Config: `agents/factory/engine.json`

```json
{
  "maxActiveOrders": 2,
  "maxAttempts": 3,
  "maxFixRounds": 2,
  "stageTimeoutMinutes": {"librarian": 20, "red": 90, "green": 90, "review": 60, "verify": 60},
  "idleMinutes": 15,
  "gateCiWaitMinutes": 60,
  "supervisorAgentId": "2df240b5-a5ea-4ebf-81ff-bf96758e8f80",
  "stages": {
    "librarian": {"agentId": "4dc8b6a7-f155-4539-9a74-2f600391a5d9", "lodge": "librarian"},
    "red":    {"agentId": "e0dd70fa-3e08-4d42-b226-0e58b0b59639", "lodge": "tester"},
    "green":  {"agentId": "6786758e-5db9-4f0f-a7df-b42adeede465", "lodge": "builder"},
    "review": {"agentId": "51c624e7-5018-4f22-a23c-dd4911e44a61", "lodge": "reviewer"},
    "verify": {"agentId": "974c23c8-f6b1-4afa-8073-79aa352c6358", "lodge": "verifier"}
  },
  "repos": {
    "gulasz101/homelab-2nd": {
      "clone": "/Users/paperclip/factory/homelab-2nd",
      "worktrees": "/Users/paperclip/factory/worktrees/homelab-2nd"
    }
  },
  "recallBanks": ["coding-agent::{repoName}", "hermes-andrzej"],
  "retainBank": "coding-agent::{repoName}",
  "hindsightUrl": "http://192.168.1.179:30239",
  "docsUrl": "http://192.168.1.179:6280",
  "lodgeUrl": "http://192.168.1.179:30260",
  "autoPickup": false
}
```

`{repoName}` is the part after the slash (`homelab-2nd`). Env overrides for tests and the
self-test: `FACTORY_ENGINE_CONFIG` (path of the config), `FACTORY_ENGINE_STATE` (state dir),
`FACTORY_HINDSIGHT_URL`, `FACTORY_DOCS_URL`, `FACTORY_LODGE_URL`, `FACTORY_GH`, `FACTORY_STOP`.

## Credentials (never in the repo)

- Paperclip: only the file `FACTORY_ENGINE_KEY_FILE` (default `~/.paperclip/factory-engine-board.key`,
  mode 600): a named **board** API key `factory-engine (GUL-2037)`. An agent key does not work: outside a
  heartbeat run Paperclip answers 403 to every cross-issue write. The engine ignores
  `PAPERCLIP_API_KEY`, so it never acts as the agent whose run happens to call it. `pc.Api` runs with
  `run_id=""` and then sends no `X-Paperclip-Run-Id` header.
- Hindsight: `HINDSIGHT_API_TOKEN`, else `apiToken` from `~/.hindsight/coding-agent.json`.
- Lodge: `~/.config/sou/<lodge name>.token` (mode 600), one per stage agent.
- `gh`: the host login, as today.
- A missing Hindsight or Lodge credential is not an error: the engine writes "recall unavailable:
  no token" into the brief, or skips the Lodge post. A missing Paperclip key is exit 2.

## State

One JSON file per work order: `<state>/<WO>.json` (default state dir
`~/factory/engine-state`). Written atomically (temp file in the same dir + `os.replace`). It is the
engine's only source of truth. After every change the engine also writes it to the work order's
Paperclip document `engine-state` (markdown + one fenced `json` block, with `baseRevisionId`, as
`pc.write_document` already does). That mirror is for people; the engine never reads it back.

```json
{"version": 1, "workOrder": "GUL-N", "workOrderId": "...", "title": "...", "projectId": "...",
 "repo": "owner/name", "base": "main", "baseSha": "...", "branch": "gul-N-slug",
 "worktree": "/abs/path", "workspaceId": "...", "specFile": "<state>/GUL-N.spec.md",
 "specRevisionId": "...", "phase": "queued|librarian|red|green|review|verify|gate|awaiting_merge|done|closed|stalled",
 "round": 1,
 "docsReady": [{"library": "...", "version": "...", "indexed": true, "note": "..."}],
 "stages": [{"stage": "red", "round": 1, "attempt": 1, "issueId": "...", "identifier": "GUL-M",
             "createdAt": "...", "result": "pending|pass|fail|timeout", "reasons": [],
             "fingerprint": "sha1 or null", "sha": "commit sha or null"}],
 "redSha": null, "pr": {"number": 0, "url": "", "head": ""}, "merge": null,
 "findings": [], "blockingConfirmed": [], "stallReason": null, "retained": false,
 "createdAt": "...", "updatedAt": "..."}
```

The spec is frozen at start: the `spec` document body is copied to `specFile` and its revision id
recorded. A later edit of the Paperclip `spec` does not change a running order (phase 3 adds
`AMEND:` blocks).

## Subcommands

| Subcommand | Does |
|---|---|
| `start GUL-N [--dry-run]` | lint the spec (`factory.py lint-spec`), refuse a bad one (exit 1). Refuse if a state file exists (idempotent: exit 0, `"already": true`). Write state with `phase: queued`. Set the work order `todo` with one comment and **no assignee**: Paperclip refuses to assign a paused agent (409), an active one would wake a model, and `in_progress` needs an assignee (422). The order's real phase is its `engine-state` document. The next `tick` does the rest. `--dry-run` prints the plan and writes nothing |
| `tick [--apply]` | one supervisor pass over every state file (below). Without `--apply` it prints what it would do and writes nothing anywhere |
| `status [GUL-N]` | one JSON line per order: phase, round, current stage issue, attempt, age in minutes, flags |
| `inventory --repo DIR --spec FILE` | the Librarian's lockfile/version table as JSON (used by `tick` and by the tests) |

`factory-run.sh` passes `engine ...` through: `factory engine tick --apply` runs
`python3 -I $TOOLING/agents/factory/engine.py tick --apply`, from the tooling copy of `main`, like
every other subcommand.

## The tick

1. `STOP` file present (`FACTORY_STOP`, default `~/paperclip-agents/majster/factory/STOP`) → print
   `stopped`, exit 0, write nothing.
2. Take `<state>/engine.lock` with `fcntl.flock(LOCK_EX | LOCK_NB)`. Held → print `busy`, exit 0.
3. For each state file, oldest first, run one step (below). One order's error (an exception, an API
   error) is caught, printed to stderr with the order id, flagged `error` in its status line, and
   the tick goes on to the next order. It never corrupts the state file: state is written only
   after the step's writes succeeded, or the step is re-runnable.
4. Slots: an order counts as **active** while its phase is `librarian` .. `gate`. A `queued` order
   starts only when fewer than `maxActiveOrders` are active (oldest first). `awaiting_merge`,
   `stalled`, `done`, `closed` hold no slot.
5. Append one line per order to `<state>/ledger.jsonl`: `time, workOrder, phase, stage, round,
   attempt, outcome, issue`.

### Step per phase

**queued → librarian (start of work)**
1. `git -C <clone> fetch origin`; `baseSha` = `origin/<base>`.
2. `git -C <clone> worktree add -b <branch> <worktrees>/<branch> <baseSha>`. Branch =
   `gul-<N>-<slug>` (slug as `factory.slugify`). If the worktree path already exists and is that
   branch, reuse it (re-run after a crash). Never touch the clone's own working tree: the old
   factory checkout may be dirty and on another branch.
3. Create a Paperclip project workspace in the work order's project:
   `POST /projects/<projectId>/workspaces {"name": "wo GUL-N", "sourceType": "local_path",
   "cwd": <worktree>, "isPrimary": false}`. Every stage issue carries its id as
   `projectWorkspaceId`. That is what makes the agent's run start in the worktree
   (`PAPERCLIP_WORKSPACE_CWD`), and the factory-guard only lets an agent write inside the repo it
   starts in. Measured on GUL-2046 (cwd probe).
4. Run `inventory`. Every row `ok` (or no rows) → the engine writes `docsReady` itself, posts the
   `docs-ready` document on the work order, and goes straight to **red**. No model run.
   Otherwise create the librarian stage issue.

**Creating a stage issue** (any stage):
- Refuse to create it while the stage agent is `paused` or `terminated`: the order stays in its
  phase with no issue and the flag `agent-paused`; no stage issue is filed (the phase move, worktree,
  workspace and `docs-ready` doc are already written). (The crew is paused until burn-in; this
  makes that state visible instead of filing issues nobody runs.)
- `POST /companies/<company>/issues` with `parentId` = work order, `projectId`,
  `projectWorkspaceId`, `assigneeAgentId` = the stage agent, `status: todo`, the work order's
  `priority`, title `[<stage>] GUL-N <title>`, with ` r<round>` after the stage name in a fix round
  and ` a<attempt>` from attempt 2 (`[green r2 a2] GUL-N ...`). No `executionPolicy`.
- Description = the brief, in this order:
  1. `## What the factory remembers` (recall, below);
  2. `## Docs ready` (the `docsReady` table; for the librarian stage: the inventory table instead);
  3. `## Last attempt failed` (from attempt 2: the previous attempt's check JSON line and the last
     60 lines of its output; when the fingerprint equals an earlier attempt of the same stage, the
     first line is `SAME FAILURE as attempt <k>: find a different cause, do not repeat the last fix.`);
  4. `## Fix round` (green of round ≥ 2: `factory.fix_round_findings_block`);
  5. the stage template `templates/engine/<stage>.md`, filled like `factory.fill_template`.
- Post a Lodge `state_change` for the stage agent (below), record the stage row, write state.

**Waiting on a stage issue** — each tick re-reads the issue (`GET /issues/<id>`):
- `done` or `in_review` → judge it (below).
- `cancelled` by someone else → the attempt fails with reason `stage issue cancelled by <who>`.
- `blocked` set by the agent → the attempt fails with the agent's last comment as reason.
- still `todo`/`in_progress`: when the age passes `stageTimeoutMinutes[stage]`, or the issue has no
  live run and no update for `idleMinutes`, the attempt is a `timeout`: the engine cancels the
  issue (`{"status": "cancelled", "comment": ...}`; it has no policy, so the plain cancel holds) and
  treats it as a failed attempt.

**Judging, per stage**
| Stage | Check | On pass |
|---|---|---|
| librarian | the issue's `docs-ready` document has one fenced json list with a row for every inventory library | store `docsReady`, write the work-order `docs-ready` doc, go to red |
| red | `factory.py check-red --repo <wt> --base <baseSha> --spec <specFile>` | `factory.py commit --repo <wt> --stage red --issue GUL-N`; `redSha`; go to green |
| green | `factory.py check-green --repo <wt> --red <redSha> --spec <specFile>` | `commit --stage green`; round 1: `open-pr --repo <wt> --issue GUL-N --title "factory(GUL-N): <title>"` (draft), record `pr`; later rounds: `push`, record `pr.head`; go to review |
| review | the issue's `findings` document → temp file → `check-findings --repo <wt> --base <baseSha> --findings <file>` | store `findings`. Empty list → gate. Else → verify |
| verify | the issue's `verdicts` document → `check-verdicts --findings <f> --verdicts <v>` | `blockingConfirmed` empty → gate. Else: round + 1 (≤ `maxFixRounds` + 1) and go to green with the findings block; over the limit → stalled |
| gate | `gh pr checks <n> --repo <repo> --json name,state`: the `check` run still pending → wait (no attempt spent) until `gateCiWaitMinutes`; then `factory.py check-gate --pr <repo>#<n> --spec <specFile>` | `awaiting_merge`: work order `in_review`, one comment with the PR link and "merge it on GitHub" (phase 4 adds the auto-merge) |

The librarian **never** stops an order: an invalid or missing `docs-ready` document, a timeout or a
failed attempt each pass with rows `{"indexed": false, "note": "no docs: <reason>"}`. It gets one
attempt.

The gate has no agent. A failed gate is a stall at once (re-running the same check on the same head
gives the same answer).

**On a failed attempt** (red, green, review, verify): record `result`, `reasons`, and the
fingerprint = sha1 of the sorted, whitespace-normalised `reasons` of the check JSON. Comment on the
old issue: `engine check: FAIL — <first reason>. Next attempt: <GUL-M>`, then create the next
attempt. Leave the worktree as it is (the next attempt starts from the same files). After
`maxAttempts` failed attempts of one stage in one round → **stalled**.

**Stalled** (phase 2; phase 3 replaces this with the stall ladder): `stallReason` = one plain
sentence; work order `blocked` with `"executionPolicy": null` in the same PATCH and that sentence as
the comment; the worktree and the workspace stay for the investigation. Retain (below). A stalled
order holds no slot.

**awaiting_merge** — each tick `gh pr view <n> --repo <repo> --json state,mergedAt,mergeCommit,headRefOid`:
- `OPEN` → nothing.
- `MERGED` and `factory.merge_contains(<clone>, <head>, <merge sha>)` → `merge` record, phase
  `done`, retain, clean up, work order `done` with comment `PR #N is merged in <sha>`.
- `MERGED` but not landed → stalled with the CONTRACT.md "unlanded" sentence.
- `CLOSED` → phase `closed`, retain, clean up, work order `blocked`: `PR #N was closed without a
  merge, so nothing shipped.`

**Clean up**: `DELETE /projects/<projectId>/workspaces/<workspaceId>`; then
`git -C <clone> worktree remove <worktree>` only when `git status --porcelain` in it is empty —
otherwise keep it and say so in the work-order comment. Never `--force`, never delete a branch.

## Recall (before every stage issue)

For each bank in `recallBanks`: `POST <hindsightUrl>/v1/default/banks/<bank>/memories/recall`
with `{"query": "<WO title>. Stage <stage>. Paths: <allowedPaths joined>", "max_tokens": 1000,
"budget": "mid"}`, timeout 20 s, `Authorization: Bearer <token>`. Keep the first 8 results, each
`text` collapsed to one line and cut to 300 characters. Format:

```
## What the factory remembers
Read-only notes from Hindsight. Use what fits; ignore the rest.
From coding-agent::homelab-2nd:
- ...
From hermes-andrzej:
- ...
```

A bank that errors becomes one line `From <bank>: recall unavailable (<HTTP code or error class>)`.
Recall never fails a stage. The bank names in the query URL are percent-encoded (`::`).

## Retain (once per order)

On `done`, `closed` or `stalled`, when `retained` is false: one
`POST <hindsightUrl>/v1/default/banks/<retainBank>/memories` with
`{"async": true, "items": [{"content": <text>, "context": "factory work order outcome",
"document_id": "factory-GUL-N", "tags": ["factory", "GUL-N"], "timestamp": <now ISO>}]}`.
Content (max 4000 characters): title, outcome, PR url, per stage the attempts with their first
reason, which fingerprints repeated, the confirmed findings' claims, the stall reason. Then
`retained: true`. A failed retain is retried on the next tick, at most 3 times, then given up with
a stderr line. Never more than one retain call per order per tick.

## Inventory (the Librarian's script)

`inventory` reads the worktree (no network for the file part):
- Scope: files in the repo root and under the literal prefix (up to the first `*`/`?`) of each
  `allowedPaths` glob.
- `package.json` (`dependencies`, `devDependencies`; exact version from `package-lock.json` when
  present), `pyproject.toml` (`[project].dependencies` via `tomllib`), `requirements*.txt`,
  `Cargo.toml` (`[dependencies]`), `go.mod` (`require`), and HelmRelease YAML in scope
  (`chart:` + `version:` under `spec.chart.spec`, line-based, no YAML parser).
- At most 25 rows, files inside `allowedPaths` first.
- Then one read of the docs index (`docsUrl`; the HTTP endpoint the `docs-search` CLI uses for
  `list`): each row gets `ok` (indexed, and an indexed version ≥ ours or an unversioned entry),
  `stale` (indexed only at a lower major.minor) or `missing`. Name match is case-insensitive with
  `-`, `_`, `.` and `@scope/` ignored. Docs index unreachable → every row `unknown`, and the
  librarian stage runs.

## Lodge

`POST` one `state_change` event per stage start and per stage result, under the stage agent's Lodge
name, with its token, timeout 5 s, best effort (an error is one stderr line). Event detail:
`GUL-N <stage> r<round> a<attempt>: started|pass|fail|timeout`. Use the same endpoint and payload
shape as the OpenCode adapter `~/.config/opencode/plugins/sou-lodge.js`.

## launchd

`agents/factory/launchd/dev.voitech.factory-engine.plist`: `factory engine tick --apply` every 120 s
(`StartInterval`), logs to `~/factory/engine-state/tick.log` (stdout and stderr), no secrets in the
plist. Installing it is a host step, done once by hand after the merge.

## Phase 2 acceptance (the live check, on this host)

1. A red stage issue's description starts with `## What the factory remembers`, then `## Docs ready`.
2. Two work orders are in `red`..`verify` at the same time, each in its own worktree, each agent run
   reports its own worktree as `PAPERCLIP_WORKSPACE_CWD`.
3. Across the run: zero stage issues ever `blocked` (`GET` every stage issue in the state files).
4. `tests/engine-check.sh` passes in `scripts/check.sh`.
