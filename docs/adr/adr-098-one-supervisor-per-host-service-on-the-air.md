# ADR-098: One supervisor per host service on the Air — root LaunchDaemons for the headless five

**Date:** 2026-10-29
**Status:** Accepted
**Deciders:** Wojtek Gula; written from the H2-336 incident review
**Project:** agent platform / host resilience
**Related:** H2-336, ADR-073 (Hermes on the Air), ADR-074 (Paperclip control plane on the Air),
tracking note `2026-10-29-windowserver-logout-outage.md`

## Context

On 2026-10-29, 09:39 CET, macOS `WindowServer` stopped checking in for 40 s, the userspace
watchdog killed it, and loginwindow treated that as a **direct logout**
(`directLogoutReason:WindowServerExited`). Every service we run on the Air was a **user
LaunchAgent** in `~/Library/LaunchAgents`, so launchd unloaded all of them in the same second:
the Hermes host gateway (which serves all six profiles), Paperclip, the MinIO LAN proxy, the
Gemini SSH tunnel, Syncthing and the factory guard. `cloudflared` is a **root LaunchDaemon**, so
the tunnel stayed up and Cloudflare kept answering 502/503: the machine looked present and was
dead. Nobody was told for two hours.

That is not a service failure, it is a supervision failure. A Mac used as a server cannot have
its critical processes living in a session that macOS is allowed to end. The interim fix (a root
LaunchDaemon `dev.voitech.homelab-watchdog` that restarts detached children when `/dev/console`
is not a user) proved the idea works — Syncthing came back on the next 120 s tick — but it left
**two** owners for the same process: a daemon that spawns detached children, and the user agents
still sitting on disk that launchd starts as soon as a GUI session returns. Two owners means
"who restarted this, and from which config?" has no answer at 03:00.

This ADR picks one model, and the rule that makes it stay picked.

## Decision

**A service that must survive a session loss is a root LaunchDaemon. A service that needs a
session is a LaunchAgent. Never both, for the same service, at the same time.**

1. **Model A — system domain — for the five headless services.** `hermes-gateway` (all six
   profiles), `paperclip`, `minio-lan-proxy`, `gemini-tunnel`, `syncthing` become
   `/Library/LaunchDaemons/dev.voitech.homelab.<service>.plist` with `UserName=paperclip`,
   `RunAtLoad=true`, `KeepAlive=true`, `ThrottleInterval` (30 s for the gateway and Paperclip,
   10 s for the rest) and `StandardOutPath`/`StandardErrorPath` under
   `/Users/paperclip/Library/Logs/homelab/`. launchd, in the system domain, is their only owner.
2. **Their LaunchAgents are deleted, not disabled.** `host/paperclip-air/bin/homelab-install-daemons.sh`
   boots the agent out of `gui/<uid>` *and* removes the plist, so a later login cannot resurrect a
   second copy. The installer refuses to finish if a service has both a daemon and an agent.
3. **Model B — user session — only where Aqua is genuinely required.** Today that is exactly one
   job on purpose: the **heartbeat sender** (see below). GUI-only tooling (screenshot helpers and
   anything `computer_use` drives) stays an agent and is *allowed* to die with the session.
4. **The interim watchdog daemon is retired** once the five daemons are installed. Restarting a
   crashed process is launchd's job and doing it from a script we own is a second supervisor. Its
   script stays in the repo as documentation of the 2026-10-29 recovery; it is not installed.
5. **`homelab-recover-appliance.sh` stays, as break-glass only.** One command, re-runnable, starts
   anything that is not listening, works with no GUI session. It is the answer to "everything is
   down and I am on a phone", not a supervisor.
6. **The heartbeat sender is a LaunchAgent deliberately.** The off-host receiver in k3s
   (`apps/host-watch`) must not be able to tell "host healthy, platform dead" from "host healthy".
   If the sender ran in the system domain it would keep ticking through a logout and hide exactly
   the failure this ADR exists for. Session loss must look like host loss.

