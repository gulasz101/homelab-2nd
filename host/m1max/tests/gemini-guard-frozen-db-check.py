#!/usr/bin/env python3
"""gemini-guard-frozen-db-check.py — GUL-1387: the cookie DB file decides an import.

With Firefox quit, `cookies.sqlite` is frozen while the proxy keeps rotating its own copy,
so the harvested fingerprint diverges from `state["cookie_hash"]` permanently — in the wrong
direction. The guard must therefore key the import on the DB's own identity (`mtime` + `size`,
recorded as `state["import_db"]`), not on the cookie hash:

  - DB unchanged since the last import  -> skip the harvest/import block entirely: no pool
    write, no message on stdout, one `import_skipped_reason` on stderr.
  - DB newer                            -> import exactly as today (candidate first, /check,
    retire the older entries, then record the new mtime/size).
  - no `import_db` yet (a pre-change state file) -> adopt the current DB as the baseline
    without importing, and stay silent on the next unchanged run.
  - a frozen DB never speaks the "browser session expired" / "no usable cookie" alarm;
  - a DB the FILE says changed still imports and, when /check fails, still speaks the existing
    "browser session expired" line and keeps the working pool entry.

Runs anywhere — no Max, no Docker, no network, no real Firefox — the way
gemini-guard-verdicts-check.py does: HOME at a temp dir carrying a fake Firefox profile with
a `cookies.sqlite`, GUARD_PROXY at a stub HTTP server on 127.0.0.1 that records every pool
write (POST /admin/api/cookies, /check, DELETE), GUARD_DOCKER at a stub script, and
GUARD_DIR/GUARD_STATE in a temp dir holding a `gemini2api.env` with fake tokens.

One `AC-n: PASS|FAIL <reason>` line per acceptance criterion; exit 1 if any FAILs.
"""
import hashlib
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
LIVE_ID = 1                     # the pool entry that is the only owner of the live cookie
WRONG_HASH = "4c6cccfe207b7dcd"  # the frozen DB's hash from the 2026-11-11 21:51Z incident

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
    """Stub proxy that models a one-entry pool and records every write.

    `check_ok` is what /check answers, so "the candidate failed" is a switch. `writes` keeps
    the order: ("candidate", id), ("check", id), ("delete", id) — enough to prove both "no
    pool write at all" and "posted, checked, retired the older entries" in that order.
    """

    def __init__(self, check_ok=True):
        self.pool = [LIVE_ID]
        self.check_ok = check_ok
        self.writes = []
        self.chat_in_run = 0
        self.chat_total = 0
        self._next_id = LIVE_ID + 1
        self.pre_rows = []
        self.post_rows = []
        self._srv = None
        self._thread = None
        self.port = None

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
                    return self._send(200, {"items": [{"id": i, "label": "wojtek-ai-pro"}
                                                      for i in stub.pool],
                                            "enabled": len(stub.pool)})
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
                    new_id = stub._next_id
                    stub._next_id += 1
                    stub.pool.append(new_id)
                    stub.writes.append(("candidate", new_id))
                    return self._send(200, {"id": new_id})
                m = re.match(r"^/admin/api/cookies/([^/]+)/check$", path)
                if m:
                    stub.writes.append(("check", int(m.group(1))))
                    return self._send(200, {"ok": bool(stub.check_ok)})
                return self._send(404, {"error": "no POST route %s" % path})

            def do_DELETE(self):
                n = int(self.headers.get("Content-Length") or 0)
                if n:
                    self.rfile.read(n)
                m = re.match(r"^/admin/api/cookies/([^/]+)$", self.path.partition("?")[0])
                if m:
                    cid = int(m.group(1))
                    stub.writes.append(("delete", cid))
                    if cid in stub.pool:
                        stub.pool.remove(cid)
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

    # ---- what the ACs ask about ----
    def candidates(self):
        return [w for w in self.writes if w[0] == "candidate"]

    def checks(self):
        return [w for w in self.writes if w[0] == "check"]

    def deletes(self):
        return [w for w in self.writes if w[0] == "delete"]

    def describe(self):
        return "writes=%r pool=%r" % (self.writes, self.pool)


