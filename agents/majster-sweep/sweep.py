#!/usr/bin/env python3
"""majster-sweep: Majster's hourly board walk, without a model.

Reads the Paperclip board with GET requests (or from a fixture tree), applies
the stuck rules Majster used to reason about, and prints one short JSON
report.  A launchd wrapper starts a Majster run only when "actionable" is
true, so the reading that used to cost 0.83 M input tokens per run costs
nothing.

This module is read-only by design: it never writes to Paperclip, so it
carries no POST, PATCH, PUT or DELETE.  Usage:

    python3 -I agents/majster-sweep/sweep.py [--fixtures DIR] [--now ISO8601]
        [--stop-file PATH] [--tick-cmd CMD] [--ps-file PATH]

Exit codes: 0 nothing needs a model, 10 actionable, 2 setup error.
"""

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

# --------------------------------------------------------------- constants

MAJSTER_ID = "2df240b5-a5ea-4ebf-81ff-bf96758e8f80"
MORNING_BREW_PROJECT = "149ae0a6-88d4-4b49-bb6d-7f605182922f"
NEVER_REPORT_ISSUE = "0b22bbd4-9766-422b-87a4-f2a8e4935976"
SWEEP_TITLE = "Hourly board sweep"

SKIP_STATUSES = frozenset(["backlog", "cancelled", "done"])
PARKED_AGENT_STATUSES = frozenset(["paused", "terminated", "pending_approval"])

NEEDS_MODEL_KINDS = frozenset([
    "hold",
    "stalled",
    "blocker_cleared",
    "orphan_blocked",
    "never_started",
    "agent_error",
    "long_child",
])

YOUNG_ISSUE_MINUTES = 15
STALLED_MINUTES = 60
NEVER_STARTED_MINUTES = 120
WAITING_HUMAN_MINUTES = 720
ZOMBIE_MINUTES = 120
IMPERSONATION_MINUTES = 1440
LONG_CHILD_SECONDS = 300
LONG_CHILD_COMMANDS = frozenset(["find", "grep", "sleep", "watch"])

MAX_ITEMS = 15
DETAIL_CHARS = 160

DEFAULT_STOP_FILE = "~/paperclip-agents/majster/factory/STOP"
DEFAULT_TICK_CMD = "factory tick"

PS_ARGV = ["ps", "-axo", "pid=,ppid=,etime=,comm="]


class SetupError(Exception):
    """Something the script cannot work with: missing env, unreadable input."""


# ------------------------------------------------------------------- clock

def parse_time(value):
    """Parse an ISO 8601 stamp into an aware UTC datetime, or None."""
    if not value:
        return None
    text = str(value).strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        stamp = datetime.fromisoformat(text)
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return stamp.astimezone(timezone.utc)


def age_minutes(now, value):
    """Minutes between `value` and `now`; None when the stamp is unreadable."""
    stamp = parse_time(value)
    if stamp is None:
        return None
    return (now - stamp).total_seconds() / 60.0


def iso_seconds(stamp):
    return stamp.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_minutes(stamp):
    return stamp.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")


def iso_display(stamp):
    return stamp.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%MZ")


# ------------------------------------------------------------------ source

def as_list(payload):
    """A bare array or a wrapped one: take the first list we find."""
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in ("issues", "agents", "comments", "interactions", "items", "data"):
            value = payload.get(key)
            if isinstance(value, list):
                return value
        for value in payload.values():
            if isinstance(value, list):
                return value
    return []


class FixtureSource(object):
    """Reads the board from JSON files on disk; used by the checks."""

    def __init__(self, root):
        self.root = root

    def _json(self, *parts):
        path = os.path.join(self.root, *parts)
        try:
            with open(path, "r", encoding="utf-8") as handle:
                return json.load(handle)
        except FileNotFoundError:
            return None
        except (OSError, ValueError) as exc:
            raise SetupError("cannot read fixture %s: %s" % (path, exc))

    def _required(self, name, *parts):
        payload = self._json(*parts)
        if payload is None:
            raise SetupError("fixture %s is missing from %s" % (name, self.root))
        return payload

    def list_issues(self):
        return as_list(self._required("issues.json", "issues.json"))

    def get_issue(self, issue_id):
        return self._json("issues", issue_id + ".json")

    def comments(self, issue_id):
        return as_list(self._json("comments", issue_id + ".json"))

    def interactions(self, issue_id):
        return as_list(self._json("interactions", issue_id + ".json"))

    def agents(self):
        return as_list(self._required("agents.json", "agents.json"))


