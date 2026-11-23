#!/usr/bin/env python3
"""Offline tests for `agents/factory/engine.py` (GUL-2037 phase 2).

The contract is agents/factory/ENGINE.md. Everything runs against one fake
HTTP server in this process (Paperclip, Hindsight, docs-mcp and the Lodge,
each under its own path prefix), a fake `gh` script and throw-away git repos
(a bare "origin" plus a clone the engine cuts worktrees from). No real
Paperclip, Hindsight, docs-mcp, Lodge or GitHub call is ever made: every
PAPERCLIP_* variable of the calling run is dropped from the engine's
environment, and the pc.py fallback URL points at the fake too.

    python3 agents/factory/tests/test_engine.py      (stdlib only)
"""

import datetime
import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# GUL-2080: an inherited GIT_DIR made fixture repos write into the real checkout.
for _var in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
             "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
             "GIT_NAMESPACE", "GIT_PREFIX", "GIT_CONFIG", "GIT_CONFIG_GLOBAL"):
    os.environ.pop(_var, None)


HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.abspath(os.path.join(HERE, "..", "engine.py"))

COMPANY = "c0000000-0000-4000-8000-0000000000e1"
PROJECT = "p0000000-0000-4000-8000-0000000000e1"
SUPERVISOR = "a0000000-0000-4000-8000-00000000000s"
STALL_OWNER = "a0000000-0000-4000-8000-0000000000pm"
INVESTIGATOR = "a0000000-0000-4000-8000-0000000000iv"
STRONG = "a0000000-0000-4000-8000-0000000000st"
AGENTS = {stage: "a0000000-0000-4000-8000-0000000000%02d" % i
          for i, stage in enumerate(("librarian", "red", "green", "review", "verify"), 1)}
LODGE = {"librarian": "librarian", "red": "tester", "green": "builder",
         "review": "reviewer", "verify": "verifier"}
REPO = "gulasz101/homelab-2nd"

SPEC_BODY = """# Spec

People read this part.

```json
{"repo": "gulasz101/homelab-2nd", "base": "main", "kind": "tests",
 "allowedPaths": ["tests/**"],
 "acs": [{"id": "AC-1", "text": "the new behaviour is tested", "check": "bash tests/ac.sh"}],
 "maxDiffLines": 100}
```
"""


# --------------------------------------------------------------------------
# the fake server
# --------------------------------------------------------------------------

class Fake:
    def __init__(self):
        self.reset()

    def reset(self):
        self.lock = threading.Lock()
        self.requests = []          # (method, raw path, body, headers)
        self.issues = {}            # id -> issue
        self.documents = {}         # (issue id, key) -> {"body", "latestRevisionId"}
        self.comments = []          # (issue id, body)
        self.workspaces = {}        # id -> workspace
        self.agents = {aid: {"id": aid, "status": "idle"} for aid in AGENTS.values()}
        self.agents[SUPERVISOR] = {"id": SUPERVISOR, "status": "paused"}
        self.counter = 900
        self.recall_status = {}     # bank -> HTTP status to answer
        self.recall_results = [{"text": "Worktrees need\n  their own branch."}]
        self.retain_status = 200
        self.docs = []              # docs-mcp listLibraries rows

    def add_work_order(self, number, title, spec_body=SPEC_BODY):
        wid = str(uuid.uuid4())
        self.issues[wid] = {"id": wid, "identifier": "GUL-%d" % number, "title": title,
                            "companyId": COMPANY, "projectId": PROJECT, "priority": "high",
                            "status": "todo", "parentId": None, "updatedAt": now()}
        if spec_body is not None:
            self.documents[(wid, "spec")] = {"body": spec_body, "latestRevisionId": "rev-spec-1"}
        return wid

    def by_ident(self, ident):
        for issue in self.issues.values():
            if issue["identifier"] == ident:
                return issue
        return None

    def mutating(self, prefix="/pc/"):
        return [r for r in self.requests if r[0] in ("POST", "PATCH", "PUT", "DELETE")
                and r[1].startswith(prefix)]

    def stage_issue_posts(self):
        return [r for r in self.requests if r[0] == "POST"
                and r[1] == "/pc/api/companies/%s/issues" % COMPANY]


FAKE = Fake()


