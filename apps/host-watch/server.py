#!/usr/bin/env python3
"""host-watch — the off-host probe and heartbeat receiver for the M1 Air (H2-336).

Why this exists: on 2026-10-29 macOS logged the GUI session out, launchd unloaded
every user LaunchAgent on the Air, Cloudflare kept answering 502/503 because the
tunnel is a *daemon*, and nobody was told for two hours. A monitor on the host
would have died with the host, so the monitoring lives in k3s and watches the Air
from outside — two independent signals:

  1. HTTP probe  — every 60 s, three public URLs. Any answer below 500 counts as
     up (401/403 means the app is alive and guarding); 502/503 is THE signature of
     "tunnel up, origin dead". Alert after 3 consecutive failures.
  2. Heartbeat   — the Air posts every 60 s (LaunchAgent, dies with the session on
     purpose). Silence for 7 minutes means the host is logged out, asleep or off:
     the only check that survives any of those. The beat also carries per-component
     health, which is how the Hermes gateway on 127.0.0.1:8642 gets watched at all.

Stdlib only: no packages, no build step, the file is mounted from a ConfigMap and
tested by apps/host-watch/tests/hostwatch-unit-check.sh exactly as it ships.

Endpoints:
  GET  /metrics    Prometheus text
  GET  /healthz    200 when the server is up
  POST /heartbeat  JSON beat, X-Heartbeat-Token gated (fail closed when unseeded)
"""

import hmac
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

VERSION = "1.0.0"

DEFAULT_TARGETS = (
    "paperclip=https://paperclip.voitech.dev,"
    "chat=https://chat.voitech.dev,"
    "status=https://status.voitech.dev"
)

PROBE_INTERVAL = int(os.environ.get("HOSTWATCH_PROBE_INTERVAL", "60"))
PROBE_TIMEOUT = float(os.environ.get("HOSTWATCH_PROBE_TIMEOUT", "10"))
FAIL_THRESHOLD = int(os.environ.get("HOSTWATCH_FAIL_THRESHOLD", "3"))
HEARTBEAT_GRACE = int(os.environ.get("HOSTWATCH_HEARTBEAT_GRACE_SECONDS", "420"))
TOKEN_FILE = os.environ.get("HOSTWATCH_TOKEN_FILE", "/etc/host-watch/token/token")
LISTEN_PORT = int(os.environ.get("HOSTWATCH_LISTEN_PORT", "9115"))
TARGETS_SPEC = os.environ.get("HOSTWATCH_PROBE_TARGETS", DEFAULT_TARGETS)


def classify(code):
    """Turn an HTTP status (or 0 for no answer) into up/down.

    Anything below 500 is UP: a 302 to a login page, a 401 or a 403 all mean the
    origin produced a real answer. 5xx is DOWN, and that includes the 502/503
    Cloudflare emits while its tunnel is healthy and the origin is gone — treating
    a 5xx as "the site responded" is how a two-hour outage stays invisible. 0
    (timeout, DNS failure, refused) is DOWN.
    """
    if code is None:
        return False
    try:
        code = int(code)
    except (TypeError, ValueError):
        return False
    if code <= 0:
        return False
    return code < 500


def parse_targets(spec):
    """'name=url,name=url' -> [TargetState]. Blank entries are ignored."""
    targets = []
    for chunk in (spec or "").split(","):
        chunk = chunk.strip()
        if not chunk or "=" not in chunk:
            continue
        name, url = chunk.split("=", 1)
        name, url = name.strip(), url.strip()
        if name and url:
            targets.append(TargetState(name, url))
    return targets


def http_status(url, timeout=None):
    """GET url, return the HTTP status, or 0 when there was no usable answer."""
    timeout = PROBE_TIMEOUT if timeout is None else timeout
    req = Request(url, headers={"User-Agent": "host-watch/%s" % VERSION})
    try:
        with urlopen(req, timeout=timeout) as response:
            return int(response.status)
    except HTTPError as exc:      # 4xx/5xx arrive as exceptions, not responses
        return int(exc.code)
    except (URLError, OSError, ValueError):
        return 0


class TargetState:
    """One probe target and what the last probes said about it."""

    def __init__(self, name, url):
        self.name = name
        self.url = url
        self.success = None          # None = never probed; 0/1 afterwards
        self.status = 0
        self.consecutive_failures = 0
        self.duration = 0.0
        self.last_probe_ts = 0.0

    def record(self, code, duration, now=None):
        now = time.time() if now is None else now
        up = classify(code)
        self.status = int(code) if code is not None else 0
        self.duration = float(duration or 0.0)
        self.last_probe_ts = float(now)
        self.success = 1 if up else 0
        if up:
            self.consecutive_failures = 0
        else:
            self.consecutive_failures += 1
        return up

    def failing(self, threshold=FAIL_THRESHOLD):
        return self.consecutive_failures >= threshold