class ApiSource(object):
    """Reads the board over HTTP. GET only; never prints the token."""

    def __init__(self, base_url, token, company_id):
        self.base = base_url.rstrip("/")
        self.token = token
        self.company = company_id

    def _get(self, path):
        url = self.base + path
        request = urllib.request.Request(url, headers={
            "Authorization": "Bearer " + self.token,
            "Accept": "application/json",
        })
        # Errors name the endpoint, never an env value or the token.
        shown = path.replace(self.company, "<company>")
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            raise SetupError("GET %s answered %s" % (shown, exc.code))
        except (urllib.error.URLError, OSError) as exc:
            reason = getattr(exc, "reason", exc)
            raise SetupError("GET %s failed: %s" % (shown, reason))
        except ValueError as exc:
            raise SetupError("GET %s returned invalid JSON: %s" % (shown, exc))

    def list_issues(self):
        path = ("/api/companies/%s/issues"
                "?status=todo,blocked,in_progress,in_review&limit=1000" % self.company)
        payload = self._get(path)
        if payload is None:
            raise SetupError("the issue list answered 404")
        return as_list(payload)

    def get_issue(self, issue_id):
        return self._get("/api/issues/%s" % issue_id)

    def comments(self, issue_id):
        path = "/api/issues/%s/comments?order=desc&limit=30" % issue_id
        return as_list(self._get(path))

    def interactions(self, issue_id):
        return as_list(self._get("/api/issues/%s/interactions" % issue_id))

    def agents(self):
        payload = self._get("/api/companies/%s/agents" % self.company)
        if payload is None:
            raise SetupError("the agents list answered 404")
        return as_list(payload)


# ------------------------------------------------------------------- items

def one_line(text, limit=DETAIL_CHARS):
    flat = " ".join(str(text).split())
    if len(flat) > limit:
        flat = flat[:limit - 3].rstrip() + "..."
    return flat


def make_item(kind, issue=None, issue_id=None, agent_id=None, detail=""):
    return {
        "kind": kind,
        "issue": issue,
        "id": issue_id,
        "agent": agent_id,
        "detail": one_line(detail),
    }


def skip_reason(issue, now):
    """Why this open row is ignored, or None when the rules apply."""
    status = (issue.get("status") or "").strip()
    if status in SKIP_STATUSES:
        return "status " + status
    if issue.get("id") == NEVER_REPORT_ISSUE:
        return "GUL-217 is the sweep's own board"
    if issue.get("projectId") == MORNING_BREW_PROJECT:
        return "Morning Brew project"
    title = (issue.get("title") or "").strip()
    if title == SWEEP_TITLE or title.startswith(SWEEP_TITLE):
        return "the sweep's own issue"
    age = age_minutes(now, issue.get("createdAt"))
    if age is not None and age < YOUNG_ISSUE_MINUTES:
        return "younger than %d min" % YOUNG_ISSUE_MINUTES
    return None


def blocker_detail(blocker):
    if not isinstance(blocker, dict):
        return "executionBlocker is set"
    kind = blocker.get("kind") or "hold"
    reason = blocker.get("reason")
    if reason:
        return "executionBlocker %s: %s" % (kind, reason)
    return "executionBlocker %s" % kind


def issue_rules(issue, now, source):
    """Every issue-level item this row trips, from its own per-issue GET."""
    items = []
    status = (issue.get("status") or "").strip()
    identifier = issue.get("identifier") or issue.get("id")
    issue_id = issue.get("id")
    agent_id = issue.get("assigneeAgentId")

    blocker = issue.get("executionBlocker")
    if blocker:
        items.append(make_item("hold", identifier, issue_id, agent_id,
                               blocker_detail(blocker)))

    updated_age = age_minutes(now, issue.get("updatedAt"))
    if status == "in_progress" and updated_age is not None and updated_age > STALLED_MINUTES:
        items.append(make_item("stalled", identifier, issue_id, agent_id,
                               "in_progress, no update for %d min" % round(updated_age)))

    blocked_by = issue.get("blockedBy") or []
    if status == "blocked":
        if blocked_by:
            states = [(entry.get("status") or "") for entry in blocked_by
                      if isinstance(entry, dict)]
            if states and all(state in ("done", "cancelled") for state in states):
                items.append(make_item(
                    "blocker_cleared", identifier, issue_id, agent_id,
                    "blocked by %d issue(s), all done or cancelled" % len(states)))
        else:
            comments = source.comments(issue_id)
            if not comments:
                items.append(make_item("orphan_blocked", identifier, issue_id, agent_id,
                                       "blocked with no blocker and no comments"))

    if status == "todo" and agent_id:
        started = issue.get("startedAt")
        if (not started and updated_age is not None
                and updated_age > NEVER_STARTED_MINUTES):
            items.append(make_item(
                "never_started", identifier, issue_id, agent_id,
                "todo for %d min, assignee never started" % round(updated_age)))

    if status == "in_review":
        for interaction in source.interactions(issue_id):
            if (interaction.get("status") or "") != "pending":
                continue
            waiting = age_minutes(now, interaction.get("createdAt"))
            if waiting is not None and waiting > WAITING_HUMAN_MINUTES:
                items.append(make_item(
                    "waiting_human", identifier, issue_id, agent_id,
                    "in_review, a human answer has been pending %d min" % round(waiting)))
                break

    for comment in source.comments(issue_id):
        if (comment.get("authorType") or "") != "user":
            continue
        if not comment.get("createdByRunId"):
            continue
        comment_age = age_minutes(now, comment.get("createdAt"))
        if comment_age is not None and comment_age > IMPERSONATION_MINUTES:
            continue
        items.append(make_item(
            "impersonation", identifier, issue_id, agent_id,
            "a user comment carries a run id (%s)" % comment.get("createdByRunId")))
        break

    return items


