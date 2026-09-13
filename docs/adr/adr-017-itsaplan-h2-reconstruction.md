# ADR-017: Itsaplan H2 is reconstructed through its own API with historical ids; API keys are re-seeded by hash

**Status:** Accepted
**Date:** 2026-09-13

## Context

On 2026-09-11 ~22:29 the `itsaplan` CNPG database was wiped (post-wipe initdb). By
2026-09-13 every table was empty: `apikey`=0, `user`=0, `project`=0, `project_column`=0,
`issue_type`=0, `issue`=0. The app (`itsaplan` v0.17.0, chart 0.1.0, pinned to `arr-box`)
was otherwise healthy, but:

- `itsaplan-api` threw `APIError: Invalid API key.` on the agent API-key path,
- `itsaplan-andrzej-runner` logged `POST /agent-runs/claim failed with 500` and never
  claimed a task,
- the project **H2 (`homelab-2nd`)**, its columns, the Andrzej agent, the admin user and
  all issues were gone.

Constraint that shaped the decision: the **Mac Hermes is healthy and unreachable by SSH**.
Its MCP token (`MCP_ITSAPLAN_API_KEY`, an `itp_…` personal key) lives only in the Mac
`.env`; if the token changed, the bridge would need a change on the Mac that cannot be made
from the homelab. The token therefore had to be made valid again *as-is*.

Recovery inputs from outside the database:

- Obsidian vault tracking notes (canonical per-issue write-ups) + `hermes_sessions/`
  archives: full issue titles, the deleted-test-issue provenance, the H2-12 description.
- Hermes backup `~/hermes-copy/profiles/andrzej/state.db` (4,405 sessions / 97,309
  messages): the raw `list_issues`/`get_issue` JSON (identifiers, ids, column ids),
  `get_project` (columns Backlog=6/Todo=7/In Progress=8/Done=9/Canceled=10, issue types
  Feature=2…Research=6), and the add/update call arguments.
- The itsaplan source at tag `v0.17.0` and the live OpenAPI at `/docs/json`.

## Decision

1. **Reconstruct through the app's own API, not raw SQL rows.** A throwaway first user
   (`admin@voitech.dev`, auto-role `god`) signs up; then `POST /projects` (key `H2`,
   `preset: software`) seeds the default columns and the exact issue-type set. This keeps
   roles, memberships and views internally consistent.
2. **Remap ids to the historical values.** Columns `1..5 → 6..10` and issue types
   `1..5 → 2..6` with a two-step `+100` / `-N` SQL offset (a one-step `+k` collides with
   the primary key mid-update), then `setval` the sequences. This preserves the `columnId`
   7/8/9 that the Mac webhook prompt hardcodes.
3. **Re-seed the Mac's personal MCP key by hash.** better-auth stores api keys as
   `base64url(sha256(key))` (43 chars, no padding) in `apikey.key`; the plugin here uses
   `defaultPrefix: itp_` and no raw storage. Insert an `apikey` row whose `key` is that
   hash of the existing Mac token, `reference_id` = the god user, `config_id = 'default'`,
   `expires_at = NULL`. **No change on the Mac.**
4. **Rotate the runner's external-agent key through the API.** `POST
   /projects/H2/ai-agents` returns the agent key once (external agents are not stored
   encrypted). Put it in SOPS `itsaplan-andrzej-agent-key` and let Flux + a deployment
   restart roll it out. The runner's `WEBHOOK_URL`/`WEBHOOK_SECRET` are unchanged (the
   secret already matched the Mac subscription).
5. **Restore auth posture via `/god`:** OIDC enabled (`auth.voitech.dev/application/o/itsaplan`),
   `registration: closed`, `emailPassword: false`, `magicLink: false` — i.e. SSO-only, as
   in ADR-001 (Itsaplan Authentik OIDC).
6. **Recreate the issues in sequence.** H2-1…H2-12 plus the two test-issue artifacts, in
   order, so `sequence_number` matches `identifier`; descriptions synced from the vault
   notes (canonical), H2-12 carrying its recovered full body; `next_sequence` left at 13.

## Consequences

**Positive**

- The Mac↔Itsaplan bridge is alive end-to-end: delegate → runner claims → HMAC webhook to
  `192.168.1.148:8644` → Mac Hermes runs → comment + column move. Verified on H2-13
  (`agent_run.id=1 status=success`, webhook `{"status":"accepted","route":"itsaplan-andrzej"}`).
- The Mac's MCP token survives untouched; only the k3s-side runner key changed (SOPS).
- Historical ids are preserved where they matter (columns 7/8/9), so the Mac prompt, the
  security-scan sync (`stateType: backlog`) and the Obsidian↔issue mapping all keep working.
- Reconstruction is reproducible from versioned/archived artifacts.

**Negative**

- Original row ids for users, the project and the agent are new (project id 1, admin id
  random). Only the *column* and *issue-type* ids were preserved. Anything hardcoding the
  old admin/agent user UUIDs would break; nothing does.
- The god user is `admin@voitech.dev`; it links to Authentik `akadmin` on first SSO login.
  A user whose Authentik email differs would land as a plain `user` and need promotion.
- H2-10/H2-11 titles were never persisted (they were created then deleted); they are
  best-effort reconstructions.
- The Mac personal key and the runner agent key remain full-account credentials; blast
  radius is the itsaplan instance.

## Alternatives considered

- **Restore the CNPG database from backups.** Impossible: both backups post-date the wipe.
- **Raw-SQL seed of every table.** Rejected: misses role/membership/view side rows and
  better-auth account rows, and risks a subtly broken UI.
- **Rotate the Mac MCP token and update the Mac.** Rejected: no SSH to the Mac; the hash
  re-seed keeps the token valid and required no remote change.
- **Hand-seed column/type ids by pre-creating throwaway rows.** Rejected in favour of the
  deterministic two-step `UPDATE` + `setval`.
- **Leave email/password enabled during rebuild.** Kept temporarily for the API session,
  then disabled to restore the SSO-only posture.

## When to revisit

- If itsaplan changes its api-key storage (better-auth `hashKey`/`storeApiKey`), the hash
  re-seed recipe changes with it.
- If itsaplan adds a supported import/export that preserves ids and keys, prefer it.
- If the Mac is ever SSH-reachable, rotating tokens becomes a one-line task and the
  hash-seed trick is no longer needed.
- If a pre-wipe itsaplan backup ever appears (another bucket/generation), prefer a real
  restore over reconstruction.
