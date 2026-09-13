# ADR-016: Karakeep state is reconstructed from vault manifests + Hermes history; back up before the thing you want to protect

**Status:** Accepted
**Date:** 2026-09-13

## Context

On 2026-09-11 the arr-stack/CNPG recovery prune cascade (ADR-012/ADR-014) also wiped Karakeep's data: after the outage its SQLite database held **0 bookmarks, 0 tags, 0 lists, 0 RSS feeds, 0 API keys**. The only surviving user was the admin account created by a fresh Authentik SSO login.

Two consequences surfaced on 2026-09-13:

1. **No usable backup existed.** The daily `karakeep-backup` CronJob (`s3://karakeep-backups/karakeep/db-<ts>.db`) had only started producing objects on **2026-09-12**, i.e. *after* the wipe. Every stored `db-*.db` was the empty 585 KB database. There was nothing to restore.
2. **The Hermes API key was dead.** The key (`ak2_…`) belonged to a user row that no longer existed, so the nightly `karakeep-nightly-digest` cron got `401` (and separately blew its 600 s idle limit while the pod was thrashing).

Everything needed to rebuild existed *outside* Karakeep, though:

- The Obsidian vault keeps a daily `karakeep/<YYYY-MM-DD>/manifest.json` (816 structured bookmarks: id, title, publisher, url, type, tags).
- The `morning-brew` repo/blog keeps 47 daily posts whose `**Source:**` lines cover the days that never got a manifest (another 101 bookmarks) — **917 unique URLs total**, 2026-07-23 → 2026-09-10.
- The Hermes `state.db` conversation history contained a dump of the original `rssFeeds` table: **18 feeds** (4 article feeds + 14 YouTube channel feeds) with their names and URLs.

## Decision

1. **Reconstruct the bookmarks through the Karakeep API** with the original `createdAt` (hoard-day) and `source` (`rss`/`web`), accepting **new document IDs** (old IDs are historical-only in the vault/blog). 917 bookmarks restored this way.
2. **Recreate the 18 RSS feeds** from the Hermes history, re-resolving the YouTube `channel_id`s from the channel names (the stored IDs were ambiguous). Feeds ingest only new items going forward; history comes from step 1.
3. **Mint a fresh API key** (`hermes-digest`, scope `fullaccess`) directly in the DB using the confirmed scheme (`keyId = 10 random bytes hex`, `secret = 16 random bytes hex`, `keyHash = base64(sha256(secret))`, token `ak2_<keyId>_<secret>`), and store it only in Hermes (`~/.hermes/.env`, the `karakeep_digest.py` fallback, and the `karakeep` skill) — never in the public repo, never printed.
4. **Make Karakeep survive bulk load.** A large crawl backlog made `/api/health` time out, and the HTTP liveness probe killed the pod repeatedly (`CrashLoopBackOff`, exit 0). The chart merges its default `httpGet` into any custom liveness handler (a `tcpSocket` override is rejected as a two-handler probe), so liveness stays `httpGet` but is deliberately tolerant (30 s timeout, 10 failures); container limits were raised to 3 CPU / 3 GiB for the drain.
5. **The daily DB backup is now the durability mechanism that matters** — it must exist *before* the next incident, and its freshness must be verified, not assumed.

## Consequences

**Positive**

- Karakeep is repopulated (917 bookmarks, correct dates, source split preserved) and the 18 feeds are back, so the nightly digest can run again.
- The reconstruction is reproducible from versioned/archived artifacts (vault manifests + blog + Hermes history), not from memory.
- The API key no longer lives hard-coded only inside a script; it is in Hermes env with a fallback.
- Karakeep no longer crashloops under crawl load.

**Negative**

- Old Karakeep document IDs are gone; the `verify_doc_ids.py` tooling still works against the *manifests* (which keep the old IDs), but not against live Karakeep.
- List memberships and history-precise (`createdAt`) times are unrecoverable; restored items carry day-precision timestamps.
- Assets/images were lost (the `karakeep-assets` bucket is empty); they are refetched lazily by the crawler.
- Tags are not restored verbatim; Karakeep's AI re-tagging regenerates them.
- The `hermes-digest` key is `fullaccess` (same as the old default) — broad, but the blast radius is a LAN/private service.

## Alternatives considered

- **Restore the DB from the MinIO backup.** Impossible: all objects post-date the wipe.
- **Recover the old DB from another source** (PVC snapshots, WAL). None existed.
- **Mint the key via the UI.** Works, but requires the plaintext to move through chat; minting from the confirmed algorithm keeps the secret out of the transcript.
- **Preserve the original document IDs via direct SQLite inserts.** Maximum continuity, but bypasses Karakeep's crawl/index queue and risks DB corruption on a live app; rejected.
- **Keep the crashlooping HTTP liveness probe.** Rejected: liveness must test the process, not responsiveness under load (same lesson as ADR-014 for Bazarr). The chart's merge behaviour forced the tolerant-`httpGet` form rather than `tcpSocket`.

## When to revisit

- If a real restore test is ever needed and the backup age is again older than the last mutation → escalate backup frequency and add a freshness alert (Prometheus rule on `lastSuccessfulFetchAt` / backup object age).
- If the vault `karakeep/<day>/manifest.json` scheme changes → update the reconstruction script.
- If Karakeep gains a supported bulk-import API that preserves timestamps and (optionally) IDs → prefer it over the per-item create loop.
