## Your job: [review{{roundSuffix}}] {{workOrder}} — review the diff

Work order: **{{workOrder}}** — {{workOrderTitle}}
Repo `{{repo}}`, branch `{{branch}}`.

First: `cd "$PAPERCLIP_WORKSPACE_CWD"`. That folder is this work order's own git
worktree (`{{worktree}}`). Read only; change nothing there.

You are the **Reviewer**. Judge the diff from `{{baseSha}}` to the working tree,
not the description of it.

1. Read `git diff {{baseSha}}` and the files it touches. Allowed paths:
   {{allowedPaths}}. Anything outside them is a finding.
   Acceptance criteria:
{{acs}}
2. Each finding is exactly one object:
   `{"id": "F-1", "file": "path", "line": 12, "severity": "blocking|minor", "claim": "one sentence"}`
   `file` must be a path in that diff and `line` must exist in its new version,
   or the factory rejects the document. An empty list means nothing to block.
3. Do not edit code and do not commit. The factory decides from your document.

Write the `findings` document on this issue: markdown plus exactly one fenced
`json` block with the list. The `-d` value is one JSON string, so newlines in the
markdown are `\n` and inner quotes are `\"`. Do it in one call:

```
curl -s -X PUT "$PAPERCLIP_API_URL/api/issues/$PAPERCLIP_TASK_ID/documents/findings" \
  -H "Authorization: Bearer $PAPERCLIP_API_KEY" \
  -H "X-Paperclip-Run-Id: $PAPERCLIP_RUN_ID" \
  -H "Content-Type: application/json" \
  -d '{"title": "findings", "format": "markdown", "body": "# Findings\n\n```json\n[]\n```\n"}'
```

A `409` means the document already exists: GET it, then send the same PUT with
`"baseRevisionId": "<latestRevisionId>"` added.

Then end the run with this one call. It is the last thing you do; the comment is
your report:

```
curl -s -X PATCH "$PAPERCLIP_API_URL/api/issues/$PAPERCLIP_TASK_ID" \
  -H "Authorization: Bearer $PAPERCLIP_API_KEY" \
  -H "X-Paperclip-Run-Id: $PAPERCLIP_RUN_ID" \
  -H "Content-Type: application/json" \
  -d '{"status": "done", "comment": "<short report: the findings count and the blocking ones, one line each>"}'
```
