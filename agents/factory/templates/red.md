# [red] {{workOrder}} — write the failing tests

Work order: **{{workOrder}}** — {{workOrderTitle}}
Repo: `{{repo}}`, checkout `{{cwd}}`, branch `{{branch}}` cut from `{{base}}` at `{{baseSha}}`.

You are the **Tester** on the red stage. Your job is the failing test, not the fix.

1. Read the work order's `spec` document if you can reach it. The spec allows
   only these paths: {{allowedPaths}}. Kind: {{kind}}.
   Acceptance criteria:
{{acs}}
2. Write or extend tests only. A changed path that is not a test path fails the
   red check: only paths with a `tests`/`test` segment or a `*.test.*` /
   `*_test.*` / `test_*.py` basename are allowed. Do not touch production code.
3. Run the acceptance-criteria check commands yourself and confirm every one of
   them reports `FAIL` on the new tests:
{{checkCommands}}
4. Do not commit. Do not open a PR. The factory script commits the red stage.

post a short comment after each step.

When the tests fail for the right reason, hand off to the review stage:

The payload has two shapes and the wrong one is refused.

**First hand-off** — no decision against this stage yet, send the full payload:

```
PATCH /api/issues/<this issue> {"status": "in_review", "executionPolicy": {{handoffPatch}}}
```

**Hand-off after a decision sent this stage back to you** — a `changes_requested` verdict is on this
stage, so send `status` and `comment` only, never `executionPolicy`:

```
PATCH /api/issues/<this issue> {"status": "in_review", "comment": "red tests updated after the changes requested; <what changed>"}
```

Why: this template's policy carries no stage ids, so re-sending it mints new ones, the stored
decision stops pointing at a stage, and the API answers `invalid_issue_disposition: missing
review_path`. A `status`-only PATCH keeps the policy the issue already has, re-pends the stage that
asked for the change and hands it to that stage's reviewer.
