#!/usr/bin/env python3
"""Per-repo safety settings in the factory (GUL-2238) — red-stage checks.

AC-1: `check-gate --never-paths-ref` reads the never-path list from the PR's
      base commit, fails as setup when it is missing there, and behaves as
      today without the flag (CONTRACT.md points 2 and 5).
AC-2: the engine passes a repo's neverPaths to the gate, never auto-merges a
      repo with no neverPaths or with autoMerge false, and skips deploy_check
      for a repo with postMergeCheck false (ENGINE.md, per-repo settings).

Stdlib only, offline: a stub `gh` served from generated fixtures, throw-away
git repos under `tempfile.mkdtemp()`, and engine.py driven in-process with
`subprocess`/gh/App-token seams stubbed. Nothing reads `$HOME` or a file
outside the repo and the temp dirs, so the Mac and CI agree.

    python3 agents/factory/tests/test_repo_config.py            (both ACs)
    python3 agents/factory/tests/test_repo_config.py --ac AC-1  (one AC)

Prints one `AC-<n>: PASS|FAIL <reason>` line per covered AC; exit 0 only if
every covered AC passes, 1 if any fails (CONTRACT.md point 2).
"""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FACTORY_PY = os.path.abspath(os.path.join(HERE, "..", "factory.py"))
ENGINE_PY = os.path.abspath(os.path.join(HERE, "..", "engine.py"))
REPO = "gulasz101/homelab-2nd"

# GUL-2080: an inherited GIT_DIR makes fixture repos write into the real checkout.
for _var in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
             "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
             "GIT_NAMESPACE", "GIT_PREFIX", "GIT_CONFIG", "GIT_CONFIG_GLOBAL"):
    os.environ.pop(_var, None)

NEVER_PATHS_BASE = {
    "comment": "fixture: what the PR base commit says",
    "globs": ["secret/**"],
    "newFilesUnder": [],
    "contentRules": {"extensions": [".yaml", ".yml"],
                     "forbiddenKinds": ["Secret"],
                     "forbiddenSopsKey": True},
}
NEVER_PATHS_HEAD = {
    "comment": "fixture: the branch dropped the safety glob",
    "globs": ["infra/**"],
    "newFilesUnder": [],
    "contentRules": {"extensions": [".yaml", ".yml"],
                     "forbiddenKinds": ["Secret"],
                     "forbiddenSopsKey": True},
}

STUB_GH = '''#!/usr/bin/env python3
"""Stub `gh` for the GUL-2238 checks: reads fixture JSON, never the network."""
import base64
import json
import os
import sys

fixtures = os.environ["GH_STUB_FIXTURES"]
with open(os.path.join(fixtures, "pr.json"), "r", encoding="utf-8") as fh:
    meta = json.load(fh)
args = sys.argv[1:]


def out(obj):
    sys.stdout.write(json.dumps(obj))
    sys.exit(0)


if args[:2] == ["pr", "view"]:
    out(meta["view"])
if args[:2] == ["pr", "checks"]:
    out([{"name": "check", "state": "SUCCESS"}])
if args[:1] == ["pr"] and "ready" in args:
    sys.exit(0)
if args[:1] == ["api"]:
    target = ""
    for arg in args[1:]:
        if "contents/" in arg:
            target = arg
            break
    if not target:
        sys.stderr.write("stub: unsupported api call %r\\n" % (args[1:],))
        sys.exit(1)
    rel = target.split("contents/", 1)[1].split("?", 1)[0]
    ref = ""
    if "ref=" in target:
        ref = target.split("ref=", 1)[1].split("&", 1)[0]
    which = "base" if ref == meta["baseSha"] else "head"
    path = os.path.join(fixtures, which, rel)
    if not os.path.isfile(path):
        sys.stderr.write("stub: 404 %s at ref %s\\n" % (rel, ref[:12]))
        sys.exit(1)
    with open(path, "rb") as fh:
        raw = fh.read()
    out({"type": "file", "encoding": "base64",
         "content": base64.b64encode(raw).decode()})
sys.stderr.write("stub: unsupported gh call %r\\n" % (args,))
sys.exit(1)
'''

