#!/usr/bin/env python3
"""A repo with no neverPaths is never auto-merged (GUL-2254, F-1 of GUL-2238).

AC-1: through the real `Engine.step_gate`, a repo with no `neverPaths` is never
      merged by the App, and `st["gate"]["autoMerge"]["why"]` contains
      'no never-path list'.

The hole this pins: `step_gate` used to record `never_paths or
factory.NEVER_PATHS_REL` into `st["gate"]["neverPaths"]`, so `never_paths_list`
was never empty after a gate run and `auto_merge` never reached its "the engine
cannot name a never-path list, only the owner merges" branch. The check below
drives the real step (no stubbed `auto_merge`), with `check-gate`, `gh pr
checks`, the App token and `subprocess` stubbed, so the decision and the `gh pr
merge` call are both observed. The positive control — a repo that does carry
neverPaths still merges — keeps the AC from passing just because nothing merges.

Stdlib only, offline, no `$HOME`/`/Users`/in-repo-absolute paths: the engine is
loaded from this checkout, everything else is generated in-process, so the Mac
and the GitHub runner agree.

    python3 agents/factory/tests/test_no_never_paths_merge.py
    python3 agents/factory/tests/test_no_never_paths_merge.py --ac AC-1

Prints one `AC-<n>: PASS|FAIL <reason>` line per covered AC; exit 0 only when
every covered AC passes, 1 when any fails (CONTRACT.md point 2).
"""

import importlib.util
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE_PY = os.path.abspath(os.path.join(HERE, "..", "engine.py"))
REPO = "gulasz101/homelab-2nd"
NEVER_PATHS = "safety/never-paths.json"

# GUL-2080: an inherited GIT_DIR makes fixture repos write into the real checkout.
for _var in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
             "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
             "GIT_NAMESPACE", "GIT_PREFIX", "GIT_CONFIG", "GIT_CONFIG_GLOBAL"):
    os.environ.pop(_var, None)


class FakeApi:
    def __init__(self):
        self.patches = []
        self.comments = []

    def patch_issue(self, issue_id, body):
        self.patches.append((issue_id, dict(body)))

    def comment(self, issue_id, text):
        self.comments.append((issue_id, text))

    def write_document(self, *args, **kwargs):
        return None


class RecordingSubprocess:
    """Stands in for the `subprocess` module inside engine.py; records argv."""

    PIPE = subprocess.PIPE
    STDOUT = subprocess.STDOUT
    CompletedProcess = subprocess.CompletedProcess
    TimeoutExpired = subprocess.TimeoutExpired
    CalledProcessError = subprocess.CalledProcessError

    def __init__(self):
        self.calls = []

    def run(self, cmd, **kwargs):
        self.calls.append(list(cmd))
        return subprocess.CompletedProcess(list(cmd), 0, "", "")


class FakeGateResult:
    """What `factory.py check-gate` returns: a passing gate, no size note."""

    def __init__(self, args):
        self.name = args[0] if args else "check-gate"
        self.code = 0
        self.parsed = {"ok": True, "check": "gate", "reasons": []}
        self.ok = True
        self.reasons = []
        self.line = ""
        self.tail = []
        self.fails = []

    def require_json(self):
        return self


