# factory-guard

One Pi extension that every code-factory agent loads. It moves the guards out
of the prompts and into code: a tool-call gate, run controls (turn cap, repeat
guard) and a diff guard that cleans up what the gate cannot parse. If it
cannot decide, it blocks. Nothing here is deleted, ever — violations are
restored, quarantined or reported.

Built for GUL-303, phase 1 of the code-factory plan (GUL-262).

## Why each rule exists

| Rule | What it blocks | Why |
|---|---|---|
| `no-role` | Every write/edit/bash when `--factory-role` is missing or unknown | A gate that defaults open is decoration (GUL-162) |
| `secrets-path` | Any tool or bash word touching `.env*`, `*.pem`, `*.key`, `id_ed25519*`, `id_rsa*`, `.ssh/`, age keys, `auth.json`, `mcp-auth.json`, `~/.paperclip/**` | Agent output lands in logs and issue comments; secrets must never be readable by the model |
| `sops-decrypt` | `sops` without `-e`/`--encrypt` | Decrypting in a chat-connected agent prints plaintext to the provider |
| `env-dump` | `printenv`, bare `env`, `export -p`, `declare -x`, bare `set` | The process environment holds DB and S3 credentials (GUL-206 family) |
| `ps-full-cmdline` | `ps aux`, `ps -ef`, `ps -o command/args`, `pgrep -l/-a/-f` | `ps` printed the Paperclip server's database and S3 secrets from the Air (GUL-206) |
| `git-force-push`, `git-main-push` | `push --force`/`-f`/`--force-with-lease`, `+` refspecs, any push of `main`/`master` | History rewrite and direct-to-main are how a fleet of agents destroys a repo |
| `git-no-verify` | `--no-verify` on any git command | The hooks are part of the contract |
| `gh-pr-merge`, `gh-repo-delete`, `gh-api-delete` | `gh pr merge`, `gh repo delete`, `gh api -X DELETE` | Merging is the owner's job (GUL-262 review gates), deleting is never the agent's |
| `new-dependency` | `npm install <pkg>`, `pnpm/yarn/bun add`, `pip install`, `uv add/pip install`, `brew/cargo/go install`, `npx -y` | Lockfile drift; installs bypass review. `npm ci`, `pnpm install --frozen-lockfile`, `uv sync`, `uv run --with` stay allowed |
| `disk-scan` | `find`/`grep -r`/`rg`/`fd`/`du`/`ls -R` over `/`, `/System`, `/Users`, `/Volumes`, `/private`, `/opt`, `/Library`, `$HOME`, `~` | They hang the agent for an hour and sweep secrets into context (GUL-131) — same root list as the old `shellCommandPrefix` |
| `protected-file` | write/edit and bash writers (`>`, `tee`, `sed -i`, `perl -i`, `mv`, `cp`, `rm`, `truncate`, `chmod`, `ln`, `git restore/rm/checkout --`) on `AGENTS.md`/`SOUL.md`/`CLAUDE.md`/`HEARTBEAT.md`/`TOOLS.md` anywhere, `.sops.yaml`, `.github/workflows/**`, `agents/factory-guard/**`, the installed guard copy, `~/.pi/agent/{settings,models}.json`, `~/.pi/agent/extensions/**`, `~/.paperclip/**` | An agent that can rewrite its own brief or the repo's CI is not a worker, it's a liability (the GUL-131/GUL-221 line of incidents) |
| `role-write-scope`, `role-write-forbidden`, `role-no-commit`, `role-no-push`, `readonly-allowlist` | Per-role write areas (see `roles.json`) | Separation of duties: tester writes tests, builder writes code, readonly only looks |
| `turn-cap` | Every gated tool after the role's cap | A Pi run that loops never stops by itself (GUL-205) |
| `repeat-guard` | A bash command on its third identical failure with no successful write/edit between | Stop flailing: report instead of grinding |

Bash parsing will never be perfect. `python3 -c "open('AGENTS.md','a')..."`
is deliberately in the live test as the case the gate lets through — and the
diff guard is what puts it back. That is the design, not an oversight.

## Roles

`--factory-role executor|tester|builder|readonly` (string flag registered by
this extension). Missing or unknown role fails closed. Profiles live in
`roles.json`:

| Role | Writes | Commit/push | Turn cap |
|---|---|---|---|
| `executor` | anywhere except the always-denied list | yes / own branch only | 60 |
| `tester` | `**/tests/**`, `**/test/**`, `**/*.test.*`, `**/*_test.*`, `**/test_*.py` inside the workspace repo | no / no | 25 |
| `builder` | workspace repo except test paths | no / no | 40 |
| `readonly` | none; bash limited to a read-only allowlist, plus the one stage hand-off (below) | no / no | 20 |

### The one write a read-only agent may make (GUL-468)

A `[review]` or `[verify]` stage ends with "PATCH this issue to `in_review`", and the API is the
only channel for it, so `curl` is allowed for the `readonly` role **only** when all of these hold:

- the request is `PATCH` (`-X PATCH`, `--request PATCH`, `--request=PATCH`, `-XPATCH`);
- exactly one URL, and it is the Paperclip API: `$PAPERCLIP_API_URL…`, `127.0.0.1`, `localhost`
  or `paperclip.voitech.dev`, on an `/issues/` path;
- the body is inline (`-d '{…}'`), never `@file` or `@-`.

