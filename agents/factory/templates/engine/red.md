## Your job: [red{{roundSuffix}}] {{workOrder}} — write the failing tests

Work order: **{{workOrder}}** — {{workOrderTitle}}
Repo `{{repo}}`, branch `{{branch}}`, cut from `{{base}}` at `{{baseSha}}`.

First: `cd "$PAPERCLIP_WORKSPACE_CWD"`. That folder is this work order's own git
worktree (`{{worktree}}`). Work only there.

You are the **Tester**. Your job is the failing test, not the fix.

1. Allowed paths: {{allowedPaths}}. Kind: {{kind}}.
   Acceptance criteria:
{{acs}}
2. Write or extend tests only. A changed path that is not a test path fails the
   red check: only paths with a `tests`/`test` segment or a `*.test.*` /
   `*_test.*` / `test_*.py` basename count. Do not touch production code.
3. Spend your turns on files, not on re-discovery. The turn cap is 60 per run.
   Read the check commands once, then write. If a check needs fixture data,
   build it at check time from one helper inside the test path instead of one
   fixture file per criterion. Write files with a few heredoc calls
   (`cat > path <<'EOF'`). A path the spec allows but that does not exist yet is
   normal here: create it.
4. Run every check command yourself and confirm each one reports `FAIL`:
{{checkCommands}}
5. Your tests run in two places: on this Mac and in GitHub CI (Linux, `HOME` is
   `/home/runner`, a fresh checkout at another path). They must give the same
   result in both. So a test must not read or compare `$HOME`, `~`, `/Users/...`,
   `/home/...`, the user name, the host name, or any file outside the repo.
   Build paths from the repo root (`git rev-parse --show-toplevel`) or from a
   temp folder made with `mktemp -d`.
6. Do not commit, do not push. Leave your changes uncommitted: the factory
   checks the worktree and commits the red stage itself.

When the tests fail for the right reason, end the run with this one call. It is
the last thing you do; the comment is your report:

```
curl -s -X PATCH "$PAPERCLIP_API_URL/api/issues/$PAPERCLIP_TASK_ID" \
  -H "Authorization: Bearer $PAPERCLIP_API_KEY" \
  -H "X-Paperclip-Run-Id: $PAPERCLIP_RUN_ID" \
  -H "Content-Type: application/json" \
  -d '{"status": "done", "comment": "<short report: what the tests cover and which AC checks now FAIL>"}'
```