def now():
    import datetime
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, status, payload=None):
        raw = b"" if payload is None else json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _handle(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        body = json.loads(raw.decode("utf-8")) if raw.strip() else None
        with FAKE.lock:
            FAKE.requests.append((method, self.path, body, dict(self.headers)))
            try:
                status, payload = route(method, self.path, body)
            except Exception as exc:  # noqa: BLE001 - surface in the test, not a hang
                status, payload = 599, {"error": "fake crashed: %r" % exc}
        self._send(status, payload)

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_PATCH(self):
        self._handle("PATCH")

    def do_PUT(self):
        self._handle("PUT")

    def do_DELETE(self):
        self._handle("DELETE")


def route(method, raw_path, body):
    parsed = urllib.parse.urlsplit(raw_path)
    path, query = parsed.path, urllib.parse.parse_qs(parsed.query)
    if path.startswith("/pc/api/"):
        return paperclip(method, path[len("/pc/api"):].split("/")[1:], query, body)
    if path.startswith("/hs/v1/default/banks/"):
        rest = path[len("/hs/v1/default/banks/"):]
        bank, _, tail = rest.partition("/")
        bank = urllib.parse.unquote(bank)
        if tail == "memories/recall" and method == "POST":
            code = FAKE.recall_status.get(bank, 200)
            return (code, {"results": FAKE.recall_results}) if code == 200 else (code, {"error": "x"})
        if tail == "memories" and method == "POST":
            return FAKE.retain_status, {"ok": FAKE.retain_status == 200}
        return 404, {"error": "no route"}
    if path == "/docs/api/listLibraries" and method == "GET":
        return 200, {"result": {"data": {"json": FAKE.docs}}}
    if path.startswith("/docsdown/"):
        return 503, {"error": "down"}
    if path == "/lodge/events" and method == "POST":
        return 201, {"ok": True}
    return 404, {"error": "no route %s %s" % (method, path)}


def paperclip(method, parts, query, body):
    n = len(parts)
    if parts[0] == "agents" and n == 2 and method == "GET":
        agent = FAKE.agents.get(parts[1])
        return (200, agent) if agent else (404, {"error": "no agent"})
    if parts[0] == "issues" and n >= 2:
        issue = FAKE.issues.get(parts[1]) or FAKE.by_ident(parts[1])
        if issue is None:
            return 404, {"error": "no issue"}
        iid = issue["id"]
        if n == 2 and method == "GET":
            return 200, issue
        if n == 2 and method == "PATCH":
            # the real server's rule (server/src/routes/issues.ts): entering `blocked` needs a
            # blocker edge, a pending interaction or an unblockDescriptor
            if (body.get("status") == "blocked" and issue.get("status") != "blocked"
                    and not body.get("blockedByIssueIds") and not body.get("unblockDescriptor")):
                return 422, {"error": "Entering blocked requires unresolved blockers, a pending "
                                      "interaction/approval, or unblockDescriptor"}
            for key, value in body.items():
                if key == "comment":
                    FAKE.comments.append((iid, value))
                else:
                    issue[key] = value
            issue["updatedAt"] = now()
            return 200, issue
        if n == 3 and parts[2] == "comments":
            if method == "POST":
                FAKE.comments.append((iid, body["body"]))
                return 201, {"id": str(uuid.uuid4()), "body": body["body"]}
            return 200, [{"body": b, "createdAt": now()} for i, b in FAKE.comments if i == iid]
        if n == 3 and parts[2] == "runs":
            return 200, []
        if n == 4 and parts[2] == "documents":
            key = (iid, parts[3])
            if method == "GET":
                doc = FAKE.documents.get(key)
                return (200, {"document": doc}) if doc else (404, {"error": "no document"})
            if method == "PUT":
                old = FAKE.documents.get(key)
                if (old or {}).get("latestRevisionId") != body.get("baseRevisionId"):
                    return 409, {"error": "Document update requires baseRevisionId"}
                doc = {"body": body["body"], "latestRevisionId": str(uuid.uuid4())}
                FAKE.documents[key] = doc
                return 200, doc
    if parts[0] == "companies" and n == 3 and parts[2] == "issues":
        if method == "GET":
            parent = (query.get("parentId") or [None])[0]
            return 200, [i for i in FAKE.issues.values() if parent is None or i.get("parentId") == parent]
        if method == "POST":
            FAKE.counter += 1
            iid = str(uuid.uuid4())
            issue = dict(body, id=iid, identifier="GUL-%d" % FAKE.counter, companyId=parts[1],
                         createdAt=now(), updatedAt=now())
            FAKE.issues[iid] = issue
            return 201, issue
    if parts[0] == "projects" and n >= 3 and parts[2] == "workspaces":
        if n == 3 and method == "GET":
            return 200, [w for w in FAKE.workspaces.values() if w["projectId"] == parts[1]]
        if n == 3 and method == "POST":
            wid = str(uuid.uuid4())
            FAKE.workspaces[wid] = dict(body, id=wid, projectId=parts[1])
            return 201, FAKE.workspaces[wid]
        if n == 4 and method == "DELETE":
            return (200, FAKE.workspaces.pop(parts[3])) if parts[3] in FAKE.workspaces else (404, {})
    return 404, {"error": "no paperclip route %s /%s" % (method, "/".join(parts))}


# --------------------------------------------------------------------------
# fixtures
# --------------------------------------------------------------------------

GIT_ENV = {"GIT_AUTHOR_NAME": "engine test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
           "GIT_COMMITTER_NAME": "engine test", "GIT_COMMITTER_EMAIL": "test@example.invalid"}


def sh_git(*args, cwd=None):
    env = dict(os.environ, **GIT_ENV)
    subprocess.run(["git"] + list(args), cwd=cwd, env=env, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def git_out(*args):
    return subprocess.run(["git"] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, env=dict(os.environ, **GIT_ENV)).stdout.strip()


class EngineCase(unittest.TestCase):
    server = None

    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.base = "http://127.0.0.1:%d" % cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        FAKE.reset()
        self.tmp = tempfile.mkdtemp(prefix="engine-check-")
        self.state = os.path.join(self.tmp, "state")
        self.stop = os.path.join(self.tmp, "STOP")
        self.origin = os.path.join(self.tmp, "origin.git")
        self.clone = os.path.join(self.tmp, "clone")
        self.worktrees = os.path.join(self.tmp, "worktrees")
        sh_git("init", "-q", "--bare", "-b", "main", self.origin)
        sh_git("init", "-q", "-b", "main", self.clone)
        with open(os.path.join(self.clone, "README.md"), "w") as fh:
            fh.write("fixture\n")
        sh_git("add", "-A", cwd=self.clone)
        sh_git("commit", "-qm", "base", cwd=self.clone)
        sh_git("remote", "add", "origin", self.origin, cwd=self.clone)
        sh_git("push", "-q", "origin", "main", cwd=self.clone)
        # the old factory checkout is dirty and on another branch: the engine
        # must never touch it
        sh_git("checkout", "-qb", "someone-elses-branch", cwd=self.clone)
        with open(os.path.join(self.clone, "dirty.txt"), "w") as fh:
            fh.write("uncommitted\n")
        self.lodge_dir = os.path.join(self.tmp, "sou")
        os.makedirs(self.lodge_dir)
        with open(os.path.join(self.lodge_dir, "tester.token"), "w") as fh:
            fh.write("lodge-test-token\n")
        self.gh_log = os.path.join(self.tmp, "gh.log")
        self.gh = os.path.join(self.tmp, "gh")
        with open(self.gh, "w") as fh:
            fh.write('#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\necho "fake gh: no route" >&2\nexit 1\n'
                     % self.gh_log)
        os.chmod(self.gh, 0o755)
        self.key_file = os.path.join(self.tmp, "engine-board.key")
        with open(self.key_file, "w") as fh:
            fh.write("fake-board-key\n")
        os.chmod(self.key_file, 0o600)
        self.config = os.path.join(self.tmp, "engine.json")
        self.write_config()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_config(self, **over):
        cfg = {"maxActiveOrders": 2, "maxAttempts": 3, "maxFixRounds": 2,
               "stageTimeoutMinutes": {"librarian": 20, "red": 90, "green": 90, "review": 60,
                                       "verify": 60},
               "idleMinutes": 15, "gateCiWaitMinutes": 60, "supervisorAgentId": SUPERVISOR,
               "stallOwnerAgentId": STALL_OWNER,
               "stages": {s: {"agentId": AGENTS[s], "lodge": LODGE[s]} for s in AGENTS},
               "repos": {REPO: {"clone": self.clone, "worktrees": self.worktrees}},
               "recallBanks": ["coding-agent::{repoName}", "hermes-andrzej"],
               "retainBank": "coding-agent::{repoName}",
               # the real hosts: the env overrides below must win over these
               "hindsightUrl": "http://hindsight.invalid", "docsUrl": "http://docs.invalid",
               "lodgeUrl": "http://lodge.invalid", "autoPickup": False}
        cfg.update(over)
        with open(self.config, "w") as fh:
            json.dump(cfg, fh)

    def env(self, **over):
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("PAPERCLIP_", "FACTORY_", "HINDSIGHT_"))}
        env.update(GIT_ENV)
        env.update({
            "HOME": self.tmp,
            "PAPERCLIP_API_URL": self.base + "/pc",
            "PAPERCLIP_API_FALLBACK_URL": self.base + "/pc",
            # the engine must ignore this one: it never acts as the calling agent
            "PAPERCLIP_API_KEY": "agent-key-must-not-be-used",
            "FACTORY_ENGINE_KEY_FILE": self.key_file,
            "FACTORY_ENGINE_CONFIG": self.config,
            "FACTORY_ENGINE_STATE": self.state,
            "FACTORY_STOP": self.stop,
            "FACTORY_HINDSIGHT_URL": self.base + "/hs",
            "FACTORY_DOCS_URL": self.base + "/docs",
            "FACTORY_LODGE_URL": self.base + "/lodge",
            "FACTORY_GH": self.gh,
            "FACTORY_LODGE_TOKEN_DIR": self.lodge_dir,
            "FACTORY_HINDSIGHT_TOKEN_FILE": os.path.join(self.tmp, "no-such-hindsight.json"),
            "HINDSIGHT_API_TOKEN": "hs-test-token",
        })
        env.update(over)
        return env

    def run_engine(self, *args, **env_over):
        proc = subprocess.run([sys.executable, "-I", ENGINE] + list(args), env=self.env(**env_over),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=120)
        lines = [ln for ln in proc.stdout.splitlines() if ln.strip()]
        self.assertEqual(len(lines), 1, "want exactly one JSON line on stdout, got %r\nstderr:\n%s"
                         % (proc.stdout, proc.stderr))
        out = json.loads(lines[0])
        self.assertEqual(out["check"], "engine-" + args[0])
        self.last_err = proc.stderr
        return proc.returncode, out

    def tick(self, apply=True, **env_over):
        return self.run_engine("tick", *(["--apply"] if apply else []), **env_over)

    def start(self, number, title="Make the thing work", spec_body=SPEC_BODY):
        FAKE.add_work_order(number, title, spec_body)
        return self.run_engine("start", "GUL-%d" % number)

    def load(self, wo):
        with open(os.path.join(self.state, wo + ".json")) as fh:
            return json.load(fh)

    def order_line(self, out, wo):
        for line in out.get("orders") or []:
            if line["workOrder"] == wo:
                return line
        self.fail("no tick line for %s in %r" % (wo, out))

    def issue_of(self, row):
        return FAKE.issues[row["issueId"]]

    def assert_no_blocked_stage_issue(self):
        """ENGINE.md: no stage issue is ever `blocked`, never an executionPolicy."""
        stage_ids = {i["id"] for i in FAKE.issues.values() if i.get("parentId")}
        for method, path, body, _ in FAKE.requests:
            if not body or method not in ("POST", "PATCH"):
                continue
            if path == "/pc/api/companies/%s/issues" % COMPANY or any(
                    path == "/pc/api/issues/%s" % sid for sid in stage_ids):
                self.assertNotIn("executionPolicy", body, "%s %s" % (method, path))
                self.assertNotEqual(body.get("status"), "blocked", "%s %s" % (method, path))


