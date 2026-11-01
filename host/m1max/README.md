# m1max — the MacBook Pro that behaves like a server

`MacBookPro18,4` (M1 Max, 32 GB), lid **shut**, on AC, with a dummy HDMI plug in the
side. Server alias `m1max` (`ssh m1max`). It runs as the owner's account
`wojciechgula`, so everything on it lives in the `gui/<uid>` launchd domain:

- the Hermes gateway (`ai.hermes.gateway`)
- Syncthing, the vault sync peer
- the Gemini proxy (`127.0.0.1:8083`, inside OrbStack)
- LM Studio, llama-embed, whisper, Kokoro, camofox, Star Office UI, ideogram4 worker

That list is the reason this machine must survive two things a laptop normally does not.

## The two ways this host dies quietly

**1. The display.** Clamshell mode is what keeps it awake with the lid shut, and clamshell mode
needs an external display. The dummy HDMI plug *is* the display, so pulling it out sleeps the
machine — which is exactly what the owner asked about. `pmset disablesleep 1` removes the whole
dependency: lid shut, no display, no idle sleep, still running.

**2. The reboot.** After a reboot or a logout there is no `gui/<uid>` domain, so every service
above stays dead until a human logs in graphically. Auto-login is the only thing that brings them
back — and macOS refuses to auto-login while **FileVault** is on. So on this host FileVault is off.
That trade is written down in `docs/adr/pending/headless-mac-runs-filevault-off.md`; it is a
decision, not an accident.

## Make it so

```bash
sudo ./bin/homelab-make-headless.sh --check    # read-only: what is set, what is not
sudo ./bin/homelab-make-headless.sh --apply    # pmset + FileVault + auto-login
```

`--apply` asks for the account password at a `sysadminctl` prompt (hidden, never on a command
line, never in a file) and asks `yes` before touching FileVault. A backup of the old
`/etc/kcpassword` is left in `/etc/` with a timestamp. Re-running it is safe.

Requirements: the account must exist (`dscl . -list /Users`), have a Secure Token
(`sysadminctl -secureTokenStatus <user>`), and the machine must be on AC.

## What is proven, and what is not

- **Proven by readback:** `pmset` values, `autoLoginUser`, `/etc/kcpassword` (root:wheel 0600),
  `sysadminctl -autologin status`.
- **Only proven by a reboot:** that auto-login actually logs in. Do it with the owner present:

  ```bash
  sudo shutdown -r now
  # once it answers on the network again:
  stat -f%Su /dev/console     # must print the account, NOT root
  ```

  `root` means auto-login failed and the host is parked at the login window. Fix
  `/etc/kcpassword` (`--apply` again) before trusting the next reboot.
- **Not available on this hardware:** `pmset autorestart`. macOS accepts the key and never stores
  it (measured on the Air, macOS 26), so a power cut still needs a human at the power button. The
  script reports this instead of pretending.

## Rollback

```bash
sudo sysadminctl -autologin off
sudo pmset -c disablesleep 0
```

FileVault goes back on through System Settings → Privacy & Security → FileVault. Do not re-enable
it while expecting the host to recover unattended: the two are mutually exclusive.

## Why there is a dummy HDMI at all

Only because clamshell mode used to require a display. Once `disablesleep=1` is set, the plug is
convenience, not a dependency — and it is worth pulling out once to prove it.
