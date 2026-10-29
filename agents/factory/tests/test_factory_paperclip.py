#!/usr/bin/env python3
"""Unit tests for `factory.py start|decide|tick` (GUL-439).

Runs against a stub Paperclip API (a small http.server in this file) and
throw-away git fixtures. No network, no real Paperclip, no Pi run.

    python3 agents/factory/tests/test_factory_paperclip.py

Exit 0 = every case passed. Non-zero = at least one failed.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
FACTORY = os.path.abspath(os.path.join(HERE, "..", "factory.py"))
sys.path.insert(0, os.path.dirname(FACTORY))
import pc  # noqa: E402  the factory's own client, for unit-level cases (GUL-496)
MAJSTER = "2df240b5-a5ea-4ebf-81ff-bf96758e8f80"
COMPANY = "c0000000-0000-4000-8000-000000000001"
PROJECT = "p0000000-0000-4000-8000-000000000001"

SPEC_BODY = """# Spec

```json
{"repo": "gulasz101/homelab-2nd", "base": "main", "kind": "tests",
 "allowedPaths": ["tests/**"],
 "acs": [{"id": "AC-1", "text": "the test command reports the new behaviour",
          "check": "bash tests/ac.sh"}],
 "maxDiffLines": 100}
```
"""

FAILURES = []
PASSES = []


# --------------------------------------------------------------------------
# stub Paperclip
# --------------------------------------------------------------------------

class State:
    def __init__(self):
        self.issues = {}
        self.documents = {}
        self.comments = []
        self.work_products = []
        self.interactions = []
        self.agents = {}
        self.runs = {}
        self.counter = 700
        # {(issueId, key): n} — force the next n PUTs of that document to 409
        self.put_conflicts = {}
        # {(issueId, key): n} — force the next n PUTs of that document to 500
        # (GUL-497: a ledger write that fails after the stage's work is done)
        self.put_failures = {}
        # the live API echoes the document bare; the stub can do either
        self.wrapped_documents = True

    def add_issue(self, **kw):
        ident = kw.pop("identifier", None)
        issue = {
            "id": str(uuid.uuid4()),
            "identifier": ident or ("GUL-%d" % self.next_number()),
            "companyId": COMPANY,
            "projectId": kw.pop("projectId", None),
            "parentId": kw.pop("parentId", None),
            "title": "work order",
            "status": "todo",
            "priority": "medium",
            "assigneeAgentId": None,
            "blockedByIssueIds": [],
            "executionPolicy": None,
            "currentExecutionWorkspace": None,
            "createdAt": "2026-10-28T08:00:00.000Z",
            "updatedAt": "2026-10-28T08:00:00.000Z",
        }
        issue.update(kw)
        self.issues[issue["id"]] = issue
        return issue

    def next_number(self):
        self.counter += 1
        return self.counter

    def doc(self, issue_id, key, body):
        self.documents[(issue_id, key)] = {
            "id": str(uuid.uuid4()), "key": key, "format": "markdown", "body": body,
            "issueId": issue_id, "latestRevisionId": str(uuid.uuid4()),
        }


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):  # keep the test output readable
            pass

        def _send(self, code, payload):
            raw = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def _body(self):
            length = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(length) or b"{}")

        def _parts(self):
            return [p for p in self.path.split("?")[0].split("/") if p]

        def do_GET(self):
            parts = self._parts()
            if parts[:3] == ["api", "companies", COMPANY] and parts[3:] == ["issues"]:
                return self._send(200, list(state.issues.values()))
            if parts[:2] == ["api", "issues"] and len(parts) == 3:
                issue = state.issues.get(parts[2])
                return self._send(200, issue) if issue else self._send(404, {"error": "not found"})
            if parts[:2] == ["api", "issues"] and len(parts) == 5 and parts[3] == "documents":
                doc = state.documents.get((parts[2], parts[4]))
                return self._send(200, {"document": doc}) if doc else self._send(404, {"error": "no doc"})
            if parts[:2] == ["api", "issues"] and len(parts) == 4 and parts[3] == "interactions":
                mine = [c for c in state.interactions if c.get("issueId") == parts[2]]
                return self._send(200, mine)
            if parts[:2] == ["api", "issues"] and len(parts) == 4 and parts[3] == "runs":
                return self._send(200, state.runs.get(parts[2], []))
            if parts[:2] == ["api", "agents"] and len(parts) == 3:
                agent = state.agents.get(parts[2])
                return self._send(200, agent) if agent else self._send(404, {"error": "no agent"})
            if parts[:2] == ["api", "projects"] and parts[3:] == ["workspaces"]:
                return self._send(200, [])
            return self._send(404, {"error": "API route not found"})

        def do_POST(self):
            parts = self._parts()
            body = self._body()
            if parts[:2] == ["api", "issues"] and parts[3:] == ["children"]:
                parent = state.issues.get(parts[2])
                if not parent:
                    return self._send(404, {"error": "no parent"})
                child = state.add_issue(
                    parentId=parent["id"], projectId=parent.get("projectId"),
                    title=body.get("title"), description=body.get("description"),
                    status=body.get("status", "todo"),
                    assigneeAgentId=body.get("assigneeAgentId"),
                    executionPolicy=body.get("executionPolicy"),
                    blockedByIssueIds=body.get("blockedByIssueIds") or [],
                )
                return self._send(201, child)
            if parts[:2] == ["api", "issues"] and parts[3:] == ["comments"]:
                state.comments.append({"issueId": parts[2], "body": body.get("body")})
                return self._send(201, {"id": str(uuid.uuid4())})
            if parts[:2] == ["api", "issues"] and len(parts) == 6 and parts[5] == "withdraw":
                for card in state.interactions:
                    if card.get("id") == parts[4]:
                        card["status"] = "withdrawn"
                        card["result"] = {"outcome": "withdrawn", "reason": body.get("reason")}
                        return self._send(200, card)
                return self._send(404, {"error": "no interaction"})
            if parts[:2] == ["api", "issues"] and parts[3:] == ["work-products"]:
                state.work_products.append(dict(body, issueId=parts[2]))
                return self._send(201, {"id": str(uuid.uuid4())})
            if parts[:2] == ["api", "issues"] and parts[3:] == ["interactions"]:
                state.interactions.append(dict(body, issueId=parts[2],
                                               id=str(uuid.uuid4()), status="pending"))
                return self._send(201, {"id": str(uuid.uuid4())})
            return self._send(404, {"error": "API route not found"})

        def do_PUT(self):
            parts = self._parts()
            body = self._body()
            if parts[:2] == ["api", "issues"] and len(parts) == 5 and parts[3] == "documents":
                slot = (parts[2], parts[4])
                existing = state.documents.get(slot)
                failures = state.put_failures.get(slot, 0)
                if failures:
                    state.put_failures[slot] = failures - 1
                    return self._send(500, {"error": "stub: forced write failure"})
                forced = state.put_conflicts.get(slot, 0)
                if forced:
                    state.put_conflicts[slot] = forced - 1
                    return self._send(409, {"error": "Document update requires baseRevisionId."})
                want = body.get("baseRevisionId")
                if existing is not None:
                    if not want or want != existing.get("latestRevisionId"):
                        return self._send(409, {"error": "Document update requires baseRevisionId."})
                elif want:
                    return self._send(409, {"error": "baseRevisionId refers to no revision"})
                doc = {"id": str(uuid.uuid4()), "key": parts[4], "format": "markdown",
                       "body": body.get("body"), "issueId": parts[2],
                       "title": body.get("title"),
                       "latestRevisionId": str(uuid.uuid4())}
                state.documents[slot] = doc
                return self._send(200, {"document": doc} if state.wrapped_documents else doc)
            return self._send(404, {"error": "API route not found"})

        def do_PATCH(self):
            parts = self._parts()
            body = self._body()
            if parts[:2] == ["api", "issues"] and len(parts) == 3:
                issue = state.issues.get(parts[2])
                if not issue:
                    return self._send(404, {"error": "not found"})
                for key in ("status", "executionPolicy", "assigneeAgentId"):
                    if key in body:
                        issue[key] = body[key]
                if body.get("comment"):
                    state.comments.append({"issueId": issue["id"], "body": body["comment"]})
                return self._send(200, issue)
            return self._send(404, {"error": "API route not found"})

    return Handler


class Stub:
    def __init__(self):
        self.state = State()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.state))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = "http://127.0.0.1:%d/api" % self.server.server_address[1]

    def close(self):
        self.server.shutdown()


class Blocked:
    """Stands in for the edge: every request is Cloudflare's 1010 block page."""

    PAGE = "<html><body><h1>Error 1010</h1>cloudflare</body></html>"

    def __init__(self):
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _answer(self):
                raw = Blocked.PAGE.encode()
                self.send_response(403)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            do_GET = do_POST = do_PUT = do_PATCH = _answer

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = "http://127.0.0.1:%d/api" % self.server.server_address[1]

    def close(self):
        self.server.shutdown()


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def run(stub, args, extra_env=None, with_key=True):
    env = dict(os.environ)
    env.pop("PAPERCLIP_API_KEY", None)
    env.pop("PAPERCLIP_RUN_ID", None)
    if with_key:
        env["PAPERCLIP_API_KEY"] = "test-key-not-a-secret"
        env["PAPERCLIP_RUN_ID"] = "test-run-id"
    env["PAPERCLIP_API_URL"] = stub.url
    env["PAPERCLIP_COMPANY_ID"] = COMPANY
    env["FACTORY_STOP"] = os.path.join(WORKDIR, "STOP")
    env["FACTORY_LEDGER_JSONL"] = os.path.join(WORKDIR, "ledger.jsonl")
    env["FACTORY_REPO"] = os.path.join(WORKDIR, "repo")
    if extra_env:
        env.update(extra_env)
    proc = subprocess.run([sys.executable, "-I", FACTORY] + args, env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                          cwd=os.path.dirname(FACTORY))
    parsed = None
    for line in proc.stdout.strip().splitlines():
        try:
            parsed = json.loads(line)
        except ValueError:
            continue
    return proc.returncode, parsed, proc.stdout + proc.stderr


