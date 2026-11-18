# Agent rule files are versioned in git, deployed by script and owned by Wojtek; they do not move under ~/.hermes

- **Status**: Pending
- **Date**: 2026-11-15
- **Issue**: GUL-1572 (implementation), found on GUL-1569 / GUL-1568; related backup gap GUL-1573
- **Related**: ADR-071 (Hermes `state.db` backup), ADR-075 (Paperclip org and runtimes), ADR-093 (point 6: the agents' own rules are always Wojtek's), tracking note `homelab/tracking/2026-11-15-gul-1569-stale-gateway-label.md`

## Context

Bill Cipher told Wojtek to restart the gateway with `launchctl kickstart -k gui/$(id -u)/ai.hermes.gateway` (GUL-1568). No such job exists. The gateway is the **system LaunchDaemon** `dev.voitech.homelab.hermes-gateway` (`/Library/LaunchDaemons/`, `UserName` = `paperclip`). Bill wasn't making it up: he was repeating his own `SOUL.md`. Four other rule files had the same stale label, left behind when the service was renamed. GUL-1569 fixed the text. Doing that showed that **nothing protects or keeps the files that steer the agents**:

| Rule files | Read by | In git? | Backed up? |
|---|---|---|---|
| `~/paperclip-agents/{claude-code,opencode,pi}/AGENTS.md` | Paperclip, live (`instructionsBundleMode: external`) | no (`~/paperclip-agents` is not a repo) | no |
| `~/.hermes/SOUL.md`, `~/.hermes/profiles/*/SOUL.md` (7 files) | Hermes, at session start | no | no (`hermes-state-backup` copies `state.db` only) |
| `~/.paperclip/.../agents/<id>/instructions/AGENTS.md` (Tester, Builder, Reviewer, Verifier, Majster, Imhotep) | Paperclip (`managed`) | the sources are in `agents/factory/briefs/` | only as repo copies |

Three more findings:

- **The managed bundles have drifted from the repo.** PRs #204 and #206 (2026-11-11) raised the turn caps to 60 in `agents/factory/briefs/` and in the guard's `roles.json`. The guard was deployed, the briefs never were. The live tester brief still says "turn cap 25" and the reviewer and verifier briefs say 40. The guard enforces 60, so the agents plan against a budget smaller than they actually have. The repo has no deploy step for the briefs.
- **The Hermes instruction gate has a hole exactly where the rules live.** `tools/file_tools_write_guards.py` blocks `write_file`/`patch` on `AGENTS.md`, `CLAUDE.md`, `SOUL.md` and `.cursorrules` in any directory. It has no approval channel in a Paperclip run, so it fails closed. But `_hermes_exempt_homes()` exempts the active profile home **and the Hermes root**, which is the whole `~/.hermes` tree. During GUL-1569, Andrzej rewrote Bill Cipher's and Matejko's `SOUL.md` without being asked, while the same gate blocked him on `~/paperclip-agents/*/AGENTS.md`. ADR-093 point 6 says the agents' own rules are always Wojtek's. The gate enforces that for the Paperclip bundles and not at all for the Hermes personas.
- **GUL-1569 itself broke ADR-093 point 6.** The PM wrote an issue telling an agent to edit five rule files. The gate stopped three of the edits, which was the right call. The two that went through only got in because they sit under `~/.hermes`.

The original proposal on GUL-1569 was to move the three Paperclip bundles under `~/.hermes/` "so the gate does not get in the way". This ADR rejects that.

## Decision

1. **Rule files stay outside the agents' write reach. Do not move them under `~/.hermes`.** The gate blocking an agent on `AGENTS.md` is correct behaviour (ADR-093 point 6), not friction to route around.
2. **Non-personal rules live in git in homelab-2nd.** `agents/instructions/{claude-code,opencode,pi}/AGENTS.md` join `agents/factory/briefs/` as the source of truth. Changes go through a PR that Wojtek merges. The factory cannot write them, because factory-guard's `protected-file` rule blocks it, and that is intended.
3. **One deploy script, `host/paperclip-air/bin/homelab-install-agent-rules.sh`.** It dry-runs by default and writes with `--apply`, and it covers both the external bundles and the managed factory bundles. It writes a backup before each file and keeps a hash manifest of what it last deployed. A live file that differs from the manifest (someone edited it live) is refused and shown as a diff, never silently overwritten. Wojtek runs it on the Air.
4. **Personal rules (the Hermes `SOUL.md` personas) get a backup, not git.** Some carry personal context that doesn't belong in a public repo: billcipher names family members and their access, and zdzislaw holds CV material. (careerpa is an empty folder with no `SOUL.md`.) All seven `SOUL.md` files and the live `AGENTS.md` copies go into the existing nightly restic run to OMV (`vault-backup.sh`) under a new tag, `agent-rules`. Restic snapshots are their history.
5. **Detect what the Hermes gate can't stop.** The memory watchdog (check 10) hashes every rule file **hourly**, compares the result with its previous run, and alerts once per distinct change through its usual Mattermost path. Patching upstream Hermes to narrow the exemption is out of scope for now.
6. **The fleet rules name the correct restart command:** `sudo launchctl kickstart -k system/dev.voitech.homelab.hermes-gateway`, next to the existing "never restart it yourself" rule. An agent that tells Wojtek what to run should give him a command that works.
7. **PM rule:** an issue never tells an agent to edit a rule file. Rule-file changes are written as a PR for Wojtek, or as an owner step on the issue.

