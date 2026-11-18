#!/usr/bin/env python3
"""gemini-guard-verdicts-check.py — GUL-1339: an inconclusive canary is a fault.

Runs `host/m1max/gemini-web2api/guard.py` as a subprocess against a stub proxy and a
stub docker CLI, so it needs no Max, no Docker, no network and no Firefox of its own:

  GUARD_PROXY   -> a stub HTTP server on 127.0.0.1 that answers GET /, the admin API
                   and /v1/chat/completions, and counts the chat requests it served
  GUARD_DOCKER  -> a shell stub for `docker info|inspect|run|restart`
  GUARD_DIR     -> a temp dir holding `gemini2api.env` (fake tokens) and the state file
  HOME          -> a temp home carrying a fake Firefox profile with a `cookies.sqlite`,
                   which is how `harvest_firefox()` is fed without touching the real one

One `AC-n: PASS|FAIL <reason>` line per acceptance criterion; exit 1 if any FAILs.

Wording contract for the production change (AC-2, AC-3): the escalation line must
contain the word "consecutive" and the count (2 or "two"); `last_canary_reason` must
carry the deciding log text truncated to at most 120 characters; the dead-cookie line
must name the cookie being expired / not a valid login.
"""
import http.server
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
HOSTDIR = os.path.dirname(HERE)                                  # host/m1max
GUARD = os.path.join(HOSTDIR, "gemini-web2api", "guard.py")
README = os.path.join(HOSTDIR, "gemini-web2api", "README.md")

# The nine names `harvest_firefox()` insists on (it needs at least six of them).
COOKIES = ["SID", "HSID", "SSID", "APISID", "SAPISID",
           "__Secure-1PSID", "__Secure-1PSIDTS", "__Secure-1PAPISID", "__Secure-1PSIDCC"]

CANARY_MODEL = "gemini-4-argon"

DOCKER_STUB = """#!/bin/sh
# test stub: just enough of the docker CLI for guard.py
if [ "$1" = "info" ]; then echo "27.0.0"; exit 0; fi
if [ "$1" = "inspect" ]; then
  case "$3" in
    *State.Status*) echo running ;;
    *) echo 'ghcr.io/zexadev/gemini-web2api-go@sha256:0000000000000000000000000000000000000000000000000000000000000000|unless-stopped' ;;
  esac
  exit 0
fi
if [ "$1" = "run" ]; then date +%s; exit 0; fi
exit 0
"""


class Stub(object):
    """Stub proxy. `pre_rows` is what `/admin/api/requests` shows before a chat request
    goes out in this run, `post_rows` what it shows afterwards — the same trick the real
    log plays, so the canary's own row is only there once the canary has fired."""

    def __init__(self):
        self.pre_rows = []
        self.post_rows = []
        self.chat_in_run = 0
        self.chat_total = 0
        self._srv = None
        self._thread = None
        self.port = None

    # ---- lifecycle ----
    def start(self):
        stub = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def _send(self, code, obj):
                body = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                path, _, query = self.path.partition("?")
                if path == "/":
                    return self._send(200, {"status": "ok", "version": "stub"})
                if path == "/admin/api/cookies":
                    return self._send(200, {"items": [{"id": 1}], "enabled": 1})
                if path == "/admin/api/requests":
                    if "model=gemini-image" in query:
                        return self._send(200, {"items": []})
                    rows = stub.post_rows if stub.chat_in_run else stub.pre_rows
                    return self._send(200, {"items": rows})
                return self._send(404, {"error": "no GET route %s" % path})

            def do_POST(self):
                path = self.path.partition("?")[0]
                n = int(self.headers.get("Content-Length") or 0)
                if n:
                    self.rfile.read(n)
                if path == "/v1/chat/completions":
                    stub.chat_in_run += 1
                    stub.chat_total += 1
                    if stub.post_rows and stub.post_rows[0].get("status") == 200:
                        return self._send(200, {"choices": [{"message": {"content": "pong"}}]})
                    return self._send(502, {"error": "upstream returned a failure reply"})
                if path == "/admin/api/cookies":
                    return self._send(200, {"id": 1})
                if re.match(r"^/admin/api/cookies/[^/]+/check$", path):
                    return self._send(200, {"ok": True})
                return self._send(404, {"error": "no POST route %s" % path})

            def do_DELETE(self):
                n = int(self.headers.get("Content-Length") or 0)
                if n:
                    self.rfile.read(n)
                return self._send(200, {"deleted": True})

        self._srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self._srv.server_address[1]
        self._thread = threading.Thread(target=self._srv.serve_forever, daemon=True)
        self._thread.start()

    def stop(self):
        if self._srv is not None:
            self._srv.shutdown()
            self._srv.server_close()

    def begin_run(self):
        self.chat_in_run = 0


