#!/usr/bin/env bash
# AC-9 — every board read names this client in the User-Agent.
#
# Why this is a check and not a comment: with no User-Agent, urllib sends the
# stock `Python-urllib/<ver>`, Cloudflare's Browser Integrity Check in front of
# paperclip.voitech.dev answers 403 `Error 1010` ("blocked access based on your
# browser's signature"), and sweep.py exits 2 with a SetupError instead of the
# brief. Same token, same second, only the UA differs -> 200 (GUL-785,
# GUL-1638). So a request without one is a bug, and this check fails on it.
#
# Offline: urllib.request.urlopen is replaced before any request goes out, so
# this runs in CI with no board and no key.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# MAJSTER_SWEEP lets the checks be rehearsed against a stub; unset it and they
# judge the real script.
SWEEP="${MAJSTER_SWEEP:-$HERE/../sweep.py}"

fail() { printf 'AC-9: FAIL %s\n' "$1"; exit 1; }

[ -f "$SWEEP" ] || fail "agents/majster-sweep/sweep.py does not exist yet, so there is nothing to judge"

if ! REASON=$(python3 -I - "$SWEEP" <<'PY'
import importlib.util
import json
import sys
import urllib.request

path = sys.argv[1]

# Import the script as a module without running main(). `python3 -I` keeps the
# import from picking up anything in the working directory.
spec = importlib.util.spec_from_file_location("sweep_under_test", path)
module = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(module)
except Exception as exc:  # noqa: BLE001
    print("cannot import sweep.py: %s" % exc)
    sys.exit(1)

seen = []


class FakeResponse(object):
    def __init__(self, payload):
        self._data = json.dumps(payload).encode("utf-8")

    def read(self):
        return self._data

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def fake_urlopen(request, timeout=None):
    seen.append(request)
    return FakeResponse({"issues": [], "comments": [], "interactions": [], "items": []})


real_urlopen = urllib.request.urlopen
urllib.request.urlopen = fake_urlopen
try:
    source = module.ApiSource("http://127.0.0.1:9", "canary-token-value",
                              "canary-company-id")
    source.list_issues()
    source.get_issue("canary-issue-id")
    source.comments("canary-issue-id")
    source.interactions("canary-issue-id")
finally:
    urllib.request.urlopen = real_urlopen

if len(seen) != 4:
    print("4 board reads were expected, %d went out" % len(seen))
    sys.exit(1)

expected = getattr(module, "USER_AGENT", None)
if not isinstance(expected, str) or not expected.strip():
    print("sweep.py defines no USER_AGENT constant for its board reads")
    sys.exit(1)

agents = set()
for request in seen:
    agent = request.get_header("User-agent")
    if not agent:
        print("board read without a User-Agent (urllib sends Python-urllib/<ver>, "
              "which Cloudflare 403s with Error 1010): %s" % request.full_url)
        sys.exit(1)
    if "urllib" in agent.lower():
        print("User-Agent %r still names urllib, which is the blocked signature" % agent)
        sys.exit(1)
    if agent != expected:
        print("User-Agent %r is not USER_AGENT %r" % (agent, expected))
        sys.exit(1)
    if "canary" in agent:
        print("User-Agent carries an environment value: %r" % agent)
        sys.exit(1)
    agents.add(agent)

sys.exit(0)
PY
); then fail "$REASON"; fi

printf 'AC-9: PASS\n'
exit 0
