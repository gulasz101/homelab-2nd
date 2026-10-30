# `host/paperclip-air` — the Air's host-level configuration, in Git

Everything on this page lives on the **M1 MacBook Air** (`paperclip`, `192.168.1.191`), not in
Kubernetes. It is here because a host you cannot review or rebuild is a host you cannot recover:
on 2026-10-29 the platform was down for two hours and the recovery steps existed only in a shell
history.

- **Decision record:** [ADR-098](../../docs/adr/adr-098-one-supervisor-per-host-service-on-the-air.md)
  — root LaunchDaemons for the headless services, LaunchAgents only where a GUI session is required.
- **Incident that forced this:** `homelab/tracking/2026-10-29-windowserver-logout-outage.md` in the
  vault (WindowServer hang → direct logout → launchd unloaded every user agent → Cloudflare 502s
  for two hours, no alert).
- **Nothing here is applied by Flux.** Flux owns the cluster; these files are installed on the Mac
  by a human running one script, on purpose (guardrail: host config stays out of the reconciler,
  but it must be reviewable and restorable).

## What is in the tree

```
host/paperclip-air/
├── bin/
│   ├── homelab-lib.sh                     # what the Air runs: services, ports, RTOs, probes
│   ├── homelab-find-agent.sh              # locate the LaunchAgent a service used to run under
│   ├── homelab-install-daemons.sh         # THE installer: agents -> daemons, one owner, + rollback
│   ├── homelab-install-scheduled-jobs.sh  # ADR-107: the two scheduled jobs -> system daemons
│   ├── hermes-state-backup.sh             # nightly state.db -> MinIO (installed, never run from here)
│   ├── hermes-memory-watchdog.sh          # hourly: memory config + backup-job health
│   ├── homelab-service-run.sh             # exec wrapper every daemon calls (installed to /usr/local/libexec/homelab)
│   ├── homelab-recover-appliance.sh       # break-glass: bring back anything not serving, headless
│   ├── homelab-drill-session-loss.sh      # the drills, and the numbers they write down
│   ├── homelab-heartbeat.sh               # 60 s heartbeat + per-component health to k3s
│   └── homelab-appliance-watchdog.sh      # LEGACY (2026-10-29 interim); refuses to run under model A
├── launchd/
│   ├── daemons/                           # system domain, UserName=paperclip, KeepAlive
│   │   ├── dev.voitech.homelab.hermes-gateway.plist
│   │   ├── dev.voitech.homelab.paperclip.plist
│   │   ├── dev.voitech.homelab.minio-lan-proxy.plist
│   │   ├── dev.voitech.homelab.gemini-tunnel.plist
│   │   ├── dev.voitech.homelab.syncthing.plist
│   │   ├── com.gulasz101.hermes-state-backup.plist      # scheduled 03:30 (ADR-107/108)
│   │   └── com.gulasz101.hermes-memory-watchdog.plist   # scheduled hourly (ADR-107/108)
│   └── agents/
│       └── dev.voitech.homelab.heartbeat.plist   # user session ON PURPOSE (see ADR-098)
├── tests/host-tree-check.sh               # CI gate: plist shape, one owner, no secrets, plan renders
├── RUNBOOK.md                             # what a human does when something is down
└── README.md                              # this file
```

## The one rule

**One supervisor per service.** A service is either a root LaunchDaemon (survives logout, restarts
on crash, needs no console) or a user LaunchAgent (dies with the session). Never both. The installer
deletes the agent it replaces (backing it up first) and `tests/host-tree-check.sh` fails if this
tree ever ships both for the same name.

**Scheduled jobs are daemons too (ADR-107).** A job launchd *schedules* — not a service it
supervises — gets the same treatment: `launchd/daemons/`, `UserName=paperclip`, an explicit `HOME`,
installed by `bin/homelab-install-scheduled-jobs.sh`. A calendar job in `gui/501` does not fire
while nobody is logged in, and the Air spends most of its life with nobody logged in.

| Job | Label | Schedule | Script (installed to `/usr/local/libexec/homelab`) |
|---|---|---|---|
| Hermes state backup | `com.gulasz101.hermes-state-backup` | daily 03:30 | `hermes-state-backup.sh` |
| Memory watchdog | `com.gulasz101.hermes-memory-watchdog` | hourly | `hermes-memory-watchdog.sh` |

The scripts live here (ADR-108) because a script that exists only in `~/.hermes/scripts/` on one
host cannot be reviewed, restored onto a replacement Air, or fixed through GitOps. `HERMES_HOME` is
passed in the plist — the installed script is no longer inside the Hermes tree and cannot infer it
from `$0`.

## First install on a fresh Air

Assumes: macOS with Homebrew, the appliance user `paperclip` exists, and the services already run
once by hand (or by the old LaunchAgents). Run as `paperclip`, with `sudo` where shown.

