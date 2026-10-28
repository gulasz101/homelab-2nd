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

When the tests fail for the right reason, hand off to the review stage exactly:

```
PATCH /api/issues/<this issue> {"status": "in_review", "executionPolicy": {{handoffPatch}}}
```
