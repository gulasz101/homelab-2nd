#!/usr/bin/env python3
"""engine.py — the model-free factory engine.

Contract: agents/factory/ENGINE.md. The stage checks stay in factory.py
(CONTRACT.md); this file only calls them as subprocesses. Python 3 standard
library only; run as `python3 -I agents/factory/engine.py <subcommand>`.

Every subcommand prints exactly one JSON line on stdout
({"ok": bool, "check": "engine-<sub>", "reasons": [...], ...}) and a short
human summary on stderr. Exit 0 ok, 1 refused / not passed, 2 setup error.
No secret is ever printed, logged or written anywhere.
"""
from __future__ import annotations

import argparse
import datetime
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

try:
    import tomllib
except ImportError:  # Python < 3.11: pyproject/Cargo rows are skipped
    tomllib = None

HERE = os.path.dirname(os.path.abspath(__file__))
FACTORY_PY = os.path.join(HERE, "factory.py")
# `python3 -I` drops the script's own directory from sys.path.
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import factory  # noqa: E402
import pc  # noqa: E402

SetupError = factory.SetupError

STAGE_PHASES = ("librarian", "red", "green", "review", "verify")
ACTIVE_PHASES = STAGE_PHASES + ("gate",)
TERMINAL_PHASES = ("done", "closed", "stalled")
LIVE_RUN_STATUSES = {"queued", "running", "starting"}
PENDING_CHECK_STATES = {"PENDING", "QUEUED", "IN_PROGRESS", "EXPECTED", "WAITING", "REQUESTED"}
FAILED = ("fail", "timeout")
TAIL_LINES = 60
INVENTORY_MAX_ROWS = 25
RETAIN_MAX_TRIES = 3


class DryRun(Exception):
    """Raised at the first write of a step when the tick runs without --apply."""


# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------

def now_utc() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc)


def iso(dt=None) -> str:
    return (dt or now_utc()).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(text):
    if not text:
        return None
    try:
        dt = datetime.datetime.fromisoformat(str(text).replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=datetime.timezone.utc)


def minutes_since(text) -> float:
    dt = parse_iso(text)
    if dt is None:
        return 0.0
    return (now_utc() - dt).total_seconds() / 60.0


def one_line(value, limit=300) -> str:
    text = " ".join(str(value if value is not None else "").split())
    return text if len(text) <= limit else text[:limit - 1] + "…"


def unwrap(payload, key):
    """The live API answers some routes bare and some as {"<key>": {...}}."""
    if isinstance(payload, dict) and isinstance(payload.get(key), dict):
        return payload[key]
    return payload if isinstance(payload, dict) else {}


def as_list(payload, *keys):
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in keys:
            if isinstance(payload.get(key), list):
                return payload[key]
    return []


def fingerprint(reasons) -> str:
    norm = sorted(" ".join(str(r).split()) for r in reasons or [])
    return hashlib.sha1("\n".join(norm).encode("utf-8")).hexdigest()


def first_reason(reasons) -> str:
    return one_line((reasons or ["no reason given"])[0], 300)


def warn(text: str) -> None:
    sys.stderr.write("engine: %s\n" % text)


def emit(ok: bool, sub: str, reasons: list, extra=None, summary: str = "") -> None:
    out = {"ok": ok, "check": "engine-" + sub, "reasons": reasons}
    if extra:
        out.update(extra)
    sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    sys.stderr.write((summary or ("engine-%s: %s" % (sub, "ok" if ok else "; ".join(reasons[:5])))) + "\n")


# --------------------------------------------------------------------------
# config, paths, credentials
# --------------------------------------------------------------------------

def load_config() -> dict:
    path = os.environ.get("FACTORY_ENGINE_CONFIG") or os.path.join(HERE, "engine.json")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            cfg = json.load(fh)
    except (OSError, ValueError) as exc:
        raise SetupError("cannot read engine config %s: %s" % (path, exc))
    for key, env in (("hindsightUrl", "FACTORY_HINDSIGHT_URL"), ("docsUrl", "FACTORY_DOCS_URL"),
                     ("lodgeUrl", "FACTORY_LODGE_URL")):
        if os.environ.get(env):
            cfg[key] = os.environ[env]
        cfg[key] = str(cfg.get(key) or "").rstrip("/")
    return cfg


def state_dir() -> str:
    return os.environ.get("FACTORY_ENGINE_STATE") or os.path.expanduser("~/factory/engine-state")


def stop_file() -> str:
    return os.environ.get("FACTORY_STOP") or os.path.expanduser(
        "~/paperclip-agents/majster/factory/STOP")


def repo_name(repo: str) -> str:
    return repo.split("/", 1)[1] if "/" in repo else repo


def bank_name(template: str, repo: str) -> str:
    return template.replace("{repoName}", repo_name(repo))


def read_secret_file(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def paperclip_api() -> "pc.Api":
    # The engine runs from launchd, outside any heartbeat run. An agent key without a run id gets
    # 403 on every cross-issue write, so the engine uses its own named board API key
    # ("factory-engine (GUL-2037)", revocable with DELETE /api/board-api-keys/<id>). It never
    # uses PAPERCLIP_API_KEY: inside an agent's run that would make the engine act as that agent.
    path = (os.environ.get("FACTORY_ENGINE_KEY_FILE")
            or os.path.expanduser("~/.paperclip/factory-engine-board.key"))
    key = read_secret_file(path)
    if not key:
        raise SetupError("no Paperclip key: create the engine key file %s (mode 600)" % path)
    return pc.Api(key=key, run_id="")


def hindsight_token() -> str:
    token = os.environ.get("HINDSIGHT_API_TOKEN") or ""
    if token:
        return token
    path = os.environ.get("FACTORY_HINDSIGHT_TOKEN_FILE") or os.path.expanduser(
        "~/.hindsight/coding-agent.json")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return str(json.load(fh).get("apiToken") or "")
    except (OSError, ValueError, AttributeError):
        return ""


def lodge_token(name: str) -> str:
    folder = os.environ.get("FACTORY_LODGE_TOKEN_DIR") or os.path.expanduser("~/.config/sou")
    return read_secret_file(os.path.join(folder, name + ".token"))


# --------------------------------------------------------------------------
# state files
# --------------------------------------------------------------------------

def write_json_atomic(path: str, data) -> None:
    folder = os.path.dirname(path)
    os.makedirs(folder, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=folder)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=1, ensure_ascii=False)
            fh.write("\n")
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def write_text_atomic(path: str, text: str) -> None:
    folder = os.path.dirname(path)
    os.makedirs(folder, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=folder)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def state_path(work_order: str) -> str:
    return os.path.join(state_dir(), work_order + ".json")


def list_states() -> list:
    folder = state_dir()
    if not os.path.isdir(folder):
        return []
    found = []
    for name in sorted(os.listdir(folder)):
        if re.match(r"^GUL-[0-9]+\.json$", name):
            with open(os.path.join(folder, name), "r", encoding="utf-8") as fh:
                found.append(json.load(fh))
    return sorted(found, key=lambda s: (s.get("createdAt") or "", s.get("workOrder") or ""))


# --------------------------------------------------------------------------
# subprocesses: git, factory.py checks, gh
# --------------------------------------------------------------------------