```bash
# 0. get the repo onto the Air
git clone https://github.com/gulasz101/homelab-2nd ~/agent-skills/homelab-2nd
cd ~/agent-skills/homelab-2nd/host/paperclip-air

# 1. see what the installer would do (no root, no changes)
./bin/homelab-install-daemons.sh --dry-run

# 2. what owns what right now
sudo ./bin/homelab-install-daemons.sh --status

# 3. convert: reads each LaunchAgent's ProgramArguments, stores them in
#    ~/.config/homelab/services.env, retires the agent, bootstraps the daemon
sudo ./bin/homelab-install-daemons.sh

# 4. heartbeat sender (as the appliance user, NOT with sudo)
cp launchd/agents/dev.voitech.homelab.heartbeat.plist ~/Library/LaunchAgents/
mkdir -p ~/.config/homelab && chmod 700 ~/.config/homelab
printf '%s' "<the token from the host-watch SOPS secret>" > ~/.config/homelab/heartbeat-token
chmod 600 ~/.config/homelab/heartbeat-token
mkdir -p ~/bin && install -m 0755 bin/homelab-heartbeat.sh ~/bin/homelab-heartbeat.sh
# the sender sources homelab-lib.sh from its own directory — install both or it
# runs with no functions and silently sends nothing
install -m 0755 bin/homelab-lib.sh ~/bin/homelab-lib.sh
# gui/<uid> only exists while somebody is logged in at the console. If this says
# "Domain does not support specified action" the Mac is sitting at the login
# window: the agent is installed and will load at the next login, and until then
# the heartbeat is (correctly) silent.
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.voitech.homelab.heartbeat.plist
tail -5 ~/Library/Logs/homelab/heartbeat.err.log      # expect silence or "components down: ..."

# 5. break-glass command, installed where sudo can find it
sudo install -m 0755 bin/homelab-recover-appliance.sh /usr/local/libexec/homelab/
sudo install -m 0755 bin/homelab-lib.sh /usr/local/libexec/homelab/

# 6. the scheduled jobs (state backup + memory watchdog) — ADR-107/108
sudo ./bin/homelab-install-scheduled-jobs.sh --dry-run     # the plan
sudo ./bin/homelab-install-scheduled-jobs.sh --status      # who is scheduled where
sudo ./bin/homelab-install-scheduled-jobs.sh               # install + prove both once
tail -3 ~/.hermes/logs/hermes-state-backup.log             # a dated SUCCESS line
tail -3 ~/.hermes/logs/hermes-memory-watchdog.log          # a dated check line

# 7. prove it (a human must be at the Mac for the first two)
sudo ./bin/homelab-drill-session-loss.sh --kill all
sudo ./bin/homelab-drill-session-loss.sh --session-loss --i-am-at-the-mac
sudo ./bin/homelab-drill-session-loss.sh --reboot-attended --i-am-at-the-mac
./bin/homelab-drill-session-loss.sh --report
```

Log out and back in afterwards, then run `--status` again: no service may show both a daemon and
an agent.

## `services.env` — the command lives on the host, not in Git

The daemons all exec the same wrapper, which reads one line per service:

```bash
# /Users/paperclip/.config/homelab/services.env   (0600, paperclip:staff, NOT in git)
SVC_HERMES_GATEWAY_CMD='/Users/paperclip/.hermes/bin/hermes gateway run'
SVC_PAPERCLIP_CMD='cd /Users/paperclip/.paperclip/cli/current && exec node server/index.js'
...
```

Why: the repo is public and the command line carries installed paths, ports and occasionally
environment (nothing secret, but host-specific). The installer **derives it from the LaunchAgent it
replaces**, so the conversion preserves whatever actually worked instead of guessing. Edit a value
and `sudo launchctl kickstart -k system/dev.voitech.homelab.<service>`.

If a service has no derivable command the installer refuses to install its daemon (a `KeepAlive`
daemon with an unknown command is a crash loop) and tells you which variable to fill in.

## Rollback

```bash
sudo ./bin/homelab-install-daemons.sh --rollback
```

Boots the daemons out, removes their plists, restores the backed-up LaunchAgents from
`~/Library/LaunchAgents.h2-336-backup-<timestamp>/`. They load at the next login; until then use
`homelab-recover-appliance.sh`.

## What this tree deliberately does not do

- **No reboot automation.** The MacBook Air has no IPMI and no PDU. Power-cut recovery rests on
  `pmset autorestart 1` + a working auto-login, and auto-login is only *proven* by an attended
  reboot (RUNBOOK.md, step 3).
- **No secrets.** Not one token, key or password. The heartbeat token file is referenced by path.
- **No GUI tooling.** Screenshots, `computer_use` and GUI browser automation keep living in the
  user session — see ADR-098 for which agents that affects.
