# factory guard self-test (GUL-437)

ADR-093 decision 4: *a daily self-test — if any role does not refuse a
forbidden edit, the factory stops.*

- `guard-selftest.sh` runs the **installed** guard copy's full role matrix
  (`$FACTORY_GUARD_DIR/tests/guard-check.sh`, all four roles, scripted
  provider, zero tokens) and drift-checks three things against `origin/main`,
  all byte-exact (ignoring `node_modules`/`.DS_Store`): the installed guard
  copy (`agents/factory-guard/`), the installed entry script and the installed
  plist. Drift is a failure: the fix is to re-copy/reinstall from main, never
  to edit the installed copies.
- launchd runs the entry from `~/paperclip-agents/factory-selftest/` —
  deliberately outside the shared checkout: concurrent agent runs park
  `~/Projects/homelab-2nd` on their own branches, and a repo-path entry then
  simply isn't there at 04:45 (happened on GUL-437's first kickstart after
  merge #65; the entry + plist drift checks mean a skipped reinstall is caught
  the next morning instead of rotting in `launchd.err.log`).
- Any failure writes `~/paperclip-agents/majster/factory/STOP` with the time,
  the role and the failing assertion (no command text). The script **never**
  deletes or overwrites STOP — only a person clears it, after the fix. While
  STOP exists, `factory start` and `factory decide` refuse (wiring issue).
- Every run appends one line to `~/paperclip-agents/majster/factory/selftest.log`:
  time, PASS/FAIL, per-role results. The last raw matrix output is kept in
  `last-guard-check.out` next to it.
- Schedule: launchd `dev.voitech.factory-guard-selftest`, daily 04:45 Warsaw
  (plist here; install/load steps in its comment). Not a Paperclip routine —
  no model run, no tokens.
- The script re-execs the `origin/main` copy of itself so a shared checkout
  that some concurrent agent run switched to a feature branch cannot decide
  what the 04:45 test actually tests.
- Overrides for testing: `FACTORY_GUARD_DIR`, `FACTORY_ENTRY_DIR`,
  `FACTORY_PLIST_PATH`, `FACTORY_STATE_DIR`, `FACTORY_REPO_DIR`, and
  `FACTORY_SELFTEST_REEXEC=1` (run this exact copy — used by the negative
  test; never point `FACTORY_GUARD_DIR` at the installed dir when loosening
  roles, use a temp copy).
