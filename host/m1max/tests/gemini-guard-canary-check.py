#!/usr/bin/env python3
"""gemini-guard-canary-check.py — GUL-2167: canary timeout and the slot_leak verdict.

Two measured defects in `host/m1max/gemini-web2api/guard.py`:

  1. the canary's own POST /v1/chat/completions was killed at 120 s while a real
     `gemini-4-argon` reply takes up to ~251 s, so the sample never reached a verdict and
     `entitlement` stayed `unknown` for ever;
  2. a canary killed that way leaves its `per_ip_concurrent` slot behind (the proxy's limit
     is 2), so the NEXT run's canary is refused locally with "direct IP slot full" and the
     guard reads that self-inflicted refusal as a slow model / degraded tier.

The checks run anywhere — no Max, no Docker, no network, no Firefox, no Paperclip. Each
scenario loads guard.py as a fresh module in this process with:

  GUARD_PROXY   a fake `urllib.request.urlopen` (records the timeout the canary goes out
                with, counts the chat requests, answers the stub proxy's admin API)
  GUARD_DOCKER  a stub docker CLI in a temp dir (info / inspect / run)
  GUARD_DIR     a temp dir holding `gemini2api.env` (fake tokens) and the state file
  HOME          a temp home carrying a fake Firefox profile with a `cookies.sqlite`, so the
                guard's frozen-DB import gate is a silent skip and the canary is reached
  guard.time    a fake clock, so the 3600 s slot_leak back-off is testable without sleeping

One `AC-n: PASS|FAIL <reason>` line per acceptance criterion asked for; exit 1 if any FAILs.
`python3 -I host/m1max/tests/gemini-guard-canary-check.py AC-1` prints AC-1's line only;
with no argument every AC this file covers is printed.

Path discipline: nothing here reads $HOME, `~`, `/Users/...` or any file outside the repo —
the repo is located from this file, and every temp path comes from `tempfile.mkdtemp()`.
"""
import contextlib
import email.message
import importlib.util
import io
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import traceback
import urllib.error

sys.dont_write_bytecode = True     # never leave __pycache__ in the tracked production dir

HERE = os.path.dirname(os.path.abspath(__file__))
HOSTDIR = os.path.dirname(HERE)                                  # host/m1max
REPO = os.path.dirname(HOSTDIR)                                   # the repo root
GUARD = os.path.join(HOSTDIR, "gemini-web2api", "guard.py")
README = os.path.join(HOSTDIR, "gemini-web2api", "README.md")

# GUL-2167 AC-7: the guard checks that were already in the repo before this work order.
# AC-7 says they still pass and are not edited, so this file only RUNS them — the AC-7
# case below never writes to them.
LEGACY = ("gemini-guard-verdicts-check.py", "gemini-guard-check.sh",
          "gemini-guard-frozen-db-check.py")

# The nine names `harvest_firefox()` insists on, so the fake profile is a usable one.
COOKIES = ["SID", "HSID", "SSID", "APISID", "SAPISID",
           "__Secure-1PSID", "__Secure-1PSIDTS", "__Secure-1PAPISID", "__Secure-1PSIDCC"]

CANARY_MODEL = "gemini-4-argon"
SLOT_FULL = "direct IP slot full: concurrent limit reached"

DOCKER_STUB = """#!/bin/sh
# test stub: just enough of the docker CLI for guard.py
if [ "$1" = "info" ]; then echo "27.0.0"; exit 0; fi
if [ "$1" = "inspect" ]; then
  case "$2 $3" in
    *State.Status*) echo running ;;
    *) echo 'ghcr.io/zexadev/gemini-web2api-go@sha256:0000000000000000000000000000000000000000000000000000000000000000|unless-stopped' ;;
  esac
  exit 0
fi
if [ "$1" = "run" ]; then date +%s; exit 0; fi
exit 0
"""

_LOADED = [0]


# ---------------------------------------------------------------- workspace

def db_identity(path):
    s = os.stat(path)
    return {"mtime": s.st_mtime, "size": s.st_size}


