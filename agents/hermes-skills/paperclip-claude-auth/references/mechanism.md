# Claude Code AI connections in Paperclip

How a `claude_local` agent gets its credential, and why subscription connections expire.

## The two auth paths

- **Anthropic subscription** (`aiConnection.mode: responsible_user`, `provider: anthropic`,
  `method: subscription`): the server exports one value as `CLAUDE_CODE_OAUTH_TOKEN` and nothing
  else. `ai-connection-runtime.js` computes
  `subscriptionFile = method === "subscription" && provider !== "anthropic"`, so Anthropic is the
  only provider with **no** credential file in the managed home and therefore **no write-back** at
  run end. `local-ai-credentials.js` captures only `claudeAiOauth.accessToken` at Connect time and
  discards the refresh token.
- **API key** (`method: api_key`): `ANTHROPIC_API_KEY`. Validated against the provider, so a setup
  token is rejected here.

## What that means in practice

A subscription connection is one ~8 h access token. Every run more than ~8 h after the last login
fails `claude_auth_required` (`OAuth session expired and could not be refreshed`), and the server
marks the grant `needs_reauthorization` and the connection health `error`. Do not diagnose this as a
refresh race with an interactive CLI: managed runs never read `~/.claude`, and `claude auth status`
reads only that file, so it is never a valid health test. The health signal is the newest *finished*
run for the agent.

## The durable fix: a setup token

`claude setup-token` mints `sk-ant-oat01-…` valid about a year, and it *is* what the server exports
as `CLAUDE_CODE_OAUTH_TOKEN`, so it drops into the existing connection with no adapter, server or
restart change.

Order matters:

1. Connect / sign in once. Only that flips `connection_grants.status` to `active` and
   `tool_connections.health_status` to `ok`; `select()` refuses a run otherwise.
2. Rotate the user-scoped `ai.credential` secret to the setup token
   (`POST /api/companies/:companyId/me/user-secrets/:secretId/rotate`, body `{"value": "…"}`).
   Owner/board only; an agent key is refused. Rotate after Connect, because Connect writes its own
   fresh access-token version.
3. The grant's credential ref is `versionSelector: "latest"`, so the next run picks it up.

## Proving it without printing the value

`company_secret_versions.value_sha256` is `sha256(utf8 value)`. Compare it with the digest of the
SOPS copy instead of ever echoing either: `host/paperclip-air/bin/homelab-claude-token-store.sh` in
the homelab-2nd repo does exactly that. The repo's `.sops.yaml` has
`encrypted_regex: ^(data|stringData)$`, so a host secret must be shaped as a Kubernetes Secret or the
value stays in the clear.

Related: homelab-2nd ADR-110, and RUNBOOK §5a/§5b under `host/paperclip-air/`.
