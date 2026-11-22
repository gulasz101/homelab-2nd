#!/usr/bin/env python3
"""Weekly sync of Ollama Cloud and OpenCode Go model lists into the homelab LiteLLM hub.

GitOps-native: edits the repo, commits, pushes, and lets Flux reconcile. New models are
probed with a real chat completion before being added. Every route the hub already advertises
is audited the same way: a permanent upstream refusal (400/403/404/410) archives the route and
writes it to `apps/llm-hub/retired-models.yaml`, because a name nobody can call is a trap, not
inventory (GUL-2009). Quota and 5xx never remove anything.

`main` carries the `protect-main` ruleset, so the sync cannot push to it. When that push is
rejected it leaves the commit on a dated branch with a PR open and exits 4 (awaiting the
owner's merge) instead of dying half-way through the release (GUL-721).
"""

from __future__ import annotations

import argparse
import concurrent.futures
import io
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
# Derived from this file's own location (apps/llm-hub/scripts/<file>) so a git
# worktree runs the sync against ITS OWN checkout instead of the primary clone.
REPO = Path(__file__).resolve().parents[3]
LITELLM_RELEASE = REPO / "apps" / "llm-hub" / "litellm-helm-release.yaml"
PROVISIONER_CM = REPO / "apps" / "llm-hub" / "litellm-key-provisioner-configmap.yaml"
OPENWEBUI_RELEASE = REPO / "apps" / "llm-hub" / "openwebui-helm-release.yaml"
# Append-only record of every route the hub has retired or refused, with the full
# previous entry, so a model can be explained or restored months later (GUL-2009).
RETIRED_LEDGER = REPO / "apps" / "llm-hub" / "retired-models.yaml"
RETIRED_DOCS = REPO / "docs" / "llm-hub-retired-models.md"

CACHE_DIR = Path.home() / ".cache" / "weekly-model-sync"
BACKUP_DIR = CACHE_DIR / "backups"

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

# ---------------------------------------------------------------------------
# Route audit (GUL-2009)
# ---------------------------------------------------------------------------
# A route the upstream refuses is not inventory, it is a trap: `/v1/models`
# keeps advertising it and the 403 lands on whoever calls it. The sync now
# probes every route it already advertises and ARCHIVES the ones the provider
# refuses permanently - no --allow-removals flag needed, because keeping a dead
# name has never fixed a caller.
#
# The split matters: quota must never delete the catalogue. A 429 (OpenCode Go
# monthly, Ollama weekly) or a 5xx/timeout is "could not check", not "gone".
PERMANENT_FAILURE_CODES = {400, 401, 403, 404, 405, 410, 422}
TRANSIENT_FAILURE_CODES = {408, 429, 500, 502, 503, 504}
# model_name -> why a chat probe failing is expected. Keep empty unless a route
# is deliberately not a chat model; a comment per entry, never a silent pass.
ROUTE_AUDIT_EXEMPT: dict[str, str] = {}

# DeepSeek's own API (api.deepseek.com) routes end in `-ds`. DeepSeek publishes
# only a handful of ids and they do NOT follow the local route name, so the
# routes we serve are mapped explicitly: local suffix -> DeepSeek upstream id.
# Anything unmapped is resolved by stripping `-ds` and matching a live id.
DS_UPSTREAM_ALIASES = {"deepseek-v4.1-flash-1017": "deepseek-flash"}
DS_MODELS_URL = "https://api.deepseek.com/models"
DS_CHAT_URL = "https://api.deepseek.com/v1/chat/completions"


def map_ollama_name(upstream_id: str) -> str:
    return upstream_id.replace(":", "-") + "-ollama"


def map_go_name(upstream_id: str) -> set[str]:
    """Return the set of LiteLLM model_names to maintain for a given Go upstream id."""
    names = set()
    suffixed = upstream_id + "-go"
    names.add(suffixed)
    if upstream_id in GO_BARE_ROUTES:
        names.add(upstream_id)
    return names


def is_ollama_model(name: str) -> bool:
    return name.endswith("-ollama")


def is_go_model(name: str) -> bool:
    return name.endswith("-go") or name in GO_BARE_ROUTES or name in GO_DERIVED_ROUTES


def is_ds_model(name: str) -> bool:
    """True for routes on DeepSeek's own API (`-ds`).

    NOT generated from a catalogue: DeepSeek's ids are few and stable, and the
    local name carries the snapshot label (`-1017`) that DeepSeek does not
    publish. They are hand-written routes the sync preserves, probes weekly and
    reports as dead if DeepSeek stops serving the upstream id (GUL-591).
    """
    return name.endswith("-ds")


def model_category(name: str) -> str:
    if is_ollama_model(name):
        return "ollama"
    if is_go_model(name):
        return "go"
    if is_ds_model(name):
        return "ds"
    return "other"


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


def git_branch() -> str:
    """Return the current branch name."""
    return run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=REPO, check=True).strip()


def preflight() -> bool:
    """Fail fast unless the checkout can safely receive an automated commit.

    The sync commits and pushes on the operator's behalf, so it must own a clean
    `main` that matches `origin/main`. Running it on a feature branch once left a
    stray commit on that branch and then pushed a stale `main`, which was rejected
    as non-fast-forward (GUL-109).
    """
    if not git_clean():
        print(
            "Working tree is dirty. Commit or stash your changes before running the sync.",
            file=sys.stderr,
        )
        return False

    branch = git_branch()
    if branch != "main":
        print(
            f"Refusing to run on branch '{branch}'. Check out main first "
            f"(git checkout main) - the sync commits and pushes to main itself.",
            file=sys.stderr,
        )
        return False

    run(["git", "fetch", "origin", "main"], cwd=REPO, check=True)
    head = run(["git", "rev-parse", "HEAD"], cwd=REPO, check=True).strip()
    remote = run(["git", "rev-parse", "origin/main"], cwd=REPO, check=True).strip()
    if head != remote:
        print(
            "Local main is behind origin/main. Run `git pull --ff-only origin main` first.",
            file=sys.stderr,
        )
        return False

    return True


# Rejection markers GitHub puts on a push that `protect-main` blocks (observed 2026-11-01,
# GUL-721: "GH013: Repository rule violations ... Required status check \"check\" is expected").
PROTECTED_MAIN_MARKERS = (
    "GH013",
    "repository rule violations",
    "protected branch",
    "Required status check",
)


def push_to_main() -> tuple[bool, str]:
    """Push the sync commit to main. Returns (ok, combined output); never raises on refusal."""
    proc = subprocess.run(["git", "push", "origin", "main"], cwd=REPO, capture_output=True, text=True)
    return proc.returncode == 0, (proc.stdout or "") + (proc.stderr or "")


