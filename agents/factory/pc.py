"""Minimal Paperclip API client for factory.py (GUL-439).

Standard library only, same rules as factory.py: no third-party imports, no
printing of the key, its environment or any request header.

Auth comes only from the environment: PAPERCLIP_API_KEY and
PAPERCLIP_RUN_ID. The board's own token file is Wojtek's login and is never
read here (GUL-297).

Base URL: PAPERCLIP_API_URL may be the bare origin (http://127.0.0.1:3100) or
already carry /api. The public URL is not usable: Cloudflare answers urllib
with 403 1010. A run inherits whatever PAPERCLIP_API_URL the adapter was given,
so an edge-shaped 403 (or an unreachable host) falls back once to the local
API and is remembered for the rest of the run (GUL-496).
"""

import json
import os
import urllib.error
import urllib.request

DEFAULT_BASE = "http://127.0.0.1:3100/api"
FALLBACK_ENV = "PAPERCLIP_API_FALLBACK_URL"
USER_AGENT = "paperclip-factory/1 (factory.py)"


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(f"HTTP {status}: {message}")
        self.status = status
        self.message = message


def base_url():
    raw = (os.environ.get("PAPERCLIP_API_URL") or DEFAULT_BASE).rstrip("/")
    return raw if raw.endswith("/api") else raw + "/api"


def fallback_base():
    """The API to try when the configured one is behind a wall (GUL-496)."""
    raw = (os.environ.get(FALLBACK_ENV) or DEFAULT_BASE).rstrip("/")
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
    def _exchange(self, base, method, path, body):
        """One HTTP exchange. Returns (status, parsed, raw). status 0 is a
        connection-level failure, not an HTTP answer."""
        url = base + path
        data = None
        headers = {
            "Authorization": "Bearer " + self.key,
            "X-Paperclip-Run-Id": self.run_id,
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
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
        except urllib.error.URLError:
            return 0, None, ""
        parsed = None
        if raw.strip():
            try:
                parsed = json.loads(raw)
            except ValueError:
                parsed = raw
        return status, parsed, raw

    @staticmethod
    def _wall(status, raw):
        """True when the answer came from the edge, not from Paperclip: a
        Cloudflare 1010 block page, or no connection at all."""
        if status == 0:
            return True
        if status != 403:
            return False
        text = (raw or "")[:2000].lower()
        return "1010" in text or "cloudflare" in text or text.lstrip().startswith("<")

    def _request(self, method, path, body=None):
        status, parsed, raw = self._exchange(self.base, method, path, body)
        if self._wall(status, raw):
            alt = fallback_base()
            if alt.rstrip("/") != self.base.rstrip("/"):
                status, parsed, raw = self._exchange(alt, method, path, body)
                if not self._wall(status, raw):
                    self.base = alt
        if status == 0:
            raise ApiError(0, f"{method} {path}: cannot reach {self.base}")
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
        """PUT a document, carrying the revision it replaces (GUL-496).

        Paperclip refuses an update that does not name the revision it was
        based on (`409 Document update requires baseRevisionId`), so read the
        document first and send its `latestRevisionId`; a first write sends
        null. The body is a whole replacement built by factory.py, so a 409
        means someone wrote in between: re-read once and retry on the fresh
        revision before giving up.
        """

        def payload_for():
            current = self.document(issue_id, key)
            revision = current.get("latestRevisionId") if isinstance(current, dict) else None
            payload = {"format": "markdown", "body": body, "baseRevisionId": revision}
            if title:
                payload["title"] = title
            if change_summary:
                payload["changeSummary"] = change_summary
            return payload

        path = f"/issues/{issue_id}/documents/{key}"
        try:
            response = self.put(path, payload_for())
        except ApiError as exc:
            if exc.status != 409:
                raise
            response = self.put(path, payload_for())
        if isinstance(response, dict) and "document" not in response and response.get("id"):
            # the live API echoes the document itself, not {"document": …}
            return {"document": response}
        return response

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