def guard_cookie_hash():
    """The `cookie_hash` the OLD decision compares: sha256(fingerprint(harvested))[:16].

    Computed through guard.py's own `fingerprint()` (exec'd, not imported: no __pycache__), so
    this test cannot drift from the production identity. The fixed guard is expected to ignore
    it — that is exactly the point of AC-5's second case.
    """
    ns = {"__name__": "guard_under_test"}
    path = GUARD
    exec(compile(open(path).read(), path, "exec"), ns)
    fp = ns.get("fingerprint")
    if not callable(fp):
        return None
    ck = "; ".join("%s=%s" % (c, "stub-value-not-a-real-cookie-" + c) for c in COOKIES)
    return hashlib.sha256(fp(ck).encode()).hexdigest()[:16]


def log_row(row_id, status, upstream):
    return {"id": row_id, "model": CANARY_MODEL, "status": status,
            "upstream_model": upstream, "total_ms": 1200, "error": "",
            "ts": int(time.time())}


def db_path(ws):
    return ws["cookies_sqlite"]


def stat_db(ws):
    s = os.stat(db_path(ws))
    return {"mtime": s.st_mtime, "size": s.st_size}


def new_workspace(root, name):
    """A temp dir that is GUARD_DIR, a fake HOME with a Firefox cookie DB, a docker stub."""
    d = os.path.join(root, name)
    home = os.path.join(d, "home")
    prof = os.path.join(home, "Library", "Application Support", "Firefox", "Profiles",
                        "abc123.default-release")
    os.makedirs(prof)
    ck = os.path.join(prof, "cookies.sqlite")
    con = sqlite3.connect(ck)
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
            "state": os.path.join(d, "cookie_guard_state.json"),
            "cookies_sqlite": ck}


def quiet_state(now, **over):
    """A healthy, already-announced state so nothing but the import block can print.

    Every `speak()` key is pre-seeded with its healthy value: the guard re-speaks a changed
    state, so a seeded one keeps stdout empty and leaves the import block as the only thing
    under test.
    """
    st = {"entitlement": "ok", "last_upstream": "4 Argon",
          "checked_at": now, "last_sample_at": now, "last_canary": now - 1800,
          "healthy_since": now - 90000, "degraded_accum_s": 0,
          "engine": "ok", "engine_at": now, "proxy": "ok", "proxy_at": now,
          "pin": "ok", "pin_at": now, "clock": "ok", "clock_at": now,
          "container": "unhealthy-restarted", "container_at": now,
          "artifact_streak": "ok", "artifact_streak_at": now}
    st.update(over)
    return st


def seed(ws, state):
    with open(ws["state"], "w") as f:
        json.dump(state, f)


def read_state(ws):
    if not os.path.exists(ws["state"]):
        return {}
    with open(ws["state"]) as f:
        return json.load(f)


def run_guard(ws, stub):
    stub.begin_run()
    stub.pre_rows = []
    stub.post_rows = [log_row(101, 200, "4 Argon")]
    env = dict(os.environ)
    env.pop("GUARD_SKIP_COOKIES", None)
    env.update({
        "HOME": ws["home"],
        "GUARD_DIR": ws["dir"],
        "GUARD_STATE": ws["state"],
        "GUARD_DOCKER": ws["docker"],
        "GUARD_PROXY": "http://127.0.0.1:%d" % stub.port,
    })
    proc = subprocess.run([sys.executable, GUARD], capture_output=True, text=True,
                          timeout=180, env=env)
    lines = [l.strip() for l in (proc.stdout or "").splitlines() if l.strip()]
    return {"rc": proc.returncode, "lines": lines,
            "stderr": (proc.stderr or "").strip()}


def same_db(recorded, actual):
    """Does a recorded import_db describe the DB on disk right now?"""
    if not isinstance(recorded, dict):
        return False
    try:
        return (abs(float(recorded.get("mtime")) - float(actual["mtime"])) < 0.000001
                and int(recorded.get("size")) == int(actual["size"]))
    except (TypeError, ValueError):
        return False


FROZEN_REASON = re.compile(r"firefox\s+db", re.I)
EXPIRE_LINE = re.compile(r"not a valid login|session expired|browser session", re.I)