def git(cwd, *args):
    subprocess.run(["git", "-C", cwd] + list(args), check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def make_repo(name="repo"):
    repo = os.path.join(WORKDIR, name)
    os.makedirs(os.path.join(repo, "tests"), exist_ok=True)
    with open(os.path.join(repo, "tests", "ac.sh"), "w") as fh:
        fh.write('#!/usr/bin/env bash\necho "AC-1: PASS"\nexit 0\n')
    with open(os.path.join(repo, "README.md"), "w") as fh:
        fh.write("fixture\n")
    git(repo, "init", "-q", "-b", "main")
    git(repo, "add", "-A")
    git(repo, "-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-qm", "base")
    git(repo, "remote", "add", "origin", repo)
    git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
    return repo, subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"],
                                stdout=subprocess.PIPE, text=True).stdout.strip()


def base_work_order(stub, base_sha, repo, identifier="GUL-900", project_id=None):
    number = identifier.split("-")[-1]
    branch = "gul-%s-add-the-fixture" % number
    issue = stub.state.add_issue(identifier=identifier, title="Add the fixture",
                                 assigneeAgentId=MAJSTER, projectId=project_id, status="in_progress")
    stub.state.doc(issue["id"], "spec", SPEC_BODY)
    ledger = {
        "version": 1, "workOrder": identifier, "workOrderId": issue["id"],
        "title": "Add the fixture", "repo": "gulasz101/homelab-2nd", "base": "main",
        "baseSha": base_sha, "cwd": repo, "branch": branch,
        "projectId": project_id, "stages": {}, "fixRounds": 0, "pr": None,
        "outcome": None, "escalated": None,
    }
    body = "# Factory ledger\n\n```json\n%s\n```\n" % json.dumps(ledger)
    stub.state.doc(issue["id"], "ledger", body)
    return issue


