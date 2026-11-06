# ADR: `minio-data` lives on a btrfs raid1 pair, not on one disk

- **Status**: Pending
- **Date**: 2026-11-02
- **Issue**: GUL-813
- **Related**: GUL-558 (the failure this answers), GUL-560 (the rules that now watch the volume), ADR-071 (Hermes `state.db` backups land here), ADR-081 (barman-cloud continues into the same store)

## Context

MinIO on OMV is the only durable store in this homelab. Every CNPG cluster (12 of them) writes
base backups and WAL into `cnpg-backups/` through the barman-cloud plugin, and the same store holds
Loki chunks, Hermes `state.db` backups, Paperclip/itsaplan attachments and Mattermost files. There is
no second copy anywhere: OMV is the durable tier, the k3s nodes are all rebuildable.

On 2026-10-28 the disk underneath it, `/dev/sdc` (Seagate `ST31000528AS`, 1 TB, 16 878 power-on
hours), started shedding sectors. In 49 hours `Reported_Uncorrect` went 369 → 3464, 835 sectors sat
pending and 835 offline-uncorrectable, btrfs `read_io_errs` went 284 → 2836, and the overall SMART
line still said `PASSED`. A single unreadable extent blocked the SATA queue, MinIO's health probe
missed its 30 s deadline, the only drive was marked offline, and every write answered
`InsufficientWriteQuorum` / `listPathRaw: 0 drives provided` — the 500 on Paperclip attachment
uploads. The backup target and the databases it protects shared one point of failure.

The evacuation to `/dev/sdd` (1.4 TB, healthy, but a 2011 disk with 9 757 hours on it) bought time
and did not change the shape: still one disk under the only copy of every backup. Live volume after
excluding dead weight was 679 GB on the source; 229 GB (`cnpg-backups/openchamber`, a runaway hourly
tarball job) and 137 GB (`cnpg-backups/honcho`, a decommissioned service) were not copied, so the
store that has to move is ~310 GB. Wojtek has two healthy 2.5 TB spares for the OMV box: 2.5 TB
usable at raid1.

Redundancy is the minimum this tier can run at. It is also not the whole design — see the last
Consequence.

## Decision

1. **Build one btrfs volume on the two 2.5 TB spares with `-d raid1 -m raid1`** — data *and*
   metadata mirrored — and mount it under `/srv/dev-disk-by-uuid-<uuid>` like every other OMV volume.
2. **Repoint MinIO's bind mount** in `/opt/homelab/minio/docker-compose.yml` at that volume's
   `minio-data/` directory. The compose file is host-side infrastructure, not Flux-managed; the
   change is recorded in the tracking note and the file is copied to
   `docker-compose.yml.pre-raid1` before it is edited.
3. **The order is part of the decision**, because doing it in the wrong order turns one incident
   into two: fit the disks only when no evacuation is running; confirm both spares are empty
   (`lsblk -o NAME,SIZE,MODEL,SERIAL` + `blkid`, no filesystem, no partition table) before the first
   write, because `mkfs.btrfs` destroys whatever is there; copy staging → raid1; cut over; prove an
   S3 PUT and a fresh CNPG WAL object; **only then** wipe `/dev/sdc`.
4. **Keep both old copies until the new volume has proven itself.** `/dev/sdd` keeps its copy until
   the raid1 has carried a full nightly backup cycle, and `/dev/sdc` is not touched at all before
   that. No disk is wiped on the strength of a filesystem that has existed for an hour.
5. **btrfs owns the mirror: no mdadm, no LVM, no RAID controller in the middle.** A failed member is
   `btrfs device add` + `btrfs balance` (or `btrfs replace` in place), and until a human runs it the
   filesystem stays mounted and readable at reduced redundancy. Nothing needs to fail over.
6. **Keep the OMV mount idiom so the existing observability keeps working**: `node_btrfs_device_errors_total`
   is already scraped from the OMV node exporter and the GUL-560 rules
   (`OMVBtrfsDeviceReadErrors`, `OMVBtrfsSustainedReadErrors`, `OMVBtrfsVolumeReadOnly`,
   `OMVDiskUnreachable`) key off `device=` — a dev-disk-by-uuid mount means those rules apply to the
   new pair unchanged.

## Consequences

What this buys:

- **One disk may fail and the store keeps serving.** Mirrored reads and writes mean MinIO does not
  flap a drive offline and backup writers do not stop; the CNPG chains keep running through the
  failure instead of ending with the disk.