def log_row(row_id, status, upstream, error, when):
    return {"id": row_id, "model": CANARY_MODEL, "status": status,
            "upstream_model": upstream, "total_ms": 1200, "error": error, "ts": when}


def new_workspace(root, name):
    """A temp dir that is GUARD_DIR, a fake HOME with a Firefox cookie DB, a docker stub."""
    d = os.path.join(root, name)
    home = os.path.join(d, "home")
    prof = os.path.join(home, "Library", "Application Support", "Firefox", "Profiles",
                        "abc123.default-release")
    os.makedirs(prof)

    con = sqlite3.connect(os.path.join(prof, "cookies.sqlite"))
    con.execute("CREATE TABLE moz_cookies (name TEXT, value TEXT, host TEXT)")
    for c in COOKIES:
        con.execute("INSERT INTO moz_cookies VALUES (?,?,?)",
                    (c, "stub-value-not-a-real-cookie-" + c, ".google.com"))
    con.commit()
    con.close()

    envf = os.path.join(d, "gemini2api.env")
    with open(envf, "w") as f:
        f.write("ADMIN_TOKEN=stub-admin-token\nGEMINI_WEB_API_KEY=stub-web-key\n")
    os.chmod(envf, 0o600)

    docker = os.path.join(d, "docker")
    with open(docker, "w") as f:
        f.write(DOCKER_STUB)
    os.chmod(docker, 0o755)

    return {"dir": d, "home": home, "docker": docker,
            "state": os.path.join(d, "cookie_guard_state.json")}


def seed(ws, state):
    with open(ws["state"], "w") as f:
        json.dump(state, f)


def read_state(ws):
    with open(ws["state"]) as f:
        return json.load(f)


def run_guard(ws, stub):
    stub.begin_run()
    env = dict(os.environ)
    env.pop("GUARD_SKIP_COOKIES", None)
    env.update({
        "HOME": ws["home"],
        "GUARD_DIR": ws["dir"],
        "GUARD_STATE": ws["state"],
        "GUARD_DOCKER": ws["docker"],
        "GUARD_PROXY": "http://127.0.0.1:%d" % stub.port,
    })
    started = int(time.time())
    proc = subprocess.run([sys.executable, GUARD], capture_output=True, text=True,
                          timeout=180, env=env)
    lines = [l.strip() for l in (proc.stdout or "").splitlines() if l.strip()]
    return {"started": started, "rc": proc.returncode, "lines": lines,
            "stderr": (proc.stderr or "").strip()}


# ---------------------------------------------------------------- predicates

ESCALATION = re.compile(r"consecutive", re.I)
COUNT = re.compile(r"\b(2|two)\b", re.I)
FAULT = re.compile(r"inconclusive|no verdict|cannot (reach|verify)|canary", re.I)


def escalations(lines):
    return [l for l in lines if ESCALATION.search(l) and COUNT.search(l)]


def inconclusive_faults(lines):
    """Lines that speak the canary fault, escalation excluded."""
    return [l for l in lines if FAULT.search(l) and l not in escalations(lines)]


# ---------------------------------------------------------------- the ACs