## Consequences

- **A WindowServer logout becomes a non-event.** launchd in the system domain is untouched by
  `gui/<uid>` teardown, so the five services keep running (or are restarted by launchd) with no
  human and no console.
- **`computer_use`, screenshots and GUI browser automation degrade for these processes.** They
  have no Aqua connection: no window server access, no screen capture. Affected today: the
  Paperclip **factory** agents and any Hermes profile that calls a screenshot/`computer_use` tool
  (`Bill Cipher` = profile `default`, `Andrzej`, `szarik`, plus the remaining profiles sharing the
  gateway). Audited 2026-10-29: no skill under `agents/` uses `computer_use` or screenshots —
  only ADR-032 and ADR-067 mention them — so nothing currently shipped depends on Aqua. Browser
  automation that goes through Playwright/Firecrawl in k3s is unaffected.
- **Keychain caveat, must be checked before flipping a service.** A LaunchDaemon with `UserName`
  runs in the system domain and does **not** unlock the user's login keychain. Anything that reads
  a generic password from the login keychain will fail headless. The five services read their
  credentials from files (`~/.hermes`, `~/.paperclip`, `.env`, ssh keys), not from the keychain, so
  they are safe today — but this is a standing constraint: **a new host service that needs a
  keychain item cannot be model A without seeding that item to a file first.**
- **Debugging moves.** There is no `launchctl print gui/<uid>` from an SSH session any more (that
  domain does not exist when nobody is logged in). Use `sudo launchctl print system/<label>` and
  `sudo launchctl kickstart -k system/<label>`.
- **Logs are launchd's.** Rotating `~/Library/Logs/homelab/*.log` becomes our job (newsyslog or a
  size check in the drill), because launchd appends forever.
- **Auto-login is no longer load-bearing for the platform**, only for GUI tooling. That removes
  the worst failure mode of the 2026-10-29 incident: a broken `autoLoginUser` no longer means a
  dark platform, just a dark screen.
- **A MacBook Air has no IPMI and no PDU.** Every recovery path here is software. Power-cut
  recovery still rests on `autorestart=1` plus working auto-login, which is only *proven* after
  the attended reboot in H2-341.

## Alternatives considered

- **Keep LaunchAgents and let the watchdog daemon own restarts (the 2026-10-29 interim state).**
  Rejected. It works, but supervision is split: launchd starts its copies when a GUI session
  returns while the daemon keeps detached children alive, so "one service, two owners" is
  permanent. It also keeps a script we wrote in the critical path of every restart.
- **Both models at once (daemon + agent with the agent disabled).** Rejected outright: a disabled
  agent is one `launchctl enable` away from a duplicate, and the failure mode is two gateways
  writing the same state DB.
- **Reboot the host when no console user is seen for N minutes.** Rejected. It reboots a perfectly
  healthy host to fix a session, it cannot fire at all if the machine is asleep, and it needs the
  very auto-login path that was broken for nine days. A restart of the five processes is cheaper
  and faster than a reboot (~90 s measured for the gateway).
- **Move the services into k3s / a Linux box.** Rejected here for scope: ADR-073/ADR-074 already
  decided the Air hosts Hermes and Paperclip natively, and the local-model + Homebrew stack is
  load-bearing. Revisit as its own decision, not as a resilience patch.

## When to revisit

- A host service comes along that genuinely needs Aqua (screen capture, GUI automation). It gets a
  LaunchAgent and accepts dying with the session — or model A and a re-architecture of that need.
- A service starts reading a keychain item: it cannot be model A until the item moves to a file.
- macOS changes system-domain launchd semantics, or `UserName` daemons lose access to the user's
  Home (a macOS major upgrade is the moment to re-run the drill).
- The Air is replaced or its user/uid changes: the plists hard-code `UserName=paperclip` and
  `/Users/paperclip`.
- If session losses stop happening for a year, this can be re-examined — but the cost of keeping
  it is zero, so the burden of proof is on removing it.
