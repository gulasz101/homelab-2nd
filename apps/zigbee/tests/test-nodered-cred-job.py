#!/usr/bin/env python3
"""Prove the nodered-mqtt-credential Job script actually works - HAND-RUN ONLY.

Same ruling as render-check.sh in this directory: this file is deliberately NOT
listed in apps/zigbee/kustomization.yaml, so Flux never reconciles it.

WHY THIS EXISTS: the Job that seeds Node-RED's MQTT credential failed twice for two
different reasons that both looked like the same useless thing. Revision 1 was the
wrong Node-RED API call; revision 2 was the right call running on
`curlimages/curl:8.11.0`, an image with no python3 at all, which died with
`/bin/sh: python3: not found`. Neither failure was visible by reading the manifest.

So this extracts the python program VERBATIM out of the Job manifest's `command:`
block scalar, points it at a fake Node-RED admin API, and asserts what actually
ARRIVED at the server. Same discipline as build/openchamber/test-proxy-strip.mjs:
test the wire, not the source. If the manifest's base URL or command shape changes,
the extraction asserts fail loudly rather than silently testing nothing.

Usage:  python3 apps/zigbee/tests/test-nodered-cred-job.py \
            apps/zigbee/nodered-mqtt-credential-job.yaml
Exit:   0 = all assertions passed, 1 = at least one failed
"""
import json
import re
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MANIFEST = sys.argv[1] if len(sys.argv) > 1 else "apps/zigbee/nodered-mqtt-credential-job.yaml"
TEST_PASSWORD = "NOT-A-REAL-PASSWORD-just-a-test-value"
BROKER_ID = "c1ecb8b21360de2b"
REV_IN = "rev-abc123"

# ---------------------------------------------------------------- extract
lines = open(MANIFEST).read().split("\n")
start = None
indent = 0
for i, ln in enumerate(lines):
    if re.match(r"^\s+- \|$", ln):
        start = i + 1
        indent = len(ln) - len(ln.lstrip())
        break
if start is None:
    sys.exit("FAIL: no block scalar found in the manifest")
script_lines = []
for ln in lines[start:]:
    if ln.strip() == "":
        script_lines.append("")
        continue
    if len(ln) - len(ln.lstrip()) < indent + 2:
        break
    script_lines.append(ln[indent + 2:])
script = "\n".join(script_lines).rstrip() + "\n"

print("== extracted script: %d lines ==" % script.count("\n"))

# Point the program at the fake server. Assert the substitution actually happened:
# a silent no-op here would make the test pass while testing nothing.
NR_ORIG = 'NR = "http://node-red:1880"'
NR_FAKE = 'NR = "http://127.0.0.1:1880"'
if NR_ORIG not in script:
    sys.exit("FAIL: the manifest's Node-RED base URL changed shape - update this test")
script = script.replace(NR_ORIG, NR_FAKE)
assert NR_FAKE in script

# The container image must have a python3. This test runs the script with the host
# python, so it cannot catch a bad image by itself - assert the manifest instead.
if "image: python:" not in open(MANIFEST).read():
    sys.exit("FAIL: the Job's image is not a python image (the script needs python3)")

# ---------------------------------------------------------------- fake Node-RED
received = {}


class FakeNodeRed(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002 - matches BaseHTTPRequestHandler
        pass

    def _send(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/flows":
            self.send_response(404)
            self.end_headers()
            return
        self._send({
            "rev": REV_IN,
            "flows": [
                {"id": BROKER_ID, "type": "mqtt-broker", "name": "broker"},
                {"id": "n1", "type": "inject"},
            ],
        })

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        received["path"] = self.path
        received["api_version"] = self.headers.get("Node-RED-API-Version")
        received["body"] = json.loads(self.rfile.read(n) or b"{}")
        self._send({"rev": "rev-after-write"})


srv = ThreadingHTTPServer(("127.0.0.1", 1880), FakeNodeRed)
threading.Thread(target=srv.serve_forever, daemon=True).start()
print("== fake Node-RED listening on 127.0.0.1:1880 ==")

# ---------------------------------------------------------------- run it
try:
    proc = subprocess.run(
        ["python3", "-c", script],
        capture_output=True, text=True, timeout=60,
        env={"MQTT_USER": "nodered", "MQTT_PASSWORD": TEST_PASSWORD,
             "PATH": "/usr/bin:/bin:/usr/local/bin"},
    )
    rc, out, err = proc.returncode, proc.stdout, proc.stderr
except subprocess.TimeoutExpired:
    rc, out, err = 124, "", "TIMEOUT: the script never stopped retrying"
print("== exit=%d ==" % rc)
print("-- stdout --"); print(out.rstrip())
print("-- stderr --"); print(err.rstrip())
srv.shutdown()

# ---------------------------------------------------------------- assert
fail = 0


def check(label, cond):
    global fail
    print(("  ok    " if cond else "  FAIL  ") + label)
    if not cond:
        fail = 1


print("== assertions ==")
check("script exited 0", rc == 0)
check("POST went to /flows", received.get("path") == "/flows")
check("Node-RED-API-Version: v2 header sent", received.get("api_version") == "v2")

body = received.get("body", {})
check("POST body carries the SAME rev that GET returned (no edit conflict)",
      body.get("rev") == REV_IN)

nodes = body.get("flows", [])
brokers = [n for n in nodes if n.get("type") == "mqtt-broker"]
check("exactly one mqtt-broker node sent back", len(brokers) == 1)
creds = brokers[0].get("credentials", {}) if brokers else {}
check("credential.user == 'nodered'", creds.get("user") == "nodered")
check("credential.password == the env value", creds.get("password") == TEST_PASSWORD)
check("the non-broker node survived the round trip",
      any(n.get("type") == "inject" for n in nodes))
check("password was NEVER printed to stdout/stderr",
      TEST_PASSWORD not in out and TEST_PASSWORD not in err)
check("no 'not found' interpreter/shell class of error", "not found" not in err)

print("\n== result: %s ==" % ("PASS" if fail == 0 else "FAIL"))
sys.exit(fail)
