# ADR: A headless Mac appliance runs FileVault off, or it does not come back on its own

- **Status**: Pending
- **Date**: 2026-11-01
- **Issue**: GUL-745
- **Related**: ADR-073 (Hermes runs on the M1 Air), ADR-107 (scheduled jobs are system daemons), ADR-108 (backups are daemons), `host/paperclip-air/RUNBOOK.md` step 3 (auto-login is only proven by an attended reboot)

## Context

`m1max` is a `MacBookPro18,4` (M1 Max, 32 GB) sitting lid-shut on a shelf, on AC, with a dummy HDMI
plug. It is not a spare laptop any more: it runs the Hermes gateway for its profiles, Syncthing (the
vault peer), the Gemini proxy, LM Studio and llama-embed, whisper, Kokoro, camofox, Star Office UI
and the ideogram4 worker. All of them are `gui/<uid>` LaunchAgents under `wojciechgula`.

Measured on 2026-11-01, over SSH, before any change:

```
fdesetup status                                    -> FileVault is On.
defaults read .../com.apple.loginwindow            -> no autoLoginUser key at all
iostat / ioreg  AppleClamshellState                -> Yes   (lid shut, clamshell mode)
system_profiler SPDisplaysDataType                 -> one display, 1920x1080: the dummy plug
pmset -g                                           -> no SleepDisabled; standby 1; hibernatemode 3
sysadminctl -secureTokenStatus wojciechgula        -> Secure token is ENABLED
```

So the host had two independent single points of death, and both of them are silent:

1. **Pull the dummy HDMI and clamshell mode ends** — a shut lid with no display sleeps, whatever
   `sleep 0` says. `sleep 0` prevents *idle* sleep; it does not prevent lid-close sleep.
2. **Reboot, logout, or a WindowServer hang** and there is no `gui/<uid>` domain. No domain means no
   LaunchAgents, and no LaunchAgent means no gateway, no Syncthing, no proxy. Nothing restarts them
   without a graphical login.

macOS will not log a user in automatically while the volume is FileVault-encrypted. That is not a
setting we can talk our way around: the automatic-login control is unavailable with FileVault on,
and `/etc/kcpassword` is useless without it. So "auto-login" and "FileVault" are a straight choice on
this class of host, and the choice was never made deliberately — the machine simply had the default,
which is FileVault on and no auto-login.

## Decision

1. **Headless macOS appliance hosts in this homelab run FileVault off.** The class is "a Mac that has
   to come back by itself with nobody in the room": today that is `m1max`; `paperclip` (the Air)
   already runs this way and it is the reason its gateway survives a power cut.
2. **Auto-login is set through `sysadminctl -autologin set -userName <user> -password -`,** so the
   password arrives at a hidden prompt and never on a command line, in a shell history, in this repo,
   or in a chat. `/etc/kcpassword` stays owned by the OS (root:wheel 0600) and is backed up
   timestamped before every change.
3. **`pmset -a disablesleep 1` is the fix for the display dependency**, not a bigger dummy plug. The
   plug stays only as a convenience.
4. **One script is the source of truth:** `host/m1max/bin/homelab-make-headless.sh --check|--apply`.
   It reports every value by readback, refuses to run without root, and gates `fdesetup disable`
   behind a typed confirmation. A static CI check (`host/m1max/tests/headless-script-check.sh`, picked
   up by `scripts/check.sh`) keeps the guard shape from rotting.
5. **The trade is stated where the person running it can see it:** `--apply` prints what turning
   FileVault off costs before it asks for `yes`.

## Consequences

- **The disk of an appliance Mac is readable to anyone holding the machine.** Physical theft of
  `m1max` (or the Air) now means reading the vault, the agent state and every profile `.env` without
  a password. Accepted for a machine that lives on a shelf in the owner's home and exists to stay
  up; **not** accepted for a portable that leaves the house, and not for anything the owner would
  call sensitive client data.
- **A reboot now recovers without a human,** which is the point: `pmset` + auto-login is the entire
  disaster-recovery story for a Mac with no IPMI and no PDU.
- **`pmset autorestart` is not part of the promise.** macOS accepts the key and silently does not
  store it on the hardware in this fleet (measured: `pmset -a autorestart 1` exits 0, `pmset -g`
  never shows it). A power *cut* still needs a hand on the button; a reboot does not. The script
  says so out loud rather than printing a green tick it cannot back up.
- **Auto-login is only proven by an attended reboot.** Until `stat -f%Su /dev/console` prints the
  account after a restart, the setting is unverified, whatever the readback says. Never reboot these
  hosts unattended after a change to this configuration.
- **Re-enabling FileVault on an appliance silently re-breaks recovery.** Anyone who turns it back on
  "for security" must expect the next reboot to park at the login window — the script's `--check`
  exists to make that visible before it bites.

## Alternatives

- **Keep FileVault on and accept a manual unlock after every reboot.** Zero recovery for power cuts,
  kernel panics and forced logouts; the owner is away on weekdays. Rejected: it is not a safety net,
  it is a prayer.
- **Use `fdesetup authrestart` for reboots while keeping FileVault on.** It supports this host and
  keeps the key in memory for one planned restart, but it needs the FileVault password at the prompt
  and does nothing for an unplanned power loss, a panic, or a logout. Helps planned maintenance only.
- **Keep FileVault on and supervise everything from a root LaunchDaemon** (the Air's watchdog
  pattern). It keeps services alive through a logout with no login at all, but it starts them as
  orphans outside launchd's supervision and cannot recreate a graphical session; it is the fallback
  for a host that must stay encrypted, not the default.
- **Leave the dummy HDMI in place and call it done.** It works until someone unplugs it, which is
  precisely the question that started this ADR. Rejected.

## When to revisit

- The machine stops being a shelf appliance (someone starts carrying it) — then FileVault goes back
  on and recovery moves to the watchdog pattern.
- macOS gains a supported auto-login-with-encryption path (or the appliance becomes reachable
  through a pre-boot unlock the owner can drive remotely).
- The host starts holding data that justifies encryption over uptime.
- A power cut costs us a service that actually matters, and `pmset autorestart` proves unsupported:
  then the fix is a smart plug or a UPS with remote power-on, not more pmset keys.
