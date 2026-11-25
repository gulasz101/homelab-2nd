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
import ghapp  # noqa: E402
import pc  # noqa: E402

SetupError = factory.SetupError

STAGE_PHASES = ("librarian", "red", "green", "review", "verify", "investigate")
ACTIVE_PHASES = STAGE_PHASES + ("gate",)
TERMINAL_PHASES = ("done", "closed", "stalled")
LIVE_RUN_STATUSES = {"queued", "running", "starting"}
PENDING_CHECK_STATES = {"PENDING", "QUEUED", "IN_PROGRESS", "EXPECTED", "WAITING", "REQUESTED"}
FAILED = ("fail", "timeout")
# A run that failed on the provider's usage limit (the Claude subscription's 5-hour or weekly
# cap). Not the agent's fault, so it uses no attempt: the stage moves to its fallback agent.
LIMIT_RE = re.compile(r"hit your [^\n]*limit|usage limit|rate limit|terminal limit failure|"
                      r"quota exceeded|429 too many requests", re.I)
TAIL_LINES = 60
MAX_FAIL_LINES = 200  # every FAIL line of a check is kept, not only the tail (GUL-2037)


def fail_lines(combined) -> list:
    """Every line of a check's output that starts with FAIL (scripts/check.sh prints
    `FAIL <test> (<s>)`), in order, de-duplicated, capped. The tail alone lost the name
    of the failed test on GUL-2132/2133 (2026-11-24)."""
    out = []
    for ln in (combined or "").splitlines():
        ln = ln.strip()
        if re.match(r"FAIL(ED)?\b", ln) and ln[:300] not in out:
            out.append(ln[:300])
            if len(out) >= MAX_FAIL_LINES:
                break
    return out


def fail_block(lines) -> list:
    """Markdown lines for a row's FAIL lines, empty when there are none."""
    if not lines:
        return []
    return ["Every FAIL line of the check (%d):" % len(lines), "```"] + list(lines) + ["```"]
INVENTORY_MAX_ROWS = 25
RETAIN_MAX_TRIES = 3
# The stall ladder (phase 3): what the Investigator may say, and what each verdict does.
VERDICTS = ("CODE-WRONG", "TEST-WRONG", "SPEC-WRONG", "ENV")
INVESTIGATE_ATTEMPTS = 2


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
        self.fails = fail_lines(combined)

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

def validate_investigation(value) -> list:
    if not isinstance(value, dict):
        return ["investigation: the json block must be one object"]
    reasons = []
    if value.get("verdict") not in VERDICTS:
        reasons.append("investigation: verdict must be one of %s" % ", ".join(VERDICTS))
    if not isinstance(value.get("cause"), str) or not value["cause"].strip():
        reasons.append("investigation: cause must be a non-empty string")
    if not isinstance(value.get("advice", ""), str):
        reasons.append("investigation: advice must be a string")
    if value.get("verdict") == "SPEC-WRONG" and not str(value.get("amend") or "").strip().startswith("AMEND:"):
        reasons.append("investigation: SPEC-WRONG needs an `amend` string that starts with `AMEND:`")
    return reasons


