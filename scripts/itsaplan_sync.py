#!/usr/bin/env python3
"""Create deduped tasks in Itsaplan project H2 from nightly security-scan findings.

Usage: itsaplan_sync.py <findings.json>

Reads findings JSON:
  {
    "date": "2026-09-10",
    "commit": "4e218ed",
    "criticals": [
      {"kind": "root_user", "file": "apps/arr-stack/radarr/radarr-deployment.yaml",
       "detail": "runAsUser: 0 (init container fix-perms)"},
      ...
    ],
    "warnings": [ {"kind": "...", "file": "...", "detail": "..."} ]
  }

Dedupe: each finding has a stable fingerprint like
  [security-scan][H2-<fingerprint>]
embedded in the issue TITLE. Before creating, the script searches Itsaplan
for that exact string; found = skip (already on the backlog). This makes the
nightly run idempotent: no duplicates, no surprises.

Requires env: ITSAPLAN_RUNNER_URL, MCP_ITSAPLAN_API_KEY.
Only writes to the Backlog column (stateType=backlog). Never assigns,
never delegates, never touches columns other than Backlog.
"""
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("ITSAPLAN_RUNNER_URL", "https://plan-api.voitech.dev").rstrip("/")
KEY = os.environ.get("MCP_ITSAPLAN_API_KEY", "")
PROJECT = "H2"
UA = "homelab-security-scan/1.0 (Hermes cronjob; +https://github.com/gulasz101/homelab-2nd)"
URL = BASE + "/mcp"

if not KEY:
    print("itsaplan_sync: MCP_ITSAPLAN_API_KEY not set, skipping sync")
    sys.exit(0)

_id = [1]


def _next_id():
    _id[0] += 1
    return _id[0]


def post(payload):
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "Authorization": "Bearer " + KEY,
        "User-Agent": UA,
    }
    req = urllib.request.Request(URL, data=json.dumps(payload).encode(), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.read().decode()
    except urllib.error.HTTPError as e:
        raise RuntimeError("Itsaplan HTTP %s: %s" % (e.code, e.read().decode()[:300]))


def parse_sse(body):
    chunks = []
    for line in body.splitlines():
        if line.startswith("data:"):
            chunks.append(line[5:].strip())
    if not chunks:
        raise RuntimeError("Itsaplan: no SSE data in response: %s" % body[:200])
    return json.loads("\n".join(chunks))


def call_tool(name, args):
    payload = {
        "jsonrpc": "2.0",
        "id": _next_id(),
        "method": "tools/call",
        "params": {"name": name, "arguments": args},
    }
    d = parse_sse(post(payload))
    res = d.get("result", {})
    if res.get("isError"):
        txt = " ".join(c.get("text", "") for c in res.get("content", []))
        raise RuntimeError("Itsaplan tool %s failed: %s" % (name, txt[:300]))
    texts = [c.get("text", "") for c in res.get("content", []) if c.get("type") == "text"]
    return "\n".join(texts)


def init_session():
    payload = {
        "jsonrpc": "2.0",
        "id": _next_id(),
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "homelab-security-scan", "version": "1.1.0"},
        },
    }
    parse_sse(post(payload))


def as_list(d):
    if isinstance(d, list):
        return d
    if isinstance(d, dict):
        return d.get("issues", [])
    return []


def find_backlog_column(columns):
    for col in columns_cache:
        if col.get("stateType") == "backlog":
            return col.get("id")
    return None


columns_cache = []


def main():
    findings_path = sys.argv[1]
    with open(findings_path) as f:
        findings = json.load(f)

    date = findings.get("date", "")
    commit = findings.get("commit", "")

    criticals = findings.get("criticals", [])
    warnings = findings.get("warnings", [])
    if not criticals and not warnings:
        print("itsaplan_sync: no findings, nothing to create")
        return

    init_session()

    # Project setup: columns (Backlog id), issue types
    d = json.loads(call_tool("get_project", {"projectKey": PROJECT}))
    columns_cache[:] = d.get("columns", [])
    backlog_id = find_backlog_column(columns_cache)
    if backlog_id is None:
        print("itsaplan_sync: no backlog column found, aborting")
        sys.exit(1)

    types = {t.get("name", "").lower(): t.get("id") for t in d.get("issueTypes", [])}
    task_type = types.get("task") or types.get("tech debt")
    bug_type = types.get("bug")

    # One search across all issues (limit 500) then in-memory dedupe: cheaper
    # than a search round-trip per finding and search_issues only matches
    # title+description text anyway.
    d = json.loads(call_tool("list_issues", {"projectKey": PROJECT, "limit": 500}))
    existing = as_list(d)
    existing_text = set()
    for i in existing:
        existing_text.add((i.get("title") or "").lower())
        # description not returned by list_issues; fingerprints are in titles,
        # which list_issues does return in full.

    created, skipped = [], []

    def fingerprint(kind, file_path):
        slug = (kind + "-" + file_path).lower()
        slug = "".join(ch if ch.isalnum() or ch in "-._" else "-" for ch in slug)
        while "--" in slug:
            slug = slug.replace("--", "-")
        return slug[:80].strip("-")

    def issue_title(fp):
        return "[security-scan][H2-%s]" % fp

    def issue_desc(sev, items, fp):
        sev_label = "critical" if sev == "criticals" else "warning"
        lines = []
        lines.append("**Source:** nightly homelab-security-scan (job 89499b7d034b), run %s on commit `%s`." % (date, commit))
        lines.append("")
        lines.append("**What to do:** review the finding(s) below in `gulasz101/homelab-2nd`, fix the GitOps manifests (prefer HelmRelease values / postRenderers),")
        lines.append("run `scripts/homelab-security-scan.sh` to confirm the finding is gone, then commit + push and move this issue to Done.")
        lines.append("If the finding must be accepted instead of fixed, document the reason in `.security-scan-exclusions.json`")
        lines.append("(the scan will then suppress it and it will stop appearing as critical/warning).")
        lines.append("")
        lines.append("**Finding type:** `%s`  **Severity:** %s  **Dedupe key:** `[H2-%s]`" % (kind, sev_label, fp))
        lines.append("")
        lines.append("**Affected files:**")
        for it in items:
            lines.append("- `%s` — %s" % (it["file"], it["detail"]))
        lines.append("")
        lines.append("*Auto-created by the nightly security scan. Reviewed and delegated by the Supreme Leader; executed by Andrzej (fresh session, delegate flow).*")
        return "\n".join(lines)

    # Group findings by (severity, kind): one issue per kind, files listed inside.
    groups = {}
    for sev in ("criticals", "warnings"):
        for f in findings.get(sev, []):
            key = (sev, f.get("kind", "unknown"))
            groups.setdefault(key, []).append(f)

    for (sev, kind), items in sorted(groups.items()):
        files_joined = "|".join(sorted(it["file"] for it in items))
        fp = fingerprint(kind, files_joined if len(items) <= 3 else kind)
        title = issue_title(fp)
        if title.lower() in existing_text:
            skipped.append(title)
            continue
        args = {
            "projectKey": PROJECT,
            "columnId": backlog_id,
            "title": title,
            "description": issue_desc(sev, items, fp),
            "priority": "high" if sev == "criticals" else "medium",
        }
        if kind == "root_user":
            args["typeId"] = task_type
        call_tool("create_issue", args)
        created.append(title)
        existing_text.add(title.lower())

    print("itsaplan_sync: created=%d skipped=%d" % (len(created), len(skipped)))
    for t in created:
        print("  + created: %s" % t)
    for t in skipped:
        print("  = skipped (already in backlog): %s" % t)


if __name__ == "__main__":
    main()