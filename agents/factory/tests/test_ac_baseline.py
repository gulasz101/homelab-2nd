#!/usr/bin/env python3
"""GUL-2228: an acceptance check that already passes on the base tree proves nothing.

The contract this file pins down:

    python3 agents/factory/factory.py check-baseline --repo DIR --spec FILE

runs every AC check of FILE in the working tree at DIR — the tree the factory cuts at
`baseSha` before it opens the red stage — and refuses only the ACs that report PASS
there. A check that cannot run yet (its script is not written, the command exits with
a non-zero code, it dies with a setup error) is *not* passing: red is where it starts
to fail. Output is the usual one-line factory JSON
`{"ok": bool, "check": "check-baseline", "reasons": [...]}` on stdout; exit 0 when no
AC passes, 1 when at least one does, 2 on an unusable spec.

    AC-1  check-baseline refuses only an AC that reports PASS on the tree, names it,
          and treats a check that cannot run yet as not passing
    AC-2  the engine stalls a queued order as SPEC-WRONG before any stage issue when
          an AC already passes on the base, and starts a clean order as today

AC-2 drives agents/factory/engine.py through the offline fake board in test_engine.py
(same fixtures, no network). Everything runs under a temporary directory: no HOME,
host or username is read or compared, so the Air and CI give the same answer.

    python3 agents/factory/tests/test_ac_baseline.py      (stdlib only)
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

# GUL-2080: an inherited GIT_DIR made fixture repos write into the real checkout.
for _var in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
             "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
             "GIT_NAMESPACE", "GIT_PREFIX", "GIT_CONFIG", "GIT_CONFIG_GLOBAL"):
    os.environ.pop(_var, None)

HERE = os.path.dirname(os.path.abspath(__file__))
FACTORY = os.path.abspath(os.path.join(HERE, "..", "factory.py"))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

GIT_ENV = {"GIT_AUTHOR_NAME": "ac baseline test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
           "GIT_COMMITTER_NAME": "ac baseline test",
           "GIT_COMMITTER_EMAIL": "test@example.invalid"}


def sh_git(*args, cwd=None):
    subprocess.run(["git"] + list(args), cwd=cwd, env=dict(os.environ, **GIT_ENV),
                   check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def spec_text(acs):
    """A spec for a work order whose AC checks live under tests/."""
    return ('# Spec\n\nPeople read this part.\n\n```json\n'
            '{"repo": "gulasz101/homelab-2nd", "base": "main", "kind": "tests",\n'
            ' "allowedPaths": ["tests/**", "src/**"], "maxDiffLines": 100,\n'
            ' "acs": %s}\n```\n' % json.dumps(acs))


def ac(number, check, text="the new behaviour is covered"):
    return {"id": "AC-%d" % number, "text": text, "check": check}


class BaselineCheck(unittest.TestCase):
    """AC-1: `factory.py check-baseline --repo DIR --spec FILE`."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ac-baseline-unit-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.tree = os.path.join(self.tmp, "tree")
        os.makedirs(os.path.join(self.tree, "tests"))
        sh_git("init", "-q", "-b", "main", self.tree)
        self.specs = 0

    def write_check(self, name, body):
        path = os.path.join(self.tree, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("#!/usr/bin/env bash\n" + body)
        os.chmod(path, 0o755)
        return name

    def commit_tree(self):
        sh_git("add", "-A", cwd=self.tree)
        sh_git("commit", "-q", "--allow-empty", "-m", "fixture base", cwd=self.tree)

    def baseline(self, acs):
        """Run check-baseline on the tree; return (exit code, parsed JSON)."""
        self.commit_tree()
        self.specs += 1
        spec = os.path.join(self.tmp, "spec-%d.md" % self.specs)
        with open(spec, "w", encoding="utf-8") as fh:
            fh.write(spec_text(acs))
        proc = subprocess.run([sys.executable, "-I", FACTORY, "check-baseline",
                               "--repo", self.tree, "--spec", spec],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                              timeout=120)
        lines = [ln for ln in proc.stdout.splitlines() if ln.strip()]
        self.assertEqual(len(lines), 1,
                         "want exactly one JSON line on stdout, got %r\nstderr:\n%s"
                         % (proc.stdout, proc.stderr))
        out = json.loads(lines[0])
        self.assertEqual(out["check"], "check-baseline")
        self.assertIsInstance(out["reasons"], list)
        self.stderr = proc.stderr
        return proc.returncode, out

    def test_01_refuses_an_ac_that_passes(self):
        self.write_check("tests/pass.sh", 'echo "AC-1: PASS"\nexit 0\n')
        rc, out = self.baseline([ac(1, "bash tests/pass.sh")])
        self.assertEqual(rc, 1, (out, self.stderr))
        self.assertFalse(out["ok"], out)
        blamed = " ".join(out["reasons"]).lower()
        self.assertIn("ac-1", blamed, "the reason must name the AC that passes: %r" % (out,))
        self.assertIn("pass", blamed, "the reason must say the AC reports PASS: %r" % (out,))

    def test_02_accepts_a_well_formed_failing_check(self):
        self.write_check("tests/fail.sh", 'echo "AC-1: FAIL not implemented yet"\nexit 1\n')
        rc, out = self.baseline([ac(1, "bash tests/fail.sh")])
        self.assertEqual(rc, 0, (out, self.stderr))
        self.assertTrue(out["ok"], out)
        self.assertEqual(out["reasons"], [], out)

    def test_03_accepts_a_check_that_cannot_run_yet(self):
        # Not written at all: `bash tests/not-yet.sh` exits 127.
        rc, out = self.baseline([ac(1, "bash tests/not-yet.sh")])
        self.assertEqual(rc, 0, ("a missing script is not a PASS", out, self.stderr))
        self.assertTrue(out["ok"], out)
        # Written but broken: exit 2 is the protocol's setup error, still not a PASS.
        self.write_check("tests/broken.sh", 'echo "ENV: no TMPDIR" >&2\nexit 2\n')
        rc, out = self.baseline([ac(1, "bash tests/broken.sh")])
        self.assertEqual(rc, 0, ("a setup error is not a PASS", out, self.stderr))
        self.assertTrue(out["ok"], out)

    def test_04_refuses_only_the_passing_ac(self):
        self.write_check("tests/mixed.sh",
                         'echo "AC-1: FAIL missing"\necho "AC-2: PASS"\nexit 1\n')
        rc, out = self.baseline([ac(1, "bash tests/mixed.sh"), ac(2, "bash tests/mixed.sh")])
        self.assertEqual(rc, 1, (out, self.stderr))
        self.assertFalse(out["ok"], out)
        blamed = " ".join(out["reasons"])
        self.assertIn("AC-2", blamed, "AC-2 passes, so it must be named: %r" % (out,))
        self.assertNotIn("AC-1", blamed, "AC-1 fails, so it must not be blamed: %r" % (out,))


# --------------------------------------------------------------------------
# AC-2: the engine runs the same check before it opens the red stage
# --------------------------------------------------------------------------

import test_engine  # noqa: E402 - after HERE is on sys.path


class EngineBaseline(test_engine.EngineCase):
    """AC-2, through the offline fake Paperclip board of test_engine.py."""

    def add_base_check(self, body, rel="tests/ac.sh"):
        """Commit the acceptance check onto origin/main: the base tree the engine cuts."""
        wt = os.path.join(self.tmp, "base-tests")
        test_engine.sh_git("worktree", "add", "-q", "-b", "base-tests", wt, "main",
                           cwd=self.clone)
        path = os.path.join(wt, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("#!/usr/bin/env bash\n" + body)
        test_engine.sh_git("add", "-A", cwd=wt)
        test_engine.sh_git("commit", "-qm", "base acceptance check", cwd=wt)
        test_engine.sh_git("push", "-q", "origin", "base-tests:main", cwd=wt)
        test_engine.sh_git("worktree", "remove", wt, cwd=self.clone)

    def test_01_stalls_a_spec_whose_check_already_passes(self):
        self.add_base_check('echo "AC-1: PASS"\nexit 0\n')
        self.start(901, "Baseline already green",
                   spec_body=spec_text([ac(1, "bash tests/ac.sh")]))
        rc, out = self.tick()
        self.assertEqual(rc, 0, (out, self.last_err))
        st = self.load("GUL-901")
        self.assertEqual(st["phase"], "stalled", (st.get("stallReason"), self.last_err))
        reason = st.get("stallReason") or ""
        self.assertIn("SPEC-WRONG", reason,
                      "an AC that already passes is a spec problem: %r" % (reason,))
        self.assertIn("AC-1", reason, "the stall must name the passing AC: %r" % (reason,))
        self.assertEqual(test_engine.FAKE.stage_issue_posts(), [],
                         "the order stalls before any stage issue exists")
        self.assertEqual(st.get("stages") or [], [])
        self.assertEqual(test_engine.FAKE.by_ident("GUL-901")["status"], "blocked")

    def test_02_starts_a_clean_order_as_today(self):
        self.add_base_check('echo "AC-1: FAIL not implemented yet"\nexit 1\n')
        self.start(902, "Clean order", spec_body=spec_text([ac(1, "bash tests/ac.sh")]))
        rc, out = self.tick()
        self.assertEqual(rc, 0, (out, self.last_err))
        st = self.load("GUL-902")
        self.assertEqual(st["phase"], "red", (st.get("stallReason"), self.last_err))
        posts = test_engine.FAKE.stage_issue_posts()
        self.assertEqual(len(posts), 1, "one red stage issue, as today")
        self.assertEqual(posts[0][2]["title"], "[red] GUL-902 Clean order")
        # the fixture really is on the base tree the engine cuts at baseSha
        with open(os.path.join(st["worktree"], "tests", "ac.sh"), encoding="utf-8") as fh:
            self.assertIn("AC-1: FAIL", fh.read())

    def test_03_a_check_that_cannot_run_yet_starts_red(self):
        # No tests/ac.sh on the base at all: it exits 127, which is not a PASS.
        self.start(903, "Not written yet")
        rc, out = self.tick()
        self.assertEqual(rc, 0, (out, self.last_err))
        st = self.load("GUL-903")
        self.assertEqual(st["phase"], "red", (st.get("stallReason"), self.last_err))
        self.assertEqual(len(test_engine.FAKE.stage_issue_posts()), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
