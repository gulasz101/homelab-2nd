# ADR-078: Star Office ingest tokens live in the database registry; the env map is gone

**Date:** 2026-10-21
**Status:** Accepted
**Deciders:** Wojtek Gula; implemented by Andrzej (GUL-76)
**Project:** homelab-2nd / star-office
**Related:** ADR-035 (event schema v1), ADR-037 (Mail-Archiver storage model)

## Context

The SOU ingest face (`POST /events`) used to authorise per-agent with a hashes-only map
`sha256(token) -> agent` carried in the `sou-ingest-tokens` Secret. GUL-76 opened because
`hermes-zdzislaw` pushed successfully while being absent from that map, which smelled like an
undocumented second authorisation path.

It was one, but not the one the map was supposed to be. The upstream SOU project moved the
registry **into the database** in SOU-291 (migration `004_agent_registry`, image v2.3.0+): the
`ingest_tokens` table holds `sha256(token) -> agent`, supports revocation (`revoked_at`) and
rotation (several tokens per agent), and `docs/public-lodge.md` in the fork says of the old
variable:

> **Deprecated: `SOU_INGEST_TOKENS`.** The old env map ... is still read as a second source.
> Move it into the database with `tokens.py import-env`, then drop the variable.

The homelab never finished that migration. The Deployment still set
`SOU_INGEST_TOKENS=/run/secrets/sou/tokens.json`, so the live code had two sources, and the
**order** is the problem (`backend/app.py`, `token_agent_for()`):

```python
def token_agent_for(store, token):
    agent = store.lookup(token)                      # deprecated env map answers FIRST
    if agent is not None:
        return agent
    with db.session_scope() as session:
        row = db.agent_for_token_hash(session, ingest_auth.hash_token(token))   # DB second
        return row.name if row is not None else None
```

The env map has no revocation concept, so for every agent whose digest was still in the map,
the map **shadowed** the database: `tokens.py revoke <agent>` set `revoked_at` in the table and
the token kept working. Measured on the live cluster before this change: revoking
`hermes-andrzej`'s row in the database and then pushing still returned `201`. The documented
kill-switch for a leaked token was a no-op for 8 of the 14 registered agents.

The map was also stale: it held 8 of the 14 agents (missing `hermes-zdzislaw`, `hermes-matejko`
at the time, `itsaplan-h2`, `itsaplan-sou`, `opencode-air`, `opencode-laptop`, `pi`), and the
SOPS file was simultaneously the thing that looked authoritative and the thing that was wrong.
Two lists, no cross-check — that is how `hermes-zdzislaw` came to look unauthorised.

The database is the complete registry (14 active rows) and it is backed up: the CNPG base
backup contains the `ingest_tokens` relation (relfilenode `base/16385/16442`) with all 14
digests, and WAL archiving to OMV MinIO covers the window between backups.

## Decision

**One authorisation path: the database registry.** The `SOU_INGEST_TOKENS` variable, the
`/run/secrets/sou/tokens.json` volume mount and the `sou-ingest-tokens` Secret are removed from
the Deployment and from the repo.

- `SOU_MODE=ingest` with no `SOU_INGEST_TOKENS` builds an **empty** store, not an open one:
  the door stays locked (`401` for an unknown token) and only registered database digests open
  it. The lockdown is the upstream contract, not a homelab tweak.
- The registry is not git-managed and does not need to be: it is runtime state of a durable
  store, backed up to OMV MinIO like every other database in the estate (ADR-037 shape). Each
  agent also holds its own plaintext token in its reporter config, so a lost binding is
  recoverable by re-registering that agent.
- Revocation now works, because there is no map left to shadow the table.

The repo stops advertising a second path, so the next engineer cannot mistake the Secret for
the source of truth and cannot "helpfully" restore it.

## Consequences

- `hermes-zdzislaw` is authorised by the database row that has always authorised it
  (`sha256(token)[:12] = 286909a89678`). Nothing about zdzislaw changes; what changes is that
  there is no longer a second, stale list to contradict it.
- `tokens.py revoke <agent>` is now effective for every agent. Before this change it silently
  did nothing for the 8 agents in the map.
- A new agent is registered with `tokens.py register <agent>` (mints a token, prints it once,
  stores only its digest) — upstream's path, and the one the fork documents. The plaintext goes
  to that agent's reporter, never into git.
- The `sou-ingest` Deployment no longer mounts a Secret, so the `secret-version` annotation
  from GUL-74 PR #10 no longer has a token map to refresh. It is kept and re-pointed at the
  `star-office-db-credentials` `secretKeyRef`, which has the same staleness property (env vars
  sourced from a Secret do not refresh in a running container either).
- A stale registry in the cluster can no longer be masked by a second list. The single list is
  the one that can be read back and checked.
- The registry is no longer recoverable by `kubectl apply` of a Secret. It is recoverable by a
  CNPG restore, or by re-registering the affected agent. Losing the whole database is a
  bigger event than losing a Secret, and it is backed up.

## Alternatives considered

- **Bind `hermes-zdzislaw` in the SOPS map and keep both paths** (the literal reading of the
  ticket). Rejected: it perpetuates the shadowing bug and extends it to zdzislaw, keeps two
  lists that drift, and leaves `tokens.py revoke` broken.
- **Make the database lose to the map** (reverse the lookup order). Rejected: that needs a code
  change in the upstream fork, and it preserves the old, revokeless model as the authority.
- **Keep the Secret as a git-tracked recovery ledger but stop the app reading it.** Rejected:
  the ledger is a hand-maintained duplicate of a database table and is already proven stale
  (8 of 14 agents). A second copy that is never compared to the first is a drift magnet, and
  it is precisely the failure mode this ADR removes. Recovery uses the CNPG backup.
- **Keep the Secret and make the database authoritative by deleting the map's rows.** Rejected:
  the rows are already in the database; deleting the Secret is the same change with less work.

## When to revisit

- If the upstream fork ever removes the `SOU_INGEST_TOKENS` code path entirely, this ADR's
  "remove the variable" step becomes a no-op and the Secret must stay deleted.
- If a second ingest face is added that cannot reach the CNPG database, it needs its own
  registry and this ADR does not cover it.
- If the token registry ever has to be reproducible from git alone (for example a cluster
  rebuild that must not restore the database), the answer is a declared, generated artefact —
  not a hand-maintained Secret next to the workload.