def agent_state(agents):
    """The agents worth watching, keyed by id: not Majster, not parked."""
    watched = {}
    for entry in agents:
        agent_id = entry.get("id")
        status = (entry.get("status") or "").strip()
        if not agent_id or agent_id == MAJSTER_ID:
            continue
        if status in PARKED_AGENT_STATUSES:
            continue
        watched[agent_id] = entry
    return watched


def agent_items(agents, open_issues_by_agent, now):
    items = []
    for agent_id, entry in agents.items():
        status = (entry.get("status") or "").strip()
        name = entry.get("name") or agent_id
        kind = None
        detail = ""
        if status == "error":
            kind = "agent_error"
            reason = entry.get("errorReason")
            detail = "agent %s is in error" % name
            if reason:
                detail += ": " + str(reason)
        elif status == "running":
            heartbeat = age_minutes(now, entry.get("lastHeartbeatAt"))
            if heartbeat is not None and heartbeat > ZOMBIE_MINUTES:
                kind = "agent_zombie"
                detail = ("agent %s says running, last heartbeat %d min ago"
                          % (name, round(heartbeat)))
        if kind is None:
            continue
        assigned = open_issues_by_agent.get(agent_id) or []
        if not assigned:
            items.append(make_item(kind, None, None, agent_id, detail))
            continue
        for issue in assigned:
            items.append(make_item(kind,
                                   issue.get("identifier") or issue.get("id"),
                                   issue.get("id"), agent_id, detail))
    return items


def parse_ps(text):
    """Rows of `ps -axo pid=,ppid=,etime=,comm=` as (pid, elapsed, comm)."""
    rows = []
    for line in (text or "").splitlines():
        fields = line.split(None, 3)
        if len(fields) < 4:
            continue
        rows.append((fields[0], fields[2], fields[3]))
    return rows


def elapsed_seconds(etime):
    """`[[dd-]hh:]mm:ss` in seconds; None when it does not parse."""
    text = (etime or "").strip()
    if not text:
        return None
    days = 0
    if "-" in text:
        head, _, text = text.partition("-")
        try:
            days = int(head)
        except ValueError:
            return None
    pieces = text.split(":")
    try:
        numbers = [int(piece) for piece in pieces]
    except ValueError:
        return None
    if len(numbers) == 3:
        hours, minutes, seconds = numbers
    elif len(numbers) == 2:
        hours, minutes, seconds = 0, numbers[0], numbers[1]
    elif len(numbers) == 1:
        hours, minutes, seconds = 0, 0, numbers[0]
    else:
        return None
    return days * 86400 + hours * 3600 + minutes * 60 + seconds


