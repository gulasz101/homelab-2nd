# ADR: The weekly model sync stops at a pull request, never at a pushed main

- **Status**: Pending
- **Date**: 2026-11-01
- **Issue**: GUL-721
- **Related**: ADR-093 (the owner keeps the merge button), ADR-111 (ADR numbers are allocated at adoption), GUL-302 (CI is one job named `check`)

## Context

`apps/llm-hub/scripts/weekly-model-sync.py` was written when `main` accepted pushes from the Air. Its
last step was `git push origin main`, and everything after it — Flux reconcile, waiting for the two
HelmReleases, triggering the key provisioner, verifying `/v1/models` — assumed the push had landed.

On 2026-10-28 the `protect-main` ruleset went live: required status check `check` with
`strict_required_status_checks_policy: true`, non-fast-forward blocked, deletion blocked, and a
**DeployKey** bypass — no user bypass (`current_user_can_bypass: never`). Measured on 2026-11-01
(the first sync since the ruleset):

```
remote: error: GH013: Repository rule violations found for refs/heads/main.
remote: - Required status check "check" is expected.
 ! [remote rejected] main -> main (push declined due to repository rule violations)
```

The script had already written its commit, so the run died with a committed-but-unpushed change:
nothing reconciled, no keys minted, no verification. Two verified model additions sat on the Air and
the cluster knew nothing about them. The failure mode is worse than a refusal — the job looks like it
did work.

## Decision

**The sync never claims a landing it did not make.** It tries `git push origin main` exactly as
before, and when that push is refused by a ruleset marker (`GH013`, `repository rule violations`,
`protected branch`, `Required status check`):

1. it pushes the same commit to `feat/weekly-model-sync-<UTC date>-<short sha>` and runs
   `gh pr create --base main` against that branch;
2. it **stops before any cluster work** — no Flux annotation, no `kubectl create job`, no proxy
   check. Cluster state must not move for a change git has not accepted;
3. it resets the local checkout to `origin/main`, so next week's `preflight()` still finds a clean
   `main` that matches the remote instead of a checkout that is one commit ahead and refuses to run;
4. it exits **4** — awaiting the owner's merge — distinct from `3` (a dead upstream route survived).

Any other push failure is still a hard error: an unrecognised rejection is not silently turned into a
PR, because the cause would be unknown.

The owner merges. Flux applies the merged commit on its own interval and the key provisioner runs on
its own schedule; the sync does not watch either across a merge that happens after the run exits.

Auto-merge, a bot bypass and a `DeployKey` for the Air are all rejected: merging is the owner's job
(ADR-093), and the `check` gate exists precisely so that a change reaches `main` with CI green under a
human's name on the button.

## Consequences

- **A weekly run that adds models ends at a PR, not at a live change.** The routine's issue is the
  handoff: PR link, what was verified, what must be merged. One click, then Flux.
- **Exit code 4 is a new state** for whatever watches this job (currently a Paperclip routine, no
  CronJob). It means "reviewable, nothing live" — not a crash and not success.
- **The failure that started this became visible in one run instead of never.** Before, the script
  raised `CalledProcessError` from `git push` and left the tree dirty for a week.
- **`--dry-run` is unchanged**: it exits before the commit and never reaches the push path.
- **Two branches if the same day is retried**: the branch name carries the commit sha, so a re-run
  never force-pushes over the previous attempt (and force-push is not an option the sync has).
- **Cost when it works**: one unmergeable-for-agents PR per week that adds nothing — the sync still
  runs weekly and reports "No changes" when the catalogue has not moved.

## Alternatives considered

- **Give the sync a `DeployKey` that bypasses `protect-main`.** The ruleset already has a DeployKey
  bypass, so this is technically one setting. Rejected: it converts the owner's merge gate into a
  formality for every future automation that gets that key, and the bypass exists for Flux's pull
  path, not for writes. Revisit only if the owner decides a specific sync key may write `main`.
- **`gh pr merge --auto` at the end of the run.** The PR merges itself once `check` is green.
  Rejected on policy (ADR-093, and `agents/factory-guard` denies `gh pr merge` outright), and it
  leaves nobody reading the diff on a change that mutates the fleet's model list.
- **Push, then poll the PR until merged inside the same run.** The owner may merge in the evening;
  the run would die at the 90-minute wall and hold a run slot for nothing.
- **Keep the crashing push and let the agent handle it by hand each week.** This is what happened
  today: it works, and it depends on an agent being awake to notice a `CalledProcessError` in a log.
- **Drop `strict_required_status_checks_policy` so a direct push can pass CI afterwards.** The
  ruleset's whole point is that the check runs *before* the merge; loosening it to save the sync a
  PR trades a guarantee for a convenience.

## When to revisit

- If the sync moves into a k3s CronJob that owns its own credential, the "Air's checkout" assumption
  in step 3 stops being true.
- If `protect-main` gains a branch exception for `feat/weekly-model-sync-*`, the PR path can go
  straight to `main` with the check's verdict attached.
- If a weekly PR with nothing to review becomes noise, the answer is to skip opening it when the
  catalogue has not moved — not to bypass the merge.
