# ADR-043: Grey-zone supervisor as its own Hermes profile, and a per-project OpenChamber worker lane

- **Status:** Accepted
- **Date:** 2026-10-09
- **Supersedes:** nothing. Related: ADR-042 (grey-zone Anthropic reseller routes on LiteLLM), ADR-022
  (`itsaplan-tasks` skill for the delegated worker), ADR-019 (bridge posts results to the source issue).

## Context

The homelab runs autonomous work through two existing mechanisms:

1. **Andrzej** — the H2 orchestrator profile (`deepseek-v4.1-flash-ollama`), which plans and delegates
   via the Itsaplan **H2** board.
2. **OpenChamber's `itsaplan-worker`** — a `qwen`/`deepseek`-class worker driven by the H2 runner,
   which executes delegated code and cluster work and reports back via ticket comments.

Two things were missing for the Star-Office-UI fork (Itsaplan project **SOU**):

- A **strong supervisor**. The experiment the user actually wants to run is: an expensive, capable
  model plans and delegates; a cheap model grinds. Andrzej is deliberately a cheap, fast model and is
  already busy with the homelab.
- A **worker that can execute SOU work at all**. The only runner (`openchamber-itsaplan-runner`)
  authenticates as the **H2** OpenChamber agent, so it polls the H2 queue only. SOU had one agent
  (Andrzej, id 3), a `Member` role carrying `ai_agents.create: false`. A SOU delegation therefore
  produced **no `agent_run` row and no error** — a silent stall. Worse, OpenChamber is a
  *member/owner* of SOU but not a registered AI agent there, so delegating to it fails outright with
  `Delegate must be an agent of this project`.

Meanwhile the grey-zone Anthropic reseller keys had just been wired into LiteLLM (ADR-042), giving the
homelab access to Opus 5.5 at reseller prices — the first time a genuinely strong model was
affordable for unattended work.

## Decision

**Two decisions, taken together, because neither is useful alone.**

### 1. The grey-zone supervisor is a dedicated Hermes profile: `szarik`

A **separate profile** (`szarik`), not a modified Andrzej and not a shared escalation route on an
existing profile. It runs `claude-opus-5-5-oneprovider` through LiteLLM, owns:

- its own LiteLLM virtual key (`hermes-szarik`, scoped to the 11 grey routes),
- its own OpenViking user (`szarik` in account `homelab`) with its own key,
- its own Mattermost bot (`szarik`) with its own token,
- its own Itsaplan agent identity on **SOU** (agent id 4, `runnerScope: project`),
- its own `SOUL.md` carrying the grey-zone trust rules and the fork's three hard rules.

Its `.env` holds **no** credential belonging to another profile.

### 2. Each Itsaplan project gets its **own** worker lane, not a shared queue

The fork gets a **second runner Deployment** —
`openchamber-itsaplan-sou-runner` — that is a distinct lane, not a second replica of the H2 runner:

| | H2 lane | SOU lane |
|---|---|---|
| Itsaplan identity | agent id 2 (`itp_Hz…`) | agent id 5 (`itp_iz…`) |
| Workspace | `/storage/workspaces/homelab-2nd` | `/storage/workspaces/star-office-ui-fork` |
| opencode agent | `itsaplan-worker` | `itsaplan-worker-sou` |
| Model | `deepseek-v4.1-flash` | `qwen3.8-flash-go` |

The opencode config is seeded at **v4** with the second agent; the H2 lane and its agent are unchanged.

## Consequences

**Positive**

- The experiment is now measurable: Opus 5.5 supervises, `qwen3.8-flash-go` grinds, and LiteLLM
  `/metrics` attributes every token to `api_key_alias="hermes-szarik"` vs the worker's key.
- SOU work no longer silently stalls. A SOU delegation now produces a run row, is claimed, and
  reports back on the SOU ticket.
- Blast radius is contained: the grey-zone keys are trust-unknown, and a compromised or lying provider
  affects only the profile that uses them, not the homelab orchestrator.
- Credential isolation is real: every identity Szarik holds is its own, so rotating any one of them
  does not touch Andrzej, OpenChamber, or the other lane.
- The lanes can be tuned independently — model, workspace, timeout, concurrency — without a shared
  blast radius. Two replicas of one Deployment could not do this because they would collide on the
  API key and therefore on the agent identity.

**Negative**

- Three more moving parts to keep alive: a profile, an agent identity, and a runner. A dead lane is
  silent by design (the runner only logs claim *failures*), so a stalled SOU delegation is
  indistinguishable from a quiet one unless the `agent_run` table is read.
- The fork's worker runs on the **same** OpenChamber pod as the H2 worker. Concurrency is `1` per
  lane, so two lanes can now run two sessions at once — more load on the t460 node than before.
- Szarik's prompts and completions pass through a reseller with no SLA and no privacy guarantee.
  Mitigated by `SOUL.md` rules (never send secrets through the model route) — mitigated, not solved.
- The god-user Itsaplan key was used to create the two SOU agents, because an agent's default
  `Member` role cannot register agents. That key has now been used for provisioning by an agent, which
  widens what its compromise would mean.
- Two profiles + two lanes means the "which agent said this" question now has four answers
  (Andrzej, Szarik, H2 worker, SOU worker), and the board only distinguishes them by username.

## Alternatives considered

- **Give Szarik a key for the existing H2 lane.** Rejected: the H2 runner polls the **H2** queue as the
  H2 OpenChamber agent. A fork delegation must not land in the homelab's queue — different workspace,
  different model, different repo, different rules.
- **Reuse one OpenChamber agent identity on both projects.** Rejected: agent identities are
  per-project, and the two lanes need different workspaces and models. Sharing the identity also
  removes the ability to tell from the run feed which project's work is executing.
- **Second replica of the H2 runner Deployment.** Rejected: both replicas would present the same API
  key, so both would poll the same agent's queue and could double-claim a run.
- **Add Szarik to the existing `andrzej` profile as a second model route.** Rejected: the whole point
  is a separate principal. Sharing a profile also shares memory, sessions and the bot identity, and
  would put reseller-routed work under the homelab orchestrator's credentials.
- **Let OpenChamber (H2 agent) be delegated SOU work.** Not possible: it is not an agent of SOU, and
  the API refuses with `Delegate must be an agent of this project`.
- **Have Andrzej create the SOU agents itself.** Not possible: its SOU role is `Member` with
  `ai_agents.create: false`. Provisioning required the god-user key.
- **One shared runner lane with a project filter.** Would need a runner feature that does not exist in
  `@itsaplan/runner@0.5.0`; the lane *is* the filter.

## When to revisit

- **If the reseller routes die or get pricier than first-party.** Szarik becomes pointless as an Opus
  5.5 harness; switch its `model.default` to a first-party model or fold it back into Andrzej.
- **If the two lanes starve each other on the t460 node.** At that point either serialise them with a
  shared lock or give the fork lane its own OpenChamber instance.
- **If `@itsaplan/runner` gains per-project filtering** — one lane could serve both queues and the
  second Deployment should be retired.
- **If OpenViking's account boundary is fixed to allow a genuine cross-account shared scope** — the
  memory-bridge workaround (delegating reads to an agent in the other account) can be retired.
- **If `ai_agents.create` is granted to a non-god role** — provisioning should move off the god-user
  key.
- **If the fork is abandoned.** The fork is explicitly personal-use and disposable; if it goes, so do
  SOU-12's chain, the `itsaplan-worker-sou` agent, its workspace and the second lane. Removal should be
  one commit plus three deletions from `kustomization.yaml`.
