#!/usr/bin/env python3
"""Route sweep: one minimal chat completion per route in the LiteLLM model_list.

Born in GUL-690: "every route still answers" is only meaningful as a before/after
comparison, so run it before and after a bump and diff the JSON.

Reads route names from the HelmRelease values (no hand-kept list), posts a tiny
non-streaming request to each and records HTTP status + latency. Uses the master
key from $LITELLM_SWEEP_KEY so a route cannot fail on key-scoped model access and
look like an upgrade breakage.

Usage: LITELLM_SWEEP_KEY=<master key> python3 apps/llm-hub/scripts/probe-llm-hub-routes.py \
         apps/llm-hub/litellm-helm-release.yaml out.json

Use the master key: a personal key fails key-scoped model access and looks like an
upgrade regression. Never echo the key.
"""
import concurrent.futures
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("PROBE_BASE", "https://llm.voitech.dev")
KEY = os.environ["LITELLM_SWEEP_KEY"]
TIMEOUT = int(os.environ.get("SWEEP_TIMEOUT", "45"))
WORKERS = int(os.environ.get("SWEEP_WORKERS", "4"))

src = sys.argv[1] if len(sys.argv) > 1 else "apps/llm-hub/litellm-helm-release.yaml"
out_path = sys.argv[2] if len(sys.argv) > 2 else None

text = open(src).read()
# Route names appear as "- model_name: <name>" inside proxy_config.model_list.
routes = re.findall(r"^\s+- model_name:\s*(\S+)\s*$", text, re.M)
# Keep order, drop duplicates.
seen, ordered = set(), []
for r in routes:
    if r not in seen:
        seen.add(r)
        ordered.append(r)


def probe(model):
    body = json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": "Reply with the single word: ok"}],
            "max_tokens": 16,
            "stream": False,
        }
    ).encode()
    req = urllib.request.Request(
        BASE.rstrip("/") + "/v1/chat/completions",
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + KEY,
            "User-Agent": "llm-hub-route-sweep/1.0 (homelab-2nd)",
        },
    )
    t0 = time.time()
    status, note = None, ""
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            status = r.status
    except urllib.error.HTTPError as e:
        status = e.code
        try:
            raw = e.read().decode("utf-8", "replace")
            note = json.loads(raw)["error"]["message"][:160]
        except Exception:
            note = "<unparseable body>"
    except Exception as e:
        status = 0
        note = repr(e)[:160]
    return {"route": model, "status": status, "seconds": round(time.time() - t0, 2), "note": note}


results = []
with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as ex:
    for res in ex.map(probe, ordered):
        results.append(res)
        print(json.dumps(res), flush=True)

ok = [r for r in results if r["status"] == 200]
bad = [r for r in results if r["status"] != 200]
print("\n=== summary ===")
print(f"routes={len(results)} ok={len(ok)} not_ok={len(bad)}")
for r in bad:
    print(f"FAIL {r['route']} -> {r['status']} {r['note']}")
if out_path:
    with open(out_path, "w") as fh:
        json.dump(results, fh, indent=2)
    print("written:", out_path)
