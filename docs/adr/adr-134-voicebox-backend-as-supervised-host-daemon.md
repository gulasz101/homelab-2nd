# ADR-134: The Voicebox TTS backend is a supervised host daemon with a durable data directory

- **Status**: Accepted
- **Date**: 2026-11-17
- **Issue**: GUL-1723 (owner request in Mattermost, handed over by the `billcipher` profile)
- **Related**: ADR-098 (one supervisor per host service, model A on the Air), ADR-107 (system LaunchDaemons for headless hosts), ADR-127 (Hermes profile state on this host)

## Context

The `billcipher` profile drives **Voicebox**, a local text-to-speech app installed at
`/Applications/Voicebox.app`. Its backend is a Python ASGI server (torch + MLX) that listens on
loopback port **17493** and answers `GET /health`. The profile's agent needs it as an ambient
capability: it should be there when a synthesis request arrives at 03:00, not something an agent
starts and forgets.

Before this decision the backend ran as a stray child process with no supervisor. launchd adopted
it as an orphan at some earlier point, so `ps` showed it alive with `ppid 1` and nothing tracked it:
no `RunAtLoad`, no restart on crash, and a reboot would have silently removed the capability.
A LaunchAgent plist had been written to `~/Library/LaunchAgents/` but never installed, because
service management is blocked from inside the Hermes gateway.

Two further facts decided the shape:

1. **The Air is headless most days.** `gui/<uid>` does not exist for long stretches, so a
   LaunchAgent is not merely inferior — it is invisible until somebody logs in at the console
   (ADR-107).
2. **The server's default data directory is relative.** With no `--data-dir` it writes `./data`
   next to its working directory. Started from the profile that resolved to
   `~/.hermes/profiles/billcipher/cache/scratch/data`, and Hermes reaps a scratch subtree that has
   been idle for a day. A live server keeps the deleted inode and keeps answering `/health`; the
   database with the voice profiles only disappears at the next start, as an empty directory.
   Nobody would connect those two events.

## Decision

1. **A system LaunchDaemon, model A:** `dev.voitech.homelab.voicebox-server`, `UserName=paperclip`,
   `RunAtLoad`, `KeepAlive`, `ThrottleInterval 10`, started through the shared
   `/usr/local/libexec/homelab/homelab-service-run.sh` wrapper with its command line in
   `~/.config/homelab/services.env` (`SVC_VOICEBOX_SERVER_CMD`). It is registered in
   `HOMELAB_SERVICES` with a port (17493), a health path (`/health`) and `svc_rto` 60 s, so the
   heartbeat watches it like every other service on the host.
2. **Durable data, not scratch:** `--data-dir /Users/paperclip/.hermes/profiles/billcipher/voicebox`
   is pinned in the command. The old database was copied there (checksummed) before the scratch
   copy was retired to a tarball in `~/.hermes/profiles/billcipher/backups/`.
3. **Loopback only, no public route.** It is a synthesis service for one agent on one host. No
   Cloudflare tunnel, no LAN bind (ADR-033's public-ingress rule does not apply to something with
   no human user).
4. **The profile keeps one break-glass script** (`scripts/start-voicebox.sh`) that no-ops when the
   port already answers, so a future agent cannot start a second copy and fight for 17493.

## Consequences

- The capability survives reboot, logout and a crash. `runs` increments on its own; measured
  48-55 s from launchd start to a 200 on `/health` (imports before uvicorn binds), which is why the
  service's RTO is 60 s rather than the 30 s the other daemons use.
- The heartbeat reports `voicebox-server` and `HostWatchComponentDown` covers it. An idle server
  reports `model_loaded: false` — correct, models load on first synthesis, not at boot.
- The service is now in the repo tree (`launchd/daemons/`, `homelab-lib.sh`, README), so
  `homelab-install-daemons.sh` reconciles it on the next run. It was installed by hand this time —
  the installer `kickstart -k`s every service, which would have restarted the gateway this run was
  running inside. Recorded as break-glass, not as the normal path.
- A model swap inside the app is a separate concern: the daemon does not care, and the data
  directory holds the voices, not the weights.

## Alternatives

- **LaunchAgent in `~/Library/LaunchAgents/`.** Rejected: no session, no service (ADR-107).
- **`launchd` `StartInterval` polling instead of `KeepAlive`.** Rejected: the process can hold the
  port and be wedged, and a periodic "is it up" tick that starts things by hand is a supervisor
  pretending to be a scheduler.
- **`/Applications/Voicebox.app` GUI login item.** Rejected: needs a GUI session, and the app's own
  auto-launch is a user-scope setting that nothing in Git can inspect.
- **Leave the existing orphan process alone.** Rejected: it was already lost once; a reboot would
  have been an outage nobody scheduled.

## When to revisit

- If a second profile wants TTS: one backend can serve several callers on loopback — do not install
  a second daemon. Revisit only if a profile needs a different model set at the same time.
- If Voicebox ever needs to be reachable from another machine, that is a new ingress decision
  (Mesh, not a public tunnel) and needs its own ADR.
- If Hermes stops reaping `cache/scratch`, the `--data-dir` pin is still correct, but the comment in
  the plist explaining *why* can be shortened.
