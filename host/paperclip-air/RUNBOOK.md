# RUNBOOK — the Air (`paperclip`, 192.168.1.191)

Written for the bad evening: something is down, you are on a phone or a laptop, nobody is sitting
at the Mac. Every command here works over SSH with no GUI session. Context: ADR-098, and the
2026-10-29 incident (`homelab/tracking/2026-10-29-windowserver-logout-outage.md`).

## 0. The single command if all else fails

```bash
ssh paperclip@192.168.1.191
sudo /usr/local/libexec/homelab/homelab-recover-appliance.sh
```

Re-runnable, starts anything not listening, prefers launchd, falls back to a detached `nohup` when
a service has no daemon installed. It never starts a second copy of a healthy service.

## 1. Is it the host, the session, or one service?

```bash
stat -f%Su /dev/console          # root = no GUI session (fine now); a username = someone is logged in
who                              # do NOT trust this: it keeps a stale console entry after a logout
sudo launchctl print system/dev.voitech.homelab.paperclip | head -20   # state = running?
curl -s -o /dev/null -w '%{http_code}\n' https://paperclip.voitech.dev  # what the world sees
```

| Symptom | Meaning | Action |
|---|---|---|
| `:3100` refuses, `/dev/console` = root | service down, session gone | `homelab-recover-appliance.sh` |
| `:3100` refuses, `launchctl print` says running | process wedged | `sudo launchctl kickstart -k system/dev.voitech.homelab.paperclip` |
| public 502/503 but `:3100` answers | Cloudflare tunnel (`cloudflared` is a daemon, it should be up) | `sudo launchctl print system/com.cloudflare.cloudflared` |
| no heartbeat in the cluster for >7 min, services answer | heartbeat sender/agent broken, or the LAN path to k3s | `launchctl print gui/$(id -u) \| grep heartbeat` |
| Mattermost says `HostWatchHeartbeatMissing` and the Mac is unreachable | host asleep/off/hung | check power and `pmset -g`; expect Cloudflare 502s |

## 2. Supervision: what must be true

```bash
sudo ./bin/homelab-install-daemons.sh --status
```

Five system daemons (`hermes-gateway`, `paperclip`, `minio-lan-proxy`, `gemini-tunnel`, `syncthing`),
**no** matching user agents, and the heartbeat as a user agent. If a service shows both `loaded` and
`YES` (agent present) you have two owners: run the installer, which fixes it.

Legacy watchdog: if `sudo launchctl print system/dev.voitech.homelab-watchdog` still exists, remove
it — launchd is the supervisor now (ADR-098).

```bash
sudo launchctl bootout system/dev.voitech.homelab-watchdog
sudo rm /Library/LaunchDaemons/dev.voitech.homelab-watchdog.plist
sudo rm /usr/local/sbin/homelab-appliance-watchdog.sh
```

### 2a. Converting a host whose services are *live orphans* (the 2026-10-29 leftover)

The installer derives each service's command from the LaunchAgent it replaces and then boots that
agent out. After the 2026-10-29 recovery the agents were **on disk but unloaded** (no `gui/501`
exists headless) while the processes the interim watchdog had started were alive, `PPID 1`, and
holding the ports. In that state the naive order is actively harmful: the daemon bootstraps, hits
`EADDRINUSE`, and `KeepAlive` turns it into a crash loop *behind* a healthy-looking orphan — two
supervisors and no owner.

The order that works, and the reason for each step:

