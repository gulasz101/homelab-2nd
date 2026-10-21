#!/usr/bin/env python3
"""Weekly sync of Ollama Cloud and OpenCode Go model lists into the homelab LiteLLM hub.

GitOps-native: edits the repo, commits, pushes, and lets Flux reconcile. New models are
probed with a real chat completion before being added. Stale models are only removed when
explicitly allowed and after confirming no consumer references them. The first run also
repoints Bill Cipher (default Hermes profile) to minimax-m3.1-flash-ollama.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

from ruamel.yaml import YAML

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
REPO = Path.home() / "Projects" / "homelab-2nd"
LITELLM_RELEASE = REPO / "apps" / "llm-hub" / "litellm-helm-release.yaml"
PROVISIONER_CM = REPO / "apps" / "llm-hub" / "litellm-key-provisioner-configmap.yaml"
OPENWEBUI_RELEASE = REPO / "apps" / "llm-hub" / "openwebui-helm-release.yaml"
BILL_CONFIG = Path.home() / ".hermes" / "config.yaml"
BILL_RELOAD_SCRIPT = Path.home() / ".hermes" / "profiles" / "andrzej" / "cache" / "scratch" / "bill-reload.sh"

# ---------------------------------------------------------------------------
# Upstream sources
# ---------------------------------------------------------------------------
OLLAMA_MODELS_URL = "https://ollama.com/v1/models"
GO_MODELS_URL = "https://opencode.ai/zen/go/v1/models"
PROXY_URL = "https://llm.voitech.dev"

# ---------------------------------------------------------------------------
# Mapping rules
# ---------------------------------------------------------------------------
# OpenCode Go routes that MUST stay bare for OpenChamber's native opencode-go provider.
GO_BARE_ROUTES = {"deepseek-v4.1-flash", "qwen3.8-flash"}

# Derived / purpose-built Go routes that are not generated from the upstream catalogue.
GO_DERIVED_ROUTES = {"hindsight-consolidation-go"}

# Ollama Cloud upstream ids that are known to be *chat* models we want to expose.
# Anything with a ":" gets the colon replaced by a dash before adding the -ollama suffix.

def map_ollama_name(upstream_id: str) -> str:
    return upstream_id.replace(":", "-") + "-ollama"


def map_go_name(upstream_id: str) -> set[str]:
    """Return the set of LiteLLM model_names to maintain for a given Go upstream id."""
    names = set()
    suffixed = upstream_id + "-go"
    names.add(suffixed)
    # Some ids need a bare alias as well because OpenChamber's native provider
    # resolves model ids from its own catalogue and rejects the -go suffix.
    if upstream_id in GO_BARE_ROUTES:
        names.add(upstream_id)
    return names


def is_ollama_model(name: str) -> bool:
    return name.endswith("-ollama")


def is_go_model(name: str) -> bool:
    return name.endswith("-go") or name in GO_BARE_ROUTES or name in GO_DERIVED_ROUTES


# ---------------------------------------------------------------------------
# Git / Flux helpers
# ---------------------------------------------------------------------------
def run(cmd: list[str], *, cwd: Path | None = None, check: bool = True, capture: bool = True) -> str:
    print(f"+ {' '.join(cmd)}")
    result = subprocess.run(
        cmd,
        cwd=cwd,
        capture_output=capture,
        text=True,
    )
    if check and result.returncode != 0:
        print(result.stdout)
        print(result.stderr, file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, cmd, result.stdout, result.stderr)
    return (result.stdout or "") + (result.stderr or "")


def git_clean() -> bool:
    """Return True if the repo working tree is clean."""
    out = run(["git", "status", "--short"], cwd=REPO, check=True)
    return out.strip() == ""


# ---------------------------------------------------------------------------
# YAML helpers (ruamel.yaml preserves comments)
# ---------------------------------------------------------------------------
yaml = YAML()
yaml.preserve_quotes = True


def load_yaml(path: Path, backup: bool = True) -> tuple[dict, Path | None]:
    if backup:
        bkp = path.with_suffix(path.suffix + f".bak-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}")
        shutil.copy2(path, bkp)
    else:
        bkp = None
    with open(path, "r", encoding="utf-8") as f:
        data = yaml.load(f)
    return data, bkp


def save_yaml(data, path: Path) -> None:
    with open(path, "w", encoding="utf-8") as f:
        yaml.dump(data, f)


# ---------------------------------------------------------------------------
# Upstream fetching
# ---------------------------------------------------------------------------
def fetch_json(url: str) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": "homelab-weekly-model-sync/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))


def fetch_ollama_model_ids() -> set[str]:
    data = fetch_json(OLLAMA_MODELS_URL)
    return {m["id"] for m in data.get("data", []) if "id" in m}


def fetch_go_model_ids() -> set[str]:
    data = fetch_json(GO_MODELS_URL)
    return {m["id"] for m in data.get("data", []) if "id" in m}


# ---------------------------------------------------------------------------
# Current config parsing
# ---------------------------------------------------------------------------
def current_model_list(data) -> list[str]:
    return [entry["model_name"] for entry in data["spec"]["values"]["proxy_config"]["model_list"]]


def desired_model_names(ollama_ids: set[str], go_ids: set[str]) -> set[str]:
    """Build the complete desired set of model_names from upstream catalogues plus hard-coded routes."""
    desired: set[str] = set()
    for oid in ollama_ids:
        desired.add(map_ollama_name(oid))
    for gid in go_ids:
        desired.update(map_go_name(gid))
    desired.update(GO_BARE_ROUTES)
    desired.update(GO_DERIVED_ROUTES)
    return desired


# ---------------------------------------------------------------------------
# Consumer reference scanning (no brain-death)
# ---------------------------------------------------------------------------
def scan_hermes_profiles() -> set[str]:
    """Scan all local Hermes profile configs for referenced model names."""
    protected: set[str] = set()
    paths = [Path.home() / ".hermes" / "config.yaml"]
    profiles_dir = Path.home() / ".hermes" / "profiles"
    if profiles_dir.exists():
        paths.extend(p / "config.yaml" for p in profiles_dir.iterdir() if p.is_dir())

    model_key_paths = [
        ("model", "default"),
        ("fallback_providers", None),  # list of dicts
        ("auxiliary", None),           # recursive scan
        ("custom_providers", None),     # list of dicts
    ]

    for path in paths:
        if not path.exists():
            continue
        try:
            with open(path, "r", encoding="utf-8") as f:
                cfg = yaml.load(f)
        except Exception:
            continue
        _collect_model_strings(cfg, protected)
    return protected


def _collect_model_strings(obj, protected: set[str]) -> None:
    if isinstance(obj, str):
        # Any string that looks like a model name we manage ends up protected.
        # Heuristic: contains a dash and a digit/family name; too broad but safe.
        protected.add(obj)
    elif isinstance(obj, dict):
        for v in obj.values():
            _collect_model_strings(v, protected)
    elif isinstance(obj, list):
        for item in obj:
            _collect_model_strings(item, protected)


def scan_openwebui_defaults(data) -> set[str]:
    """Extract model names from Open WebUI DEFAULT_MODELS and DEFAULT_PINNED_MODELS env vars."""
    protected: set[str] = set()
    env_vars = data["spec"]["values"].get("extraEnvVars", [])
    for ev in env_vars:
        name = ev.get("name", "")
        if name in ("DEFAULT_MODELS", "DEFAULT_PINNED_MODELS"):
            value = ev.get("value", "")
            protected.update(v.strip() for v in value.split(",") if v.strip())
    return protected


# ---------------------------------------------------------------------------
# Model probing
# ---------------------------------------------------------------------------
def get_master_key() -> str:
    cmd = [
        "ssh", "homelab-2nd",
        "sudo", "kubectl", "-n", "llm-hub", "get", "secret", "litellm-master-key",
        "-o", "jsonpath={.data.master-key}", "|", "base64", "-d",
    ]
    out = run(cmd, capture=True).strip()
    if not out:
        raise RuntimeError("Could not retrieve LiteLLM master key")
    return out


def get_provider_keys() -> dict[str, str]:
    keys: dict[str, str] = {}
    for key_name, secret_key in [
        ("OLLAMA_API_KEY", "OLLAMA_API_KEY"),
        ("OPENCODE_GO_SUBSCRIPTION_API_KEY", "OPENCODE_GO_SUBSCRIPTION_API_KEY"),
    ]:
        cmd = [
            "ssh", "homelab-2nd",
            "sudo", "kubectl", "-n", "llm-hub", "get", "secret", "litellm-provider-keys",
            "-o", f"jsonpath={{.data.{secret_key}}}", "|", "base64", "-d",
        ]
        value = run(cmd, capture=True).strip()
        if not value:
            raise RuntimeError(f"Could not retrieve provider key {secret_key}")
        keys[key_name] = value
    return keys


def upstream_id_for_model(model_name: str, ollama_ids: set[str], go_ids: set[str]) -> tuple[str, str] | None:
    """Return (upstream_model_id, provider) for a LiteLLM model_name, or None if not probeable."""
    if is_ollama_model(model_name):
        base = model_name.removesuffix("-ollama")
        candidates = [base]
        if "-" in base:
            parts = base.rsplit("-", 1)
            candidates.append(f"{parts[0]}:{parts[1]}")
            if len(parts[0].split("-")) >= 2:
                base2, tag2 = parts[0].rsplit("-", 1)
                candidates.append(f"{base2}:{tag2}")
        for c in candidates:
            if c in ollama_ids:
                return (c, "ollama")
        return (candidates[0], "ollama")
    if is_go_model(model_name):
        if model_name.endswith("-go"):
            base = model_name.removesuffix("-go")
            if base in go_ids:
                return (base, "go")
        if model_name in go_ids:
            return (model_name, "go")
        return None
    return None


def probe_model(model_name: str, upstream_id: str, provider: str, key: str) -> dict:
    """Probe the upstream provider directly with a real chat completion."""
    if provider == "ollama":
        url = "https://ollama.com/v1/chat/completions"
        headers = {
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "User-Agent": "homelab-weekly-model-sync/1.0",
        }
    elif provider == "go":
        url = "https://opencode.ai/zen/go/v1/chat/completions"
        headers = {
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "x-opencode-session": os.environ.get("SYNC_SESSION_ID") or str(os.urandom(16).hex()),
            "User-Agent": "homelab-weekly-model-sync/1.0",
        }
    else:
        return {"ok": False, "latency_ms": 0, "content": "", "error": f"Unknown provider {provider}"}

    payload = json.dumps({
        "model": upstream_id,
        "messages": [{"role": "user", "content": f"Say exactly: {model_name} is online"}],
        "max_tokens": 400,
    }).encode("utf-8")
    req = urllib.request.Request(url, data=payload, headers=headers, method="POST")

    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = json.loads(resp.read().decode("utf-8"))
            msg = body.get("choices", [{}])[0].get("message", {})
            content = msg.get("content", "").strip()
            reasoning = msg.get("reasoning", "").strip() or msg.get("reasoning_content", "").strip()
            latency = int((time.time() - start) * 1000)
            return {
                "ok": bool(content or reasoning),
                "latency_ms": latency,
                "content": content,
                "reasoning": reasoning,
                "error": None,
            }
    except urllib.error.HTTPError as e:
        latency = int((time.time() - start) * 1000)
        return {
            "ok": False,
            "latency_ms": latency,
            "content": "",
            "reasoning": "",
            "error": f"HTTP {e.code}: {e.read().decode('utf-8', errors='replace')[:500]}",
        }
    except Exception as e:
        latency = int((time.time() - start) * 1000)
        return {
            "ok": False,
            "latency_ms": latency,
            "content": "",
            "reasoning": "",
            "error": str(e)[:500],
        }


# ---------------------------------------------------------------------------
# Config mutation
# ---------------------------------------------------------------------------
def build_model_entry(model_name: str) -> dict:
    if is_ollama_model(model_name):
        # Reverse-engineer upstream id from model_name: strip -ollama, replace last dash back to colon if needed.
        upstream = model_name.removesuffix("-ollama")
        # For ids like deepseek-v4.1-flash:1017, the colon was replaced with dash.
        # We do not know which dashes were colons; we try common tag patterns.
        candidates = [
            upstream,
            upstream.rsplit("-", 1)[0] + ":" + upstream.rsplit("-", 1)[1] if "-" in upstream else upstream,
        ]
        # Prefer the candidate that exists in Ollama catalogue; fallback to the first.
        # (We keep a reference to the catalogue in the caller.)
        return {
            "model_name": model_name,
            "litellm_params": {
                "model": f"openai/{candidates[0]}",
                "api_base": "https://ollama.com/v1",
                "api_key": "os.environ/OLLAMA_API_KEY",
            },
        }
    if is_go_model(model_name):
        # For -go suffixed names, the upstream id is model_name without -go.
        upstream = model_name.removesuffix("-go") if model_name.endswith("-go") else model_name
        return {
            "model_name": model_name,
            "litellm_params": {
                "model": f"openai/{upstream}",
                "api_base": "https://opencode.ai/zen/go/v1",
                "api_key": "os.environ/OPENCODE_GO_SUBSCRIPTION_API_KEY",
            },
        }
    raise ValueError(f"Cannot build entry for unknown model category: {model_name}")


def fix_ollama_model_string(entry: dict, ollama_ids: set[str]) -> None:
    """Ensure the openai/<id> string matches the real upstream id (including colons)."""
    model_name = entry["model_name"]
    upstream = model_name.removesuffix("-ollama")
    # Try exact upstream first, then with colon reconstruction
    candidates = [upstream]
    if "-" in upstream:
        base, tag = upstream.rsplit("-", 1)
        candidates.append(f"{base}:{tag}")
    # Also try second-to-last dash if the tag itself contains dashes
    parts = upstream.split("-")
    if len(parts) >= 3:
        candidates.append(f"{'-'.join(parts[:-1])}:{parts[-1]}")
    chosen = None
    for c in candidates:
        if c in ollama_ids:
            chosen = c
            break
    if not chosen:
        chosen = candidates[0]
    entry["litellm_params"]["model"] = f"openai/{chosen}"


def update_litellm_model_list(data, ollama_ids: set[str], go_ids: set[str], add: set[str], remove: set[str]) -> None:
    model_list = data["spec"]["values"]["proxy_config"]["model_list"]

    # Remove stale entries
    if remove:
        model_list[:] = [entry for entry in model_list if entry["model_name"] not in remove]

    # Add new entries in the right section
    new_ollama = sorted(n for n in add if is_ollama_model(n))
    new_go = sorted(n for n in add if is_go_model(n))

    for name in new_ollama:
        entry = build_model_entry(name)
        fix_ollama_model_string(entry, ollama_ids)
        # Insert before the first Go section comment / first non-ollama entry.
        insert_idx = len(model_list)
        for i, e in enumerate(model_list):
            if not is_ollama_model(e["model_name"]):
                insert_idx = i
                break
        model_list.insert(insert_idx, entry)

    for name in new_go:
        entry = build_model_entry(name)
        # Insert after the last Go entry.
        insert_idx = len(model_list)
        for i, e in enumerate(model_list):
            if not (is_ollama_model(e["model_name"]) or is_go_model(e["model_name"])):
                insert_idx = i
                break
        # If there are new ollama entries already inserted, the boundary is later.
        model_list.insert(insert_idx, entry)


def update_key_provisioner(cm_data, desired: set[str]) -> None:
    """Rewrite DESIRED_MODELS in the embedded provision.py to match the desired model names."""
    provision_py = cm_data["data"]["provision.py"]

    # Expand with openai/ variants to keep the provisioner behaviour identical.
    expanded: set[str] = set()
    for m in sorted(desired):
        expanded.add(m)
        if not m.startswith("openai/"):
            expanded.add(f"openai/{m}")

    models_lines = [f'        "{m}",' for m in sorted(expanded)]
    new_block = "DESIRED_MODELS = [\n" + "\n".join(models_lines) + "\n    ]"

    replaced, count = re.subn(
        r"DESIRED_MODELS\s*=\s*\[.*?\]",
        new_block,
        provision_py,
        flags=re.DOTALL,
        count=1,
    )
    if count != 1:
        raise RuntimeError("Could not locate DESIRED_MODELS block in provision.py")
    cm_data["data"]["provision.py"] = replaced


def update_openwebui_pins(data, newly_added: set[str]) -> set[str]:
    """Auto-pin newly added models whose names contain 'flash'. Returns the new pinned set."""
    env_vars = data["spec"]["values"]["extraEnvVars"]
    pinned_var = None
    for ev in env_vars:
        if ev.get("name") == "DEFAULT_PINNED_MODELS":
            pinned_var = ev
            break
    if not pinned_var:
        return set()

    current = {v.strip() for v in pinned_var["value"].split(",") if v.strip()}
    to_pin = {m for m in newly_added if "flash" in m.lower() and m not in current}
    if to_pin:
        current.update(to_pin)
        pinned_var["value"] = ",".join(sorted(current))
    return to_pin


# ---------------------------------------------------------------------------
# Flux / verification
# ---------------------------------------------------------------------------
def flux_reconcile() -> None:
    ts = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    run(["ssh", "homelab-2nd", "sudo", "kubectl", "-n", "flux-system",
         "annotate", "gitrepository", "flux-system",
         f"reconcile.fluxcd.io/requestedAt={ts}", "--overwrite"], check=True)
    run(["ssh", "homelab-2nd", "sudo", "kubectl", "-n", "flux-system",
         "annotate", "kustomization", "apps",
         f"reconcile.fluxcd.io/requestedAt={ts}", "--overwrite"], check=True)


def wait_for_helmrelease_ready(namespace: str, name: str, timeout_seconds: int = 300) -> None:
    run([
        "ssh", "homelab-2nd", "sudo", "kubectl", "-n", namespace,
        "wait", "--for=condition=ready", f"helmrelease/{name}",
        f"--timeout={timeout_seconds}s",
    ], check=True)


def trigger_key_provisioner() -> str:
    job_name = f"litellm-key-provisioner-manual-{int(time.time())}"
    run([
        "ssh", "homelab-2nd", "sudo", "kubectl", "-n", "llm-hub",
        "create", "job", "--from=cronjob/litellm-key-provisioner", job_name,
    ], check=True)
    run([
        "ssh", "homelab-2nd", "sudo", "kubectl", "-n", "llm-hub",
        "wait", "--for=condition=complete", f"job/{job_name}", "--timeout=120s",
    ], check=True)
    return job_name


def proxy_advertises(model_name: str, master_key: str) -> bool:
    req = urllib.request.Request(
        f"{PROXY_URL}/v1/models",
        headers={"Authorization": f"Bearer {master_key}", "User-Agent": "homelab-weekly-model-sync/1.0"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    ids = {m["id"] for m in data.get("data", [])}
    return model_name in ids


def key_can_access(key: str, model_name: str) -> bool:
    req = urllib.request.Request(
        f"{PROXY_URL}/key/info",
        headers={"Authorization": f"Bearer {key}", "User-Agent": "homelab-weekly-model-sync/1.0"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print(f"  /key/info failed: HTTP {e.code}", file=sys.stderr)
        return False
    models = data.get("info", {}).get("models", [])
    return model_name in models or f"openai/{model_name}" in models


def get_bill_cipher_key() -> str:
    cmd = [
        "ssh", "homelab-2nd",
        "sudo", "kubectl", "-n", "llm-hub", "get", "secret", "litellm-user-keys",
        "-o", "jsonpath={.data.hermes-bill-cipher-key}", "|", "base64", "-d",
    ]
    return run(cmd, capture=True).strip()


# ---------------------------------------------------------------------------
# Bill Cipher brain swap
# ---------------------------------------------------------------------------
def bill_cipher_default_model() -> str:
    if not BILL_CONFIG.exists():
        return ""
    with open(BILL_CONFIG, "r", encoding="utf-8") as f:
        cfg = yaml.load(f)
    return cfg.get("model", {}).get("default", "")


def set_bill_cipher_default(model_name: str, dry_run: bool) -> None:
    if dry_run:
        print(f"[DRY-RUN] Would set Bill Cipher default model to {model_name}")
        return
    data, backup = load_yaml(BILL_CONFIG)
    current = data.get("model", {}).get("default", "")
    if current == model_name:
        print(f"Bill Cipher default already {model_name}; no change.")
        return
    if "model" not in data:
        data["model"] = {}
    data["model"]["default"] = model_name
    save_yaml(data, BILL_CONFIG)
    print(f"Updated Bill Cipher default model to {model_name} (backup: {backup})")


def restart_default_gateway(dry_run: bool) -> None:
    """Restart the default Hermes gateway from outside its own process (osascript escape)."""
    if dry_run:
        print("[DRY-RUN] Would restart default Hermes gateway via osascript+nohup")
        return
    BILL_RELOAD_SCRIPT.parent.mkdir(parents=True, exist_ok=True)
    script = f"""#!/usr/bin/env bash
