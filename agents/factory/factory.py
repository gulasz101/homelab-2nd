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