```bash
# 0. put the commands in place first, so nothing is derived from a JXA wrapper
sudo -u paperclip ~/.config/homelab/gen-services-env.py       # or write services.env by hand

# 1. kill the interim supervisor FIRST, or it resurrects the orphans inside 120 s
sudo launchctl bootout system/dev.voitech.homelab-watchdog
sudo rm /Library/LaunchDaemons/dev.voitech.homelab-watchdog.plist

# 2. retire the agents before the ports change hands (they are unloaded, so this
#    is only file state - a GUI login mid-cutover would otherwise load them)
mv ~/Library/LaunchAgents/{ai.hermes.gateway,io.paperclip.server,io.paperclip.minio-proxy,ai.hermes.gemini-tunnel,sh.brew.syncthing}.plist \
   ~/Library/LaunchAgents.h2-336-backup-*/

# 3. now kill the orphans: they are PPID 1, so nothing else will
for p in 9000 3100 8083 8384 8642; do sudo lsof -nP -iTCP:$p -sTCP:LISTEN -t | xargs -r sudo kill -TERM; done
# syncthing keeps a monitor parent: pkill -f 'syncthing --no-browser' as well

# 4. bootstrap once the ports are free, then prove it
for s in minio-lan-proxy paperclip gemini-tunnel syncthing hermes-gateway; do
  sudo launchctl enable "system/dev.voitech.homelab.$s"
  sudo launchctl bootstrap system "/Library/LaunchDaemons/dev.voitech.homelab.$s.plist"
done
sudo ./bin/homelab-install-daemons.sh --status      # every row loaded, no agent
ps -Ao ppid,command | grep -E 'gateway run|paperclip/cli|minio_proxy|syncthing' | grep '^ *1 '   # must be empty
```

Killing `hermes-gateway` ends any Hermes agent run in flight, including the one doing the cutover.
Do it from a detached script (`python3 -c 'os.setsid()'`-style double fork) or with a person at the
Mac; a run is not a supervisor and its unposted work dies with it.

## 3. Boot resilience (attended only)

A MacBook Air has **no IPMI and no PDU**. There is no out-of-band power control: every recovery
path on this host is software, so a dead power supply means a human and a cable.

```bash
sudo pmset -g | grep -E 'autorestart|standby|autopoweroff| sleep'
# required on AC: autorestart 1, sleep 0, standby 0, autopoweroff 0
sudo defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser   # must be paperclip
sudo ls -l /etc/kcpassword                                                    # root:wheel 0600
```

Auto-login only runs at **boot**, never after a logout — and it was pointing at a deleted account
(`wojciechgula`) for nine days, which is why the Mac sat at a login window for two hours.
Proving it needs an attended reboot:

```bash
sudo ./bin/homelab-drill-session-loss.sh --reboot-attended --i-am-at-the-mac
# after the host is back:
stat -f%Su /dev/console      # must print paperclip; if it prints root, auto-login is broken
```

If it prints `root`, re-seed the auto-login password (`/etc/kcpassword`) and re-run. **Never reboot
unattended until this has printed `paperclip` at least once.**

## 4. The drills (a drill that has never run is not a plan)

```bash
sudo ./bin/homelab-drill-session-loss.sh --kill all          # crash RTO per service
sudo ./bin/homelab-drill-session-loss.sh --session-loss --i-am-at-the-mac
sudo ./bin/homelab-drill-session-loss.sh --restore            # checklist, then --record
./bin/homelab-drill-session-loss.sh --report
```

Results land in `~/Library/Logs/homelab/drills.jsonl`, one line per service per drill. Paste the
measured numbers into the table below — the *target* column is a promise, the *measured* column is
the truth.

| Service | Port | RTO target | Measured (kill -9) | Measured (session loss) | RPO |
|---|---|---|---|---|---|
| `hermes-gateway` (6 profiles) | 8642 | 90 s | *not measured* — killing it on purpose ends the run doing the killing (§2a); needs the attended drill | *pending drill* | ≤ 24 h — `~/.hermes` snapshot at 03:30 to OMV MinIO `hermes-state-backups` (ADR-071) |
| `paperclip` | 3100 | 120 s | **14 s** (2026-10-30) | *pending drill* | minutes — CNPG WAL → OMV MinIO (barman plugin), daily base backup 03:00, 30 d retention |
| `minio-lan-proxy` | 9000 | 30 s | **1 s** (2026-10-30) | *pending drill* | none needed (stateless relay) |
| `gemini-tunnel` | 8083 | 30 s | **1 s** (2026-10-30) | *pending drill* | none needed (stateless ssh forward) |
| `syncthing` | 8384 | 30 s | **1 s** (2026-10-30) | *pending drill* | ≤ minutes (peer-to-peer; the vault lives on the other side too) |
| whole platform after a logout | — | 300 s | — | *pending drill* | — |

