#!/usr/bin/env python3
"""factory.py — deterministic stage checks for the Pi code factory.

Contract: agents/factory/CONTRACT.md (GUL-436, ADR-093). A script decides
whether a stage passed, not a model. Python 3 standard library only; run as
`python3 -I agents/factory/factory.py <subcommand>`.

Every subcommand prints exactly one JSON line on stdout
({"ok": bool, "check": name, "reasons": [...], ...}) and a short human
summary on stderr. Exit 0 = pass, 1 = fail, 2 = usage or setup error.
No Paperclip calls. The only network user is `gh`, inside check-gate and
open-pr, and its binary comes from env FACTORY_GH.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
NEVER_PATHS_FILE = os.path.join(HERE, "never-paths.json")
SPEC_KINDS = {"docs", "tests", "manifest", "code", "agent-rules"}


class SetupError(Exception):
    """The check could not be trusted: unreadable inputs, git/gh broken,
    a check command violating its protocol. Exit code 2."""


def emit(ok: bool, check: str, reasons: list, extra: dict | None = None) -> None:
    out = {"ok": ok, "check": check, "reasons": reasons}
    if extra:
        out.update(extra)
    sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    if ok:
        sys.stderr.write("%s: PASS\n" % check)
    else:
        sys.stderr.write("%s: FAIL (%d reasons)\n" % (check, len(reasons)))
        for r in reasons[:20]:
            sys.stderr.write("  - %s\n" % r)


# --------------------------------------------------------------------------
# git helpers (argument lists, never a shell string)
# --------------------------------------------------------------------------

def git(repo: str, *args: str, allow_fail: bool = False) -> str:
    cmd = ["git", "-C", repo] + list(args)
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True)
    if proc.returncode != 0 and not allow_fail:
        raise SetupError("git %s failed (exit %d): %s"
                         % (" ".join(args), proc.returncode, proc.stderr.strip()[:300]))
    return proc.stdout


def git_bytes(repo: str, *args: str) -> bytes:
    cmd = ["git", "-C", repo] + list(args)
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return proc.stdout if proc.returncode == 0 else b""


def head_exists(repo: str) -> bool:
    proc = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", "HEAD"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return proc.returncode == 0


def diff_touched(repo: str, sha: str) -> dict:
    """Union of `git diff --name-status <sha>` (committed+staged+unstaged)
    and untracked files, per CONTRACT.md point 6. Returns path -> status
    ('A' added, 'M' modified, 'D' deleted, 'R' renamed; rename sides are
    'R' and 'A'). Untracked count as 'A'."""
    touched: dict = {}
    raw = git(repo, "diff", "--name-status", "-z", sha)
    fields = [f for f in raw.split("\0") if f != ""]
    i = 0
    while i < len(fields):
        token = fields[i]  # e.g. "M", "A", "D", "R100"
        letter = token[0]
        if letter in ("R", "C"):
            old, new = fields[i + 1], fields[i + 2]
            touched[old] = "D" if letter == "C" else "R"
            touched[new] = "A"
            i += 3
        else:
            touched[fields[i + 1]] = letter
            i += 2
    others = git(repo, "ls-files", "--others", "--exclude-standard", "-z")
    for p in [p for p in others.split("\0") if p]:
        touched.setdefault(p, "A")
    return touched


# --------------------------------------------------------------------------
# globs (CONTRACT.md point 1: ** crosses folders)
# --------------------------------------------------------------------------

def glob_to_regex(pat: str) -> "re.Pattern":
    out: list = []
    i, n = 0, len(pat)
    while i < n:
        if pat.startswith("/**/", i):
            out.append("/(?:[^/]+/)*")
            i += 4
        elif pat.startswith("**/", i):
            out.append("(?:[^/]+/)*")
            i += 3
        elif pat.startswith("/**", i) and i + 3 == n:
            out.append("/.+")
            i += 3
        elif pat.startswith("**", i):
            out.append(".*")
            i += 2
        elif pat[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pat[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pat[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def glob_match(globs: list, path: str) -> bool:
    return any(glob_to_regex(g).match(path) for g in globs)


# --------------------------------------------------------------------------
# test-path classification — must agree with looksLikeTestPath in
# agents/factory-guard/policy.ts (parity-tested in agents/factory/tests/)
# --------------------------------------------------------------------------

def _last_index(segs: list, needle: str) -> int:
    for i in range(len(segs) - 1, -1, -1):
        if segs[i] == needle:
            return i
    return -1


def looks_like_test_path(p: str) -> bool:
    segs = [s for s in re.split(r"[\\/]", p) if s]
    low = [s.lower() for s in segs]
    for needle in ("tests", "test"):
        idx = _last_index(low, needle)
        if idx != -1 and idx < len(low) - 1:
            return True
    base = low[-1] if low else ""
    if re.search(r"\.test\.[a-z0-9]+\Z", base):
        return True
    if re.search(r"_test\.[a-z0-9]+\Z", base):
        return True
    if re.search(r"^test_.*\.py\Z", base):
        return True
    return False


# --------------------------------------------------------------------------
# fenced JSON blocks (specs, findings, verdicts)
# --------------------------------------------------------------------------

_FENCE_OPEN = re.compile(r"^```json[ \t]*$")
_FENCE_CLOSE = re.compile(r"^```[ \t]*$")


def extract_json_block(text: str, what: str):
    """Return the parsed value of the exactly-one fenced json block.
    Contract violation (zero or 2+ blocks, invalid JSON, wrong top-level
    shape) is a finding, not a setup error, EXCEPT unreadable files — those
    raise SetupError at the caller. Returns (value, reasons)."""
    lines = text.splitlines()
    starts = [i for i, ln in enumerate(lines) if _FENCE_OPEN.match(ln)]
    if len(starts) == 0:
        return None, ["%s: no fenced ```json block found" % what]
    if len(starts) > 1:
        return None, ["%s: %d fenced json blocks, want exactly 1" % (what, len(starts))]
    body = []
    closed = False
    for ln in lines[starts[0] + 1:]:
        if _FENCE_CLOSE.match(ln):
            closed = True
            break
        body.append(ln)
    if not closed:
        return None, ["%s: fenced json block is never closed" % what]
    try:
        return json.loads("\n".join(body)), []
    except json.JSONDecodeError as e:
        return None, ["%s: json block does not parse: %s" % (what, e)]


def read_text_file(path: str) -> str:
    if not os.path.isfile(path):
        raise SetupError("file not found: %s" % path)
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError) as e:
        raise SetupError("cannot read %s: %s" % (path, e))


# --------------------------------------------------------------------------
# spec validation (CONTRACT.md point 1)
# --------------------------------------------------------------------------

def validate_spec(value, is_lint: bool) -> list:
    reasons: list = []
    if not isinstance(value, dict):
        return ["spec: top level must be a JSON object"]
    expected = {"repo", "base", "kind", "allowedPaths", "acs", "maxDiffLines"}
    extra = sorted(set(value) - expected)
    missing = sorted(expected - set(value))
    if extra:
        reasons.append("spec: unknown keys %s" % extra)
    if missing:
        reasons.append("spec: missing keys %s" % missing)
    if reasons:
        return reasons
    repo = value["repo"]
    if not (isinstance(repo, str) and re.match(r"^[^/]+/[^/]+$", repo)):
        reasons.append("spec: repo must be OWNER/REPO")
    if not (isinstance(value["base"], str) and value["base"]):
        reasons.append("spec: base must be a non-empty string")
    if value["kind"] not in SPEC_KINDS:
        reasons.append("spec: kind %r not in %s" % (value["kind"], sorted(SPEC_KINDS)))
    ap = value["allowedPaths"]
    if not (isinstance(ap, list) and len(ap) >= 1
            and all(isinstance(g, str) and g for g in ap)):
        reasons.append("spec: allowedPaths must be a list of >=1 non-empty globs")
    md = value["maxDiffLines"]
    if not (isinstance(md, int) and not isinstance(md, bool) and md > 0):
        reasons.append("spec: maxDiffLines must be an integer > 0")
    acs = value["acs"]
    if not isinstance(acs, list) or len(acs) < 1:
        reasons.append("spec: acs must be a list with at least one AC")
        return reasons
    seen_ids = set()
    for ac in acs:
        if not isinstance(ac, dict) or set(ac) != {"id", "text", "check"}:
            reasons.append("spec: each ac must be exactly {id, text, check}: %r" % (ac,))
            continue
        aid = ac["id"]
        if not (isinstance(aid, str) and re.match(r"^AC-[0-9]+$", aid)
                and not re.match(r"^AC-0[0-9]+$", aid)):
            reasons.append("spec: ac id %r must be AC-<n>, no leading zeros" % (aid,))
        elif aid in seen_ids:
            reasons.append("spec: duplicate ac id %r" % aid)
        seen_ids.add(aid)
        if not (isinstance(ac["text"], str) and ac["text"].strip()):
            reasons.append("spec: %s: text must be non-empty" % aid)
        chk = ac["check"]
        if not (isinstance(chk, str) and chk.strip() and "\n" not in chk):
            reasons.append("spec: %s: check must be one single-line command" % aid)
    return reasons


def load_spec(path: str) -> dict:
    value, reasons = extract_json_block(read_text_file(path), "spec")
    if reasons:
        raise SetupError("; ".join(reasons))
    spec_reasons = validate_spec(value, False)
    if spec_reasons:
        raise SetupError("spec invalid: " + "; ".join(spec_reasons))
    return value


# --------------------------------------------------------------------------
# AC check engine (CONTRACT.md point 2)
# --------------------------------------------------------------------------

_AC_LINE = re.compile(r"^(AC-[0-9]+): (PASS|FAIL)(?: (.+))?$")


def group_acs(spec: dict) -> dict:
    groups: dict = {}
    for ac in spec["acs"]:
        groups.setdefault(ac["check"], []).append(ac["id"])
    return groups


def run_ac_checks(repo: str, spec: dict, expect: str):
    """Run every unique check command once. expect is 'PASS' or 'FAIL'.
    Returns (violations, setup_errors)."""
    violations: list = []
    setup: list = []
    for cmd, ac_ids in group_acs(spec).items():
        proc = subprocess.run(["bash", "-c", cmd], cwd=repo,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        sys.stderr.write(proc.stderr)
        rc = proc.returncode
        if rc not in (0, 1):
            setup.append("setup error: check %r exited %d (protocol allows 0 or 1)" % (cmd, rc))
            continue
        reported: dict = {}
        for line in proc.stdout.splitlines():
            m = _AC_LINE.match(line.strip())
            if not m:
                continue
            aid, status = m.group(1), m.group(2)
            if aid in ac_ids:
                if aid in reported and reported[aid] != status:
                    setup.append("setup error: check %r reports %s twice with different status" % (cmd, aid))
                reported[aid] = status
            else:
                setup.append("setup error: check %r reports %s, which it does not cover" % (cmd, aid))
        for aid in ac_ids:
            if aid not in reported:
                setup.append("setup error: no AC line for %s from check %r" % (aid, cmd))
        fails = [a for a in ac_ids if reported.get(a) == "FAIL"]
        passes = [a for a in ac_ids if reported.get(a) == "PASS"]
        if rc == 0 and fails:
            setup.append("setup error: check %r exited 0 but reports FAIL (%s)" % (cmd, ",".join(fails)))
        if rc == 1 and not fails:
            setup.append("setup error: check %r exited 1 but no covered AC reports FAIL" % cmd)
        if expect == "FAIL":
            for aid in passes:
                violations.append("%s reported PASS during red" % aid)
        else:
            for aid in fails:
                violations.append("%s reported FAIL: %s" % (aid, cmd))
    return violations, setup


# --------------------------------------------------------------------------
# never paths (CONTRACT.md point 5)
# --------------------------------------------------------------------------

def load_never_paths() -> dict:
    try:
        with open(NEVER_PATHS_FILE, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise SetupError("never-paths.json unreadable: %s" % e)
    for key in ("globs", "newFilesUnder", "contentRules"):
        if key not in cfg:
            raise SetupError("never-paths.json missing key %r" % key)
    return cfg


def _kind_lines_hit(text: str, kinds: list) -> bool:
    for kind in kinds:
        if re.search(r"^[ \t]*kind:[ \t]+%s[ \t]*(#.*)?$" % re.escape(kind),
                     text, re.MULTILINE):
            return True
    return False


def _sops_root(text: str) -> bool:
    return bool(re.search(r"^sops:[ \t]*$", text, re.MULTILINE))


def never_path_reasons(cfg: dict, path: str, status: str, text_provider) -> list:
    """text_provider(path) -> new-version text or None. Returns reasons []
    when the path is fine (not a never path)."""
    reasons: list = []
    if glob_match(cfg["globs"], path):
        reasons.append("never path (glob): %s" % path)
        return reasons
    for prefix in cfg.get("newFilesUnder", []):
        if status == "A" and path.startswith(prefix):
            reasons.append("never path (new file under %s): %s" % (prefix, path))
            return reasons
    rules = cfg.get("contentRules", {})
    exts = tuple(rules.get("extensions", []))
    if exts and path.endswith(exts):
        text = text_provider(path)
        if text is not None:
            kinds = rules.get("forbiddenKinds", [])
            if kinds and _kind_lines_hit(text, kinds):
                reasons.append("never path (content kind): %s" % path)
            if rules.get("forbiddenSopsKey") and _sops_root(text):
                reasons.append("never path (sops-encrypted): %s" % path)
    return reasons


def worktree_text(repo: str, path: str):
    full = os.path.join(repo, path)
    if not os.path.isfile(full):
        return None
    try:
        with open(full, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


# --------------------------------------------------------------------------
# gh helper (check-gate / open-pr only)
# --------------------------------------------------------------------------

def gh_bin() -> str:
    return os.environ.get("FACTORY_GH", "gh")


def gh_json(args: list) -> object:
    cmd = [gh_bin()] + args
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise SetupError("gh %s failed (exit %d): %s"
                         % (" ".join(args[:3]), proc.returncode, proc.stderr.strip()[:300]))
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        raise SetupError("gh %s returned non-JSON: %s" % (" ".join(args[:3]), e))


def gh_text(args: list) -> str:
    cmd = [gh_bin()] + args
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise SetupError("gh %s failed (exit %d): %s"
                         % (" ".join(args[:3]), proc.returncode, proc.stderr.strip()[:300]))
    return proc.stdout


def parse_pr_ref(ref: str):
    if "#" not in ref:
        raise SetupError("--pr must be OWNER/REPO#N, got %r" % ref)
    repo_part, _, num = ref.rpartition("#")
    if not re.match(r"^[^/]+/[^/]+$", repo_part) or not num.isdigit():
        raise SetupError("--pr must be OWNER/REPO#N, got %r" % ref)
    return repo_part, num


# --------------------------------------------------------------------------
# subcommands
# --------------------------------------------------------------------------

def cmd_lint_spec(args) -> int:
    text = read_text_file(args.spec)
    value, reasons = extract_json_block(text, "spec")
    if reasons:
        emit(False, "lint-spec", reasons)
        return 1
    reasons = validate_spec(value, True)
    if reasons:
        emit(False, "lint-spec", reasons)
        return 1
    emit(True, "lint-spec", [])
    return 0


def cmd_check_red(args) -> int:
    spec = load_spec(args.spec)
    touched = diff_touched(args.repo, args.base)
    reasons: list = []
    for path, status in sorted(touched.items()):
        if not looks_like_test_path(path):
            reasons.append("red stage touched a non-test path: %s" % path)
        elif not glob_match(spec["allowedPaths"], path):
            reasons.append("test path outside allowedPaths: %s" % path)
    if not touched:
        reasons.append("nothing changed: red requires failing tests")
    violations, setup = run_ac_checks(args.repo, spec, "FAIL")
    reasons.extend(violations)
    if setup:
        emit(False, "check-red", reasons + setup)
        return 2
    emit(len(reasons) == 0, "check-red", reasons)
    return 0 if not reasons else 1


def cmd_check_green(args) -> int:
    spec = load_spec(args.spec)
    touched = diff_touched(args.repo, args.red)
    reasons: list = []
    for path, status in sorted(touched.items()):
        if looks_like_test_path(path):
            reasons.append("test path differs from the red commit: %s (%s)" % (path, status))
        if not glob_match(spec["allowedPaths"], path):
            reasons.append("changed path outside allowedPaths: %s" % path)
    violations, setup = run_ac_checks(args.repo, spec, "PASS")
    reasons.extend(violations)
    if setup:
        emit(False, "check-green", reasons + setup)
        return 2
    check_sh = os.path.join(args.repo, "scripts", "check.sh")
    if os.path.isfile(check_sh):
        proc = subprocess.run(["bash", "scripts/check.sh"], cwd=args.repo,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        sys.stderr.write(proc.stdout)
        if proc.returncode != 0:
            reasons.append("scripts/check.sh exited %d" % proc.returncode)
    emit(len(reasons) == 0, "check-green", reasons)
    return 0 if not reasons else 1


def validate_findings(value):
    if not isinstance(value, list):
        return None, ["findings: top level must be a JSON list (empty list = no findings)"]
    reasons: list = []
    seen = set()
    for f in value:
        if not isinstance(f, dict) or set(f) != {"id", "file", "line", "severity", "claim"}:
            reasons.append("finding must be exactly {id, file, line, severity, claim}: %r" % (f,))
            continue
        if not (isinstance(f["id"], str) and re.match(r"^F-[0-9]+$", f["id"])):
            reasons.append("finding id %r must be F-<n>" % (f["id"],))
        elif f["id"] in seen:
            reasons.append("duplicate finding id %r" % f["id"])
        seen.add(f["id"])
        if not (isinstance(f["file"], str) and f["file"]):
            reasons.append("%s: file must be a non-empty repo-relative path" % f["id"])
        if not (isinstance(f["line"], int) and not isinstance(f["line"], bool) and f["line"] >= 1):
            reasons.append("%s: line must be an integer >= 1" % f["id"])
        if f["severity"] not in ("blocking", "minor"):
            reasons.append("%s: severity %r must be blocking|minor" % (f["id"], f["severity"]))
        if not (isinstance(f["claim"], str) and f["claim"].strip()):
            reasons.append("%s: claim must be non-empty" % f["id"])
    return value if not reasons else None, reasons


def cmd_check_findings(args) -> int:
    value, reasons = extract_json_block(read_text_file(args.findings), "findings")
    if reasons:
        emit(False, "check-findings", reasons)
        return 1
    findings, vreasons = validate_findings(value)
    if vreasons:
        emit(False, "check-findings", vreasons)
        return 1
    touched = set(diff_touched(args.repo, args.base))
    for f in findings:
        if f["file"] not in touched:
            reasons.append("%s: file %s is not in the diff from %s" % (f["id"], f["file"], args.base))
            continue
        text = worktree_text(args.repo, f["file"])
        if text is None:
            reasons.append("%s: no new version of %s to check line %d against"
                           % (f["id"], f["file"], f["line"]))
            continue
        n_lines = len(text.splitlines())
        if f["line"] > n_lines:
            reasons.append("%s: line %d does not exist in %s (%d lines)"
                           % (f["id"], f["line"], f["file"], n_lines))
    emit(len(reasons) == 0, "check-findings", reasons)
    return 0 if not reasons else 1


def cmd_check_verdicts(args) -> int:
    f_value, reasons = extract_json_block(read_text_file(args.findings), "findings")
    if reasons:
        emit(False, "check-verdicts", reasons)
        return 1
    findings, vreasons = validate_findings(f_value)
    if vreasons:
        emit(False, "check-verdicts", vreasons)
        return 1
    v_value, v2reasons = extract_json_block(read_text_file(args.verdicts), "verdicts")
    if v2reasons:
        emit(False, "check-verdicts", v2reasons)
        return 1
    reasons = []
    if not isinstance(v_value, list):
        emit(False, "check-verdicts", ["verdicts: top level must be a JSON list"])
        return 1
    seen = set()
    by_id = {}
    for v in v_value:
        if not isinstance(v, dict) or set(v) != {"id", "verdict", "evidence"}:
            reasons.append("verdict must be exactly {id, verdict, evidence}: %r" % (v,))
            continue
        if not (isinstance(v["id"], str) and re.match(r"^F-[0-9]+$", v["id"])):
            reasons.append("verdict id %r must be F-<n>" % (v["id"],))
        elif v["id"] in seen:
            reasons.append("duplicate verdict for %s" % v["id"])
        else:
            seen.add(v["id"])
            by_id[v["id"]] = v
        if v.get("verdict") not in ("confirmed", "rejected", "unproven"):
            reasons.append("%s: verdict %r must be confirmed|rejected|unproven" % (v.get("id"), v.get("verdict")))
        if not (isinstance(v.get("evidence"), str) and v["evidence"].strip()):
            reasons.append("%s: evidence must be non-empty" % v.get("id"))
    f_ids = [f["id"] for f in findings if isinstance(f, dict) and "id" in f]
    for fid in f_ids:
        if fid not in seen:
            reasons.append("finding %s has no verdict" % fid)
    for vid in sorted(seen):
        if vid not in f_ids:
            reasons.append("verdict %s has no matching finding" % vid)
    blocking_confirmed = [
        f["id"] for f in findings
        if f["id"] in by_id and f["severity"] == "blocking"
        and by_id[f["id"]]["verdict"] == "confirmed"
    ]
    ok = len(reasons) == 0
    emit(ok, "check-verdicts", reasons, {"blockingConfirmed": blocking_confirmed if ok else []})
    return 0 if ok else 1


def cmd_check_gate(args) -> int:
    spec = load_spec(args.spec)
    repo, num = parse_pr_ref(args.pr)
    view = gh_json(["pr", "view", num, "--repo", repo, "--json",
                    "headRefOid,baseRefOid,additions,deletions,files"])
    reasons: list = []
    try:
        head_oid = view["headRefOid"]
        base_oid = view["baseRefOid"]
        additions = int(view["additions"])
        deletions = int(view["deletions"])
        files = view["files"]
    except (KeyError, TypeError, ValueError) as e:
        raise SetupError("gh pr view json missing field: %r" % e)
    checks = gh_json(["pr", "checks", num, "--repo", repo, "--json", "name,state"])
    named = [c for c in checks if isinstance(c, dict) and c.get("name") == "check"]
    if not named:
        reasons.append("no check run named 'check' on this PR")
    elif not any(str(c.get("state", "")).upper() == "SUCCESS" for c in named):
        states = sorted({str(c.get("state")) for c in named})
        reasons.append("check run is not SUCCESS (states: %s)" % ",".join(states))
    total = additions + deletions
    if total > spec["maxDiffLines"]:
        reasons.append("diff too big: %d lines > maxDiffLines %d" % (total, spec["maxDiffLines"]))
    cfg = load_never_paths()
    content_cache: dict = {}

    def pr_content_text(path: str, ref: str):
        key = (path, ref)
        if key not in content_cache:
            out = subprocess.run([gh_bin(), "api",
                                  "/repos/%s/contents/%s?ref=%s" % (repo, path, ref)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            payload = None
            if out.returncode == 0:
                try:
                    payload = json.loads(out.stdout)
                except json.JSONDecodeError:
                    raise SetupError("gh api contents for %s returned non-JSON" % path)
            if payload is None:
                raise SetupError("gh api contents for %s failed (exit %d): %s"
                                 % (path, out.returncode, out.stderr.strip()[:200]))
            try:
                content_cache[key] = base64.b64decode(
                    payload["content"]).decode("utf-8", errors="replace")
            except (KeyError, TypeError, ValueError) as e:
                raise SetupError("gh api contents for %s: bad payload (%r)" % (path, e))
        return content_cache[key]

    for entry in files:
        path = entry.get("path")
        if not path:
            raise SetupError("gh pr view files entry without path: %r" % entry)
        status = "A" if entry.get("changeType") == "ADDED" else \
                 "D" if entry.get("changeType") == "DELETED" else "M"

        def provider(p: str, _path=path, _status=status):
            ref = head_oid if _status != "D" else base_oid
            return pr_content_text(_path, ref)

        reasons.extend(never_path_reasons(cfg, path, status, provider))
    emit(len(reasons) == 0, "check-gate", reasons)
    return 0 if not reasons else 1


def cmd_commit(args) -> int:
    if args.stage not in ("red", "green"):
        raise SetupError("--stage must be red or green")
    if not re.match(r"^GUL-[0-9]+$", args.issue):
        raise SetupError("--issue must be GUL-<n>, got %r" % args.issue)
    if head_exists(args.repo):
        touched = diff_touched(args.repo, "HEAD")
    else:
        touched = {p: "A" for p in
                   [q for q in git(args.repo, "ls-files", "--others", "--exclude-standard", "-z").split("\0") if q]}
    reasons: list = []
    for path in sorted(touched):
        is_test = looks_like_test_path(path)
        if args.stage == "red" and not is_test:
            reasons.append("red commit touches a non-test path: %s" % path)
        if args.stage == "green" and is_test:
            reasons.append("green commit touches a test path: %s" % path)
    if not touched:
        # A decide that died after its commit (Paperclip error, crash, cancelled
        # run) is re-run against a clean tree. The stage's own commit IS HEAD
        # then, so hand back that sha instead of refusing: otherwise a stage
        # that already did its work can never be recorded, and the work order
        # stalls with a null sha in the ledger (GUL-497).
        head_subject = git(args.repo, "log", "-1", "--format=%s").strip() if head_exists(args.repo) else ""
        wanted = "factory(%s): %s" % (args.issue, args.stage)
        if head_subject == wanted:
            emit(True, "commit", ["already committed: HEAD is this stage's commit"],
                 {"sha": git(args.repo, "rev-parse", "HEAD").strip()})
            return 0
        reasons.append("nothing to commit")
    if reasons:
        emit(False, "commit", reasons)
        return 1
    git(args.repo, "add", "-A")
    message = "factory(%s): %s\n\nCo-Authored-By: Paperclip <noreply@paperclip.ing>\n" % (args.issue, args.stage)
    git(args.repo, "-c", "user.name=factory", "-c", "user.email=factory@paperclip.ing",
        "commit", "-m", message)
    sha = git(args.repo, "rev-parse", "HEAD").strip()
    emit(True, "commit", [], {"sha": sha})
    return 0


def cmd_open_pr(args) -> int:
    if not re.match(r"^GUL-[0-9]+$", args.issue):
        raise SetupError("--issue must be GUL-<n>, got %r" % args.issue)
    branch = git(args.repo, "rev-parse", "--abbrev-ref", "HEAD").strip()
    if branch in ("main", "master"):
        emit(False, "open-pr", ["refusing to open a PR from %s" % branch])
        return 1
    if head_exists(args.repo) and git(args.repo, "status", "--porcelain").strip():
        emit(False, "open-pr", ["uncommitted changes: run `commit` first"])
        return 1
    remote_url = git(args.repo, "remote", "get-url", "origin").strip()
    m = re.search(r"([^/:]+)/([^/]+?)(?:\.git)?$", remote_url)
    if not m or ":" not in remote_url and "/" not in remote_url.replace("://", ""):
        raise SetupError("cannot derive OWNER/REPO from origin %r" % remote_url)
    owner_repo = "%s/%s" % (m.group(1), m.group(2))
    git(args.repo, "push", "-u", "origin", branch)
    body = "Work order: [%s](https://paperclip.voitech.dev/GUL/issues/%s)\n" % (args.issue, args.issue)
    url = gh_text(["pr", "create", "--repo", owner_repo, "--title", args.title,
                   "--body", body, "--head", branch]).strip()
    if not url.startswith("http"):
        raise SetupError("gh pr create did not print a URL: %r" % url[:200])
    emit(True, "open-pr", [], {"url": url})
    return 0


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# factory phase 2 (GUL-439): the script drives Paperclip
# --------------------------------------------------------------------------
#
# These three subcommands (start, decide, tick) are the only ones that talk to
# Paperclip. They use pc.py (stdlib urllib) with auth from PAPERCLIP_API_KEY
# and PAPERCLIP_RUN_ID only — never ~/.paperclip/auth.json (GUL-297).

FACTORY_DIR = HERE
STAGE_ORDER = ("red", "green", "review", "verify", "gate")
OPEN_STATUSES = {"backlog", "todo", "in_progress", "in_review", "blocked"}
HANDOFF_POLICY_TEMPLATE = {
    "stages": [{"type": "review", "participants": [{"type": "agent", "agentId": ""}]}],
}


def _sys_path_for_modules() -> None:
    # `python3 -I` drops the script's own directory from sys.path, so a module
    # next to factory.py is only importable after putting it back explicitly.
    if HERE not in sys.path:
        sys.path.insert(0, HERE)


def _stop_file() -> str:
    return os.environ.get("FACTORY_STOP") or os.path.expanduser(
        "~/paperclip-agents/majster/factory/STOP")


def _ledger_jsonl() -> str:
    return os.environ.get("FACTORY_LEDGER_JSONL") or os.path.expanduser(
        "~/paperclip-agents/majster/factory/ledger.jsonl")


def load_agent_config() -> dict:
    path = os.environ.get("FACTORY_AGENTS_FILE") or os.path.join(FACTORY_DIR, "agents.json")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as exc:
        raise SetupError("cannot read %s: %s" % (path, exc))


def handoff_policy(cfg: dict) -> dict:
    policy = json.loads(json.dumps(HANDOFF_POLICY_TEMPLATE))
    policy["stages"][0]["participants"][0]["agentId"] = cfg["majster"]
    return policy


def stage_agent(cfg: dict, stage: str) -> dict:
    try:
        return cfg["stages"][stage]
    except KeyError:
        raise SetupError("agents.json has no entry for stage %r" % stage)


def fill_template(stage: str, values: dict) -> str:
    path = os.path.join(FACTORY_DIR, "templates", stage + ".md")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        raise SetupError("cannot read template %s: %s" % (path, exc))
    for key, value in values.items():
        text = text.replace("{{" + key + "}}", str(value))
    leftover = re.findall(r"\{\{([a-z][a-zA-Z0-9_]*)\}\}", text)
    if leftover:
        raise SetupError("template %s has unfilled placeholders: %s"
                         % (stage, ", ".join(sorted(set(leftover)))))
    return text


def slugify(text: str, limit: int = 40) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return (slug[:limit].rstrip("-") or "work")


def load_json_document(api, issue_id: str, key: str):
    """Read a document and parse its one fenced json block. Returns None when
    the document does not exist, an empty dict when it has no block."""
    doc = api.document(issue_id, key)
    if not doc:
        return None
    body = doc.get("body") if isinstance(doc, dict) else None
    if not isinstance(body, str):
        return None
    if "```json" not in body:
        return {}
    value, _reasons = extract_json_block(body, key)
    return value


def fence_json_document(title: str, prose: str, payload) -> str:
    return "%s\n\n```json\n%s\n```\n" % (prose.rstrip(), json.dumps(payload, indent=1, ensure_ascii=False))


def save_ledger(api, work_order_id: str, ledger: dict, summary: str) -> None:
    body = fence_json_document(
        "Factory ledger",
        "# Factory ledger\n\nWritten by `factory.py`; one fenced JSON block is the state. "
        "Do not hand-edit: `factory decide` keeps it.",
        ledger)
    response = api.write_document(work_order_id, "ledger", body,
                                  title="Factory ledger", change_summary=summary)
    doc = response.get("document") if isinstance(response, dict) else None
    if not isinstance(doc, dict) or not doc.get("id"):
        raise SetupError("ledger write was not echoed back by Paperclip")


def _run_self(args: list) -> tuple:
    """Run one of this script's checks as a child process. Returns
    (exit_code, parsed json line or None, combined output tail)."""
    cmd = [sys.executable, "-I", os.path.abspath(__file__)] + args
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out = proc.stdout.strip()
    parsed = None
    if out:
        try:
            parsed = json.loads(out.splitlines()[-1])
        except ValueError:
            parsed = None
    combined = "\n".join(x for x in (proc.stdout, proc.stderr) if x)
    return proc.returncode, parsed, combined


def check_comment(parsed, combined: str) -> str:
    line = json.dumps(parsed, ensure_ascii=False) if parsed is not None else "(no json)"
    tail = [ln for ln in combined.splitlines() if ln.strip()][-60:]
    return "%s\n\n```\n%s\n```" % (line, "\n".join(tail))


def resolve_issue(api, company_id: str, identifier: str):
    issue = api.by_identifier(company_id, identifier)
    if not issue:
        raise SetupError("issue %s not found in company %s" % (identifier, company_id))
    return issue


def work_order_cwd(api, issue: dict) -> str:
    workspace = issue.get("currentExecutionWorkspace")
    if isinstance(workspace, dict) and workspace.get("cwd"):
        return workspace["cwd"]
    project_id = issue.get("projectId")
    if project_id:
        try:
            for ws in api.project_workspaces(project_id) or []:
                if ws.get("isPrimary") and ws.get("cwd"):
                    return ws["cwd"]
        except Exception:  # noqa: BLE001 - a missing project must not hide FACTORY_REPO
            pass
    return os.environ.get("FACTORY_REPO") or os.path.abspath(os.path.join(FACTORY_DIR, "..", ".."))


def open_work_orders(api, company_id: str, cfg: dict, exclude_id: str, project_id) -> list:
    """Every other open issue in the same project that is assigned to Majster and
    carries a `spec` document. Document check is per issue: the company list does
    not include document summaries."""
    found = []
    for item in api.issues(company_id):
        if item.get("id") == exclude_id:
            continue
        if item.get("status") not in OPEN_STATUSES:
            continue
        if item.get("assigneeAgentId") != cfg["majster"]:
            continue
        if project_id and item.get("projectId") != project_id:
            continue
        if api.document(item["id"], "spec"):
            found.append(item)
    return found


def stage_title(work_order: str, title: str, stage: str, round_no: int) -> str:
    suffix = "" if round_no == 1 else " r%d" % round_no
    return "[%s%s] %s — %s" % (stage, suffix, work_order, title[:120])


def stage_key(stage: str, round_no: int) -> str:
    return stage if round_no == 1 else "%s:r%d" % (stage, round_no)


def template_values(spec: dict, ledger: dict, cfg: dict, stage: str, round_no: int,
                    work_order: dict, extra: dict) -> dict:
    acs = "\n".join("   - %s: %s" % (a.get("id"), a.get("text")) for a in spec.get("acs", []))
    commands = "\n".join("   - `%s`" % a.get("check") for a in spec.get("acs", []))
    values = {
        "workOrder": ledger["workOrder"],
        "workOrderId": work_order["id"],
        "workOrderTitle": work_order.get("title", ""),
        "repo": ledger["repo"],
        "cwd": ledger["cwd"],
        "branch": ledger["branch"],
        "base": ledger["base"],
        "baseSha": ledger["baseSha"],
        "kind": spec.get("kind", ""),
        "allowedPaths": ", ".join("`%s`" % p for p in spec.get("allowedPaths", [])),
        "acs": acs,
        "checkCommands": commands,
        "maxDiffLines": spec.get("maxDiffLines", 400),
        "roundSuffix": "" if round_no == 1 else " r%d" % round_no,
        "handoffPatch": json.dumps(handoff_policy(cfg), separators=(",", ":")),
        "redSha": (ledger.get("stages", {}).get("red") or {}).get("sha", "(red not committed)"),
        "reviewIssue": (ledger.get("stages", {}).get("review:r%d" % round_no)
                        or ledger.get("stages", {}).get("review") or {}).get("identifier", "?"),
        "prRef": "%s#%s" % (ledger["repo"], (ledger.get("pr") or {}).get("number", "?")),
        "findingsBlock": "",
    }
    values.update(extra)
    return values


def plan_stages(cfg: dict, spec: dict, ledger: dict, work_order: dict, round_no: int,
                findings_block: str) -> list:
    plan = []
    for stage in STAGE_ORDER if round_no == 1 else ("green", "review", "verify"):
        agent = stage_agent(cfg, stage)
        extra = {"findingsBlock": findings_block if stage == "green" else ""}
        plan.append({
            "stage": stage,
            "key": stage_key(stage, round_no),
            "title": stage_title(ledger["workOrder"], work_order.get("title", ""), stage, round_no),
            "description": fill_template(
                stage, template_values(spec, ledger, cfg, stage, round_no, work_order, extra)),
            "agentId": agent["agentId"],
            "agentName": agent.get("name", stage),
            "round": round_no,
        })
    return plan


def create_stages(api, work_order_id: str, plan: list, cfg: dict) -> list:
    created = []
    previous = None
    policy = handoff_policy(cfg)
    for item in plan:
        body = {
            "title": item["title"],
            "description": item["description"],
            "status": "todo" if previous is None else "blocked",
            "priority": "medium",
            "assigneeAgentId": item["agentId"],
            "executionPolicy": policy,
        }
        if previous is not None:
            body["blockedByIssueIds"] = [previous]
        child = api.create_child(work_order_id, body)
        if not isinstance(child, dict) or not child.get("id"):
            raise SetupError("child creation for stage %s was not echoed back" % item["stage"])
        if child.get("status") != body["status"]:
            raise SetupError("stage %s came back %r, wanted %r"
                             % (item["stage"], child.get("status"), body["status"]))
        created.append({"stage": item["stage"], "key": item["key"], "round": item["round"],
                        "issue": child})
        previous = child["id"]
    return created


def _resolve_base(repo: str, base: str) -> str:
    base_sha = git(repo, "rev-parse", "origin/" + base, allow_fail=True).strip()
    if not base_sha:
        base_sha = git(repo, "rev-parse", base, allow_fail=True).strip()
    if not base_sha:
        raise SetupError("cannot resolve base %r in %s" % (base, repo))
    return base_sha


def _switch_to_work_order_branch(repo: str, branch: str, base_sha: str) -> str:
    """Cut the work order branch at base_sha, or switch to it when it is already
    there at that sha (the "start twice" case). Returns "" on success, or the
    reason the branch cannot be used."""
    existing = git(repo, "rev-parse", "--verify", "--quiet", "refs/heads/" + branch,
                   allow_fail=True).strip()
    if existing and existing != base_sha:
        return ("branch %s already exists at %s, not at the work order base %s: "
                "move it out of the way before starting"
                % (branch, existing[:12], base_sha[:12]))
    if existing:
        git(repo, "switch", branch)
    else:
        git(repo, "switch", "-c", branch, base_sha)
    return ""


def cmd_factory_start(args) -> int:
    _sys_path_for_modules()
    import pc

    if os.path.exists(_stop_file()):
        emit(False, "start", ["STOP flag present: %s" % _stop_file()])
        return 1
    try:
        api = pc.Api()
    except LookupError as exc:
        sys.stderr.write("factory start: %s\n" % exc)
        return 2
    company = os.environ.get("PAPERCLIP_COMPANY_ID") or args.company
    cfg = load_agent_config()

    work_order = resolve_issue(api, company, args.work_order)
    spec_doc = api.document(work_order["id"], "spec")
    if not spec_doc or not spec_doc.get("body"):
        raise SetupError("%s has no `spec` document" % args.work_order)

    import tempfile
    spec_path = os.path.join(tempfile.mkdtemp(prefix="factory-spec-"), "spec.md")
    with open(spec_path, "w", encoding="utf-8") as fh:
        fh.write(spec_doc["body"])
    code, lint, lint_output = _run_self(["lint-spec", "--spec", spec_path])
    if code != 0:
        emit(False, "start", ["spec lint failed"] + list((lint or {}).get("reasons", [])),
             {"workOrder": args.work_order})
        return 1
    spec, spec_reasons = extract_json_block(spec_doc["body"], "spec")
    if spec is None:
        raise SetupError("spec document does not parse: %s" % "; ".join(spec_reasons))

    cwd = args.repo or work_order_cwd(api, work_order)
    # The factory's own code now runs from a checkout of main (GUL-502, ADR-096).
    # That checkout must never be a work order's workspace: `start` would cut the
    # work order branch in it and the next invocation would move it back to main,
    # leaving a ledger pointing at a tree that no longer holds the diff.
    if os.path.realpath(cwd) == os.path.realpath(os.path.join(FACTORY_DIR, "..", "..")):
        raise SetupError(
            "refusing to start a work order in the factory's own tooling checkout (%s): "
            "that copy must stay on main. The work order runs in its own workspace — "
            "check the project workspace, or pass --repo" % cwd)
    project_id = work_order.get("projectId")
    busy = open_work_orders(api, company, cfg, work_order["id"], project_id)
    if busy:
        emit(False, "start", [
            "another factory work order is open: %s (%s)" % (b["identifier"], b.get("status"))
            for b in busy] + [
            "one checkout per work order: the shared checkout cannot hold two diffs "
            "(project worktrees are unavailable on this instance, see ADR-095)"],
            {"workOrder": args.work_order})
        return 1

    base = spec["base"]
    number = args.work_order.split("-")[-1]
    branch = "gul-%s-%s" % (number, slugify(work_order.get("title", "")))

    existing = load_json_document(api, work_order["id"], "ledger")
    if existing and existing.get("stages"):
        emit(True, "start", ["work order already started; nothing created"],
             {"workOrder": args.work_order, "created": 0,
              "stages": existing.get("stages")})
        return 0

    if args.dry_run:
        base_sha = _resolve_base(cwd, base)
    else:
        # The work order runs on its own branch, cut here (GUL-481). Without this
        # the red commit lands on the checkout's local main and `open-pr` refuses
        # ("refusing to open a PR from main"), so a real work order cannot finish.
        git(cwd, "fetch", "origin")
        dirty = git(cwd, "status", "--porcelain").strip()
        if dirty:
            paths = [ln[3:] for ln in dirty.splitlines()][:5]
            emit(False, "start", [
                "checkout is dirty: %s" % ", ".join(paths),
                "commit or stash it first: a work order needs a clean checkout and its "
                "own branch (ADR-095)"], {"workOrder": args.work_order})
            return 1
        base_sha = _resolve_base(cwd, base)
        reason = _switch_to_work_order_branch(cwd, branch, base_sha)
        if reason:
            emit(False, "start", [reason], {"workOrder": args.work_order})
            return 1

    ledger = {
        "version": 1,
        "workOrder": args.work_order,
        "workOrderId": work_order["id"],
        "title": work_order.get("title", ""),
        "repo": spec["repo"],
        "base": base,
        "baseSha": base_sha,
        "cwd": cwd,
        "branch": branch,
        "projectId": project_id,
        "stages": {},
        "fixRounds": 0,
        "pr": None,
        "outcome": None,
        "escalated": None,
    }

    plan = plan_stages(cfg, spec, ledger, work_order, 1, "")
    if args.dry_run:
        emit(True, "start", ["dry run: nothing created"], {
            "workOrder": args.work_order,
            "dryRun": True,
            "cwd": cwd,
            "branch": ledger["branch"],
            "baseSha": base_sha,
            "planned": [{"stage": p["stage"], "title": p["title"],
                         "agent": p["agentName"], "agentId": p["agentId"],
                         "status": "todo" if i == 0 else "blocked",
                         "blockedBy": None if i == 0 else plan[i - 1]["stage"]}
                        for i, p in enumerate(plan)],
        })
        return 0

    created = create_stages(api, work_order["id"], plan, cfg)
    for item in created:
        ledger["stages"][item["key"]] = {
            "issueId": item["issue"]["id"],
            "identifier": item["issue"].get("identifier"),
            "round": item["round"],
            "attempts": 0,
            "sha": None,
        }
    save_ledger(api, work_order["id"], ledger, "start %s" % args.work_order)
    api.comment(work_order["id"],
                "factory start: 5 stage issues created, chained %s. Checkout `%s`, branch `%s`."
                % (" → ".join(i["issue"].get("identifier", "?") for i in created), cwd, ledger["branch"]))
    emit(True, "start", ["5 stage issues created"], {
        "workOrder": args.work_order,
        "created": len(created),
        "cwd": cwd,
        "branch": ledger["branch"],
        "stages": [{"stage": i["stage"], "issue": i["issue"].get("identifier")} for i in created],
    })
    return 0


def _stage_round(stage_issue: dict) -> tuple:
    match = re.match(r"^\[([a-z]+)(?: r([0-9]+))?\]", stage_issue.get("title", ""))
    if not match:
        raise SetupError("stage issue %s has no [stage] title prefix" % stage_issue.get("identifier"))
    return match.group(1), int(match.group(2) or 1)


def _apply_stage_comment(api, stage_issue: dict, text: str) -> None:
    api.comment(stage_issue["id"], text)


def _escalate(api, work_order_id: str, ledger: dict, reason: str, identifier: str) -> None:
    ledger["outcome"] = "escalate"
    ledger["escalated"] = reason
    save_ledger(api, work_order_id, ledger, "escalate %s" % identifier)
    api.patch_issue(work_order_id, {
        "status": "blocked",
        "executionPolicy": None,
        "comment": "factory escalate: %s — no more retries. Wojtek decides." % reason,
    })


def cmd_factory_decide(args) -> int:
    _sys_path_for_modules()
    import pc

    if os.path.exists(_stop_file()):
        emit(False, "decide", ["STOP flag present: %s" % _stop_file()])
        return 1
    try:
        api = pc.Api()
    except LookupError as exc:
        sys.stderr.write("factory decide: %s\n" % exc)
        return 2
    company = os.environ.get("PAPERCLIP_COMPANY_ID") or args.company
    cfg = load_agent_config()

    stage_issue = resolve_issue(api, company, args.stage_issue)
    if not stage_issue.get("parentId"):
        raise SetupError("%s is not a stage issue (no parent work order)" % args.stage_issue)
    work_order = api.issue(stage_issue["parentId"])
    ledger = load_json_document(api, work_order["id"], "ledger")
    if not ledger:
        raise SetupError("%s has no ledger document" % work_order.get("identifier"))
    stage, round_no = _stage_round(stage_issue)
    key = stage_key(stage, round_no)
    if stage not in STAGE_ORDER:
        raise SetupError("unknown stage %r on %s" % (stage, args.stage_issue))

    cwd = ledger["cwd"]
    spec_doc = api.document(work_order["id"], "spec")
    if not spec_doc or not spec_doc.get("body"):
        raise SetupError("%s has no `spec` document" % work_order.get("identifier"))
    import tempfile
    tmp = tempfile.mkdtemp(prefix="factory-decide-")
    spec_path = os.path.join(tmp, "spec.md")
    with open(spec_path, "w", encoding="utf-8") as fh:
        fh.write(spec_doc["body"])

    if stage == "red":
        check_args = ["check-red", "--repo", cwd, "--base", ledger["baseSha"], "--spec", spec_path]
    elif stage == "green":
        red_sha = ((ledger["stages"].get("red") or {}).get("sha"))
        if not red_sha:
            raise SetupError("no red commit recorded in the ledger")
        check_args = ["check-green", "--repo", cwd, "--red", red_sha, "--spec", spec_path]
    elif stage == "review":
        review_key = key
        findings = api.document(stage_issue["id"], "findings")
        if not findings or not findings.get("body"):
            emit(False, "decide", ["review issue has no `findings` document"], {"stage": "review"})
            return 1
        findings_path = os.path.join(tmp, "findings.md")
        with open(findings_path, "w", encoding="utf-8") as fh:
            fh.write(findings["body"])
        check_args = ["check-findings", "--repo", cwd, "--base", ledger["baseSha"],
                      "--findings", findings_path]
    elif stage == "verify":
        review_entry = (ledger["stages"].get("review:r%d" % round_no)
                        or ledger["stages"].get("review") or {})
        review_doc = api.document(review_entry.get("issueId", ""), "findings") if review_entry else None
        verdicts = api.document(stage_issue["id"], "verdicts")
        if not review_doc or not verdicts:
            emit(False, "decide", ["verify needs both the review `findings` and its own `verdicts`"],
                 {"stage": "verify"})
            return 1
        findings_path = os.path.join(tmp, "findings.md")
        verdicts_path = os.path.join(tmp, "verdicts.md")
        with open(findings_path, "w", encoding="utf-8") as fh:
            fh.write(review_doc["body"])
        with open(verdicts_path, "w", encoding="utf-8") as fh:
            fh.write(verdicts["body"])
        check_args = ["check-verdicts", "--findings", findings_path, "--verdicts", verdicts_path]
    else:  # gate
        pr = ledger.get("pr") or {}
        if not pr.get("number"):
            raise SetupError("no PR recorded in the ledger for the gate stage")
        check_args = ["check-gate", "--pr", "%s#%s" % (ledger["repo"], pr["number"]),
                      "--spec", spec_path]

    code, parsed, combined = _run_self(check_args)
    comment = check_comment(parsed, combined)
    passed = code == 0
    blocking = (parsed or {}).get("blockingConfirmed") or []

    decision = "approve" if passed else "request_changes"
    reasons = []
    if not passed:
        reasons = list((parsed or {}).get("reasons") or ["check exited %d" % code])

    # verify: a confirmed blocking finding opens a fix round, at most two.
    open_fix_round = stage == "verify" and passed and blocking and round_no < 2
    if stage == "verify" and passed and blocking and round_no >= 2:
        decision = "escalate"
        reasons = ["a third fix round would start; confirmed blocking: %s" % ", ".join(blocking)]

    attempts = int((ledger["stages"].get(key) or {}).get("attempts", 0))
    if decision == "request_changes":
        attempts += 1
        ledger["stages"].setdefault(key, {})["attempts"] = attempts
        if attempts >= 3:
            decision = "escalate"
            reasons = ["third request-changes on %s" % key]

    result = {
        "ok": passed and decision != "escalate",
        "check": "decide",
        "reasons": reasons,
        "stage": stage,
        "round": round_no,
        "decision": decision,
        "applied": bool(args.apply),
        "workOrder": work_order.get("identifier"),
    }

    if decision == "escalate":
        if args.apply:
            _escalate(api, work_order["id"], ledger, reasons[0] if reasons else "escalated",
                      stage_issue.get("identifier", "?"))
            api.patch_issue(stage_issue["id"], {"status": "blocked", "executionPolicy": None,
                                                "comment": "escalated: %s" % (reasons[0] if reasons else "")})
        emit(False, "decide", reasons, result)
        return 1

    if not args.apply:
        emit(passed, "decide", reasons, result)
        return 0 if passed else 1

    if decision == "request_changes":
        api.patch_issue(stage_issue["id"], {"status": "in_progress", "comment": comment})
        save_ledger(api, work_order["id"], ledger, "request changes %s" % key)
        emit(False, "decide", reasons, result)
        return 1

    # approve
    if stage == "red":
        ccode, cparsed, cout = _run_self(["commit", "--repo", cwd, "--stage", "red",
                                          "--issue", work_order["identifier"]])
        if ccode != 0:
            raise SetupError("red commit refused: %s" % ((cparsed or {}).get("reasons")))
        ledger["stages"].setdefault(key, {"issueId": stage_issue["id"], "round": round_no,
                                          "attempts": 0})
        ledger["stages"][key]["sha"] = (cparsed or {}).get("sha")
        api.patch_issue(stage_issue["id"], {"status": "done", "comment": comment})
    elif stage == "green":
        ccode, cparsed, cout = _run_self(["commit", "--repo", cwd, "--stage", "green",
                                          "--issue", work_order["identifier"]])
        if ccode != 0:
            raise SetupError("green commit refused: %s" % ((cparsed or {}).get("reasons")))
        ledger["stages"].setdefault(key, {"issueId": stage_issue["id"], "round": round_no,
                                          "attempts": 0})
        ledger["stages"][key]["sha"] = (cparsed or {}).get("sha")
        existing_pr = ledger.get("pr") or {}
        if existing_pr.get("number"):
            # a decide re-run must not open a second PR for the same branch
            pass
        else:
            pcode, pparsed, pout = _run_self(["open-pr", "--repo", cwd,
                                              "--issue", work_order["identifier"],
                                              "--title", "factory(%s): %s" % (
                                                  work_order["identifier"], work_order.get("title", "")[:100])])
            if pcode != 0:
                raise SetupError("open-pr refused: %s" % ((pparsed or {}).get("reasons")))
            url = (pparsed or {}).get("url")
            number = None
            match = re.search(r"/pull/([0-9]+)", url or "")
            if match:
                number = int(match.group(1))
            ledger["pr"] = {"number": number, "url": url}
            api.create_work_product(work_order["id"], {
                "type": "pull_request", "provider": "github",
                "title": "PR for %s" % work_order["identifier"],
                "url": url, "externalId": str(number) if number else None,
                "status": "ready_for_review", "isPrimary": True,
                "reviewState": "needs_board_review",
            })
        api.patch_issue(stage_issue["id"], {"status": "done", "comment": comment})
    elif stage == "review":
        api.patch_issue(stage_issue["id"], {"status": "done", "comment": comment})
    elif stage == "verify":
        api.patch_issue(stage_issue["id"], {"status": "done", "comment": comment})
        if open_fix_round:
            ledger["fixRounds"] = int(ledger.get("fixRounds", 0)) + 1
            findings_block = ("\n**Confirmed blocking findings from verify (fix these, round %d):**\n%s\n"
                              % (round_no + 1, "\n".join("- %s" % b for b in blocking)))
            spec, spec_reasons = extract_json_block(spec_doc["body"], "spec")
            if spec is None:
                raise SetupError("spec document does not parse: %s" % "; ".join(spec_reasons))
            plan = plan_stages(cfg, spec, ledger, work_order, round_no + 1, findings_block)
            created = create_stages(api, work_order["id"], plan, cfg)
            for item in created:
                ledger["stages"][item["key"]] = {
                    "issueId": item["issue"]["id"], "identifier": item["issue"].get("identifier"),
                    "round": item["round"], "attempts": 0, "sha": None,
                }
            api.comment(work_order["id"], "fix round %d opened: %s"
                        % (round_no + 1, ", ".join(i["issue"].get("identifier", "?") for i in created)))
    else:  # gate
        api.patch_issue(stage_issue["id"], {"status": "done", "comment": comment})
        pr = ledger.get("pr") or {}
        api.create_interaction(work_order["id"], {
            "kind": "request_confirmation",
            "resolverPolicy": "human_only",
            "title": "Merge PR #%s?" % pr.get("number"),
            "summary": "The factory gate passed. Wojtek merges.",
            "payload": {"version": 1, "prompt": "Merge PR #%s?" % pr.get("number"),
                        "detailsMarkdown": pr.get("url") or ""},
        })
        api.patch_issue(work_order["id"], {"status": "in_review"})

    ledger["outcome"] = "pass"
    save_ledger(api, work_order["id"], ledger, "approve %s" % key)
    emit(True, "decide", [], result)
    return 0


def _now_iso() -> str:
    import datetime
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def _age_hours(stamp: str) -> float:
    import datetime
    try:
        then = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return 0.0
    delta = datetime.datetime.now(datetime.timezone.utc) - then
    return round(delta.total_seconds() / 3600.0, 1)


def cmd_factory_tick(args) -> int:
    _sys_path_for_modules()
    import pc

    try:
        api = pc.Api()
    except LookupError as exc:
        sys.stderr.write("factory tick: %s\n" % exc)
        return 2
    company = os.environ.get("PAPERCLIP_COMPANY_ID") or args.company
    cfg = load_agent_config()
    stop = os.path.exists(_stop_file())

    lines = []
    rows = []
    for item in api.issues(company):
        if item.get("status") not in OPEN_STATUSES:
            continue
        if item.get("assigneeAgentId") != cfg["majster"]:
            continue
        if not api.document(item["id"], "spec"):
            continue
        ledger = load_json_document(api, item["id"], "ledger") or {}
        stages = ledger.get("stages") or {}
        current_key, current = None, None
        order = list(stages.keys())
        for key in reversed(order):
            entry = stages[key]
            child = api.issue(entry["issueId"]) if entry.get("issueId") else None
            if child and child.get("status") not in ("done", "cancelled"):
                current_key, current = key, child
                break
        if current is None and order:
            entry = stages[order[-1]]
            current_key = order[-1]
            current = api.issue(entry["issueId"]) if entry.get("issueId") else None
        flags = []
        agent_name = "-"
        model = "-"
        age = 0.0
        runs = None
        if current:
            age = _age_hours(current.get("updatedAt") or current.get("createdAt") or "")
            agent_id = current.get("assigneeAgentId")
            if agent_id:
                try:
                    agent = api.agent(agent_id)
                    agent_name = agent.get("name") or agent_id[:8]
                    model = (agent.get("adapterConfig") or {}).get("model") or "-"
                except Exception:  # noqa: BLE001
                    agent_name = agent_id[:8]
            runs = api.runs(current["id"])
            if runs is None:
                flags.append("runs-unknown")
            else:
                if not runs:
                    flags.append("no-run")
                if age > 2:
                    flags.append("idle>2h")
            if current.get("activeRecoveryAction") or current.get("executionBlocker"):
                flags.append("recovery-hold")
        if stop:
            flags.append("STOP")
        attempts = 0
        if current_key and stages.get(current_key):
            attempts = int(stages[current_key].get("attempts", 0))
        lines.append("%s  %-12s %-10s age %5.1fh rounds %d%s"
                     % (item.get("identifier"), current_key or "-", agent_name, age, attempts,
                        ("  [" + ",".join(flags) + "]") if flags else ""))
        rows.append({
            "time": _now_iso(),
            "workOrder": item.get("identifier"),
            "stage": current_key,
            "agent": agent_name,
            "model": model,
            "outcome": ledger.get("outcome") or "pending",
            "round": (stages.get(current_key) or {}).get("round", 1) if current_key else 0,
            "durationSec": int(age * 3600),
        })
        if runs:
            usage = None
            for run in runs:
                for candidate in ("usage", "tokenUsage", "tokens"):
                    if isinstance(run.get(candidate), dict):
                        usage = run[candidate]
                        break
                if usage:
                    break
            if usage:
                rows[-1]["tokens"] = usage

    # config drift: every factory agent must carry the guard extension and its role.
    # An entry with `factoryRole: null` runs without the guard (phase 2: Majster's
    # gate stage has no extraArgs and `readonly` would refuse `decide`), so it is
    # reported as "not required" rather than as drift on every sweep (GUL-481).
    drift = []
    seen = set()
    for stage in STAGE_ORDER:
        agent = stage_agent(cfg, stage)
        agent_id = agent["agentId"]
        if agent_id in seen:
            continue
        seen.add(agent_id)
        if not agent.get("factoryRole"):
            drift.append({"agent": agent.get("name", stage), "guard": "not required",
                          "expectedRole": None})
            continue
        try:
            live = api.agent(agent_id)
        except Exception as exc:  # noqa: BLE001
            drift.append({"agent": agent.get("name", stage), "error": str(exc)[:120]})
            continue
        extra = ((live.get("adapterConfig") or {}).get("extraArgs")) or []
        has_extension = cfg.get("extension") in extra
        has_role = False
        for i, arg in enumerate(extra):
            if arg == "--factory-role" and i + 1 < len(extra) and extra[i + 1] == agent.get("factoryRole"):
                has_role = True
        entry = {"agent": live.get("name") or agent.get("name", stage),
                 "extension": has_extension, "role": has_role,
                 "expectedRole": agent.get("factoryRole")}
        drift.append(entry)

    try:
        os.makedirs(os.path.dirname(_ledger_jsonl()), exist_ok=True)
        with open(_ledger_jsonl(), "a", encoding="utf-8") as fh:
            for row in rows:
                fh.write(json.dumps(row, ensure_ascii=False) + "\n")
    except OSError as exc:
        sys.stderr.write("factory tick: cannot append ledger.jsonl: %s\n" % exc)

    emit(True, "tick", lines, {"workOrders": rows, "configDrift": drift, "stop": stop})
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="factory.py",
                               description="Deterministic factory stage checks (agents/factory/CONTRACT.md)")
    sub = p.add_subparsers(dest="command", required=True)

    s = sub.add_parser("lint-spec")
    s.add_argument("--spec", required=True)
    s.set_defaults(fn=cmd_lint_spec)

    s = sub.add_parser("check-red")
    s.add_argument("--repo", required=True)
    s.add_argument("--base", required=True)
    s.add_argument("--spec", required=True)
    s.set_defaults(fn=cmd_check_red)

    s = sub.add_parser("check-green")
    s.add_argument("--repo", required=True)
    s.add_argument("--red", required=True)
    s.add_argument("--spec", required=True)
    s.set_defaults(fn=cmd_check_green)

    s = sub.add_parser("check-findings")
    s.add_argument("--repo", required=True)
    s.add_argument("--base", required=True)
    s.add_argument("--findings", required=True)
    s.set_defaults(fn=cmd_check_findings)

    s = sub.add_parser("check-verdicts")
    s.add_argument("--findings", required=True)
    s.add_argument("--verdicts", required=True)
    s.set_defaults(fn=cmd_check_verdicts)

    s = sub.add_parser("check-gate")
    s.add_argument("--pr", required=True, help="OWNER/REPO#N")
    s.add_argument("--spec", required=True)
    s.set_defaults(fn=cmd_check_gate)

    s = sub.add_parser("commit")
    s.add_argument("--repo", required=True)
    s.add_argument("--stage", required=True, choices=["red", "green"])
    s.add_argument("--issue", required=True)
    s.set_defaults(fn=cmd_commit)

    s = sub.add_parser("open-pr")
    s.add_argument("--repo", required=True)
    s.add_argument("--issue", required=True)
    s.add_argument("--title", required=True)
    s.set_defaults(fn=cmd_open_pr)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--company", default=os.environ.get("PAPERCLIP_COMPANY_ID", ""),
                        help="company id (default: PAPERCLIP_COMPANY_ID)")

    s = sub.add_parser("start", parents=[common])
    s.add_argument("work_order", help="work order identifier, e.g. GUL-439")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--repo", help="override the checkout directory")
    s.set_defaults(fn=cmd_factory_start)

    s = sub.add_parser("decide", parents=[common])
    s.add_argument("stage_issue", help="stage issue identifier, e.g. GUL-441")
    s.add_argument("--apply", action="store_true", help="make the Paperclip PATCH")
    s.set_defaults(fn=cmd_factory_decide)

    s = sub.add_parser("tick", parents=[common])
    s.set_defaults(fn=cmd_factory_tick)
    return p


def main(argv: list) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.fn(args)
    except SetupError as e:
        name = getattr(args, "command", "?")
        emit(False, name, ["setup error: %s" % e])
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
