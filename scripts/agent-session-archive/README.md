# agent-session-archive

One-off migration tooling (H2-45) that consolidates the historical AI-agent
session transcripts off the M1 Max onto OMV, and **proves** the copy before
anything local is allowed to be deleted.

The hard rule from the Supreme Leader:

> Do NOT delete ANYTHING from the M1 Max before backups are verified.
> Verification = per-tool file manifests (path + size + sha256) with ZERO diff
> between source and destination.

"Verified" is therefore a machine-checkable fact, not a feeling. That is what
`agent_archive.py verify` is for.

## Files

| File | Purpose |
|---|---|
| `agent_archive.py` | stdlib-only: manifest, verify, SQLite snapshot, SigV4 MinIO upload |
| `run-on-mac.sh` | the Mac-side pipeline: stage → manifest → rsync → verify → pack → upload |
| `tests/test_agent_archive.py` | 24 unit tests, including the AWS SigV4 `get-vanilla` vector and a guard that the runbook contains no destructive command |

Nothing here deletes: there is no code path that removes a source file, and a
test (`RunbookGuardTests`) fails the build if a delete flag or a destructive
shell command is ever added to the runbook.

## Running it

On the M1 Max (the machine that owns the transcripts):

```bash
cd homelab-2nd/scripts/agent-session-archive
python3 -m unittest discover -s tests -v      # optional, but cheap
./run-on-mac.sh --dry-run                     # show the plan, write nothing
MINIO_ACCESS_KEY=... MINIO_SECRET_KEY=... ./run-on-mac.sh
```

`MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` (or `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY`) are read from the environment only. They are never
passed as arguments, never written to disk and never printed. Without them the
NFS archive still happens; the MinIO cold copy is reported as SKIPPED.

Useful variables: `TOOLS="opencode"`, `OMV_HOST`, `OMV_DEST`, `STAGE`,
`MINIO_ENDPOINT`, `MINIO_BUCKET`.

## Where the data lands

```
OMV  <OMV_DEST>/<tool>/source/        the transcripts, structure preserved
OMV  <OMV_DEST>/<tool>/manifests/     source.manifest, destination.manifest
S3   s3://agent-session-archive/<tool>/<tool>-<timestamp>.tar.gz|.tar.zst
```

Default `OMV_DEST`:

```
/srv/dev-disk-by-uuid-cda9bf6e-0ed1-4e61-b063-1cbab7351886/openchamber/data/agent-session-archive
```

The destination manifest is computed **on OMV**, not from the local staging
tree — hashing the local tree twice would prove nothing about what actually
landed.

## Manifest format

```
<sha256><2 spaces><bytes><2 spaces><relpath>
```

UTF-8, LF, sorted by `relpath`. Excluded noise (mirrored by `RSYNC_NOISE` in
the runbook): `__pycache__`, `*.pyc`, `.DS_Store`, `*.tmp`, `*.temp`, `*-wal`,
`*-shm`, `.cache`, `node_modules`, `.Trashes`, `.Spotlight-V100`, `.fseventsd`.
Symlinks are reported as warnings and not followed, so a symlinked transcript
is a visible decision rather than a silent omission.

Exit codes for `verify`: `0` identical, `1` any difference (printed one per
line as `MISSING` / `EXTRA` / `SIZE` / `HASH`), `2` usage or I/O error.

## Two things that are easy to get wrong

1. **The OpenCode source is a live SQLite database in WAL mode.** A plain copy
   can be torn. `run-on-mac.sh` rsyncs everything *except* `opencode.db*` and
   then puts a consistent snapshot in its place via SQLite's online-backup API
   (`agent_archive.py sqlite-snapshot`). Verifying a torn copy would be a false
   comfort.
2. **An empty staging tree always verifies.** If staging comes out empty, the
   manifests match trivially and the tool would report success over nothing. The
   runbook therefore treats an empty staged manifest as a *failure*, not a pass.

## macOS notes

- `python3` is required (`xcode-select --install`, or Homebrew). macOS still
  ships `/usr/bin/sqlite3`, but the runbook uses the Python snapshot path so
  there is one implementation.
- Some macOS versions ship `openrsync` as `/usr/bin/rsync`, which lacks several
  GNU options. The runbook only uses `-a --no-D` plus `--info=stats2` when the
  local rsync advertises it, so it works with both.
- `zstd` is used for packing when present; otherwise `tar.gz`. The object key
  keeps whichever extension is real.

## Cleanup is out of scope here

Deleting the Mac-side originals is a separate issue, gated on the verified
manifests plus the Supreme Leader's explicit go-ahead. This directory contains
no cleanup command.
