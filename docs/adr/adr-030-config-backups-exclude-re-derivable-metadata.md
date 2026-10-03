# ADR-030: Nightly config backups exclude re-derivable media metadata

Date: 2026-10-03
Status: Accepted
Related: tracking note `2026-10-03-arr-stack-config-backup-oom-fix` (vault), commits `4e102ce`, `b80b26f`, `9b8dde3`

## Context

The nightly `arr-stack-config-backup` CronJob tars all eight config PVCs and
streams them to OMV MinIO. Jellyfin's config PVC had grown to ~1.6 GB — 1.5 GB
of it `data/metadata` (People + library scrapes re-downloaded after the
September k3s migration) — while arr-box has ~500 MB of memory headroom. The
original upload code read each whole archive into RAM; the combination OOM-killed
the job every night Oct 1–3 and briefly flapped the node. The memory bug is
fixed (streamed uploads everywhere), but the size problem remains: 1.5 GB of
re-scrapeable metadata copied to MinIO nightly, with 7-deep retention, adds
~10 GB per service to the durable bucket and stretches every restore and the
nightly window for no durability gain.

Supreme Leader approved excluding it: *"Yes you can exclude data/metadata/"*.

## Decision

`arr-stack-backup-script` now passes GNU tar `--exclude` flags for the jellyfin
service only:

- `./data/metadata` — re-derivable: Jellyfin re-scrapes titles, artwork, people
  from the media itself plus online providers.
- `./data/cache` — pure scratch, never restore-worthy.

Kept on the same PVC and therefore in the backup: `data/data` (jellyfin.db —
users, parental controls, plugin config, stream positions: NOT re-derivable),
`config.xml`, `network.xml`, `system.xml`, `plugins/`, `keygen/`, logs excluded
by omission size anyway.

The same commit round also swept the *other* hand-rolled SigV4 uploaders
(openviking, karakeep, openchamber) onto the streamed upload pattern — same
slurp bug class, not yet at bomb size — and gave the openviking backup
container its first `resources` block.

## Consequences

**Positive**
- Jellyfin nightly archive drops from ~1.57 GB to ~52 MB (verified live).
- MinIO storage growth from arr-stack backups drops ~30x.
- Backup window shrinks; less NFS/S3 pressure on OMV at 04:00.
- New-device restores are faster (metadata re-scrape is expected anyway).

**Negative / accepted**
- A restore must re-scrape metadata: expect CPU-heavy Jellyfin scanning for
  some hours on a big library. Mitigated by nothing: it's the nature of the
  data. Media *files* themselves are never in config backups — that's the
  array's job.
- The exclusion list is hardcoded per-service in the script. If another app's
  config PVC grows a re-derivable monster (Bazarr subs cache, arr apps'
  MediaCover), a code change is needed. Acceptable at homelab scale; grep for
  `tar_excludes`.
- Historical `configs/jellyfin/*` objects in MinIO from before this change
  still contain metadata (they age out via the existing 7-deep retention).

## Alternatives considered

1. **Keep backing up everything** — durability maximalism. Rejected: metadata
   is deterministically rebuildable from the media; paying 10 GB + a nightly
   1.5 GB transfer for it is noise, and it was the proximate cause of the OOM
   incident (memory fix alone would have left a slow-growing cost problem).
2. **Split metadata onto its own PVC** and back up DB PVC only — cleaner
   topology but a storage migration on a working service; disproportionate for
   a backup-size preference.
3. **Exclude via jellyfin's own `.gitignore`-style knobs** — Jellyfin has no
   native "don't persist metadata" setting; the directory is designed to be
   the library cache. Not available.

## When to revisit

- If Jellyfin gains an official portable library-export API that is smaller
  than a re-scrape, back that up instead of raw DB files.
- If any other service's `tar_excludes` grows past ~3 entries, move the
  exclusion map into a ConfigMap key rather than code (still GitOps).
- If MinIO bucket pressure appears on OMV generally, audit retention depth
  (7) across all nightly backup jobs in one pass.
