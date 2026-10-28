# factory guard self-test (GUL-437)

ADR-093 decision 4: *a daily self-test — if any role does not refuse a
forbidden edit, the factory stops.*

- `guard-selftest.sh` runs the **installed** guard copy's full role matrix
  (`$FACTORY_GUARD_DIR/tests/guard-check.sh`, all four roles, scripted
  provider, zero tokens) and checks the installed copy is byte-identical to
  `agents/factory-guard/` on `origin/main`. Drift is a failure: the fix is to
  re-copy from main (GUL-311 recipe), never to edit the installed copy.
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
- Overrides for testing: `FACTORY_GUARD_DIR`, `FACTORY_STATE_DIR`,
  `FACTORY_REPO_DIR`, and `FACTORY_SELFTEST_REEXEC=1` (run this exact copy —
  used by the negative test; never point `FACTORY_GUARD_DIR` at the installed
  dir when loosening roles, use a temp copy).
