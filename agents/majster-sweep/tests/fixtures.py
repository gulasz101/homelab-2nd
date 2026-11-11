#!/usr/bin/env python3
"""Fixture builder for the majster-sweep checks (GUL-1238 red stage).

Usage:  python3 fixtures.py <case> <dir>

Writes the fixture tree that `sweep.py --fixtures DIR` reads:

    <dir>/issues.json               the issue list, a bare JSON array
    <dir>/issues/<id>.json          per-issue GET; a missing file means 404
    <dir>/comments/<id>.json        GET /issues/<id>/comments, bare array
    <dir>/interactions/<id>.json    GET /issues/<id>/interactions, bare array
    <dir>/agents.json               GET /companies/<co>/agents, bare array
    <dir>/ps.txt                    `ps -axo pid=,ppid=,etime=,comm=` output

Every timestamp is derived from NOW, so the age rules never depend on the
wall clock.  One case per acceptance criterion, plus the seven per-kind
cases AC-2 walks through.
"""

import json
import os
import sys
from datetime import datetime, timedelta

NOW = "2026-11-09T18:00:00Z"
_NOW = datetime.strptime(NOW, "%Y-%m-%dT%H:%M:%SZ")

# Real ids from the spec / the board, so the rules match production data.
PROJECT = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
MORNING_BREW = "149ae0a6-88d4-4b49-bb6d-7f605182922f"
GUL217 = "0b22bbd4-9766-422b-87a4-f2a8e4935976"
MAJSTER = "2df240b5-a5ea-4ebf-81ff-bf96758e8f80"

AGENT = "11111111-1111-4111-8111-111111111111"    # healthy worker
OTHER = "22222222-2222-4222-8222-222222222222"    # the agent a fleet rule fires on
PARKED = "33333333-3333-4333-8333-333333333333"   # never reported
PARKED2 = "44444444-4444-4444-8444-444444444444"
PARKED3 = "55555555-5555-4555-8555-555555555555"