def load_engine():
    spec = importlib.util.spec_from_file_location("factory_engine_under_test_no_np", ENGINE_PY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def engine_for(module, repo_cfg, api, global_cfg=None):
    repo_entry = {"clone": "/nonexistent/clone", "worktrees": "/nonexistent/worktrees",
                  "projectId": "11111111-2222-3333-4444-555555555555"}
    repo_entry.update(repo_cfg)
    cfg = {"repos": {REPO: repo_entry}, "autoMerge": True, "postMergeCheck": True}
    cfg.update(global_cfg or {})
    eng = module.Engine(cfg, api, True)
    eng.save = lambda st: None
    eng.finish = lambda st: None
    eng.retain = lambda st: None
    eng.cleanup = lambda st: None
    eng.app_env = lambda st: ({}, "")
    return eng


def work_order_state(**extra):
    st = {"workOrder": "GUL-2254", "workOrderId": "wo-2254", "repo": REPO, "round": 1,
          "phase": "gate", "stages": [], "findings": [], "investigations": [],
          "baseSha": "b" * 40, "specFile": "/dev/null",
          "pr": {"number": 12, "url": "https://example.invalid/pull/12",
                 "head": "h" * 40, "base": "b" * 40}}
    st.update(extra)
    return st


def step_gate_run(module, repo_cfg, global_cfg=None):
    """Run the real step_gate; return (state, api, subprocess calls, gate argv).

    `auto_merge` is NOT stubbed: the decision the AC talks about is the one the
    engine actually makes, and the `gh pr merge` it would run is recorded by the
    fake `subprocess` module.
    """
    api = FakeApi()
    eng = engine_for(module, repo_cfg, api, global_cfg)
    rec = RecordingSubprocess()
    gate_calls = []

    def fake_run_factory(args):
        gate_calls.append(list(args))
        return FakeGateResult(list(args))

    orig = (module.subprocess, module.run_factory, module.gh_pr_checks)
    module.subprocess = rec
    module.run_factory = fake_run_factory
    module.gh_pr_checks = lambda repo, number: [{"name": "check", "state": "SUCCESS"}]
    st = work_order_state()
    try:
        eng.step_gate(st)
    finally:
        module.subprocess, module.run_factory, module.gh_pr_checks = orig
    argv = gate_calls[0] if gate_calls else []
    return st, api, rec.calls, argv


def _merges(calls):
    return [c for c in calls if len(c) > 1 and c[1] == "pr" and "merge" in c]


def ac1():
    """No neverPaths: the App never merges and the reason names the missing list."""
    fails = []
    module = load_engine()

    st, api, calls, argv = step_gate_run(module, {})
    gate = st.get("gate") or {}
    auto = gate.get("autoMerge") or {}
    why = str(auto.get("why") or "")

    # The gate still runs on the factory's shipped list (ENGINE.md): no repo
    # neverPaths means the flag is absent, not an empty value.
    if any(str(a) == "--never-paths" for a in argv):
        fails.append("the gate command for a repo with no neverPaths passed --never-paths: %r"
                     % (argv,))

    if auto.get("merged") is not False:
        fails.append("step_gate merged (or recorded no decision) for a repo with no neverPaths: "
                     "autoMerge=%r" % (auto,))

    if "no never-path list" not in why:
        fails.append("st['gate']['autoMerge']['why'] does not name the missing never-path list "
                     "(why=%r)" % (why,))

    merges = _merges(calls)
    if merges:
        fails.append("the engine ran a merge command for a repo with no neverPaths: %r" % (merges,))

    if st.get("phase") != "awaiting_merge":
        fails.append("the order left step_gate in phase %r; the owner still has to merge it"
                     % (st.get("phase"),))

    comments = [str(body.get("comment") or "") for _issue, body in api.patches]
    if not comments:
        fails.append("step_gate posted no comment, so the owner was never told to merge")
    elif any("the factory merged it" in c.lower() for c in comments):
        fails.append("the gate comment claims the factory merged a PR it did not merge: %r"
                     % (comments[-1][:300],))

    # Positive control: the same path, with a neverPaths, does auto-merge. Without
    # it this AC would pass on a build that never merges anything.
    st2, _api2, calls2, argv2 = step_gate_run(module, {"neverPaths": NEVER_PATHS})
    auto2 = (st2.get("gate") or {}).get("autoMerge") or {}
    if auto2.get("merged") is not True:
        fails.append("positive control: a repo with neverPaths %s and global autoMerge true did "
                     "not merge (autoMerge=%r)" % (NEVER_PATHS, auto2))
    merges2 = _merges(calls2)
    if not merges2:
        fails.append("positive control: a repo with neverPaths ran no `gh pr merge`")
    else:
        cmd = [str(x) for x in merges2[0]]
        if "--squash" not in cmd or "--match-head-commit" not in cmd \
                or ("h" * 40) not in cmd:
            fails.append("positive control: the merge command is not the squash pinned to the "
                         "checked head: %r" % (cmd,))
    if "--never-paths" not in argv2 or NEVER_PATHS not in [str(a) for a in argv2]:
        fails.append("positive control: the repo's neverPaths did not reach the gate: %r" % (argv2,))

    return fails


CHECKS = {"AC-1": ac1}


def main(argv):
    wanted = ["AC-1"]
    if "--ac" in argv:
        idx = argv.index("--ac")
        want = argv[idx + 1] if idx + 1 < len(argv) else ""
        if want not in CHECKS:
            sys.stderr.write("usage: %s [--ac AC-1]\n" % os.path.basename(__file__))
            return 2
        wanted = [want]
    bad = 0
    for ac in wanted:
        try:
            fails = CHECKS[ac]()
        except Exception as exc:  # noqa: BLE001 - a check that cannot run is a FAIL here
            fails = ["%s: %s" % (type(exc).__name__, exc)]
        if fails:
            bad = 1
            sys.stdout.write("%s: FAIL %s\n" % (ac, fails[0]))
            for extra in fails[1:]:
                sys.stdout.write("  also: %s\n" % extra)
            sys.stderr.write("%s: %d failing assertion(s)\n" % (ac, len(fails)))
        else:
            sys.stdout.write("%s: PASS\n" % ac)
    return bad


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