def new_workspace(root, name):
    """GUARD_DIR + a fake HOME with a Firefox cookie DB + a docker stub, all under root."""
    d = os.path.join(root, name)
    home = os.path.join(d, "home")
    prof = os.path.join(home, "Library", "Application Support", "Firefox", "Profiles",
                        "zz123.default-release")
    os.makedirs(prof)

    db = os.path.join(prof, "cookies.sqlite")
    con = sqlite3.connect(db)
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

    return {"dir": d, "home": home, "docker": docker, "db": db,
            "state": os.path.join(d, "cookie_guard_state.json")}


def seed(ws, state):
    with open(ws["state"], "w") as f:
        json.dump(state, f)


def read_state(ws):
    try:
        with open(ws["state"]) as f:
            return json.load(f)
    except Exception:
        return {}


def steady(ws, now, **extra):
    """A settled guard state: every speak() key already at its healthy value, the DB load and
    the pool recorded, a healthy entitlement. A run over this should change nothing except
    what the scenario is about — that is what makes "changes no state" testable."""
    st = {
        "engine": "ok", "engine_at": now - 600,
        "container": "healthy", "container_at": now - 600,
        "pin": "ok", "pin_at": now - 600,
        "clock": "ok", "clock_at": now - 600,
        "proxy": "ok", "proxy_at": now - 600,
        "artifact_streak": "ok", "artifact_streak_at": now - 600,
        "cookie_hash": "seed0000seed0000",
        "import_db": db_identity(ws["db"]),
        "entitlement": "ok", "last_upstream": "4 Argon",
        "checked_at": now - 600, "last_sample_at": now - 600, "last_canary": now - 600,
        "healthy_since": now - 600, "inconclusive_samples": 0,
    }
    st.update(extra)
    return st


# ---------------------------------------------------------------- fake proxy

class FakeResponse(object):
    def __init__(self, status, obj):
        self.status = status
        if isinstance(obj, bytes):
            self._body = obj
        elif isinstance(obj, str):
            self._body = obj.encode()
        else:
            self._body = json.dumps(obj).encode()

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def log_row(row_id, status, upstream, error, when):
    return {"id": row_id, "model": CANARY_MODEL, "status": status,
            "upstream_model": upstream, "total_ms": 1200, "error": error, "ts": when}


def http_error(code, obj):
    """A real urllib HTTPError carrying the proxy's JSON body, the way a 429 arrives."""
    headers = email.message.Message()
    return urllib.error.HTTPError("http://127.0.0.1:1/v1/chat/completions", code,
                                  "Too Many Requests", headers,
                                  io.BytesIO(json.dumps(obj).encode()))


class Proxy(object):
    """The stub the guard talks to through the patched urlopen. `canary` says what the one
    chat request in the run gets: `ok` (200, paid upstream), `slot_full_429`, `timeout`."""

    def __init__(self, canary="ok"):
        self.canary = canary
        self.chat_calls = 0
        self.canary_timeout = None
        self.pre_rows = []
        self.post_rows = []
        self.calls = []

    def urlopen(self, req, timeout=None, **kwargs):
        url = getattr(req, "full_url", str(req))
        method = (getattr(req, "get_method", lambda: "GET")() or "GET").upper()
        self.calls.append({"url": url, "method": method, "timeout": timeout})
        rest = url.split("://", 1)[-1]
        path = rest[rest.find("/"):] if "/" in rest else "/"
        base, _, query = path.partition("?")

        if method == "POST" and base.endswith("/v1/chat/completions"):
            self.canary_timeout = timeout
            self.chat_calls += 1
            return self._chat()
        if base == "/":
            return FakeResponse(200, {"status": "ok", "version": "stub"})
        if base == "/health":                       # zeroclaw gateway, container_check
            return FakeResponse(200, '{"status":"ok"}')
        if base == "/admin/api/cookies":
            if method == "POST":
                return FakeResponse(200, {"id": 1})
            return FakeResponse(200, {"items": [{"id": 1}], "enabled": 1})
        if re.match(r"^/admin/api/cookies/[^/]+/check$", base):
            return FakeResponse(200, {"ok": True})
        if base.startswith("/admin/api/cookies/"):
            return FakeResponse(200, {"deleted": True})
        if base == "/admin/api/requests":
            return self._requests(query)
        return FakeResponse(404, {"error": "no route %s %s" % (method, base)})

    def _requests(self, query):
        if "model=gemini-image" in query:
            return FakeResponse(200, {"items": []})
        if "model=" in query:                       # the canary model: before/after the chat
            rows = self.post_rows if self.chat_calls else self.pre_rows
            return FakeResponse(200, {"items": rows})
        newest = (self.post_rows or self.pre_rows or [])[:1]
        return FakeResponse(200, {"items": newest})

    def _chat(self):
        if self.canary == "ok":
            self.post_rows = [log_row(101, 200, "4 Argon", "", int(time.time()) + 120)]
            return FakeResponse(200, {"choices": [{"message": {"content": "pong"}}]})
        if self.canary == "slot_full_429":
            self.post_rows = [log_row(102, 429, "", SLOT_FULL, int(time.time()) + 120)]
            raise http_error(429, {"error": SLOT_FULL})
        if self.canary == "timeout":
            self.post_rows = [log_row(103, 504, "", "context deadline exceeded")]
            raise TimeoutError("_read_status: timed out")
        raise AssertionError("unknown canary mode %r" % (self.canary,))


