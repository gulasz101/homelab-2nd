#!/usr/bin/env python3
"""GUL-690 probe: forced tool_choice + thinking disabled against a LiteLLM route.

Reads the LiteLLM key from $LITELLM_PROBE_KEY (never printed), posts N probes to
/v1/chat/completions and reports per-probe status, timing, whether a real tool
call came back, and whether reasoning_content was present.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("PROBE_BASE", "https://llm.voitech.dev")
MODEL = os.environ.get("PROBE_MODEL", "deepseek-v4.1-flash-1017-ds")
N = int(os.environ.get("PROBE_N", "5"))
PAD_TOKENS = int(os.environ.get("PROBE_PAD_TOKENS", "21000"))
KEY = os.environ["LITELLM_PROBE_KEY"]

# ~4 chars per token of filler, so the request lands near the 21k-input-token
# repro size from GUL-476 without needing a tokenizer.
filler = ("The maintainer keeps a list of small mental models for systems work. " * 400)
filler = filler[: PAD_TOKENS * 4]

body = {
    "model": MODEL,
    "messages": [
        {"role": "system", "content": filler},
        {
            "role": "user",
            "content": "Call the search_mental_models tool with the query 'second-order effects'. "
                       "Do not answer in prose; call the tool.",
        },
    ],
    "tools": [
        {
            "type": "function",
            "function": {
                "name": "search_mental_models",
                "description": "Search the mental-model bank.",
                "parameters": {
                    "type": "object",
                    "properties": {"query": {"type": "string"}},
                    "required": ["query"],
                },
            },
        }
    ],
    "tool_choice": {"type": "function", "function": {"name": "search_mental_models"}},
    "thinking": {"type": "disabled"},
    "max_tokens": 400,
}

results = []
for i in range(1, N + 1):
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        BASE.rstrip("/") + "/v1/chat/completions",
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + KEY,
            # Cloudflare answers bare python-urllib with 403; identify ourselves.
            "User-Agent": "gul690-probe/1.0 (homelab-2nd)",
        },
    )
    t0 = time.time()
    status, payload, err = None, None, None
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            status = r.status
            payload = json.loads(r.read())
    except urllib.error.HTTPError as e:
        status = e.code
        try:
            payload = json.loads(e.read())
        except Exception:
            payload = {"raw": "<unparseable>"}
    except Exception as e:  # network/timeout
        err = repr(e)
    dt = time.time() - t0

    calls = 0
    reasoning = None
    if isinstance(payload, dict) and payload.get("choices"):
        first = payload["choices"][0]
        msg = (first.get("message") or {}) if isinstance(first, dict) else {}
        calls = len(msg.get("tool_calls") or [])
        rc = msg.get("reasoning_content")
        reasoning = (len(rc) if isinstance(rc, str) else rc)
    detail = ""
    if status != 200:
        detail = json.dumps(payload)[:400] if payload else (err or "")
    results.append(
        {
            "probe": i,
            "status": status,
            "seconds": round(dt, 2),
            "tool_calls": calls,
            "reasoning_content": reasoning,
            "detail": detail,
        }
    )
    print(json.dumps(results[-1]), flush=True)
    time.sleep(1)

ok = sum(1 for r in results if r["status"] == 200 and r["tool_calls"] >= 1 and not r["reasoning_content"])
print(
    json.dumps(
        {
            "model": MODEL,
            "base": BASE,
            "ok_probes": ok,
            "total": len(results),
            "verdict": "PASS" if ok == len(results) else "FAIL",
        }
    )
)
sys.exit(0 if ok == len(results) else 1)
