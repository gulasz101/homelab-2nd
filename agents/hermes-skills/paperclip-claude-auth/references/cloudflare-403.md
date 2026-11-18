# 403 "Attention Required! | Cloudflare" — block, not logout

Symptom: run ends in `claude_auth_required`, agent latches `error` with

```
ACP agent reported a terminal access failure.
Failed to authenticate. API Error: 403 Attention Required! | Cloudflare
```

The `Attention Required! | Cloudflare` HTML page is served by Cloudflare before the request reaches
Anthropic. Claude Code retries 5xx/429 and does **not** retry 403, so the ACP session dies; the
adapter then maps "Failed to authenticate" to `claude_auth_required` and the board reads "logged out".

## Order of checks (do not rotate anything first)

1. Was the token working minutes earlier? A failed run that wrote for 20+ minutes means the credential
   lived that long — the block hit one request, not the login.
2. Live probe with the vaulted token, real CLI:

```bash
F=~/claude-code-oauth.sops.yaml
plain=$(sops --decrypt "$F")
tok=$(printf '%s\n' "$plain" | sed -n 's/.*\(sk-ant-[A-Za-z0-9_-]*\).*/\1/p' | head -1)
cd /tmp && CLAUDE_CODE_OAUTH_TOKEN="$tok" claude -p "Reply with exactly: PONG" \
  --model claude-opus-5-5 --permission-mode bypassPermissions
```

`PONG` = the credential is fine, stop looking for a login problem. Never print `$tok`.
3. Raw API probe: with the right UA a real error body (`rate_limit_error`, `invalid_request_error`)
   proves Cloudflare is not blocking this IP. A fake/old UA answers `claude_code_version_too_old` —
   that is the API talking, also not a block.

## Recovery

`error` is a latch, not a lock (`agent-invokability` blocks only paused/terminated/pending_approval),
so any new run of that agent clears it. For an agent with `heartbeat.enabled: false` nothing wakes it
by itself, and the PM's sweep will not wake it on a provider/auth failure — it escalates to the owner
with "must re-authenticate", which is wrong when the token is proven good.

Agent-legal retry of the dead run (no new assignment, no comment on the agent's issues):

```bash
curl -s -X POST "$PAPERCLIP_API_URL/api/agents/<agentId>/wakeup" \
  -H "Authorization: Bearer $PAPERCLIP_API_KEY" -H 'content-type: application/json' \
  -d '{"source":"on_demand","triggerDetail":"system","reason":"retry_failed_run",
       "failedRunId":"<runId>","forceFreshSession":false}'
```

`202` with a queue receipt; then watch `heartbeat_runs` for the new run. Pass `failedRunId` — caller
markers and fresh-session overrides do not authorise a replay of another principal's run.

**An agent key cannot wake a different agent**: the route answers `403 {"error":"Agent can only
invoke itself"}`. If the latch belongs to another agent you do not own, the retry has to come from a
board actor (Wojtek, one click on the failed run) — or wait for the PM's next assignment, because
`error` does not block invocation.

## Preventing the repeat

Two overlapping sessions on one subscription token (`heartbeat.maxConcurrentRuns: 2`) from one IP is
the most likely trigger; `maxConcurrentRuns: 1` removes it. The permanent fix is upstream: classify a
403 carrying a Cloudflare interstitial as `provider_transient` in
`server/src/services/recovery/provider-failure-classification.ts`, not `claude_auth_required`.