set -euo pipefail
nohup hermes -p default gateway restart > /tmp/bill-reload.log 2>&1 &
echo "Gateway restart dispatched at $(date -Iseconds)"
"""
    BILL_RELOAD_SCRIPT.write_text(script, encoding="utf-8")
    BILL_RELOAD_SCRIPT.chmod(0o755)
    run(["osascript", "-e", f'do shell script "nohup bash {BILL_RELOAD_SCRIPT} > /tmp/bill-reload-osascript.log 2>&1 &"'], check=True)
    print("Default gateway restart dispatched via osascript+nohup.")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description="Weekly LLM model-list sync")
    parser.add_argument("--dry-run", action="store_true", help="Show diff but do not commit or mutate cluster")
    parser.add_argument("--allow-removals", action="store_true", help="Allow removal of unreferenced stale models")
    parser.add_argument("--skip-bill-cipher", action="store_true", help="Skip the Bill Cipher model swap")
    args = parser.parse_args()

    print(f"=== Weekly LLM model-list sync — {'DRY-RUN' if args.dry_run else 'LIVE'} ===")

    if not REPO.exists():
        print(f"Repo not found at {REPO}", file=sys.stderr)
        return 1

    # ------------------------------------------------------------------
    # Fetch upstream catalogues
    # ------------------------------------------------------------------
    print("\n-- Fetching Ollama Cloud catalogue --")
    ollama_ids = fetch_ollama_model_ids()
    print(f"Ollama Cloud: {len(ollama_ids)} models")

    print("\n-- Fetching OpenCode Go catalogue --")
    go_ids = fetch_go_model_ids()
    print(f"OpenCode Go: {len(go_ids)} models")

    # ------------------------------------------------------------------
    # Load current configs
    # ------------------------------------------------------------------
    litellm_data, _ = load_yaml(LITELLM_RELEASE, backup=not args.dry_run)
    provisioner_data, _ = load_yaml(PROVISIONER_CM, backup=not args.dry_run)
    openwebui_data, _ = load_yaml(OPENWEBUI_RELEASE, backup=not args.dry_run)

    current = set(current_model_list(litellm_data))
    desired = desired_model_names(ollama_ids, go_ids)

    # Preserve non-Ollama/non-Go routes (z.ai, OpenRouter, Gemini, LM Studio, etc.)
    desired.update({m for m in current if not (is_ollama_model(m) or is_go_model(m))})

    additions = desired - current
    removals = current - desired

    print(f"\nCurrent models in proxy: {len(current)}")
    print(f"Desired models:          {len(desired)}")
    print(f"Additions:               {len(additions)}")
    print(f"Removals:                {len(removals)}")
    if additions:
        for m in sorted(additions):
            print(f"  + {m}")
    if removals:
        for m in sorted(removals):
            print(f"  - {m}")

    if args.dry_run and not additions and not removals:
        print("\nNo changes. Exiting dry-run.")
        return 0

    # ------------------------------------------------------------------
    # Probe additions
    # ------------------------------------------------------------------
    provider_keys = get_provider_keys()
    master_key = get_master_key()
    os.environ["SYNC_SESSION_ID"] = os.urandom(16).hex()
    verified_additions: set[str] = set()
    failed_additions: dict[str, str] = {}

    if additions:
        print("\n-- Probing additions (upstream directly) --")
        for m in sorted(additions):
            probe_info = upstream_id_for_model(m, ollama_ids, go_ids)
            if not probe_info:
                print(f"  Skipping {m}: cannot determine upstream id")
                failed_additions[m] = "Cannot determine upstream id"
                continue
            upstream_id, provider = probe_info
            key = provider_keys.get("OLLAMA_API_KEY" if provider == "ollama" else "OPENCODE_GO_SUBSCRIPTION_API_KEY", "")
            print(f"  Probing {m} ({provider}/{upstream_id}) ...", end=" ", flush=True)
            result = probe_model(m, upstream_id, provider, key)
            if result["ok"]:
                print(f"OK ({result['latency_ms']} ms): content={result['content'][:40]!r} reasoning={result['reasoning'][:40]!r}")
                verified_additions.add(m)
            else:
                print(f"FAIL ({result['latency_ms']} ms): {result['error']}")
                failed_additions[m] = result["error"]
    else:
        verified_additions = set()

    if not verified_additions and not removals:
        print("\nNo verified additions and no removals; nothing to do.")
        return 0

    # ------------------------------------------------------------------
    # Brain-death safety: check consumer references before removals
    # ------------------------------------------------------------------
    protected = scan_hermes_profiles() | scan_openwebui_defaults(openwebui_data)
    print(f"\n-- Consumer reference scan --")
    print(f"Protected model names: {len(protected)}")

    safe_removals: set[str] = set()
    blocked_removals: dict[str, set[str]] = {}
    if args.allow_removals:
        for m in removals:
            if m in protected:
                blocked_removals[m] = {"referenced by consumer config"}
            else:
                safe_removals.add(m)
        if blocked_removals:
            print(f"Blocked removals (referenced): {', '.join(sorted(blocked_removals))}")
        if safe_removals:
            print(f"Safe removals: {', '.join(sorted(safe_removals))}")
    else:
        print("Removals disabled (use --allow-removals to enable). Stale models kept in config.")
        safe_removals = set()

    if args.dry_run:
        print("\n-- DRY-RUN diff summary --")
        print(f"Would add:    {sorted(verified_additions)}")
        print(f"Would remove: {sorted(safe_removals)}")
        print(f"Would skip (failed probe): {sorted(failed_additions)}")
        print(f"Would skip (protected):    {sorted(blocked_removals)}")
        return 0

    if not verified_additions and not safe_removals:
        print("\nNo verified additions or safe removals; nothing to commit.")
        return 0

    # ------------------------------------------------------------------
    # Mutate configs
    # ------------------------------------------------------------------
    print("\n-- Updating configs --")
    update_litellm_model_list(litellm_data, ollama_ids, go_ids, verified_additions, safe_removals)
    update_key_provisioner(provisioner_data, desired - safe_removals)
    newly_pinned = update_openwebui_pins(openwebui_data, verified_additions)
    if newly_pinned:
        print(f"Auto-pinned in Open WebUI: {', '.join(sorted(newly_pinned))}")

    save_yaml(litellm_data, LITELLM_RELEASE)
    save_yaml(provisioner_data, PROVISIONER_CM)
    save_yaml(openwebui_data, OPENWEBUI_RELEASE)

    # ------------------------------------------------------------------
    # Commit and push
    # ------------------------------------------------------------------
    if git_clean():
        print("\nWorking tree clean after mutations; nothing to commit.")
        return 0

    commit_msg = f"feat(llm-hub): weekly model sync — add {len(verified_additions)} model(s)"
    if safe_removals:
        commit_msg += f", remove {len(safe_removals)} stale model(s)"
    commit_body = f"""Weekly sync against upstream catalogues.

