#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-1431: the weekly model sync keeps Open WebUI honest.
#
# Before: the sync only ever ADDED pins, a pin protected its route from
# removal (so a dead pin could never go), and nothing looked at the default.
# Open WebUI kept opening on gemma-4-12b-uncensored.
#
# AC-1: prune_openwebui_pins() drops exactly the pins with no route and keeps
#       the order of the rest.
# AC-2: dead_openwebui_defaults() names a DEFAULT_MODELS entry with no route,
#       and the sync does not rewrite it (the default is the owner's choice).
# AC-3: only DEFAULT_MODELS protects a route; DEFAULT_PINNED_MODELS does not.
# AC-4: the repo as committed is clean: every Open WebUI default and pin has a
#       `model_name:` route in litellm-helm-release.yaml.
#
# Hermetic: stdlib Python only. ruamel.yaml gets a stand-in when missing, the
# same way weekly-model-sync-allowlist-check.sh does it. AC-4 reads the two
# YAML files with a line scan, not a YAML parser, so CI needs nothing extra.
#
# Exit: 0 = all pass, 1 = at least one fails.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

python3 - "$ROOT" <<'PY'
import importlib.util
import re
import sys
import types
from pathlib import Path

ROOT = Path(sys.argv[1])
SYNC = ROOT / "apps" / "llm-hub" / "scripts" / "weekly-model-sync.py"
RELEASE = ROOT / "apps" / "llm-hub" / "litellm-helm-release.yaml"
OPENWEBUI = ROOT / "apps" / "llm-hub" / "openwebui-helm-release.yaml"

failed = []
def check(ac, ok, why):
    print(("ok:   " if ok else "FAIL: ") + f"{ac} {why}")
    if not ok:
        failed.append(ac)

try:
    import ruamel.yaml  # noqa: F401
except ImportError:
    ruamel = types.ModuleType("ruamel")
    ry = types.ModuleType("ruamel.yaml")
    class YAML:  # stand-in: satisfies the import, raises on real use
        def __init__(self, *a, **k): pass
        def __getattr__(self, name): raise RuntimeError("ruamel stand-in used")
    ry.YAML = YAML
    ruamel.yaml = ry
    sys.modules["ruamel"] = ruamel
    sys.modules["ruamel.yaml"] = ry

spec = importlib.util.spec_from_file_location("weekly_model_sync", SYNC)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

def owui(default, pins):
    return {"spec": {"values": {"extraEnvVars": [
        {"name": "DEFAULT_MODELS", "value": default},
        {"name": "DEFAULT_PINNED_MODELS", "value": pins},
        {"name": "OTHER", "value": "dead-route"},
    ]}}}

routes = {"beam-free-go", "kimi-k2.7-code", "saluki-27b-local"}

# AC-1
d = owui("beam-free-go", "beam-free-go,gemma-4-12b-uncensored,kimi-k2.7-code,qwen3.8-27b-mlx,saluki-27b-local")
dropped = mod.prune_openwebui_pins(d, routes)
pins = d["spec"]["values"]["extraEnvVars"][1]["value"]
check("AC-1", dropped == {"gemma-4-12b-uncensored", "qwen3.8-27b-mlx"}
      and pins == "beam-free-go,kimi-k2.7-code,saluki-27b-local",
      f"dead pins dropped, order kept (dropped={sorted(dropped)}, pins={pins})")
d2 = owui("beam-free-go", "beam-free-go,kimi-k2.7-code")
check("AC-1", mod.prune_openwebui_pins(d2, routes) == set()
      and d2["spec"]["values"]["extraEnvVars"][1]["value"] == "beam-free-go,kimi-k2.7-code",
      "clean pins are left alone")

# AC-2
d = owui("gemma-4-12b-uncensored", "beam-free-go")
dead = mod.dead_openwebui_defaults(d, routes)
check("AC-2", dead == {"gemma-4-12b-uncensored"}, f"dead default is reported ({sorted(dead)})")
check("AC-2", d["spec"]["values"]["extraEnvVars"][0]["value"] == "gemma-4-12b-uncensored",
      "the default itself is not rewritten")
check("AC-2", mod.dead_openwebui_defaults(owui("beam-free-go", ""), routes) == set(),
      "a routed default is not reported")

# AC-3
prot = mod.scan_openwebui_defaults(owui("beam-free-go", "kimi-k2.7-code,old-pin"))
check("AC-3", prot == {"beam-free-go"}, f"only the default is protected ({sorted(prot)})")

# AC-4: the committed repo
routed = set(re.findall(r"^\s*-\s*model_name:\s*\"?([^\"\s]+)\"?\s*$", RELEASE.read_text(), re.M))
text = OPENWEBUI.read_text()
def env_value(name):
    m = re.search(r"-\s*name:\s*" + name + r"\s*\n\s*value:\s*\"([^\"]*)\"", text)
    return [v.strip() for v in m.group(1).split(",") if v.strip()] if m else None
default = env_value("DEFAULT_MODELS")
pinned = env_value("DEFAULT_PINNED_MODELS")
check("AC-4", default is not None and pinned is not None, "DEFAULT_MODELS and DEFAULT_PINNED_MODELS found")
if default is not None and pinned is not None:
    missing = sorted(set(default + pinned) - routed)
    check("AC-4", not missing, "every Open WebUI default and pin has a LiteLLM route"
          + (f" (missing: {', '.join(missing)})" if missing else ""))
    check("AC-4", default == ["beam-free-go"], f"default is beam-free-go ({default})")

sys.exit(1 if failed else 0)
PY