def open_sync_pr(commit_msg: str, body: str) -> str:
    """Push the commit to a dated sync branch and open its PR. Returns the PR URL.

    The owner keeps the merge button (ADR-093) and `protect-main` requires the `check`
    status, so the sync cannot land its own commit. It stops with the work reviewable
    instead of dying on a rejected push: one branch, one PR, one click.
    """
    short = run(["git", "rev-parse", "--short=7", "HEAD"], cwd=REPO, check=True).strip()
    branch = f"feat/weekly-model-sync-{datetime.now(timezone.utc).strftime('%Y-%m-%d')}-{short}"
    run(["git", "push", "-u", "origin", f"HEAD:refs/heads/{branch}"], cwd=REPO, check=True)
    url = run(
        ["gh", "pr", "create", "--base", "main", "--head", branch, "--title", commit_msg, "--body", body],
        cwd=REPO,
        check=True,
    ).strip()
    last = url.splitlines()[-1].strip() if url else ""
    if not last.startswith("http"):
        raise RuntimeError(f"gh pr create did not print a URL: {url[:200]!r}")
    return last


# ---------------------------------------------------------------------------
# YAML helpers (ruamel.yaml preserves comments)
# ---------------------------------------------------------------------------
yaml = YAML()
yaml.preserve_quotes = True


def load_yaml(path: Path, *, backup: bool = True) -> tuple[dict, Path | None]:
    if backup:
        BACKUP_DIR.mkdir(parents=True, exist_ok=True)
        bkp = BACKUP_DIR / f"{path.name}.bak-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}"
        shutil.copy2(path, bkp)
    else:
        bkp = None
    with open(path, "r", encoding="utf-8") as f:
        data = yaml.load(f)
    return data, bkp


def save_yaml(data, path: Path) -> None:
    with open(path, "w", encoding="utf-8") as f:
        yaml.dump(data, f)


def dump_yaml(data) -> str:
    """Same writer, into a string (the ledger is a generated file, not a release)."""
    buffer = io.StringIO()
    yaml.dump(data, buffer)
    return buffer.getvalue()


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


