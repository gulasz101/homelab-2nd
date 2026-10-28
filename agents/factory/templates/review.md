# [review{{roundSuffix}}] {{workOrder}} — review the green diff

Work order: **{{workOrder}}** — {{workOrderTitle}}
Repo: `{{repo}}`, checkout `{{cwd}}`, branch `{{branch}}`.

You are the **Reviewer**. Judge the diff from `{{baseSha}}` to the working tree,
not the description of it.

1. Read `git diff {{baseSha}}` and the files it touches. Allowed paths for this
   work order: {{allowedPaths}}. Anything outside them is a finding.
2. File findings in the `findings` document on THIS issue, as markdown plus
   exactly one fenced `json` block (see `agents/factory/CONTRACT.md` point 3):
   `{"id": "F-1", "file": "path", "line": 12, "severity": "blocking|minor", "claim": "one sentence"}`
   An empty list means you found nothing worth blocking. Be concrete: a claim
   without a file and a line is a finding the script rejects.
3. Do not edit code and do not commit. Review only. The factory script decides
   the stage from your document.

Post a short comment after each step, **before** the hand-off; this role cannot post a comment
through the API, so the short comments are for the write stages and your report goes in the hand-off.
The hand-off is the last call of this run: it reassigns the issue and Paperclip cancels the sending
run, so nothing you send afterwards lands. Its `comment` is the report.

When the findings document is written, hand off to the verify stage:

The payload has two shapes and the wrong one is refused. Both carry the report in `comment`.

**First hand-off** — no decision against this stage yet, send the full payload:

```
curl -s -X PATCH "$PAPERCLIP_API_URL/api/issues/$PAPERCLIP_TASK_ID" \
  -H "Authorization: Bearer $PAPERCLIP_API_KEY" \
  -H "X-Paperclip-Run-Id: $PAPERCLIP_RUN_ID" \
  -H "Content-Type: application/json" \
  -d '{"status": "in_review", "executionPolicy": {{handoffPatch}}, "comment": "<the short report: the findings count and the blocking ones, one line each>"}'
```

**Hand-off after a decision sent this stage back to you** — a `changes_requested` verdict is on this
stage, so send `status` and `comment` only, never `executionPolicy`:

```
curl -s -X PATCH "$PAPERCLIP_API_URL/api/issues/$PAPERCLIP_TASK_ID" \
  -H "Authorization: Bearer $PAPERCLIP_API_KEY" \
  -H "X-Paperclip-Run-Id: $PAPERCLIP_RUN_ID" \
  -H "Content-Type: application/json" \
  -d '{"status": "in_review", "comment": "findings updated after the changes requested; <what changed>"}'
```

Why: this template's policy carries no stage ids, so re-sending it mints new ones, the stored
decision stops pointing at a stage, and the API answers `invalid_issue_disposition: missing
review_path`. A `status`-only PATCH keeps the policy the issue already has, re-pends the stage that
asked for the change and hands it to that stage's reviewer.
