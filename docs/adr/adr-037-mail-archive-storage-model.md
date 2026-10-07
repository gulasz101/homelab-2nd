# ADR-037: Mail-Archive storage model — DB-resident archive, CNPG backups to OMV MinIO, DataProtection keyring on NFS

## Status

Accepted — 2026-10-07 · Deployment epic H2-145, step ST6 (H2-151). Relates to
ADR-016 ("back up before the thing you want to protect") and the guardrail-4
storage topology. No Supersedes.

## Context

Mail-Archiver (`s1t5/mail-archiver`) is the homelab's route out of Gmail: it
pulls **mail and attachments** over IMAP into PostgreSQL, and its web UI searches
that store and exports mbox/EML. That makes a few storage decisions non-obvious
and high-stakes, because of two facts verified from the upstream source:

1. **The whole archive is the database.** Mail and attachments live in Postgres,
   not on a filesystem. There is no per-message file to copy; the database *is*
   the product.
2. **Upstream stores IMAP mailbox passwords in plaintext** in the `MailAccounts`
   table (verified: `Models/MailAccount.cs` writes the model straight through,
   no value converter), and OAuth refresh tokens are sealed with the ASP.NET
   Core DataProtection keyring. So the database — and therefore its backups —
   hold mailbox credentials in a form that is directly replayable if leaked.

The homelab's standing rules frame the same problem: live database PVCs go on
`local-path` NVMe on the compute node for latency; **nothing durable may live on
homelab-2nd**; durability comes from CNPG-native backups to OMV MinIO (guardrail
3/4). A few things in this deployment are genuinely not rebuildable from Git, and
they need a different home than the rebuildable NVMe.

## Decision

1. **Live archive = CNPG `Cluster` `mailarchiver-db`, single instance, 20Gi
   `local-path` PVC on the compute node.** Fast, and explicitly treated as
   rebuildable — losing the node is a restore, not a data-loss event.
2. **Durability = CloudNativePG Barman ObjectStore plugin → OMV MinIO**, bucket
   path `s3://cnpg-backups/mail-archiver`, continuous WAL archiving plus a daily
   03:00 base backup (`ScheduledBackup`, `immediate: true` on first apply),
   retention 30 days. OMV is the only durable store (guardrail 4).
3. **The DataProtection keyring → a static OMV NFS PV (`mailarchiver-keys`,
   1Gi, reclaim `Retain`), mounted at `/app/DataProtection-Keys`.** These keys
   seal every OAuth refresh token and every session cookie; losing them means
   re-consenting every mailbox. They are the one artifact here that Git cannot
   rebuild, so they do **not** live on homelab-2nd's rebuildable NVMe. `Retain`
   is deliberate: removing the Flux objects must never delete them from the NAS.
4. **Ephemeral staging is ephemeral.** The app creates `/app/uploads` and
   `/app/exports` at startup for import/export staging; those are `emptyDir`.
   Exports are downloaded and discarded; nothing durable is written there.
5. **The sensitive asset is the backup, not the live disk.** Because mailbox
   passwords are plaintext in Postgres, the MinIO objects are as sensitive as
   mail credentials. Compensating controls are: encrypted-at-rest objects,
   a least-privilege MinIO principal scoped to `cnpg-backups/mail-archiver/*`,
   a tight namespace NetworkPolicy, and a restore drill before anyone relies
   on the store.
6. **Application configuration is env-only** (double-underscore `appsettings`
   overrides) and every secret comes from a SOPS-encrypted Secret. No secret is
   written to the image, the repo, or a hand-edited manifest.

## Consequences

**Positive.**
- Search over the whole archive is a local Postgres query — fast, no filesystem
  walk, no attachment-duplication scheme to maintain.
- One backup mechanism covers the entire product (mail, attachments, credentials,
  keyring *references*), so there is a single recovery story: restore the CNPG
  cluster + remount the keyring.
- The live tier stays on fast local NVMe; durability is centralised on OMV and
  shared with every other CNPG cluster in the homelab.
- The blast radius of losing the compute node is bounded and rehearsed.

**Negative / risks.**
- **A corrupt or dropped database loses the whole archive** until a restore is
  performed — there is no per-file safety net. Backup freshness (alerted at
  >26h) and the restore drill are the mitigations, and they are load-bearing.
- **The backups are credential-bearing.** Anyone who can read `cnpg-backups/
  mail-archiver` can read mailbox passwords. MinIO access control and backup
  encryption are security controls, not housekeeping.
- The keyring at rest is **unencrypted ASP.NET XML** on the NFS share; NFS
  itself is not encrypted. Accepted for now on a trusted LAN share, flagged as a
  hardening follow-up.
- **Guardrail 4 in practice is "local NVMe of whichever node schedules the
  pod", not strictly homelab-2nd.** CNPG primaries are spread across all three
  nodes (observed 2026-10-07: mail-archiver and shlink on arr-box, authentik/
  opengist/itsaplan/litellm on t460, nextcloud/mattermost/openwebui on
  homelab-2nd). This is a standing architecture observation, not specific to
  Mail-Archiver; managing it properly is a separate decision.
- The 20Gi PVC will need expansion as the two accounts (~30 GB total) sync in.

## Alternatives considered

- **IMAP sync + flag/maildir approach** (offlineimap/notmuch/maildir-style:
  store raw EML on the filesystem, index separately). Rejected: a much larger
  operational surface (sync tooling, index rebuilds, attachment de-duplication),
  no integrated web search/export UI, and it duplicates what Mail-Archiver
  already does. It also does not remove the plaintext-credentials problem — it
  just moves the store.
- **Other archivers (Netdata-style/similar turnkey tools).** Rejected during
  planning: Mail-Archiver was the chosen product for Gmail-specific retention and
  mbox/EML export, OIDC SSO and an optional MCP endpoint. Re-evaluating the
  product is out of scope for a storage ADR.
- **Keep mail in Gmail and store only an index.** Rejected: it does not satisfy
  the actual goal (getting the mailbox out of Gmail), and leaves the data
  dependent on the provider.
- **Store attachments on OMV NFS/MinIO instead of in Postgres.** Rejected:
  upstream has no object-store attachment backend; adopting one would mean
  forking the application.
- **Back the database up to a homelab-2nd disk.** Rejected outright by
  guardrail 4 — homelab-2nd is rebuildable and is not a durable store.

## When to revisit

- The archive outgrows the NVMe, or the 20Gi PVC is repeatedly expanded — revisit
  the storage class and whether attachments should be externalised.
- Upstream ships object-storage/attachment externalisation, or moves mailbox
  credentials to an encrypted-at-rest form — the "backups are cleared data"
  risk model changes.
- The OMV MinIO/RustFS migration lands (the `minio/minio` image is no longer
  pullable; an archived image is the only copy) — the durability leg of this
  decision moves with it.
- The DataProtection keyring needs encryption at rest, or NFS is no longer
  trusted.
- Guardrail 4 is restated to pin CNPG primaries to a specific node — the
  "primaries spread across nodes" observation above would then need enforcing.