def long_child_items(ps_text):
    items = []
    for pid, etime, comm in parse_ps(ps_text):
        name = os.path.basename(comm.strip())
        if name not in LONG_CHILD_COMMANDS:
            continue
        seconds = elapsed_seconds(etime)
        if seconds is None or seconds <= LONG_CHILD_SECONDS:
            continue
        items.append(make_item(
            "long_child", None, None, None,
            "pid %s %s running %s (over %d min)"
            % (pid, name, etime, LONG_CHILD_SECONDS // 60)))
    return items


# ------------------------------------------------------------------ report

def sort_items(items):
    def key(item):
        issue = item.get("issue") or "zzzz"
        return (0 if item.get("kind") in NEEDS_MODEL_KINDS else 1, issue,
                item.get("detail") or "")
    return sorted(items, key=key)


def build_brief(now, items, truncated, stop_text, tick_lines):
    lines = ["<!-- sweep:%s -->" % iso_minutes(now),
             "## Sweep %s" % iso_display(now)]
    if stop_text is not None:
        lines.append("factory STOPPED: %s" % stop_text)
    if items:
        for item in items:
            subject = item.get("issue") or item.get("agent") or "-"
            lines.append("- [%s] %s - %s" % (item.get("kind"), subject,
                                             item.get("detail") or ""))
    else:
        lines.append("- quiet board, nothing needed")
    if truncated:
        lines.append("- %d more flagged item(s) not listed here" % truncated)
    lines.extend(tick_lines)
    return "\n".join(lines)


def build_report(source, now, ps_text, stop_text, tick_lines):
    open_issues = []
    for row in source.list_issues():
        issue_id = row.get("id")
        if not issue_id:
            continue
        issue = source.get_issue(issue_id)
        if issue is None:
            continue          # the per-issue GET answered 404: no evidence
        if not isinstance(issue, dict):
            continue
        if skip_reason(issue, now) is not None:
            continue
        open_issues.append(issue)

    items = []
    for issue in open_issues:
        items.extend(issue_rules(issue, now, source))

    by_agent = {}
    for issue in open_issues:
        agent_id = issue.get("assigneeAgentId")
        if agent_id:
            by_agent.setdefault(agent_id, []).append(issue)

    items.extend(agent_items(agent_state(source.agents()), by_agent, now))
    items.extend(long_child_items(ps_text))

    items = sort_items(items)
    truncated = max(0, len(items) - MAX_ITEMS)
    kept = items[:MAX_ITEMS]

    actionable = any(item.get("kind") in NEEDS_MODEL_KINDS for item in kept)
    report = {
        "now": iso_seconds(now),
        "open": len(open_issues),
        "stop": stop_text,
        "actionable": actionable,
        "items": kept,
        "truncated": truncated,
        "tick": tick_lines,
        "brief_md": build_brief(now, kept, truncated, stop_text, tick_lines),
    }
    return report


# -------------------------------------------------------------------- work

def read_stop_file(path):
    if not path:
        return None
    try:
        with open(os.path.expanduser(path), "r", encoding="utf-8") as handle:
            text = handle.read().strip()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise SetupError("cannot read the STOP file: %s" % exc)
    return text or None


def run_tick(command):
    if not command:
        return []
    try:
        finished = subprocess.run(command, shell=True, capture_output=True,
                                  text=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        return []
    return [line for line in (finished.stdout or "").splitlines() if line.strip()]


def read_ps(path):
    if path:
        try:
            with open(os.path.expanduser(path), "r", encoding="utf-8") as handle:
                return handle.read()
        except OSError as exc:
            raise SetupError("cannot read the ps file: %s" % exc)
    try:
        finished = subprocess.run(PS_ARGV, capture_output=True, text=True,
                                  timeout=60)
    except (OSError, subprocess.SubprocessError):
        return ""
    return finished.stdout or ""


def live_source():
    missing = [name for name in ("PAPERCLIP_API_URL", "PAPERCLIP_API_KEY",
                                 "PAPERCLIP_COMPANY_ID") if not os.environ.get(name)]
    if missing:
        raise SetupError("%s is not set; export it or pass --fixtures" % missing[0])
    return ApiSource(os.environ["PAPERCLIP_API_URL"],
                     os.environ["PAPERCLIP_API_KEY"],
                     os.environ["PAPERCLIP_COMPANY_ID"])


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="sweep.py",
        description="Majster's hourly board walk, without a model.")
    parser.add_argument("--fixtures", metavar="DIR",
                        help="read the board from JSON files in DIR")
    parser.add_argument("--now", metavar="ISO8601",
                        help="clock for the age rules (tests); default: now")
    parser.add_argument("--stop-file", metavar="PATH", default=DEFAULT_STOP_FILE,
                        help="STOP file to watch (default: %s)" % DEFAULT_STOP_FILE)
    parser.add_argument("--tick-cmd", metavar="CMD", default=DEFAULT_TICK_CMD,
                        help="the factory tick command whose lines we keep")
    parser.add_argument("--ps-file", metavar="PATH",
                        help="read the process list from a file instead of running ps")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        now = parse_time(args.now) if args.now else datetime.now(timezone.utc)
        if now is None:
            raise SetupError("--now is not an ISO 8601 timestamp")
        source = FixtureSource(args.fixtures) if args.fixtures else live_source()
        stop_text = read_stop_file(args.stop_file)
        tick_lines = run_tick(args.tick_cmd)
        ps_text = read_ps(args.ps_file)
        report = build_report(source, now, ps_text, stop_text, tick_lines)
    except SetupError as exc:
        sys.stderr.write("sweep: %s\n" % exc)
        return 2
    sys.stdout.write(json.dumps(report, separators=(",", ":")) + "\n")
    return 10 if report.get("actionable") else 0


if __name__ == "__main__":
    sys.exit(main())
