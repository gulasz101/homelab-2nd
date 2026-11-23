# Factory auto-merge runbook (GUL-2037 phase 4)

What the factory does when a work order's gate passes, and how to stop it.
Contract: `agents/factory/ENGINE.md`, section "Auto-merge".

## How auto-merge works

1. The gate runs `factory.py check-gate --split-safety` on the work order's PR.
   A never-path hit is reported as `safety` instead of failing the gate.
2. With `safety` empty, `pr.head` recorded, `"autoMerge": true` in
   `agents/factory/engine.json` and the tick running `--apply`, the engine asks
   `ghapp.py` for an installation token and posts the self-approvals on the PR:
   every passed stage, every investigation verdict, the finding counts, the gate.
3. It then runs `gh pr merge <n> --squash --match-head-commit <pr.head>`, so
   GitHub merges exactly the commit the stages checked, or nothing at all.
4. Every other outcome (no key, a GitHub error, a refused merge) means the owner
   merges on GitHub. That is never a stall: the order already passed every check,
   and the work-order comment names the first condition that did not hold.
5. The tick then reads `gh pr view` and settles the order once the merge commit
   contains the branch head. A merge that does not is `unlanded`, never `done`.

## Where the key lives

- The merge identity is the GitHub App `gulasz101-factory`, App ID `5893473`
  (`githubApp.appId` in `agents/factory/engine.json`).
- The private key is a PEM file under `/Users/paperclip/.config/factory/`, one
  file per App, mode 600, readable only by the account that runs the tick.
  The directory is mode 700.
- `FACTORY_GH_APP_KEY_FILE` names that PEM. The launchd daemon inherits
  `EnvironmentVariables` only, so the variable belongs in
  `dev.voitech.factory-engine.plist`. With no variable, `ghapp.py` reads the
  macOS keychain item, service `factory-github-app`, account `5893473`, value
  base64 on one line.
- `ghapp.py` signs the App JWT with `openssl` and asks for an installation token
  scoped to the one order's repository (contents and pull requests write). The
  token is cached mode 600 in the engine state dir until 5 minutes before it
  expires. It is never printed, committed or written to a comment.

## What GitHub enforces

- The `protect-main` ruleset requires the `check` run and a code-owner review,
  and the GitHub App is not on its bypass list.
- `.github/CODEOWNERS` names @gulasz101 for every path listed in
  `agents/factory/never-paths.json`: SOPS files, `clusters/`, AGENTS.md and
  SOUL.md, the factory and guard trees, workflows, the tunnel manifests and
  `docs/adr/`. A never-path PR cannot merge without the owner's review.
- `--match-head-commit` is the second line of defence: a permitted merge cannot
  land a commit that no stage of the work order checked.

## How to stop the factory

`touch ~/paperclip-agents/majster/factory/STOP` (or the path in `FACTORY_STOP`).
A tick that finds `STOP` prints `stopped`, exits 0 and writes nothing: no stage
issue, no comment, no merge, no state file. Remove the file to resume.
To keep the pipeline running and stop only auto-merge, set `"autoMerge": false`
in `agents/factory/engine.json`: the next tick reads it and the owner merges.
