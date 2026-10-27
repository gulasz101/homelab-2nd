# ADR-093: Pi-only code factory with scripted gates; Wojtek keeps the merge button

- **Status**: Accepted
- **Date**: 2026-10-27
- **Issue**: GUL-262 (plan revision `694de18c`, approved by the owner 2026-10-27, card `1cac7bd2`); this ADR filed by GUL-304
- **Related**: ADR-075 (org and runtimes — this amends its executor model), ADR-087, ADR-088, ADR-089 (Majster and the morning PM — this amends what they review), ADR-090 (OpenCode deny rules — this is why OpenCode is paused for code work)

## Context

Every bit of code the agents produced so far was trusted, then checked by hand, and
merged by a person. The numbers from the GUL-262 analysis:

- All 36 merged homelab-2nd PRs were merged by Wojtek by hand, median 36 minutes after
  they opened. The checks (`render-check.sh`, `kubeconform`, `gitleaks`, `adr-check.sh`)
  were hand-run only — nothing bound a "green" claim to the PR's head commit.
- Prompt-level guards leaked three times: GUL-162 (OpenCode deny rules never enforced
  in Paperclip runs, ADR-090), GUL-131, GUL-206. A rule written in prose is
  documentation, not enforcement.
- Pi has no turn limit (GUL-205): a fidgeting agent burns the weekly quota while
  producing nothing.
- keel-v2 (single author, v0.18.57, read at commit `1015fd6`) showed where reliability
  actually comes from: scripts that check every step — a test must fail, then pass; a
  guard reverts forbidden diffs; a second agent must prove every finding — not smarter
  models. Notably, keel's final review is always a person and it never auto-merges.
  This design goes further than keel, but only after the numbers arrive.

Wojtek approved the plan on [GUL-262](/GUL/issues/GUL-262) on 2026-10-27. This ADR
records that decision: what the factory is, who runs it, and who holds the merge button.

## Decision

1. **Code changes go through a Pi-only factory with one narrow role per agent.**
   Tester (writes the failing test or check first; may edit only tests), Builder
   (makes it pass; the tests are frozen), Reviewer (read-only, a different model
   family from the Builder, so the two do not make the same mistake), Verifier
   (read-only, proves or rejects every finding), Inspector (read-only, answers the
   "may" gates). Roles never share a session. A Pi session survives only inside one
   stage: `pi_local` resumes per agent and issue, so a Builder sent back continues
   where it stopped and the Reviewer always starts fresh.
2. **Majster becomes the Foreman.** A script moves each work order through its stages
   (child issues, blockers, review stages with Majster as participant) and runs the
   checks. No model decides whether a check passed; Majster's model handles only what
   the script flags.
3. **Every repo gets one `check` command**, run by a GitHub Action on every PR. No
   green check on the PR's head commit, no merge.
4. **Guards live in code, not in prompts.** The `factory-guard` Pi extension is a
   tool gate that fails closed, a path allowlist per role, a diff guard that reverts
   files outside it when a run ends, a turn cap per role, a repeat guard (the same
   failing command twice with nothing changed is refused), and a daily self-test: if
   any role does not refuse a forbidden edit, the factory stops. Prompt rules are
   documentation only.
5. **Merge gate.** Wojtek merges everything in phases 1 and 2. In phase 3 the Inspector
   runs in shadow mode and writes "would merge" or "would ask Wojtek, because ..." on
   every PR. After it agrees with Wojtek on 20 PRs in a row it may merge the low-risk
   kinds alone: docs, tests, and the pilot repo with green CI. homelab-2nd manifests
   stay with Wojtek until the numbers say otherwise.
6. **The "never" list — always Wojtek's, no gate can waive it:** secrets, `.sops.yaml`
   and anything SOPS-encrypted; `clusters/` (the Flux bootstrap), CNPG clusters and
   backups, PVCs and storage, anything that deletes data; public exposure (Cloudflare
   tunnels, ingress); the agents' own rules (AGENTS.md, SOUL.md, the guard, the
   factory config, the CI workflows); a new dependency, a budget or quota increase; a
   new ADR with a real alternative.