# ---------------------------------------------------------------- fake clock / loading

class FakeTime(object):
    """guard.time, with a clock this script owns. sleep() advances it instead of waiting."""

    def __init__(self):
        self._now = float(int(time.time()))

    def time(self):
        return self._now

    def sleep(self, seconds):
        self._now += float(seconds)

    def __getattr__(self, name):
        return getattr(time, name)


def load_guard(env_extra):
    """A fresh module object for guard.py, imported under `env_extra`."""
    for k in ("GUARD_CANARY_TIMEOUT_S", "GUARD_SKIP_COOKIES"):
        os.environ.pop(k, None)
    os.environ.update(env_extra)
    _LOADED[0] += 1
    name = "guard_under_test_%d" % _LOADED[0]
    spec = importlib.util.spec_from_file_location(name, GUARD)
    if spec is None:
        raise RuntimeError("cannot load %s" % GUARD)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def scenario(root, name, canary="ok", env_extra=None, offsets=None):
    """A fresh workspace seeded with the steady state (`offsets` are seconds from now),
    then one guard.main() run against the stub proxy and the fake clock."""
    ws = new_workspace(root, name)
    now = int(time.time())
    extra = dict((k, now + v) for k, v in (offsets or {}).items())
    return run_main(ws, steady(ws, now, **extra), canary, env_extra)


def run_main(ws, seed_state, canary="ok", env_extra=None):
    """Seed the state, then run guard.main() once against the stub proxy and fake clock."""
    seed(ws, seed_state)

    server = Proxy(canary)
    for k in ("GUARD_CANARY_TIMEOUT_S", "GUARD_SKIP_COOKIES"):
        os.environ.pop(k, None)
    os.environ.update({
        "HOME": ws["home"],
        "GUARD_DIR": ws["dir"],
        "GUARD_STATE": ws["state"],
        "GUARD_DOCKER": ws["docker"],
        "GUARD_PROXY": "http://127.0.0.1:9",
    })
    os.environ.update(env_extra or {})
    mod = load_guard(env_extra or {})
    clock = FakeTime()
    mod.time = clock

    import urllib.request
    real = urllib.request.urlopen
    urllib.request.urlopen = server.urlopen
    buf = io.StringIO()
    err = None
    try:
        with contextlib.redirect_stdout(buf):
            mod.main()
    except BaseException:
        err = traceback.format_exc(limit=6)
    finally:
        urllib.request.urlopen = real

    return {"state": read_state(ws), "seeded": seed_state,
            "lines": [l.strip() for l in buf.getvalue().splitlines() if l.strip()],
            "chat": server.chat_calls, "canary_timeout": server.canary_timeout,
            "error": err, "now": int(clock.time())}


# ---------------------------------------------------------------- small helpers

def as_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def speaks(lines, pattern, and_pattern=None):
    for line in lines:
        if re.search(pattern, line, re.I) and (and_pattern is None
                                               or re.search(and_pattern, line, re.I)):
            return line
    return ""


def diff_text(run, ignore=("import_skipped_reason",)):
    before, after = run["seeded"], run["state"]
    out = []
    for key in sorted(set(before) | set(after)):
        if key in ignore:
            continue
        if before.get(key) != after.get(key):
            out.append("%s: %r -> %r" % (key, before.get(key), after.get(key)))
    return out