def ago(minutes):
    return (_NOW - timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")


def iid(n):
    return "a0000000-0000-4000-8000-%012d" % n


def row(n, ident, status, title="Board item", project=PROJECT, agent=AGENT,
        created=600, updated=5, started=0, blocker=None, blocked_by=()):
    """A per-issue GET row.  `started` is minutes-ago, 0 means null (not started)."""
    return {
        "id": iid(n),
        "identifier": ident,
        "title": title,
        "status": status,
        "projectId": project,
        "assigneeAgentId": agent,
        "createdAt": ago(created),
        "updatedAt": ago(updated),
        "startedAt": ago(started) if started else None,
        "executionBlocker": blocker,
        "blockedBy": list(blocked_by),
    }


def agent(aid, name, status, hb=5, reason=None):
    return {"id": aid, "name": name, "status": status,
            "lastHeartbeatAt": ago(hb), "errorReason": reason}


def comment(cid, body, author="agent", run=None, minutes=60):
    return {"id": cid, "body": body, "authorType": author,
            "createdByRunId": run, "createdAt": ago(minutes)}


def interaction(xid, status="pending", kind="request_confirmation", minutes=900):
    return {"id": xid, "kind": kind, "status": status, "createdAt": ago(minutes)}


class Case(object):
    def __init__(self):
        self.entries = []          # (list_row, get_override, missing_get)
        self.agents = [agent(AGENT, "Builder", "idle")]
        self.comments = {}
        self.interactions = {}
        self.ps = ""

    def add(self, issue_row, get=None, missing=False):
        self.entries.append((issue_row, get, missing))
        return issue_row["id"]

    def say(self, issue_id, comments=None, interactions=None):
        if comments is not None:
            self.comments[issue_id] = comments
        if interactions is not None:
            self.interactions[issue_id] = interactions


def blocked_by(n, status):
    return {"id": iid(n), "identifier": "GUL-9%02d" % n, "status": status}


# ---------------------------------------------------------------- the cases

def quiet():
    """AC-1: three open issues that trip no rule, a healthy fleet, no STOP."""
    c = Case()
    c.add(row(1, "GUL-101", "in_progress", updated=10, started=120))
    c.add(row(2, "GUL-102", "todo", agent=None, updated=180))
    issue_id = c.add(row(3, "GUL-103", "in_review", updated=20, started=200))
    c.say(issue_id, interactions=[interaction("x-103", status="answered", minutes=1200)])
    return c


def hold():
    c = Case()
    c.add(row(11, "GUL-201", "in_progress", updated=10, started=300,
              blocker={"kind": "hold", "reason": "waiting on the OMV maintenance window"}))
    c.add(row(12, "GUL-212", "in_progress", updated=10, started=300))
    return c


def stalled():
    c = Case()
    c.add(row(13, "GUL-202", "in_progress", updated=120, started=400))
    c.add(row(14, "GUL-214", "in_progress", updated=10, started=400))
    return c


def blocker_cleared():
    c = Case()
    c.add(row(15, "GUL-203", "blocked", updated=30, started=600,
              blocked_by=[blocked_by(90, "done"), blocked_by(91, "cancelled")]))
    return c


def orphan_blocked():
    c = Case()
    c.add(row(16, "GUL-204", "blocked", updated=30, started=600))
    return c


def never_started():
    c = Case()
    c.add(row(17, "GUL-205", "todo", updated=180, started=0))
    return c


def agent_error():
    c = Case()
    c.agents = [agent(AGENT, "Builder", "idle"),
                agent(OTHER, "Florian", "error", hb=2880, reason="Process lost -- server may have restarted"),
                agent(MAJSTER, "Majster", "error", hb=5, reason="never reported: Majster is the watchdog")]
    c.add(row(18, "GUL-206", "todo", agent=OTHER, updated=10))
    return c


def long_child():
    c = Case()
    c.add(row(19, "GUL-207", "in_progress", updated=10, started=200))
    c.ps = ("  4242     1 07:30 /usr/bin/find\n"
            "  4243     1 00:45 /usr/bin/grep\n"
            "  4244     1 07:30 /bin/bash\n")
    return c


def per_issue_get():
    """AC-3: the list is not evidence, the per-issue GET is."""
    c = Case()
    # listed in_review, its own GET says done -> not reported
    c.add(row(31, "GUL-301", "in_review", updated=10, started=300),
          get={"status": "done"})
    # no per-issue file at all -> GET returns 404 -> skipped, even though the
    # list row carries an executionBlocker that would otherwise be a hold
    c.add(row(32, "GUL-302", "in_progress", updated=10, started=300,
              blocker={"kind": "hold", "reason": "listed only"}),
          missing=True)
    # listed todo, its own GET says in_progress and stale -> stalled
    c.add(row(33, "GUL-303", "todo", updated=10, started=300),
          get={"status": "in_progress", "updatedAt": ago(120)})
    return c


def skip_rules():
    """AC-4: every skip rule, each row would otherwise fire a rule."""
    c = Case()
    c.add(row(41, "GUL-401", "backlog", updated=10, started=300,
              blocker={"kind": "hold", "reason": "backlog row"}))
    c.add(row(42, "GUL-402", "cancelled", updated=10, started=300,
              blocker={"kind": "hold", "reason": "cancelled row"}))
    c.add(row(43, "GUL-403", "in_progress", created=5, updated=120, started=300))
    c.add(row(44, "GUL-404", "in_progress", project=MORNING_BREW, updated=120, started=300))
    c.add(row(45, "GUL-405", "in_progress", title="Hourly board sweep", updated=120, started=300))
    c.add(row(46, "GUL-217", "in_progress", updated=120, started=300))
    c.entries[5][0]["id"] = GUL217
    # parked agents: red or zombie, but parked on purpose -> never reported
    c.agents = [agent(AGENT, "Builder", "idle"),
                agent(PARKED, "Paused One", "paused", hb=5000, reason="parked"),
                agent(PARKED2, "Terminated One", "terminated", hb=5000, reason="parked"),
                agent(PARKED3, "Approval One", "pending_approval", hb=5000, reason="parked")]
    return c


def no_model_kinds():
    """AC-5: the three kinds that are reported but never need a model."""
    c = Case()
    issue_id = c.add(row(51, "GUL-501", "in_review", updated=20, started=900))
    c.say(issue_id, interactions=[interaction("x-501", status="pending", minutes=840)])
    c.agents = [agent(AGENT, "Builder", "idle"),
                agent(OTHER, "Zombie Runner", "running", hb=180)]
    c.add(row(52, "GUL-502", "todo", agent=OTHER, updated=10))
    issue_id = c.add(row(53, "GUL-503", "in_progress", updated=10, started=200))
    c.say(issue_id, comments=[comment("c-503", "ship it", author="user", run="run-abc123", minutes=360)])
    # decoys: a human comment with no run, and an agent comment with a run
    issue_id = c.add(row(54, "GUL-504", "in_progress", updated=10, started=200))
    c.say(issue_id, comments=[comment("c-504", "looks fine", author="user", run=None, minutes=300)])
    issue_id = c.add(row(55, "GUL-505", "in_progress", updated=10, started=200))
    c.say(issue_id, comments=[comment("c-505", "builder here", author="agent", run="run-def456", minutes=300)])
    return c


def size_cap():
    """AC-7: 300 open issues, 40 flagged, the no-model ones listed first."""
    c = Case()
    n = 100
    for i in range(10):                      # listed first, never needs a model
        n += 1
        issue_id = c.add(row(n, "GUL-%03d" % (700 + i), "in_review", updated=10, started=900))
        c.say(issue_id, interactions=[interaction("x-%d" % n, status="pending", minutes=840)])
    for i in range(30):                      # needs a model, listed after them
        n += 1
        c.add(row(n, "GUL-%03d" % (800 + i), "in_progress", updated=10, started=300,
                  blocker={"kind": "hold", "reason": "waiting on somebody"}))
    for i in range(260):                     # quiet filler
        n += 1
        c.add(row(n, "GUL-%03d" % (100 + i), "in_progress", updated=10, started=200))
    return c


CASES = {
    "quiet": quiet,
    "hold": hold,
    "stalled": stalled,
    "blocker_cleared": blocker_cleared,
    "orphan_blocked": orphan_blocked,
    "never_started": never_started,
    "agent_error": agent_error,
    "long_child": long_child,
    "per-issue-get": per_issue_get,
    "skip-rules": skip_rules,
    "no-model-kinds": no_model_kinds,
    "size-cap": size_cap,
}


# ------------------------------------------------------------------ writing

def dump(path, obj):
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "w") as fh:
        json.dump(obj, fh, indent=1, sort_keys=True)
        fh.write("\n")


def write_case(case, out):
    os.makedirs(out, exist_ok=True)
    dump(os.path.join(out, "issues.json"), [r for r, _, _ in case.entries])
    for list_row, get, missing in case.entries:
        if missing:
            continue
        detail = dict(list_row)
        detail.update(get or {})
        dump(os.path.join(out, "issues", list_row["id"] + ".json"), detail)
    for issue_id, items in case.comments.items():
        dump(os.path.join(out, "comments", issue_id + ".json"), items)
    for issue_id, items in case.interactions.items():
        dump(os.path.join(out, "interactions", issue_id + ".json"), items)
    dump(os.path.join(out, "agents.json"), case.agents)
    with open(os.path.join(out, "ps.txt"), "w") as fh:
        fh.write(case.ps)


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: fixtures.py <case> <dir>\n")
        return 2
    name, out = argv[1], argv[2]
    factory = CASES.get(name)
    if factory is None:
        sys.stderr.write("unknown case %r (known: %s)\n" % (name, ", ".join(sorted(CASES))))
        return 2
    write_case(factory(), out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