# --------------------------------------------------------------------------
# the cases
# --------------------------------------------------------------------------

class TickGuards(EngineCase):
    def test_01_stop_file_writes_nothing(self):
        with open(self.stop, "w") as fh:
            fh.write("stop\n")
        rc, out = self.tick()
        self.assertEqual(rc, 0)
        self.assertTrue(out["ok"])
        self.assertIn("stopped", out["reasons"])
        self.assertIn("stopped", self.last_err)
        self.assertFalse(os.path.exists(self.state), "STOP must write nothing")
        self.assertEqual(FAKE.requests, [])

    def test_02_lock_held_prints_busy(self):
        os.makedirs(self.state)
        with open(os.path.join(self.state, "engine.lock"), "a") as held:
            fcntl.flock(held.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            rc, out = self.tick()
        self.assertEqual(rc, 0)
        self.assertIn("busy", out["reasons"])
        self.assertIn("busy", self.last_err)
        self.assertEqual(FAKE.requests, [])


class Start(EngineCase):
    def test_03_start_queue_idempotent_and_bad_spec(self):
        rc, out = self.start(101, "Respell foreign words")
        self.assertEqual(rc, 0, out)
        self.assertEqual(out["phase"], "queued")
        st = self.load("GUL-101")
        self.assertEqual(st["phase"], "queued")
        self.assertEqual(st["branch"], "gul-101-respell-foreign-words")
        self.assertEqual(st["specRevisionId"], "rev-spec-1")
        with open(st["specFile"]) as fh:
            self.assertEqual(fh.read(), SPEC_BODY, "the spec is frozen into specFile")
        wo = FAKE.by_ident("GUL-101")
        self.assertNotIn("assigneeAgentId", wo, "start assigns nobody (paused agent: 409)")
        self.assertEqual(wo["status"], "todo")
        self.assertEqual(len([c for c in FAKE.comments if c[0] == wo["id"]]), 1)
        for _, path, _, headers in FAKE.requests:
            if path.startswith("/pc/"):
                self.assertNotIn("X-Paperclip-Run-Id", headers, "no run id outside a heartbeat run")
                self.assertEqual(headers.get("Authorization"), "Bearer fake-board-key")

        before = len(FAKE.mutating())
        rc, out = self.run_engine("start", "GUL-101")
        self.assertEqual(rc, 0)
        self.assertTrue(out.get("already"))
        self.assertEqual(len(FAKE.mutating()), before, "a second start writes nothing")

        rc, out = self.start(102, "Bad one", spec_body="no fence here\n")
        self.assertEqual(rc, 1, out)
        self.assertFalse(out["ok"])
        self.assertFalse(os.path.exists(os.path.join(self.state, "GUL-102.json")))
        bad = FAKE.by_ident("GUL-102")
        self.assertEqual([r for r in FAKE.mutating() if bad["id"] in r[1]], [])


class TickFlow(EngineCase):
    def test_04_queued_to_red(self):
        self.start(201, "Respell foreign words")
        rc, out = self.tick()
        self.assertEqual(rc, 0, (out, self.last_err))
        st = self.load("GUL-201")
        self.assertEqual(st["phase"], "red")
        wt = os.path.join(self.worktrees, "gul-201-respell-foreign-words")
        self.assertEqual(st["worktree"], wt)
        self.assertEqual(git_out("-C", wt, "rev-parse", "--abbrev-ref", "HEAD"), st["branch"])
        self.assertEqual(st["baseSha"], git_out("-C", self.origin, "rev-parse", "main"))
        # the clone's own working tree is untouched
        self.assertEqual(git_out("-C", self.clone, "rev-parse", "--abbrev-ref", "HEAD"),
                         "someone-elses-branch")
        self.assertTrue(os.path.exists(os.path.join(self.clone, "dirty.txt")))

        ws_posts = [r for r in FAKE.requests
                    if r[0] == "POST" and r[1] == "/pc/api/projects/%s/workspaces" % PROJECT]
        self.assertEqual(len(ws_posts), 1)
        self.assertEqual(ws_posts[0][2], {"name": "wo GUL-201", "sourceType": "local_path",
                                          "cwd": wt, "isPrimary": False})
        self.assertEqual(st["workspaceId"], list(FAKE.workspaces)[0])
        wo = FAKE.by_ident("GUL-201")
        self.assertIn((wo["id"], "docs-ready"), FAKE.documents, "docs-ready written on the work order")
        self.assertIn((wo["id"], "engine-state"), FAKE.documents, "state mirrored")

        posts = FAKE.stage_issue_posts()
        self.assertEqual(len(posts), 1, "no librarian issue: no rows means straight to red")
        body = posts[0][2]
        self.assertEqual(body["title"], "[red] GUL-201 Respell foreign words")
        self.assertEqual(body["status"], "todo")
        self.assertEqual(body["parentId"], wo["id"])
        self.assertEqual(body["projectId"], PROJECT)
        self.assertEqual(body["projectWorkspaceId"], st["workspaceId"])
        self.assertEqual(body["assigneeAgentId"], AGENTS["red"])
        self.assertEqual(body["priority"], "high")
        self.assertNotIn("executionPolicy", body)
        desc = body["description"]
        self.assertTrue(desc.startswith("## What the factory remembers\n"), desc[:200])
        headings = [ln for ln in desc.splitlines() if ln.startswith("## ")]
        self.assertEqual(headings[:2], ["## What the factory remembers", "## Docs ready"])
        self.assertIn("- Worktrees need their own branch.", desc)
        self.assertEqual(st["stages"][0]["stage"], "red")
        self.assertEqual(st["stages"][0]["result"], "pending")
        # the Lodge heard the stage start under the tester's name
        lodge = [r for r in FAKE.requests if r[1] == "/lodge/events"]
        self.assertEqual(len(lodge), 1)
        self.assertEqual(lodge[0][2]["agent"], "tester")
        self.assertEqual(lodge[0][2]["event_type"], "state_change")
        self.assertEqual(lodge[0][2]["payload"]["detail"], "GUL-201 red r1 a1: started")
        # one ledger line per order per tick
        with open(os.path.join(self.state, "ledger.jsonl")) as fh:
            ledger = [json.loads(l) for l in fh if l.strip()]
        self.assertEqual([l["workOrder"] for l in ledger], ["GUL-201"])
        for key in ("time", "phase", "stage", "round", "attempt", "outcome", "issue"):
            self.assertIn(key, ledger[0])
        self.assert_no_blocked_stage_issue()

        # the next tick only waits on the open issue
        rc, out = self.tick()
        self.assertEqual(rc, 0)
        self.assertEqual(len(FAKE.stage_issue_posts()), 1)
        self.assertIn("waiting", self.order_line(out, "GUL-201")["flags"])

    def test_05_paused_stage_agent(self):
        FAKE.agents[AGENTS["red"]]["status"] = "paused"
        self.start(202)
        rc, out = self.tick()
        self.assertEqual(rc, 0, out)
        self.assertEqual(FAKE.stage_issue_posts(), [])
        self.assertIn("agent-paused", self.order_line(out, "GUL-202")["flags"])
        self.assertEqual(self.load("GUL-202")["stages"], [])
        rc, out = self.tick()
        self.assertEqual(FAKE.stage_issue_posts(), [])
        self.assertIn("agent-paused", self.order_line(out, "GUL-202")["flags"])

    def test_06_slots(self):
        for n in (301, 302, 303):
            self.assertEqual(self.start(n, "Order %d" % n)[0], 0)
        rc, out = self.tick()
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.load("GUL-301")["phase"], "red")
        self.assertEqual(self.load("GUL-302")["phase"], "red")
        third = self.load("GUL-303")
        self.assertEqual(third["phase"], "queued")
        self.assertIsNone(third["worktree"])
        self.assertIn("waiting-slot", self.order_line(out, "GUL-303")["flags"])
        self.assertEqual(len(FAKE.stage_issue_posts()), 2)
        self.assertEqual(len(FAKE.workspaces), 2)
        self.assertNotEqual(self.load("GUL-301")["worktree"], self.load("GUL-302")["worktree"])

    def test_06b_missing_worktree_stalls_without_an_attempt(self):
        # GUL-2026 replay, 2026-11-23: the state named a worktree that did not exist, the
        # check ran in an empty path and the agent fell back to the shared clone.
        self.start(304, "Lost worktree")
        self.tick()
        st = self.load("GUL-304")
        self.assertEqual(st["phase"], "red")
        row = st["stages"][0]
        self.issue_of(row)["status"] = "done"
        subprocess.run(["git", "-C", self.clone, "worktree", "remove", "--force", st["worktree"]],
                       check=True)
        rc, out = self.tick()
        st = self.load("GUL-304")
        self.assertEqual(st["phase"], "stalled", self.last_err)
        self.assertTrue(st["stallReason"].startswith("ENV: the worktree "), st["stallReason"])
        self.assertIn("worktree-missing", self.order_line(out, "GUL-304")["flags"])
        self.assertEqual(len(st["stages"]), 1, "no new attempt")
        self.assertEqual(st["stages"][0]["result"], "pending", "the red attempt was not judged")
        titles = [p[2]["title"] for p in FAKE.stage_issue_posts()]
        self.assertEqual(len(titles), 2, titles)
        self.assertTrue(titles[0].startswith("[red] GUL-304"), titles)
        self.assertTrue(titles[1].startswith("[stall] GUL-304"), "the owner is woken: %s" % titles)

    def test_07_08_09_failed_attempts_stall_recall_retain(self):
        FAKE.recall_status["hermes-andrzej"] = 500
        self.start(401, "Failing order")
        self.tick()
        st = self.load("GUL-401")
        first = st["stages"][0]
        wo = FAKE.by_ident("GUL-401")

        # 8. recall: one bank 500, bank names percent-encoded
        desc = self.issue_of(first)["description"]
        self.assertIn("From hermes-andrzej: recall unavailable (500)", desc)
        self.assertIn("From coding-agent::homelab-2nd:", desc)
        recall_paths = [r[1] for r in FAKE.requests if r[1].endswith("/memories/recall")]
        self.assertIn("/hs/v1/default/banks/coding-agent%3A%3Ahomelab-2nd/memories/recall",
                      recall_paths)
        recall = [r for r in FAKE.requests if r[1].endswith("/memories/recall")][0]
        self.assertEqual(recall[2]["max_tokens"], 1000)
        self.assertEqual(recall[2]["budget"], "mid")
        self.assertEqual(recall[2]["query"], "Failing order. Stage red. Paths: tests/**")
        self.assertEqual(recall[3].get("Authorization"), "Bearer hs-test-token")

        # 7. attempt 1 "done" with no tests written: check-red fails
        self.issue_of(first)["status"] = "done"
        rc, out = self.tick()
        st = self.load("GUL-401")
        a1, a2 = st["stages"][0], st["stages"][1]
        self.assertEqual(a1["result"], "fail", self.last_err)
        self.assertTrue(a1["reasons"])
        self.assertRegex(a1["fingerprint"] or "", r"^[0-9a-f]{40}$")
        self.assertEqual(a2["attempt"], 2)
        self.assertEqual(a2["result"], "pending")
        self.assertEqual(self.issue_of(a2)["title"], "[red a2] GUL-401 Failing order")
        desc2 = self.issue_of(a2)["description"]
        self.assertIn("## Last attempt failed", desc2)
        self.assertNotIn("SAME FAILURE", desc2)
        old_comments = [b for i, b in FAKE.comments if i == a1["issueId"]]
        self.assertEqual(len(old_comments), 1, old_comments)
        self.assertTrue(old_comments[0].startswith("engine check: FAIL — "))
        self.assertTrue(old_comments[0].endswith("Next attempt: %s" % a2["identifier"]))
        self.assertEqual(self.issue_of(a1)["status"], "done", "the old attempt stays done")
        # unassigned before the engine's comment, so Paperclip cannot reopen it and
        # wake its agent next to the new attempt (GUL-2074)
        a1_path = "/pc/api/issues/%s" % a1["issueId"]
        unassign = [n for n, r in enumerate(FAKE.requests) if r[0] == "PATCH" and r[1] == a1_path
                    and "assigneeAgentId" in r[2] and r[2]["assigneeAgentId"] is None]
        comment = [n for n, r in enumerate(FAKE.requests) if r[0] == "POST"
                   and r[1] == a1_path + "/comments"]
        self.assertEqual(len(unassign), 1, [r for r in FAKE.requests if r[1] == a1_path])
        self.assertEqual(len(comment), 1)
        self.assertLess(unassign[0], comment[0], "unassign comes first")

        # the same failure again: attempt 3's brief says so first
        self.issue_of(a2)["status"] = "done"
        self.tick()
        st = self.load("GUL-401")
        a2, a3 = st["stages"][1], st["stages"][2]
        self.assertEqual(a2["fingerprint"], a1["fingerprint"])
        desc3 = self.issue_of(a3)["description"]
        section = desc3.split("## Last attempt failed\n", 1)[1]
        self.assertTrue(section.startswith("SAME FAILURE as attempt 1:"), section[:200])

        # attempt 3 fails too: maxAttempts spent -> stalled
        self.issue_of(a3)["status"] = "done"
        retains_before = [r for r in FAKE.requests if r[1].endswith("/memories")]
        self.assertEqual(retains_before, [])
        rc, out = self.tick()
        st = self.load("GUL-401")
        self.assertEqual(st["phase"], "stalled", self.last_err)
        self.assertTrue(st["stallReason"])
        self.assertEqual(len(st["stages"]), 3, "no fourth attempt")
        wo_patches = [r[2] for r in FAKE.requests
                      if r[0] == "PATCH" and r[1] == "/pc/api/issues/%s" % wo["id"]]
        stall = [b for b in wo_patches if b.get("status") == "blocked"]
        self.assertEqual(len(stall), 1, wo_patches)
        self.assertIn("executionPolicy", stall[0])
        self.assertIsNone(stall[0]["executionPolicy"])
        self.assertEqual(stall[0]["comment"].split("\n")[0], st["stallReason"])
        self.assertEqual(stall[0]["unblockDescriptor"]["owner"], {"agentId": STALL_OWNER})
        self.assertIn(st["stallReason"], stall[0]["unblockDescriptor"]["action"])
        self.assertEqual(wo["status"], "blocked")
        self.assertTrue(os.path.isdir(st["worktree"]), "the worktree stays for the investigation")
        self.assertIn(st["workspaceId"], FAKE.workspaces, "the workspace stays too")
        self.assert_no_blocked_stage_issue()

        # 9. retain exactly once, even over more ticks
        self.tick()
        self.tick()
        retains = [r for r in FAKE.requests if r[0] == "POST" and r[1].endswith("/memories")]
        self.assertEqual(len(retains), 1, [r[1] for r in retains])
        self.assertEqual(retains[0][1], "/hs/v1/default/banks/coding-agent%3A%3Ahomelab-2nd/memories")
        body = retains[0][2]
        self.assertIs(body["async"], True)
        item = body["items"][0]
        self.assertEqual(item["document_id"], "factory-GUL-401")
        self.assertEqual(item["tags"], ["factory", "GUL-401"])
        self.assertEqual(item["context"], "factory work order outcome")
        self.assertLessEqual(len(item["content"]), 4000)
        self.assertIn("Failing order", item["content"])
        self.assertIn(st["stallReason"], item["content"])
        self.assertTrue(self.load("GUL-401")["retained"])
        stall_patches = [r for r in FAKE.requests if r[0] == "PATCH"
                         and r[1] == "/pc/api/issues/%s" % wo["id"] and r[2].get("status") == "blocked"]
        self.assertEqual(len(stall_patches), 1, "the stall notice is sent once")

    def test_09b_failed_retain_retried_at_most_three_times(self):
        FAKE.retain_status = 500
        self.start(402, "Retain fails")
        self.write_config(maxAttempts=1)
        self.tick()
        self.issue_of(self.load("GUL-402")["stages"][0])["status"] = "done"
        for _ in range(5):
            self.tick()
        st = self.load("GUL-402")
        self.assertEqual(st["phase"], "stalled")
        retains = [r for r in FAKE.requests if r[0] == "POST" and r[1].endswith("/memories")]
        self.assertEqual(len(retains), 3)
        self.assertFalse(st["retained"])

    def test_09c_closed_pr_cancels_the_work_order(self):
        wo = FAKE.issues[self.start(701, "Closed PR")[1] and FAKE.by_ident("GUL-701")["id"]]
        self.tick()
        path = os.path.join(self.state, "GUL-701.json")
        st = self.load("GUL-701")
        st["phase"] = "awaiting_merge"
        st["pr"] = {"number": 9, "url": "https://github.com/x/y/pull/9", "head": "abc"}
        with open(path, "w") as fh:
            json.dump(st, fh)
        with open(self.gh, "w") as fh:
            fh.write('#!/bin/sh\necho \'{"state": "CLOSED", "mergedAt": null, "mergeCommit": null, '
                     '"headRefOid": "abc"}\'\n')
        rc, out = self.tick()
        self.assertEqual(rc, 0, (out, self.last_err))
        st = self.load("GUL-701")
        self.assertEqual(st["phase"], "closed")
        self.assertTrue(st["noticeSent"])
        self.assertEqual(wo["status"], "cancelled")
        self.assert_no_blocked_stage_issue()

    def ladder_config(self, **over):
        FAKE.agents[INVESTIGATOR] = {"id": INVESTIGATOR, "status": "idle"}
        FAKE.agents[STRONG] = {"id": STRONG, "status": "idle"}
        stages = {s: {"agentId": AGENTS[s], "lodge": LODGE[s]} for s in AGENTS}
        stages["investigate"] = {"agentId": INVESTIGATOR, "lodge": "investigator"}
        self.write_config(stages=stages, strongAgents={"red": STRONG}, maxInvestigations=2, **over)

    def fail_red_until_escalated(self, wo_id, n):
        for _ in range(n):
            st = self.load(wo_id)
            self.issue_of(st["stages"][-1])["status"] = "done"  # done with no tests: check-red fails
            self.tick()

    def investigate(self, st, verdict_json):
        row = st["stages"][-1]
        self.assertEqual(row["stage"], "investigate")
        FAKE.documents[(row["issueId"], "investigation")] = {
            "body": "# Investigation\n\n```json\n%s\n```\n" % json.dumps(verdict_json),
            "latestRevisionId": "rev-inv-%s" % row["identifier"]}
        self.issue_of(row)["status"] = "done"
        return self.tick()

    def test_12_stall_ladder(self):
        self.ladder_config()
        self.start(801, "Ladder")
        self.tick()
        self.fail_red_until_escalated("GUL-801", 3)
        st = self.load("GUL-801")
        self.assertEqual(st["phase"], "investigate", self.last_err)
        self.assertEqual(st["ladder"], 1)
        inv_row = st["stages"][-1]
        inv_issue = self.issue_of(inv_row)
        self.assertEqual(inv_issue["title"], "[investigate L1] GUL-801 Ladder")
        self.assertEqual(inv_issue["assigneeAgentId"], INVESTIGATOR)
        self.assertIn("## The stuck stage", inv_issue["description"])
        self.assertIn("### Attempt 3", inv_issue["description"])
        self.assertIn("TEST-WRONG", inv_issue["description"])
        self.assertNotEqual(FAKE.by_ident("GUL-801")["status"], "blocked", "no stall yet")

        # a bad document is a failed attempt, not a verdict
        rc, out = self.investigate(st, {"verdict": "MAYBE", "cause": "x"})
        st = self.load("GUL-801")
        self.assertEqual(st["stages"][-1]["stage"], "investigate")
        self.assertEqual(st["stages"][-1]["attempt"], 2)
        self.assertIn("verdict must be one of", st["stages"][-2]["reasons"][0])

        # TEST-WRONG: the leftovers are stashed (kept), red runs again with the advice
        with open(os.path.join(st["worktree"], "leftover.sh"), "w") as fh:
            fh.write("echo half-done\n")
        rc, out = self.investigate(st, {"verdict": "TEST-WRONG", "cause": "tests/ac.sh calls the "
                                        "script with a flag the AC never names", "advice": "drop the flag"})
        st = self.load("GUL-801")
        self.assertEqual(st["phase"], "red", self.last_err)
        self.assertFalse(os.path.exists(os.path.join(st["worktree"], "leftover.sh")))
        stash = subprocess.run(["git", "-C", st["worktree"], "stash", "list"], stdout=subprocess.PIPE,
                               text=True, env=dict(os.environ, **GIT_ENV)).stdout
        self.assertIn("factory GUL-801: before red reruns (TEST-WRONG", stash)
        red = st["stages"][-1]
        self.assertEqual((red["stage"], red["ladder"], red["attempt"]), ("red", 1, 1))
        red_issue = self.issue_of(red)
        self.assertEqual(red_issue["title"], "[red L1] GUL-801 Ladder")
        self.assertEqual(red_issue["assigneeAgentId"], AGENTS["red"])
        self.assertIn("Verdict **TEST-WRONG**", red_issue["description"])
        self.assertIn("drop the flag", red_issue["description"])

        # red fails 3 more times -> second investigation; CODE-WRONG -> one attempt on the strong agent
        self.fail_red_until_escalated("GUL-801", 3)
        st = self.load("GUL-801")
        self.assertEqual((st["phase"], st["ladder"]), ("investigate", 2), self.last_err)
        self.investigate(st, {"verdict": "CODE-WRONG", "cause": "c", "advice": "a"})
        st = self.load("GUL-801")
        strong = st["stages"][-1]
        self.assertEqual(self.issue_of(strong)["assigneeAgentId"], STRONG)
        self.assertEqual(st["strongStage"], "red")

        # the strong attempt fails once -> the ladder is spent (2 investigations) -> stall + wake
        self.fail_red_until_escalated("GUL-801", 1)
        st = self.load("GUL-801")
        self.assertEqual(st["phase"], "stalled", self.last_err)
        self.assertIn("The stall ladder is spent (2 investigation(s))", st["stallReason"])
        wo = FAKE.by_ident("GUL-801")
        self.assertEqual(wo["status"], "blocked")
        self.assertEqual(wo["unblockDescriptor"]["owner"], {"agentId": STALL_OWNER})
        wakes = [i for i in FAKE.issues.values() if i["title"].startswith("[stall] GUL-801")]
        self.assertEqual(len(wakes), 1)
        self.assertEqual(wakes[0]["assigneeAgentId"], STALL_OWNER)
        self.assertEqual(st["wake"]["sent"], True)
        self.tick()
        self.assertEqual(len([i for i in FAKE.issues.values() if i["title"].startswith("[stall]")]), 1,
                         "one wake per stall")
        self.assert_no_blocked_stage_issue()

    def test_13_spec_wrong_stalls_and_wake_limit(self):
        self.ladder_config(maxStallWakesPerDay=1)
        os.makedirs(self.state, exist_ok=True)
        with open(os.path.join(self.state, "stall-wakes.json"), "w") as fh:
            json.dump({datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"): 1}, fh)
        self.start(802, "Spec wrong")
        self.tick()
        self.fail_red_until_escalated("GUL-802", 3)
        st = self.load("GUL-802")
        # SPEC-WRONG needs an AMEND: block
        self.investigate(st, {"verdict": "SPEC-WRONG", "cause": "AC-1 contradicts itself"})
        st = self.load("GUL-802")
        self.assertEqual(st["phase"], "investigate")
        self.investigate(st, {"verdict": "SPEC-WRONG", "cause": "AC-1 contradicts itself",
                              "amend": "AMEND: AC-1 prints 9, not 10."})
        st = self.load("GUL-802")
        self.assertEqual(st["phase"], "stalled", self.last_err)
        self.assertIn("SPEC-WRONG: AC-1 contradicts itself", st["stallReason"])
        self.assertIn("Proposed AMEND block", st["stallReason"])
        self.assertEqual(st["wake"], {"sent": False, "reason": "daily wake limit (1) reached"})
        self.assertEqual([i for i in FAKE.issues.values() if i["title"].startswith("[stall]")], [])
        self.assertEqual(FAKE.by_ident("GUL-802")["status"], "blocked")

    def test_11_dry_tick_writes_nothing(self):
        self.start(501, "Dry run")
        path = os.path.join(self.state, "GUL-501.json")
        with open(path) as fh:
            before = fh.read()
        files_before = sorted(os.listdir(self.state))
        writes_before = len(FAKE.mutating())
        rc, out = self.tick(apply=False)
        self.assertEqual(rc, 0, out)
        self.assertFalse(out["apply"])
        self.assertTrue(self.order_line(out, "GUL-501").get("would"))
        with open(path) as fh:
            self.assertEqual(fh.read(), before)
        self.assertEqual(sorted(os.listdir(self.state)), files_before)
        self.assertEqual(len(FAKE.mutating()), writes_before)
        self.assertEqual([r for r in FAKE.requests if r[1].startswith(("/hs/", "/lodge/"))
                          and r[0] != "GET"], [])
        self.assertFalse(os.path.exists(self.worktrees))

        # and on an order in red, waiting: still nothing
        self.tick()
        with open(path) as fh:
            before = fh.read()
        writes_before = len(FAKE.mutating())
        self.issue_of(self.load("GUL-501")["stages"][0])["status"] = "done"
        rc, out = self.tick(apply=False)
        with open(path) as fh:
            self.assertEqual(fh.read(), before)
        self.assertEqual(len(FAKE.mutating()), writes_before)


class Inventory(EngineCase):
    def make_repo(self):
        repo = os.path.join(self.tmp, "inv")
        os.makedirs(os.path.join(repo, "apps", "demo"))
        os.makedirs(os.path.join(repo, "other"))
        with open(os.path.join(repo, "package.json"), "w") as fh:
            json.dump({"dependencies": {"react": "^18.2.0", "left-pad": "1.0.0"},
                       "devDependencies": {"@vitest/runner": "^1.6.0"}}, fh)
        with open(os.path.join(repo, "package-lock.json"), "w") as fh:
            json.dump({"packages": {"node_modules/@vitest/runner": {"version": "1.6.1"}}}, fh)
        with open(os.path.join(repo, "requirements-dev.txt"), "w") as fh:
            fh.write("requests==2.31.0\nFlask>=3.0  # the web bit\n-r other.txt\n\n")
        with open(os.path.join(repo, "apps", "demo", "helm-release.yaml"), "w") as fh:
            fh.write("apiVersion: helm.toolkit.fluxcd.io/v2\nkind: HelmRelease\nmetadata:\n"
                     "  name: grafana\nspec:\n  chart:\n    spec:\n      chart: grafana\n"
                     "      version: \"8.5.0\"\n      sourceRef:\n        kind: HelmRepository\n")
        # outside the scope: never read
        with open(os.path.join(repo, "other", "package.json"), "w") as fh:
            json.dump({"dependencies": {"lodash": "4.17.21"}}, fh)
        spec = os.path.join(self.tmp, "inv-spec.md")
        with open(spec, "w") as fh:
            fh.write(SPEC_BODY.replace('["tests/**"]', '["apps/demo/**"]'))
        return repo, spec

    def test_10_inventory_rows_and_status(self):
        repo, spec = self.make_repo()
        FAKE.docs = [
            {"library": "React", "versions": [{"ref": {"version": "18.3.1"}, "status": "completed"}]},
            {"library": "runner", "versions": [{"ref": {"version": "1.2.0"}, "status": "completed"}]},
            {"library": "requests", "versions": [{"ref": {"version": ""}, "status": "completed"}]},
            {"library": "flask", "versions": [{"ref": {"version": "2.3.0"}, "status": "completed"},
                                              {"ref": {"version": "3.1.0"}, "status": "running"}]},
            {"library": "Grafana", "versions": [{"ref": {"version": "8.5.0"}, "status": "completed"}]},
        ]
        rc, out = self.run_engine("inventory", "--repo", repo, "--spec", spec)
        self.assertEqual(rc, 0, out)
        self.assertEqual(out["docsIndex"], "ok")
        rows = {r["library"]: r for r in out["rows"]}
        self.assertEqual(out["rows"][0]["library"], "grafana", "files inside allowedPaths first")
        self.assertEqual(rows["grafana"]["file"], os.path.join("apps", "demo", "helm-release.yaml"))
        self.assertEqual(rows["grafana"]["version"], "8.5.0")
        self.assertEqual(rows["react"]["version"], "18.2.0")
        self.assertEqual(rows["@vitest/runner"]["version"], "1.6.1", "exact version from the lock")
        self.assertEqual(rows["requests"]["version"], "2.31.0")
        self.assertEqual(rows["Flask"]["version"], "3.0")
        self.assertEqual(rows["Flask"]["file"], "requirements-dev.txt")
        self.assertNotIn("lodash", rows, "other/ is outside the scope")
        self.assertEqual(len(out["rows"]), 6)
        want = {"grafana": "ok", "react": "ok", "@vitest/runner": "stale", "requests": "ok",
                "Flask": "stale", "left-pad": "missing"}
        self.assertEqual({k: v["status"] for k, v in rows.items()}, want)

        rc, out = self.run_engine("inventory", "--repo", repo, "--spec", spec,
                                  FACTORY_DOCS_URL=self.base + "/docsdown")
        self.assertEqual(rc, 0, out)
        self.assertEqual(out["docsIndex"], "unreachable")
        self.assertEqual({r["status"] for r in out["rows"]}, {"unknown"})

    def test_10b_inventory_not_ok_starts_librarian(self):
        # a queued order whose worktree has a missing library gets a librarian issue
        sh_git("checkout", "-q", "main", cwd=self.clone)
        with open(os.path.join(self.clone, "package.json"), "w") as fh:
            json.dump({"dependencies": {"left-pad": "1.0.0"}}, fh)
        sh_git("add", "package.json", cwd=self.clone)
        sh_git("commit", "-qm", "pkg", cwd=self.clone)
        sh_git("push", "-q", "origin", "main", cwd=self.clone)
        self.start(601, "Needs docs")
        rc, out = self.tick()
        self.assertEqual(rc, 0, (out, self.last_err))
        st = self.load("GUL-601")
        self.assertEqual(st["phase"], "librarian")
        body = FAKE.stage_issue_posts()[0][2]
        self.assertEqual(body["title"], "[librarian] GUL-601 Needs docs")
        self.assertEqual(body["assigneeAgentId"], AGENTS["librarian"])
        headings = [ln for ln in body["description"].splitlines() if ln.startswith("## ")]
        self.assertEqual(headings[:2], ["## What the factory remembers", "## Docs ready"])
        self.assertIn("| left-pad | 1.0.0 | package.json | missing |", body["description"])

        # the librarian never stops an order: no docs-ready document -> red with no-docs rows
        self.issue_of(st["stages"][0])["status"] = "done"
        rc, out = self.tick()
        st = self.load("GUL-601")
        self.assertEqual(st["phase"], "red", self.last_err)
        self.assertEqual(st["docsReady"][0]["indexed"], False)
        self.assertTrue(st["docsReady"][0]["note"].startswith("no docs: "))
        self.assert_no_blocked_stage_issue()


if __name__ == "__main__":
    unittest.main(verbosity=2)