def stage_title(st: dict, stage: str, attempt: int) -> str:
    tags = [stage]
    if st.get("ladder"):
        tags.append("L%d" % st["ladder"])
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

    def repo_setting(self, st: dict, key: str):
        """A per-repo key from `repos.<repo>.` when it is set, else the global one.

        GUL-2238: repos joining the factory differ in how much rope they give it
        (`autoMerge`, `postMergeCheck`, `neverPaths`); the global key stays the
        default so every existing repo entry keeps today's behaviour.
        """
        rc = self.repo_cfg(st)
        if key in rc:
            return rc[key]
        return self.cfg.get(key)

    def never_paths_list(self, st: dict) -> str:
        """The never-path list governing this order, or "" when nothing proves one.

        The repo's own `neverPaths`, else the list the gate recorded it judged by
        (the shipped one, for an order written before GUL-2238). Empty means the
        engine cannot say what is off-limits, so only the owner merges.
        """
        own = str(self.repo_cfg(st).get("neverPaths") or "")
        if own:
            return own
        return str((st.get("gate") or {}).get("neverPaths") or "")

    def spec(self, st: dict) -> dict:
        return factory.load_spec(st["specFile"])

    def comment(self, issue_id: str, text: str) -> None:
        self.api.comment(issue_id, text)

    @staticmethod
    def rows(st: dict, stage: str, rnd: int) -> list:
        # `ladder` is the stall-ladder step: each investigation starts a fresh count of attempts.
        lad = st.get("ladder") or 0
        return [r for r in st.get("stages") or [] if r["stage"] == stage and r["round"] == rnd
                and (r.get("ladder") or 0) == lad]

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
        elif phase == "deploy_check":
            self.step_deploy(st)
        elif phase == "reverting":
            self.step_revert(st)
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
        problem = self.baseline_problem(st)
        if problem:
            # No stage ever ran: there is no stage to investigate, so no [stall] wake issue
            # is filed. The blocked work order, with its unblock note owned by the stall
            # owner, is the whole message.
            self.stall(st, problem, wake=False)
            return
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

    def baseline_problem(self, st: dict) -> str:
        """GUL-2228: an AC whose check already reports PASS on the base tree proves nothing.
        The engine runs the same check the red stage will, on the tree it just cut at
        `baseSha`, and stalls the order as SPEC-WRONG before any stage issue exists.
        A check that cannot run yet (no script, a setup error) is not a PASS, and a
        check-baseline that could not be trusted (exit 2) is no proof of a bad spec:
        both start the order as it always started."""
        res = run_factory(["check-baseline", "--repo", st["worktree"], "--spec", st["specFile"]])
        if res.ok:
            return ""
        if res.code != 1 or not res.reasons:
            warn("%s: check-baseline did not run: %s" % (st["workOrder"], one_line(res.combined)))
            return ""
        return ("SPEC-WRONG: an acceptance check already passes on the base tree at %s: %s. "
                "A check that passes before the change can never go red, so no stage can prove "
                "anything. Amend the spec's AC checks so they fail on the base (a person decides: "
                "the frozen spec is never changed by a model)."
                % (st["baseSha"][:12], "; ".join(res.reasons)))

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
    def stage_agent(self, st: dict, stage: str) -> str:
        """The stage's agent; the stronger one for the one retry after a CODE-WRONG verdict."""
        if st.get("strongStage") == stage:
            strong = (self.cfg.get("strongAgents") or {}).get(stage)
            if strong:
                return strong
        if stage in (st.get("fallbackStages") or []):
            fallback = (self.cfg.get("fallbackAgents") or {}).get(stage)
            if fallback:
                return fallback
        conf = (self.cfg.get("stages") or {}).get(stage)
        if not conf or not conf.get("agentId"):
            raise SetupError("engine.json has no agent for the %s stage" % stage)
        return conf["agentId"]

    def max_attempts(self, st: dict, stage: str) -> int:
        if stage == "investigate":
            return INVESTIGATE_ATTEMPTS
        if st.get("strongStage") == stage:
            return 1  # "a stronger model once" (the stall ladder)
        return int(self.cfg.get("maxAttempts", 3))

    def create_stage_issue(self, st: dict, stage: str):
        # Checked here too, not only at the start of step_stage: a stage's own check can
        # remove the worktree, and the next attempt was then created in the same tick with
        # no worktree; its agent fell back to the shared clone (GUL-2083, 2026-11-23).
        problem = self.worktree_problem(st)
        if problem:
            self.flag("worktree-missing")
            self.stall(st, problem + " No stage runs until it is back; no attempt was used.")
            return None
        agent_id = self.stage_agent(st, stage)
        agent = unwrap(self.api.agent(agent_id), "agent")
        if agent.get("status") in ("paused", "terminated"):
            self.flag("agent-paused")
            self.note("agent-paused", stage)
            return None
        problem = self.prepare_claude_guard(st, agent_id) or self.prepare_builder_test_paths(st)
        if problem:
            self.flag("guard-missing")
            self.stall(st, problem + " The agent does not run without its guard; no attempt was used.")
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
        row = {"stage": stage, "round": st["round"], "ladder": st.get("ladder") or 0,
               "attempt": attempt, "issueId": issue["id"],
               "identifier": issue.get("identifier") or issue["id"], "createdAt": iso(),
               "result": "pending", "reasons": [], "fingerprint": None, "sha": None}
        st.setdefault("stages", []).append(row)
        self.save(st)
        prev = rows[-1] if rows else None
        if prev and prev["result"] in FAILED and not prev.get("commented"):
            # Unassign first. The engine posts as a board user, and Paperclip reopens a
            # closed or blocked issue on a user comment when it has an assignee: the old
            # attempt's agent then runs again next to the new one (GUL-2074, 2026-11-23).
            self.api.patch_issue(prev["issueId"], {"assigneeAgentId": None})
            self.comment(prev["issueId"], "engine check: FAIL — %s. Next attempt: %s"
                         % (first_reason(prev.get("reasons")), row["identifier"]))
            prev["commented"] = True
            self.save(st)
        lodge_event(self.cfg, stage, self.detail(st, row, "started"), "started")
        self.note("created", stage, row)
        return row

    def prepare_builder_test_paths(self, st: dict):
        """None, or an ENV sentence. GUL-2204: the Pi factory-guard lets the Builder write
        the spec's builderTestPaths. It reads them from `factory-builder-test-paths.json` in
        the worktree's own git dir, which is outside the worktree and never committed. The
        engine rewrites it before every attempt, `[]` when the spec has none, so a list
        never leaks from one order into another."""
        wt = st.get("worktree") or ""
        try:
            with open(st["specFile"], encoding="utf-8") as fh:
                text = fh.read()
            spec, _ = factory.extract_json_block(text, "spec")
            paths = factory.builder_test_paths(spec or {})
            gitdir = git(wt, "rev-parse", "--absolute-git-dir", check=False).strip()
            if not gitdir:
                return "ENV: no git dir for the worktree %s." % (wt or "(no worktree)")
            target = os.path.join(gitdir, "factory-builder-test-paths.json")
            tmp = target + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump({"paths": paths}, fh)
            os.replace(tmp, target)
        except (OSError, ValueError, KeyError) as exc:
            return "ENV: could not write builderTestPaths for %s (%s)." % (wt or "(no worktree)", exc)
        return None

    def prepare_claude_guard(self, st: dict, agent_id: str):
        """None, or an ENV sentence. A Claude Code agent (the Reviewer on Sonnet) runs on
        Paperclip's ACP engine, which ignores extra CLI flags. ACP does load the worktree's
        `.claude/settings.local.json`, and Paperclip merges its own keys into that file and
        keeps the rest. So the engine writes the agent's guard there (the factory-guard
        PreToolUse hook and permissions.deny) before every attempt, and keeps `.claude/` out
        of git through the repo's info/exclude."""
        source = (self.cfg.get("claudeGuards") or {}).get(agent_id)
        if not source:
            return None
        wt = st.get("worktree") or ""
        try:
            with open(source, encoding="utf-8") as fh:
                guard = json.load(fh)
            if not (guard.get("hooks") or {}).get("PreToolUse"):
                return "ENV: the guard file %s has no PreToolUse hook." % source
            target = os.path.join(wt, ".claude", "settings.local.json")
            os.makedirs(os.path.dirname(target), exist_ok=True)
            current = {}
            if os.path.exists(target):
                try:
                    with open(target, encoding="utf-8") as fh:
                        current = json.load(fh)
                except ValueError:
                    current = {}
            if not isinstance(current, dict):
                current = {}
            perms = dict(current.get("permissions") or {})
            perms["deny"] = sorted(set(perms.get("deny") or [])
                                   | set((guard.get("permissions") or {}).get("deny") or []))
            current["permissions"] = perms
            current["hooks"] = guard["hooks"]
            tmp = target + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(current, fh, indent=2)
            os.chmod(tmp, 0o600)
            os.replace(tmp, target)
            common = git(wt, "rev-parse", "--git-common-dir", check=False).strip()
            if common:
                if not os.path.isabs(common):
                    common = os.path.join(wt, common)
                exclude = os.path.join(common, "info", "exclude")
                os.makedirs(os.path.dirname(exclude), exist_ok=True)
                lines = open(exclude, encoding="utf-8").read().splitlines() if os.path.exists(exclude) else []
                if ".claude/" not in lines:
                    with open(exclude, "a", encoding="utf-8") as fh:
                        fh.write("\n.claude/\n")
        except (OSError, ValueError) as exc:
            return "ENV: could not write the Claude guard into %s (%s)." % (wt or "(no worktree)", exc)
        return None

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
        ladder_part = self.investigation_section(st, stage)
        if ladder_part:
            parts.append(ladder_part)
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
        lines.extend(fail_block(prev.get("failLines")))
        return "\n".join(lines)

    def template_values(self, st: dict, stage: str, spec: dict) -> dict:
        return {
            "workOrder": st["workOrder"], "workOrderTitle": st.get("title", ""),
            "repo": st["repo"], "worktree": st.get("worktree", ""), "branch": st["branch"],
            "base": st["base"], "baseSha": st.get("baseSha", ""), "kind": spec.get("kind", ""),
            "allowedPaths": ", ".join("`%s`" % p for p in spec.get("allowedPaths", [])),
            "builderTestPaths": (", ".join("`%s`" % p for p in spec.get("builderTestPaths") or [])
                                 or "none"),
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
    def worktree_problem(self, st: dict):
        """None when the order's worktree exists and is on its branch, else one sentence.

        Without this guard a missing worktree burns attempts: the check runs in an empty
        path (every test fails in 0 s) and the agent's Paperclip workspace falls back to
        the shared clone (GUL-2026 replay, 2026-11-23)."""
        wt = st.get("worktree")
        if not wt or not os.path.isdir(wt):
            return "ENV: the worktree %s does not exist." % (wt or "(none)")
        head = git(wt, "rev-parse", "--abbrev-ref", "HEAD", check=False).strip()
        if head != st["branch"]:
            return "ENV: the worktree %s is on %r, not %s." % (wt, head, st["branch"])
        return None

    def step_stage(self, st: dict) -> None:
        stage = st["phase"]
        problem = self.worktree_problem(st)
        if problem:
            self.flag("worktree-missing")
            self.stall(st, problem + " No stage runs until it is back; no attempt was used.")
            return
        row = self.current_row(st, stage)
        if row is not None and row["result"] in FAILED:
            failed = [r for r in self.rows(st, stage, st["round"]) if r["result"] in FAILED]
            if len(failed) >= self.max_attempts(st, stage):
                self.escalate(st, stage, self.attempts_sentence(st, stage, failed))
                return
        if row is None or row["result"] != "pending":
            self.create_stage_issue(st, stage)
            return
        issue = unwrap(self.api.issue(row["issueId"]), "issue")
        status = issue.get("status")
        self.note("pending", stage, row)
        if status in ("done", "in_review"):
            getattr(self, "judge_" + stage)(st, row)
            return
        if status != "cancelled":
            # GUL-2147: after its retry budget Paperclip sets a limit-hit run's issue
            # `blocked`, often before the engine's next tick. That is still the provider's
            # limit, not the agent's failure, so it must reach the fallback, not burn an attempt.
            limit = self.limit_error(st, row, stage)
            if limit:
                self.limit_fallback(st, row, stage, limit)
                return
        if status == "cancelled":
            self.fail_attempt(st, row, "fail", ["stage issue cancelled by %s" % self.who(issue)])
        elif status == "blocked":
            self.fail_attempt(st, row, "fail", [self.last_comment(row["issueId"])
                                                or "the agent set the stage issue blocked"])
        else:
            self.check_timeout(st, row, stage, issue)

    def limit_error(self, st: dict, row: dict, stage: str) -> str:
        """The error of a run that hit the provider's usage limit, or "". Only for a stage
        with a fallback agent that the order does not use yet, and only when no run of the
        attempt is still live (Paperclip may retry by itself)."""
        if stage in (st.get("fallbackStages") or []):
            return ""
        if not (self.cfg.get("fallbackAgents") or {}).get(stage):
            return ""
        runs = self.api.runs(row["issueId"])
        if not runs:
            return ""
        runs = [r for r in runs if isinstance(r, dict)]
        if any(r.get("status") in LIVE_RUN_STATUSES for r in runs):
            return ""
        for run in runs:
            if run.get("status") != "failed":
                continue
            if not run.get("error") and run.get("runId") and hasattr(self.api, "run"):
                run = dict(run, error=(self.api.run(run["runId"]) or {}).get("error"))
            text = "%s %s" % (run.get("error") or "", run.get("errorCode") or "")
            if LIMIT_RE.search(text):
                return one_line(run.get("error") or text, 200)
        return ""

    def limit_fallback(self, st: dict, row: dict, stage: str, error: str) -> None:
        """Move the stage to its fallback agent for the rest of the order. The attempt that
        hit the limit is stopped and recorded as `limit`, which uses no attempt."""
        self.would("move %s to the fallback agent (%s)" % (row["identifier"], error))
        self.api.patch_issue(row["issueId"], {
            "assigneeAgentId": None, "status": "cancelled",
            "comment": "engine: this run hit the provider's usage limit (%s). The %s stage moves "
                       "to its fallback agent; this does not count as a failed attempt." % (error, stage)})
        row.update({"result": "limit", "reasons": ["usage limit: %s" % error], "commented": True,
                    "finishedAt": iso()})
        st["fallbackStages"] = sorted(set(st.get("fallbackStages") or []) | {stage})
        self.save(st)
        self.flag("fallback-" + stage)
        lodge_event(self.cfg, stage, self.detail(st, row, "limit"), "limit")
        self.note("limit", stage, row)
        self.create_stage_issue(st, stage)

    def fallback_note(self, st: dict) -> str:
        names = (self.cfg.get("fallbackNames") or {})
        return "; ".join("%s fallback: %s (the main agent hit its usage limit)"
                         % (stage, names.get(stage, "fallback agent"))
                         for stage in st.get("fallbackStages") or [])

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
                     check_line: str = "", tail=None, fails=None) -> None:
        self.would("record %s of %s" % (result, row["identifier"]))
        if row["stage"] == "librarian":
            self.librarian_fallback(st, row, result, reasons)
            return
        row.update({"result": result, "reasons": reasons, "fingerprint": fingerprint(reasons),
                    "checkLine": check_line or json.dumps(
                        {"ok": False, "check": "engine-" + row["stage"], "reasons": reasons},
                        ensure_ascii=False),
                    "outputTail": list(tail or [])[-TAIL_LINES:],
                    "failLines": list(fails or [])[:MAX_FAIL_LINES], "finishedAt": iso()})
        self.save(st)
        lodge_event(self.cfg, row["stage"], self.detail(st, row, result), result)
        self.note(result, row["stage"], row)
        failed = [r for r in self.rows(st, row["stage"], st["round"]) if r["result"] in FAILED]
        if len(failed) >= self.max_attempts(st, row["stage"]):
            self.escalate(st, row["stage"], self.attempts_sentence(st, row["stage"], failed))
        else:
            self.create_stage_issue(st, row["stage"])

    def attempts_sentence(self, st: dict, stage: str, failed: list) -> str:
        last = failed[-1]
        if not last.get("commented"):
            self.comment(last["issueId"], "engine check: FAIL — %s. No next attempt: %d attempt(s) "
                         "failed, so the stall ladder takes over." % (first_reason(last.get("reasons")),
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
        if st.get("strongStage") == row["stage"]:
            st["strongStage"] = None
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
            self.fail_attempt(st, row, "fail", res.reasons, res.line, res.tail, res.fails)
            return
        com = run_factory(["commit", "--repo", st["worktree"], "--stage", "red",
                           "--issue", st["workOrder"], "--spec", st["specFile"]]).require_json()
        if not com.ok:
            self.fail_attempt(st, row, "fail", com.reasons, com.line, com.tail, com.fails)
            return
        st["redSha"] = com.parsed["sha"]
        self.passed(st, row, st["redSha"])
        self.enter(st, "green")

    def judge_green(self, st: dict, row: dict) -> None:
        self.would("judge %s: factory.py check-green" % row["identifier"])
        res = run_factory(["check-green", "--repo", st["worktree"], "--red", st["redSha"],
                           "--spec", st["specFile"]]).require_json()
        if not res.ok:
            self.fail_attempt(st, row, "fail", res.reasons, res.line, res.tail, res.fails)
            return
        com = run_factory(["commit", "--repo", st["worktree"], "--stage", "green",
                           "--issue", st["workOrder"], "--spec", st["specFile"]]).require_json()
        if not com.ok:
            self.fail_attempt(st, row, "fail", com.reasons, com.line, com.tail, com.fails)
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
            self.fail_attempt(st, row, "fail", res.reasons, res.line, res.tail, res.fails)
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
            self.fail_attempt(st, row, "fail", res.reasons, res.line, res.tail, res.fails)
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
            self.escalate(st, "green", "Verify confirmed blocking findings (%s) in round %d and the "
                          "fix-round limit is spent." % (", ".join(st["blockingConfirmed"]), st["round"]))
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
        never_paths = str(self.repo_cfg(st).get("neverPaths") or "")
        gate_args = ["check-gate", "--pr", "%s#%s" % (st["repo"], pr["number"]),
                     "--spec", st["specFile"], "--split-safety"]
        if never_paths:
            # GUL-2238: the repo's own list, read at the commit the PR is based on:
            # a branch must not be able to widen the safety net that judges it.
            base = str(st.get("baseSha") or pr.get("base") or "")
            gate_args += ["--never-paths", never_paths]
            if base:
                gate_args += ["--never-paths-ref", base]
        res = run_factory(gate_args).require_json()
        safety = list((res.parsed or {}).get("safety") or [])
        st["gate"] = {"result": "pass" if res.ok else "fail", "reasons": res.reasons,
                      "safety": safety, "at": iso(),
                      "neverPaths": never_paths or factory.NEVER_PATHS_REL}
        if not res.ok:
            self.stall(st, "The gate failed on PR #%s: %s." % (pr["number"], "; ".join(res.reasons[:3])))
            return
        note = (res.parsed or {}).get("sizeNote")
        link = pr.get("url") or "#%s" % pr["number"]
        merged, why = self.auto_merge(st, safety, note)
        st["gate"]["autoMerge"] = {"merged": merged, "why": why}
        if merged:
            comment = "PR %s passed the gate, and the factory merged it (squash). %s" % (link, why)
        else:
            comment = "PR %s passed the gate: merge it on GitHub. Not merged by the factory: %s" % (link, why)
        if note:
            comment = note + "\n\n" + comment
        if self.fallback_note(st):
            comment = comment + "\n\n" + self.fallback_note(st) + "."
        self.api.patch_issue(st["workOrderId"], {"status": "in_review", "comment": comment})
        st["phase"] = "awaiting_merge"
        self.save(st)
        self.note("pass", "gate")

    # -- auto-merge (phase 4, decisions 1 and 7) ----------------------------------
    def self_approvals(self, st: dict, note) -> str:
        lines = ["**Factory self-approvals** (GUL-2037 phase 4, run mode `auto`):"]
        for row in st.get("stages") or []:
            if row.get("result") == "pass":
                lines.append("- %s: %s passed the engine check" % (row.get("stage"), row.get("identifier")))
        for inv in st.get("investigations") or []:
            if inv.get("verdict"):
                lines.append("- investigation %s: %s" % (inv.get("identifier"), inv.get("verdict")))
        lines.append("- review findings: %d, blocking confirmed by verify: %d"
                     % (len(st.get("findings") or []), len(st.get("blockingConfirmed") or [])))
        lines.append("- gate: CI `check` SUCCESS, no never path touched")
        if self.fallback_note(st):
            lines.append("- " + self.fallback_note(st))
        if note:
            lines.append("- %s" % note)
        return "\n".join(lines)

    def app_env(self, st: dict):
        """(env with the App's installation token, None) or (None, sentence)."""
        try:
            token = ghapp.installation_token(self.cfg, st["repo"], state_dir())
        except ghapp.AppError as exc:
            return None, "no GitHub App token (%s)." % exc
        env = dict(os.environ, GH_TOKEN=token)
        env.pop("GITHUB_TOKEN", None)
        return env, ""

    def auto_merge(self, st: dict, safety: list, note):
        """Merge the PR as the GitHub App when nothing SAFETY is touched.

        Returns (merged, sentence). Every failure here means "the owner merges",
        never a stall: the order already passed every check.
        """
        pr = st["pr"]
        # GUL-2238: name the key that blocked the merge, so the owner's comment says
        # which of the three it was (the repo's autoMerge, the missing list, the global).
        if self.repo_cfg(st).get("autoMerge") is False:
            return False, "auto-merge is off for %s in engine.json." % st["repo"]
        if not self.never_paths_list(st):
            return False, ("no never-path list for %s in engine.json. Only the owner merges this."
                           % st["repo"])
        if not self.repo_setting(st, "autoMerge"):
            return False, "auto-merge is off in engine.json."
        if safety:
            return False, "SAFETY: %s. Only the owner merges this." % "; ".join(safety[:3])
        head = pr.get("head") or ""
        if not head:
            return False, "the engine has no recorded head commit for the PR."
        if not self.apply:
            self.would("auto-merge PR #%s as the GitHub App" % pr["number"])
            return False, "dry run."
        env, err = self.app_env(st)
        if env is None:
            return False, err
        body = self.self_approvals(st, note)
        com = subprocess.run([factory.gh_bin(), "pr", "comment", str(pr["number"]), "--repo", st["repo"],
                              "--body", body], env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True)
        if com.returncode != 0:
            return False, "posting the self-approvals failed: %s" % com.stderr.strip()[:200]
        # --match-head-commit: merge exactly the head that the stages checked, or nothing
        mrg = subprocess.run([factory.gh_bin(), "pr", "merge", str(pr["number"]), "--repo", st["repo"],
                              "--squash", "--match-head-commit", head], env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if mrg.returncode != 0:
            return False, "`gh pr merge` failed: %s" % mrg.stderr.strip()[:200]
        return True, "Self-approvals are listed in a comment on the PR."

    # -- catch-up: "the head branch is not up to date" -------------------------------
    def catch_up(self, st: dict, view: dict) -> None:
        """The ruleset wants the PR branch up to date with `main`. When `main` moved after
        the gate, the App's merge is refused. Then the engine asks GitHub to merge `main`
        into the PR branch ("Update branch"), and merges only if the new head is exactly
        the checked head + a commit of `main`, and CI passes on it. Every failure leaves
        the merge to the owner, with a comment. It never stalls.
        """
        gate = st.get("gate") or {}
        if (gate.get("autoMerge") or {}).get("merged") or gate.get("safety") \
                or not self.repo_setting(st, "autoMerge"):
            return
        pr = st.get("pr") or {}
        cu = st.setdefault("catchUp", {"count": 0})
        if cu.get("gaveUp"):
            return
        number, repo = pr.get("number"), st["repo"]
        live_head = str(view.get("headRefOid") or "")
        pending = cu.get("pending")
        if not pending:
            if str(view.get("mergeStateStatus") or "").upper() != "BEHIND":
                return
            if live_head != pr.get("head"):
                self.give_up_catch_up(st, "the PR head moved to %s, not the head the stages checked."
                                      % live_head[:12])
                return
            if cu["count"] >= int(self.cfg.get("maxCatchUps", 3)):
                self.give_up_catch_up(st, "the branch was updated %d times and `main` keeps moving."
                                      % cu["count"])
                return
            if not self.apply:
                self.would("update PR #%s with main as the GitHub App" % number)
                return
            env, err = self.app_env(st)
            if env is None:
                self.give_up_catch_up(st, err)
                return
            upd = subprocess.run([factory.gh_bin(), "api", "-X", "PUT",
                                  "repos/%s/pulls/%s/update-branch" % (repo, number),
                                  "-f", "expected_head_sha=%s" % pr["head"]], env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            if upd.returncode != 0:
                self.give_up_catch_up(st, "GitHub refused \"Update branch\": %s"
                                      % (upd.stderr.strip() or upd.stdout.strip())[:200])
                return
            cu["pending"] = {"from": pr["head"], "at": iso()}
            self.save(st)
            self.note("catch-up", "merge")
            return
        # an update is on its way: wait for the new head, prove its shape, wait for CI
        if live_head == pending["from"]:
            if minutes_since(pending["at"]) > float(self.cfg.get("catchUpWaitMinutes", 15)):
                self.give_up_catch_up(st, "GitHub accepted \"Update branch\" but the head did not move.")
            return
        env, err = self.app_env(st)
        if env is None:
            self.give_up_catch_up(st, err)
            return
        shape = self.catch_up_shape(repo, live_head, pending["from"], env)
        if shape:
            self.give_up_catch_up(st, shape)
            return
        try:
            ci = check_run_state(gh_pr_checks(repo, number))
        except SetupError as exc:
            warn("%s: %s" % (st["workOrder"], exc))
            return
        if ci == "pending":
            if minutes_since(pending["at"]) > float(self.cfg.get("gateCiWaitMinutes", 60)):
                self.give_up_catch_up(st, "CI on the updated head %s did not finish in time." % live_head[:12])
            return
        if ci != "pass":
            self.give_up_catch_up(st, "CI `check` failed on the updated head %s (the change + newest `main`)."
                                  % live_head[:12])
            return
        cu["count"] += 1
        cu.pop("pending", None)
        cu.setdefault("heads", []).append({"from": pending["from"], "to": live_head, "at": iso()})
        pr["checkedHead"] = pr.get("checkedHead") or pending["from"]
        pr["head"] = live_head
        why_note = ("branch updated with `main`: %s = checked head %s + `main`, CI `check` passed again"
                    % (live_head[:12], pending["from"][:12]))
        merged, why = self.auto_merge(st, [], why_note)
        st.setdefault("gate", {})["autoMerge"] = {"merged": merged, "why": why, "afterCatchUp": True}
        link = pr.get("url") or "#%s" % number
        if merged:
            comment = ("PR %s was behind `main`. The factory updated the branch, CI passed again, and it "
                       "merged it (squash). %s" % (link, why))
        else:
            comment = ("PR %s was behind `main`. The factory updated the branch and CI passed, but did not "
                       "merge it: %s Merge it on GitHub." % (link, why))
        self.api.patch_issue(st["workOrderId"], {"comment": comment})
        self.save(st)
        self.note("pass" if merged else "waiting", "merge")

    def catch_up_shape(self, repo: str, new_head: str, old_head: str, env: dict) -> str:
        """'' when new_head is a merge of old_head (first parent) and a commit of `main`."""
        def api(path):
            proc = subprocess.run([factory.gh_bin(), "api", path], env=env, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)
            if proc.returncode != 0:
                raise SetupError(proc.stderr.strip()[:200])
            return json.loads(proc.stdout)
        try:
            parents = [p.get("sha") for p in (api("repos/%s/commits/%s" % (repo, new_head)).get("parents") or [])]
            if len(parents) != 2 or parents[0] != old_head:
                return ("the new head %s is not a merge of the checked head %s and `main` (parents: %s)."
                        % (new_head[:12], old_head[:12], ", ".join(p[:12] for p in parents) or "none"))
            status = api("repos/%s/compare/%s...main" % (repo, parents[1])).get("status")
        except (SetupError, ValueError) as exc:
            return "could not read the new head %s: %s" % (new_head[:12], exc)
        if status not in ("identical", "ahead"):
            return "the new head merged in %s, which is not on `main` (%s)." % (parents[1][:12], status)
        return ""

    def give_up_catch_up(self, st: dict, why: str) -> None:
        cu = st.setdefault("catchUp", {"count": 0})
        cu["gaveUp"] = why
        cu.pop("pending", None)
        pr = st.get("pr") or {}
        self.api.patch_issue(st["workOrderId"], {
            "comment": "PR %s is behind `main` and the factory could not update it: %s Merge it on GitHub."
                       % (pr.get("url") or "#%s" % pr.get("number"), why)})
        self.save(st)

    # -- awaiting_merge -----------------------------------------------------------
    def step_merge(self, st: dict) -> None:
        pr = st.get("pr") or {}
        try:
            view = factory.gh_json(["pr", "view", str(pr.get("number")), "--repo", st["repo"],
                                    "--json", "state,mergedAt,mergeCommit,headRefOid,mergeStateStatus"])
        except SetupError as exc:
            self.flag("merge-unknown")
            warn("%s: %s" % (st["workOrder"], exc))
            return
        state = str((view or {}).get("state") or "").upper()
        self.note("waiting", "merge")
        if state == "OPEN":
            self.catch_up(st, view or {})
            self.flag("pr-open")
            return
        number = pr.get("number")
        if state == "CLOSED":
            self.would("settle closed PR #%s" % number)
            st["phase"] = "closed"
            # `cancelled`, not `blocked`: the order is over and nobody has to act. Paperclip also
            # refuses (422) a `blocked` write with no blocker, interaction or unblockDescriptor.
            st["notice"] = {"status": "cancelled", "executionPolicy": None,
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
        if self.repo_setting(st, "postMergeCheck"):
            st["phase"] = "deploy_check"
            st["deploy"] = {"sha": merge_sha, "since": iso(), "reconcileRequested": False}
            self.save(st)
            self.note("deploy-check", "merge")
            return
        st["phase"] = "done"
        st["notice"] = {"status": "done", "comment": "PR #%s is merged in %s" % (number, merge_sha)}
        self.save(st)
        self.note("done", "merge")
        self.finish(st)

    # -- deploy_check: the check after the merge (phase 4, decision 8) -------------
    def kubectl(self, *args: str):
        binary = os.environ.get("FACTORY_KUBECTL") or self.cfg.get("kubectl") or "kubectl"
        try:
            return subprocess.run([binary] + list(args), stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired) as exc:
            return subprocess.CompletedProcess([binary], 127, "", str(exc))

    def flux_kustomizations(self) -> list:
        """[(name, ready True/False/None, applied sha, attempted sha, message)] or raises."""
        ns = self.cfg.get("fluxNamespace", "flux-system")
        proc = self.kubectl("get", "kustomizations.kustomize.toolkit.fluxcd.io", "-n", ns, "-o", "json")
        if proc.returncode != 0:
            raise SetupError("kubectl get kustomizations failed: %s" % proc.stderr.strip()[:200])
        rows = []
        for item in (json.loads(proc.stdout or "{}").get("items") or []):
            status = item.get("status") or {}
            ready, message = None, ""
            for cond in status.get("conditions") or []:
                if cond.get("type") == "Ready":
                    ready = {"True": True, "False": False}.get(cond.get("status"))
                    message = one_line(cond.get("message") or "", 200)
            sha = lambda rev: (rev or "").rsplit(":", 1)[-1] if "sha1:" in (rev or "") else ""  # noqa: E731
            rows.append(((item.get("metadata") or {}).get("name") or "?", ready,
                         sha(status.get("lastAppliedRevision")),
                         sha(status.get("lastAttemptedRevision")), message))
        if not rows:
            raise SetupError("no Flux Kustomizations in namespace %s" % ns)
        return rows

    def contains(self, st: dict, merge_sha: str, sha: str) -> bool:
        """Is the merge commit in `sha`'s history (Flux applied our commit or a later one)?"""
        # plain ancestry, not factory.merge_contains: its squash-merge heuristics (same files,
        # same content) would call an older commit "containing" the merge
        if not sha:
            return False
        clone = self.repo_cfg(st)["clone"]

        def ancestor() -> int:
            return subprocess.run(["git", "-C", clone, "merge-base", "--is-ancestor", merge_sha, sha],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode

        rc = ancestor()
        if rc not in (0, 1):  # an object is missing: fetch once, then ask again
            git(clone, "fetch", "--quiet", "origin", check=False)
            rc = ancestor()
        return rc == 0

    def step_deploy(self, st: dict) -> None:
        dep = st["deploy"]
        sha = dep["sha"]
        self.note("waiting", "deploy")
        if not dep.get("reconcileRequested"):
            # ask Flux to fetch now instead of waiting for its interval; harmless if it fails
            self.would("ask Flux to reconcile the git source")
            ns = self.cfg.get("fluxNamespace", "flux-system")
            self.kubectl("annotate", "--overwrite", "gitrepository/%s" % self.cfg.get("fluxSource", "flux-system"),
                         "-n", ns, "reconcile.fluxcd.io/requestedAt=%s" % iso())
            dep["reconcileRequested"] = True
            self.save(st)
        try:
            rows = self.flux_kustomizations()
        except (SetupError, ValueError) as exc:
            self.flag("flux-unknown")
            warn("%s: %s" % (st["workOrder"], exc))
            rows = None
        waited = minutes_since(dep["since"])
        limit = float(self.cfg.get("deployWaitMinutes", 30))
        if rows is not None:
            if "brokenBefore" not in dep:
                # a Kustomization that already failed on an older commit is not this merge's fault:
                # it never triggers a revert, it only holds the order until the time limit
                dep["brokenBefore"] = [r[0] for r in rows if r[1] is False and not self.contains(st, sha, r[3])]
                self.save(st)
            failed = [r for r in rows if r[1] is False and r[0] not in dep["brokenBefore"]
                      and self.contains(st, sha, r[3])]
            if failed:
                self.post_merge_failed(st, "Flux could not apply the merge: %s" % "; ".join(
                    "%s: %s" % (r[0], r[4]) for r in failed[:3]))
                return
            pending = [r for r in rows if not (r[1] is True and self.contains(st, sha, r[2]))]
            if pending:
                if waited < limit:
                    self.flag("flux-pending")
                    return
                self.stall(st, "Flux did not apply merge %s within %d minutes (%s). Nothing points at "
                               "the merge yet, so the factory did not revert it." % (
                                   sha[:12], limit, ", ".join(r[0] for r in pending[:5])))
                return
        elif waited < limit:
            return
        else:
            self.stall(st, "The engine could not read Flux for %d minutes after merge %s, so the check "
                           "after the merge did not run." % (limit, sha[:12]))
            return
        dep["fluxReadyAt"] = iso()
        failures = self.run_live_checks(st, sha)
        dep["liveChecks"] = failures
        if failures:
            self.post_merge_failed(st, "live check failed: %s" % "; ".join(failures[:3]))
            return
        n = len(self.spec(st).get("liveChecks") or [])
        st["phase"] = "done"
        st["notice"] = {"status": "done", "comment": (
            "PR #%s is merged in %s. Flux applied it (all Kustomizations Ready) and %d live check(s) "
            "passed." % (st["pr"]["number"], sha, n))}
        self.save(st)
        self.note("done", "deploy")
        self.finish(st)

    def run_live_checks(self, st: dict, sha: str) -> list:
        checks = self.spec(st).get("liveChecks") or []
        if not checks:
            return []
        self.would("run %d live check(s) at %s" % (len(checks), sha[:12]))
        wt = st.get("worktree")
        if not (wt and os.path.isdir(wt)):
            return ["the worktree %s is missing, so no live check could run" % wt]
        git(wt, "fetch", "--quiet", "origin")
        git(wt, "checkout", "--quiet", "--detach", sha)
        failures = []
        timeout = float(self.cfg.get("liveCheckTimeoutSeconds", 600))
        for lc in checks:
            try:
                proc = subprocess.run(["bash", "-c", lc["check"]], cwd=wt, stdout=subprocess.PIPE,
                                      stderr=subprocess.STDOUT, text=True, timeout=timeout)
                if proc.returncode != 0:
                    failures.append("%s exit %d: %s" % (lc["id"], proc.returncode,
                                                        one_line(proc.stdout[-300:], 300)))
            except subprocess.TimeoutExpired:
                failures.append("%s timed out after %ds" % (lc["id"], timeout))
        return failures

    def post_merge_failed(self, st: dict, why: str) -> None:
        """Open a revert PR as the App, then the `reverting` phase merges it when CI passes."""
        dep = st["deploy"]
        dep["failure"] = why
        self.would("open a revert PR for %s" % dep["sha"][:12])
        try:
            token = ghapp.installation_token(self.cfg, st["repo"], state_dir())
        except ghapp.AppError as exc:
            self.stall(st, "The check after the merge failed (%s), and the factory could not revert it: "
                           "no GitHub App token (%s). Revert %s by hand." % (why, exc, dep["sha"][:12]))
            return
        wt = st.get("worktree")
        branch = "revert-%s" % st["workOrder"].lower()
        try:
            if not (wt and os.path.isdir(wt)):
                raise SetupError("the worktree %s is missing" % wt)
            git(wt, "fetch", "--quiet", "origin")
            git(wt, "checkout", "--quiet", "-B", branch, "origin/%s" % st.get("base", "main"))
            git(wt, "revert", "--no-edit", dep["sha"])
            git(wt, "push", "--quiet", "origin", "HEAD:refs/heads/%s" % branch)
            head = git(wt, "rev-parse", "HEAD").strip()
        except SetupError as exc:
            self.stall(st, "The check after the merge failed (%s), and the revert failed: %s. Revert %s "
                           "by hand." % (why, exc, dep["sha"][:12]))
            return
        env = dict(os.environ, GH_TOKEN=token)
        env.pop("GITHUB_TOKEN", None)
        body = ("The check after the merge of PR #%s failed: %s\n\nThe factory reverts merge %s. "
                "Opened by the engine (GUL-2037 phase 4, decision 8)." % (st["pr"]["number"], why, dep["sha"]))
        proc = subprocess.run([factory.gh_bin(), "pr", "create", "--repo", st["repo"], "--base",
                               st.get("base", "main"), "--head", branch, "--title",
                               "revert: %s (the check after the merge failed)" % st["workOrder"],
                               "--body", body], env=env, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True)
        m = re.search(r"/pull/([0-9]+)", proc.stdout or "")
        if proc.returncode != 0 or not m:
            self.stall(st, "The check after the merge failed (%s). The revert branch %s is pushed, but "
                           "opening its PR failed: %s" % (why, branch, proc.stderr.strip()[:200]))
            return
        st["revert"] = {"branch": branch, "number": int(m.group(1)), "url": proc.stdout.strip(),
                        "head": head, "since": iso()}
        st["phase"] = "reverting"
        self.save(st)
        self.note("reverting", "deploy")

    def step_revert(self, st: dict) -> None:
        rev, why = st["revert"], st["deploy"].get("failure", "")
        self.note("waiting", "revert")
        state = check_run_state(gh_pr_checks(st["repo"], rev["number"]))
        if state == "pending" and minutes_since(rev["since"]) < float(self.cfg.get("gateCiWaitMinutes", 60)):
            self.flag("ci-pending")
            return
        if state != "pass":
            self.stall(st, "The check after the merge failed (%s). Revert PR %s has CI `check` %s, so the "
                           "factory did not merge it. Merge or fix it by hand." % (why, rev["url"], state))
            return
        self.would("merge revert PR #%s as the GitHub App" % rev["number"])
        try:
            token = ghapp.installation_token(self.cfg, st["repo"], state_dir())
        except ghapp.AppError as exc:
            self.stall(st, "The check after the merge failed (%s). Merge revert PR %s by hand: no GitHub "
                           "App token (%s)." % (why, rev["url"], exc))
            return
        env = dict(os.environ, GH_TOKEN=token)
        env.pop("GITHUB_TOKEN", None)
        mrg = subprocess.run([factory.gh_bin(), "pr", "merge", str(rev["number"]), "--repo", st["repo"],
                              "--squash", "--match-head-commit", rev["head"]], env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if mrg.returncode != 0:
            self.stall(st, "The check after the merge failed (%s). Merging revert PR %s failed: %s. Merge "
                           "it by hand." % (why, rev["url"], mrg.stderr.strip()[:200]))
            return
        rev["merged"] = True
        # a revert always wakes the stall owner: the order did not ship
        self.stall(st, "The check after the merge failed (%s). The factory reverted it: PR %s is merged."
                   % (why, rev["url"]))

    # -- the stall ladder (phase 3) -----------------------------------------------
    def escalate(self, st: dict, stage: str, sentence: str) -> None:
        """A stage ran out of attempts: ask the Investigator instead of stalling at once.

        Ladder: same agent with the failure (the attempts) -> Investigator verdict ->
        TEST-WRONG reruns red / CODE-WRONG gives the stage one attempt on the stronger
        model -> a human. At most `maxInvestigations` per order, so it cannot loop.
        """
        done = [i for i in st.get("investigations") or [] if i.get("verdict")]
        limit = int(self.cfg.get("maxInvestigations", 2))
        if stage in ("investigate", "librarian") or "investigate" not in (self.cfg.get("stages") or {}):
            self.stall(st, sentence)
            return
        if len(done) >= limit:
            self.stall(st, "%s The stall ladder is spent (%d investigation(s))." % (sentence, len(done)))
            return
        self.would("escalate %s to the Investigator" % stage)
        failed_rows = [r for r in self.rows(st, stage, st["round"]) if r["result"] in FAILED]
        st.setdefault("investigations", []).append({
            "stage": stage, "round": st["round"], "ladder": st.get("ladder") or 0,
            "sentence": sentence, "fromVerify": stage == "green" and not failed_rows,
            "failedRows": [r["identifier"] for r in failed_rows], "verdict": None})
        st["ladder"] = (st.get("ladder") or 0) + 1
        st["strongStage"] = None
        self.enter(st, "investigate")

    def investigation_section(self, st: dict, stage: str) -> str:
        """For the Investigator: the stuck stage and its failed attempts. For the retried
        stage: the verdict and the advice."""
        inv = (st.get("investigations") or [None])[-1]
        if not inv:
            return ""
        if stage == "investigate":
            lines = ["## The stuck stage",
                     "Stage `%s`, round %d. The engine says: %s" % (inv["stage"], inv["round"],
                                                                     inv["sentence"])]
            by_id = {r["identifier"]: r for r in st.get("stages") or []}
            for ident in inv.get("failedRows") or []:
                r = by_id.get(ident) or {}
                lines += ["", "### Attempt %s (%s): `%s`" % (r.get("attempt"), ident, r.get("result")),
                          "```", r.get("checkLine") or "(no check line)"]
                if r.get("outputTail"):
                    lines += [""] + list(r["outputTail"][-TAIL_LINES:])
                lines.append("```")
                lines += fail_block(r.get("failLines"))
            if inv.get("fromVerify"):
                lines += ["", "### Blocking findings that verify confirmed",
                          "```json", json.dumps([f for f in st.get("findings") or []
                                                 if f.get("id") in (st.get("blockingConfirmed") or [])],
                                                indent=1, ensure_ascii=False), "```"]
            return "\n".join(lines)
        if inv.get("verdict") and inv.get("ladder", -1) + 1 == (st.get("ladder") or 0):
            return "\n".join([
                "## The Investigator looked at the last failures",
                "Verdict **%s** (%s). Cause: %s" % (inv["verdict"], inv.get("identifier", ""),
                                                   inv.get("cause", "")),
                "", "What to do differently: %s" % (inv.get("advice") or "(no advice)")])
        return ""

    def judge_investigate(self, st: dict, row: dict) -> None:
        self.would("judge %s (investigation)" % row["identifier"])
        doc = self.api.document(row["issueId"], "investigation")
        body = doc.get("body") if isinstance(doc, dict) else None
        if not isinstance(body, str) or not body.strip():
            self.fail_attempt(st, row, "fail", ["no investigation document on %s" % row["identifier"]])
            return
        value, reasons = factory.extract_json_block(body, "investigation")
        if not reasons:
            reasons = validate_investigation(value)
        if reasons:
            self.fail_attempt(st, row, "fail", reasons)
            return
        inv = st["investigations"][-1]
        inv.update({"verdict": value["verdict"], "cause": one_line(value["cause"], 600),
                    "advice": one_line(value.get("advice") or "", 1200),
                    "amend": str(value.get("amend") or "")[:4000], "identifier": row["identifier"]})
        self.passed(st, row)
        verdict, stage = inv["verdict"], inv["stage"]
        lodge_event(self.cfg, "investigate", self.detail(st, row, verdict), verdict)
        if verdict in ("SPEC-WRONG", "ENV"):
            extra = " Proposed AMEND block in the `investigation` document of %s." % row["identifier"] \
                if verdict == "SPEC-WRONG" else ""
            self.stall(st, "%s Investigator %s: %s: %s.%s" % (inv["sentence"], row["identifier"],
                                                              verdict, inv["cause"], extra))
            return
        if verdict == "TEST-WRONG":
            if stage not in ("red", "green") or (st.get("pr") or {}).get("number"):
                self.stall(st, "%s Investigator %s: TEST-WRONG, but green already pushed code, so "
                           "red cannot rewrite the tests on this branch: %s." % (
                               inv["sentence"], row["identifier"], inv["cause"]))
                return
            self.set_aside_worktree(st, "before red reruns (TEST-WRONG, %s)" % row["identifier"])
            self.enter(st, "red")
            return
        # CODE-WRONG: the stuck stage once more, on the stronger model, with the advice.
        st["strongStage"] = stage
        if inv.get("fromVerify"):
            st["round"] += 1
        self.enter(st, stage)

    def set_aside_worktree(self, st: dict, why: str) -> None:
        """Keep the failed attempts' leftovers in a stash (never deleted), so the next stage
        starts from the last commit."""
        wt = st["worktree"]
        if git(wt, "status", "--porcelain").strip():
            self.would("git stash the leftovers in %s" % wt)
            git(wt, "stash", "push", "--include-untracked", "-m", "factory %s: %s" % (st["workOrder"], why))

    def wake_owner(self, st: dict, sentence: str) -> None:
        """A final stall wakes the stall owner with one issue, at most `maxStallWakesPerDay`
        a day; after that the stall waits for the 05:30 round."""
        owner = self.cfg.get("stallOwnerAgentId")
        limit = int(self.cfg.get("maxStallWakesPerDay", 3))
        path = os.path.join(state_dir(), "stall-wakes.json")
        try:
            with open(path, "r", encoding="utf-8") as fh:
                wakes = json.load(fh)
        except (OSError, ValueError):
            wakes = {}
        today = iso()[:10]
        if not owner or int(wakes.get(today) or 0) >= limit:
            st["wake"] = {"sent": False, "reason": "daily wake limit (%d) reached" % limit}
            return
        self.would("wake the stall owner")
        issue = unwrap(self.api.post("/companies/%s/issues" % st["companyId"], {
            "title": "[stall] %s %s" % (st["workOrder"], st.get("title", "")[:110]),
            "description": "The factory engine stalled **%s** and the stall ladder is spent.\n\n%s\n\n"
                           "Decide: fix the spec, file a follow-up, or cancel the order. The work order "
                           "is `blocked` with an unblock note owned by you." % (st["workOrder"], sentence),
            "status": "todo", "priority": st.get("priority") or "medium",
            "projectId": st["projectId"], "assigneeAgentId": owner}), "issue")
        wakes = {today: int(wakes.get(today) or 0) + 1}
        write_json_atomic(path, wakes)
        st["wake"] = {"sent": True, "issue": issue.get("identifier") or issue.get("id")}

    # -- terminal phases ---------------------------------------------------------
    def stall(self, st: dict, sentence: str, wake: bool = True) -> None:
        self.would("stall: %s" % sentence)
        st["phase"] = "stalled"
        st["stallReason"] = sentence
        self.halt_open_attempts(st)
        # Paperclip refuses (422) `blocked` with no blocker, interaction or unblockDescriptor.
        # The engine's board key may name any agent as the owner: the stall owner (Claude Code,
        # the last step of the stall ladder) decides what happens next.
        owner = self.cfg.get("stallOwnerAgentId")
        if not owner:
            raise SetupError("engine.json has no stallOwnerAgentId")
        if wake and not st.get("wake"):
            self.wake_owner(st, sentence)
        st["notice"] = {"status": "blocked", "executionPolicy": None, "comment": sentence,
                        "unblockDescriptor": {"owner": {"agentId": owner}, "action": (
                            "Decide the stalled work order %s: %s" % (st["workOrder"], sentence))[:500]}}
        self.save(st)
        self.note("stalled")
        self.finish(st)

    def halt_open_attempts(self, st: dict) -> None:
        """A stalled order runs no agent. An attempt that is still open is unassigned and
        cancelled, and recorded as `halted`: not a failure, so it uses no attempt. A
        finished attempt (done / in_review) stays pending, to be judged after the stall."""
        for row in st.get("stages") or []:
            if row.get("result") != "pending":
                continue
            issue = unwrap(self.api.issue(row["issueId"]), "issue")
            if issue.get("status") in ("done", "in_review"):
                continue
            self.would("halt %s (the order stalled)" % row["identifier"])
            if issue.get("status") != "cancelled":
                self.api.patch_issue(row["issueId"], {"assigneeAgentId": None, "status": "cancelled"})
                self.comment(row["issueId"], "engine: the work order stalled, so this attempt is "
                             "stopped. It does not count as a failed attempt.")
            row.update({"result": "halted", "reasons": ["the work order stalled"],
                        "commented": True, "finishedAt": iso()})
        self.save(st)

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
    ok, reasons, extra, summary = start_order(cfg, api, issue, dry_run=args.dry_run)
    emit(ok, "start", reasons, extra, summary)
    return 0 if ok else 1


def start_order(cfg: dict, api, issue: dict, dry_run: bool = False, doc=None, how: str = "") -> tuple:
    """Freeze the spec and queue the order. Returns (ok, reasons, extra, summary); writes nothing
    when it fails. `doc` is the spec document when the caller already read it (pickup)."""
    wo = issue["identifier"].upper()
    if doc is None:
        doc = api.document(issue["id"], "spec")
    body = doc.get("body") if isinstance(doc, dict) else None
    if not isinstance(body, str) or not body.strip():
        return False, ["%s has no spec document" % wo], {"workOrder": wo}, ""
    with tempfile.TemporaryDirectory() as tmp:
        lint_path = os.path.join(tmp, "spec.md")
        with open(lint_path, "w", encoding="utf-8") as fh:
            fh.write(body)
        lint = run_factory(["lint-spec", "--spec", lint_path])
        if not lint.ok:
            return False, ["spec: " + r for r in lint.reasons], {"workOrder": wo}, ""
        spec = factory.load_spec(lint_path)
    if spec["repo"] not in (cfg.get("repos") or {}):
        return False, ["repo %s is not in engine.json" % spec["repo"]], {"workOrder": wo}, ""
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
    if dry_run:
        return (True, [], {"workOrder": wo, "dryRun": True,
                           "plan": {"branch": st["branch"], "repo": st["repo"], "base": st["base"]}},
                "engine-start: %s would be queued on %s" % (wo, st["branch"]))
    # No assignee: Paperclip refuses (409) to assign a paused agent, an active one would wake a model,
    # and `in_progress` requires an assignee (422). So the work order stays `todo`, unassigned; its
    # real phase is the `engine-state` document.
    api.patch_issue(issue["id"], {"status": "todo",
                                  "comment": "The factory engine took this work order%s. Branch `%s`; "
                                  "the next tick starts it when a slot is free." % (how, st["branch"])})
    write_text_atomic(st["specFile"], body)
    write_json_atomic(state_path(wo), st)
    try:
        api.write_document(issue["id"], "engine-state",
                           fenced("Engine state", "Written by `engine.py` after every change.", st),
                           title="engine-state")
    except Exception as exc:  # noqa: BLE001 - the mirror is for people only
        warn("%s: engine-state mirror not written: %s" % (wo, exc))
    return (True, [], {"workOrder": wo, "phase": "queued", "branch": st["branch"]},
            "engine-start: %s queued on %s" % (wo, st["branch"]))


SPEC_GATE_PREFIX = "spec-gate:"


def spec_gate_accepted(interactions: list, revision_id: str):
    """The accepted spec-gate card for this exact spec revision, or None.

    Intake (phase 5): the PM writes the `spec` document and opens a `request_confirmation` card
    bound to its revision, with an idempotency key that starts `spec-gate:`. Only a human's accept
    counts: an agent may never approve the spec it, or another agent, wrote. A card for an older
    revision does not count either (Paperclip marks it `stale_target`, but we check too)."""
    for it in interactions or []:
        if it.get("kind") != "request_confirmation":
            continue
        if not str(it.get("idempotencyKey") or "").startswith(SPEC_GATE_PREFIX):
            continue
        result = it.get("result") or {}
        if result.get("outcome") != "accepted" or not it.get("resolvedByUserId") or it.get("resolvedByAgentId"):
            continue
        target = (it.get("payload") or {}).get("target") or {}
        if target.get("type") != "issue_document" or target.get("key") != "spec":
            continue
        if not revision_id or target.get("revisionId") != revision_id:
            continue
        return it
    return None


def pickup(cfg: dict, api, apply: bool) -> list:
    """Queue every work order whose spec a human approved (`autoPickup`). One line per order.

    Candidates are `in_review` issues of each repo's `projectId`. A refused spec (lint, wrong repo)
    gets one comment per spec revision, remembered in `<state>/pickup-refused.json`, so a tick never
    repeats it; a new revision with a new accepted card is tried again."""
    if not cfg.get("autoPickup"):
        return []
    company = cfg.get("companyId")
    projects = [rc.get("projectId") for rc in (cfg.get("repos") or {}).values() if rc.get("projectId")]
    if not company or not projects:
        warn("autoPickup: no companyId or repo projectId in engine.json, nothing picked up")
        return []
    refused_path = os.path.join(state_dir(), "pickup-refused.json")
    try:
        with open(refused_path, "r", encoding="utf-8") as fh:
            refused = json.load(fh)
    except (OSError, ValueError):
        refused = {}
    lines = []
    for project in projects:
        payload = api.get("/companies/%s/issues?projectId=%s&status=in_review&limit=200" % (company, project))
        if isinstance(payload, dict):
            payload = payload.get("issues") or payload.get("items") or []
        for issue in payload if isinstance(payload, list) else []:
            wo = str(issue.get("identifier") or "").upper()
            if (not re.match(r"^GUL-[0-9]+$", wo) or issue.get("status") != "in_review"
                    or issue.get("projectId") != project or issue.get("parentId")
                    or os.path.exists(state_path(wo))):
                continue
            line = {"workOrder": wo, "flags": ["pickup"], "phase": "intake", "stage": "intake", "round": 0}
            try:
                doc = api.document(issue["id"], "spec")
                rev = (doc or {}).get("latestRevisionId")
                if not rev or refused.get(wo) == rev:
                    continue
                card = spec_gate_accepted(api.interactions(issue["id"]), rev)
                if not card:
                    continue
                if not apply:
                    line.update(outcome="would-start", would="start %s (spec %s approved)" % (wo, rev))
                    lines.append(line)
                    continue
                full = api.by_identifier(None, wo) or issue
                ok, reasons, extra, _ = start_order(cfg, api, full, doc=doc,
                                                    how=" after the owner approved the spec")
                if ok:
                    line.update(outcome="started", phase="queued", stage="queued")
                else:
                    refused[wo] = rev
                    write_json_atomic(refused_path, refused)
                    api.comment(issue["id"], "The factory engine cannot start this approved spec:\n\n"
                                + "\n".join("- " + r for r in reasons)
                                + "\n\nFix the `spec` document and open a new spec-gate card.")
                    line.update(outcome="refused", flags=["pickup", "refused"], error="; ".join(reasons))
            except Exception as exc:  # noqa: BLE001 - one bad issue never stops the tick
                line.update(outcome="error", flags=["pickup", "error"],
                            error=one_line("%s: %s" % (type(exc).__name__, exc), 400))
                warn("%s: pickup: %s" % (wo, line["error"]))
            lines.append(line)
    return lines


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
        picked = pickup(cfg, paperclip_api(), bool(args.apply)) if cfg.get("autoPickup") else []
        states = list_states()
        if not states and not picked:
            emit(True, "tick", [], {"apply": bool(args.apply), "orders": []}, "engine-tick: no orders")
            return 0
        lines = list(picked)
        if states:
            engine = Engine(cfg, paperclip_api(), bool(args.apply))
            engine.states = states
            lines += [engine.run_order(st) for st in states]
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