SPEC_BODY = """# Fixture spec

```json
{"repo": "gulasz101/homelab-2nd", "base": "main", "kind": "code",
 "allowedPaths": ["secret/**", "agents/**"],
 "acs": [{"id": "AC-1", "text": "fixture", "check": "bash agents/factory/tests/repo-config-check.sh"}],
 "maxDiffLines": 100}
```
"""


# --------------------------------------------------------------------------
# AC-1 fixtures: a throw-away repo whose base commit and branch disagree on
# the never-path list, plus a stub gh that serves the same two versions.
# --------------------------------------------------------------------------

def _git(repo, *args):
    proc = subprocess.run(["git", "-C", repo] + list(args),
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                          env=dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull,
                                   GIT_CONFIG_NOSYSTEM="1"))
    if proc.returncode != 0:
        raise RuntimeError("git %s failed: %s" % (" ".join(args), proc.stderr.strip()[:400]))
    return proc.stdout.strip()


def _write_tree(root, files):
    for rel, text in files.items():
        full = os.path.join(root, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as fh:
            fh.write(text)


def build_env(root, base_files, head_files, changed):
    """A temp repo at `FACTORY_GATE_REPO`, gh fixtures, a stub gh and a spec."""
    repo = os.path.join(root, "repo")
    os.makedirs(repo, exist_ok=True)
    _git(repo, "init", "-q")
    _write_tree(repo, base_files)
    _git(repo, "add", "-A")
    _git(repo, "-c", "user.email=factory@example.invalid", "-c", "user.name=factory",
         "commit", "-q", "--allow-empty", "-m", "base")
    base_sha = _git(repo, "rev-parse", "HEAD")
    for rel in list(base_files):
        if rel not in head_files:
            os.remove(os.path.join(repo, rel))
    _write_tree(repo, head_files)
    _git(repo, "add", "-A")
    _git(repo, "-c", "user.email=factory@example.invalid", "-c", "user.name=factory",
         "commit", "-q", "--allow-empty", "-m", "head")
    head_sha = _git(repo, "rev-parse", "HEAD")

    fixtures = os.path.join(root, "fixtures")
    _write_tree(os.path.join(fixtures, "base"), base_files)
    _write_tree(os.path.join(fixtures, "head"), head_files)
    os.makedirs(os.path.join(fixtures, "base"), exist_ok=True)
    os.makedirs(os.path.join(fixtures, "head"), exist_ok=True)
    view = {"headRefOid": head_sha, "baseRefOid": base_sha,
            "additions": 2, "deletions": 1, "mergeable": "MERGEABLE", "isDraft": False,
            "files": [{"path": path, "changeType": "MODIFIED"} for path in changed]}
    with open(os.path.join(fixtures, "pr.json"), "w", encoding="utf-8") as fh:
        json.dump({"baseSha": base_sha, "headSha": head_sha, "view": view}, fh)

    stub = os.path.join(root, "gh")
    with open(stub, "w", encoding="utf-8") as fh:
        fh.write(STUB_GH)
    os.chmod(stub, 0o755)

    spec = os.path.join(root, "spec.md")
    with open(spec, "w", encoding="utf-8") as fh:
        fh.write(SPEC_BODY)

    env = dict(os.environ)
    for var in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
                "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"):
        env.pop(var, None)
    env.update({"FACTORY_GH": stub, "FACTORY_GATE_REPO": repo,
                "GH_STUB_FIXTURES": fixtures,
                "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"})
    return {"repo": repo, "base": base_sha, "head": head_sha, "spec": spec,
            "env": env, "fixtures": fixtures}


def run_gate(checkout, extra):
    cmd = [sys.executable, "-I", FACTORY_PY, "check-gate",
           "--pr", "%s#12" % REPO, "--spec", checkout["spec"]] + list(extra)
    return subprocess.run(cmd, cwd=checkout["repo"], env=checkout["env"],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                          timeout=180)