def run_legacy(root):
    """Run the three existing guard checks, output hidden so their own AC lines cannot be
    mistaken for ours. Returns one (name, rc, last output line) per check.

    The environment is scrubbed: the scenarios above leave GUARD_*/HOME pointing at temp
    dirs that are gone by now, and a check must not inherit them or this machine's $HOME.
    """
    home = os.path.join(root, "legacy-home")
    tmp = os.path.join(root, "legacy-tmp")
    os.makedirs(home, exist_ok=True)
    os.makedirs(tmp, exist_ok=True)
    env = {"PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
           "HOME": home, "TMPDIR": tmp, "PYTHONDONTWRITEBYTECODE": "1"}
    out = []
    for name in LEGACY:
        path = os.path.join(HERE, name)
        if not os.path.isfile(path):
            out.append((name, 127, "missing"))
            continue
        cmd = [sys.executable, "-I", path] if name.endswith(".py") else ["bash", path]
        try:
            proc = subprocess.run(cmd, cwd=REPO, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True, timeout=900, env=env)
            tail = [l for l in proc.stdout.splitlines() if l.strip()]
            out.append((name, proc.returncode, tail[-1][:160] if tail else ""))
        except (OSError, subprocess.SubprocessError) as exc:
            out.append((name, 126, repr(exc)))
    return out


def paragraphs(text):
    out, cur, start = [], [], 1
    for i, line in enumerate(text.splitlines(), 1):
        if line.strip():
            if not cur:
                start = i
            cur.append(line)
        elif cur:
            out.append((start, "\n".join(cur)))
            cur = []
    if cur:
        out.append((start, "\n".join(cur)))
    return out


# ---------------------------------------------------------------- classify_canary_error

_UNKNOWN = object()
STATUS_NAMES = ("status", "code", "http", "http_status", "status_code", "http_code", "rc")
NOW_NAMES = ("now", "ts", "when", "at", "now_s", "now_ts", "time", "t", "epoch", "seconds")
STATE_NAMES = ("st", "state", "state_dict", "stats", "statefile", "guard_state")
TEXT_NAMES = ("text", "body", "err", "error", "message", "msg", "reason", "reply", "detail",
              "payload", "response", "exc", "exception", "e", "err_text", "status_text")


def _arg_for(param, status, text, st, now):
    n = param.lower()
    if n in STATUS_NAMES:
        return status
    if n in NOW_NAMES:
        return now
    if n in STATE_NAMES:
        return st
    if n in TEXT_NAMES:
        return text
    return _UNKNOWN


def call_classify(fn, status, text, st, now):
    """Call classify_canary_error() whatever its signature looks like.

    The AC names the function and its three verdicts but not the parameter order, so bind by
    parameter NAME first (that is exact) and fall back to the plausible positional orders.
    """
    import inspect
    tried = []
    try:
        params = [p for p in inspect.signature(fn).parameters.values()
                  if p.kind not in (p.VAR_POSITIONAL, p.VAR_KEYWORD)]
    except (TypeError, ValueError):
        params = None

    if params is not None:
        kwargs, ok = {}, True
        for p in params:
            value = _arg_for(p.name, status, text, st, now)
            if value is _UNKNOWN:
                ok = False
                break
            kwargs[p.name] = value
        if ok:
            try:
                return fn(**kwargs)
            except TypeError as exc:
                tried.append("kwargs %r: %s" % (sorted(kwargs), exc))
            except Exception as exc:
                tried.append("kwargs raised %r" % (exc,))

    for args in ((status, text, st, now), (st, now, status, text), (st, status, text, now),
                 (status, text, st), (st, status, text), (text, status, st, now),
                 (text, st, now), (status, text), (text, st)):
        try:
            return fn(*args)
        except TypeError as exc:
            tried.append("%d positional: %s" % (len(args), exc))
        except Exception as exc:
            tried.append("%d positional raised %r" % (len(args), exc))
    raise AssertionError("classify_canary_error() could not be called: "
                         + " | ".join(tried[:4]))


TIMEOUT_PAYLOADS = ("The read operation timed out",
                    TimeoutError("timed out"),
                    "canary request failed: TimeoutError('timed out')")


def err_text(status, text):
    """The error as the guard would see it: `HTTP <code>: <proxy body>` for a string. An
    implementation may key on the status argument or on the text, so both carry it."""
    if isinstance(text, str) and status:
        return "HTTP %d: %s" % (status, text)
    return text


