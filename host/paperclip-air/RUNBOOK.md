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
| `hermes-gateway` (6 profiles) | 8642 | 90 s | *pending drill* | *pending drill* | ≤ 24 h — `~/.hermes` snapshot at 03:30 to OMV MinIO `hermes-state-backups` (ADR-071) |
| `paperclip` | 3100 | 120 s | *pending drill* | *pending drill* | minutes — CNPG WAL → OMV MinIO (barman plugin), daily base backup 03:00, 30 d retention |
| `minio-lan-proxy` | 9000 | 30 s | *pending drill* | *pending drill* | none needed (stateless relay) |
| `gemini-tunnel` | 8083 | 30 s | *pending drill* | *pending drill* | none needed (stateless ssh forward) |
| `syncthing` | 8384 | 30 s | *pending drill* | *pending drill* | ≤ minutes (peer-to-peer; the vault lives on the other side too) |
| whole platform after a logout | — | 300 s | — | *pending drill* | — |

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
- **Scheduled jobs are agents too.** `com.gulasz101.hermes-state-backup` (daily 03:30) and the
  factory guard are LaunchAgents: with nobody logged in they never run, so those backups silently
  stop. Convert them the same way (daemon + `StartCalendarInterval`) before relying on model A for
  good — tracked as follow-up work, not part of the initial conversion.
- **After a macOS major upgrade,** re-run `--status` and one drill: system-domain launchd semantics
  and `UserName` daemons' access to the user's home are the things that break.