def git(repo: str, *args: str, check: bool = True) -> str:
    proc = subprocess.run(["git", "-C", repo] + list(args), stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0 and check:
        raise SetupError("git %s failed (exit %d): %s"
                         % (" ".join(args[:3]), proc.returncode, proc.stderr.strip()[:300]))
    return proc.stdout


class CheckResult:
    def __init__(self, args, code, parsed, combined):
        self.name = args[0]
        self.code = code
        self.parsed = parsed if isinstance(parsed, dict) else None
        self.ok = code == 0 and bool(self.parsed) and self.parsed.get("ok") is True
        reasons = (self.parsed or {}).get("reasons")
        self.reasons = [str(r) for r in reasons] if isinstance(reasons, list) and reasons else (
            [] if self.ok else ["%s exited %d" % (self.name, code)])
        self.line = json.dumps(self.parsed, ensure_ascii=False) if self.parsed else "(no json)"
        self.tail = [ln for ln in (combined or "").splitlines() if ln.strip()][-TAIL_LINES:]

    def require_json(self):
        if self.parsed is None:
            raise SetupError("factory.py %s printed no JSON line (exit %d): %s"
                             % (self.name, self.code, (self.tail or ["no output"])[-1][:300]))
        return self


def run_factory(args: list) -> CheckResult:
    proc = subprocess.run([sys.executable, "-I", FACTORY_PY] + args, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True)
    parsed = None
    lines = [ln for ln in proc.stdout.splitlines() if ln.strip()]
    if lines:
        try:
            parsed = json.loads(lines[-1])
        except ValueError:
            parsed = None
    combined = "\n".join(x for x in (proc.stdout, proc.stderr) if x)
    return CheckResult(args, proc.returncode, parsed, combined)


def gh_pr_checks(repo: str, number) -> list:
    """`gh pr checks --json` exits 8 while checks are pending and 1 when one
    failed, so the exit code is not the error signal: unparseable output is."""
    proc = subprocess.run([factory.gh_bin(), "pr", "checks", str(number), "--repo", repo,
                           "--json", "name,state"], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True)
    if proc.stdout.strip():
        try:
            value = json.loads(proc.stdout)
            if isinstance(value, list):
                return value
        except ValueError:
            pass
    if "no checks reported" in proc.stderr:
        return []
    raise SetupError("gh pr checks %s failed (exit %d): %s"
                     % (number, proc.returncode, proc.stderr.strip()[:300]))


def check_run_state(checks: list) -> str:
    named = [c for c in checks if isinstance(c, dict) and c.get("name") == "check"]
    states = {str(c.get("state") or "").upper() for c in named}
    if not named or states & PENDING_CHECK_STATES:
        return "pending" if "SUCCESS" not in states else "pass"
    return "pass" if "SUCCESS" in states else "fail"


# --------------------------------------------------------------------------
# plain HTTP for Hindsight, docs-mcp and the Lodge (Paperclip goes through pc.py)
# --------------------------------------------------------------------------

def http_json(method: str, url: str, body=None, token: str = "", timeout: float = 20):
    """Returns (status, parsed). Raises OSError-family on a connection failure."""
    headers = {"Accept": "application/json", "User-Agent": "factory-engine/1"}
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status, raw = resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        status, raw = exc.code, exc.read()
    try:
        parsed = json.loads(raw.decode("utf-8", "replace")) if raw.strip() else None
    except ValueError:
        parsed = None
    return status, parsed


# --------------------------------------------------------------------------
# inventory (ENGINE.md, "Inventory")
# --------------------------------------------------------------------------

SKIP_DIRS = {".git", "node_modules", "target", ".venv", "venv", "vendor", "dist", "build",
             "__pycache__"}


def is_manifest(name: str) -> bool:
    return (name in ("package.json", "pyproject.toml", "Cargo.toml", "go.mod")
            or bool(re.match(r"^requirements.*\.txt$", name))
            or name.endswith((".yaml", ".yml")))


def scope_dirs(allowed: list) -> list:
    dirs = set()
    for glob in allowed:
        prefix = re.split(r"[*?]", glob, maxsplit=1)[0]
        folder = prefix.rstrip("/") if prefix.endswith("/") else os.path.dirname(prefix)
        if folder:
            dirs.add(folder)
    return sorted(dirs)


def manifest_files(repo: str, allowed: list) -> list:
    found = []
    for name in sorted(os.listdir(repo)):
        if os.path.isfile(os.path.join(repo, name)) and is_manifest(name):
            found.append(name)
    for folder in scope_dirs(allowed):
        top = os.path.join(repo, folder)
        if not os.path.isdir(top):
            continue
        for root, subdirs, files in os.walk(top):
            subdirs[:] = sorted(d for d in subdirs if d not in SKIP_DIRS)
            for name in sorted(files):
                rel = os.path.relpath(os.path.join(root, name), repo)
                if is_manifest(name) and rel not in found:
                    found.append(rel)
    inside = [p for p in found if factory.glob_match(allowed, p)]
    return inside + [p for p in found if p not in inside]


def _req_line(text: str):
    m = re.match(r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)", text)
    if not m:
        return None
    v = re.search(r"(?:===|==|>=|~=|<=|>|<)\s*([0-9][^,;\s]*)", text)
    return m.group(1), (v.group(1) if v else "")


def _npm_version(lock: dict, name: str, wanted: str) -> str:
    entry = (lock.get("packages") or {}).get("node_modules/" + name) or \
        (lock.get("dependencies") or {}).get(name) or {}
    if isinstance(entry, dict) and entry.get("version"):
        return str(entry["version"])
    m = re.search(r"[0-9]+(?:\.[0-9]+)*", str(wanted))
    return m.group(0) if m else str(wanted)


def _read(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def parse_manifest(repo: str, rel: str) -> list:
    path = os.path.join(repo, rel)
    name = os.path.basename(rel)
    text = _read(path)
    rows = []
    if name == "package.json":
        try:
            data = json.loads(text)
        except ValueError:
            return []
        lock = {}
        lock_path = os.path.join(os.path.dirname(path), "package-lock.json")
        if os.path.isfile(lock_path):
            try:
                lock = json.loads(_read(lock_path))
            except ValueError:
                lock = {}
        for section in ("dependencies", "devDependencies"):
            for lib, wanted in sorted((data.get(section) or {}).items()):
                rows.append((lib, _npm_version(lock, lib, wanted)))
    elif name == "pyproject.toml" and tomllib:
        try:
            data = tomllib.loads(text)
        except (ValueError, tomllib.TOMLDecodeError):
            return []
        for dep in (data.get("project") or {}).get("dependencies") or []:
            row = _req_line(str(dep))
            if row:
                rows.append(row)
    elif name.startswith("requirements") and name.endswith(".txt"):
        for line in text.splitlines():
            line = line.split("#", 1)[0].strip()
            if line and not line.startswith("-"):
                row = _req_line(line)
                if row:
                    rows.append(row)
    elif name == "Cargo.toml" and tomllib:
        try:
            data = tomllib.loads(text)
        except (ValueError, tomllib.TOMLDecodeError):
            return []
        for lib, spec in sorted((data.get("dependencies") or {}).items()):
            version = spec if isinstance(spec, str) else (spec or {}).get("version", "")
            rows.append((lib, str(version).lstrip("^~=")))
    elif name == "go.mod":
        in_block = False
        for line in text.splitlines():
            line = line.split("//", 1)[0].strip()
            if line.startswith("require ("):
                in_block = True
                continue
            if in_block and line == ")":
                in_block = False
                continue
            if line.startswith("require "):
                line = line[len("require "):].strip()
            elif not in_block:
                continue
            parts = line.split()
            if len(parts) >= 2:
                segs = [s for s in parts[0].split("/") if not re.match(r"^v[0-9]+$", s)]
                rows.append((segs[-1] if segs else parts[0], parts[1].lstrip("v")))
    elif name.endswith((".yaml", ".yml")):
        rows.extend(helm_charts(text))
    return rows


def helm_charts(text: str) -> list:
    """`chart:` + `version:` under spec.chart.spec, line-based (no YAML parser)."""
    if not re.search(r"^kind:\s*HelmRelease\s*$", text, re.M):
        return []
    lines = text.splitlines()
    rows = []
    for i, line in enumerate(lines):
        m = re.match(r"^(\s+)chart:\s*[\"']?([^\"'\s#]+)", line)
        if not m:
            continue
        indent = m.group(1)
        version = ""
        for nxt in lines[i + 1:i + 12]:
            v = re.match(r"^%sversion:\s*[\"']?([^\"'\s#]+)" % re.escape(indent), nxt)
            if v:
                version = v.group(1)
                break
        rows.append((m.group(2), version))
    return rows


def norm_lib(name: str) -> str:
    text = str(name or "").lower()
    text = re.sub(r"^@[^/]+/", "", text)
    return re.sub(r"[-_.]", "", text)


def version_key(text: str):
    nums = re.findall(r"[0-9]+", str(text or ""))
    return tuple(int(n) for n in nums[:2]) if nums else None


def docs_index(docs_url: str):
    """{normalised name: [indexed versions]} from the docs-mcp tRPC route the
    `docs-search list` CLI uses, or None when the index cannot be read."""
    try:
        status, payload = http_json("GET", docs_url + "/api/listLibraries", timeout=10)
    except (OSError, ValueError):
        return None
    if status != 200 or not isinstance(payload, dict):
        return None
    data = (payload.get("result") or {}).get("data")
    if isinstance(data, dict) and "json" in data:
        data = data["json"]
    if not isinstance(data, list):
        return None
    index = {}
    for lib in data:
        if not isinstance(lib, dict) or not lib.get("library"):
            continue
        versions = []
        for v in lib.get("versions") or []:
            if not isinstance(v, dict) or v.get("status") not in (None, "completed"):
                continue
            ref = v.get("ref") if isinstance(v.get("ref"), dict) else {}
            versions.append(str(ref.get("version", v.get("version", "")) or ""))
        index.setdefault(norm_lib(lib["library"]), []).extend(versions)
    return {k: v for k, v in index.items() if v}


def classify(version: str, indexed) -> str:
    if indexed is None:
        return "missing"
    ours = version_key(version)
    if "" in indexed or ours is None:
        return "ok"
    keys = [version_key(v) for v in indexed]
    if any(k is not None and k >= ours for k in keys):
        return "ok"
    return "stale"


def inventory(repo: str, spec: dict, docs_url: str) -> dict:
    allowed = spec.get("allowedPaths") or []
    rows, seen = [], set()
    for rel in manifest_files(repo, allowed):
        for lib, version in parse_manifest(repo, rel):
            key = norm_lib(lib)
            if not key or key in seen:
                continue
            seen.add(key)
            rows.append({"library": lib, "version": str(version or ""), "file": rel})
    rows = rows[:INVENTORY_MAX_ROWS]
    index = docs_index(docs_url) if rows else {}
    for row in rows:
        if index is None:
            row["status"], row["indexedVersions"] = "unknown", []
        else:
            have = index.get(norm_lib(row["library"]))
            row["status"] = classify(row["version"], have)
            row["indexedVersions"] = sorted(set(have or []))
    return {"rows": rows, "docsIndex": "unreachable" if index is None else "ok"}


def ready_rows_from_inventory(rows: list, reason: str = "") -> list:
    out = []
    for r in rows:
        if r.get("status") == "ok":
            note = "indexed: %s" % (", ".join(v or "unversioned" for v in r.get("indexedVersions") or [])
                                    or "yes")
            out.append({"library": r["library"], "version": r["version"], "indexed": True,
                        "note": note})
        else:
            out.append({"library": r["library"], "version": r["version"], "indexed": False,
                        "note": "no docs: %s" % (reason or r.get("status") or "unknown")})
    return out


def parse_docs_ready(doc, inventory_rows: list):
    """Returns (rows, None) or (None, reason) for the librarian's document."""
    body = doc.get("body") if isinstance(doc, dict) else None
    if not isinstance(body, str) or not body.strip():
        return None, "no docs-ready document on the librarian issue"
    value, reasons = factory.extract_json_block(body, "docs-ready")
    if reasons:
        return None, reasons[0]
    if not isinstance(value, list):
        return None, "docs-ready: the json block is not a list"
    by_name = {norm_lib(r["library"]): r for r in value
               if isinstance(r, dict) and isinstance(r.get("library"), str)}
    missing = [r["library"] for r in inventory_rows if norm_lib(r["library"]) not in by_name]
    if missing:
        return None, "docs-ready has no row for %s" % ", ".join(missing)
    out = []
    for r in inventory_rows:
        got = by_name[norm_lib(r["library"])]
        out.append({"library": r["library"], "version": str(got.get("version") or r["version"]),
                    "indexed": got.get("indexed") is True, "note": one_line(got.get("note"), 200)})
    return out, None


def docs_table(rows: list) -> str:
    if not rows:
        return "No libraries found in scope."
    lines = ["| library | version | indexed | note |", "|---|---|---|---|"]
    for r in rows:
        lines.append("| %s | %s | %s | %s |" % (r["library"], r.get("version") or "-",
                                                "yes" if r.get("indexed") else "no",
                                                one_line(r.get("note"), 200).replace("|", "/")))
    return "\n".join(lines)


def inventory_table(rows: list) -> str:
    if not rows:
        return "No libraries found in scope."
    lines = ["| library | version | file | status | indexed versions |", "|---|---|---|---|---|"]
    for r in rows:
        lines.append("| %s | %s | %s | %s | %s |" % (
            r["library"], r.get("version") or "-", r.get("file", ""), r.get("status", ""),
            ", ".join(v or "unversioned" for v in r.get("indexedVersions") or []) or "-"))
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Hindsight recall / retain, the Lodge
# --------------------------------------------------------------------------

def recall_section(cfg: dict, st: dict, stage: str, spec: dict) -> str:
    lines = ["## What the factory remembers",
             "Read-only notes from Hindsight. Use what fits; ignore the rest."]
    token = hindsight_token()
    query = "%s. Stage %s. Paths: %s" % (st.get("title", ""), stage,
                                         ", ".join(spec.get("allowedPaths") or []))
    for template in cfg.get("recallBanks") or []:
        bank = bank_name(template, st["repo"])
        if not token:
            lines.append("From %s: recall unavailable (no token)" % bank)
            continue
        url = "%s/v1/default/banks/%s/memories/recall" % (
            cfg["hindsightUrl"], urllib.parse.quote(bank, safe=""))
        try:
            status, payload = http_json("POST", url, {"query": query, "max_tokens": 1000,
                                                      "budget": "mid"}, token, 20)
        except Exception as exc:  # noqa: BLE001 - recall never fails a stage
            lines.append("From %s: recall unavailable (%s)" % (bank, type(exc).__name__))
            continue
        if not 200 <= status < 300:
            lines.append("From %s: recall unavailable (%d)" % (bank, status))
            continue
        results = as_list(payload, "results", "memories", "items")[:8]
        lines.append("From %s:" % bank)
        texts = [one_line(r.get("text") if isinstance(r, dict) else r, 300) for r in results]
        lines.extend("- " + t for t in texts if t) if any(texts) else lines.append("- (nothing)")
    return "\n".join(lines)


def retain_content(st: dict) -> str:
    lines = ["Factory work order %s: %s" % (st["workOrder"], st.get("title", "")),
             "Outcome: %s" % st["phase"],
             "PR: %s" % ((st.get("pr") or {}).get("url") or "none")]
    groups = {}
    for row in st.get("stages") or []:
        groups.setdefault((row["stage"], row["round"]), []).append(row)
    for (stage, rnd), rows in groups.items():
        parts = ["a%d %s%s" % (r["attempt"], r["result"],
                               (" (%s)" % first_reason(r.get("reasons"))[:200]) if r.get("reasons") else "")
                 for r in rows]
        lines.append("%s r%d: %s" % (stage, rnd, "; ".join(parts)))
        prints = [r.get("fingerprint") for r in rows if r.get("fingerprint")]
        repeated = sorted({p for p in prints if prints.count(p) > 1})
        for fp in repeated:
            lines.append("%s r%d repeated the same failure in attempts %s" % (
                stage, rnd, ", ".join(str(r["attempt"]) for r in rows if r.get("fingerprint") == fp)))
    gate = st.get("gate") or {}
    if gate:
        lines.append("gate: %s%s" % (gate.get("result"), (" (%s)" % first_reason(gate.get("reasons")))
                                     if gate.get("reasons") else ""))
    for f in st.get("blockingFindings") or []:
        if isinstance(f, dict):
            lines.append("confirmed finding %s: %s" % (f.get("id"), one_line(f.get("claim"), 300)))
    if st.get("stallReason"):
        lines.append("Stalled: %s" % st["stallReason"])
    return "\n".join(lines)[:4000]


LODGE_STATE = {"started": "writing", "pass": "idle", "fail": "error", "timeout": "error"}


def lodge_event(cfg: dict, stage: str, detail: str, outcome: str) -> None:
    """One state_change in the envelope the OpenCode Lodge adapter sends
    (version 1, agent, event_type, timestamp, payload). Best effort."""
    name = ((cfg.get("stages") or {}).get(stage) or {}).get("lodge")
    if not name or not cfg.get("lodgeUrl"):
        return
    token = lodge_token(name)
    if not token:
        return
    body = {"version": 1, "agent": name, "event_type": "state_change", "timestamp": iso(),
            "payload": {"state": LODGE_STATE.get(outcome, "idle"), "detail": detail}}
    try:
        status, _ = http_json("POST", cfg["lodgeUrl"] + "/events", body, token, 5)
        if not 200 <= status < 300:
            warn("lodge %s: HTTP %d" % (name, status))
    except Exception as exc:  # noqa: BLE001 - the Lodge is best effort
        warn("lodge %s: %s" % (name, type(exc).__name__))


# --------------------------------------------------------------------------
# the engine
# --------------------------------------------------------------------------

def stage_title(st: dict, stage: str, attempt: int) -> str:
    tags = [stage]
    if st["round"] > 1:
        tags.append("r%d" % st["round"])
    if attempt > 1:
        tags.append("a%d" % attempt)
    return "[%s] %s %s" % (" ".join(tags), st["workOrder"], st.get("title", "")[:120])


def fenced(title: str, prose: str, payload) -> str:
    return "# %s\n\n%s\n\n```json\n%s\n```\n" % (
        title, prose.strip(), json.dumps(payload, indent=1, ensure_ascii=False))


class Engine:
    def __init__(self, cfg: dict, api, apply: bool):
        self.cfg = cfg
        self.api = api
        self.apply = apply
        self.states = []
        self.out = {}
        self.mirror_due = False

    # -- bookkeeping ------------------------------------------------------
    def would(self, what: str) -> None:
        """Every write calls this first: a dry tick stops the step here."""
        if not self.apply:
            raise DryRun(what)

    def save(self, st: dict) -> None:
        self.would("update the state file")
        st["updatedAt"] = iso()
        write_json_atomic(state_path(st["workOrder"]), st)
        self.mirror_due = True

    def mirror(self, st: dict) -> None:
        body = fenced("Engine state", "Written by `engine.py` after every change. People read "
                      "this; the engine never reads it back.", st)
        try:
            self.api.write_document(st["workOrderId"], "engine-state", body, title="engine-state")
        except Exception as exc:  # noqa: BLE001 - the mirror is for people only
            warn("%s: engine-state mirror not written: %s" % (st["workOrder"], exc))

    def note(self, outcome: str, stage: str = "", row=None) -> None:
        self.out["outcome"] = outcome
        if stage:
            self.out["stage"] = stage
        if row:
            self.out["issue"] = row.get("identifier")
            self.out["attempt"] = row.get("attempt")

    def flag(self, name: str) -> None:
        if name not in self.out["flags"]:
            self.out["flags"].append(name)

    def active(self) -> int:
        return sum(1 for s in self.states if s.get("phase") in ACTIVE_PHASES)

    def repo_cfg(self, st: dict) -> dict:
        rc = (self.cfg.get("repos") or {}).get(st["repo"])
        if not rc:
            raise SetupError("repo %s is not in engine.json" % st["repo"])
        return rc

    def spec(self, st: dict) -> dict:
        return factory.load_spec(st["specFile"])

    def comment(self, issue_id: str, text: str) -> None:
        self.api.comment(issue_id, text)

    @staticmethod
    def rows(st: dict, stage: str, rnd: int) -> list:
        return [r for r in st.get("stages") or [] if r["stage"] == stage and r["round"] == rnd]

    def current_row(self, st: dict, stage: str):
        rows = self.rows(st, stage, st["round"])
        return rows[-1] if rows else None

    # -- the tick ---------------------------------------------------------
    def run_order(self, st: dict) -> dict:
        self.out = {"workOrder": st["workOrder"], "flags": [], "outcome": "idle"}
        self.mirror_due = False
        try:
            self.step(st)
        except DryRun as plan:
            self.out["would"] = str(plan)
        except Exception as exc:  # noqa: BLE001 - one order never stops the tick
            self.flag("error")
            self.out["outcome"] = "error"
            self.out["error"] = one_line("%s: %s" % (type(exc).__name__, exc), 400)
            warn("%s: %s" % (st["workOrder"], self.out["error"]))
        if self.mirror_due:
            self.mirror(st)
        row = self.current_row(st, st["phase"]) if st["phase"] in STAGE_PHASES else None
        self.out.update({"phase": st["phase"], "round": st["round"]})
        self.out.setdefault("stage", st["phase"])
        if row:
            self.out.setdefault("issue", row.get("identifier"))
            self.out.setdefault("attempt", row.get("attempt"))
        return self.out

    def step(self, st: dict) -> None:
        phase = st["phase"]
        if phase == "queued":
            self.step_queued(st)
        elif phase in STAGE_PHASES:
            self.step_stage(st)
        elif phase == "gate":
            self.step_gate(st)
        elif phase == "awaiting_merge":
            self.step_merge(st)
        else:
            self.finish(st)

    # -- queued -> librarian / red ------------------------------------------
    def step_queued(self, st: dict) -> None:
        if self.active() >= int(self.cfg.get("maxActiveOrders", 2)):
            self.flag("waiting-slot")
            self.note("queued")
            return
        rc = self.repo_cfg(st)
        clone = rc["clone"]
        if not st.get("baseSha"):
            self.would("git fetch origin in %s and record baseSha" % clone)
            git(clone, "fetch", "--quiet", "origin")
            st["baseSha"] = git(clone, "rev-parse", "--verify",
                                "refs/remotes/origin/%s^{commit}" % st["base"]).strip()
            self.save(st)
        worktree = os.path.join(rc["worktrees"], st["branch"])
        self.ensure_worktree(clone, worktree, st["branch"], st["baseSha"])
        if st.get("worktree") != worktree:
            st["worktree"] = worktree
            self.save(st)
        self.ensure_workspace(st)
        inv = inventory(worktree, self.spec(st), self.cfg.get("docsUrl", ""))
        st["inventory"] = inv["rows"]
        if all(r["status"] == "ok" for r in inv["rows"]):
            st["docsReady"] = ready_rows_from_inventory(inv["rows"])
            self.would("write the docs-ready document and start red")
            self.write_docs_ready(st)
            self.enter(st, "red")
        else:
            self.enter(st, "librarian")

    def ensure_worktree(self, clone: str, path: str, branch: str, base_sha: str) -> None:
        if os.path.isdir(path):
            head = git(path, "rev-parse", "--abbrev-ref", "HEAD", check=False).strip()
            if head == branch:
                return  # a re-run after a crash: reuse it
            raise SetupError("worktree path %s exists but is on %r, not %s" % (path, head, branch))
        self.would("git worktree add %s" % path)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if git(clone, "rev-parse", "--verify", "--quiet", "refs/heads/" + branch, check=False).strip():
            git(clone, "worktree", "add", path, branch)
        else:
            git(clone, "worktree", "add", "-b", branch, path, base_sha)

    def ensure_workspace(self, st: dict) -> None:
        if st.get("workspaceId"):
            return
        name = "wo " + st["workOrder"]
        # A crash between the POST and the state write left a workspace behind:
        # find it by name and cwd instead of creating a second one.
        for ws in as_list(self.api.project_workspaces(st["projectId"]), "workspaces", "items"):
            if isinstance(ws, dict) and ws.get("name") == name and ws.get("cwd") == st["worktree"]:
                st["workspaceId"] = ws["id"]
                self.save(st)
                return
        self.would("create the project workspace %r" % name)
        resp = self.api.post("/projects/%s/workspaces" % st["projectId"],
                             {"name": name, "sourceType": "local_path", "cwd": st["worktree"],
                              "isPrimary": False})
        ws = unwrap(resp, "workspace")
        if not ws.get("id"):
            raise SetupError("workspace create returned no id")
        st["workspaceId"] = ws["id"]
        self.save(st)

    def write_docs_ready(self, st: dict) -> None:
        body = fenced("Docs ready", "Written by the factory engine. The table is for people; the "
                      "json block is the record.\n\n" + docs_table(st["docsReady"]), st["docsReady"])
        self.api.write_document(st["workOrderId"], "docs-ready", body, title="docs-ready")

    def enter(self, st: dict, phase: str) -> None:
        st["phase"] = phase
        self.save(st)
        self.note("enter-" + phase, phase)
        if phase in STAGE_PHASES:
            self.create_stage_issue(st, phase)

    # -- stage issues ---------------------------------------------------------
    def create_stage_issue(self, st: dict, stage: str):
        agent_id = self.cfg["stages"][stage]["agentId"]
        agent = unwrap(self.api.agent(agent_id), "agent")
        if agent.get("status") in ("paused", "terminated"):
            self.flag("agent-paused")
            self.note("agent-paused", stage)
            return None
        rows = self.rows(st, stage, st["round"])
        attempt = len(rows) + 1
        title = stage_title(st, stage, attempt)
        self.would("create %s" % title)
        issue = self.find_open_child(st, title)
        if issue is None:
            body = {"title": title, "description": self.brief(st, stage, rows),
                    "status": "todo", "priority": st.get("priority") or "medium",
                    "parentId": st["workOrderId"], "projectId": st["projectId"],
                    "projectWorkspaceId": st["workspaceId"], "assigneeAgentId": agent_id}
            issue = unwrap(self.api.post("/companies/%s/issues" % st["companyId"], body), "issue")
            if not issue.get("id"):
                raise SetupError("stage issue create returned no id")
        # The tiny window: a crash between the POST above and this save leaves an
        # issue the state does not know. find_open_child adopts it on the re-run.
        row = {"stage": stage, "round": st["round"], "attempt": attempt, "issueId": issue["id"],
               "identifier": issue.get("identifier") or issue["id"], "createdAt": iso(),
               "result": "pending", "reasons": [], "fingerprint": None, "sha": None}
        st.setdefault("stages", []).append(row)
        self.save(st)
        prev = rows[-1] if rows else None
        if prev and prev["result"] in FAILED and not prev.get("commented"):
            self.comment(prev["issueId"], "engine check: FAIL — %s. Next attempt: %s"
                         % (first_reason(prev.get("reasons")), row["identifier"]))
            prev["commented"] = True
            self.save(st)
        lodge_event(self.cfg, stage, self.detail(st, row, "started"), "started")
        self.note("created", stage, row)
        return row

    def find_open_child(self, st: dict, title: str):
        known = {r["issueId"] for r in st.get("stages") or []}
        for issue in self.api.children_of(st["companyId"], st["workOrderId"]):
            if (issue.get("title") == title and issue.get("id") not in known
                    and issue.get("status") not in ("done", "cancelled")):
                return issue
        return None

    @staticmethod
    def detail(st: dict, row: dict, outcome: str) -> str:
        return "%s %s r%d a%d: %s" % (st["workOrder"], row["stage"], row["round"], row["attempt"],
                                       outcome)

    def brief(self, st: dict, stage: str, rows: list) -> str:
        spec = self.spec(st)
        parts = [recall_section(self.cfg, st, stage, spec)]
        if stage == "librarian":
            parts.append("## Docs ready\nThe libraries in scope and what the docs index has for "
                         "them:\n\n" + inventory_table(st.get("inventory") or []))
        else:
            parts.append("## Docs ready\n" + docs_table(st.get("docsReady") or []))
        if rows:
            parts.append(self.last_failed_section(rows))
        if stage == "green" and st["round"] > 1:
            parts.append("## Fix round" + factory.fix_round_findings_block(
                st.get("blockingConfirmed") or [], st.get("blockingFindings") or [],
                st["round"], st.get("lastVerify") or ""))
        parts.append(factory.fill_template("engine/" + stage, self.template_values(st, stage, spec)))
        return "\n\n".join(p.strip() for p in parts) + "\n"

    @staticmethod
    def last_failed_section(rows: list) -> str:
        prev = rows[-1]
        lines = ["## Last attempt failed"]
        same = [r for r in rows[:-1] if r.get("fingerprint") and r["fingerprint"] == prev.get("fingerprint")]
        if same:
            lines.append("SAME FAILURE as attempt %d: find a different cause, do not repeat the "
                         "last fix." % same[-1]["attempt"])
        lines.append("Attempt %d (%s) ended `%s`. The engine check said:"
                     % (prev["attempt"], prev.get("identifier"), prev["result"]))
        lines.append("```")
        lines.append(prev.get("checkLine") or "(no check line)")
        tail = prev.get("outputTail") or []
        if tail:
            lines.append("")
            lines.extend(tail[-TAIL_LINES:])
        lines.append("```")
        return "\n".join(lines)

    def template_values(self, st: dict, stage: str, spec: dict) -> dict:
        return {
            "workOrder": st["workOrder"], "workOrderTitle": st.get("title", ""),
            "repo": st["repo"], "worktree": st.get("worktree", ""), "branch": st["branch"],
            "base": st["base"], "baseSha": st.get("baseSha", ""), "kind": spec.get("kind", ""),
            "allowedPaths": ", ".join("`%s`" % p for p in spec.get("allowedPaths", [])),
            "acs": "\n".join("   - %s: %s" % (a["id"], a["text"]) for a in spec.get("acs", [])),
            "checkCommands": "\n".join("   - `%s`" % a["check"] for a in spec.get("acs", [])),
            "maxDiffLines": spec.get("maxDiffLines", 400),
            "roundSuffix": "" if st["round"] == 1 else " r%d" % st["round"],
            "redSha": st.get("redSha") or "(red not committed)",
            "findingsJson": json.dumps(st.get("findings") or [], indent=1, ensure_ascii=False),
            "docsUrl": self.cfg.get("docsUrl", ""),
            "timeoutMinutes": (self.cfg.get("stageTimeoutMinutes") or {}).get(stage, 60),
        }

    # -- waiting on a stage issue -----------------------------------------------
    def step_stage(self, st: dict) -> None:
        stage = st["phase"]
        row = self.current_row(st, stage)
        if row is not None and row["result"] in FAILED:
            failed = [r for r in self.rows(st, stage, st["round"]) if r["result"] in FAILED]
            if len(failed) >= int(self.cfg.get("maxAttempts", 3)):
                self.stall(st, self.attempts_sentence(st, stage, failed))
                return
        if row is None or row["result"] != "pending":
            self.create_stage_issue(st, stage)
            return
        issue = unwrap(self.api.issue(row["issueId"]), "issue")
        status = issue.get("status")
        self.note("pending", stage, row)
        if status in ("done", "in_review"):
            getattr(self, "judge_" + stage)(st, row)
        elif status == "cancelled":
            self.fail_attempt(st, row, "fail", ["stage issue cancelled by %s" % self.who(issue)])
        elif status == "blocked":
            self.fail_attempt(st, row, "fail", [self.last_comment(row["issueId"])
                                                or "the agent set the stage issue blocked"])
        else:
            self.check_timeout(st, row, stage, issue)

    @staticmethod
    def who(issue: dict) -> str:
        for key in ("cancelledByAgentId", "cancelledByUserId", "updatedByAgentId", "updatedByUserId"):
            if issue.get(key):
                return str(issue[key])
        return "someone else"

    def last_comment(self, issue_id: str) -> str:
        try:
            comments = as_list(self.api.get("/issues/%s/comments" % issue_id), "comments", "items")
        except pc.ApiError:
            return ""
        comments = [c for c in comments if isinstance(c, dict) and c.get("body")]
        if not comments:
            return ""
        comments.sort(key=lambda c: c.get("createdAt") or "")
        return one_line(comments[-1]["body"], 300)

    def check_timeout(self, st: dict, row: dict, stage: str, issue: dict) -> None:
        limit = float((self.cfg.get("stageTimeoutMinutes") or {}).get(stage, 60))
        age = minutes_since(row["createdAt"])
        reason = ""
        if age >= limit:
            reason = "timeout: no result after %d minutes (limit %d)" % (age, limit)
        else:
            idle_limit = float(self.cfg.get("idleMinutes", 15))
            idle = minutes_since(issue.get("updatedAt") or row["createdAt"])
            if idle >= idle_limit:
                runs = self.api.runs(row["issueId"])
                if runs is not None and not any(isinstance(r, dict) and r.get("status") in LIVE_RUN_STATUSES
                                                for r in runs):
                    reason = "timeout: no live run and no update for %d minutes" % idle
        if not reason:
            self.flag("waiting")
            return
        self.would("cancel %s (%s)" % (row["identifier"], reason))
        self.api.patch_issue(row["issueId"], {"status": "cancelled",
                                              "comment": "engine: %s. This attempt is cancelled." % reason})
        self.fail_attempt(st, row, "timeout", [reason])

    def fail_attempt(self, st: dict, row: dict, result: str, reasons: list,
                     check_line: str = "", tail=None) -> None:
        self.would("record %s of %s" % (result, row["identifier"]))
        if row["stage"] == "librarian":
            self.librarian_fallback(st, row, result, reasons)
            return
        row.update({"result": result, "reasons": reasons, "fingerprint": fingerprint(reasons),
                    "checkLine": check_line or json.dumps(
                        {"ok": False, "check": "engine-" + row["stage"], "reasons": reasons},
                        ensure_ascii=False),
                    "outputTail": list(tail or [])[-TAIL_LINES:], "finishedAt": iso()})
        self.save(st)
        lodge_event(self.cfg, row["stage"], self.detail(st, row, result), result)
        self.note(result, row["stage"], row)
        failed = [r for r in self.rows(st, row["stage"], st["round"]) if r["result"] in FAILED]
        if len(failed) >= int(self.cfg.get("maxAttempts", 3)):
            self.stall(st, self.attempts_sentence(st, row["stage"], failed))
        else:
            self.create_stage_issue(st, row["stage"])

    def attempts_sentence(self, st: dict, stage: str, failed: list) -> str:
        last = failed[-1]
        if not last.get("commented"):
            self.comment(last["issueId"], "engine check: FAIL — %s. No next attempt: %d attempts "
                         "failed, so the work order is stalled." % (first_reason(last.get("reasons")),
                                                                    len(failed)))
            last["commented"] = True
        return ("The %s stage failed %d attempts in round %d, last: %s."
                % (stage, len(failed), st["round"], first_reason(last.get("reasons"))))

    def librarian_fallback(self, st: dict, row: dict, result: str, reasons: list) -> None:
        """The librarian never stops an order (ENGINE.md, Judging)."""
        st["docsReady"] = ready_rows_from_inventory(st.get("inventory") or [], first_reason(reasons))
        self.write_docs_ready(st)
        self.comment(row["issueId"], "engine check: %s — %s. The librarian gets one attempt: red "
                     "starts with `no docs:` rows." % (result.upper(), first_reason(reasons)))
        row.update({"result": result, "reasons": reasons, "fingerprint": fingerprint(reasons),
                    "commented": True, "finishedAt": iso()})
        lodge_event(self.cfg, "librarian", self.detail(st, row, result), result)
        self.enter(st, "red")

    # -- judging ----------------------------------------------------------------
    def passed(self, st: dict, row: dict, sha=None) -> None:
        row.update({"result": "pass", "reasons": [], "sha": sha, "finishedAt": iso()})
        lodge_event(self.cfg, row["stage"], self.detail(st, row, "pass"), "pass")

    def judge_librarian(self, st: dict, row: dict) -> None:
        self.would("judge %s (librarian)" % row["identifier"])
        rows, reason = parse_docs_ready(self.api.document(row["issueId"], "docs-ready"),
                                        st.get("inventory") or [])
        if reason:
            self.fail_attempt(st, row, "fail", [reason])
            return
        st["docsReady"] = rows
        self.write_docs_ready(st)
        self.passed(st, row)
        self.enter(st, "red")

    def judge_red(self, st: dict, row: dict) -> None:
        self.would("judge %s: factory.py check-red" % row["identifier"])
        res = run_factory(["check-red", "--repo", st["worktree"], "--base", st["baseSha"],
                           "--spec", st["specFile"]]).require_json()
        if not res.ok:
            self.fail_attempt(st, row, "fail", res.reasons, res.line, res.tail)
            return
        com = run_factory(["commit", "--repo", st["worktree"], "--stage", "red",
                           "--issue", st["workOrder"]]).require_json()
        if not com.ok:
            self.fail_attempt(st, row, "fail", com.reasons, com.line, com.tail)
            return
        st["redSha"] = com.parsed["sha"]
        self.passed(st, row, st["redSha"])
        self.enter(st, "green")

    def judge_green(self, st: dict, row: dict) -> None:
        self.would("judge %s: factory.py check-green" % row["identifier"])
        res = run_factory(["check-green", "--repo", st["worktree"], "--red", st["redSha"],
                           "--spec", st["specFile"]]).require_json()
        if not res.ok:
            self.fail_attempt(st, row, "fail", res.reasons, res.line, res.tail)
            return
        com = run_factory(["commit", "--repo", st["worktree"], "--stage", "green",
                           "--issue", st["workOrder"]]).require_json()
        if not com.ok:
            self.fail_attempt(st, row, "fail", com.reasons, com.line, com.tail)
            return
        sha = com.parsed["sha"]
        pr = st.get("pr") or {}
        # open-pr / push failing is not the Builder's fault: raise, the step re-runs
        # next tick (check-green passes again, commit hands back HEAD).
        if not pr.get("number"):
            op = run_factory(["open-pr", "--repo", st["worktree"], "--issue", st["workOrder"],
                              "--title", "factory(%s): %s" % (st["workOrder"], st.get("title", ""))])
            if not op.ok:
                raise SetupError("open-pr failed: %s" % "; ".join(op.reasons))
            url = op.parsed["url"]
            m = re.search(r"/pull/([0-9]+)", url)
            st["pr"] = {"number": int(m.group(1)) if m else 0, "url": url, "head": sha}
        else:
            push = run_factory(["push", "--repo", st["worktree"], "--issue", st["workOrder"]])
            if not push.ok:
                raise SetupError("push failed: %s" % "; ".join(push.reasons))
            pr["head"] = sha
            st["pr"] = pr
        self.passed(st, row, sha)
        self.enter(st, "review")

    def document_file(self, st: dict, row: dict, key: str):
        doc = self.api.document(row["issueId"], key)
        body = doc.get("body") if isinstance(doc, dict) else None
        if not isinstance(body, str) or not body.strip():
            return None, None
        path = os.path.join(state_dir(), "%s.%s.%s.md" % (st["workOrder"], row["identifier"], key))
        write_text_atomic(path, body)
        return path, body

    def judge_review(self, st: dict, row: dict) -> None:
        self.would("judge %s: factory.py check-findings" % row["identifier"])
        path, body = self.document_file(st, row, "findings")
        if path is None:
            self.fail_attempt(st, row, "fail", ["no findings document on %s" % row["identifier"]])
            return
        res = run_factory(["check-findings", "--repo", st["worktree"], "--base", st["baseSha"],
                           "--findings", path]).require_json()
        if not res.ok:
            self.fail_attempt(st, row, "fail", res.reasons, res.line, res.tail)
            return
        value, _ = factory.extract_json_block(body, "findings")
        st["findings"] = value or []
        self.passed(st, row)
        self.enter(st, "verify" if st["findings"] else "gate")

    def judge_verify(self, st: dict, row: dict) -> None:
        self.would("judge %s: factory.py check-verdicts" % row["identifier"])
        path, _ = self.document_file(st, row, "verdicts")
        if path is None:
            self.fail_attempt(st, row, "fail", ["no verdicts document on %s" % row["identifier"]])
            return
        findings_path = os.path.join(state_dir(), "%s.findings-r%d.md" % (st["workOrder"], st["round"]))
        write_text_atomic(findings_path, fenced("Findings", "The review findings this verify judged.",
                                                st.get("findings") or []))
        res = run_factory(["check-verdicts", "--findings", findings_path,
                           "--verdicts", path]).require_json()
        if not res.ok:
            self.fail_attempt(st, row, "fail", res.reasons, res.line, res.tail)
            return
        st["blockingConfirmed"] = list(res.parsed.get("blockingConfirmed") or [])
        st["blockingFindings"] = list(res.parsed.get("blockingFindings") or [])
        st["lastVerify"] = row["identifier"]
        self.passed(st, row)
        if not st["blockingConfirmed"]:
            self.enter(st, "gate")
            return
        max_rounds = int(self.cfg.get("maxFixRounds", 2)) + 1
        if st["round"] + 1 > max_rounds:
            self.stall(st, "Verify confirmed blocking findings (%s) in round %d and the fix-round "
                       "limit is spent." % (", ".join(st["blockingConfirmed"]), st["round"]))
            return
        st["round"] += 1
        self.enter(st, "green")

    # -- gate -------------------------------------------------------------------
    def step_gate(self, st: dict) -> None:
        pr = st.get("pr") or {}
        self.note("gate", "gate")
        if not pr.get("number"):
            self.would("stall: no PR")
            self.stall(st, "The gate has no PR to check.")
            return
        state = check_run_state(gh_pr_checks(st["repo"], pr["number"]))
        if state == "pending":
            if not st.get("gateSince"):
                self.would("start the CI wait for PR #%s" % pr["number"])
                st["gateSince"] = iso()
                self.save(st)
            if minutes_since(st["gateSince"]) < float(self.cfg.get("gateCiWaitMinutes", 60)):
                self.flag("ci-pending")
                self.note("waiting", "gate")
                return
        self.would("run factory.py check-gate on PR #%s" % pr["number"])
        res = run_factory(["check-gate", "--pr", "%s#%s" % (st["repo"], pr["number"]),
                           "--spec", st["specFile"]]).require_json()
        st["gate"] = {"result": "pass" if res.ok else "fail", "reasons": res.reasons, "at": iso()}
        if not res.ok:
            self.stall(st, "The gate failed on PR #%s: %s." % (pr["number"], "; ".join(res.reasons[:3])))
            return
        note = (res.parsed or {}).get("sizeNote")
        comment = "PR %s passed the gate: merge it on GitHub." % (pr.get("url") or "#%s" % pr["number"])
        if note:
            comment = note + "\n\n" + comment
        self.api.patch_issue(st["workOrderId"], {"status": "in_review", "comment": comment})
        st["phase"] = "awaiting_merge"
        self.save(st)
        self.note("pass", "gate")

    # -- awaiting_merge -----------------------------------------------------------
    def step_merge(self, st: dict) -> None:
        pr = st.get("pr") or {}
        try:
            view = factory.gh_json(["pr", "view", str(pr.get("number")), "--repo", st["repo"],
                                    "--json", "state,mergedAt,mergeCommit,headRefOid"])
        except SetupError as exc:
            self.flag("merge-unknown")
            warn("%s: %s" % (st["workOrder"], exc))
            return
        state = str((view or {}).get("state") or "").upper()
        self.note("waiting", "merge")
        if state == "OPEN":
            self.flag("pr-open")
            return
        number = pr.get("number")
        if state == "CLOSED":
            self.would("settle closed PR #%s" % number)
            st["phase"] = "closed"
            st["notice"] = {"status": "blocked", "executionPolicy": None,
                            "comment": "PR #%s was closed without a merge, so nothing shipped." % number}
            self.save(st)
            self.note("closed", "merge")
            self.finish(st)
            return
        if state != "MERGED":
            self.flag("merge-unknown")
            return
        merge_sha = ((view.get("mergeCommit") or {}).get("oid") or "")
        head = pr.get("head") or view.get("headRefOid") or ""
        self.would("settle merged PR #%s" % number)
        landed = factory.merge_contains(self.repo_cfg(st)["clone"], head, merge_sha)
        if landed is None:
            self.flag("merge-unknown")
            return
        st["merge"] = {"state": "MERGED" if landed else "unlanded", "sha": merge_sha,
                       "head": head, "at": view.get("mergedAt")}
        if not landed:
            self.stall(st, factory.unlanded_reason(number, head, merge_sha))
            return
        st["phase"] = "done"
        st["notice"] = {"status": "done", "comment": "PR #%s is merged in %s" % (number, merge_sha)}
        self.save(st)
        self.note("done", "merge")
        self.finish(st)

    # -- terminal phases ---------------------------------------------------------
    def stall(self, st: dict, sentence: str) -> None:
        self.would("stall: %s" % sentence)
        st["phase"] = "stalled"
        st["stallReason"] = sentence
        st["notice"] = {"status": "blocked", "executionPolicy": None, "comment": sentence}
        self.save(st)
        self.note("stalled")
        self.finish(st)

    def finish(self, st: dict) -> None:
        """Retain, clean up, tell the work order. Each part runs once and is
        recorded, so a crash in between is finished by the next tick."""
        if not st.get("retained") and int(st.get("retainTries") or 0) < RETAIN_MAX_TRIES:
            self.retain(st)
        if st["phase"] in ("done", "closed") and not st.get("cleanedUp"):
            self.cleanup(st)
        if st.get("notice") and not st.get("noticeSent"):
            self.would("PATCH the work order %s" % st["notice"]["status"])
            body = dict(st["notice"])
            if st.get("cleanupNote"):
                body["comment"] = "%s\n\n%s" % (body["comment"], st["cleanupNote"])
            self.api.patch_issue(st["workOrderId"], body)
            st["noticeSent"] = True
            self.save(st)
        if st.get("retained") or int(st.get("retainTries") or 0) >= RETAIN_MAX_TRIES:
            self.note(self.out.get("outcome") if self.out.get("outcome") not in ("idle",) else st["phase"])

    def retain(self, st: dict) -> None:
        self.would("retain the outcome in Hindsight")
        token = hindsight_token()
        bank = bank_name(self.cfg.get("retainBank") or "", st["repo"])
        error = ""
        if not token:
            error = "no token"
        else:
            url = "%s/v1/default/banks/%s/memories" % (self.cfg["hindsightUrl"],
                                                       urllib.parse.quote(bank, safe=""))
            body = {"async": True, "items": [{
                "content": retain_content(st), "context": "factory work order outcome",
                "document_id": "factory-" + st["workOrder"], "tags": ["factory", st["workOrder"]],
                "timestamp": iso()}]}
            try:
                status, _ = http_json("POST", url, body, token, 20)
                if not 200 <= status < 300:
                    error = "HTTP %d" % status
            except Exception as exc:  # noqa: BLE001 - retried next tick
                error = type(exc).__name__
        if error:
            st["retainTries"] = int(st.get("retainTries") or 0) + 1
            warn("%s: retain failed (%s), try %d of %d%s" % (
                st["workOrder"], error, st["retainTries"], RETAIN_MAX_TRIES,
                ", giving up" if st["retainTries"] >= RETAIN_MAX_TRIES else ""))
        else:
            st["retained"] = True
        self.save(st)

    def cleanup(self, st: dict) -> None:
        self.would("delete the workspace and remove the worktree")
        if st.get("workspaceId") and not st.get("workspaceDeleted"):
            try:
                self.api.delete("/projects/%s/workspaces/%s" % (st["projectId"], st["workspaceId"]))
            except pc.ApiError as exc:
                if exc.status != 404:
                    raise
            st["workspaceDeleted"] = True
            self.save(st)
        wt = st.get("worktree")
        note = ""
        if wt and os.path.isdir(wt):
            dirty = git(wt, "status", "--porcelain").strip()
            if dirty:
                note = "The worktree %s has uncommitted changes, so it stays." % wt
            else:
                git(self.repo_cfg(st)["clone"], "worktree", "remove", wt)
        st["cleanedUp"] = True
        st["cleanupNote"] = note
        self.save(st)


# --------------------------------------------------------------------------
# status lines
# --------------------------------------------------------------------------

def status_line(st: dict, last: dict) -> dict:
    row = None
    if st["phase"] in STAGE_PHASES:
        rows = [r for r in st.get("stages") or [] if r["stage"] == st["phase"] and r["round"] == st["round"]]
        row = rows[-1] if rows else None
    since = (row or {}).get("createdAt") or st.get("updatedAt") or st.get("createdAt")
    flags = list((last or {}).get("flags") or [])
    if st["phase"] in STAGE_PHASES and (row is None or row["result"] != "pending") and "no-issue" not in flags:
        flags.append("no-issue")
    if st["phase"] in TERMINAL_PHASES and not st.get("retained"):
        flags.append("retain-pending")
    return {"workOrder": st["workOrder"], "phase": st["phase"], "round": st["round"],
            "issue": (row or {}).get("identifier"), "attempt": (row or {}).get("attempt"),
            "ageMinutes": int(minutes_since(since)), "flags": flags}


# --------------------------------------------------------------------------
# subcommands
# --------------------------------------------------------------------------

def cmd_start(args) -> int:
    wo = args.work_order.strip().upper()
    if not re.match(r"^GUL-[0-9]+$", wo):
        raise SetupError("work order must be GUL-<n>, got %r" % args.work_order)
    if os.path.exists(stop_file()):
        emit(False, "start", ["stopped: the STOP file exists"], {"workOrder": wo})
        return 1
    if os.path.exists(state_path(wo)):
        emit(True, "start", [], {"workOrder": wo, "already": True})
        return 0
    cfg = load_config()
    api = paperclip_api()
    issue = api.by_identifier(None, wo)
    if not issue:
        raise SetupError("work order %s not found" % wo)
    doc = api.document(issue["id"], "spec")
    body = doc.get("body") if isinstance(doc, dict) else None
    if not isinstance(body, str) or not body.strip():
        emit(False, "start", ["%s has no spec document" % wo], {"workOrder": wo})
        return 1
    with tempfile.TemporaryDirectory() as tmp:
        lint_path = os.path.join(tmp, "spec.md")
        with open(lint_path, "w", encoding="utf-8") as fh:
            fh.write(body)
        lint = run_factory(["lint-spec", "--spec", lint_path])
        if not lint.ok:
            emit(False, "start", ["spec: " + r for r in lint.reasons], {"workOrder": wo})
            return 1
        spec = factory.load_spec(lint_path)
    if spec["repo"] not in (cfg.get("repos") or {}):
        emit(False, "start", ["repo %s is not in engine.json" % spec["repo"]], {"workOrder": wo})
        return 1
    number = wo.split("-", 1)[1]
    st = {"version": 1, "workOrder": wo, "workOrderId": issue["id"], "title": issue.get("title", ""),
          "projectId": issue.get("projectId"), "companyId": issue.get("companyId"),
          "priority": issue.get("priority") or "medium", "repo": spec["repo"], "base": spec["base"],
          "baseSha": None, "branch": "gul-%s-%s" % (number, factory.slugify(issue.get("title", ""))),
          "worktree": None, "workspaceId": None,
          "specFile": os.path.join(state_dir(), wo + ".spec.md"),
          "specRevisionId": (doc or {}).get("latestRevisionId"), "phase": "queued", "round": 1,
          "docsReady": [], "stages": [], "redSha": None, "pr": {"number": 0, "url": "", "head": ""},
          "merge": None, "findings": [], "blockingConfirmed": [], "stallReason": None,
          "retained": False, "createdAt": iso(), "updatedAt": iso()}
    if not st["projectId"] or not st["companyId"]:
        raise SetupError("work order %s has no projectId or companyId" % wo)
    if args.dry_run:
        emit(True, "start", [], {"workOrder": wo, "dryRun": True,
                                 "plan": {"branch": st["branch"], "repo": st["repo"], "base": st["base"]}},
             "engine-start: %s would be queued on %s" % (wo, st["branch"]))
        return 0
    # No assignee: Paperclip refuses (409) to assign a paused agent, an active one would wake a model,
    # and `in_progress` requires an assignee (422). So the work order stays `todo`, unassigned; its
    # real phase is the `engine-state` document.
    api.patch_issue(issue["id"], {"status": "todo",
                                  "comment": "The factory engine took this work order. Branch `%s`; "
                                  "the next tick starts it when a slot is free." % st["branch"]})
    write_text_atomic(st["specFile"], body)
    write_json_atomic(state_path(wo), st)
    try:
        api.write_document(issue["id"], "engine-state",
                           fenced("Engine state", "Written by `engine.py` after every change.", st),
                           title="engine-state")
    except Exception as exc:  # noqa: BLE001 - the mirror is for people only
        warn("%s: engine-state mirror not written: %s" % (wo, exc))
    emit(True, "start", [], {"workOrder": wo, "phase": "queued", "branch": st["branch"]},
         "engine-start: %s queued on %s" % (wo, st["branch"]))
    return 0


def cmd_tick(args) -> int:
    if os.path.exists(stop_file()):
        emit(True, "tick", ["stopped"], {"stopped": True}, "engine-tick: stopped")
        return 0
    folder = state_dir()
    if args.apply:
        os.makedirs(folder, exist_ok=True)
    lock = None
    lock_path = os.path.join(folder, "engine.lock")
    # A dry tick writes nothing anywhere, not even the lock file: it locks one
    # that already exists and otherwise runs unlocked (it changes nothing).
    if args.apply or os.path.exists(lock_path):
        lock = open(lock_path, "a" if args.apply else "r")
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            lock.close()
            emit(True, "tick", ["busy"], {"busy": True}, "engine-tick: busy")
            return 0
    try:
        cfg = load_config()
        states = list_states()
        if not states:
            emit(True, "tick", [], {"apply": bool(args.apply), "orders": []}, "engine-tick: no orders")
            return 0
        engine = Engine(cfg, paperclip_api(), bool(args.apply))
        engine.states = states
        lines = [engine.run_order(st) for st in states]
        if args.apply:
            record_tick(lines)
    finally:
        if lock:
            lock.close()
    errors = ["%s: %s" % (l["workOrder"], l.get("error")) for l in lines if "error" in l["flags"]]
    summary = "\n".join("engine-tick: %s %s %s%s%s" % (
        l["workOrder"], l["phase"], l.get("outcome"),
        (" [%s]" % ",".join(l["flags"])) if l["flags"] else "",
        (" would: %s" % l["would"]) if l.get("would") else "") for l in lines)
    emit(not errors, "tick", errors, {"apply": bool(args.apply), "orders": lines}, summary)
    return 1 if errors else 0


def record_tick(lines: list) -> None:
    folder = state_dir()
    stamp = iso()
    with open(os.path.join(folder, "ledger.jsonl"), "a", encoding="utf-8") as fh:
        for l in lines:
            fh.write(json.dumps({"time": stamp, "workOrder": l["workOrder"], "phase": l["phase"],
                                 "stage": l.get("stage"), "round": l.get("round"),
                                 "attempt": l.get("attempt"), "outcome": l.get("outcome"),
                                 "issue": l.get("issue")}, ensure_ascii=False) + "\n")
    write_json_atomic(os.path.join(folder, "last-tick.json"),
                      {l["workOrder"]: {"at": stamp, "flags": l["flags"], "outcome": l.get("outcome")}
                       for l in lines})


def cmd_status(args) -> int:
    states = list_states()
    if args.work_order:
        wanted = args.work_order.strip().upper()
        states = [s for s in states if s["workOrder"] == wanted]
        if not states:
            emit(False, "status", ["no state for %s" % wanted])
            return 1
    try:
        with open(os.path.join(state_dir(), "last-tick.json"), "r", encoding="utf-8") as fh:
            last = json.load(fh)
    except (OSError, ValueError):
        last = {}
    lines = [status_line(s, last.get(s["workOrder"])) for s in states]
    summary = "\n".join("engine-status: %s %s r%s %s a%s %dm %s" % (
        l["workOrder"], l["phase"], l["round"], l["issue"] or "-", l["attempt"] or "-",
        l["ageMinutes"], ",".join(l["flags"])) for l in lines) or "engine-status: no orders"
    emit(True, "status", [], {"orders": lines}, summary)
    return 0


def cmd_inventory(args) -> int:
    spec = factory.load_spec(args.spec)
    result = inventory(os.path.abspath(args.repo), spec, load_config().get("docsUrl", ""))
    summary = "engine-inventory: %d rows, docs index %s" % (len(result["rows"]), result["docsIndex"])
    emit(True, "inventory", [], result, summary)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="engine.py", description="model-free factory engine")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("start")
    p.add_argument("work_order")
    p.add_argument("--dry-run", action="store_true")
    p = sub.add_parser("tick")
    p.add_argument("--apply", action="store_true")
    p = sub.add_parser("status")
    p.add_argument("work_order", nargs="?")
    p = sub.add_parser("inventory")
    p.add_argument("--repo", required=True)
    p.add_argument("--spec", required=True)
    return parser


def main(argv: list) -> int:
    try:
        args = build_parser().parse_args(argv)
    except SystemExit as exc:
        if exc.code in (0, None):
            return 0
        emit(False, "usage", ["bad arguments"])
        return 2
    handlers = {"start": cmd_start, "tick": cmd_tick, "status": cmd_status, "inventory": cmd_inventory}
    try:
        return handlers[args.cmd](args)
    except (SetupError, pc.ApiError, OSError) as exc:
        emit(False, args.cmd, ["setup error: %s" % one_line(exc, 500)])
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