# ---------------------------------------------------------------- the ACs

def evaluate(root, results):
    now = int(time.time())

    def record(ac, why, ok_reason):
        results[ac] = (not why, "; ".join(why) if why else ok_reason)

    # ------------------------------------------------------------ AC-1
    why = []
    for value, want in ((None, 300), ("450", 450), ("", 300),
                        ("not-a-number", 300), ("0", 300), ("-5", 300)):
        label = "unset" if value is None else repr(value)
        mod = load_guard({} if value is None else {"GUARD_CANARY_TIMEOUT_S": value})
        fn = getattr(mod, "canary_timeout_s", None)
        if not callable(fn):
            why.append("guard.py has no canary_timeout_s()")
            break
        try:
            got = fn()
        except Exception as exc:
            why.append("canary_timeout_s() raised %r with GUARD_CANARY_TIMEOUT_S=%s"
                       % (exc, label))
            continue
        if as_int(got) != want:
            why.append("GUARD_CANARY_TIMEOUT_S=%s gave %r, want %d" % (label, got, want))
    record("AC-1", why, "canary_timeout_s() reads the env var, 300 by default")

    # ------------------------------------------------------------ AC-2
    why = []
    for value, want in ((None, 600), ("450", 750)):
        label = "unset" if value is None else repr(value)
        mod = load_guard({} if value is None else {"GUARD_CANARY_TIMEOUT_S": value})
        fn = getattr(mod, "wrapper_min_budget_s", None)
        if not callable(fn):
            why.append("guard.py has no wrapper_min_budget_s()")
            break
        try:
            got = fn()
        except Exception as exc:
            why.append("wrapper_min_budget_s() raised %r with GUARD_CANARY_TIMEOUT_S=%s"
                       % (exc, label))
            continue
        if as_int(got) != want:
            why.append("wrapper_min_budget_s() with GUARD_CANARY_TIMEOUT_S=%s is %r, "
                       "want %d (timeout + 180 image + 120 margin)" % (label, got, want))

    try:
        with open(README) as f:
            readme = f.read()
    except OSError as exc:
        readme = ""
        why.append("README unreadable: %r" % (exc,))
    if readme:
        para = ""
        for _start, body in paragraphs(readme):
            if "GUARD_CANARY_TIMEOUT_S" in body and "600" in body:
                para = body
                break
        if not para:
            why.append("no README paragraph names both GUARD_CANARY_TIMEOUT_S and 600 s")
        else:
            for label, pattern in (("the Air", r"\bAir\b"), ("the cron", r"cron"),
                                   ("the SSH wrapper", r"wrapper|SSH")):
                if not re.search(pattern, para, re.I):
                    why.append("the README timeout paragraph does not name %s" % label)
    record("AC-2", why, "wrapper budget = timeout + 300 s, README names it at 600 s")

    # ------------------------------------------------------------ AC-3
    why = []
    for value, want in ((None, 300), ("450", 450)):
        label = "unset" if value is None else repr(value)
        env = {} if value is None else {"GUARD_CANARY_TIMEOUT_S": value}
        run = scenario(root, "ac3-%s" % (value or "default"), "ok", env)
        if run["error"]:
            why.append("guard.py crashed with GUARD_CANARY_TIMEOUT_S=%s:\n%s"
                       % (label, run["error"]))
            continue
        if run["chat"] != 1:
            why.append("with GUARD_CANARY_TIMEOUT_S=%s the run sent %d canary request(s), "
                       "want 1" % (label, run["chat"]))
            continue
        if as_int(run["canary_timeout"]) != want:
            why.append("with GUARD_CANARY_TIMEOUT_S=%s the canary went out with timeout=%r, "
                       "want %d" % (label, run["canary_timeout"], want))
    record("AC-3", why, "the canary is sent with canary_timeout_s(), 300 / 450")

    # ------------------------------------------------------------ AC-4
    why = []
    mod = load_guard({})
    fn = getattr(mod, "classify_canary_error", None)
    if not callable(fn):
        why.append("guard.py has no classify_canary_error()")
    else:
        # a timeout, however the implementation wants to be handed it
        verdict, rec = None, []
        for payload in TIMEOUT_PAYLOADS:
            for status in (0, 504):
                st = {}
                try:
                    got = call_classify(fn, status, err_text(status, payload), st, now)
                except AssertionError as exc:
                    rec.append(str(exc))
                    continue
                if str(got) == "timeout":
                    verdict, rec = st, []
                    break
            if verdict is not None:
                break
        if verdict is None:
            why.append("a canary timeout is not classified 'timeout'%s"
                       % (": " + rec[0] if rec else ""))
        else:
            stamp = as_int(verdict.get("canary_timeout_at"))
            if stamp is None:
                why.append("the timeout verdict did not record canary_timeout_at (state %r)"
                           % (verdict,))
            elif abs(stamp - now) > 5:
                why.append("canary_timeout_at is %d, want the sample's own clock %d"
                           % (stamp, now))

        slot_cases = (
            ("a slot-full 429 within the 7200 s window after a canary timeout",
             429, SLOT_FULL, {"canary_timeout_at": now - 100}, "slot_leak"),
            ("a slot-full 429 with no earlier canary timeout",
             429, SLOT_FULL, {}, "other"),
            ("a slot-full 429 more than 7200 s after the last canary timeout",
             429, SLOT_FULL, {"canary_timeout_at": now - 7201}, "other"),
            ("an unrelated 502 after a canary timeout",
             502, "upstream returned a failure reply", {"canary_timeout_at": now - 100},
             "other"),
        )
        for label, status, text, extra, want in slot_cases:
            st = dict(extra)
            try:
                got = call_classify(fn, status, err_text(status, text), st, now)
            except AssertionError as exc:
                why.append("%s: %s" % (label, exc))
                continue
            if str(got) != want:
                why.append("%s is %r, want %r" % (label, got, want))
            elif want == "other" and "slot_leak_until" in st:
                why.append("%s set slot_leak_until" % label)
    record("AC-4", why, "classify_canary_error(): timeout / slot_leak / other")

    # ------------------------------------------------------------ AC-5
    why = []
    run_a = scenario(root, "ac5-a", "slot_full_429", offsets={"canary_timeout_at": -120})
    if run_a["error"]:
        why.append("the slot-full 429 run crashed:\n%s" % run_a["error"])
    else:
        if run_a["chat"] != 1:
            why.append("the slot-full 429 run sent %d canary request(s), want 1"
                       % (run_a["chat"],))
        until = as_int(run_a["state"].get("slot_leak_until"))
        if until is None:
            why.append("no slot_leak_until after a slot-full 429 that followed a canary "
                       "timeout (state keys: %r)" % (sorted(run_a["state"]),))
        elif not (run_a["now"] + 3590 <= until <= run_a["now"] + 3610):
            why.append("slot_leak_until is %d, want now + 3600 (= %d)"
                       % (until, run_a["now"] + 3600))
        if as_int(run_a["state"].get("inconclusive_samples")) not in (None, 0):
            why.append("the slot_leak sample was counted as inconclusive (%r)"
                       % (run_a["state"].get("inconclusive_samples"),))
        if run_a["state"].get("entitlement") != "ok":
            why.append("the slot_leak verdict changed entitlement to %r, want the seeded 'ok'"
                       % (run_a["state"].get("entitlement"),))
        if not speaks(run_a["lines"], r"slot", r"leak|held|stuck|freed|released|drain|killed"):
            why.append("no slot_leak message spoke: %r"
                       % ([l[:100] for l in run_a["lines"]],))

        run_b = scenario(root, "ac5-b", "slot_full_429")
        if run_b["error"]:
            why.append("the no-earlier-timeout run crashed:\n%s" % run_b["error"])
        else:
            if as_int(run_b["state"].get("inconclusive_samples")) != 1:
                why.append("the slot-full 429 with no earlier timeout left "
                           "inconclusive_samples %r, want 1 (inconclusive)"
                           % (run_b["state"].get("inconclusive_samples"),))
            if run_b["state"].get("entitlement") != "unknown":
                why.append("the slot-full 429 with no earlier timeout left entitlement %r, "
                           "want 'unknown'" % (run_b["state"].get("entitlement"),))
            if "slot_leak_until" in run_b["state"]:
                why.append("the slot-full 429 with no earlier timeout still set "
                           "slot_leak_until")
            if speaks(run_b["lines"], r"slot", r"leak"):
                why.append("the slot-full 429 with no earlier timeout spoke a slot leak: %r"
                           % (speaks(run_b["lines"], r"slot", r"leak")[:120],))
    record("AC-5", why, "a slot-full 429 after a timeout is slot_leak (3600 s), else "
                        "inconclusive")

    # ------------------------------------------------------------ AC-6
    why = []
    ws_c = new_workspace(root, "ac6-a")
    backoff_seed = steady(ws_c, now, canary_timeout_at=now - 120, slot_leak_until=now + 1800)
    run_c = run_main(ws_c, backoff_seed, "ok")
    if run_c["error"]:
        why.append("the in-back-off run crashed:\n%s" % run_c["error"])
    else:
        if run_c["chat"] != 0:
            why.append("a run inside the 3600 s back-off still sent %d canary request(s)"
                       % (run_c["chat"],))
        changed = diff_text(run_c)
        if changed:
            why.append("a run inside the back-off changed state (%s)" % "; ".join(changed[:5]))
        new_canary_keys = [k for k in run_c["state"]
                           if k not in backoff_seed
                           and re.search(r"canary|leak|inconclusive|entitlement|upstream|slot",
                                         k, re.I)]
        if new_canary_keys:
            why.append("the back-off run invented canary state: %r" % (new_canary_keys,))

        ws_d = new_workspace(root, "ac6-b")
        after_seed = steady(ws_d, now, canary_timeout_at=now - 3605, slot_leak_until=now - 5)
        run_d = run_main(ws_d, after_seed, "ok")
        if run_d["error"]:
            why.append("the back-off-expired run crashed:\n%s" % run_d["error"])
        else:
            if run_d["chat"] != 1:
                why.append("a run at the end of the back-off sent %d canary request(s), "
                           "want 1" % (run_d["chat"],))
            for key in ("slot_leak_until", "canary_timeout_at"):
                if key in run_d["state"]:
                    why.append("a successful canary left %s = %r behind"
                               % (key, run_d["state"][key]))
            if run_d["state"].get("entitlement") != "ok":
                why.append("the successful canary left entitlement %r, want 'ok'"
                           % (run_d["state"].get("entitlement"),))
            if run_d["state"].get("last_upstream") != "4 Argon":
                why.append("the successful canary left last_upstream %r, want '4 Argon'"
                           % (run_d["state"].get("last_upstream"),))
    record("AC-6", why, "back-off skips silently, then one canary clears the leak state")

    # ------------------------------------------------------------ AC-7
    # The three guard checks that were here before this work order must still pass, and the
    # fix's entry points must exist — without them this AC is not decidable, and a red
    # stage that only re-ran the legacy checks would report PASS before any work was done.
    why = []
    legacy = run_legacy(root)
    broken = ["%s (rc %d: %s)" % (name, rc, tail) for name, rc, tail in legacy if rc != 0]
    if broken:
        why.append("an existing guard check failed: " + "; ".join(broken))
    mod = load_guard({})
    missing = [n for n in ("canary_timeout_s", "wrapper_min_budget_s", "classify_canary_error")
               if not callable(getattr(mod, n, None))]
    if missing:
        why.append("the existing guard checks pass (%d/%d) but guard.py has no %s, so the fix "
                   "this AC guards is not there yet"
                   % (len(legacy) - len(broken), len(legacy), ", ".join(missing)))
    record("AC-7", why, "the three existing guard checks still pass and the fix is in place")


def main(argv):
    if not os.path.isfile(GUARD):
        sys.stderr.write("setup error: %s is missing\n" % GUARD)
        return 2

    wanted = [a.upper() for a in argv[1:] if a.upper().startswith("AC-")]
    results = {}
    root = tempfile.mkdtemp(prefix="gemini-guard-canary-")
    try:
        try:
            evaluate(root, results)
        except Exception:
            sys.stderr.write("setup error while running the guard checks:\n%s\n"
                             % traceback.format_exc(limit=8))
            return 2
    finally:
        shutil.rmtree(root, ignore_errors=True)

    ids = wanted or ["AC-%d" % n for n in range(1, 8)]
    failed = 0
    for ac in ids:
        ok, reason = results.get(ac, (False, "not evaluated"))
        if ok:
            print("%s: PASS %s" % (ac, reason))
        else:
            failed += 1
            print("%s: FAIL %s" % (ac, reason))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