- **2.5 TB usable against ~310 GB of live data** — about 8× headroom, so no capacity-driven decision
  for years and no pressure to prune backups in a hurry.
- **No new subsystem to operate.** Same filesystem, same mount idiom, same exporter, same alerts,
  same evacuation procedure as the one that just ran.
- Recovery is two documented commands, not a rebuild of a RAID array.

What it costs, accepted with eyes open:

- **Half the raw capacity goes to the mirror.** 5 TB of spares buys 2.5 TB usable. That is the price
  of surviving a disk.
- **A rebuild is a full 2.5 TB streaming copy** (`btrfs replace`) at the speed of the slower member —
  hours, up to a day on 2011-vintage SATA. During it the volume runs at single redundancy, so the
  honest statement is: *one* failure is free, a *second* failure during the rebuild is not.
- **No hot spare, no automatic rebuild, no controller failover.** btrfs raid1 is a filesystem, not a
  managed array; the repair is a human running two commands. That is a real operational dependency
  and it belongs in the runbook, not in the footnotes.
- **The pair is only as good as the worse drive**, and both spares are old enough to deserve a SMART
  read before `mkfs` and a watched `Reallocated_Sector_Ct` afterwards. Age is not a hypothetical in
  this homelab: the disk that failed already said `PASSED`.
- **The migration's own source is a 2011 disk** (`/dev/sdd`). The cutover window — copy, stop, copy
  delta, repoint, start, verify — is the riskiest hour of the whole job, and it is why nothing is
  deleted until the other side has proven itself.

And the line that must not get lost: **raid1 is not a backup.** It protects against a disk dying. It
does not protect against a fat-fingered `rm`, a bad MinIO upgrade, a corruption that is faithfully
written to both members, OMV being rebuilt wrong, fire or theft. This ADR makes the store survive
hardware. **The second copy question stays open** (offsite, or `rclone`/`restic` of `cnpg-backups` to
another host such as `arr-box`) and is filed separately; nothing here implies it exists.

## Alternatives considered

1. **A single larger disk, plus an `rclone` copy of `cnpg-backups` to another host.** Cheapest
   capacity and simplest to run: one 4 TB disk holds the store with room to spare, and a nightly
   copy elsewhere covers the "the machine is gone" case. Rejected *as the primary*, because the
   failure tolerance is exactly what just failed us: one disk dies and the whole store is offline
   until someone restores 300+ GB from a copy that has to be alive, reachable and have the space at
   the worst possible moment. There is no rebuild here, only a restore — measured in hours, not
   minutes, and it needs the second host to have been working all along. As the *second copy* half of
   the design this is still the right shape; it is wrong as the only copy.
2. **ZFS mirror on OMV.** Same redundancy, better integrity story (checksums, `zpool scrub` that can
   actually repair from the mirror, `zpool replace` with real progress accounting). Rejected on cost
   of operation, not capacity: it means a DKMS kernel-module stack on the OMV box, ARC memory taken
   out of a 31 GB host that also runs k3s durable storage, a second mount/import idiom beside btrfs,
   and a parallel alerting story the current rules know nothing about — all to protect write-once
   backup objects. A second storage subsystem is a second thing that can be misconfigured at 2 a.m.
3. **Keep MinIO on a single SSD.** Fast, silent, no moving parts — and it repeats the exact fault
   this ADR exists to answer: one device under every backup in the house. It also spends money on
   IOPS a write-once backup workload does not need while buying zero redundancy, so it is the most
   expensive way to stay unsafe.
4. **btrfs raid1 on the two 2.5 TB spares (chosen).** The minimum redundancy that keeps the store
   online through one disk failure, with no new subsystem, no new alerting and 8× headroom — and it
   is the option the owner already owns the hardware for.

## When to revisit

- **When the second copy exists.** This ADR is half a design. The day an offsite or other-host copy
  of `cnpg-backups` is real and verified by a restore, revisit whether the raid1 pair must stay the
  primary or becomes one of two.
- **When either spare reports reallocated sectors, or a rebuild has to happen in anger.** If a
  repair means a day at single redundancy, price a pair of new CMR disks against that downtime
  instead of repairing 2011 hardware again.
- **If a second failure lands during a rebuild**, that is the signal: stop repairing old disks, buy
  matched new ones. Do not answer it with a third old disk.
- **When usable 2.5 TB passes ~70 % (about 1.75 TB)**, decide between more disks and pruning dead
  weight (`openchamber`/`honcho`-style buckets) — at that point, not before.