def main():
    results = {}                                   # "AC-1" -> (ok, reason)

    def record(ac, ok, reason):
        results[ac] = (bool(ok), reason)

    if not os.path.isfile(GUARD):
        sys.stderr.write("setup error: %s is missing\n" % GUARD)
        return 2

    root = tempfile.mkdtemp(prefix="gemini-guard-verdicts-")
    stubs = []
    try:
        # ---------------------------------------------------------- scenario A
        # healthy state, then two inconclusive samples, then one healthy sample.
        stub = Stub()
        stub.start()
        stubs.append(stub)
        ws = new_workspace(root, "a")
        t0 = int(time.time())
        seed(ws, {
            "entitlement": "ok",
            "last_upstream": "4 Argon",
            "checked_at": t0 - 4200,          # 70 min stale: the incident's frozen clock
            "last_sample_at": t0 - 4200,
            "healthy_since": t0 - 90000,
            "degraded_accum_s": 1234,
        })

        # the log has no row for this sample yet; the live probe is what fires and fails
        stub.pre_rows = []
        stub.post_rows = [log_row(101, 502, "",
                                  "upstream returned a failure reply (inner[31] set)",
                                  t0 + 120)]
        run1 = run_guard(ws, stub)
        st1 = read_state(ws) if os.path.exists(ws["state"]) else {}

        stub.pre_rows = list(stub.post_rows)
        stub.post_rows = [log_row(102, 502, "",
                                  "upstream returned a failure reply (inner[31] set)",
                                  int(time.time()) + 120)]
        run2 = run_guard(ws, stub)
        st2 = read_state(ws) if os.path.exists(ws["state"]) else {}

        # --- AC-1: a sample with no verdict leaves no green wall behind it
        why = []
        if st1.get("entitlement") != "unknown":
            why.append("entitlement is %r, want 'unknown'" % (st1.get("entitlement"),))
        if int(st1.get("checked_at") or 0) < run1["started"]:
            why.append("checked_at is %r, not refreshed this run" % (st1.get("checked_at"),))
        if int(st1.get("last_sample_at") or 0) < run1["started"]:
            why.append("last_sample_at is %r, not refreshed this run"
                       % (st1.get("last_sample_at"),))
        record("AC-1", not why,
               "; ".join(why) or "fresh timestamps, entitlement unknown")

        # --- AC-2: one fault, no escalation; the second one escalates exactly once
        why = []
        if not inconclusive_faults(run1["lines"]):
            why.append("first inconclusive sample spoke nothing: %r" % (run1["lines"],))
        esc1 = escalations(run1["lines"])
        if esc1:
            why.append("first inconclusive sample already escalated: %r" % (esc1[0][:120],))
        esc2 = escalations(run2["lines"])
        if len(esc2) != 1:
            why.append("second consecutive sample spoke %d escalations, want exactly 1 "
                       "(lines: %r)" % (len(esc2), [l[:100] for l in run2["lines"]]))
        if len(esc2) == 1 and not COUNT.search(esc2[0]):
            why.append("the escalation does not name the count of 2: %r" % (esc2[0][:120],))
        record("AC-2", not why,
               "; ".join(why) or "one fault, then exactly one escalation naming 2")

        # --- AC-4: unknown stays unknown, and no degraded time is invented or wiped
        why = []
        if st2.get("entitlement") != "unknown":
            why.append("after two inconclusive samples entitlement is %r, want 'unknown'"
                       % (st2.get("entitlement"),))
        for name, st in (("after 1", st1), ("after 2", st2)):
            if "healthy_since" in st:
                why.append("healthy_since survived %s inconclusive sample(s)" % name)
            if int(st.get("degraded_accum_s") or 0) != 1234:
                why.append("degraded_accum_s %s = %r, want the seeded 1234 untouched"
                           % (name, st.get("degraded_accum_s")))
        record("AC-4", not why, "; ".join(why) or "unknown kept, healthy_since dropped, "
                                                  "cumulative degraded time untouched")

        # --- AC-5: a real verdict clears the streak and speaks no alarm
        stub.pre_rows = list(stub.post_rows)
        stub.post_rows = [log_row(103, 200, "4 Argon", "", int(time.time()) + 120)]
        run3 = run_guard(ws, stub)
        st3 = read_state(ws) if os.path.exists(ws["state"]) else {}
        why = []
        if int(st2.get("inconclusive_samples") or 0) != 2:
            why.append("after two inconclusive samples inconclusive_samples is %r, want 2"
                       % (st2.get("inconclusive_samples"),))
        if st3.get("entitlement") != "ok":
            why.append("healthy sample left entitlement %r, want 'ok'"
                       % (st3.get("entitlement"),))
        if st3.get("last_upstream") != "4 Argon":
            why.append("healthy sample left last_upstream %r, want '4 Argon'"
                       % (st3.get("last_upstream"),))
        if int(st3.get("inconclusive_samples") or 0) != 0:
            why.append("healthy sample did not clear inconclusive_samples (%r)"
                       % (st3.get("inconclusive_samples"),))
        if "inconclusive_since" in st3:
            why.append("healthy sample did not drop inconclusive_since")
        if escalations(run3["lines"]):
            why.append("healthy sample still escalated: %r"
                       % (escalations(run3["lines"])[0][:120],))
        if inconclusive_faults(run3["lines"]):
            why.append("healthy sample still spoke the inconclusive fault: %r"
                       % (inconclusive_faults(run3["lines"])[0][:120],))
        record("AC-5", not why,
               "; ".join(why) or "entitlement ok, last_upstream 4 Argon, streak cleared, "
                                 "nothing spoken")

        # ---------------------------------------------------------- scenario B/C
        # The request log already names the cause, so no chat request may go out.
        now = int(time.time())
        # --- AC-3a: no SNlM0e is a dead cookie
        stub_b = Stub()
        stub_b.start()
        stubs.append(stub_b)
        ws_b = new_workspace(root, "b")
        dead = log_row(10945, 502, "",
                       "no SNlM0e in page (cookie expired or not signed in)", now + 120)
        stub_b.pre_rows = [dead]
        stub_b.post_rows = [dead]
        seed(ws_b, {"entitlement": "ok", "last_upstream": "4 Argon",
                    "checked_at": now - 3600, "last_sample_at": now - 3600,
                    "last_canary": now - 1800, "degraded_accum_s": 99})
        run_b = run_guard(ws_b, stub_b)
        st_b = read_state(ws_b) if os.path.exists(ws_b["state"]) else {}

        why_b = []
        if stub_b.chat_total != 0:
            why_b.append("sent %d chat request(s) although the log already said the cookie "
                         "is dead" % stub_b.chat_total)
        cookie_line = [l for l in run_b["lines"]
                       if re.search(r"cookie|login|session", l, re.I)
                       and re.search(r"expired|not signed in|not a valid login|no valid "
                                     r"cookie|dead", l, re.I)]
        if not cookie_line:
            why_b.append("no dead-cookie message: %r" % ([l[:100] for l in run_b["lines"]],))
        reason_b = str(st_b.get("last_canary_reason") or "")
        if "SNlM0e" not in reason_b:
            why_b.append("last_canary_reason %r does not carry the deciding log text"
                         % (reason_b[:120],))
        if len(reason_b) > 120:
            why_b.append("last_canary_reason is %d chars, want it truncated to 120"
                         % len(reason_b))

        # --- AC-3b: Client.Timeout is a slow model, and the entitlement is unknown
        stub_c = Stub()
        stub_c.start()
        stubs.append(stub_c)
        ws_c = new_workspace(root, "c")
        slow = log_row(10946, 502, "",
                       "net/http: request canceled (Client.Timeout exceeded while awaiting "
                       "headers)", now + 120)
        stub_c.pre_rows = [slow]
        stub_c.post_rows = [slow]
        seed(ws_c, {"entitlement": "ok", "last_upstream": "4 Argon",
                    "checked_at": now - 3600, "last_sample_at": now - 3600,
                    "last_canary": now - 1800, "degraded_accum_s": 99})
        run_c = run_guard(ws_c, stub_c)
        st_c = read_state(ws_c) if os.path.exists(ws_c["state"]) else {}

        why_c = []
        if stub_c.chat_total != 0:
            why_c.append("sent %d chat request(s) although the log already said the model "
                         "timed out" % stub_c.chat_total)
        if st_c.get("entitlement") != "unknown":
            why_c.append("slow model left entitlement %r, want 'unknown'"
                         % (st_c.get("entitlement"),))
        reason_c = str(st_c.get("last_canary_reason") or "")
        if not re.search(r"Client\.Timeout|deadline exceeded|request canceled", reason_c):
            why_c.append("last_canary_reason %r does not carry the deciding log text"
                         % (reason_c[:120],))
        if not [l for l in run_c["lines"]
                if re.search(r"inconclusive|slow|timeout|deadline|cannot", l, re.I)]:
            why_c.append("no slow-model message: %r"
                         % ([l[:100] for l in run_c["lines"]],))

        why3 = ["dead cookie: " + w for w in why_b] + ["slow model: " + w for w in why_c]
        record("AC-3", not why3,
               "; ".join(why3) or "log-first classification decided both cases, no chat request")

        # --- AC-6: the README documents the verdict rules
        why6 = []
        section = None
        try:
            with open(README) as f:
                lines = f.read().splitlines()
        except OSError as exc:
            lines = []
            why6.append("README unreadable: %r" % (exc,))
        for i, line in enumerate(lines):
            if line.lstrip().startswith("#") and re.search(r"verdict", line, re.I):
                body = []
                for rest in lines[i + 1:]:
                    if re.match(r"^#{1,2}\s", rest):
                        break
                    body.append(rest)
                section = "\n".join(body)
                break
        if section is None:
            why6.append("README has no Verdicts section")
        else:
            if not re.search(r"\bunknown\b", section, re.I):
                why6.append("the Verdicts section does not name the 'unknown' state")
            if not re.search(r"(two|2)\s+consecutive", section, re.I):
                why6.append("the Verdicts section does not document the two-consecutive "
                            "escalation")
            if not re.search(r"request log|log first|log-first", section, re.I):
                why6.append("the Verdicts section does not document the log-first "
                            "classification")
            if not re.search(r"120", section):
                why6.append("the Verdicts section does not mention the wrapper's 120 s kill")
            if not re.search(r"wrapper", section, re.I):
                why6.append("the Verdicts section does not mention the wrapper")
        record("AC-6", not why6, "; ".join(why6) or "README documents all four rules")

    finally:
        for s in stubs:
            s.stop()

    failed = 0
    for n in range(1, 7):
        ac = "AC-%d" % n
        ok, reason = results.get(ac, (False, "not evaluated"))
        if ok:
            print("%s: PASS %s" % (ac, reason))
        else:
            failed += 1
            print("%s: FAIL %s" % (ac, reason))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