7. **Hermes leaves the code path.** Bill Cipher, Florian, Zdzisław, Matejko and Szarik
   stay on Hermes. Andrzej moves to Ops: cluster and host work, break-glass, live
   checks after a merge, and the failures the factory cannot fix (Docker, ports, keys,
   network). OpenCode is paused for code work until it passes the same guard
   self-test, then returns only as an overflow Builder.
8. **Claude Code (PM) writes specs with checkable criteria** — each acceptance
   criterion names its check — owns the gate policy, and reads the factory's ledger
   and escalations each morning. It stops reading every diff, and it audits the
   Inspector instead of being the Inspector: it runs once a day and its tokens are the
   most expensive.
9. **Rollout.** Phase 1 (week 1): the `check` command, the GitHub Action, the
   factory-guard with its self-test, and this ADR. Phase 2 (week 2): the factory
   script (tick, check, commit, open PR), Majster's Foreman brief, the new agents
   (Tester, Reviewer, Verifier; Pi becomes the Builder), and 5 real work orders end to
   end. Phase 3 (weeks 3 and 4): the Inspector in shadow mode, then limited
   auto-merge. Pilot repo: homelab-2nd, because Wojtek has not named another project.
10. **Copy keel-v2's ideas; do not install keel.**

## Consequences

- **More runs per change**: about 5 agent runs plus 3 short Majster check runs instead
  of the 1 or 2 today. The OpenCode Go weekly quota is the real limit, so each stage
  gets a token cap.
- **Flash models will fail the red and green checks more often** than Opus-grade
  models would. That is the point: the check catches it, the loop retries twice, then
  escalates. Phase 2 produces the real first-pass numbers.
- **Paperclip's own failure modes remain** (recovery holds, deferred wakes, stray
  cards) because the pipeline is built from issues, blockers and review stages rather
  than keel's checkpointed engine. If Majster's model turns out to be the weak link,
  the tick can run from launchd with Majster's agent key and no model at all.
- **Auto-merge on homelab-2nd means auto-deploy** — which is exactly why manifests
  stay with Wojtek even after the Inspector earns phase 3.
- **Once the guard is on, no Pi agent can edit agent instruction files** (AGENTS.md
  and the like). Those changes become Wojtek's, as they should have been all along.
- Positive: every merge decision arrives with a script's verdict on the head commit,
  not an agent's claim; the deterministic base (check, CI, guard) lands before any new
  agent exists, so the factory is built on ground that already proves things.

## Alternatives considered

- **Run keel itself.** Lost: one author, three weeks old, about 30,000 lines of
  engine, changes daily, nothing for GitOps YAML — and Paperclip already is our engine
  and inbox.
- **Keep the generic executors with prompt guards (today's state).** Lost: the guards
  leaked (GUL-162, GUL-131, GUL-206) and Wojtek still reviews every PR — no reliability,
  no time back.
- **A mixed Pi and OpenCode factory.** Lost: two guards to write and test, and
  OpenCode's deny rules never applied in Paperclip runs (GUL-162, ADR-090). Model
  variety through llm-hub gives the same spread without the second harness.
- **Claude Code as the Inspector.** Lost: it runs once a day and its tokens are the
  most expensive — the wrong shape for a per-PR gate. It audits the Inspector instead.
- **Let the Inspector merge from day one.** Lost: there is no evidence yet that it
  decides like Wojtek. Shadow mode and the 20-PR streak are how it earns that.

## When to revisit

- After 20 shadow-mode PRs: the agreement data decides the auto-merge scope. If it
  disagrees with Wojtek even once late in the streak, the clock restarts.
- If first-pass check rates stay low after phase 2: the roles or the model choices
  need re-deciding, not the pipeline.
- If the OpenCode Go weekly quota runs out: the factory is bigger than the free tier
  was budgeted for.
- If keel reaches a stable 1.0 with more contributors: re-evaluate copy-vs-install.
- If Paperclip ships a native workflow engine: the factory script's issue plumbing
  (stages, blockers, wakes) should move onto it.
