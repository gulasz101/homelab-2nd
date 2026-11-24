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
FALLBACK = "a0000000-0000-4000-8000-0000000000fb"
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
        self.runs = {}              # issue id -> heartbeat runs
        self.run_details = {}       # run id -> full heartbeat run (with `error`)
        self.agents[FALLBACK] = {"id": FALLBACK, "status": "idle"}
        self.interactions = {}      # issue id -> interaction cards

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
    if path.startswith("/gh/"):
        if path == "/gh/repos/%s/installation" % REPO and method == "GET":
            return 200, {"id": 77}
        if path == "/gh/app/installations/77/access_tokens" and method == "POST":
            return 201, {"token": "ghs_fake_installation_token"}
        return 404, {"message": "Not Found"}
    if path == "/docs/api/listLibraries" and method == "GET":
        return 200, {"result": {"data": {"json": FAKE.docs}}}
    if path.startswith("/docsdown/"):
        return 503, {"error": "down"}
    if path == "/lodge/events" and method == "POST":
        return 201, {"ok": True}
    return 404, {"error": "no route %s %s" % (method, path)}


def paperclip(method, parts, query, body):
    n = len(parts)
    if parts[0] == "heartbeat-runs" and n == 2 and method == "GET":
        # the real server: the per-issue run list leaves `error` null, the detail has it
        run = FAKE.run_details.get(parts[1])
        return (200, run) if run else (404, {"error": "no run"})
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
            return 200, FAKE.runs.get(iid, [])
        if n == 3 and parts[2] == "interactions" and method == "GET":
            return 200, FAKE.interactions.get(iid, [])
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
            project = (query.get("projectId") or [None])[0]
            status = (query.get("status") or [None])[0]
            return 200, [i for i in FAKE.issues.values()
                         if (parent is None or i.get("parentId") == parent)
                         and (project is None or i.get("projectId") == project)
                         and (status is None or i.get("status") in status.split(","))]
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

    def test_06c_stall_halts_an_open_attempt(self):
        # GUL-2083, 2026-11-23: the order stalled, but its open green attempt kept its
        # assignee, and the agent wrote into the shared clone. A stall stops it.
        self.start(305, "Halt on stall")
        self.tick()
        st = self.load("GUL-305")
        row = st["stages"][0]
        self.issue_of(row)["status"] = "in_progress"
        subprocess.run(["git", "-C", self.clone, "worktree", "remove", "--force", st["worktree"]],
                       check=True)
        self.tick()
        st = self.load("GUL-305")
        self.assertEqual(st["phase"], "stalled", self.last_err)
        row = st["stages"][0]
        self.assertEqual(row["result"], "halted", "stopped, not counted as a failure")
        issue = self.issue_of(row)
        self.assertEqual(issue["status"], "cancelled")
        self.assertIsNone(issue.get("assigneeAgentId"), "no agent keeps running it")
        path = "/pc/api/issues/%s" % row["issueId"]
        patch = [n for n, r in enumerate(FAKE.requests) if r[0] == "PATCH" and r[1] == path
                 and r[2].get("status") == "cancelled"]
        comment = [n for n, r in enumerate(FAKE.requests) if r[0] == "POST" and r[1] == path + "/comments"]
        self.assertEqual(len(patch), 1)
        self.assertEqual(len(comment), 1)
        self.assertLess(patch[0], comment[0], "unassigned before the comment (GUL-2074)")
        # the worktree comes back and the order is resumed: a new attempt, not attempt 3 of 3
        self.tick()
        self.assertEqual(len([p for p in FAKE.stage_issue_posts() if p[2]["title"].startswith("[red")]), 1,
                         "a stalled order creates no attempt")
        self.assert_no_blocked_stage_issue()

    def test_06d_usage_limit_moves_the_stage_to_its_fallback(self):
        # GUL-2037 phase 4: the Reviewer on Sonnet shares the Claude subscription limit. A run
        # that hits it is not the agent's failure: the stage moves to its fallback agent.
        self.write_config(fallbackAgents={"red": FALLBACK}, fallbackNames={"red": "glm"})
        self.start(306, "Limit fallback")
        self.tick()
        st = self.load("GUL-306")
        row = st["stages"][0]
        self.assertEqual(self.issue_of(row)["assigneeAgentId"], AGENTS["red"])
        self.issue_of(row)["status"] = "in_progress"
        # a live run: Paperclip may still retry by itself, so the engine waits
        FAKE.runs[row["issueId"]] = [
            {"status": "failed", "error": "ACP agent reported a terminal limit failure.\n"
                                          "You've hit your 5-hour limit"},
            {"status": "running"}]
        self.tick()
        self.assertEqual(self.load("GUL-306")["stages"][0]["result"], "pending")
        FAKE.runs[row["issueId"]][1]["status"] = "failed"
        rc, out = self.tick()
        st = self.load("GUL-306")
        first, second = st["stages"][0], st["stages"][1]
        self.assertEqual(first["result"], "limit", self.last_err)
        self.assertEqual(st["fallbackStages"], ["red"])
        old = self.issue_of(first)
        self.assertEqual(old["status"], "cancelled")
        self.assertIsNone(old.get("assigneeAgentId"), "the limited agent is not woken again")
        self.assertEqual(self.issue_of(second)["assigneeAgentId"], FALLBACK)
        self.assertEqual(second["result"], "pending")
        self.assertIn("fallback-red", self.order_line(out, "GUL-306")["flags"])
        # a failure that is not a limit never moves anything
        self.issue_of(second)["status"] = "in_progress"
        FAKE.runs[second["issueId"]] = [{"status": "failed", "error": "process exited 1"}]
        self.tick()
        st = self.load("GUL-306")
        self.assertEqual(len(st["stages"]), 2)
        self.assertEqual(st["stages"][1]["result"], "pending")
        # a limit run of a stage with no fallback agent waits for the idle timeout as before
        self.write_config()
        FAKE.runs[second["issueId"]] = [{"status": "failed", "error": "You've hit your weekly limit"}]
        self.tick()
        self.assertEqual(len(self.load("GUL-306")["stages"]), 2)
        self.assert_no_blocked_stage_issue()

    def test_06d2_limit_on_a_blocked_attempt_with_a_bare_run_list(self):
        # GUL-2147 live: Paperclip spent its retry budget and set the attempt `blocked`
        # before the engine's tick, and its run list has `error: null`. The limit text is
        # only in /heartbeat-runs/<id>. That is still a limit: fallback, no attempt used.
        self.write_config(fallbackAgents={"red": FALLBACK}, fallbackNames={"red": "glm"})
        self.start(307, "Limit on blocked")
        self.tick()
        row = self.load("GUL-307")["stages"][0]
        self.issue_of(row)["status"] = "blocked"
        FAKE.comments.append((row["issueId"], "Paperclip retried this issue's run after it ended "
                              "without finishing, but the bounded retry budget is spent"))
        FAKE.runs[row["issueId"]] = [{"runId": "r-307", "status": "failed", "error": None,
                                      "errorCode": "acpx_turn_failed"}]
        FAKE.run_details["r-307"] = {"runId": "r-307", "status": "failed",
                                     "error": "ACP agent reported a terminal limit failure.\n"
                                              "You've hit your 5-hour limit",
                                     "errorCode": "acpx_turn_failed"}
        self.tick()
        st = self.load("GUL-307")
        first, second = st["stages"][0], st["stages"][1]
        self.assertEqual(first["result"], "limit", self.last_err)
        self.assertEqual(st["fallbackStages"], ["red"])
        self.assertEqual(self.issue_of(second)["assigneeAgentId"], FALLBACK)
        # a blocked attempt whose run failed for another reason still uses an attempt
        self.issue_of(second)["status"] = "blocked"
        FAKE.runs[second["issueId"]] = [{"runId": "r-307b", "status": "failed", "error": None}]
        FAKE.run_details["r-307b"] = {"runId": "r-307b", "status": "failed", "error": "process exited 1"}
        self.tick()
        self.assertEqual(self.load("GUL-307")["stages"][1]["result"], "fail")

    def test_06e_claude_guard_is_written_into_the_worktree(self):
        # The Reviewer on Sonnet runs on Paperclip's ACP engine, which ignores extra CLI
        # flags but loads the worktree's .claude/settings.local.json.
        guard = os.path.join(self.tmp, "guard.json")
        with open(guard, "w") as fh:
            json.dump({"permissions": {"deny": ["Edit", "Write"]},
                       "hooks": {"PreToolUse": [{"matcher": "*", "hooks": [
                           {"type": "command", "command": "node hook.ts readonly"}]}]}}, fh)
        self.write_config(claudeGuards={AGENTS["red"]: guard})
        self.start(307, "Guarded agent")
        self.tick()
        st = self.load("GUL-307")
        self.assertEqual(st["phase"], "red", self.last_err)
        self.assertEqual(len(st["stages"]), 1)
        target = os.path.join(st["worktree"], ".claude", "settings.local.json")
        with open(target) as fh:
            written = json.load(fh)
        self.assertEqual(written["hooks"]["PreToolUse"][0]["hooks"][0]["command"], "node hook.ts readonly")
        self.assertEqual(written["permissions"]["deny"], ["Edit", "Write"])
        self.assertEqual(oct(os.stat(target).st_mode & 0o777), "0o600")
        status = subprocess.run(["git", "-C", st["worktree"], "status", "--porcelain"],
                                stdout=subprocess.PIPE, text=True, check=True).stdout
        self.assertEqual(status, "", "the guard file never shows up in git")
        # Paperclip merges its own keys into the file; the engine keeps them
        written["permissions"]["allow"] = ["Bash(curl:*)"]
        written["permissions"]["deny"] = ["Bash(rm:*)"]
        with open(target, "w") as fh:
            json.dump(written, fh)
        self.issue_of(st["stages"][0])["status"] = "cancelled"
        self.tick()
        with open(target) as fh:
            again = json.load(fh)
        self.assertEqual(again["permissions"]["allow"], ["Bash(curl:*)"])
        self.assertEqual(again["permissions"]["deny"], ["Bash(rm:*)", "Edit", "Write"])

    def test_06f_broken_claude_guard_stalls_without_an_attempt(self):
        guard = os.path.join(self.tmp, "guard.json")
        with open(guard, "w") as fh:
            json.dump({"permissions": {"deny": ["Edit"]}}, fh)
        self.write_config(claudeGuards={AGENTS["red"]: guard})
        self.start(308, "Broken guard")
        rc, out = self.tick()
        st = self.load("GUL-308")
        self.assertEqual(st["phase"], "stalled", self.last_err)
        self.assertIn("no PreToolUse hook", st["stallReason"])
        self.assertIn("guard-missing", self.order_line(out, "GUL-308")["flags"])
        self.assertEqual(st["stages"], [])
        self.assertFalse([p for p in FAKE.stage_issue_posts() if p[2]["title"].startswith("[red")],
                         "the agent never runs without its guard")

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

    # -- phase 4: auto-merge ---------------------------------------------------
    FAKE_GH = r"""#!%(py)s
import json, os, sys
a = sys.argv[1:]
with open(%(log)r, "a") as fh:
    fh.write(json.dumps({"argv": a, "token": os.environ.get("GH_TOKEN", "")}) + "\n")
files = json.loads(os.environ.get("FAKE_GH_FILES", '["README.md"]'))
if a[:2] == ["pr", "checks"]:
    print(json.dumps([{"name": "check", "state": os.environ.get("FAKE_GH_CHECK", "SUCCESS")}])); sys.exit(0)
if a[:1] == ["api"] and a[1:3] == ["-X", "PUT"]:
    rc = int(os.environ.get("FAKE_GH_UPD_RC", "0"))
    if rc:
        sys.stderr.write("HTTP 422: merge conflict\n")
    else:
        print(json.dumps({"message": "Updating pull request branch."}))
    sys.exit(rc)
if a[:1] == ["api"] and "/commits/" in a[1]:
    parents = json.loads(os.environ.get("FAKE_GH_PARENTS", "[]"))
    print(json.dumps({"parents": [{"sha": x} for x in parents]})); sys.exit(0)
if a[:1] == ["api"] and "/compare/" in a[1]:
    print(json.dumps({"status": os.environ.get("FAKE_GH_CMP", "ahead")})); sys.exit(0)
if a[:2] == ["pr", "view"] and "headRefOid,baseRefOid,additions,deletions,files,mergeable,isDraft" in a:
    print(json.dumps({"headRefOid": "h" * 40, "baseRefOid": "b" * 40, "additions": 3,
                      "deletions": 1, "mergeable": "MERGEABLE", "isDraft": False,
                      "files": [{"path": f, "changeType": "MODIFIED"} for f in files]}))
    sys.exit(0)
if a[:2] == ["pr", "view"]:
    print(json.dumps({"state": "OPEN", "mergedAt": None, "mergeCommit": None,
                      "headRefOid": os.environ.get("FAKE_GH_HEAD", "h" * 40),
                      "mergeStateStatus": os.environ.get("FAKE_GH_MSS", "CLEAN")}))
    sys.exit(0)
if a[:2] == ["pr", "comment"]:
    sys.exit(0)
if a[:2] == ["pr", "merge"]:
    rc = int(os.environ.get("FAKE_GH_MERGE_RC", "0"))
    if rc:
        sys.stderr.write("GraphQL: Repository rule violations found\n")
    sys.exit(rc)
sys.stderr.write("fake gh: no route %%r\n" %% (a,)); sys.exit(1)
"""

    def gate_order(self, number, **cfg):
        self.write_config(**cfg)
        self.start(number, "Auto merge")
        self.tick()
        st = self.load("GUL-%d" % number)
        st.update({"phase": "gate", "pr": {"number": 12, "url": "https://github.com/x/y/pull/12",
                                          "head": "h" * 40}})
        st["stages"].append({"stage": "review", "identifier": "GUL-990", "result": "pass"})
        with open(os.path.join(self.state, "GUL-%d.json" % number), "w") as fh:
            json.dump(st, fh)
        with open(self.gh, "w") as fh:
            fh.write(self.FAKE_GH % {"py": sys.executable, "log": self.gh_log})
        os.chmod(self.gh, 0o755)
        self.app_key = os.path.join(self.tmp, "app.pem")
        subprocess.run(["openssl", "genrsa", "-out", self.app_key, "2048"], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return "GUL-%d" % number

    def gh_calls(self):
        if not os.path.exists(self.gh_log):
            return []
        with open(self.gh_log) as fh:
            return [json.loads(ln) for ln in fh if ln.startswith("{")]

    def app_env(self, **over):
        env = {"FACTORY_GH_APP_KEY_FILE": self.app_key, "FACTORY_GITHUB_API": self.base + "/gh"}
        env.update(over)
        return env

    def test_14_auto_merge_as_the_app(self):
        wo = self.gate_order(1401, autoMerge=True, githubApp={"appId": 5893473})
        rc, out = self.tick(**self.app_env())
        self.assertEqual(rc, 0, (out, self.last_err))
        st = self.load(wo)
        self.assertEqual(st["phase"], "awaiting_merge", self.last_err)
        self.assertTrue(st["gate"]["autoMerge"]["merged"], st["gate"])
        merges = [c for c in self.gh_calls() if c["argv"][:2] == ["pr", "merge"]]
        self.assertEqual(len(merges), 1)
        self.assertIn("--squash", merges[0]["argv"])
        self.assertEqual(merges[0]["argv"][merges[0]["argv"].index("--match-head-commit") + 1], "h" * 40)
        self.assertEqual(merges[0]["token"], "ghs_fake_installation_token")
        comments = [c for c in self.gh_calls() if c["argv"][:2] == ["pr", "comment"]]
        self.assertEqual(len(comments), 1)
        self.assertIn("review: GUL-990 passed", comments[0]["argv"][-1])
        # the JWT is RS256, iss = the App id, and verifies against the key
        auth = [r for r in FAKE.requests if r[1] == "/gh/repos/%s/installation" % REPO][0][3]
        jwt = auth.get("Authorization", "").split(" ", 1)[1]
        head, payload, sig = jwt.split(".")
        pad = lambda x: x + "=" * (-len(x) % 4)  # noqa: E731
        import base64
        self.assertEqual(json.loads(base64.urlsafe_b64decode(pad(payload)))["iss"], "5893473")
        pub = os.path.join(self.tmp, "pub.pem")
        subprocess.run(["openssl", "rsa", "-in", self.app_key, "-pubout", "-out", pub], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        sigf = os.path.join(self.tmp, "sig")
        with open(sigf, "wb") as fh:
            fh.write(base64.urlsafe_b64decode(pad(sig)))
        ver = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub, "-signature", sigf],
                             input=("%s.%s" % (head, payload)).encode(), stdout=subprocess.PIPE)
        self.assertEqual(ver.returncode, 0, ver.stdout)
        token_req = [r for r in FAKE.requests if r[1].endswith("/access_tokens")][0]
        self.assertEqual(token_req[2]["repositories"], ["homelab-2nd"])
        self.assertIn("merged it (squash)", FAKE.comments[-1][1] if FAKE.comments else
                      json.dumps(FAKE.requests[-5:]))

    def test_15_never_path_is_left_to_the_owner(self):
        wo = self.gate_order(1402, autoMerge=True, githubApp={"appId": 5893473})
        rc, out = self.tick(**self.app_env(FAKE_GH_FILES='["agents/factory/engine.py"]'))
        self.assertEqual(rc, 0, (out, self.last_err))
        st = self.load(wo)
        self.assertEqual(st["phase"], "awaiting_merge", self.last_err)
        self.assertEqual(st["gate"]["result"], "pass")
        self.assertIn("never path (glob): agents/factory/engine.py", st["gate"]["safety"])
        self.assertFalse(st["gate"]["autoMerge"]["merged"])
        self.assertIn("SAFETY", st["gate"]["autoMerge"]["why"])
        self.assertEqual([c for c in self.gh_calls() if c["argv"][:2] in (["pr", "merge"], ["pr", "comment"])], [])

    def test_16_no_key_or_refused_merge_never_stalls(self):
        wo = self.gate_order(1403, autoMerge=True, githubApp={"appId": 5893473})
        rc, out = self.tick(**self.app_env(FACTORY_GH_APP_KEY_FILE=os.path.join(self.tmp, "nope.pem")))
        st = self.load(wo)
        self.assertEqual(st["phase"], "awaiting_merge", self.last_err)
        self.assertIn("no GitHub App token", st["gate"]["autoMerge"]["why"])
        self.assertEqual([c for c in self.gh_calls() if c["argv"][:2] == ["pr", "merge"]], [])
        wo = self.gate_order(1404, autoMerge=True, githubApp={"appId": 5893473})
        rc, out = self.tick(**self.app_env(FAKE_GH_MERGE_RC="1"))
        st = self.load(wo)
        self.assertEqual(st["phase"], "awaiting_merge", self.last_err)
        self.assertIn("Repository rule violations", st["gate"]["autoMerge"]["why"])
        self.assert_no_blocked_stage_issue()

    # -- phase 4: the check after the merge (decision 8) ------------------------
    DEPLOY_GH = r"""#!%(py)s
import json, os, sys
a = sys.argv[1:]
with open(%(log)r, "a") as fh:
    fh.write(json.dumps({"argv": a, "token": os.environ.get("GH_TOKEN", "")}) + "\n")
if a[:2] == ["pr", "view"]:
    print(json.dumps({"state": "MERGED", "mergedAt": "2026-11-23T20:00:00Z",
                      "mergeCommit": {"oid": os.environ["FAKE_MERGE_SHA"]},
                      "headRefOid": os.environ["FAKE_MERGE_SHA"]})); sys.exit(0)
if a[:2] == ["pr", "checks"]:
    print(json.dumps([{"name": "check", "state": os.environ.get("FAKE_GH_CHECK", "SUCCESS")}])); sys.exit(0)
if a[:1] == ["api"] and a[1:3] == ["-X", "PUT"]:
    rc = int(os.environ.get("FAKE_GH_UPD_RC", "0"))
    if rc:
        sys.stderr.write("HTTP 422: merge conflict\n")
    else:
        print(json.dumps({"message": "Updating pull request branch."}))
    sys.exit(rc)
if a[:1] == ["api"] and "/commits/" in a[1]:
    parents = json.loads(os.environ.get("FAKE_GH_PARENTS", "[]"))
    print(json.dumps({"parents": [{"sha": x} for x in parents]})); sys.exit(0)
if a[:1] == ["api"] and "/compare/" in a[1]:
    print(json.dumps({"status": os.environ.get("FAKE_GH_CMP", "ahead")})); sys.exit(0)
if a[:2] == ["pr", "create"]:
    print("https://github.com/gulasz101/homelab-2nd/pull/77"); sys.exit(0)
if a[:2] == ["pr", "merge"]:
    sys.exit(0)
sys.stderr.write("fake gh: no route %%r\n" %% (a,)); sys.exit(1)
"""
    FAKE_KUBECTL = r"""#!%(py)s
import json, os, sys
a = sys.argv[1:]
with open(%(log)r, "a") as fh:
    fh.write(json.dumps({"argv": a}) + "\n")
if a[:1] == ["annotate"]:
    sys.exit(0)
with open(%(rows)r) as fh:
    rows = json.load(fh)
items = [{"metadata": {"name": r["name"]}, "status": {
    "lastAppliedRevision": "main@sha1:" + r["applied"], "lastAttemptedRevision": "main@sha1:" + r["attempted"],
    "conditions": [{"type": "Ready", "status": r["ready"], "message": r.get("message", "")}]}} for r in rows]
print(json.dumps({"items": items}))
"""

    def merged_order(self, number, live_checks, **cfg):
        spec = SPEC_BODY.replace('"maxDiffLines": 100}', '"maxDiffLines": 100,\n "liveChecks": %s}'
                                 % json.dumps(live_checks))
        self.write_config(autoMerge=True, githubApp={"appId": 5893473}, postMergeCheck=True, **cfg)
        rc, out = self.start(number, "Deploy check", spec_body=spec)
        self.assertEqual(rc, 0, out)
        self.tick()
        wo = "GUL-%d" % number
        st = self.load(wo)
        wt = st["worktree"]
        self.base_sha = git_out("-C", self.origin, "rev-parse", "main")
        with open(os.path.join(wt, "feature-%d.txt" % number), "w") as fh:
            fh.write("shipped\n")
        sh_git("add", "-A", cwd=wt)
        sh_git("commit", "-qm", "the feature", cwd=wt)
        sh_git("push", "-q", "origin", "HEAD:main", cwd=wt)
        self.merge_sha = git_out("-C", wt, "rev-parse", "HEAD")
        st.update({"phase": "awaiting_merge",
                   "pr": {"number": 12, "url": "https://github.com/x/y/pull/12", "head": self.merge_sha}})
        with open(os.path.join(self.state, wo + ".json"), "w") as fh:
            json.dump(st, fh)
        with open(self.gh, "w") as fh:
            fh.write(self.DEPLOY_GH % {"py": sys.executable, "log": self.gh_log})
        os.chmod(self.gh, 0o755)
        self.kube_rows = os.path.join(self.tmp, "kube.json")
        self.kube_log = os.path.join(self.tmp, "kube.log")
        self.kube = os.path.join(self.tmp, "kubectl")
        with open(self.kube, "w") as fh:
            fh.write(self.FAKE_KUBECTL % {"py": sys.executable, "log": self.kube_log, "rows": self.kube_rows})
        os.chmod(self.kube, 0o755)
        self.app_key = os.path.join(self.tmp, "app.pem")
        subprocess.run(["openssl", "genrsa", "-out", self.app_key, "2048"], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return wo

    def flux(self, *rows):
        with open(self.kube_rows, "w") as fh:
            json.dump([dict(zip(("name", "ready", "applied", "attempted", "message"), r)) for r in rows], fh)

    def deploy_env(self, **over):
        return self.app_env(FACTORY_KUBECTL=self.kube, FAKE_MERGE_SHA=self.merge_sha, **over)

    def test_17_post_merge_waits_for_flux_then_live_checks_pass(self):
        wo = self.merged_order(1701, [{"id": "LIVE-1", "check": "test -f feature-1701.txt"}])
        self.flux(("apps", "True", self.base_sha, self.base_sha))
        rc, out = self.tick(**self.deploy_env())
        self.assertEqual(rc, 0, (out, self.last_err))
        self.assertEqual(self.load(wo)["phase"], "deploy_check", self.last_err)
        rc, out = self.tick(**self.deploy_env())
        st = self.load(wo)
        self.assertEqual(st["phase"], "deploy_check", "Flux has not applied the merge yet")
        self.assertIn("flux-pending", self.order_line(out, wo)["flags"])
        with open(self.kube_log) as fh:
            self.assertEqual(sum(1 for ln in fh if '"annotate"' in ln), 1, "one reconcile request only")
        self.flux(("apps", "True", self.merge_sha, self.merge_sha))
        rc, out = self.tick(**self.deploy_env())
        st = self.load(wo)
        self.assertEqual(st["phase"], "done", self.last_err)
        self.assertEqual(st["deploy"]["liveChecks"], [])
        self.assertEqual(FAKE.by_ident(wo)["status"], "done")
        self.assertIn("1 live check(s) passed", [b for _, b in FAKE.comments][-1])
        self.assertEqual([c for c in self.gh_calls() if c["argv"][:2] == ["pr", "create"]], [])

    def test_18_failed_live_check_reverts_as_the_app_and_wakes_the_owner(self):
        wo = self.merged_order(1801, [{"id": "LIVE-1", "check": "echo broken; exit 3"}])
        self.flux(("apps", "True", self.merge_sha, self.merge_sha))
        self.tick(**self.deploy_env())
        rc, out = self.tick(**self.deploy_env())
        self.assertEqual(rc, 0, (out, self.last_err))
        st = self.load(wo)
        self.assertEqual(st["phase"], "reverting", self.last_err)
        self.assertIn("LIVE-1 exit 3: broken", st["deploy"]["failure"])
        rev = st["revert"]
        self.assertEqual(rev["number"], 77)
        # the revert branch is on origin, on top of main, and undoes the merge
        self.assertEqual(git_out("-C", self.origin, "rev-parse", "revert-gul-1801"), rev["head"])
        self.assertEqual(git_out("-C", self.origin, "rev-parse", "revert-gul-1801^"), self.merge_sha)
        self.assertEqual(git_out("-C", self.origin, "ls-tree", "--name-only", rev["head"]), "README.md")
        creates = [c for c in self.gh_calls() if c["argv"][:2] == ["pr", "create"]]
        self.assertEqual(creates[0]["token"], "ghs_fake_installation_token")
        rc, out = self.tick(**self.deploy_env())
        st = self.load(wo)
        self.assertEqual(st["phase"], "stalled", self.last_err)
        self.assertTrue(st["revert"]["merged"])
        merges = [c for c in self.gh_calls() if c["argv"][:2] == ["pr", "merge"]]
        self.assertEqual(merges[-1]["argv"][2], "77")
        self.assertEqual(merges[-1]["argv"][merges[-1]["argv"].index("--match-head-commit") + 1], rev["head"])
        self.assertIn("The factory reverted it", st["stallReason"])
        self.assertTrue(st["wake"]["sent"])
        self.assertEqual(FAKE.by_ident(wo)["status"], "blocked")

    def test_19_flux_failure_reverts_but_an_old_failure_does_not(self):
        wo = self.merged_order(1901, [])
        self.flux(("apps", "False", self.base_sha, self.merge_sha, "kustomize build failed"),
                  ("infra", "True", self.merge_sha, self.merge_sha))
        self.tick(**self.deploy_env())
        self.tick(**self.deploy_env())
        st = self.load(wo)
        self.assertEqual(st["phase"], "reverting", self.last_err)
        self.assertIn("apps: kustomize build failed", st["deploy"]["failure"])
        # broken before the merge, still broken on an older commit: never a revert
        wo = self.merged_order(1902, [], deployWaitMinutes=0)
        self.flux(("apps", "False", self.base_sha, self.base_sha, "old breakage"),
                  ("infra", "True", self.merge_sha, self.merge_sha))
        self.tick(**self.deploy_env())
        self.tick(**self.deploy_env())
        st = self.load(wo)
        self.assertEqual(st["phase"], "stalled", (st.get("deploy"), self.base_sha, self.merge_sha))
        self.assertNotIn("revert", st)
        self.assertIn("did not revert", st["stallReason"])

    def test_20_live_checks_are_linted(self):
        bad = SPEC_BODY.replace('"maxDiffLines": 100}', '"maxDiffLines": 100, "liveChecks": [{"id": "X"}]}')
        rc, out = self.start(2001, "Bad live check", spec_body=bad)
        self.assertNotEqual(rc, 0)
        self.assertIn("liveCheck", json.dumps(out))

    def test_24_behind_main_is_updated_then_merged(self):
        wo = self.gate_order(2401, autoMerge=True, githubApp={"appId": 5893473})
        # the App's first merge is refused: the branch is behind `main`
        self.tick(**self.app_env(FAKE_GH_MERGE_RC="1"))
        st = self.load(wo)
        self.assertEqual(st["phase"], "awaiting_merge", self.last_err)
        self.assertFalse(st["gate"]["autoMerge"]["merged"])
        # next tick: GitHub says BEHIND -> the engine asks for "Update branch" with the checked head
        self.tick(**self.app_env(FAKE_GH_MSS="BEHIND"))
        upd = [c for c in self.gh_calls() if c["argv"][:3] == ["api", "-X", "PUT"]]
        self.assertEqual(len(upd), 1, self.gh_calls())
        self.assertIn("expected_head_sha=" + "h" * 40, upd[0]["argv"])
        self.assertEqual(upd[0]["token"], "ghs_fake_installation_token")
        self.assertEqual(self.load(wo)["catchUp"]["pending"]["from"], "h" * 40)
        # the head has not moved yet: nothing else happens
        self.tick(**self.app_env(FAKE_GH_MSS="BEHIND"))
        self.assertEqual(len([c for c in self.gh_calls() if c["argv"][:3] == ["api", "-X", "PUT"]]), 1)
        # new head = checked head + a commit of main, CI pending: wait
        new = "n" * 40
        shape = dict(FAKE_GH_HEAD=new, FAKE_GH_MSS="BLOCKED",
                     FAKE_GH_PARENTS=json.dumps(["h" * 40, "m" * 40]), FAKE_GH_CMP="ahead")
        merges_before = len([c for c in self.gh_calls() if c["argv"][:2] == ["pr", "merge"]])
        self.tick(**self.app_env(FAKE_GH_CHECK="IN_PROGRESS", **shape))
        self.assertEqual(len([c for c in self.gh_calls() if c["argv"][:2] == ["pr", "merge"]]), merges_before)
        # CI passes: merged as the App, pinned to the new head
        self.tick(**self.app_env(**shape))
        st = self.load(wo)
        merges = [c for c in self.gh_calls() if c["argv"][:2] == ["pr", "merge"]]
        self.assertEqual(len(merges), merges_before + 1)
        self.assertEqual(merges[-1]["argv"][merges[-1]["argv"].index("--match-head-commit") + 1], new)
        self.assertTrue(st["gate"]["autoMerge"]["merged"], st["gate"])
        self.assertEqual(st["pr"]["head"], new)
        self.assertEqual(st["pr"]["checkedHead"], "h" * 40)
        self.assertEqual(st["catchUp"]["count"], 1)
        self.assertNotIn("gaveUp", st["catchUp"])
        approvals = [c for c in self.gh_calls() if c["argv"][:2] == ["pr", "comment"]][-1]["argv"][-1]
        self.assertIn("branch updated with `main`", approvals)
        self.assertIn("was behind `main`", FAKE.comments[-1][1])
        self.assert_no_blocked_stage_issue()

    def test_25_catch_up_refuses_a_foreign_head(self):
        wo = self.gate_order(2501, autoMerge=True, githubApp={"appId": 5893473})
        self.tick(**self.app_env(FAKE_GH_MERGE_RC="1"))
        self.tick(**self.app_env(FAKE_GH_MSS="BEHIND"))
        # someone else pushed: first parent is not the checked head
        self.tick(**self.app_env(FAKE_GH_HEAD="x" * 40, FAKE_GH_MSS="BLOCKED",
                                 FAKE_GH_PARENTS=json.dumps(["y" * 40, "m" * 40])))
        st = self.load(wo)
        self.assertIn("not a merge of the checked head", st["catchUp"]["gaveUp"])
        self.assertEqual(st["phase"], "awaiting_merge")
        self.assertFalse(st["gate"]["autoMerge"]["merged"])
        merges = [c for c in self.gh_calls() if c["argv"][:2] == ["pr", "merge"]]
        self.assertEqual(len(merges), 1)  # only the first, refused one
        self.assertIn("could not update it", FAKE.comments[-1][1])
        # a merge of main that is not on main is refused too; a refused update gives up at once
        wo = self.gate_order(2502, autoMerge=True, githubApp={"appId": 5893473})
        self.tick(**self.app_env(FAKE_GH_MERGE_RC="1"))
        self.tick(**self.app_env(FAKE_GH_MSS="BEHIND", FAKE_GH_UPD_RC="1"))
        self.assertIn("merge conflict", self.load(wo)["catchUp"]["gaveUp"])
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



class FailLines(unittest.TestCase):
    """Every FAIL line of a check is kept and shown, not only the 60-line tail
    (GUL-2132/2133: the failed test's name was above the tail, 2026-11-24)."""

    def load_engine(self):
        import importlib.util
        sys.path.insert(0, os.path.dirname(ENGINE))
        try:
            spec = importlib.util.spec_from_file_location("engine_under_test", ENGINE)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
        finally:
            sys.path.pop(0)
        return mod

    def test_26_fail_lines_survive_a_long_tail(self):
        eng = self.load_engine()
        out = "\n".join(["PASS render (2s)", "FAIL agents/factory-guard/tests/claude-hook-check.sh (1s)",
                          "PASS sops (2s)", "FAIL agents/x/tests/y-check.sh (3s)",
                          "FAIL agents/x/tests/y-check.sh (3s)"]
                         + ["noise %d" % n for n in range(200)]
                         + ['{"ok": false, "check": "check-green", "reasons": ["1 failed"]}'])
        res = eng.CheckResult(["check-green"], 1, {"ok": False, "reasons": ["1 failed"]}, out)
        self.assertNotIn("claude-hook-check.sh", "\n".join(res.tail), "test needs the name above the tail")
        self.assertEqual(res.fails, ["FAIL agents/factory-guard/tests/claude-hook-check.sh (1s)",
                                     "FAIL agents/x/tests/y-check.sh (3s)"])
        row = {"attempt": 1, "identifier": "GUL-1", "result": "fail", "checkLine": res.line,
               "outputTail": res.tail, "failLines": res.fails}
        section = eng.Engine.last_failed_section([row])
        self.assertIn("Every FAIL line of the check (2):", section)
        self.assertIn("FAIL agents/factory-guard/tests/claude-hook-check.sh (1s)", section)
        self.assertEqual(eng.fail_block([]), [])
        many = "\n".join("FAIL t%d" % n for n in range(eng.MAX_FAIL_LINES + 50))
        self.assertEqual(len(eng.fail_lines(many)), eng.MAX_FAIL_LINES)

class Pickup(EngineCase):
    """Phase 5 intake: a human-accepted spec-gate card starts the order with no PM run."""

    def card(self, wid, rev, outcome="accepted", user="user-1", agent=None, key="spec-gate:x"):
        FAKE.interactions.setdefault(wid, []).append({
            "id": str(uuid.uuid4()), "kind": "request_confirmation", "idempotencyKey": key,
            "status": "resolved", "result": {"version": 1, "outcome": outcome},
            "resolvedByUserId": user, "resolvedByAgentId": agent,
            "payload": {"target": {"type": "issue_document", "key": "spec", "revisionId": rev}}})

    def in_review(self, number, title="Pick me up", spec_body=SPEC_BODY):
        wid = FAKE.add_work_order(number, title, spec_body)
        FAKE.issues[wid]["status"] = "in_review"
        return wid

    def test_27_accepted_spec_gate_starts_the_order(self):
        self.write_config(autoPickup=True, companyId=COMPANY,
                          repos={REPO: {"clone": self.clone, "worktrees": self.worktrees,
                                        "projectId": PROJECT}})
        good = self.in_review(301)
        self.card(good, "rev-spec-1")
        agent_ok = self.in_review(302)                       # an agent accepted: never counts
        self.card(agent_ok, "rev-spec-1", user=None, agent="a-1")
        stale = self.in_review(303)                          # accepted, but for an older revision
        self.card(stale, "rev-spec-0")
        rejected = self.in_review(304)
        self.card(rejected, "rev-spec-1", outcome="rejected")
        other = self.in_review(305)                          # not a spec-gate card
        self.card(other, "rev-spec-1", key="confirmation:plan")
        todo = FAKE.add_work_order(306, "Still todo")        # not in_review
        self.card(todo, "rev-spec-1")
        bad = self.in_review(307, spec_body="no fence here\n")
        self.card(bad, "rev-spec-1")

        rc, out = self.tick(apply=False)
        self.assertEqual(rc, 0, out)
        would = [l["workOrder"] for l in out["orders"] if l.get("outcome") == "would-start"]
        self.assertEqual(sorted(would), ["GUL-301", "GUL-307"])
        self.assertEqual(FAKE.mutating(), [], "a dry tick writes nothing")
        self.assertFalse(os.path.exists(os.path.join(self.state, "GUL-301.json")))

        rc, out = self.tick()
        self.assertEqual(self.load("GUL-301")["specRevisionId"], "rev-spec-1")
        self.assertEqual(FAKE.issues[good]["status"], "todo")
        for n in (302, 303, 304, 305, 306, 307):
            self.assertFalse(os.path.exists(os.path.join(self.state, "GUL-%d.json" % n)), n)
        refused = [l for l in out["orders"] if l.get("outcome") == "refused"]
        self.assertEqual([l["workOrder"] for l in refused], ["GUL-307"])
        bad_comments = [c for c in FAKE.comments if c[0] == bad]
        self.assertEqual(len(bad_comments), 1)
        self.assertIn("cannot start", bad_comments[0][1])

        self.tick()
        self.assertEqual(len([c for c in FAKE.comments if c[0] == bad]), 1,
                         "a refused revision is commented once, not on every tick")
        self.assertEqual(len([c for c in FAKE.comments if c[0] == good
                              and "approved the spec" in c[1]]), 1, "started once")

    def test_28_pickup_off_reads_no_issue_list(self):
        wid = self.in_review(311)
        self.card(wid, "rev-spec-1")
        self.tick()
        self.assertFalse(os.path.exists(os.path.join(self.state, "GUL-311.json")))
        self.assertFalse([r for r in FAKE.requests if "status=in_review" in r[1]])


if __name__ == "__main__":
    unittest.main(verbosity=2)