def gate_json(proc):
    for line in reversed((proc.stdout or "").strip().splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                pass
    return {}


def ac1():
    """--never-paths-ref: the base commit's list, setup when missing, today without it."""
    fails = []
    root = tempfile.mkdtemp(prefix="gul2238-ac1-")
    try:
        never_rel = "agents/factory/never-paths.json"
        # secret/a.yaml is an ordinary ConfigMap: the point of the fixture is the
        # glob, not a content rule, and today's gate reads that file at head.
        base_files = {never_rel: json.dumps(NEVER_PATHS_BASE, indent=1),
                      "secret/a.yaml": "kind: ConfigMap\n",
                      "README.md": "fixture\n"}
        head_files = {never_rel: json.dumps(NEVER_PATHS_HEAD, indent=1),
                      "secret/a.yaml": "kind: ConfigMap\n",
                      "README.md": "fixture\n"}
        checkout = build_env(os.path.join(root, "moved"), base_files, head_files,
                             ["secret/a.yaml"])

        # (a) the base commit says secret/** is a never path; the branch dropped
        #     it. With --never-paths-ref the gate must judge by the base list.
        proc = run_gate(checkout, ["--split-safety", "--never-paths-ref", checkout["base"]])
        data = gate_json(proc)
        safety = data.get("safety")
        safety = safety if isinstance(safety, list) else []
        if proc.returncode != 0:
            fails.append("with --never-paths-ref the gate did not pass (exit %d, stdout %r, stderr %r)"
                         % (proc.returncode, (proc.stdout or "").strip()[:300],
                            (proc.stderr or "").strip()[-300:]))
        elif not any("secret/a.yaml" in str(s) for s in safety):
            fails.append("a path that is a never path only in the PR's base commit was not "
                         "reported under safety (safety=%r)" % (safety,))

        # (b) the same read without --split-safety: a gate FAIL naming the path.
        proc = run_gate(checkout, ["--never-paths-ref", checkout["base"]])
        data = gate_json(proc)
        reasons = data.get("reasons")
        reasons = reasons if isinstance(reasons, list) else []
        if proc.returncode != 1:
            fails.append("without --split-safety and with --never-paths-ref the gate exited %d, "
                         "expected 1 (stdout %r)" % (proc.returncode, (proc.stdout or "").strip()[:300]))
        elif not any("secret/a.yaml" in str(r) for r in reasons):
            fails.append("without --split-safety the gate did not fail on the base-commit never "
                         "path (reasons=%r)" % (reasons,))

        # (c) no never-paths file at the base ref -> setup error, exit 2.
        bare = build_env(os.path.join(root, "bare"), {"README.md": "no list here\n"},
                         {"README.md": "no list here\n"}, ["secret/a.yaml"])
        proc = run_gate(bare, ["--split-safety", "--never-paths-ref", bare["base"]])
        blob = ((proc.stdout or "") + (proc.stderr or "")).lower()
        if proc.returncode != 2:
            fails.append("a never-paths file missing at the base commit exited %d, expected a "
                         "setup error (exit 2); output %r"
                         % (proc.returncode, ((proc.stdout or "") + (proc.stderr or "")).strip()[-400:]))
        elif "setup error" not in blob:
            fails.append("the missing never-paths file exited 2 but no JSON line said "
                         "'setup error': %r" % (((proc.stdout or "") + (proc.stderr or "")).strip()[-400:],))

        # (d) no flag: today's behaviour — the list this checkout ships with
        #     (agents/factory/** is never-path) still reports under safety.
        today = build_env(os.path.join(root, "today"), {"README.md": "fixture\n"},
                          {"README.md": "fixture\n"}, ["agents/factory/factory.py"])
        proc = run_gate(today, ["--split-safety"])
        data = gate_json(proc)
        safety = data.get("safety")
        safety = safety if isinstance(safety, list) else []
        if proc.returncode != 0:
            fails.append("without the flag the gate no longer behaves as today: exit %d, "
                         "stdout %r" % (proc.returncode, (proc.stdout or "").strip()[:300]))
        elif not any("agents/factory/factory.py" in str(s) for s in safety):
            fails.append("without the flag a never path from the shipped list "
                         "(agents/factory/**) was not reported under safety (safety=%r)"
                         % (safety,))
    finally:
        shutil.rmtree(root, ignore_errors=True)
    return fails


# --------------------------------------------------------------------------
# AC-2: engine.py, driven in-process with its seams stubbed
# --------------------------------------------------------------------------

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
    """Stands in for the `subprocess` module inside engine.py."""

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


def load_engine():
    spec = importlib.util.spec_from_file_location("factory_engine_under_test", ENGINE_PY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def engine_for(module, repo_cfg, global_cfg=None):
    cfg = {"repos": {REPO: repo_cfg}, "autoMerge": True, "postMergeCheck": True}
    repo_entry = {"clone": "/nonexistent/clone", "worktrees": "/nonexistent/worktrees",
                  "projectId": "11111111-2222-3333-4444-555555555555"}
    repo_entry.update(repo_cfg)
    cfg["repos"] = {REPO: repo_entry}
    cfg.update(global_cfg or {})
    eng = module.Engine(cfg, FakeApi(), True)
    eng.save = lambda st: None
    eng.finish = lambda st: None
    eng.retain = lambda st: None
    eng.cleanup = lambda st: None
    eng.app_env = lambda st: ({}, "")
    return eng


def work_order_state(**extra):
    st = {"workOrder": "GUL-2238", "workOrderId": "wo-2238", "repo": REPO, "round": 1,
          "phase": "gate", "stages": [], "findings": [], "investigations": [],
          "baseSha": "b" * 40, "specFile": "/dev/null",
          "pr": {"number": 12, "url": "https://example.invalid/pull/12",
                 "head": "h" * 40, "base": "b" * 40}}
    st.update(extra)
    return st


def gate_invocation(module, repo_cfg):
    """step_gate's `factory.py check-gate` argv for this repo config."""
    eng = engine_for(module, repo_cfg)
    eng.auto_merge = lambda st, safety, note: (False, "stubbed by the test")
    calls = []
    orig_factory, orig_checks = module.run_factory, module.gh_pr_checks
    module.run_factory = lambda args: (calls.append(list(args))
                                       or _FakeFactoryResult())
    module.gh_pr_checks = lambda repo, number: [{"name": "check", "state": "SUCCESS"}]
    try:
        eng.step_gate(work_order_state())
    finally:
        module.run_factory, module.gh_pr_checks = orig_factory, orig_checks
    return [c for c in calls if c and c[0] == "check-gate"]


class _FakeFactoryResult:
    ok = True
    code = 0
    parsed = {}
    reasons = []

    def require_json(self):
        return self


def auto_merge_case(module, repo_cfg, global_cfg=None):
    rec = RecordingSubprocess()
    orig = module.subprocess
    module.subprocess = rec
    try:
        eng = engine_for(module, repo_cfg, global_cfg)
        merged, why = eng.auto_merge(work_order_state(phase="gate"), [], None)
    finally:
        module.subprocess = orig
    merges = [c for c in rec.calls if len(c) > 1 and c[1] == "pr" and "merge" in c]
    return merged, why, merges


def merge_case(module, repo_cfg, global_cfg=None):
    orig_json, orig_contains = module.factory.gh_json, module.factory.merge_contains
    module.factory.gh_json = lambda args: {
        "state": "MERGED", "mergedAt": "2026-11-25T00:00:00Z",
        "mergeCommit": {"oid": "m" * 40}, "headRefOid": "h" * 40,
        "mergeStateStatus": "CLEAN"}
    module.factory.merge_contains = lambda clone, head, merge: True
    try:
        eng = engine_for(module, repo_cfg, global_cfg)
        st = work_order_state(phase="awaiting_merge")
        eng.step_merge(st)
    finally:
        module.factory.gh_json, module.factory.merge_contains = orig_json, orig_contains
    return st.get("phase")


def ac2():
    """Per-repo neverPaths, autoMerge and postMergeCheck in the engine."""
    fails = []
    module = load_engine()

    # (a) the repo's neverPaths reaches the gate, next to --never-paths-ref.
    calls = gate_invocation(module, {"neverPaths": "safety/never-paths.json",
                                     "clone": "/nonexistent"})
    if not calls:
        fails.append("the gate step ran no `check-gate` command at all")
    else:
        argv = calls[0]
        if "--never-paths-ref" not in argv:
            fails.append("the gate command the engine runs for a repo with neverPaths has no "
                         "--never-paths-ref: %r" % (argv,))
        else:
            idx = argv.index("--never-paths-ref")
            ref = argv[idx + 1] if idx + 1 < len(argv) else ""
            if not (len(ref) >= 7 and all(ch in "0123456789abcdef" for ch in ref.lower())):
                fails.append("--never-paths-ref was passed %r, not a commit to read the list from "
                             "(argv=%r)" % (ref, argv))
        if not any("never-paths.json" == str(arg) or "safety/never-paths.json" == str(arg)
                   for arg in argv):
            fails.append("the repo's neverPaths (safety/never-paths.json) is not passed to the "
                         "gate: %r" % (argv,))

    # (b) a repo that is configured to merge does merge (the positive control),
    #     with the global autoMerge on and the repo's neverPaths configured.
    merged, why, merges = auto_merge_case(module, {"neverPaths": "safety/never-paths.json"},
                                          {"autoMerge": True})
    if not merged or not merges:
        fails.append("a repo with neverPaths and autoMerge true did not auto-merge "
                     "(merged=%r, why=%r, merge calls=%r)" % (merged, why, merges))

    # (c) no neverPaths on the repo: never auto-merge.
    merged, why, merges = auto_merge_case(module, {}, {"autoMerge": True})
    if merged or merges:
        fails.append("a repo with no neverPaths was auto-merged (merged=%r, why=%r, calls=%r)"
                     % (merged, why, merges))

    # (d) the repo's autoMerge false beats the global true: never auto-merge.
    merged, why, merges = auto_merge_case(module,
                                          {"neverPaths": "safety/never-paths.json",
                                           "autoMerge": False},
                                          {"autoMerge": True})
    if merged or merges:
        fails.append("a repo with autoMerge false was auto-merged (merged=%r, why=%r, calls=%r)"
                     % (merged, why, merges))

    # (e) postMergeCheck false on the repo: the merge goes straight to done.
    phase = merge_case(module, {"neverPaths": "safety/never-paths.json",
                                "postMergeCheck": False}, {"postMergeCheck": True})
    if phase != "done":
        fails.append("a merged repo with postMergeCheck false entered phase %r, expected 'done' "
                     "(deploy_check must be skipped)" % (phase,))

    # (f) the global default still runs deploy_check (per-repo false is what skips it).
    phase = merge_case(module, {"neverPaths": "safety/never-paths.json"},
                       {"postMergeCheck": True})
    if phase != "deploy_check":
        fails.append("a merged repo without a postMergeCheck setting entered phase %r, expected "
                     "'deploy_check' (today's behaviour)" % (phase,))
    return fails


CHECKS = {"AC-1": ac1, "AC-2": ac2}


def main(argv):
    wanted = []
    if "--ac" in argv:
        idx = argv.index("--ac")
        want = argv[idx + 1] if idx + 1 < len(argv) else ""
        if want not in CHECKS:
            sys.stderr.write("usage: %s [--ac AC-1|AC-2]\n" % os.path.basename(__file__))
            return 2
        wanted = [want]
    else:
        wanted = ["AC-1", "AC-2"]
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