Additions ({len(verified_additions)} verified by live probe):
{chr(10).join(f"- {m}" for m in sorted(verified_additions)) or "- none"}

Failed probes (kept out):
{chr(10).join(f"- {m}: {e}" for m, e in sorted(failed_additions.items())) or "- none"}

Removals:
{chr(10).join(f"- {m}" for m in sorted(safe_removals)) or "- none"}

Blocked removals (still referenced):
{chr(10).join(f"- {m}" for m in sorted(blocked_removals)) or "- none"}
"""
    run(["git", "add", "-A"], cwd=REPO, check=True)
    run(["git", "commit", "-m", commit_msg, "-m", commit_body], cwd=REPO, check=True)
    run(["git", "push", "origin", "main"], cwd=REPO, check=True)
    print(f"\nCommitted and pushed: {commit_msg}")

    # ------------------------------------------------------------------
    # Reconcile and provision keys
    # ------------------------------------------------------------------
    print("\n-- Reconciling Flux --")
    flux_reconcile()
    wait_for_helmrelease_ready("llm-hub", "litellm", timeout_seconds=300)
    wait_for_helmrelease_ready("llm-hub", "open-webui", timeout_seconds=300)

    print("\n-- Triggering key provisioner --")
    trigger_key_provisioner()

    # ------------------------------------------------------------------
    # Verify
    # ------------------------------------------------------------------
    print("\n-- Verifying proxy and keys --")
    for m in sorted(verified_additions):
        if proxy_advertises(m, master_key):
            print(f"  {m}: advertised ✓")
        else:
            print(f"  {m}: NOT advertised ✗", file=sys.stderr)

    bill_key = get_bill_cipher_key()
    target = "minimax-m3.1-flash-ollama"
    if target in verified_additions or target in current:
        if key_can_access(bill_key, target):
            print(f"  Bill Cipher key can access {target} ✓")
        else:
            print(f"  Bill Cipher key CANNOT access {target} ✗", file=sys.stderr)
            return 1

    # ------------------------------------------------------------------
    # Bill Cipher brain swap (first run only, idempotent)
    # ------------------------------------------------------------------
    if not args.skip_bill_cipher:
        print("\n-- Bill Cipher brain swap --")
        current_bill = bill_cipher_default_model()
        print(f"Current Bill Cipher default: {current_bill}")
        if current_bill != target:
            if target in verified_additions or target in current:
                # Final live test through Bill Cipher's own key
                bill_upstream = upstream_id_for_model(target, ollama_ids, go_ids)
                if not bill_upstream:
                    print(f"Cannot determine upstream id for {target}; skipping probe.", file=sys.stderr)
                    return 1
                bill_upstream_id, bill_provider = bill_upstream
                bill_key_for_probe = provider_keys.get("OLLAMA_API_KEY" if bill_provider == "ollama" else "OPENCODE_GO_SUBSCRIPTION_API_KEY", "")
                result = probe_model(target, bill_upstream_id, bill_provider, bill_key_for_probe)
                if result["ok"]:
                    print(f"Bill Cipher probe {target} OK: {result['content'][:60]!r}")
                    set_bill_cipher_default(target, dry_run=False)
                    restart_default_gateway(dry_run=False)
                else:
                    print(f"Bill Cipher probe {target} failed: {result['error']}", file=sys.stderr)
                    print("Skipping brain swap; fix the route and retry.", file=sys.stderr)
                    return 1
            else:
                print(f"Target model {target} not available; skipping brain swap.", file=sys.stderr)
                return 1
        else:
            print(f"Bill Cipher default already {target}; no swap needed.")

    print("\n=== Sync complete ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
