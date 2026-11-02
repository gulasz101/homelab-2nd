#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/probe-url.sh actually sends the UA it claims to send, and the trap it
# documents is real (GUL-785).
#
# Hermetic: a throwaway Python HTTP server on localhost stands in for Cloudflare
# and answers 403 / `error code: 1010` to any client whose User-Agent contains
# `Python-urllib`, and 200 to everything else. No network, no cluster, no
# secrets — safe for CI.
#
# Proves three things:
#   1. the trap reproduces: urllib's default client gets 403 from the stand-in;
#   2. the helper passes:    scripts/probe-url.sh gets 200 from the same server;
#   3. the helper is honest: probing with UA='Python-urllib/3.15' fails (exit 1),
#      so a green result is the header's doing, not the script lying.
#
# Discovered and run by scripts/check.sh, like every */tests/*-check.sh.
# Exit: 0 = every case passed, 1 = at least one failed.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/scripts/probe-url.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null' EXIT

fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
head1() { printf '\n== %s\n' "$1"; }

[ -f "$SCRIPT" ] && ok "scripts/probe-url.sh exists" || { bad "scripts/probe-url.sh missing"; exit 1; }
bash -n "$SCRIPT" && ok "passes bash -n" || bad "bash -n failed"

# ---- the stand-in edge -----------------------------------------------------
cat > "$WORK/edge.py" <<'PY'
import http.server
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ua = self.headers.get("User-Agent", "")
        if "Python-urllib" in ua:
            body = b"error code: 1010\n"
            self.send_response(403)
        else:
            body = b"ok\n"
            self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY

python3 "$WORK/edge.py" > "$WORK/port" 2>"$WORK/edge.err" &
SRV_PID=$!
port=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  port=$(head -1 "$WORK/port" 2>/dev/null)
  [ -n "$port" ] && break
  sleep 0.2
done
if [ -z "$port" ]; then
  bad "stand-in server did not start: $(head -3 "$WORK/edge.err")"
  exit 1
fi
URL="http://127.0.0.1:$port/"
ok "stand-in edge listening on $URL"

# ---- 1. the trap reproduces ------------------------------------------------
head1 "the trap"
code=$(python3 - "$URL" <<'PY'
import sys
import urllib.error
import urllib.request

URL = sys.argv[1]
req = urllib.request.Request(URL)  # no UA override: urllib adds Python-urllib/<ver>

try:
    print(urllib.request.urlopen(req, timeout=10).status)
except urllib.error.HTTPError as e:
    print(e.code)
PY
)
if [ "$code" = "403" ]; then
  ok "urllib default User-Agent gets 403 from the stand-in edge"
else
  bad "urllib default UA expected 403, got '$code'"
fi

# ---- 2. the helper passes --------------------------------------------------
head1 "the helper"
if out=$("$SCRIPT" "$URL" 2>&1); then
  case "$out" in
    200*) ok "probe-url.sh gets 200 ($(echo "$out" | cut -d' ' -f1))" ;;
    *)    bad "probe-url.sh exited 0 but printed '$out'" ;;
  esac
else
  bad "probe-url.sh failed against the stand-in edge: $out"
fi

# ---- 3. the helper is honest ----------------------------------------------
head1 "the helper does not lie"
if out=$(UA='Python-urllib/3.15' "$SCRIPT" "$URL" 2>&1); then
  bad "probe-url.sh exited 0 while sending the blocked UA: $out"
else
  case "$out" in
    403*) ok "probe-url.sh reports 403 and exits 1 when the UA is the blocked one" ;;
    *)    bad "probe-url.sh failed but printed '$out' (expected 403)" ;;
  esac
fi

head1 "result"
if [ "$fail" -eq 0 ]; then
  echo "PASS"
  exit 0
fi
echo "FAIL"
exit 1
