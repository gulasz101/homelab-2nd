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

When every AC check prints `PASS`, hand off to the review stage exactly:

```
PATCH /api/issues/<this issue> {"status": "in_review", "executionPolicy": {{handoffPatch}}}
```
