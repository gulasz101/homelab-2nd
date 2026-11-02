# ADR-113: The heartbeat sender is a system daemon that reports the session, not one that dies with it

- **Status**: Accepted
- **Date**: 2026-11-02
- **Issue**: GUL-732 (`HostWatchHeartbeatMissing` firing permanently; host-watch blind)
- **Supersedes**: ADR-098 decision 6 ("the heartbeat sender is a LaunchAgent deliberately") and the
  matching clause in ADR-098's *Consequences*
- **Amends**: ADR-107 / ADR-108 — the sender joins the scheduled jobs that must run from the system
  domain, from this repo
- **Related**: GUL-643 (armed the heartbeat), GUL-728 (the leak detector that could not report),
  GUL-680 (the original leaked port-forward), GUL-745 (m1max headless), H2-336 (built host-watch),
  tracking note `2026-11-02-gul-732-heartbeat-headless.md`

## Context

ADR-098 decision 6 made the heartbeat sender a **user LaunchAgent on purpose**: it died with the
GUI session, so the off-host receiver could not tell "host healthy, platform dead" from "host
healthy". Session loss had to look like host loss. That reasoning was correct while the Air had a
human in front of it and a login window was an abnormal state.

It is the wrong rule for the machine we actually run. On 2026-11-01 the Air had no Aqua session at
all — `stat -f%Su /dev/console` answered `root`, `launchctl print gui/501` answered *"Domain does
not support specified action"* — and it had been that way for days. There is no `gui/501` to run
anything in, so the sender never started. Measured consequences:

- `hostwatch_heartbeat_last_seen_timestamp_seconds` sat at 0 for the life of the deployment
  (`hostwatch_heartbeat_accepted_total 0`), so `HostWatchHeartbeatMissing` fired permanently. A
  permanently firing critical alert is worse than no alert: it teaches everyone to ignore the one
  signal that survives a dead host.
- `hostwatch_host_leak{name="kubectl_port_forward"}` was exported **nowhere**, because the only
  process that produces it was the sender that never ran. `HostWatchOrphanKubectlForward` therefore
  had no series to fire on while two port-forwards leaked for 20 hours (GUL-728, GUL-680).
- `hostwatch_component_up` was equally empty: the Hermes gateway on `127.0.0.1:8642` has no public
  front, so the beat is the only thing that can watch it.

So the old design did not preserve the intent of ADR-098; it inverted it. "Session loss looks like
host loss" became "the appliance is permanently in the state that used to mean host loss", and the
monitoring was blind the whole time. m1max went headless on the same day (GUL-745), so this is the
normal shape of both Macs now, not an Air-only quirk.

## Decision

**The sender never dies with the session. It runs in the system domain and reports the session
inside every beat, and the receiver decides what a missing session means.**

1. `dev.voitech.homelab.heartbeat` is a **system LaunchDaemon** in
   `/Library/LaunchDaemons/`, `UserName=paperclip`, `HOME` set, `StartInterval 60`,
   `RunAtLoad`, `ThrottleInterval 30` — the ADR-107 shape, because it is a scheduled job that must
   fire with nobody logged in. There is no LaunchAgent copy anywhere in the tree; the installer
   retires one if it finds it.
2. The script is deployed from this repo to `/usr/local/libexec/homelab/homelab-heartbeat.sh` by
   `bin/homelab-install-scheduled-jobs.sh` (ADR-108), not run out of `~/bin`.
3. Every beat carries three session fields, all cheap and all host-local:
   - `console_user` — `stat -f%Su /dev/console` (`root` = nobody logged in; never trust `who`,
     which keeps a stale entry after a logout);
   - `gui_session` — 1 when a session exists at all: console owner is a real user, **or**
     `launchctl print gui/<uid>` succeeds;
   - `gui_expected` — 1 when *this host is supposed to have a session*, from
     `HOMELAB_GUI_EXPECTED` in `~/.config/homelab/heartbeat.env`. Default 0. The Air is 0: it is an
     appliance on a shelf and a login is the exception.
4. The receiver exports `hostwatch_gui_session{host}` and `hostwatch_gui_session_expected{host}`
   and **one beat produces two independent alerts**:

   | Signal | Meaning | Alert |
   |---|---|---|
   | no beat for >420 s | the host is asleep, hung, off, or its launchd domain is broken | `HostWatchHeartbeatMissing` (critical) |
   | beat, `gui_expected=1`, `gui_session=0` | the host is alive and has lost its session — the 2026-10-29 WindowServer logout | `HostWatchSessionGone` (warning) |

   The second alert is gated on `gui_expected`, which is what stops it from being the same
   always-firing noise on a headless host that the staleness alert just stopped being.

## Consequences

- **Headless is a first-class state, not a failure.** The Air beats, exports component health and
  the leak counter, and pages nobody about the absence of a session it does not want.
- **A real session loss on a host that expects one is still its own alert**, and it is now a *more*
  precise signal than before: previously a logout and a power cut were the same silence; now a live
  host with no session says so explicitly.
- **The sender is one more thing that must survive without a login**, and it now can: it is
  supervised by launchd in the system domain, and its failure mode is silence (which the staleness
  alert catches) rather than a false all-clear.
- **The token and env file stay host state**, not repo state: `~/.config/homelab/heartbeat-token`
  (0600) and `~/.config/homelab/heartbeat.env`. The repo carries the SOPS-encrypted secret only.
- **`homelab-install-daemons.sh --status` no longer prints the heartbeat as an agent.** The
  single-owner rule still holds: system domain only, and `tests/host-tree-check.sh` fails if both
  plists ever exist for the same label.
- **Cost of a wrong `gui_expected`.** Set it to 1 on a host nobody logs into and you get the old
  permanent alert back, one layer up. It is host configuration on purpose, so the fix is a one-line
  file edit on that host, not a repo PR.
- **Not covered:** sleep. A sleeping Mac sends no beat and still looks dead — correctly, and
  `pmset` is what keeps it awake.

## Alternatives considered

- **Keep the user agent and silence the alert (option 2 in the issue).** Rejected. It documents the
  blindness instead of fixing it: the leak counter and component health stay in a domain that does
  not exist, and we keep paying for an alert nobody can act on.
- **Two senders — a cheap system-domain liveness ping plus the session-sensitive `gui/501` beat
  (option 3).** Rejected. Two senders means two things to keep alive and the next person has to
  work out which one died; it also needs the receiver to reconcile two timelines for one host. One
  beat carrying the session is strictly less machinery for the same information.
- **Let the receiver infer "nobody logged in" from the beat's own absence.** Rejected: that is the
  original design, and it cannot distinguish a logout from a power cut — which is precisely the
  distinction this ADR is about.
- **Poll the Air's session from k3s** (SSH from the cluster every minute). Rejected: adds a
  credential and a network path to the monitoring, and it still cannot observe anything inside the
  host's session.

## When to revisit

- A host appears that genuinely needs `gui/501` (GUI automation, screen capture). It sets
  `HOMELAB_GUI_EXPECTED=1` and keeps this alert; there is no reason to split the sender again.
- The heartbeat ever needs to carry something that a non-GUI process cannot read (keychain,
  window-server state): that is the keychain caveat from ADR-098, and it means a second, GUI-bound
  reporter — not a rollback of this decision.
- macOS changes what `launchctl print gui/<uid>` reports from a system daemon (a macOS major
  upgrade is the moment to re-run the drill): the console-owner check is the fallback and is worth
  keeping even if the launchctl probe stops being useful.
- If a second host starts beating, the receiver's in-memory single-host state becomes the limit and
  the metrics need per-host state rather than one `host` label.
