# ADR-110: Claude Code runs on a setup token, because an Anthropic subscription connection cannot refresh

- **Status**: Proposed (owner sign-off outstanding)
- **Date**: 2026-10-31
- **Issue**: GUL-642 (follow-up to GUL-640, GUL-656, GUL-686)
- **Related**: ADR-106 (the current fleet model), ADR-107/108 (the Air's scheduled jobs)

## Context

The Claude Code PM agent (Paperclip agent `97efeb2d`, `claude_local` adapter, subscription auth) has
lost its login twice in five days — 2026-10-25 and 2026-10-30 — and both times the only fix was a
human typing `/login` on the Mac. The 2026-10-31 04:30Z PM round died 11 s in with
`claude_auth_required`.

The obvious suspect was the shared `~/.claude/.credentials.json`, held by an interactive TUI that has
been running since 24 Oct on an older CLI. **That suspect is dead.** A managed run never reads
`~/.claude`: the server builds a throwaway home per run. Worse, the file has been an empty stub
(`accessToken` and `refreshToken` empty, `expiresAt: 0`, mtime 30 Oct 05:30Z) while two runs
*succeeded* on 30 Oct.

What the server actually does with a subscription credential, read from the installed build
(`@paperclipai/server` 2026.1012.0):

- `packages/shared/.../ai-connections`: `anthropic.subscription.envKey = "CLAUDE_CODE_OAUTH_TOKEN"`.
- `services/ai-connection-runtime.js:185`: `subscriptionFile = method === "subscription" && provider !== "anthropic"`.
  For **every other** provider a credential *file* is written into the managed home and the file is
  read back at run end so a refresh can be written into the vault (line 256 onward). For Anthropic
  the file branch is skipped and the value is exported as an env var (line 224).
- `services/local-ai-credentials.js:31`: at Connect time the server keeps **only**
  `claudeAiOauth.accessToken`. The refresh token is read from the login home and thrown away.

So an Anthropic subscription connection is a single ~8 h access token with no refresh token and no
write-back path. Its expiry is terminal by design, not by accident. That matches the observed
timeline exactly: minted 2026-10-30 13:39Z, two clean runs inside the window (18:18Z, 20:21Z), dead
at 04:30Z ~15 h later. The vault secret is still version 1; no write-back has ever happened because
for Anthropic there is no code path that could.

The consequence is not "a twice-a-week annoyance": the daily 05:30Z PM round cannot run at all
unless a human logged in within the previous eight hours.

## Decision

1. **The vault credential becomes a long-lived setup token, not an access token.** `claude setup-token`
   (installed CLI 2.1.314: *"Set up a long-lived authentication token (requires Claude subscription)"*)
   prints an `sk-ant-oat01-…` token with roughly a one-year life. A setup token is exactly the value
   the server already exports as `CLAUDE_CODE_OAUTH_TOKEN`, so it is a drop-in for the existing
   connection: no adapter change, no server patch, no restart.
2. **Delivery is a secret rotation, in this order:** Connect/sign in once (the only step that flips
   the grant back to `active` and the connection health to `ok`), **then** rotate the user-scoped
   `ai.credential` secret to the setup token. Rotate only after Connect, because Connect writes its
   own fresh access-token version and would overwrite the setup token.
3. **Nothing about the runtime changes.** `connection_grants.credential_secret_refs` selects
   `versionSelector: "latest"`, so the rotated value is picked up by the next run automatically.
4. **The secret stays in the two vaults that already exist.** Paperclip's own encrypted secret store
   (`local_encrypted`, user-scoped to the owner) is the operational copy; the SOPS file under
   `host/paperclip-air/secrets/` is the copy that survives a Paperclip rebuild. Equality is proven by
   comparing SHA-256 digests (`company_secret_versions.value_sha256` is `sha256(utf8 value)`), never by
   printing either side.
5. **The acceptance test is two consecutive 05:30Z runs succeeded** with no re-login. `claude auth
   status` is *not* the test: it reads `~/.claude`, which no managed run touches (GUL-661).

## Consequences

- The PM round survives a week of silence from the human. That is the whole point of the ticket.
- One token now carries a year of authority instead of eight hours of it. It is owner-scoped, sits in
  an encrypted store and is revocable from the Claude account; but it is also a single long-lived
  credential, so it belongs in the vault list that gets reviewed, not in a shell history.
- The `Connect Anthropic` card stays necessary but only as an activation step, roughly once per token.
- Anyone reading this later must not "simplify" by rotating an access token from `claude auth login`
  into the secret: that reintroduces the 8 h cliff.

## Alternatives considered

- **Kill the interactive TUI / delete `~/.claude/.credentials.json`** (the original option 2). Rejected
  on evidence: the managed run never reads that file, and it was a stub while runs were succeeding.
  There is no refresh race between the TUI and the run — there is no refresh at all.
- **Patch Paperclip to write the refreshed credential back for Anthropic.** Rejected for now: the
  write-back branch exists for other providers, but Anthropic's flow never captures a refresh token
  or a credential file, and the server is a third-party npm bundle, not our source. Revisit if upstream
  implements it; our setup token keeps working either way.
- **An Anthropic API key through the connection (`method: api_key`).** The provider validates the key
  against the API and a setup token is not an API key, so this path rejects it — and an API key would
  move the agent off the subscription onto per-token billing.
- **A Claude route in LiteLLM (option 3).** `https://llm.voitech.dev/v1/models` exposes no Opus route
  for the local key (checked 2026-10-30). Building one means curating a route and paying per token.

## When to revisit

- The setup token approaches ~11 months of age (expect first mint 2026-10-31 → renew before 2027-10).
- Paperclip gains refresh-token capture plus write-back for Anthropic subscriptions; then the setup
  token becomes optional rather than necessary.
- The subscription lapses, or Anthropic changes what `CLAUDE_CODE_OAUTH_TOKEN` accepts.