def git_out(repo, *args):
    proc = subprocess.run(["git", "-C", repo] + list(args),
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    return proc.stdout.strip() if proc.returncode == 0 else ""


def branch_sha(repo, branch):
    return git_out(repo, "rev-parse", "--verify", "--quiet", "refs/heads/" + branch)


def head_branch(repo):
    return git_out(repo, "rev-parse", "--abbrev-ref", "HEAD")


def stage_issue(stub, parent, title, status="in_progress"):
    return stub.state.add_issue(parentId=parent["id"], title=title, status=status,
                                assigneeAgentId=MAJSTER)


def check(name, condition, detail=""):
    if condition:
        PASSES.append(name)
        print("ok   %s" % name)
    else:
        FAILURES.append(name)
        print("FAIL %s %s" % (name, detail))


# --------------------------------------------------------------------------
# cases
# --------------------------------------------------------------------------

def case_start_cuts_branch(stub):
    """Gap 1 (GUL-481): start cuts the work order branch, refuses a dirty checkout."""
    repo, base_sha = make_repo("repo-branch")
    wo = base_work_order(stub, base_sha, repo, identifier="GUL-902", project_id=PROJECT)
    branch = "gul-902-add-the-fixture"
    env = {"FACTORY_REPO": repo}

    with open(os.path.join(repo, "README.md"), "a") as fh:
        fh.write("someone else's work in progress\n")
    code, out, raw = run(stub, ["start", "GUL-902"], extra_env=env)
    check("start: a dirty checkout is refused",
          code == 1 and any("dirty" in r for r in (out or {}).get("reasons", [])), raw[-400:])
    check("start: a dirty checkout gets no branch", branch_sha(repo, branch) == "", branch)
    check("start: a dirty checkout creates no stages",
          not [i for i in stub.state.issues.values() if i.get("parentId") == wo["id"]],
          str([i.get("title") for i in stub.state.issues.values()]))

    git(repo, "checkout", "--", "README.md")
    code, out, raw = run(stub, ["start", "GUL-902"], extra_env=env)
    check("start: cuts the branch at baseSha and switches to it",
          code == 0 and branch_sha(repo, branch) == base_sha and head_branch(repo) == branch,
          "%s %s %s" % (code, branch_sha(repo, branch), head_branch(repo)))
    ledger_body = stub.state.documents[(wo["id"], "ledger")]["body"]
    check("start: the ledger records the branch it cut",
          branch in ledger_body and base_sha in ledger_body, ledger_body[:200])

    code2, out2, raw2 = run(stub, ["start", "GUL-902"], extra_env=env)
    check("start twice: no-op, branch stays where it is",
          code2 == 0 and (out2 or {}).get("created") == 0
          and branch_sha(repo, branch) == base_sha and head_branch(repo) == branch, raw2[-300:])

    # a branch already cut at baseSha but no ledger yet: switch to it, do not fail
    wo3 = base_work_order(stub, base_sha, repo, identifier="GUL-903", project_id=PROJECT + "-b")
    reused = "gul-903-add-the-fixture"
    git(repo, "branch", reused, base_sha)
    git(repo, "switch", "--detach", base_sha)
    code3, out3, raw3 = run(stub, ["start", "GUL-903"], extra_env=env)
    check("start: an existing branch at baseSha is re-used, not re-created",
          code3 == 0 and head_branch(repo) == reused, raw3[-300:])

    # a branch that exists at another sha is refused, not force-reset
    wo4 = base_work_order(stub, base_sha, repo, identifier="GUL-904", project_id=PROJECT + "-c")
    git(repo, "switch", "-c", "gul-904-add-the-fixture", base_sha)
    with open(os.path.join(repo, "README.md"), "a") as fh:
        fh.write("another commit\n")
    git(repo, "-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-qam", "moved")
    git(repo, "switch", "main")
    code4, out4, raw4 = run(stub, ["start", "GUL-904"], extra_env=env)
    check("start: a branch that moved off baseSha is refused",
          code4 == 1 and any("already exists" in r for r in (out4 or {}).get("reasons", [])),
          raw4[-300:])

    # keep these work orders out of the shared-project busy check of later cases
    for issue in (wo, wo3, wo4):
        stub.state.issues[issue["id"]]["status"] = "done"


def case_start_refuses_tooling_checkout(stub):
    """GUL-502 (ADR-096): the factory's own code runs from a checkout of main. If
    `start` were allowed to cut a work order branch there, the next invocation
    would move that tree back to main and the ledger would point at a checkout
    that no longer holds the diff."""
    repo, base_sha = make_repo("repo-tooling")
    tooling = os.path.abspath(os.path.join(os.path.dirname(FACTORY), "..", ".."))
    wo = base_work_order(stub, base_sha, repo, identifier="GUL-905")
    code, out, raw = run(stub, ["start", "GUL-905", "--repo", tooling])
    check("start: refuses to cut a branch in the factory's own tooling checkout",
          code == 2 and any("tooling checkout" in r for r in (out or {}).get("reasons", [])),
          raw[-400:])
    check("start: the tooling checkout keeps its branch (none created)",
          git_out(tooling, "rev-parse", "--abbrev-ref", "HEAD") != "gul-905-add-the-fixture",
          git_out(tooling, "rev-parse", "--abbrev-ref", "HEAD"))
    stub.state.issues[wo["id"]]["status"] = "done"


def case_start_creates_chain(stub, base_sha, repo):
    wo = base_work_order(stub, base_sha, repo)
    code, out, raw = run(stub, ["start", "GUL-900"])
    children = [i for i in stub.state.issues.values() if i.get("parentId") == wo["id"]]
    titles = [c["title"] for c in children]
    check("start: exits 0", code == 0, raw[-400:])
    check("start: creates 5 children", len(children) == 5, titles)
    check("start: creates the 5 chained children with the review stage",
          [t.split("]")[0] + "]" for t in titles] == ["[red]", "[green]", "[review]", "[verify]", "[gate]"], titles)
    check("start: first child todo, the rest blocked",
          [c["status"] for c in children] == ["todo", "blocked", "blocked", "blocked", "blocked"],
          [c["status"] for c in children])
    chain = [c["blockedByIssueIds"] for c in children]
    check("start: each stage blocked by the one before",
          chain == [[], [children[0]["id"]], [children[1]["id"]], [children[2]["id"]], [children[3]["id"]]],
          chain)
    policy = children[0]["executionPolicy"]
    check("start: red/green/review/verify carry the review hand-off to Majster",
          all(c["executionPolicy"] == {"stages": [{"type": "review", "participants": [
              {"type": "agent", "agentId": MAJSTER}]}]} for c in children[:4]), policy)
    with open(os.path.join(HERE, "..", "agents.json"), encoding="utf-8") as fh:
        stage_cfg = json.load(fh)
    expected_agents = [stage_cfg["stages"][s]["agentId"]
                       for s in ("red", "green", "review", "verify")] + [stage_cfg["majster"]]
    check("start: stage agents come from agents.json",
          [c["assigneeAgentId"] for c in children] == expected_agents,
          [c["assigneeAgentId"] for c in children])
    check("start: red template's hand-off is the last step and carries the report",
          '"status": "in_review", "executionPolicy"' in children[0]["description"]
          and '"comment": "<the short report' in children[0]["description"]
          and "before** the hand-off" in children[0]["description"])
    check("start: ledger records base, branch and cwd",
          all(k in stub.state.documents[(wo["id"], "ledger")]["body"]
              for k in (base_sha, "gul-900-add-the-fixture", repo)))

    code2, out2, raw2 = run(stub, ["start", "GUL-900"])
    after = [i for i in stub.state.issues.values() if i.get("parentId") == wo["id"]]
    check("start twice: creates no duplicates", code2 == 0 and len(after) == 5
          and (out2 or {}).get("created") == 0, raw2[-300:])


def case_stop_blocks(stub, base_sha, repo):
    wo = base_work_order(stub, base_sha, repo)
    open(os.path.join(WORKDIR, "STOP"), "w").close()
    code, out, raw = run(stub, ["start", "GUL-900"])
    check("STOP: start refuses", code == 1 and "STOP" in (out or {}).get("reasons", [""])[0], raw[-300:])
    stage = stage_issue(stub, wo, "[red] GUL-900 — Add the fixture")
    code2, out2, raw2 = run(stub, ["decide", "GUL-%s" % stage["identifier"].split("-")[1], "--apply"])
    check("STOP: decide refuses", code2 == 1 and "STOP" in (out2 or {}).get("reasons", [""])[0], raw2[-300:])
    os.unlink(os.path.join(WORKDIR, "STOP"))
    return wo, stage


def case_missing_key(stub):
    code, out, raw = run(stub, ["start", "GUL-900"], with_key=False)
    check("missing key: exits 2 and says which one",
          code == 2 and "PAPERCLIP_API_KEY" in raw, raw[-300:])


def case_decide_red(stub, base_sha, repo):
    wo = base_work_order(stub, base_sha, repo)
    stage = stage_issue(stub, wo, "[red] GUL-900 — Add the fixture")
    # make the AC check fail: only a test path changes
    with open(os.path.join(repo, "tests", "ac.sh"), "w") as fh:
        fh.write('#!/usr/bin/env bash\necho "AC-1: FAIL not implemented yet"\nexit 1\n')
    code, out, raw = run(stub, ["decide", stage["identifier"], "--apply"])
    check("decide red: pass approves the stage",
          code == 0 and out.get("decision") == "approve"
          and stub.state.issues[stage["id"]]["status"] == "done", raw[-600:])
    check("decide red: the comment carries the check JSON and its output",
          any('"check": "check-red"' in c["body"] and "check-red: PASS" in c["body"]
              for c in stub.state.comments),
          [c["body"][:120] for c in stub.state.comments][-2:])

    # a non-test change fails red
    wo2 = stub.state.add_issue(identifier="GUL-901", title="Another order",
                               assigneeAgentId=MAJSTER, status="in_progress")
    stub.state.doc(wo2["id"], "spec", SPEC_BODY)
    stub.state.doc(wo2["id"], "ledger", stub.state.documents[(wo["id"], "ledger")]["body"])
    stage2 = stage_issue(stub, wo2, "[red] GUL-901 — Another order")
    with open(os.path.join(repo, "README.md"), "w") as fh:
        fh.write("production code changed in the red stage\n")
    code2, out2, raw2 = run(stub, ["decide", stage2["identifier"], "--apply"])
    check("decide red: fail requests changes",
          code2 == 1 and out2.get("decision") == "request_changes"
          and stub.state.issues[stage2["id"]]["status"] == "in_progress", raw2[-500:])
    return wo, stage


def case_verify_fix_round(stub, base_sha, repo):
    wo = base_work_order(stub, base_sha, repo)
    stub.state.documents[(wo["id"], "ledger")]["body"] = (
        "# Factory ledger\n\n```json\n%s\n```\n" % json.dumps({
            "version": 1, "workOrder": "GUL-900", "workOrderId": wo["id"], "title": "Add the fixture",
            "repo": "gulasz101/homelab-2nd", "base": "main", "baseSha": base_sha, "cwd": repo,
            "branch": "gul-900", "projectId": None, "fixRounds": 0, "pr": None,
            "outcome": None, "escalated": None,
            "stages": {"review": {"issueId": "review-1", "identifier": "GUL-950", "round": 1,
                                  "attempts": 0, "sha": None},
                       "verify": {"issueId": "verify-1", "identifier": "GUL-951", "round": 1,
                                  "attempts": 0, "sha": None}},
        }))
    review = stub.state.add_issue(identifier="GUL-950", title="[review] GUL-900", parentId=wo["id"])
    verify = stage_issue(stub, wo, "[verify] GUL-900 — Add the fixture")
    stub.state.doc(review["id"], "findings",
                   '# Findings\n\n```json\n[{"id": "F-1", "file": "tests/ac.sh", "line": 1, '
                   '"severity": "blocking", "claim": "the AC check never runs"}]\n```\n')
    stub.state.doc(verify["id"], "verdicts",
                   '# Verdicts\n\n```json\n[{"id": "F-1", "verdict": "confirmed", '
                   '"evidence": "bash tests/ac.sh -> AC-1: FAIL"}]\n```\n')
    # point the ledger at the real ids so decide can find the findings document
    ledger = json.loads(stub.state.documents[(wo["id"], "ledger")]["body"].split("```json")[1].split("```")[0])
    ledger["stages"]["review"]["issueId"] = review["id"]
    ledger["stages"]["verify"]["issueId"] = verify["id"]
    stub.state.documents[(wo["id"], "ledger")]["body"] = "# Factory ledger\n\n```json\n%s\n```\n" % json.dumps(ledger)

    code, out, raw = run(stub, ["decide", verify["identifier"], "--apply"])
    children = [i for i in stub.state.issues.values() if i.get("parentId") == wo["id"]]
    round2 = [c for c in children if " r2]" in c["title"]]
    check("decide verify: a confirmed blocking finding opens round 2",
          code == 0 and out.get("decision") == "approve" and len(round2) == 3, raw[-600:])
    check("decide verify: round 2 is green → review → verify, chained",
          [c["title"].split("]")[0] + "]" for c in round2] == ["[green r2]", "[review r2]", "[verify r2]"]
          and round2[1]["blockedByIssueIds"] == [round2[0]["id"]], [c["title"] for c in round2])
    check("decide verify: the confirmed finding is pasted into the fix issue",
          "F-1" in round2[0]["description"], round2[0]["description"][:200])


def case_third_failure_escalates(stub, base_sha, repo):
    wo = base_work_order(stub, base_sha, repo)
    stage = stage_issue(stub, wo, "[red] GUL-900 — Add the fixture")
    with open(os.path.join(repo, "README.md"), "w") as fh:
        fh.write("still not a test\n")
    codes = []
    for _ in range(3):
        code, out, raw = run(stub, ["decide", stage["identifier"], "--apply"])
        codes.append((code, (out or {}).get("decision")))
    check("escalate: the third request-changes escalates the work order",
          codes[0][1] == "request_changes" and codes[2][1] == "escalate"
          and stub.state.issues[wo["id"]]["status"] == "blocked", codes)
    check("escalate: the work order PATCH clears executionPolicy",
          stub.state.issues[wo["id"]]["executionPolicy"] is None)
    body = stub.state.documents[(wo["id"], "ledger")]["body"]
    check("escalate: the ledger records it", '"outcome": "escalate"' in body or '"escalated"' in body)


def case_tick(stub, base_sha, repo):
    wo = base_work_order(stub, base_sha, repo)
    stage = stage_issue(stub, wo, "[red] GUL-900 — Add the fixture")
    agent_id = "agent-tester-1"
    stub.state.agents[agent_id] = {
        "id": agent_id, "name": "Tester",
        "adapterConfig": {"model": "test-model",
                          "extraArgs": ["--factory-role", "builder"]},  # wrong on purpose
    }
    config_path = os.path.join(WORKDIR, "agents.json")
    with open(os.path.join(HERE, "..", "agents.json")) as fh:
        config = json.load(fh)
    config["stages"]["red"]["agentId"] = agent_id
    with open(config_path, "w") as fh:
        json.dump(config, fh)
    os.environ["FACTORY_AGENTS_FILE_FOR_TEST"] = config_path
    stub.state.issues[stage["id"]]["assigneeAgentId"] = agent_id
    ledger = json.loads(stub.state.documents[(wo["id"], "ledger")]["body"].split("```json")[1].split("```")[0])
    ledger["stages"] = {"red": {"issueId": stage["id"], "identifier": stage["identifier"],
                                "round": 1, "attempts": 0, "sha": None}}
    stub.state.documents[(wo["id"], "ledger")]["body"] = "# Factory ledger\n\n```json\n%s\n```\n" % json.dumps(ledger)
    stub.state.runs[stage["id"]] = []

    code, out, raw = run(stub, ["tick"], extra_env={"FACTORY_AGENTS_FILE": config_path})
    drift = {d.get("agent"): d for d in (out or {}).get("configDrift", [])}
    check("tick: exits 0 and prints one line per open work order",
          code == 0 and any(line.startswith("GUL-900") for line in out.get("reasons", [])), raw[-400:])
    check("tick: flags a wrong --factory-role",
          drift.get("Tester", {}).get("role") is False and drift["Tester"]["expectedRole"] == "tester", drift)
    check("tick: flags the missing guard extension",
          drift.get("Tester", {}).get("extension") is False, drift)
    check("tick: an entry without a factoryRole is 'guard: not required', not drift",
          (drift.get("Majster") or {}).get("guard") == "not required"
          and "role" not in (drift.get("Majster") or {}), drift)
    ledger_path = os.path.join(WORKDIR, "ledger.jsonl")
    rows = [json.loads(l) for l in open(ledger_path).read().splitlines() if l.strip()] if os.path.exists(ledger_path) else []
    check("tick: appends a ledger.jsonl row with the contract fields",
          bool(rows) and all(k in rows[-1] for k in
                             ("time", "workOrder", "stage", "agent", "model", "outcome", "round", "durationSec")),
          rows[-1] if rows else None)
    check("tick: the API key never reaches stdout", "test-key-not-a-secret" not in raw)


def case_write_document_carries_revision(stub):
    """GUL-496: a document write names the revision it replaces, first write null."""
    issue = stub.state.add_issue(identifier="GUL-996", title="probe")
    api = pc.Api(key="test-key-not-a-secret", run_id="test-run-id", base=stub.url)
    slot = (issue["id"], "ledger")
    first = api.write_document(issue["id"], "ledger", "# one\n", title="Ledger")
    rev1 = stub.state.documents[slot]["latestRevisionId"]
    check("write_document: a first write is accepted with a null baseRevisionId",
          isinstance(first, dict) and stub.state.documents[slot]["body"] == "# one\n", first)
    api.write_document(issue["id"], "ledger", "# two\n", title="Ledger")
    rev2 = stub.state.documents[slot]["latestRevisionId"]
    check("write_document: the second write replaces the revision it read",
          rev1 != rev2 and stub.state.documents[slot]["body"] == "# two\n", rev2)
    stub.state.put_conflicts[slot] = 1
    api.write_document(issue["id"], "ledger", "# three\n", title="Ledger")
    check("write_document: a 409 re-reads the revision and retries once",
          stub.state.documents[slot]["body"] == "# three\n",
          stub.state.documents[slot]["body"])
    stub.state.wrapped_documents = False
    try:
        bare = api.write_document(issue["id"], "ledger", "# four\n", title="Ledger")
    finally:
        stub.state.wrapped_documents = True
    check("write_document: the live bare-document echo is normalised to {'document': …}",
          isinstance(bare, dict) and isinstance(bare.get("document"), dict)
          and bool(bare["document"].get("id")), bare)
    import factory  # noqa: E402  the script's own save_ledger, imported for the echo check
    stub.state.wrapped_documents = False
    try:
        factory.save_ledger(api, issue["id"], {"version": 1, "workOrder": "GUL-996"}, "probe")
        accepted, detail = True, ""
    except Exception as exc:  # SetupError from a missing echo, or an ApiError
        accepted, detail = False, repr(exc)
    finally:
        stub.state.wrapped_documents = True
    check("save_ledger: a ledger write against the live echo shape does not raise",
          accepted, detail)
    check("edge fallback: a JSON 403 from Paperclip is not mistaken for the edge",
          not pc.Api._wall(403, '{"error":"forbidden"}')
          and pc.Api._wall(403, Blocked.PAGE) and pc.Api._wall(0, ""))


def case_edge_block_falls_back(stub):
    """GUL-496: an inherited public URL that Cloudflare blocks does not kill the run."""
    edge = Blocked()
    os.environ[pc.FALLBACK_ENV] = stub.url
    try:
        issue = stub.state.add_issue(identifier="GUL-997", title="probe")
        api = pc.Api(key="test-key-not-a-secret", run_id="test-run-id", base=edge.url)
        got = api.issue(issue["id"])
        check("edge fallback: a Cloudflare 1010 falls back to the local API",
              isinstance(got, dict) and got.get("id") == issue["id"], got)
        check("edge fallback: the working base is remembered for the rest of the run",
              api.base == stub.url, api.base)
    finally:
        os.environ.pop(pc.FALLBACK_ENV, None)
        edge.close()


def case_commit_is_idempotent(stub):
    """GUL-497: re-running commit on a stage whose commit is already HEAD returns that sha."""
    repo, _base = make_repo("idem-repo")
    code, out, raw = run(stub, ["commit", "--repo", repo, "--stage", "red", "--issue", "GUL-995"],
                         with_key=False)
    check("commit: a clean tree still refuses with 'nothing to commit'",
          code == 1 and (out or {}).get("reasons") == ["nothing to commit"], raw[-300:])

    with open(os.path.join(repo, "tests", "ac.sh"), "w") as fh:
        fh.write('#!/usr/bin/env bash\necho "AC-1: PASS"\nexit 0\n# red\n')
    code, first, raw = run(stub, ["commit", "--repo", repo, "--stage", "red", "--issue", "GUL-995"],
                           with_key=False)
    sha1 = (first or {}).get("sha")
    check("commit: the first run commits and returns a sha",
          code == 0 and bool(sha1) and sha1 == git_out(repo, "rev-parse", "HEAD"), raw[-300:])

    code, again, raw = run(stub, ["commit", "--repo", repo, "--stage", "red", "--issue", "GUL-995"],
                           with_key=False)
    check("commit: a second run on the same stage returns HEAD instead of refusing",
          code == 0 and (again or {}).get("sha") == sha1
          and git_out(repo, "rev-list", "--count", "HEAD") == "2", raw[-300:])

    code, other, raw = run(stub, ["commit", "--repo", repo, "--stage", "green", "--issue", "GUL-995"],
                           with_key=False)
    check("commit: another stage on the same clean tree still refuses",
          code == 1 and "nothing to commit" in ((other or {}).get("reasons") or [""]), raw[-300:])


def case_ledger_write_precedes_done(stub):
    """GUL-497 part 2: a failed ledger write leaves the stage in_progress, not done."""
    repo, base = make_repo("order-repo")
    wo = base_work_order(stub, base, repo, identifier="GUL-905")
    stage = stage_issue(stub, wo, "[red] GUL-905 — Add the fixture")
    with open(os.path.join(repo, "tests", "ac.sh"), "w") as fh:
        fh.write('#!/usr/bin/env bash\necho "AC-1: FAIL not implemented yet"\nexit 1\n')
    slot = (wo["id"], "ledger")
    before = stub.state.documents[slot]["body"]
    stub.state.put_failures[slot] = 1

    code, out, raw = run(stub, ["decide", stage["identifier"], "--apply"])
    check("decide red: a failed ledger write is a setup error, exit 2",
          code == 2 and "ledger write failed" in raw, raw[-400:])
    check("decide red: a failed ledger write leaves the stage in_progress",
          stub.state.issues[stage["id"]]["status"] == "in_progress",
          stub.state.issues[stage["id"]]["status"])
    check("decide red: a failed ledger write leaves the ledger byte-identical",
          stub.state.documents[slot]["body"] == before)
    check("decide red: the stage is not patched done and gets no done comment",
          not [c for c in stub.state.comments if c["issueId"] == stage["id"]],
          [c["body"][:80] for c in stub.state.comments if c["issueId"] == stage["id"]])
    check("decide red: the stage's commit was made before the write",
          git_out(repo, "log", "-1", "--format=%s") == "factory(GUL-905): red",
          git_out(repo, "log", "-1", "--format=%s"))

    # the whole point: the same decide can be re-run and finishes the job
    code2, out2, raw2 = run(stub, ["decide", stage["identifier"], "--apply"])
    body = stub.state.documents[slot]["body"]
    check("decide red: the re-run records the sha the failed attempt committed",
          code2 == 0 and stub.state.issues[stage["id"]]["status"] == "done"
          and git_out(repo, "rev-parse", "HEAD") in body
          and '"outcome": "pass"' in body, raw2[-400:])
    check("decide red: the re-run adds no second commit",
          git_out(repo, "rev-list", "--count", "HEAD") == "2",
          git_out(repo, "rev-list", "--count", "HEAD"))


def case_green_approve_opens_one_pr(stub):
    """GUL-497: the green pass — commit → open-pr → ledger → done, and one PR re-used on a re-run."""
    repo, origin, base, red_sha, branch = make_green_repo()
    wo = base_work_order(stub, base, repo, identifier="GUL-907")
    stub.state.doc(wo["id"], "spec", GREEN_SPEC_BODY)
    ledger = json.loads(stub.state.documents[(wo["id"], "ledger")]["body"]
                        .split("```json")[1].split("```")[0])
    ledger["stages"] = {"red": {"issueId": "red-1", "identifier": "GUL-906", "round": 1,
                                "attempts": 0, "sha": red_sha}}
    stub.state.documents[(wo["id"], "ledger")]["body"] = (
        "# Factory ledger\n\n```json\n%s\n```\n" % json.dumps(ledger))
    stage = stage_issue(stub, wo, "[green] GUL-907 — Add the fix")
    gh_log = os.path.join(WORKDIR, "gh-calls.log")
    env = {"FACTORY_GH": write_gh_stub(os.path.join(WORKDIR, "gh-stub.sh")),
           "GH_CALL_LOG": gh_log}

    code, out, raw = run(stub, ["decide", stage["identifier"], "--apply"], extra_env=env)
    calls = [l for l in open(gh_log).read().splitlines() if l.strip()] if os.path.exists(gh_log) else []
    body = stub.state.documents[(wo["id"], "ledger")]["body"]
    products = [p for p in stub.state.work_products if p.get("issueId") == wo["id"]]
    check("decide green: the pass commits, opens a PR and marks the stage done",
          code == 0 and out.get("decision") == "approve"
          and stub.state.issues[stage["id"]]["status"] == "done", raw[-700:])
    check("decide green: the commit is the stage's own and the branch is pushed",
          git_out(repo, "log", "-1", "--format=%s") == "factory(GUL-907): green"
          and git_out(origin, "rev-parse", "refs/heads/" + branch) == git_out(repo, "rev-parse", "HEAD"),
          "%s / %s" % (git_out(repo, "log", "-1", "--format=%s"),
                       git_out(origin, "rev-parse", "refs/heads/" + branch)))
    check("decide green: open-pr called gh once", len(calls) == 1, calls)
    check("decide green: the ledger records the PR it opened",
          '"number": 80' in body and '"outcome": "pass"' in body, body[-300:])
    check("decide green: the PR is linked as a work product",
          len(products) == 1 and "pull/80" in (products[0].get("url") or "")
          and products[0].get("externalId") == "80", products)

    code2, out2, raw2 = run(stub, ["decide", stage["identifier"], "--apply"], extra_env=env)
    calls2 = [l for l in open(gh_log).read().splitlines() if l.strip()]
    products2 = [p for p in stub.state.work_products if p.get("issueId") == wo["id"]]
    check("decide green: a re-run reuses the recorded PR instead of opening a second",
          code2 == 0 and len(calls2) == 1 and len(products2) == 1, calls2)
    check("decide green: the re-run leaves the stage done and the ledger intact",
          stub.state.issues[stage["id"]]["status"] == "done"
          and '"number": 80' in stub.state.documents[(wo["id"], "ledger")]["body"], raw2[-400:])
    # the tick cases sweep every open work order, and this fixture's ledger
    # names a stage issue the stub never created (red-1): close it here.
    stub.state.issues[wo["id"]]["status"] = "done"


GREEN_SPEC_BODY = """# Spec

```json
{"repo": "gulasz101/homelab-2nd", "base": "main", "kind": "code",
 "allowedPaths": ["src/**"],
 "acs": [{"id": "AC-1", "text": "a.py carries the fix the red stage's check asks for",
          "check": "bash tests/ac.sh"}],
 "maxDiffLines": 100}
```
"""


def write_gh_stub(path):
    """A gh that answers `pr create` and logs every call. Enough for open-pr."""
    with open(path, "w") as fh:
        fh.write("#!/usr/bin/env bash\n"
                 'printf "%s|%s\\n" "$1" "$2" >> "$GH_CALL_LOG"\n'
                 'case "$1" in\n'
                 '  pr)\n'
                 '    [ "$2" = "create" ] || { echo "stub gh: pr $2 not stubbed" >&2; exit 1; }\n'
                 '    echo "https://github.com/gulasz101/homelab-2nd/pull/80"\n'
                 '    ;;\n'
                 '  *) echo "stub gh: not stubbed: $*" >&2; exit 1 ;;\n'
                 "esac\n")
    os.chmod(path, 0o755)
    return path


def make_green_repo(name="green-repo"):
    """A work-order branch holding the red commit, with the green fix in the tree.

    origin is a bare repo rather than the checkout itself: `open-pr` pushes the
    branch, and git refuses to update a branch that origin has checked out.
    """
    root = os.path.join(WORKDIR, name)
    origin = os.path.join(root, "origin.git")
    repo = os.path.join(root, "repo")
    for sub in ("tests", "src"):
        os.makedirs(os.path.join(repo, sub), exist_ok=True)
    subprocess.run(["git", "init", "--bare", "-q", origin], check=True)
    with open(os.path.join(repo, "tests", "ac.sh"), "w") as fh:
        fh.write("#!/usr/bin/env bash\n"
                 'if grep -q fixed src/a.py; then echo "AC-1: PASS"; exit 0; fi\n'
                 'echo "AC-1: FAIL a.py does not carry the fix"; exit 1\n')
    with open(os.path.join(repo, "src", "a.py"), "w") as fh:
        fh.write("value = 'TODO'\n")
    with open(os.path.join(repo, "README.md"), "w") as fh:
        fh.write("fixture\n")
    git(repo, "init", "-q", "-b", "main")
    git(repo, "add", "-A")
    git(repo, "-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-qm", "base")
    git(repo, "remote", "add", "origin", origin)
    git(repo, "push", "-q", "origin", "main")
    base_sha = git_out(repo, "rev-parse", "HEAD")

    branch = "gul-907-add-the-fix"
    git(repo, "switch", "-q", "-c", branch)
    with open(os.path.join(repo, "tests", "ac.sh"), "a") as fh:
        fh.write("# red: the check is written, the fix is not there\n")
    git(repo, "add", "-A")
    git(repo, "-c", "user.email=t@example.com", "-c", "user.name=T",
        "commit", "-qm", "factory(GUL-907): red")
    red_sha = git_out(repo, "rev-parse", "HEAD")
    # the green stage's work as a builder leaves it: in the tree, not committed
    with open(os.path.join(repo, "src", "a.py"), "w") as fh:
        fh.write("value = 'fixed'\n")
    return repo, origin, base_sha, red_sha, branch


# --------------------------------------------------------------------------
# GUL-553: the gate raises no card; the tick notices the GitHub merge
# --------------------------------------------------------------------------

GATE_VIEW = {"headRefOid": "aaaa", "baseRefOid": "bbbb", "additions": 3, "deletions": 1,
             "files": [{"path": "src/a.py", "changeType": "MODIFIED"}]}


def write_merge_gh_stub(path):
    """A gh that serves `pr view` from $GH_VIEW_FILE and a green `pr checks`."""
    with open(path, "w") as fh:
        fh.write("#!/usr/bin/env bash\n"
                 'printf "%s|%s\\n" "$1" "$2" >> "$GH_CALL_LOG"\n'
                 'case "$1 $2" in\n'
                 '  "pr view")   cat "$GH_VIEW_FILE" ;;\n'
                 '  "pr checks") cat "$GH_CHECKS_FILE" ;;\n'
                 '  *) echo "stub gh: not stubbed: $*" >&2; exit 1 ;;\n'
                 "esac\n")
    os.chmod(path, 0o755)
    return path


def merge_env(tag, view):
    """Env for one decide/tick run: a stub gh answering `pr view` with `view`."""
    view_path = os.path.join(WORKDIR, "view-%s.json" % tag)
    checks_path = os.path.join(WORKDIR, "checks-%s.json" % tag)
    with open(view_path, "w") as fh:
        json.dump(view, fh)
    with open(checks_path, "w") as fh:
        json.dump([{"name": "check", "state": "SUCCESS"}], fh)
    return {"FACTORY_GH": write_merge_gh_stub(os.path.join(WORKDIR, "gh-merge.sh")),
            "GH_VIEW_FILE": view_path, "GH_CHECKS_FILE": checks_path,
            "GH_CALL_LOG": os.path.join(WORKDIR, "gh-merge-calls.log")}


def ledger_of(stub, wo):
    return json.loads(stub.state.documents[(wo["id"], "ledger")]["body"]
                      .split("```json")[1].split("```")[0])


def write_ledger(stub, wo, ledger):
    stub.state.documents[(wo["id"], "ledger")]["body"] = (
        "# Factory ledger\n\n```json\n%s\n```\n" % json.dumps(ledger))


def gate_work_order(stub, repo, identifier, pr_number):
    """A work order that already passed the gate: PR recorded, gate stage done."""
    wo = base_work_order(stub, "base-sha", repo, identifier=identifier)
    ledger = ledger_of(stub, wo)
    ledger["pr"] = {"number": pr_number,
                    "url": "https://github.com/gulasz101/homelab-2nd/pull/%d" % pr_number}
    gate = stage_issue(stub, wo, "[gate] %s - Merge" % identifier, status="done")
    ledger["stages"] = {"gate": {"issueId": gate["id"], "identifier": gate["identifier"],
                                 "round": 1, "attempts": 0, "sha": None}}
    write_ledger(stub, wo, ledger)
    stub.state.issues[wo["id"]]["status"] = "in_review"
    return wo, gate


def comments_on(stub, issue_id):
    return [c["body"] for c in stub.state.comments if c["issueId"] == issue_id]


def case_gate_leaves_no_card(stub):
    """GUL-553: the gate pass raises no card; the work order waits on a monitor."""
    repo, base = make_repo("gate-repo")
    wo = base_work_order(stub, base, repo, identifier="GUL-910")
    ledger = ledger_of(stub, wo)
    ledger["pr"] = {"number": 91,
                    "url": "https://github.com/gulasz101/homelab-2nd/pull/91"}
    write_ledger(stub, wo, ledger)
    gate = stage_issue(stub, wo, "[gate] GUL-910 - Merge")

    code, out, raw = run(stub, ["decide", gate["identifier"], "--apply"],
                         extra_env=merge_env("gate", GATE_VIEW))
    cards = [c for c in stub.state.interactions if c.get("issueId") == wo["id"]]
    issue = stub.state.issues[wo["id"]]
    monitor = (issue.get("executionPolicy") or {}).get("monitor") or {}
    said = comments_on(stub, wo["id"])

    check("gate decide: the pass still marks the gate stage done",
          code == 0 and stub.state.issues[gate["id"]]["status"] == "done", raw[-500:])
    check("gate decide: no 'Merge PR' card is raised", not cards,
          [c.get("title") for c in cards])
    check("gate decide: the work order waits in_review on an external_service monitor",
          issue["status"] == "in_review" and monitor.get("kind") == "external_service"
          and bool(monitor.get("nextCheckAt")), monitor)
    check("gate decide: the comment says merge on GitHub and that there is no card",
          any("Merge PR #91 on GitHub" in c and "no card to accept" in c for c in said), said[-1:])


def case_tick_notices_the_merge(stub):
    """GUL-553: a merge on GitHub moves the work order on with nobody clicking."""
    repo, _base = make_repo("merge-repo")
    wo, _gate = gate_work_order(stub, repo, "GUL-911", 92)
    leftover = {"id": "card-left", "issueId": wo["id"], "kind": "request_confirmation",
                "title": "Merge PR #92?", "status": "pending",
                "payload": {"version": 1, "prompt": "Merge PR #92?"}}
    stub.state.interactions.append(leftover)

    code, out, raw = run(stub, ["tick", "--apply"], extra_env=merge_env(
        "merged", {"state": "MERGED", "mergedAt": "2026-10-28T17:13:00Z",
                   "mergeCommit": {"oid": "c0ffee123"}}))
    issue = stub.state.issues[wo["id"]]
    ledger = ledger_of(stub, wo)
    said = comments_on(stub, wo["id"])

    check("tick merged: the work order is done without anyone touching a card",
          code == 0 and issue["status"] == "done", raw[-500:])
    check("tick merged: the comment carries the merge commit",
          any("c0ffee123" in c for c in said), said[-1:])
    check("tick merged: the ledger records the merge",
          (ledger.get("merge") or {}).get("state") == "merged" and ledger.get("outcome") == "merged",
          ledger.get("merge"))
    check("tick merged: a leftover merge card is withdrawn", leftover["status"] == "withdrawn",
          leftover.get("status"))
    check("tick merged: the monitor is cleared", issue.get("executionPolicy") is None,
          issue.get("executionPolicy"))


def case_tick_waits_on_an_open_pr(stub):
    """GUL-553: an open PR changes nothing but keeps the wait a real path."""
    repo, _base = make_repo("open-repo")
    wo, _gate = gate_work_order(stub, repo, "GUL-912", 93)
    env = merge_env("open", {"state": "OPEN", "mergedAt": None, "mergeCommit": None})
    before = len(comments_on(stub, wo["id"]))

    code, out, raw = run(stub, ["tick"], extra_env=env)
    issue = stub.state.issues[wo["id"]]
    check("tick dry: an open PR writes nothing",
          code == 0 and issue["status"] == "in_review"
          and len(comments_on(stub, wo["id"])) == before
          and issue.get("executionPolicy") is None, raw[-400:])
    check("tick dry: the sweep line flags the open PR",
          any("pr-open" in line for line in (out or {}).get("reasons", [])),
          (out or {}).get("reasons"))

    code2, out2, raw2 = run(stub, ["tick", "--apply"], extra_env=env)
    monitor = (stub.state.issues[wo["id"]].get("executionPolicy") or {}).get("monitor") or {}
    check("tick open: --apply re-arms the monitor and leaves the work order waiting",
          code2 == 0 and stub.state.issues[wo["id"]]["status"] == "in_review"
          and monitor.get("kind") == "external_service" and bool(monitor.get("nextCheckAt")),
          monitor)
    check("tick open: no comment and no status change",
          len(comments_on(stub, wo["id"])) == before, comments_on(stub, wo["id"]))
    # keep the later cases clean: an open work order would be re-read by them
    stub.state.issues[wo["id"]]["status"] = "done"


def case_tick_blocks_a_closed_pr(stub):
    """GUL-553: a PR closed without a merge is one plain sentence, not a mystery."""
    repo, _base = make_repo("closed-repo")
    wo, _gate = gate_work_order(stub, repo, "GUL-913", 94)

    code, out, raw = run(stub, ["tick", "--apply"], extra_env=merge_env(
        "closed", {"state": "CLOSED", "mergedAt": None, "mergeCommit": None}))
    issue = stub.state.issues[wo["id"]]
    said = [c for c in comments_on(stub, wo["id"]) if "closed without a merge" in c]
    ledger = ledger_of(stub, wo)

    check("tick closed: the work order is blocked",
          code == 0 and issue["status"] == "blocked", raw[-500:])
    check("tick closed: one sentence says nothing shipped", len(said) == 1, said)
    check("tick closed: the ledger records the close",
          (ledger.get("merge") or {}).get("state") == "closed", ledger.get("merge"))


def main():
    global WORKDIR
    WORKDIR = tempfile.mkdtemp(prefix="factory-pc-tests-")
    try:
        repo, base_sha = make_repo()
        stub = Stub()
        try:
            case_start_cuts_branch(stub)
            case_start_refuses_tooling_checkout(stub)
            case_start_creates_chain(stub, base_sha, repo)
            case_stop_blocks(stub, base_sha, repo)
            case_missing_key(stub)
            case_decide_red(stub, base_sha, repo)
            case_verify_fix_round(stub, base_sha, repo)
            case_third_failure_escalates(stub, base_sha, repo)
            case_tick(stub, base_sha, repo)
            case_write_document_carries_revision(stub)
            case_edge_block_falls_back(stub)
            case_commit_is_idempotent(stub)
            case_ledger_write_precedes_done(stub)
            case_green_approve_opens_one_pr(stub)
            case_gate_leaves_no_card(stub)
            case_tick_notices_the_merge(stub)
            case_tick_waits_on_an_open_pr(stub)
            case_tick_blocks_a_closed_pr(stub)
        finally:
            stub.close()
    finally:
        shutil.rmtree(WORKDIR, ignore_errors=True)
    print("\n%s passed, %s failed" % (len(PASSES), len(FAILURES)))
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