def fetch_ds_model_ids(key: str) -> set[str]:
    """DeepSeek's own catalogue (api.deepseek.com/models).

    Returns an empty set when no key is available: the `-ds` routes still resolve
    through DS_UPSTREAM_ALIASES, so a missing key degrades the dead-route check
    instead of failing the whole weekly sync.
    """
    if not key:
        print("WARN: no DEEPSEEK_API_KEY; -ds routes fall back to alias mapping")
        return set()
    req = urllib.request.Request(
        DS_MODELS_URL,
        headers={
            "Authorization": f"Bearer {key}",
            "User-Agent": "homelab-weekly-model-sync/1.0",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read().decode("utf-8"))
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


def upstream_refs(data) -> list[tuple[str, str, str]]:
    """Return (model_name, upstream_id, provider) for every catalogue-backed route."""
    refs: list[tuple[str, str, str]] = []
    for entry in data["spec"]["values"]["proxy_config"]["model_list"]:
        params = entry.get("litellm_params") or {}
        raw = str(params.get("model", ""))
        api_base = str(params.get("api_base", ""))
        if "opencode.ai" in api_base:
            provider = "go"
            upstream_id = raw.split("/", 1)[1] if raw.startswith("openai/") else raw
        elif "ollama.com" in api_base:
            provider = "ollama"
            upstream_id = raw.split("/", 1)[1] if raw.startswith("openai/") else raw
        elif raw.startswith("deepseek/"):
            # GUL-591: a DeepSeek-direct route carries no api_base (provider
            # default), so it is identified by its native provider prefix.
            provider = "ds"
            upstream_id = raw.split("/", 1)[1]
        else:
            continue  # z.ai, OpenRouter, Gemini, oneprovider... own catalogues, out of scope
        refs.append((entry["model_name"], upstream_id, provider))
    return refs


def dead_upstream_routes(data, ollama_ids: set[str], go_ids: set[str], ds_ids: set[str] | None = None) -> list[tuple[str, str, str]]:
    """Routes the sync does NOT own that point at an upstream id the catalogue no longer serves.

    The sync regenerates its own routes from the catalogue (`map_go_name` / `map_ollama_name`),
    so a retired model behind one of those is cleaned up by the weekly removals - loud enough
    already. The dangerous case is a hand-written route: its name no longer matches any
    catalogue pattern, so nothing regenerates it and nothing notices when the upstream
    withdraws the model. GUL-105: `minimax-m3.1-flash-free` was retired while a PR was in
    review, `hindsight-consolidation-go` kept "working" by failing over to its metered
    fallback, and the sync said nothing for a whole week.
    """
    dead: list[tuple[str, str, str]] = []
    for name, upstream_id, provider in upstream_refs(data):
        if provider == "go":
            live = upstream_id in go_ids
            sync_owned = name in map_go_name(upstream_id)
        elif provider == "ds":
            # `-ds` routes are hand-written by design, so nothing regenerates
            # them: report dead the moment DeepSeek stops serving the id. With no
            # DeepSeek catalogue (missing key) assume live rather than cry wolf.
            live = (not ds_ids) or upstream_id in ds_ids
            sync_owned = False
        else:
            live = upstream_id in ollama_ids or map_ollama_name(upstream_id).removesuffix("-ollama") in {
                i.replace(":", "-") for i in ollama_ids
            }
            sync_owned = name == map_ollama_name(upstream_id)
        if not live and not sync_owned:
            dead.append((name, upstream_id, provider))
    return dead


def report_dead_upstream_routes(dead: list[tuple[str, str, str]]) -> None:
    """Print the dead-route block loudly enough that a red job gets read."""
    if not dead:
        print("\n-- Upstream reference check --")
        print("OK: every catalogue-backed route points at a model the catalogue still serves.")
        return
    print("\n" + "!" * 78)
    print("!! DEAD UPSTREAM ROUTES - a route points at a model the catalogue no longer lists.")
    for name, upstream_id, provider in dead:
        print(f"!!   {name}  ->  {provider}/{upstream_id}")
    print("!! These routes still answer, because LiteLLM silently falls through to the next")
    print("!! model in router_settings.fallbacks - usually a metered or weaker one. Point them")
    print("!! at a live model in apps/llm-hub/ and retire the dead id from the key provisioner.")
    print("!! (GUL-105: minimax-m3.1-flash-free was retired under a route that never noticed.)")
    print("!" * 78)


# ---------------------------------------------------------------------------
# Key-provisioner ConfigMap editing (preserves Python comments inside DESIRED_MODELS)
# ---------------------------------------------------------------------------
_BLOCK_RE = re.compile(r"(DESIRED_MODELS\s*=\s*\[)(.*?)(\n\s*\])", re.DOTALL)
_MODEL_LINE_RE = re.compile(r'^(\s*)"((?:openai/)?[^"]+)"(\s*,?)(\s*(?:#.*)?)$')


def _parse_desired_models_block(text: str) -> tuple[str, str, str, list[dict]]:
    """Return (before, opening, closing, entries) for the DESIRED_MODELS block."""
    m = _BLOCK_RE.search(text)
    if not m:
        raise RuntimeError("Could not locate DESIRED_MODELS block in provision.py")
    before = text[: m.start()]
    opening = m.group(1)
    closing = m.group(3)
    block = m.group(2)

    entries: list[dict] = []
    for raw_line in block.splitlines():
        line = raw_line.rstrip()
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            entries.append({"kind": "other", "line": raw_line})
            continue
        mo = _MODEL_LINE_RE.match(line)
        if not mo:
            entries.append({"kind": "other", "line": raw_line})
            continue
        model_name = mo.group(2)
        entries.append({"kind": "model", "model": model_name, "line": raw_line, "indent": mo.group(1)})
    return before, opening, closing, entries


def current_provisioner_models(path: Path) -> set[str]:
    """Read the current DESIRED_MODELS set from the provisioner ConfigMap."""
    text = path.read_text(encoding="utf-8")
    _, _, _, entries = _parse_desired_models_block(text)
    return {e["model"] for e in entries if e["kind"] == "model"}


def _bare_model_id(model_name: str) -> str:
    """Strip the `openai/` alias prefix; the provisioner expands both forms itself."""
    return model_name[len("openai/") :] if model_name.startswith("openai/") else model_name


def compute_provisioner_desired(
    provisioner_current: set[str],
    routed_models: set[str],
    verified_additions: set[str],
    failed_additions: set[str],
    safe_removals: set[str],
) -> set[str]:
    """The key allowlist: only ids the proxy actually routes after this run.

    Granting a service key permission for a model the proxy cannot serve is a
    silent trap for every consumer - the request fails at LiteLLM, not at the
    key check. The old allowlist was built from every catalogue id, probed or
    not, so unresolved ids piled up and thirteen of them had no route at all
    (GUL-1096). So keep an existing id only when something routes it (the
    `openai/` alias resolves to the same route), then drop the ids this run
    retires or failed to verify, and add back only the verified additions.
    """
    routed = {_bare_model_id(m) for m in routed_models}
    # Compare removals on the bare id too: the allowlist stores some ids with an
    # `openai/` prefix, so subtracting the route names directly leaves a retired
    # route's permission behind (found by the allowlist check, GUL-2009).
    removed = {_bare_model_id(m) for m in safe_removals}
    kept = {
        m for m in provisioner_current
        if _bare_model_id(m) in routed and _bare_model_id(m) not in removed
    }
    kept -= failed_additions
    kept |= verified_additions
    return kept


def update_key_provisioner(text: str, desired: set[str]) -> str:
    """Rewrite the DESIRED_MODELS block while keeping all existing comments and ordering."""
    m = _BLOCK_RE.search(text)
    if not m:
        raise RuntimeError("Could not locate DESIRED_MODELS block in provision.py")
    before = text[: m.start()]
    opening = m.group(1)
    closing = m.group(3)
    after = text[m.end() :]
    block = m.group(2).lstrip("\n")

    entries: list[dict] = []
    for raw_line in block.splitlines():
        line = raw_line.rstrip()
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            entries.append({"kind": "other", "line": raw_line})
            continue
        mo = _MODEL_LINE_RE.match(line)
        if not mo:
            entries.append({"kind": "other", "line": raw_line})
            continue
        entries.append(
            {
                "kind": "model",
                "model": mo.group(2),
                "line": raw_line,
                "indent": mo.group(1),
            }
        )

    existing = {e["model"] for e in entries if e["kind"] == "model"}
    to_add = desired - existing
    to_remove = existing - desired

    kept = [e for e in entries if not (e["kind"] == "model" and e["model"] in to_remove)]

    for cat in ("other", "ollama", "go", "ds"):
        adds = sorted(m for m in to_add if model_category(m) == cat)
        if not adds:
            continue
        last_idx = -1
        default_indent = "        "
        for i, e in enumerate(kept):
            if e["kind"] == "model":
                default_indent = e.get("indent") or default_indent
                if model_category(e["model"]) == cat:
                    last_idx = i
        insert_idx = len(kept) if last_idx == -1 else last_idx + 1
        for m in adds:
            kept.insert(
                insert_idx,
                {"kind": "model", "model": m, "line": f'{default_indent}"{m}",'},
            )
            insert_idx += 1

    new_block = "\n".join(e["line"] for e in kept)
    return before + opening + "\n" + new_block + closing + after


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
        protected.add(obj)
    elif isinstance(obj, dict):
        for v in obj.values():
            _collect_model_strings(v, protected)
    elif isinstance(obj, list):
        for item in obj:
            _collect_model_strings(item, protected)


def scan_openwebui_defaults(data) -> set[str]:
    """Model names in Open WebUI DEFAULT_MODELS: the owner's chosen default.

    GUL-1431: DEFAULT_PINNED_MODELS no longer protects a route. A pin used to
    block the removal of the very route it pointed at, so a dead pin could
    never go away. Pins now follow the routes (prune_openwebui_pins); only the
    default is protected, because changing it is the owner's call.
    """
    protected: set[str] = set()
    env_vars = data["spec"]["values"].get("extraEnvVars", [])
    for ev in env_vars:
        if ev.get("name", "") == "DEFAULT_MODELS":
            value = ev.get("value", "")
            protected.update(v.strip() for v in value.split(",") if v.strip())
    return protected


def _openwebui_env(data, name: str):
    for ev in data["spec"]["values"].get("extraEnvVars", []):
        if ev.get("name") == name:
            return ev
    return None


def prune_openwebui_pins(data, routes: set[str]) -> set[str]:
    """Drop pins for models LiteLLM no longer routes. Returns the dropped names.

    GUL-1431: the sync only ever added pins, so Open WebUI kept showing
    gemma-4-12b-uncensored long after it stopped being a good default, and a
    route removed by hand stayed pinned forever.
    """
    pinned_var = _openwebui_env(data, "DEFAULT_PINNED_MODELS")
    if not pinned_var:
        return set()
    current = [v.strip() for v in str(pinned_var.get("value", "")).split(",") if v.strip()]
    dead = {m for m in current if m not in routes}
    if dead:
        pinned_var["value"] = ",".join(m for m in current if m not in dead)
    return dead


def dead_openwebui_defaults(data, routes: set[str]) -> set[str]:
    """DEFAULT_MODELS entries with no LiteLLM route. Reported, never rewritten."""
    return {m for m in scan_openwebui_defaults(data) if m not in routes}


# ---------------------------------------------------------------------------
# Cluster access
# ---------------------------------------------------------------------------
# GUL-1431: the sync used `ssh homelab-2nd sudo kubectl ...`. The Clevo node
# `homelab-2nd.local` was retired on 2026-11-12 (control plane moved to
# mimir), so that hostname no longer resolves and every run would die on its
# first secret read. The Air has its own kubeconfig (~/.kube/config ->
# https://192.168.1.179:6443), so kubectl runs locally. SYNC_KUBECTL overrides
# the command (space-separated), e.g. for a different kubeconfig.
KUBECTL = os.environ.get("SYNC_KUBECTL", "kubectl").split()


def kubectl(*args: str) -> list[str]:
    return [*KUBECTL, *args]


def read_secret_value(namespace: str, secret: str, key: str) -> str:
    """Decoded value of one Secret key, '' when absent. Never printed."""
    import base64
    jsonpath = "{.data." + key.replace(".", "\\.") + "}"
    print(f"+ {' '.join(kubectl('-n', namespace, 'get', 'secret', secret, '-o', 'jsonpath=' + jsonpath))}")
    result = subprocess.run(
        kubectl("-n", namespace, "get", "secret", secret, "-o", f"jsonpath={jsonpath}"),
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, result.args, "", result.stderr)
    raw = result.stdout.strip()
    return base64.b64decode(raw).decode("utf-8").strip() if raw else ""


# ---------------------------------------------------------------------------
# Model probing
# ---------------------------------------------------------------------------
def get_master_key() -> str:
    out = read_secret_value("llm-hub", "litellm-master-key", "master-key")
    if not out:
        raise RuntimeError("Could not retrieve LiteLLM master key")
    return out


def get_provider_keys() -> dict[str, str]:
    keys: dict[str, str] = {}
    for key_name, secret_key in [
        ("OLLAMA_API_KEY", "OLLAMA_API_KEY"),
        ("OPENCODE_GO_SUBSCRIPTION_API_KEY", "OPENCODE_GO_SUBSCRIPTION_API_KEY"),
        # GUL-591: DeepSeek's own API, paying on Wojtek's key.
        ("DEEPSEEK_API_KEY", "DEEPSEEK_API_KEY"),
    ]:
        value = read_secret_value("llm-hub", "litellm-provider-keys", secret_key)
        if not value:
            if key_name == "DEEPSEEK_API_KEY":
                # The -ds routes are opt-in: a missing key must not break the
                # weekly sync for the Ollama/Go catalogues.
                print("WARN: DEEPSEEK_API_KEY missing from litellm-provider-keys")
                keys[key_name] = ""
                continue
            raise RuntimeError(f"Could not retrieve provider key {secret_key}")
        keys[key_name] = value
    return keys


def upstream_id_for_model(
    model_name: str, ollama_ids: set[str], go_ids: set[str], ds_ids: set[str] | None = None
) -> tuple[str, str] | None:
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
    if is_ds_model(model_name):
        # Local name carries the snapshot label DeepSeek does not publish, so
        # resolve through the explicit alias map first (GUL-591).
        base = model_name.removesuffix("-ds")
        return (DS_UPSTREAM_ALIASES.get(base, base), "ds")
    return None


def probe_model(
    model_name: str, upstream_id: str, provider: str, key: str, *, max_tokens: int = 400, timeout: int = 120
) -> dict:
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
    elif provider == "ds":
        url = DS_CHAT_URL
        headers = {
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "User-Agent": "homelab-weekly-model-sync/1.0",
        }
    else:
        return {"ok": False, "latency_ms": 0, "content": "", "error": f"Unknown provider {provider}"}

    payload = json.dumps({
        "model": upstream_id,
        "messages": [{"role": "user", "content": f"Say exactly: {model_name} is online"}],
        "max_tokens": max_tokens,
    }).encode("utf-8")
    req = urllib.request.Request(url, data=payload, headers=headers, method="POST")

    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = json.loads(resp.read().decode("utf-8"))
            msg = body.get("choices", [{}])[0].get("message", {})
            content = (msg.get("content") or "").strip()
            reasoning = (msg.get("reasoning") or "").strip() or (msg.get("reasoning_content") or "").strip()
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
        upstream = model_name.removesuffix("-ollama")
        candidates = [
            upstream,
            upstream.rsplit("-", 1)[0] + ":" + upstream.rsplit("-", 1)[1] if "-" in upstream else upstream,
        ]
        return {
            "model_name": model_name,
            "litellm_params": {
                "model": f"openai/{candidates[0]}",
                "api_base": "https://ollama.com/v1",
                "api_key": "os.environ/OLLAMA_API_KEY",
            },
        }
    if is_go_model(model_name):
        upstream = model_name.removesuffix("-go") if model_name.endswith("-go") else model_name
        return {
            "model_name": model_name,
            "litellm_params": {
                "model": f"openai/{upstream}",
                "api_base": "https://opencode.ai/zen/go/v1",
                "api_key": "os.environ/OPENCODE_GO_SUBSCRIPTION_API_KEY",
            },
        }
    if is_ds_model(model_name):
        # Native `deepseek/` provider: no api_base (provider default), and
        # reasoning_effort maps to DeepSeek's thinking mode instead of 400ing.
        base = model_name.removesuffix("-ds")
        upstream = DS_UPSTREAM_ALIASES.get(base, base)
        return {
            "model_name": model_name,
            "litellm_params": {
                "model": f"deepseek/{upstream}",
                "api_key": "os.environ/DEEPSEEK_API_KEY",
            },
        }
    raise ValueError(f"Cannot build entry for unknown model category: {model_name}")


def fix_ollama_model_string(entry: dict, ollama_ids: set[str]) -> None:
    """Ensure the openai/<id> string matches the real upstream id (including colons)."""
    model_name = entry["model_name"]
    upstream = model_name.removesuffix("-ollama")
    candidates = [upstream]
    if "-" in upstream:
        base, tag = upstream.rsplit("-", 1)
        candidates.append(f"{base}:{tag}")
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

    if remove:
        model_list[:] = [entry for entry in model_list if entry["model_name"] not in remove]

    new_ollama = sorted(n for n in add if is_ollama_model(n))
    new_go = sorted(n for n in add if is_go_model(n))

    for name in new_ollama:
        entry = build_model_entry(name)
        fix_ollama_model_string(entry, ollama_ids)
        insert_idx = len(model_list)
        for i, e in enumerate(model_list):
            if not is_ollama_model(e["model_name"]):
                insert_idx = i
                break
        model_list.insert(insert_idx, entry)

    for name in new_go:
        entry = build_model_entry(name)
        insert_idx = len(model_list)
        for i, e in enumerate(model_list):
            if not (is_ollama_model(e["model_name"]) or is_go_model(e["model_name"])):
                insert_idx = i
                break
        model_list.insert(insert_idx, entry)


def update_openwebui_pins(data, newly_added: set[str]) -> set[str]:
    """Auto-pin newly added models whose names contain 'flash'. Returns the new pinned set."""
    env_vars = data["spec"]["values"].get("extraEnvVars", [])
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
def _plain(obj):
    """CommentedMap -> plain struct, so the ledger dump carries no ruamel types."""
    if isinstance(obj, dict):
        return {str(k): _plain(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_plain(v) for v in obj]
    if isinstance(obj, (str, int, float, bool)) or obj is None:
        return obj
    return str(obj)


# ---------------------------------------------------------------------------
# Route audit + retirement ledger (GUL-2009)
# ---------------------------------------------------------------------------
LEDGER_HEADER = """\
# Routes the LLM hub has retired, or refused to add, and why.
#
# Written by apps/llm-hub/scripts/weekly-model-sync.py - never edit by hand.
# Read by humans at docs/llm-hub-retired-models.md (regenerated from this file).
#
# `entry` is the exact model_list entry that was removed, so a route can be
# pasted back into litellm-helm-release.yaml when the upstream serves it again.
# Three states:
#   retired  - was advertised by the hub, the upstream refused it permanently
#   rejected - never added: the catalogue offered it, the probe refused it
#   revoked  - retired after the upstream dropped it from the catalogue
"""


def route_probe_target(entry: dict) -> tuple[str, str] | None:
    """(upstream_id, provider) for a configured route, read from its own litellm_params.

    Read from the entry, never from the catalogue: a route that 403s is usually
    still listed upstream, and the hand-written routes have no catalogue entry
    at all. A base we do not own (local LM Studio, in-cluster services) returns
    None and is left strictly alone.
    """
    params = entry.get("litellm_params") or {}
    model = str(params.get("model") or "")
    if not model:
        return None
    upstream_id = model.split("/", 1)[-1]
    base = str(params.get("api_base") or "")
    if "ollama.com" in base:
        return upstream_id, "ollama"
    if "opencode.ai" in base:
        return upstream_id, "go"
    if not base and model.startswith("deepseek/"):
        return upstream_id, "ds"
    return None


def _probe_key(provider_keys: dict[str, str], provider: str) -> str:
    return provider_keys.get(
        {"ollama": "OLLAMA_API_KEY", "ds": "DEEPSEEK_API_KEY"}.get(provider, "OPENCODE_GO_SUBSCRIPTION_API_KEY"),
        "",
    )


def reason_class(status_code: int | None, error: str | None) -> str:
    """Short, stable bucket for a refusal, so the ledger can be counted."""
    low = str(error or "").lower()
    if "model access is disabled" in low or "permission_error" in low or status_code == 403:
        return "access_disabled"
    if status_code == 410 or "deprecat" in low or "retired" in low or "no longer" in low:
        return "deprecated"
    if status_code == 400 and ("not included" in low or "plan" in low or "not supported" in low):
        return "not_in_plan"
    return f"http_{status_code}" if status_code else "unreachable"


def _classify_probe(result: dict) -> tuple[str, int | None, str]:
    """ok | permanent | transient, plus the HTTP code and the reason text.

    permanent = the provider will not serve this name at all (400/403/404/410).
    transient = we could not tell (429 quota, 5xx, timeout, network).
    """
    if result.get("ok"):
        return "ok", None, ""
    error = str(result.get("error") or "") or "no response"
    match = re.search(r"HTTP (\d{3})", error)
    code = int(match.group(1)) if match else None
    if code is None:
        return "transient", None, error[:300]
    if code in PERMANENT_FAILURE_CODES:
        return "permanent", code, error[:300]
    if code in TRANSIENT_FAILURE_CODES:
        return "transient", code, error[:300]
    if 400 <= code < 500:
        return "permanent", code, error[:300]
    return "transient", code, error[:300]


def audit_routes(data, provider_keys: dict[str, str], *, workers: int = 8) -> list[dict]:
    """Probe every route the hub advertises, read-only, and classify the answer.

    Parallel (a refusal is fast, a working route is the slow one) and capped in
    tokens: this runs against the owner's own subscription every week, so it
    must cost one short completion per route and nothing more.
    """
    entries = data["spec"]["values"]["proxy_config"]["model_list"]
    plans: list[tuple[str, tuple[str, str] | None, str | None]] = []
    for entry in entries:
        name = entry["model_name"]
        exempt = ROUTE_AUDIT_EXEMPT.get(name)
        if not exempt and name in GO_DERIVED_ROUTES:
            # Purpose-built route: it may ride its own fallback, so a probe of the
            # upstream says nothing about the route. Left to the reference check.
            exempt = "derived route with fallbacks - audit it through the hub, not the upstream"
        plans.append((name, route_probe_target(entry), exempt))

    def audit_one(plan: tuple[str, tuple[str, str] | None, str | None]) -> dict:
        name, target, exempt = plan
        if exempt:
            return {"model_name": name, "status": "exempt", "code": None, "reason": exempt,
                    "upstream_id": None, "provider": None, "latency_ms": 0}
        if target is None:
            return {"model_name": name, "status": "unprobeable", "code": None,
                    "reason": "not a hosted provider route (local or in-cluster api_base)",
                    "upstream_id": None, "provider": None, "latency_ms": 0}
        upstream_id, provider = target
        result = probe_model(
            name, upstream_id, provider, _probe_key(provider_keys, provider), max_tokens=16, timeout=90
        )
        status, code, reason = _classify_probe(result)
        return {"model_name": name, "status": status, "code": code, "reason": reason,
                "upstream_id": upstream_id, "provider": provider,
                "latency_ms": result.get("latency_ms", 0)}

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        results = list(pool.map(audit_one, plans))
    return sorted(results, key=lambda r: r["model_name"])


def report_route_audit(results: list[dict]) -> None:
    """Print the lane table. Loud for anything the caller cannot use."""
    ok = [r for r in results if r["status"] == "ok"]
    permanent = [r for r in results if r["status"] == "permanent"]
    transient = [r for r in results if r["status"] == "transient"]
    unprobeable = [r for r in results if r["status"] == "unprobeable"]
    exempt = [r for r in results if r["status"] == "exempt"]

    print("\n-- Route audit (every advertised route, one short completion each) --")
    print(f"  answers:        {len(ok)}")
    print(f"  refused:        {len(permanent)}  <- archived this run")
    print(f"  unverified:     {len(transient)}  (quota/5xx/timeout: kept, never archived)")
    print(f"  not probed:     {len(unprobeable) + len(exempt)}  (local/in-cluster/exempt: left alone)")
    for r in permanent:
        print(f"  RETIRE {r['model_name']}  ({r['provider']}/{r['upstream_id']})  "
              f"{r['code']}: {reason_class(r['code'], r['reason'])}")
    for r in transient:
        print(f"  KEEP   {r['model_name']}  unverified: {r['reason'][:90]}")


def load_ledger() -> dict:
    if not RETIRED_LEDGER.exists():
        return {"retired": []}
    data = YAML(typ="safe").load(RETIRED_LEDGER.read_text(encoding="utf-8")) or {}
    if not isinstance(data, dict):
        data = {}
    data.setdefault("retired", [])
    return data


def record_ledger(records: list[dict]) -> list[str]:
    """Append or refresh ledger entries. Returns the affected model names.

    Deduplicated by (model_name, state, reason_class): a model that fails the
    same way for six weeks is one row with a `count`, not six rows of noise.
    """
    if not records:
        return []
    ledger = load_ledger()
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    touched: list[str] = []
    for rec in records:
        name = rec["model_name"]
        state = rec.get("state", "retired")
        klass = rec.get("reason_class") or reason_class(rec.get("code"), rec.get("reason", ""))
        existing = next(
            (e for e in ledger["retired"]
             if e.get("model_name") == name and e.get("state") == state and e.get("reason_class") == klass),
            None,
        )
        if existing:
            existing["last_seen"] = today
            existing["count"] = int(existing.get("count") or 1) + 1
            existing["status"] = rec.get("code")
            existing["reason"] = rec.get("reason", existing.get("reason"))
            touched.append(name)
            continue
        entry = {
            "model_name": name,
            "state": state,
            "provider": rec.get("provider"),
            "upstream_id": rec.get("upstream_id"),
            "reason_class": klass,
            "status": rec.get("code"),
            "reason": rec.get("reason", ""),
            "first_seen": today,
            "last_seen": today,
            "count": 1,
        }
        if rec.get("entry"):
            entry["entry"] = rec["entry"]
        ledger["retired"].append(entry)
        touched.append(name)

    RETIRED_LEDGER.parent.mkdir(parents=True, exist_ok=True)
    RETIRED_LEDGER.write_text(LEDGER_HEADER + dump_yaml(ledger), encoding="utf-8")
    render_retired_docs(ledger)
    return touched


def render_retired_docs(ledger: dict) -> None:
    """Regenerate the human-readable table from the ledger (docs, not a source of truth)."""
    rows = sorted(ledger.get("retired", []), key=lambda e: (str(e.get("last_seen", "")), e.get("model_name", "")), reverse=True)
    lines = [
        "# Retired LLM hub routes",
        "",
        "Generated by `apps/llm-hub/scripts/weekly-model-sync.py` from",
        "`apps/llm-hub/retired-models.yaml` - do not edit either by hand.",
        "",
        "A route is retired when the upstream refuses it permanently (400, 403, 404, 410).",
        "A 429 (quota) or a 5xx never retires anything, because that is *could not check*, not *gone*:",
        "the sync reports those and leaves the route where it is.",
        "",
        "**Why this file exists:** a retired route that stays in `/v1/models` is a trap. Clients pick it",
        "from the list, the call comes back 403, and the caller has no way to know the model is switched",
        "off upstream rather than broken in the hub.",
        "",
        "**To restore a model:** the full previous `model_list` entry is kept in the YAML ledger under",
        "`entry`. Paste it back into `apps/llm-hub/litellm-helm-release.yaml`, and the next sync keeps it",
        "if the probe answers. For quota-driven states, just wait for the reset: a rejected candidate is",
        "re-probed every week and adds itself once the provider serves it.",
        "",
        "| model | state | provider | last seen | status | why |",
        "|---|---|---|---|---|---|",
    ]
    for e in rows:
        why = str(e.get("reason") or "").replace("|", "/").replace("\n", " ")[:140]
        lines.append(
            f"| `{e.get('model_name')}` | {e.get('state')} | {e.get('provider') or '-'} | "
            f"{e.get('last_seen') or '-'} | {e.get('status') or '-'} | {why} |"
        )
    if not rows:
        lines.append("| - | - | - | - | - | nothing retired yet |")
    lines.append("")
    RETIRED_DOCS.parent.mkdir(parents=True, exist_ok=True)
    RETIRED_DOCS.write_text("\n".join(lines), encoding="utf-8")


def flux_reconcile() -> None:
    ts = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    run(kubectl("-n", "flux-system",
         "annotate", "gitrepository", "flux-system",
         f"reconcile.fluxcd.io/requestedAt={ts}", "--overwrite"), check=True)
    run(kubectl("-n", "flux-system",
         "annotate", "kustomization", "apps",
         f"reconcile.fluxcd.io/requestedAt={ts}", "--overwrite"), check=True)


def wait_for_helmrelease_ready(namespace: str, name: str, timeout_seconds: int = 300) -> None:
    run(kubectl(
        "-n", namespace,
        "wait", "--for=condition=ready", f"helmrelease/{name}",
        f"--timeout={timeout_seconds}s",
    ), check=True)


def trigger_key_provisioner() -> str:
    job_name = f"litellm-key-provisioner-manual-{int(time.time())}"
    run(kubectl(
        "-n", "llm-hub",
        "create", "job", "--from=cronjob/litellm-key-provisioner", job_name,
    ), check=True)
    run(kubectl(
        "-n", "llm-hub",
        "wait", "--for=condition=complete", f"job/{job_name}", "--timeout=120s",
    ), check=True)
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


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description="Weekly LLM model-list sync")
    parser.add_argument("--dry-run", action="store_true", help="Show diff but do not commit or mutate cluster")
    parser.add_argument("--allow-removals", action="store_true", help="Allow removal of unreferenced stale models")
    parser.add_argument(
        "--skip-route-audit",
        action="store_true",
        help="Do not probe the routes the hub already advertises (skips forced archival of refused routes)",
    )
    parser.add_argument(
        "--commit-only",
        action="store_true",
        help="Apply the mutation and commit on the CURRENT branch; no push, no PR, no Flux, no proxy check",
    )
    args = parser.parse_args()

    print(f"=== Weekly LLM model-list sync — {'DRY-RUN' if args.dry_run else 'LIVE'} ===")

    if not REPO.exists():
        print(f"Repo not found at {REPO}", file=sys.stderr)
        return 1

    # ------------------------------------------------------------------
    # Preflight: the sync owns the commit and the push to main
    # ------------------------------------------------------------------
    if not args.dry_run and not args.commit_only and not preflight():
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

    provider_keys = get_provider_keys()

    print("\n-- Fetching DeepSeek catalogue --")
    ds_ids = fetch_ds_model_ids(provider_keys.get("DEEPSEEK_API_KEY", ""))
    print(f"DeepSeek: {len(ds_ids)} models" + ("" if ds_ids else " (unavailable)"))

    # ------------------------------------------------------------------
    # Load current configs
    # ------------------------------------------------------------------
    litellm_data, _ = load_yaml(LITELLM_RELEASE, backup=not args.dry_run)
    openwebui_data, _ = load_yaml(OPENWEBUI_RELEASE, backup=not args.dry_run)

    current = set(current_model_list(litellm_data))
    upstream_desired = desired_model_names(ollama_ids, go_ids)

    # Routes the sync does not regenerate still have to point at something real.
    dead_upstreams = dead_upstream_routes(litellm_data, ollama_ids, go_ids, ds_ids)

    # GUL-1431: a default that points at a removed route is the failure the
    # owner saw (Open WebUI opening on a model nobody serves). The sync does not
    # pick a new default by itself; it goes red and names the entry.
    dead_defaults = dead_openwebui_defaults(openwebui_data, current)
    if dead_defaults:
        print("\n!! Open WebUI DEFAULT_MODELS points at model(s) LiteLLM does not route: "
              + ", ".join(sorted(dead_defaults)))
        print("!! Pick a new default in apps/llm-hub/openwebui-helm-release.yaml.")

    def exit_code() -> int:
        """3 when something still needs the owner: a dead upstream reference, a dead
        Open WebUI default, or a hand-written route the upstream refuses."""
        return 3 if (dead_upstreams or dead_defaults or refused_handwritten) else 0

    # ------------------------------------------------------------------
    # Route audit (GUL-2009): probe what the hub already advertises
    # ------------------------------------------------------------------
    # The catalogue questions ("is this model still offered?") never asked
    # whether a route ANSWERS. This one does, and the owner's rule is blunt: a
    # route the provider refuses permanently is archived from the hub, because
    # leaving it there only moves the 403 onto the next caller.
    audit_results: list[dict] = []
    # Snapshot the entries BEFORE anything is removed: the ledger keeps the exact
    # model_list entry of a retired route so it can be pasted back later.
    entry_snapshot = {
        entry["model_name"]: _plain(entry)
        for entry in litellm_data["spec"]["values"]["proxy_config"]["model_list"]
    }
    if args.skip_route_audit:
        print("\n-- Route audit skipped (--skip-route-audit) --")
    else:
        audit_results = audit_routes(litellm_data, provider_keys)
        report_route_audit(audit_results)

    refused_routes = {r["model_name"] for r in audit_results if r["status"] == "permanent"}

    # Preserve non-Ollama/non-Go routes in the LiteLLM model list (z.ai, OpenRouter, Gemini, etc.)
    litellm_desired = upstream_desired | {m for m in current if not (is_ollama_model(m) or is_go_model(m))}

    # The key-provisioner whitelist is route-backed: an id upstream offers but
    # the proxy does not route earns no permission (GUL-1096). Verified
    # additions, failed probes and this run's removals are folded in at mutation
    # time, once the probes have answered.
    provisioner_current = current_provisioner_models(PROVISIONER_CM)
    provisioner_desired = compute_provisioner_desired(
        provisioner_current, current, set(), set(), set()
    )

    litellm_additions = litellm_desired - current
    litellm_removals = current - litellm_desired
    provisioner_additions = provisioner_desired - provisioner_current
    provisioner_removals = provisioner_current - provisioner_desired

    print(f"\nCurrent models in proxy: {len(current)}")
    print(f"Desired models:          {len(litellm_desired)}")
    print(f"LiteLLM additions:       {len(litellm_additions)}")
    print(f"LiteLLM removals:        {len(litellm_removals)}")
    print(f"Key provisioner additions: {len(provisioner_additions)}")
    print(f"Key provisioner removals:  {len(provisioner_removals)}")
    if litellm_additions:
        for m in sorted(litellm_additions):
            print(f"  + {m}")
    if litellm_removals:
        for m in sorted(litellm_removals):
            print(f"  - {m}")

    report_dead_upstream_routes(dead_upstreams)

    if args.dry_run and not litellm_additions and not litellm_removals and not provisioner_additions and not provisioner_removals:
        print("\nNo changes. Exiting dry-run.")
        return exit_code()

    # ------------------------------------------------------------------
    # Probe additions
    # ------------------------------------------------------------------
    master_key = get_master_key()
    os.environ["SYNC_SESSION_ID"] = os.urandom(16).hex()
    verified_additions: set[str] = set()
    failed_additions: dict[str, str] = {}

    if litellm_additions:
        print("\n-- Probing LiteLLM additions (upstream directly) --")
        for m in sorted(litellm_additions):
            probe_info = upstream_id_for_model(m, ollama_ids, go_ids, ds_ids)
            if not probe_info:
                print(f"  Skipping {m}: cannot determine upstream id")
                failed_additions[m] = "Cannot determine upstream id"
                continue
            upstream_id, provider = probe_info
            key = provider_keys.get(
                {"ollama": "OLLAMA_API_KEY", "ds": "DEEPSEEK_API_KEY"}.get(
                    provider, "OPENCODE_GO_SUBSCRIPTION_API_KEY"
                ),
                "",
            )
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

    # ------------------------------------------------------------------
    # Brain-death safety: check consumer references before removals
    # ------------------------------------------------------------------
    protected = scan_hermes_profiles() | scan_openwebui_defaults(openwebui_data)
    print(f"\n-- Consumer reference scan --")
    print(f"Protected model names: {len(protected)}")

    safe_removals: set[str] = set()
    blocked_removals: dict[str, set[str]] = {}
    if args.allow_removals:
        for m in litellm_removals:
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

    # A route the upstream refuses is archived whether or not --allow-removals was
    # passed, and a consumer pin does NOT block it: the pin does not fix the 403,
    # it only guarantees the consumer keeps eating one. The pin is reported so the
    # consumer gets fixed; the name leaves the catalogue either way.
    # Only what the sync itself generated may be archived without a human. A
    # hand-written route (GO_DERIVED_ROUTES) may be riding an intentional fallback,
    # and deleting it would remove working behaviour, so it is reported and left
    # alone (GUL-105). `litellm_removals` is the current-but-no-longer-catalogued
    # set: still sync-generated, just stale, so a refusal there is a probe finding
    # and not an --allow-removals decision.
    sync_owned_routes = (upstream_desired | GO_BARE_ROUTES | set(litellm_removals)) - GO_DERIVED_ROUTES
    refused_handwritten = refused_routes - sync_owned_routes
    if refused_handwritten:
        print("\n!! Hand-written route(s) refused by the upstream - NOT archived, decide by hand:")
        for name in sorted(refused_handwritten):
            row = next(r for r in audit_results if r["model_name"] == name)
            print(f"!!   {name}: {row['code']} {row['reason'][:120]}")

    forced_removals = {m for m in refused_routes if m in current and m in sync_owned_routes}
    if forced_removals:
        print(f"Forced archival - upstream refuses these ({len(forced_removals)}): "
              + ", ".join(sorted(forced_removals)))
        for m in sorted(forced_removals):
            blocked_removals.pop(m, None)
        safe_removals |= forced_removals

    pinned_to_dead = sorted(
        m for m in protected if m in (forced_removals | set(blocked_removals) | safe_removals)
    )
    if pinned_to_dead:
        print("Consumer pins pointing at routes leaving the hub - fix the consumer: "
              + ", ".join(pinned_to_dead))

    routes_after = (current | verified_additions) - safe_removals
    stale_pins = {
        m for m in (v.strip() for v in str((_openwebui_env(openwebui_data, "DEFAULT_PINNED_MODELS") or {}).get("value", "")).split(","))
        if m and m not in routes_after
    }
    if stale_pins:
        print(f"Open WebUI pins with no route (will be dropped): {', '.join(sorted(stale_pins))}")

    if not verified_additions and not safe_removals and not stale_pins:
        print("\nNo changes.")
        return exit_code()

    if args.dry_run:
        print("\n-- DRY-RUN diff summary --")
        print(f"Would add:    {sorted(verified_additions)}")
        print(f"Would remove: {sorted(safe_removals)}")
        if forced_removals:
            print(f"Would archive (upstream refuses, not a flag decision): {sorted(forced_removals)}")
        if pinned_to_dead:
            print(f"Would report as a broken consumer pin: {pinned_to_dead}")
        print(f"Would skip (failed probe): {sorted(failed_additions)}")
        print(f"Would skip (protected):    {sorted(blocked_removals)}")
        print(f"Would unpin in Open WebUI: {sorted(stale_pins)}")
        if not verified_additions and not safe_removals:
            print("No changes.")
        return exit_code()

    # ------------------------------------------------------------------
    # Mutate configs
    # ------------------------------------------------------------------
    print("\n-- Updating configs --")
    update_litellm_model_list(litellm_data, ollama_ids, go_ids, verified_additions, safe_removals)
    newly_pinned = update_openwebui_pins(openwebui_data, verified_additions)
    if newly_pinned:
        print(f"Auto-pinned in Open WebUI: {', '.join(sorted(newly_pinned))}")
    unpinned = prune_openwebui_pins(openwebui_data, routes_after)
    if unpinned:
        print(f"Unpinned in Open WebUI (no route): {', '.join(sorted(unpinned))}")

    # Key provisioner is edited as text so the embedded Python comments survive.
    provisioner_text = PROVISIONER_CM.read_text(encoding="utf-8")
    new_provisioner_desired = compute_provisioner_desired(
        provisioner_current,
        current,
        verified_additions,
        set(failed_additions),
        safe_removals,
    )
    new_provisioner_text = update_key_provisioner(provisioner_text, new_provisioner_desired)

    ledger_records: list[dict] = []
    for r in audit_results:
        if r["status"] != "permanent" or r["model_name"] not in forced_removals:
            continue
        ledger_records.append({
            "model_name": r["model_name"],
            "state": "retired",
            "provider": r["provider"],
            "upstream_id": r["upstream_id"],
            "code": r["code"],
            "reason_class": reason_class(r["code"], r["reason"]),
            "reason": r["reason"],
            "entry": entry_snapshot.get(r["model_name"]),
        })
    for name, error in failed_additions.items():
        target = upstream_id_for_model(name, ollama_ids, go_ids, ds_ids)
        klass_status, code, reason = _classify_probe({"ok": False, "error": error})
        ledger_records.append({
            "model_name": name,
            "state": "rejected",
            "provider": target[1] if target else None,
            "upstream_id": target[0] if target else None,
            "code": code,
            "reason_class": reason_class(code, error),
            "reason": reason,
        })
    if ledger_records:
        record_ledger(ledger_records)
        print(f"\nLedger updated: {RETIRED_LEDGER.relative_to(REPO)} "
              f"({len(ledger_records)} record(s)), docs regenerated")

    save_yaml(litellm_data, LITELLM_RELEASE)
    save_yaml(openwebui_data, OPENWEBUI_RELEASE)
    PROVISIONER_CM.write_text(new_provisioner_text, encoding="utf-8")

    # ------------------------------------------------------------------
    # Commit and push
    # ------------------------------------------------------------------
    if git_clean():
        print("\nWorking tree clean after mutations; nothing to commit.")
        return exit_code()

    commit_msg = f"feat(llm-hub): weekly model sync — add {len(verified_additions)} model(s)"
    if forced_removals:
        commit_msg += f", archive {len(forced_removals)} refused route(s)"
    if safe_removals - forced_removals:
        commit_msg += f", remove {len(safe_removals - forced_removals)} stale model(s)"
    if stale_pins:
        commit_msg += f", unpin {len(stale_pins)} dead Open WebUI pin(s)"
    commit_body = f"""Weekly sync against upstream catalogues.

Additions ({len(verified_additions)} verified by live probe):
{chr(10).join(f"- {m}" for m in sorted(verified_additions)) or "- none"}

Failed probes (kept out):
{chr(10).join(f"- {m}: {e}" for m, e in sorted(failed_additions.items())) or "- none"}

Removals:
{chr(10).join(f"- {m}" for m in sorted(safe_removals)) or "- none"}

Archived because the upstream refuses them (probe, not a flag):
{chr(10).join(f"- {r['model_name']}: {r['code']} {reason_class(r['code'], r['reason'])}" for r in audit_results if r['model_name'] in forced_removals) or "- none"}

Consumer pins pointing at a route that left the hub (fix the consumer):
{chr(10).join(f"- {m}" for m in pinned_to_dead) or "- none"}

Blocked removals (still referenced):
{chr(10).join(f"- {m}" for m in sorted(blocked_removals)) or "- none"}

Open WebUI pins dropped (no route):
{chr(10).join(f"- {m}" for m in sorted(stale_pins)) or "- none"}

Co-Authored-By: Paperclip <noreply@paperclip.ing>
"""
    # Stage only the files this script owns. `git add -A` would sweep in
    # whatever WIP another agent left in the tree.
    owned = [LITELLM_RELEASE, OPENWEBUI_RELEASE, PROVISIONER_CM]
    if ledger_records:
        owned += [RETIRED_LEDGER, RETIRED_DOCS]
    for path in owned:
        run(["git", "add", "--", str(path)], cwd=REPO, check=True)
    run(["git", "commit", "-m", commit_msg, "-m", commit_body], cwd=REPO, check=True)

    if args.commit_only:
        print("\n--commit-only: commit left on the current branch. No push, no PR, no cluster. --")
        print(f"Committed: {commit_msg}")
        return exit_code()

    # ------------------------------------------------------------------
    # Land it. `protect-main` requires the `check` status on main, so a direct push is
    # refused (GUL-721). Then the commit goes to a branch with a PR open and the run
    # STOPS before touching the cluster: nothing is reconciled or provisioned for a
    # change that is not in git. Exit 4 tells the caller "reviewable, awaiting merge".
    # ------------------------------------------------------------------
    pushed, push_out = push_to_main()
    if not pushed:
        if not any(marker in push_out for marker in PROTECTED_MAIN_MARKERS):
            print(push_out, file=sys.stderr)
            raise RuntimeError("git push origin main failed for a reason other than the protect-main ruleset")
        print("\n-- main is protected; opening a PR instead of pushing --")
        url = open_sync_pr(
            commit_msg,
            "Weekly LLM model-list sync — automated output of\n"
            "`apps/llm-hub/scripts/weekly-model-sync.py`.\n\n" + commit_body,
        )
        # Leave the checkout as the next run expects to find it: clean `main` at origin.
        run(["git", "reset", "--hard", "origin/main"], cwd=REPO, check=True)
        print("\n=== Sync complete, NOT live: PR awaiting the owner's merge ===")
        print(f"PR: {url}")
        print("Flux and the key provisioner are untouched. Merge the PR; the next Flux")
        print("interval applies it, and the provisioner's own schedule mints the keys.")
        print("Exit 4 = awaiting merge.")
        return 4

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
    print("\n-- Verifying proxy --")
    for m in sorted(verified_additions):
        if proxy_advertises(m, master_key):
            print(f"  {m}: advertised ✓")
        else:
            print(f"  {m}: NOT advertised ✗", file=sys.stderr)

    for m in sorted(forced_removals):
        gone = not proxy_advertises(m, master_key)
        print(f"  {m}: {'archived ✓' if gone else 'STILL ADVERTISED ✗'}")
        if not gone:
            print(f"    {m} is refused upstream but still in /v1/models", file=sys.stderr)

    print("\n=== Sync complete ===")
    return exit_code()


if __name__ == "__main__":
    sys.exit(main())