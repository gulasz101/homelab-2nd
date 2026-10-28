# [green{{roundSuffix}}] {{workOrder}} — make the tests pass

Work order: **{{workOrder}}** — {{workOrderTitle}}
Repo: `{{repo}}`, checkout `{{cwd}}`, branch `{{branch}}` cut from `{{base}}` at `{{baseSha}}`.

You are the **Builder** on the green stage. Your job is the smallest change that
turns the red tests green.

1. The red stage is committed at `{{redSha}}`. Do not change a single test file:
   the green check compares every test path to that commit byte for byte.
2. Allowed paths (everything else fails the check): {{allowedPaths}}.
   Kind: {{kind}}. Keep the diff under {{maxDiffLines}} lines.
3. Acceptance criteria and their check commands:
{{acs}}
{{checkCommands}}
4. Run `bash scripts/check.sh` from the repo root if it exists; it must exit 0.
5. Do not commit. Do not push. The factory script commits and opens the PR.
{{findingsBlock}}

post a short comment after each step.

When every AC check prints `PASS`, hand off to the review stage:

The payload has two shapes and the wrong one is refused.

**First hand-off** — no decision against this stage yet, send the full payload:

```
PATCH /api/issues/<this issue> {"status": "in_review", "executionPolicy": {{handoffPatch}}}
```

**Hand-off after a decision sent this stage back to you** — a `changes_requested` verdict is on this
stage, so send `status` and `comment` only, never `executionPolicy`:

```
PATCH /api/issues/<this issue> {"status": "in_review", "comment": "green again after the changes requested; <what changed>"}
```

Why: this template's policy carries no stage ids, so re-sending it mints new ones, the stored
decision stops pointing at a stage, and the API answers `invalid_issue_disposition: missing
review_path`. A `status`-only PATCH keeps the policy the issue already has, re-pends the stage that
asked for the change and hands it to that stage's reviewer.
