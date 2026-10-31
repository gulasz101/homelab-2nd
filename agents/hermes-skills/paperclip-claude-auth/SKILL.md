---
name: paperclip-claude-auth
description: >
  Use when a Claude Code agent in Paperclip loses its login or a run fails with
  claude_auth_required, and when rotating that connection's credential. Covers
  the Anthropic subscription path, the setup-token fix and the order of steps.
---

# Paperclip Claude auth

An Anthropic **subscription** AI connection hands `claude_local` exactly one value, as
`CLAUDE_CODE_OAUTH_TOKEN`, and the server keeps no refresh token and has no write-back for that
provider. So the connection dies about 8 hours after each login, by design. The fix is a
`claude setup-token` value rotated into the same secret — see
[references/mechanism.md](references/mechanism.md) for the code evidence.

## Procedure

1. **Check the right signal.** Newest *finished* run for the agent (`heartbeat_runs`), not
   `claude auth status` (that reads `~/.claude`, which managed runs never touch) and not the agent
   row (its `errorReason` is sticky).
2. **Reconnect once.** Connect / sign in is the only thing that flips `connection_grants.status` to
   `active` and `tool_connections.health_status` to `ok`. `select()` refuses a run otherwise.
3. **Rotate, after the reconnect.** `claude setup-token` mints `sk-ant-oat01-…` (~1 year); rotate the
   user-scoped `ai.credential` secret with it (`POST /api/companies/:id/me/user-secrets/:id/rotate`,
   `{"value": "…"}`). Owner/board only. Rotating first gets overwritten, because Connect writes its
   own access-token version.
4. **Verify without printing.** `company_secret_versions.value_sha256` is `sha256(utf8 value)`.
   `host/paperclip-air/bin/homelab-claude-token-store.sh --verify` compares it with the SOPS copy and
   prints `MATCH` plus the version number.
5. **Acceptance.** Two consecutive managed runs succeeded after the rotation. One morning cannot
   prove it: the daily round is one run.

## Traps

- Never mark a subscription connection `method: api_key` to "stabilise" it: the provider validates a
  key, rejects a setup token, and it moves the agent onto per-token billing.
- The grant's credential ref is `versionSelector: "latest"`, so a rotation needs no other change and
  no restart.
- Do not read, print or paste the credential. Digest comparison only.