class HeartbeatStore:
    """Last heartbeat received, and whether we are allowed to accept one at all.

    Fail closed: no token file means every beat is rejected. A heartbeat the
    receiver cannot trust is worse than no heartbeat, because a forged or stale
    beat masks a real outage.
    """

    def __init__(self, token_file=TOKEN_FILE, grace=HEARTBEAT_GRACE):
        self.token_file = token_file
        self.grace = grace
        self.last_seen = 0.0
        self.host = ""
        self.console_user = ""
        self.components = {}
        # GUL-680: host-reported leak counters (leaked child processes). Kept
        # separate from components because "0 leaked forwards" is good news and
        # "0 components up" is bad news — same shape, opposite meaning.
        self.leaks = {}
        self.last_payload_ts = 0
        self.rejected = 0
        self.accepted = 0

    def token(self):
        try:
            with open(self.token_file, "r", encoding="utf-8") as handle:
                return handle.read().strip()
        except OSError:
            return ""

    def configured(self):
        return bool(self.token())

    def accept(self, presented):
        expected = self.token()
        if not expected:
            return False
        return hmac.compare_digest(presented or "", expected)

    def record(self, raw_payload, now=None):
        now = time.time() if now is None else now
        try:
            payload = json.loads(raw_payload)
        except (TypeError, ValueError):
            return False
        if not isinstance(payload, dict):
            return False
        self.last_seen = float(now)
        self.host = str(payload.get("host", ""))
        self.console_user = str(payload.get("console_user", ""))
        try:
            self.last_payload_ts = int(payload.get("ts", 0))
        except (TypeError, ValueError):
            self.last_payload_ts = 0
        components = payload.get("components")
        if isinstance(components, dict):
            clean = {}
            for key, value in components.items():
                clean[str(key)] = 1 if value in (True, 1, "1", "true", "up") else 0
            self.components = clean
        leaks = payload.get("leaks")
        if isinstance(leaks, dict):
            counters = {}
            for key, value in leaks.items():
                try:
                    counters[str(key)] = max(0, int(value))
                except (TypeError, ValueError):
                    continue
            self.leaks = counters
        self.accepted += 1
        return True

    def last_seen_timestamp(self):
        return float(self.last_seen or 0.0)

    def age(self, now=None):
        if not self.last_seen:
            return None
        now = time.time() if now is None else now
        return now - self.last_seen

    def stale(self, now=None):
        age = self.age(now=now)
        return age is not None and age > self.grace


def probe_once(targets, fetch=None, now=None):
    """Probe every target once. Returns how many targets answered DOWN this round.

    Down is per-round (the last probe said no) and deliberately not
    threshold-based: the alert rule owns the "3 in a row" decision, and the log
    line should say what just happened, not what will page.
    """
    fetch = http_status if fetch is None else fetch
    now = time.time() if now is None else now
    failing = 0
    for target in targets:
        started = time.time()
        code = fetch(target.url)
        up = target.record(code, time.time() - started, now=now)
        if not up:
            failing += 1
    return failing


def _fmt(value):
    """Prometheus-friendly number: ints stay ints, floats stay short."""
    if isinstance(value, int):
        return str(value)
    if float(value) == int(float(value)):
        return str(int(float(value)))
    return "%.3f" % float(value)