Measurements are the crash drill (`--kill <service>`): the service is SIGKILLed and the clock starts
when its port goes *free*, not when the signal lands. Timing from the signal recorded `0 s` for
`paperclip` on 2026-10-30, because a dying process's listening socket keeps accepting for a moment —
a zero that looks like a perfect result and measures nothing. The `drills.jsonl` line from that first
run is left in place; the number above is from the corrected re-run.

Only the four services with no other dependency were drilled headless. `hermes-gateway` and the
session-loss row need a person at the Mac.

Restore drills have their own two rows: `restore-paperclip` (CNPG + MinIO → scratch namespace →
working UI) and `restore-hermes` (`~/.hermes` from the 03:30 snapshot → gateway starts). Both are
recorded with `--record restore-paperclip <seconds> pass`.

## 5. Alerting

Two independent signals, both *off the Air* (in k3s, `apps/host-watch`), because the Mac cannot
alert about itself when it is the thing that is dead:

1. **HTTP probe**, every 60 s, of `https://paperclip.voitech.dev`, `https://chat.voitech.dev` and
   `https://status.voitech.dev`; Mattermost after 3 consecutive failures.
2. **Heartbeat**, expected every 60 s from `homelab-heartbeat.sh`; the alert fires when the last
   beat is older than 7 minutes. This is the only check that survives the host being logged out,
   asleep or switched off — and it is why the sender must stay a user agent.

The heartbeat also carries per-component health (`hermes-gateway`, `paperclip`, `minio-lan-proxy`,
`gemini-tunnel`, `syncthing`), which is how the Hermes API gets watched at all: it binds
`127.0.0.1:8642` on the Air and only a process on the Air can see it.

### 5a. Claude Code auth is dead (GUL-641)

- **Symptom:** Claude Code agent runs fail with `agent error: Failed to authenticate` (OAuth session
  expired and could not be refreshed, `~/.claude/.credentials.json` blanked) and its ticket sits
  parked. On 2026-10-30 it sat there for nine hours with nobody told.
- **Check:** `~/.local/bin/claude auth status` — `"loggedIn": false` is dead. The hourly
  `com.gulasz101.hermes-memory-watchdog` checks the same thing and logs
  `check9 claude_auth=...` to `~/.hermes/logs/hermes-memory-watchdog.log`; for the verdict alone run
  `/usr/local/libexec/homelab/hermes-memory-watchdog.sh --claude-auth-only`.
- **Fix:** `claude auth login`, or `/login` in an interactive session. This is a **human** action: no
  daemon kickstart, no agent restart and no reboot will refresh an expired OAuth session, and
  `claude login` is not a subcommand.

Seeding the heartbeat token (once, after `apps/host-watch` has reconciled):

```bash
# on a box with the age key
sops -e -i apps/host-watch/host-watch-heartbeat-token.sops.yaml   # edit the plaintext value first
sops -d apps/host-watch/host-watch-heartbeat-token.sops.yaml | yq -r '.stringData.token'
# then on the Air:
printf '%s' '<that value>' > ~/.config/homelab/heartbeat-token && chmod 600 ~/.config/homelab/heartbeat-token
```

## 6. Housekeeping that is now ours

- **Logs.** launchd appends forever to `~/Library/Logs/homelab/*.log`. Check size monthly; rotate
  by hand (`: > file` after a `kill -HUP`-free restart) or add a `newsyslog.d` entry.
- **Scheduled jobs are daemons too (ADR-107, ADR-108).** `com.gulasz101.hermes-state-backup`
  (daily 03:30), `com.gulasz101.hermes-memory-watchdog` (hourly) and the factory guard live in
  `/Library/LaunchDaemons` with `UserName=paperclip`. They used to be LaunchAgents and went silent
  the moment the 2026-10-29 WindowServer kill unloaded the GUI session. Nothing scheduled belongs in
  `~/Library/LaunchAgents` — if you find one there, install it with
  `bin/homelab-install-scheduled-jobs.sh` instead. Check the truth with
  `sudo ./bin/homelab-install-scheduled-jobs.sh --status`; a hand-run job is not a substitute for a
  schedule that fires.
- **After a macOS major upgrade,** re-run `--status` and one drill: system-domain launchd semantics
  and `UserName` daemons' access to the user's home are the things that break.
