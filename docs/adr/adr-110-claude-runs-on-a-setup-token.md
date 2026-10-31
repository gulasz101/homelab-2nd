# ADR-110: Claude Code runs on a setup token, because an Anthropic subscription connection cannot refresh

- **Status**: Proposed (owner sign-off outstanding)
- **Date**: 2026-10-31
- **Issue**: GUL-642 (follow-up to GUL-640, GUL-656, GUL-686); amended by GUL-691 (one-command
  rotation, drift detection)
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
   - **That overwrite is the trap this ADR keeps biting on.** Accepting a Connect card writes a new
     vault version with an ~8 h access token and leaves the SOPS copy untouched; the grant reads
     `versionSelector: "latest"`, so the very next 05:30 round authenticates with the wrong
     credential and dies. Before GUL-691 nothing noticed until the round failed. The drift check in
     `host/paperclip-air/bin/homelab-lib.sh` (`claude_token_state`) compares the two digests daily and
     alerts with the fix command; that is the detector for this trap, not the run failure.
3. **Nothing about the runtime changes.** `connection_grants.credential_secret_refs` selects
   `versionSelector: "latest"`, so the rotated value is picked up by the next run automatically.
4. **The secret stays in the two vaults that already exist.** Paperclip's own encrypted secret store
   (`local_encrypted`, user-scoped to the owner) is the operational copy; the SOPS file under
   `host/paperclip-air/secrets/` is the copy that survives a Paperclip rebuild. Equality is proven by
   comparing SHA-256 digests (`company_secret_versions.value_sha256` is `sha256(utf8 value)`), never by
   printing either side.
5. **The acceptance test is two consecutive 05:30Z runs succeeded** with no re-login. `claude auth
   status` is *not* the test: it reads `~/.claude`, which no managed run touches (GUL-661).

## One command from the Air (GUL-691)

The rotation used to be a board-UI step plus a digest check, because the route was documented as
owner-only. It is drivable from the Air, with one credential stored once:

- `POST /api/companies/:companyId/me/user-secrets/:secretId/rotate` calls `assertBoard(req)`
  (`@paperclipai/server` 2026.1012.0, `dist/routes/secrets.js:678-683`).
- `assertBoard` checks only `req.actor.type === "board"` (`dist/routes/authz.js:23-27`).
- A bearer that `boardAuth.findBoardApiKeyByToken()` recognises becomes
  `{type: "board", userId: <key owner>, source: "board_key"}` (`dist/middleware/auth.js:239-253`);
  board keys are `pcp_board_<48 hex>` (`dist/services/board-auth.js:17-19`) and expire after 30 days
  unless created with another `expiresAt`.

So the owner is a **board API key in SOPS** away from one command; an agent key still gets 403, and
stays that way on purpose. `host/paperclip-air/bin/homelab-claude-token-store.sh --rotate` takes the
token on stdin, writes the SOPS copy, POSTs it with the bearer on a file descriptor and the body on
stdin (never argv, so `ps` cannot see it), then prints `MATCH … version N`.

The server's own `claude setup-token` login route is not a path here: it requires
`options.setupTokenLogin` (a sandbox login transport), which is null on this instance, so it answers
`503` (`dist/routes/agents.js:317`, `:5595-5608`).

**What the shape guard can and cannot do.** It accepts only `sk-ant-oat01-…` and names an
`sk-ant-api03-…` key as the wrong thing (per-token billing). It cannot tell a *setup* OAuth token
from a *Connect* OAuth token of the same family — both are `sk-ant-oat…`, and the CLI itself only
tests the `sk-ant-oat` prefix. That is exactly why the digest comparison, not the shape, is the
detector for a Connect overwrite.

## Monitoring (GUL-691)

`hermes-memory-watchdog.sh` grew a `check9b` next to the auth check:

- daily (hourly daemon, 24 h alert dedupe) digest comparison of the SOPS copy against the newest live
  `company_secret_versions` row: `mismatch` = the credential is no longer the setup token;
- shape assertion on the SOPS value: `badshape`;
- the mint date (`~/.config/homelab/claude-token-mint`, metadata only) drives `expiring` at 30 days
  left and `expired` after the year;
- unknown is never green and never pages: a missing SOPS copy or an unreadable vault is logged, not
  alerted.

Alerts go out on the same channel as the other watchdog conditions (GUL-641), and every message
carries the exact fix command. No new channel, no new secret.

**The mint date is only as good as the path that wrote it.** `--rotate` records it on the way past,
because it holds the fresh token at that moment. The manual fallback in RUNBOOK §5b does not: a person
pastes a value into the Paperclip UI and this host never sees it, so the file keeps whatever date the
last successful `--rotate` wrote — and a stale date is worse than a missing one, because it makes a
year-old token look fresh. `--record-mint` is the one step that makes the fallback an aged credential.
A missing file stays survivable and honest: the check reads `ok:vN` with no days-left figure and makes
no expiry claim rather than inventing one. Whoever adds a third rotation path owes it a `write_mint`.

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