def render_metrics(targets, store, now=None):
    """The whole exposition, built from state. Pure: no I/O, so tests can call it."""
    now = time.time() if now is None else now
    lines = [
        "# HELP hostwatch_up 1 while the exporter is answering scrapes.",
        "# TYPE hostwatch_up gauge",
        "hostwatch_up 1",
        "# HELP hostwatch_probe_success 1 when the last probe counted as up (any HTTP < 500).",
        "# TYPE hostwatch_probe_success gauge",
    ]
    for target in targets:
        lines.append('hostwatch_probe_success{target="%s"} %d' % (target.name, target.success or 0))
    lines += [
        "# HELP hostwatch_probe_status_code HTTP status of the last probe (0 = no answer).",
        "# TYPE hostwatch_probe_status_code gauge",
    ]
    for target in targets:
        lines.append('hostwatch_probe_status_code{target="%s"} %d' % (target.name, target.status))
    lines += [
        "# HELP hostwatch_probe_consecutive_failures Failures since the last good answer.",
        "# TYPE hostwatch_probe_consecutive_failures gauge",
    ]
    for target in targets:
        lines.append('hostwatch_probe_consecutive_failures{target="%s"} %d'
                     % (target.name, target.consecutive_failures))
    lines += [
        "# HELP hostwatch_probe_duration_seconds How long the last probe took.",
        "# TYPE hostwatch_probe_duration_seconds gauge",
    ]
    for target in targets:
        lines.append('hostwatch_probe_duration_seconds{target="%s"} %s'
                     % (target.name, _fmt(round(target.duration, 3))))
    lines += [
        "# HELP hostwatch_probe_last_probe_timestamp_seconds Unix time of the last probe.",
        "# TYPE hostwatch_probe_last_probe_timestamp_seconds gauge",
    ]
    for target in targets:
        lines.append('hostwatch_probe_last_probe_timestamp_seconds{target="%s"} %s'
                     % (target.name, _fmt(round(target.last_probe_ts, 3))))
    lines += [
        "# HELP hostwatch_heartbeat_configured 1 when a token is seeded, 0 while unseeded.",
        "# TYPE hostwatch_heartbeat_configured gauge",
        "hostwatch_heartbeat_configured %d" % (1 if store.configured() else 0),
        "# HELP hostwatch_heartbeat_last_seen_timestamp_seconds Unix time of the last accepted beat.",
        "# TYPE hostwatch_heartbeat_last_seen_timestamp_seconds gauge",
        "hostwatch_heartbeat_last_seen_timestamp_seconds %s" % _fmt(round(store.last_seen_timestamp(), 3)),
        "# HELP hostwatch_heartbeat_rejected_total Beats rejected (bad token or unseeded).",
        "# TYPE hostwatch_heartbeat_rejected_total counter",
        "hostwatch_heartbeat_rejected_total %d" % store.rejected,
        "# HELP hostwatch_heartbeat_accepted_total Beats accepted.",
        "# TYPE hostwatch_heartbeat_accepted_total counter",
        "hostwatch_heartbeat_accepted_total %d" % store.accepted,
    ]
    age = store.age(now=now)
    if age is not None:
        lines += [
            "# HELP hostwatch_heartbeat_age_seconds Seconds since the last accepted beat.",
            "# TYPE hostwatch_heartbeat_age_seconds gauge",
            "hostwatch_heartbeat_age_seconds %s" % _fmt(round(age, 3)),
        ]
    lines += [
        "# HELP hostwatch_component_up Component health as reported by the host itself.",
        "# TYPE hostwatch_component_up gauge",
    ]
    for component in sorted(store.components):
        lines.append('hostwatch_component_up{component="%s"} %d'
                     % (component, store.components[component]))
    lines += [
        "# HELP hostwatch_host_leak Leaked child processes the host found still running (0 = clean).",
        "# TYPE hostwatch_host_leak gauge",
    ]
    for name in sorted(store.leaks):
        lines.append('hostwatch_host_leak{name="%s"} %d' % (name, store.leaks[name]))
    lines += [
        "# HELP hostwatch_heartbeat_host_info Identity of the last beating host.",
        "# TYPE hostwatch_heartbeat_host_info gauge",
        'hostwatch_heartbeat_host_info{host="%s",console_user="%s"} 1'
        % (store.host or "", store.console_user or ""),
    ]
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    server_version = "host-watch/" + VERSION
    targets = []
    store = None

    def _send(self, code, body, content_type="text/plain; charset=utf-8"):
        payload = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path.split("?")[0] == "/metrics":
            self._send(200, render_metrics(self.targets, self.store))
        elif self.path.split("?")[0] == "/healthz":
            self._send(200, "ok\n")
        else:
            self._send(404, "not found\n")

    def do_POST(self):
        if self.path.split("?")[0] != "/heartbeat":
            self._send(404, "not found\n")
            return
        presented = self.headers.get("X-Heartbeat-Token", "")
        if not self.store.accept(presented):
            self.store.rejected += 1
            # Loud on purpose: a mismatch here is either an unseeded token or a
            # sender with the wrong one, and either way the heartbeat is useless.
            print("heartbeat rejected (%d total): token missing/wrong or receiver unseeded"
                  % self.store.rejected, flush=True)
            self._send(401, "heartbeat rejected\n")
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > 65536:
            self._send(400, "bad length\n")
            return
        raw = self.rfile.read(length).decode("utf-8", "replace")
        if not self.store.record(raw):
            self._send(400, "bad payload\n")
            return
        self._send(202, "accepted\n")

    def log_message(self, fmt, *args):   # keep the pod log readable
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


def probe_loop(targets, interval=PROBE_INTERVAL, fetch=None):
    while True:
        failing = probe_once(targets, fetch=fetch)
        if failing:
            print("probe: %d/%d targets failing" % (failing, len(targets)), flush=True)
        time.sleep(interval)


def build():
    targets = parse_targets(TARGETS_SPEC)
    store = HeartbeatStore()
    return targets, store


def main():
    targets, store = build()
    Handler.targets = targets
    Handler.store = store
    thread = threading.Thread(target=probe_loop, args=(targets,), daemon=True)
    thread.start()
    server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    print("host-watch %s listening on :%d, %d targets every %ds, heartbeat grace %ds, token %s"
          % (VERSION, LISTEN_PORT, len(targets), PROBE_INTERVAL, HEARTBEAT_GRACE,
             "seeded" if store.configured() else "UNSEEDED (rejecting every beat)"), flush=True)
    if not store.configured():
        print("seed the token: see host/paperclip-air/RUNBOOK.md section 5", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
