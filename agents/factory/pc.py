"""Minimal Paperclip API client for factory.py (GUL-439).

Standard library only, same rules as factory.py: no third-party imports, no
printing of the key, its environment or any request header.

Auth comes only from the environment: PAPERCLIP_API_KEY and
PAPERCLIP_RUN_ID. The board's own token file is Wojtek's login and is never
read here (GUL-297).

Base URL: PAPERCLIP_API_URL may be the bare origin (http://127.0.0.1:3100) or
already carry /api. The public URL is not usable: Cloudflare answers urllib
with 403 1010.
"""

import json
import os
import urllib.error
import urllib.request

DEFAULT_BASE = "http://127.0.0.1:3100/api"


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(f"HTTP {status}: {message}")
        self.status = status
        self.message = message


def base_url():
    raw = (os.environ.get("PAPERCLIP_API_URL") or DEFAULT_BASE).rstrip("/")
    return raw if raw.endswith("/api") else raw + "/api"


def credentials():
    """Return (key, run_id) or raise LookupError naming what is missing."""
    key = os.environ.get("PAPERCLIP_API_KEY") or ""
    run_id = os.environ.get("PAPERCLIP_RUN_ID") or ""
    missing = [n for n, v in (("PAPERCLIP_API_KEY", key), ("PAPERCLIP_RUN_ID", run_id)) if not v]
    if missing:
        raise LookupError("missing " + " and ".join(missing))
    return key, run_id


class Api:
    def __init__(self, key=None, run_id=None, base=None):
        self.key, self.run_id = (key, run_id) if key and run_id else credentials()
        self.base = (base or base_url()).rstrip("/")

    # -- transport -------------------------------------------------------
    def _request(self, method, path, body=None):
        url = self.base + path
        data = None
        headers = {
            "Authorization": "Bearer " + self.key,
            "X-Paperclip-Run-Id": self.run_id,
            "Accept": "application/json",
        }
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                status = resp.status
                raw = resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            status = exc.code
            raw = exc.read().decode("utf-8", "replace")
        except urllib.error.URLError as exc:
            raise ApiError(0, f"{method} {path}: {exc.reason}") from exc
        parsed = None
        if raw.strip():
            try:
                parsed = json.loads(raw)
            except ValueError:
                parsed = raw
        return status, parsed

    def _call(self, method, path, body=None, ok=(200, 201)):
        status, parsed = self._request(method, path, body)
        if status not in ok:
            detail = parsed.get("error") if isinstance(parsed, dict) else parsed
            raise ApiError(status, f"{method} {path}: {detail}")
        return parsed

    def get(self, path):
        return self._call("GET", path)

    def post(self, path, body):
        return self._call("POST", path, body)

    def patch(self, path, body):
        return self._call("PATCH", path, body)

    def put(self, path, body):
        return self._call("PUT", path, body)

    # -- endpoints the factory uses --------------------------------------
    def issues(self, company_id):
        return self.get(f"/companies/{company_id}/issues")

    def issue(self, issue_id):
        return self.get(f"/issues/{issue_id}")

    def by_identifier(self, company_id, identifier):
        for item in self.issues(company_id):
            if item.get("identifier") == identifier:
                return item
        return None

    def children_of(self, company_id, parent_id):
        return [i for i in self.issues(company_id) if i.get("parentId") == parent_id]

    def document(self, issue_id, key):
        try:
            payload = self.get(f"/issues/{issue_id}/documents/{key}")
        except ApiError as exc:
            if exc.status == 404:
                return None
            raise
        doc = payload.get("document") if isinstance(payload, dict) else None
        if isinstance(doc, dict):
            return doc
        return payload if isinstance(payload, dict) else None

    def write_document(self, issue_id, key, body, title=None, change_summary=None):
        payload = {"format": "markdown", "body": body}
        if title:
            payload["title"] = title
        if change_summary:
            payload["changeSummary"] = change_summary
        return self.put(f"/issues/{issue_id}/documents/{key}", payload)

    def comment(self, issue_id, body):
        return self.post(f"/issues/{issue_id}/comments", {"body": body})

    def create_child(self, parent_id, body):
        return self.post(f"/issues/{parent_id}/children", body)

    def patch_issue(self, issue_id, body):
        resp = self.patch(f"/issues/{issue_id}", body)
        want = body.get("status")
        if want and isinstance(resp, dict) and resp.get("status") not in (None, want):
            raise ApiError(200, f"PATCH /issues/{issue_id}: echoed status {resp.get('status')!r}, wanted {want!r}")
        return resp

    def create_work_product(self, issue_id, body):
        return self.post(f"/issues/{issue_id}/work-products", body)

    def create_interaction(self, issue_id, body):
        return self.post(f"/issues/{issue_id}/interactions", body)

    def runs(self, issue_id):
        try:
            payload = self.get(f"/issues/{issue_id}/runs")
        except ApiError as exc:
            if exc.status in (403, 404):
                return None
            raise
        if isinstance(payload, list):
            return payload
        if isinstance(payload, dict):
            return payload.get("runs") or payload.get("items")
        return None

    def agent(self, agent_id):
        return self.get(f"/agents/{agent_id}")

    def project_workspaces(self, project_id):
        return self.get(f"/projects/{project_id}/workspaces")


def run_id_or_empty():
    return os.environ.get("PAPERCLIP_RUN_ID") or ""