Everything else through `curl` is refused with `readonly-allowlist`: any other verb, another host,
a body or upload from a local file (`-T`, `--data-binary`, `-F`), or an output file (`-o`). The
point is that the role stays read only on the filesystem and cannot reach a second API, while still
being able to hand its own stage back. `tests/policy.test.ts` has three allow cases and eight block
cases, and the live matrix runs a real PATCH and a real POST.

"Workspace repo" = the git top-level of the run's cwd. Only `executor` may
write outside it, because today's Pi works on files outside repos.

## Turn-cap measurement (executor: 60)

Method: counted the assistant messages per Pi session file (each is one model
turn, which is what `turn_end` counts) in `~/.pi/agent/sessions/` with mtime
in the 14 days before 2026-10-27:

- 19 session files, 1-3 assistant turns each, 95th percentile (nearest-rank) = 3.
- Rounded up to the next ten = 10, but the floor of 60 from the plan rules.
- Caveat worth knowing: the Paperclip Pi adapter runs `pi --print` in
  `/Users/paperclip/Projects` and those runs left no session directory
  (`--Users-paperclip-Projects--` does not exist), so the real executor
  population is not yet in the sample. The measured files come from manual
  verification and smoke runs.

So: **executor 60** for now. Once Pi runs are started with session saving
(the activation step does), re-count turns per session file over a fortnight
of real wakes and tighten the number.

## Run controls

- **Turn cap**: `turn_end` increments a per-process counter (per Paperclip
  wake). At the cap, every gated call is blocked with
  `factory-guard: turn cap <N> reached. Post a short comment with what is done
  and what is left, end it with "RESULT: stalled", and stop.`
- **Repeat guard**: same failing bash command twice, no successful write/edit
  in between, third attempt blocked with
  `factory-guard: same failing command, nothing changed. Change something or stop.`
- **Diff guard** (`agent_before_settle`, once per run): `git status --porcelain`
  in the workspace repo; out-of-scope or protected tracked changes are
  `git restore --staged --worktree -- <path>`-ed, untracked ones are moved to
  `$PAPERCLIP_RUN_SCRATCH_DIR/factory-guard-quarantine/` (OS temp fallback).
  Protected files outside any repo (`~/.pi/agent/*`, `~/paperclip-agents/*/`)
  are hash-snapshotted at `session_start` and restored from the snapshot copy
  at settle. Committed violations are blamed on THIS run (GUL-424): the base is
  the `HEAD` SHA captured at `session_start`, so foreign commits already on the
  branch when the run started are never logged against the executor. With no
  start SHA (resumed session) the old `merge-base(origin|main, HEAD)` fallback
  applies; if the shared checkout was branch-switched mid-run (start SHA no
  longer an ancestor of HEAD) the committed scan is skipped rather than guessing.
  Committed work is never rewritten — only reported, and each path is logged
  once even though settle fires twice. Then at most one continuation asks the
  agent to paste the list of
  restored/quarantined/committed items into its issue comment and end with
  `RESULT: guard-violation` when something was committed in violation.
  Deviation from the plan, on purpose: files that may hold credentials
  (`settings.json`, `models.json`, anything named `auth.json`/`mcp-auth.json`)
  are hash-watched but never copied into the scratch dir — a restore copy is
  itself a secret at rest. Those get reported, not restored.
- **Block log**: one JSON line per block/restore at
  `~/.pi/agent/factory-guard/blocks.jsonl` (`FACTORY_GUARD_BLOCK_LOG` overrides
  for tests). Fields: `time, role, tool, rule[, path]`. No command text, no
  reason text — either can carry a secret.

## Load it

```bash
pi --extension <dir>/index.ts --factory-role executor
```

jiti loads the TypeScript directly, no build step. During activation the copy
lives at `~/paperclip-agents/pi/extensions/factory-guard/` — see the GUL-303
PR description for the full procedure (it is a post-merge, separate step so
nothing lands in `~/.pi/agent/extensions/`, which loads into every Pi process
including Majster).

## Run the self-test

```bash
bash agents/factory-guard/tests/guard-check.sh
```

Unit table (176 cases, `node:test`, no npm deps, Node 24 type-stripping) then
the live test: a real `pi --print` in a fresh temp git repo driven by
`tests/scripted-provider.ts` (faux stream protocol, fixed tool-call list from
JSON — zero tokens, identical every run). Exit 0 only if the allowed write
applied, the gated calls blocked, the unparseable `AGENTS.md` write was
restored by the diff guard and `blocks.jsonl` held one line per block without
command text. Where `pi` is missing (CI) it prints
`SKIP live: pi not installed` and the unit part still gates the merge.

## Layout

- `index.ts` — Pi wiring only: events, state, git calls, snapshots, log. No rules.
- `policy.ts` — every rule, pure functions, no Pi imports. `scanBashLine()` is
  the compound-command parser.
- `roles.json` — the role profiles.
- `tests/` — `policy.test.ts` (table), `scripted-provider.ts`, `guard-check.sh`.

## Known gaps (backstopped by the diff guard)

- Function bodies, `case` arms and `for` loops are parsed best-effort.
- Interpreter writes (`python3 -c`, `node -e`, heredoc into a path) are not
  understood; only paths named literally are caught.
- A file renamed/moved into place by unparseable code is caught at settle by
  its final path, not its method.

That is fine: the gate slows an agent down, the diff guard guarantees the
tree ends clean, the block log gives the review the evidence.