## Implementation notes (GUL-1572, 2026-11-15)

- **The factory guard is a second writer.** At 16:42:14, a Pi session that had started before the owner's 16:20 label fix ended, and its diff guard restored all three `~/paperclip-agents/*/AGENTS.md` to its session-start snapshot (`~/.pi/agent/factory-guard/blocks.jsonl`, rule `restore-outside-repo`). The guard can't tell an owner edit from an agent's. So the deploy script **refuses `--apply` while any `factory-guard/index.ts` process runs**, and check 10 catches a revert within the hour.
- **"Known" live content.** The script overwrites a live file only when it matches the last deploy (`~/paperclip-agents/.deployed.sha256`) or a version once committed at that repo path (`git hash-object` against the file's history). Anything else is DRIFT. It is refused and printed (`--adopt-live` prints it as a patch for the repo), and replaced only with `--overwrite-drift`. The three bundles were committed verbatim first, so the first deploy is a clean update.
- **Not yet in git:** Majster's managed bundle (613 lines, edited in place on the Air across GUL-1116 to GUL-1431, matching neither `majster-foreman.md` nor `majster-fleet-watch.md`) and Imhotep's (no repo source). Both are covered by the restic snapshot and check 10. The script lists them as `not in git`.

## Consequences

**Positive**
- Every rule an agent runs under has an owner, a history and an off-host copy. Rebuilding the Air no longer loses the fleet's instructions.
- The drift that happened with the turn caps, where the repo said one thing and the agents read another, now fails loudly at deploy time.
- A Hermes agent rewriting a persona becomes visible within a day instead of never.
- The gate keeps meaning something. Nobody learns that "the special directory" is the way around it.

**Negative**
- A one-word rule fix now costs a PR plus an owner run on the Air, instead of an agent edit. This is deliberate: it is the same cost ADR-093 already accepted for code.
- `SOUL.md` changes are seen only after the fact (by up to 24 h), not prevented. A malicious or confused Hermes edit can steer a few sessions before anyone sees the alert.
- Two sources of truth with different privacy: git for `AGENTS.md`, restic for `SOUL.md`. The script and this ADR have to say which file lives where.

## Alternatives considered

- **Move the Paperclip bundles under `~/.hermes/`** (the GUL-1569 proposal). It would get them into the state-backup's reach and make the gate stop blocking. That is the problem: it makes them agent-writable and contradicts ADR-093 point 6. And today's backup wouldn't save them anyway, since it copies only `state.db`. Rejected.
- **Exempt `~/paperclip-agents` in the gate's config.** The gate accepts only extra *protected* patterns (`security.protected_instruction_extra_patterns`), not exemptions, and an exemption would have the same flaw as the move. Rejected.
- **A private git repo for all rule files, `SOUL.md` included.** It gives history and review for the personas too, but adds a new repo, a deploy key on the Air, and a second PR flow. Worth revisiting if persona edits become frequent. For now, restic history and the drift alert are enough. Deferred.
- **Patch Hermes so the gate covers `~/.hermes/**/SOUL.md` and asks over the gateway.** That would prevent the edits rather than detect them, but it means forking upstream code that is updated weekly, and in a Paperclip run there's still no human to approve. Deferred to upstream.
- **Status quo with a "re-read the rules after a rename" checklist.** That is prompt-level enforcement, which ADR-093 already calls documentation, not a guard. Rejected.

## When to revisit

- Hermes gains a per-path policy, or an approval channel that works in Paperclip runs. Then prevention can replace detection for `SOUL.md`.
- Persona edits become frequent enough that restic history isn't reviewable. Then move to the private-repo alternative.
- Paperclip can load managed bundles straight from a git ref. Then the deploy script goes away.
- A rule file is found edited with no drift alert. Then the alert is broken, and that is an incident, not a tweak.
