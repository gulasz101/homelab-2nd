#!/usr/bin/env python3
"""Fake Pi-hole FTL v6 API + Mattermost webhook sink for pihole_curfew.py tests.

Serves the handful of endpoints the seeder and the roster audit touch, over real
HTTP, so the script is exercised exactly as it runs in the cluster (urllib,
X-FTL-SID/CSRF headers, JSON bodies) instead of being monkeypatched.

    python3 fake_ftl.py --port 0 --portfile /tmp/pihole-fake.port

Control endpoints (not part of the real API — the tests drive the state):

    POST /__state  {clients:[], suggestions:[], devices:[], deny:{exact:[],regex:[]}}
    POST /__reset  wipe state and the request log
    GET  /__requests  [["GET","/api/clients"], ...]
    GET  /__webhooks  [{"text": ...}, ...]   what Mattermost would have received
"""
import argparse
import json
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAC_RE = re.compile(r"^(?:[0-9a-f]{2}:){5}[0-9a-f]{2}$")


class State:
    def __init__(self):
        self.clients = {}
        self.deny = {"exact": {}, "regex": {}}
        self.suggestions = []
        self.devices = []
        self.requests = []
        self.webhooks = []
        self.next_id = 1
        self.auth_calls = 0

    def load(self, payload):
        self.clients = {}
        self.next_id = 1
        for c in payload.get("clients") or []:
            mac = str(c["client"]).lower()
            self.clients[mac] = {"client": mac, "name": "",
                                 "comment": c.get("comment") or "",
                                 "groups": [int(g) for g in c.get("groups") or []],
                                 "id": self.next_id}
            self.next_id += 1
        self.deny = {"exact": {}, "regex": {}}
        for kind, entries in (payload.get("deny") or {}).items():
            for d in entries:
                self.deny[kind][d["domain"]] = dict(d)
        self.suggestions = payload.get("suggestions") or []
        self.devices = payload.get("devices") or []
        self.requests = []


STATE = State()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _send(self, code, payload):
        raw = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def do_POST(self):
        if self.path == "/__state":
            STATE.load(self._body())
            return self._send(200, {"ok": True})
        if self.path == "/__reset":
            STATE.load({})
            return self._send(200, {"ok": True})
        STATE.requests.append(("POST", self.path))
        if self.path == "/api/auth":
            STATE.auth_calls += 1
            return self._send(200, {"session": {"sid": "fake-sid", "csrf": "fake-csrf",
                                                "valid": True, "totp": False}})
        if self.path == "/api/clients":
            b = self._body()
            mac = str(b.get("client") or "").lower()
            if mac in STATE.clients:
                return self._send(400, {"error": {"key": "already_exists"}})
            STATE.clients[mac] = {"client": mac, "name": "", "comment": b.get("comment") or "",
                                  "groups": [int(g) for g in b.get("groups") or []],
                                  "id": STATE.next_id}
            STATE.next_id += 1
            return self._send(201, {"clients": [STATE.clients[mac]]})
        if self.path == "/webhook":
            STATE.webhooks.append(self._body())
            return self._send(200, {"ok": True})
        return self._send(404, {"error": {"key": "not_found", "message": self.path}})

    def do_PUT(self):
        STATE.requests.append(("PUT", self.path))
        if self.path.startswith("/api/clients/"):
            mac = self.path[len("/api/clients/"):].lower()
            b = self._body()
            if mac not in STATE.clients:
                return self._send(404, {"error": {"key": "not_found"}})
            STATE.clients[mac]["comment"] = b.get("comment") or ""
            STATE.clients[mac]["groups"] = [int(g) for g in b.get("groups") or []]
            return self._send(200, {"clients": [STATE.clients[mac]]})
        return self._send(404, {"error": {"key": "not_found", "message": self.path}})

    def do_GET(self):
        if self.path == "/__requests":
            return self._send(200, {"requests": STATE.requests})
        if self.path == "/__webhooks":
            return self._send(200, {"webhooks": STATE.webhooks})
        STATE.requests.append(("GET", self.path))
        if self.path.startswith("/api/domains/deny/"):
            kind = self.path.rsplit("/", 1)[1]
            return self._send(200, {"domains": list(STATE.deny.get(kind, {}).values())})
        if self.path == "/api/clients":
            return self._send(200, {"clients": list(STATE.clients.values())})
        if self.path == "/api/clients/_suggestions":
            return self._send(200, {"clients": STATE.suggestions})
        if self.path == "/api/network/devices":
            return self._send(200, {"devices": STATE.devices, "cursor": None})
        return self._send(404, {"error": {"key": "not_found", "message": self.path}})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--portfile", required=True)
    args = ap.parse_args()
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    with open(args.portfile, "w") as fh:
        fh.write(str(srv.server_address[1]))
    sys.stderr.write(f"fake FTL listening on 127.0.0.1:{srv.server_address[1]}\n")
    srv.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
