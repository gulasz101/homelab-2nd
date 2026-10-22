# ADR-079: LaunchAgents on the Air reach LAN services through loopback relays, never directly

**Date:** 2026-10-22
**Status:** Accepted
**Deciders:** Wojtek Gula; implemented by Andrzej (Hermes agent)
**Project:** agent platform (M1 Air host automation)
**Related:** GUL-87, GUL-74, GUL-36, ADR-071 (state.db backup), ADR-073 (Hermes on the Air), ADR-074 (Paperclip on the Air)

## Context

The Hermes state backup LaunchAgent (`com.gulasz101.hermes-state-backup`, daily 03:30) failed
its 2026-10-21 and 2026-10-22 runs with:

```
mc: <ERROR> Unable to initialize new alias from the provided credentials.
Get "http://openmediavault.local:9000/probe-bsign-...?location=":
dial tcp 192.168.1.180:9000: connect: no route to host.
```

GUL-74 read that as a missing route to OMV at 03:30 and added a retry loop around an
`/usr/bin/nc` probe. It "fixed" the symptom: the probe passed, the job still failed, and the
diagnosis was never re-tested under launchd.

The real cause is **macOS Local Network privacy** (GUL-36). A launchd-spawned process that is
not Apple-signed cannot open a LAN connection, and the OS reports that refusal as
`EHOSTUNREACH` — "no route to host" — which is indistinguishable from a missing route in the
log. The `nc` probe passed because `/usr/bin/nc` is Apple-signed; `~/.local/bin/mc` is a
third-party binary and was denied. The 2026-10-21 21:22 manual run succeeded because a
process started from an interactive shell inherits a different privacy context from one
launchd spawns.

The GUL-36 fix already exists on this host: `io.paperclip.minio-proxy`, a stdlib threaded TCP
relay on `127.0.0.1:9000` → `192.168.1.180:9000`, running under `/usr/bin/python3`, which
*is* allowed LAN access. Paperclip's own storage endpoint was moved to the relay at the time.
The backup was never moved.

The failure mode is silent in the worst way: the job exits 1, the log says "no route to
host", and every later diagnosis reads as a network problem. The only durable copy of every
agent conversation (ADR-071) went unwritten for two nights.

## Decision

1. **A LaunchAgent that talks to a LAN host must go through a loopback relay, not the LAN
   address.** For MinIO on OMV that relay is `127.0.0.1:9000` (`io.paperclip.minio-proxy`).
   The `hermes-state-backup` LaunchAgent now sets `MINIO_ENDPOINT=http://127.0.0.1:9000` in
   its plist `EnvironmentVariables`, with the reason in a comment next to it.
2. **The endpoint is layered, in this order: LaunchAgent `EnvironmentVariables` → the env
   file's default → the script's default.** The env file
   (`~/.config/hermes-state-backup/minio.env`, mode 600) uses
   `MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://127.0.0.1:9000}"`, so the agent wins and a manual
   run still gets the relay. Nothing about the credentials changed.
3. **The readiness probe must be the same client the job uses.** The wait loop now runs
   `mc alias set` against `MINIO_ENDPOINT` and treats its exit code as the answer. `mc alias
   set` performs a signed probe, so it exercises the real path with the real binary and the
   real credentials. An Apple-signed probe (`nc`) is not evidence: it passes exactly when the
   real client is being denied.
4. **A backup that is verified only by hand is not verified.** Every fix to a scheduled job
   is proven by `launchctl kickstart -k` and the job's own exit status, not by running the
   script in a shell. A shell and a LaunchAgent have different privacy contexts; that
   difference is the bug.
5. **The relay is a first-class dependency of every Air-side job that needs the LAN**, and
   must be kept alive independently of the job it serves: `RunAtLoad` + `KeepAlive` on its own
   LaunchAgent, bound to loopback only. OMV is not exposed further by this.
6. **The general fix — granting Local Network access to the specific binary — is a GUI action
   the owner has to take** (System Settings → Privacy & Security → Local Network). Until then
   the relay is the supported path. When that permission is granted the relays can be retired
   in one pass, and this ADR revisited.

## Consequences

- The 03:30 backup runs again under launchd, proven by a kickstarted run and `launchctl list`
  exit status 0 — not by a manual run.
- Any Air-side job that reaches a LAN host directly is broken in exactly the same way and
  fails the same way. The tell is a launchd-only failure that reads as a network problem
  while the same command works from a shell.
- The loopback relay becomes a shared dependency: if it dies, every LAN-reaching Air job
  fails together. It is deliberately independent of the services it fronts and restarts on its
  own via `KeepAlive`.
- The relay is host-level, not GitOps — the same ruling as GUL-36. It lives in
  `~/.paperclip/bin/` with its own LaunchAgent, and the *decision* lives here in the repo.
- Fixing a macOS privacy problem by adding a relay adds a moving part. Accepted: the
  alternative is a silent daily failure of the only copy of the conversation history.
- The failure took two nights to surface because the watchdog reports on the backup log's
  contents, and "the job exited 1" is not one of its conditions. That gap is a separate
  finding, not fixed here.

## Alternatives considered

- **Keep `nc` as the probe and let the alias set fail loudly.** Rejected: the probe would
  keep passing while the thing that matters is denied. A readiness check that cannot fail
  when the job will fail is worse than none, because it converts a loud failure into a
  confident one.
- **Grant Local Network permission to `~/.local/bin/mc` and point it straight at OMV.**
  Rejected for now: it is a GUI action on the owner's machine, and it fixes one binary. The
  relay fixes the whole class and is already running. Revisit when the permission is granted.
- **Run the backup from a different scheduler (cron, a Hermes cron job, a container).**
  Rejected: the source data is on the Mac and the job must be a per-user LaunchAgent to run
  while the Air is awake. Changing the scheduler would not change the privacy context of the
  process that does the upload.
- **Copy `state.db` to OMV over SMB/NFS instead of S3.** Rejected: the same LAN privacy
  block applies to the mount helper, and it breaks the single-credential, bucket-scoped
  uploader model from ADR-071.
- **Run the whole backup inside the cluster and pull the databases over the WireGuard/
  Netbird link.** Rejected: the databases only exist on the Mac, so something still has to
  read them there and send them out — the transfer would just move to a different, larger
  surface. ADR-071 already ruled the cluster out for this job.
- **Have the script detect `EHOSTUNREACH` and fail with a clearer message.** Rejected as a
  fix: better diagnostics, same zero backups. It is worth having as a symptom, not a remedy.

## When to revisit

- The owner grants Local Network access to the relevant binaries in System Settings. Then the
  relays can go, the endpoints can point straight at the hosts, and this ADR is superseded.
- A new Air-side job needs a LAN host other than MinIO: it needs its own relay, or a shared
  one extended, and the rule in decision 1 applies to it from the start.
- The relay is replaced by a native macOS mechanism (a per-binary TCC grant managed by MDM,
  or a supported loopback-forwarding API) — then the "loopback relay" half of this ADR is
  obsolete even if the "probe with the real client" half is not.
- The Air stops being a host that reaches the LAN at all (everything moves into the cluster):
  then the whole class of problem disappears with the jobs.