def readme_reason():
    try:
        text = open(README).read()
    except OSError as exc:
        return ["README unreadable: %r" % (exc,)]
    paras = [p for p in re.split(r"\n\s*\n", text)
             if re.search(r"cookies\.sqlite|cookie\s+DB", p, re.I)]
    if not paras:
        return ["README never names the cookie DB file (cookies.sqlite)"]
    sec = "\n".join(paras).lower()
    why = []
    if not re.search(r"mtime|modified|last write", sec):
        why.append("the cookie-DB section does not say the file's mtime/size is what is watched")
    if not re.search(r"\bhash\b", sec):
        why.append("the cookie-DB section never mentions the cookie hash it replaces")
    if not re.search(r"(not|rather than|instead of|never)[^.]{0,100}hash", sec):
        why.append("the cookie-DB section does not state that the DB file, NOT the hash, "
                   "decides an import")
    if not re.search(r"silent|stays quiet|no output", sec):
        why.append("the cookie-DB section does not say a stale DB is silent")
    if not re.search(r"never (alarms?|speaks?)|no alarm|does not alarm|never raises", sec):
        why.append("the cookie-DB section does not say a stale DB never alarms")
    return why


def main():
    results = {}

    def record(ac, why, good):
        results[ac] = (not why, "; ".join(why) if why else good)

    if not os.path.isfile(GUARD):
        sys.stderr.write("setup error: %s is missing\n" % GUARD)
        return 2

    root = tempfile.mkdtemp(prefix="gemini-guard-frozen-db-")
    stubs = []
    try:
        # ---------------------------------------------------------------- AC-1, AC-2
        # The 2026-11-11 21:51Z shape: Firefox quit, the DB frozen, cookie_hash deliberately
        # wrong (the frozen DB's own hash). One run must not touch the pool at all.
        stub = Stub(check_ok=True)
        stub.start()
        stubs.append(stub)
        ws = new_workspace(root, "frozen")
        t0 = int(time.time())
        base_db = stat_db(ws)
        seed(ws, quiet_state(t0, cookie_hash=WRONG_HASH, import_db=dict(base_db)))
        run = run_guard(ws, stub)
        st = read_state(ws)

        why1 = []
        if run["rc"] != 0:
            why1.append("guard exited %r" % (run["rc"],))
        if run["lines"]:
            why1.append("stdout was not silent: %r" % ([l[:120] for l in run["lines"]],))
        if stub.pool != [LIVE_ID]:
            why1.append("pool is %r, want exactly the live entry [%d] (%s)"
                        % (stub.pool, LIVE_ID, stub.describe()))
        if int(st.get("healthy_since") or 0) != t0 - 90000:
            why1.append("healthy_since moved to %r; an unchanged DB must leave it untouched"
                        % (st.get("healthy_since"),))
        record("AC-1", why1, "rc 0, silent stdout, one pool entry, healthy_since untouched")

        why2 = []
        if stub.writes:
            why2.append("the run wrote to the pool: %r" % (stub.writes,))
        reason = str(st.get("import_skipped_reason") or "")
        if not reason:
            why2.append("no import_skipped_reason recorded")
        elif not FROZEN_REASON.search(reason):
            why2.append("import_skipped_reason does not name the frozen/unchanged DB: %r"
                        % (reason[:160],))
        elif str(int(base_db["mtime"])) not in reason:
            why2.append("import_skipped_reason does not name the DB's recorded mtime %d: %r"
                        % (int(base_db["mtime"]), reason[:160]))
        if not same_db(st.get("import_db"), base_db):
            why2.append("import_db is %r, want the unchanged baseline %r"
                        % (st.get("import_db"), base_db))
        record("AC-2", why2, "no pool write; import_skipped_reason names the frozen DB; "
                             "import_db untouched")

        # ---------------------------------------------------------------- AC-3
        # The browser writes a fresh login: the DB's mtime moves past the recorded import.
        stub3 = Stub(check_ok=True)
        stub3.start()
        stubs.append(stub3)
        ws3 = new_workspace(root, "fresh")
        now3 = int(time.time())
        old_mtime = now3 - 86400
        os.utime(db_path(ws3), (old_mtime, old_mtime))
        size3 = os.stat(db_path(ws3)).st_size
        seed(ws3, quiet_state(now3, cookie_hash=WRONG_HASH,
                              import_db={"mtime": old_mtime - 3600, "size": size3}))
        new_mtime = now3 + 7200
        os.utime(db_path(ws3), (new_mtime, new_mtime))
        fresh = stat_db(ws3)
        run3 = run_guard(ws3, stub3)
        st3 = read_state(ws3)

        why3 = []
        cand = stub3.candidates()
        if not cand:
            why3.append("no candidate posted (%s)" % (stub3.describe(),))
        if not stub3.checks():
            why3.append("/check was never called on the candidate")
        if cand and stub3.checks() and stub3.checks()[0][1] != cand[0][1]:
            why3.append("/check was called on %r, not the posted candidate %r"
                        % (stub3.checks()[0][1], cand[0][1]))
        if not any(w[1] == LIVE_ID for w in stub3.deletes()):
            why3.append("the older pool entry %d was never retired (%s)"
                        % (LIVE_ID, stub3.describe()))
        if cand and stub3.checks() and (stub3.writes.index(cand[0])
                                        > stub3.writes.index(stub3.checks()[0])):
            why3.append("candidate was /check'ed before it was posted")
        if fresh["mtime"] == old_mtime:
            why3.append("the test could not move the DB mtime (os.utime had no effect)")
        if not same_db(st3.get("import_db"), fresh):
            why3.append("import_db is %r, want the new DB %r" % (st3.get("import_db"), fresh))
        if st3.get("cookie_hash") == WRONG_HASH:
            why3.append("cookie_hash still the pre-import value %r" % (WRONG_HASH,))
        if run3["rc"] != 0:
            why3.append("guard exited %r" % (run3["rc"],))
        record("AC-3", why3, "candidate posted, /check called, old entry retired, new "
                             "mtime/size recorded")

        # ---------------------------------------------------------------- AC-4
        # A pre-change state file: no import_db. Adopt the DB as baseline, never import, never
        # alarm. /check is set to fail, so an import would speak and be caught.
        stub4 = Stub(check_ok=False)
        stub4.start()
        stubs.append(stub4)
        ws4 = new_workspace(root, "baseline")
        now4 = int(time.time())
        seed(ws4, quiet_state(now4, cookie_hash=WRONG_HASH))
        base4 = stat_db(ws4)
        first = run_guard(ws4, stub4)
        st4 = read_state(ws4)
        second = run_guard(ws4, stub4)
        st4b = read_state(ws4)

        why4 = []
        for label, res in (("baseline run", first), ("next unchanged run", second)):
            if res["rc"] != 0:
                why4.append("%s exited %r" % (label, res["rc"]))
            if res["lines"]:
                why4.append("%s was not silent: %r"
                            % (label, [l[:120] for l in res["lines"]]))
        if stub4.writes:
            why4.append("the baseline was written to the pool: %r" % (stub4.writes,))
        if not same_db(st4.get("import_db"), base4):
            why4.append("import_db is %r after the baseline run, want the current DB %r"
                        % (st4.get("import_db"), base4))
        reason4 = str(st4.get("import_skipped_reason") or "")
        if "baseline" not in reason4.lower() or "no import" not in reason4.lower():
            why4.append("import_skipped_reason is %r, want 'baseline recorded, no import'"
                        % (reason4[:160],))
        if not same_db(st4b.get("import_db"), base4):
            why4.append("the next unchanged run changed import_db to %r"
                        % (st4b.get("import_db"),))
        if any(w[1] == LIVE_ID for w in stub4.deletes()):
            why4.append("the baseline run retire the live entry (%s)" % (stub4.describe(),))
        record("AC-4", why4, "baseline adopted with no pool write and no alarm; the next "
                             "unchanged run stayed silent")

        # ---------------------------------------------------------------- AC-5
        # The DB changed but the harvested pair is not a live login: keep what works, speak the
        # existing browser-session-expired line.
        stub5 = Stub(check_ok=False)
        stub5.start()
        stubs.append(stub5)
        ws5 = new_workspace(root, "expired")
        now5 = int(time.time())
        old5 = now5 - 86400
        os.utime(db_path(ws5), (old5, old5))
        size5 = os.stat(db_path(ws5)).st_size
        recorded5 = {"mtime": old5 - 3600, "size": size5}
        seed(ws5, quiet_state(now5, cookie_hash=WRONG_HASH, import_db=dict(recorded5)))
        moved = now5 + 3600
        os.utime(db_path(ws5), (moved, moved))
        run5 = run_guard(ws5, stub5)
        st5 = read_state(ws5)

        why5 = []
        if not stub5.candidates():
            why5.append("the changed DB was never tried (%s)" % (stub5.describe(),))
        if not stub5.checks():
            why5.append("/check was never called")
        if LIVE_ID not in stub5.pool:
            why5.append("the previous pool entry %d is gone (%s)"
                        % (LIVE_ID, stub5.describe()))
        if any(w[1] == LIVE_ID for w in stub5.deletes()):
            why5.append("a failed /check retired the working entry %d" % (LIVE_ID,))
        if not [l for l in run5["lines"] if EXPIRE_LINE.search(l)]:
            why5.append("no browser-session-expired message: %r"
                        % ([l[:120] for l in run5["lines"]],))
        if st5.get("cookie_hash") != WRONG_HASH:
            why5.append("cookie_hash became %r although the candidate failed /check"
                        % (st5.get("cookie_hash"),))
        if st5.get("import_db") != recorded5:
            why5.append("a failed /check moved import_db to %r, want the previous baseline %r"
                        % (st5.get("import_db"), recorded5))
        if run5["rc"] != 0:
            why5.append("guard exited %r" % (run5["rc"],))

        # Case 2: the FILE changed but the hash did not (Firefox rewrote the DB while only the
        # rotating cookies moved — the fingerprint excludes those). The fixed guard keys the
        # import on the file, so this is still an import: candidate, /check, and on failure the
        # same alarm. The hash-first guard decides "nothing to do" and says nothing at all.
        h_same = guard_cookie_hash()
        stub6 = Stub(check_ok=False)
        stub6.start()
        stubs.append(stub6)
        ws6 = new_workspace(root, "expired-same-hash")
        now6 = int(time.time())
        old6 = now6 - 86400
        os.utime(db_path(ws6), (old6, old6))
        size6 = os.stat(db_path(ws6)).st_size
        recorded6 = {"mtime": old6 - 3600, "size": size6}
        seed(ws6, quiet_state(now6, cookie_hash=h_same, import_db=dict(recorded6)))
        moved6 = now6 + 3600
        os.utime(db_path(ws6), (moved6, moved6))
        run6 = run_guard(ws6, stub6)
        st6 = read_state(ws6)
        if not h_same:
            why5.append("guard.py has no fingerprint() to compute the pre-change hash")
        else:
            if not stub6.candidates():
                why5.append("the DB file changed (mtime %d) but the hash was already current, "
                            "so no candidate was posted — the file, not the hash, decides an "
                            "import (%s)" % (moved6, stub6.describe()))
            if not stub6.checks():
                why5.append("no /check on the DB's candidate (hash-equal case)")
            if not [l for l in run6["lines"] if EXPIRE_LINE.search(l)]:
                why5.append("the failed /check spoke no browser-session-expired line when the "
                            "DB was newer but the hash matched: %r"
                            % ([l[:120] for l in run6["lines"]],))
            if LIVE_ID not in stub6.pool:
                why5.append("the previous pool entry %d is gone after the failed /check (%s)"
                            % (LIVE_ID, stub6.describe()))
            if st6.get("import_db") != recorded6:
                why5.append("a failed /check moved import_db to %r (hash-equal case)"
                            % (st6.get("import_db"),))
        record("AC-5", why5, "browser-session-expired line spoken, previous pool entry kept")

        # ---------------------------------------------------------------- AC-6
        why6 = readme_reason()
        record("AC-6", why6, "README says the DB file (not the hash) decides an import, and "
                             "that a stale DB is silent and never alarms")
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
