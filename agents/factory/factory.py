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
# The checkout this script runs from: agents/factory/../../ = the repo root.
# check-gate needs it for the one check that reads git objects and the cluster
# (scripts/helmrelease-pin-vs-cluster.sh). FACTORY_GATE_REPO overrides it so the
# self-test can point that check at a fixture instead of the real repo.
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))

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

# GUL-853: a check that cannot print an `AC-<n>: PASS|FAIL` line is a work order
# that can never pass the red stage, whatever the Tester writes — `check-red`
# answers "setup error: no AC line for AC-n" three rounds running and the whole
# work order escalates. Bash is Turing-complete, so lint cannot prove that a
# command reports; it can reject the shapes that are *structurally* unable to:
# a command that never mentions its own AC ids, and one that is not a
# delegation to a script that might print them. Everything else is decided by
# running the check (check-red is the proof), as point 2 says.
_SCRIPT_CHECK = re.compile(
    r"^(?:bash|sh|dash|zsh|python3?|node|deno|bun|tsx)\s+"
    r"(?:-[A-Za-z-]+(?:[ =][^\s]+)?\s+)*"          # runner flags, e.g. -I, --yes
    r"[\w./@%+-]+\.(?:sh|bash|py|js|mjs|cjs|ts|mts)\b"
)


def _check_reports(cmd: str, aid: str) -> bool:
    """The command mentions the AC id it has to report: `echo "AC-1: FAIL x"`."""
    return re.search(r"(?<![\w-])%s:(?!\w)" % re.escape(aid), cmd) is not None


def _silent_check_reason(aid: str, cmd: str) -> str:
    return (
        "%s: check %r can never print an AC line: name the id in the command "
        "(sh -c 'if <test>; then echo \"%s: PASS\"; else echo \"%s: FAIL <reason>\"; "
        "exit 1; fi') or delegate to a script that prints it (bash path/to/check.sh). "
        "Use the if/else form, not `test && echo PASS || echo FAIL`: that one exits 0 "
        "after printing FAIL, which check-red reads as a setup error. A check that only "
        "runs `test`, `grep` or a validator is a setup error in every stage and the red "
        "stage can never pass it (GUL-853)"
        % (aid, cmd, aid, aid)
    )


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
        elif (is_lint and isinstance(aid, str) and re.match(r"^AC-[1-9][0-9]*$", aid)
              and not (_check_reports(chk, aid) or _SCRIPT_CHECK.match(chk.strip()))):
            reasons.append(_silent_check_reason(aid, chk))
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
# merge watch (GUL-553): the gate raises no card; the tick reads the PR
# --------------------------------------------------------------------------

MERGE_MONITOR_HOURS = 1
MERGE_MONITOR_ATTEMPTS = 72  # one tick an hour: three days of patience


def monitor_payload(pr: dict, hours: int = MERGE_MONITOR_HOURS) -> dict:
    """The issue monitor that makes `in_review` a real wait after the gate.

    Paperclip only accepts `kind: external_service`, and it redacts
    `externalRef` before storing it, so the PR number rides in `notes` and the
    clickable link is the `pull_request` work product from the green stage.

    `nextCheckAt` is validated by the live API against
    `...T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$` — an ISO `+00:00` offset is a 422,
    so the stamp is formatted by hand rather than by `datetime.isoformat()`.
    """
    import datetime
    next_check = (datetime.datetime.now(datetime.timezone.utc)
                  + datetime.timedelta(hours=hours))
    return {
        "kind": "external_service",
        "serviceName": "github pull request",
        "externalRef": pr.get("url") or "PR #%s" % pr.get("number"),
        "nextCheckAt": next_check.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "maxAttempts": MERGE_MONITOR_ATTEMPTS,
        "notes": "waiting for the merge of PR #%s on github" % pr.get("number"),
    }


def pr_merge_view(repo: str, number) -> dict:
    """`gh pr view <n> --json state,mergedAt,mergeCommit`: the merge is the signal."""
    view = gh_json(["pr", "view", str(number), "--repo", repo,
                    "--json", "state,mergedAt,mergeCommit"])
    if not isinstance(view, dict):
        raise SetupError("gh pr view %s returned no object" % number)
    return view


def withdraw_merge_cards(api, work_order_id: str) -> int:
    """Withdraw leftover "Merge PR #N?" cards (GUL-553).

    The gate no longer raises one, so this only cleans up cards left by a run
    from before the change, or by a decide that was interrupted mid-flight.
    """
    import pc
    try:
        cards = api.interactions(work_order_id)
    except pc.ApiError:
        return 0
    withdrawn = 0
    for card in cards or []:
        if card.get("status") != "pending":
            continue
        payload = card.get("payload") or {}
        if card.get("kind") != "request_confirmation":
            continue
        title = str(card.get("title") or payload.get("title") or "")
        prompt = str(payload.get("prompt") or "")
        if not (title.startswith("Merge PR") or prompt.startswith("Merge PR")):
            continue
        try:
            api.withdraw_interaction(work_order_id, card["id"],
                                     "the factory now reads the merge from github")
            withdrawn += 1
        except pc.ApiError:
            continue
    return withdrawn


def settle_merge(api, work_order: dict, ledger: dict, pr: dict, view: dict,
                 apply: bool) -> str:
    """Move a work order on after a merge, or say why it cannot. Returns the
    merge state it saw: `merged`, `closed` or `open`."""
    number = pr.get("number")
    state = str(view.get("state") or "").upper()
    merged_at = view.get("mergedAt")
    commit = ((view.get("mergeCommit") or {}) or {}).get("oid")

    if state == "MERGED":
        if not apply:
            return "merged"
        withdrawn = withdraw_merge_cards(api, work_order["id"])
        ledger["merge"] = {"state": "merged", "sha": commit, "at": merged_at}
        ledger["outcome"] = "merged"
        save_ledger(api, work_order["id"], ledger, "merged PR #%s" % number)
        note = ""
        if withdrawn:
            note = " %d leftover merge card(s) withdrawn." % withdrawn
        api.patch_issue(work_order["id"], {
            "status": "done", "executionPolicy": None,
            "comment": ("PR #%s is merged in `%s` (%s). No card: the factory read "
                        "the merge on GitHub and moved this work order on.%s"
                        % (number, commit or "?", merged_at or "?", note)),
        })
        return "merged"

    if state == "CLOSED":
        if not apply:
            return "closed"
        ledger["merge"] = {"state": "closed", "sha": None, "at": None}
        ledger["outcome"] = "closed"
        save_ledger(api, work_order["id"], ledger, "PR #%s closed without a merge" % number)
        api.patch_issue(work_order["id"], {
            "status": "blocked", "executionPolicy": None,
            "unblockDescriptor": _unblock_descriptor(
                api, "PR #%s was closed unmerged: reopen it or start a new work order, then "
                     "clear this block; the factory owns this park." % number),
            "comment": ("PR #%s was closed without a merge, so nothing shipped. "
                        "Reopen it or start a new work order." % number),
        })
        return "closed"

    if apply:
        # still open: keep the wait a real path by re-arming the monitor
        api.patch_issue(work_order["id"], {"executionPolicy": {"monitor": monitor_payload(pr)}})
    return "open"


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


# --------------------------------------------------------------------------
# chart pin vs cluster (GUL-552, ADR-097)
#
# scripts/helmrelease-pin-vs-cluster.sh, not this file, owns the judgement: it
# diffs two refs, reads the live HelmReleases with kubectl and fails a pin that
# sits below the chart version the cluster is already running. Keeping it in
# bash means one implementation for the gate and for a human running the same
# check by hand on an ordinary PR.
# --------------------------------------------------------------------------

PIN_CHECK = os.path.join("scripts", "helmrelease-pin-vs-cluster.sh")
PIN_HEAD_REF = "refs/factory/pr-%s"


def ref_sha(repo: str, ref: str) -> str:
    """Full sha of ref, or "" when it is not in this checkout."""
    return git(repo, "rev-parse", "--verify", "--quiet", ref + "^{commit}",
               allow_fail=True).strip()


def ensure_pin_refs(repo: str, pr_num: str, base_oid: str, head_oid: str) -> tuple:
    """Return (base_ref, head_ref) that both resolve in `repo`.

    The gate runs from the tooling checkout, which is force-moved to
    origin/main on every call (CONTRACT point 0), so the PR's commits are
    usually absent. Fetch the PR head into its own ref plus the base tip, then
    insist the head resolves to exactly the sha gh reported: a stale ref left
    behind by an earlier PR would otherwise diff the wrong thing and pass."""
    head_ref = PIN_HEAD_REF % pr_num
    git(repo, "fetch", "--quiet", "--no-tags", "origin",
        "+refs/pull/%s/head:%s" % (pr_num, head_ref), base_oid, allow_fail=True)
    if ref_sha(repo, head_ref) != head_oid:
        if ref_sha(repo, head_oid) == head_oid:
            head_ref = head_oid
        else:
            raise SetupError("PR head %s not in %s and could not be fetched"
                             % (head_oid[:12], repo))
    if ref_sha(repo, base_oid) != base_oid:
        raise SetupError("PR base %s not in %s and could not be fetched"
                         % (base_oid[:12], repo))
    return base_oid, head_ref


def pin_reasons(repo: str, pr_num: str, base_oid: str, head_oid: str) -> list:
    """Reasons from the pin-vs-cluster check: exit 1 gives one reason per FAIL
    line, exit 0 gives none, anything else is a setup error - a check that
    could not read the cluster must never pass a PR."""
    script = os.path.join(repo, PIN_CHECK)
    if not os.path.isfile(script):
        raise SetupError("check-gate needs %s (run from the repo checkout)" % PIN_CHECK)
    base_ref, head_ref = ensure_pin_refs(repo, pr_num, base_oid, head_oid)
    proc = subprocess.run(["bash", script, base_ref, head_ref], cwd=repo,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for line in proc.stdout.splitlines():
        sys.stderr.write("  pin-vs-cluster: %s\n" % line)
    if proc.returncode == 0:
        return []
    if proc.returncode == 1:
        fails = [l.strip() for l in proc.stdout.splitlines() if l.startswith("FAIL ")]
        if not fails:
            raise SetupError("pin-vs-cluster exited 1 without a FAIL line")
        return fails
    raise SetupError("pin-vs-cluster exited %d: %s"
                     % (proc.returncode,
                        (proc.stderr.strip() or proc.stdout.strip())[-300:]))


def touches_helmrelease(files: list, head_oid: str, text_for_path, globs: list) -> bool:
    """True when the PR changes a HelmRelease document. Deletions do not count
    (nothing left to pin), and neither do never-path globs: those already fail
    the gate, and their content is deliberately not fetched. Keeps the cluster
    check off PRs that never touch a release, and on every PR that does."""
    for entry in files:
        path = entry.get("path") or ""
        if not path.endswith((".yaml", ".yml")) or looks_like_test_path(path):
            continue
        if entry.get("changeType") == "DELETED" or glob_match(globs, path):
            continue
        try:
            text = text_for_path(path, head_oid) or ""
        except SetupError:
            # An unreadable changed YAML already fails the never-path loop
            # above; it cannot also be the release that needs the pin check.
            continue
        if re.search(r"^kind:[ \t]+HelmRelease[ \t]*(#.*)?$", text, re.MULTILINE):
            return True
    return False


def cmd_check_gate(args) -> int:
    spec = load_spec(args.spec)
    repo, num = parse_pr_ref(args.pr)
    view = gh_json(["pr", "view", num, "--repo", repo, "--json",
                    "headRefOid,baseRefOid,additions,deletions,files,mergeable"])
    reasons: list = []
    try:
        head_oid = view["headRefOid"]
        base_oid = view["baseRefOid"]
        additions = int(view["additions"])
        deletions = int(view["deletions"])
        files = view["files"]
    except (KeyError, TypeError, ValueError) as e:
        raise SetupError("gh pr view json missing field: %r" % e)
    try:
        checks = gh_json(["pr", "checks", num, "--repo", repo, "--json", "name,state"])
    except SetupError as e:
        # `gh pr checks` exits 1 with "no checks reported" when the branch has no
        # run yet (a fresh PR, or a CONFLICTING one GitHub never built a merge ref
        # for). That is a state of the PR the gate judges, not a broken tool
        # (GUL-1155): judge it as "no green check" so the stage gets a real answer
        # instead of a protocol error.
        if "no checks reported" not in str(e):
            raise
        checks = []
    named = [c for c in checks if isinstance(c, dict) and c.get("name") == "check"]
    if not named:
        reasons.append("no check run named 'check' on this PR")
        if isinstance(view, dict) and str(view.get("mergeable") or "").upper() == "CONFLICTING":
            reasons.append("PR is CONFLICTING with its base, so GitHub never builds the "
                           "merge ref and the check workflow cannot start: rebase the branch")
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
    # ADR-097: a pin is a floor too. Any PR that touches a HelmRelease has to
    # pass the cluster comparison before the gate can pass (GUL-552).
    gate_repo = os.environ.get("FACTORY_GATE_REPO") or REPO_ROOT
    if touches_helmrelease(files, head_oid, pr_content_text, cfg["globs"]):
        reasons.extend(pin_reasons(gate_repo, num, base_oid, head_oid))
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


def cmd_push(args) -> int:
    """Push the checkout's branch to origin (GUL-1267 F-1).

    A fix round commits on the same branch the first green stage opened its PR
    from, so the PR head is only the round's work once that commit is pushed.
    Round 1 opened the PR *and* pushed; a later round reuses the PR and must
    still push, or the gate reads the round-1 head and offers to merge it.
    """
    if not re.match(r"^GUL-[0-9]+$", args.issue):
        raise SetupError("--issue must be GUL-<n>, got %r" % args.issue)
    branch = git(args.repo, "rev-parse", "--abbrev-ref", "HEAD").strip()
    if branch in ("main", "master"):
        emit(False, "push", ["refusing to push %s" % branch])
        return 1
    git(args.repo, "push", "-u", "origin", branch)
    emit(True, "push", [], {"branch": branch,
                            "sha": git(args.repo, "rev-parse", "HEAD").strip()})
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


def repo_slug(value) -> str:
    """`gulasz101/homelab-2nd` from a spec's repo field or any clone URL."""
    text = str(value or "").strip().rstrip("/")
    if text.endswith(".git"):
        text = text[:-4]
    for marker in ("github.com/", "github.com:"):
        if marker in text:
            text = text.split(marker, 1)[1]
    parts = [part for part in text.strip("/").split("/") if part]
    return "/".join(parts[-2:]).lower() if len(parts) >= 2 else ""


def _workspace_slug(workspace) -> str:
    return repo_slug(workspace.get("repoUrl") or workspace.get("repo") or "") if isinstance(workspace, dict) else ""


def _workspace_cwd(workspace) -> str:
    return (workspace.get("cwd") or "") if isinstance(workspace, dict) else ""


def _project_workspaces(api, project_id) -> list:
    if not project_id:
        return []
    try:
        return [ws for ws in (api.project_workspaces(project_id) or []) if isinstance(ws, dict)]
    except Exception:  # noqa: BLE001 - a missing project must not hide the fallback
        return []


def _company_workspaces(api, company_id) -> list:
    """Every workspace in the company, flattened. One API call per project, so
    only the repo-lookup path pays for it."""
    found = []
    try:
        projects = api.projects(company_id) or []
    except Exception:  # noqa: BLE001 - no project list means no cross-project lookup
        return found
    if isinstance(projects, dict):
        projects = projects.get("projects") or []
    for project in projects:
        if isinstance(project, dict):
            found.extend(_project_workspaces(api, project.get("id")))
    return found


def work_order_cwd(api, issue: dict, repo: str = "", company_id: str = "") -> tuple:
    """`(cwd, note)`: the checkout this work order runs in.

    The spec names the repo the work order changes. The issue's project names a
    checkout. They can disagree: three Image Studio work orders asked for
    `gulasz101/homelab-2nd`, their project checks out `ideogram4-local`, and the
    factory cut branches in the wrong tree (GUL-1389). So the repo decides.

    - A workspace whose own repo (or, with no `repoUrl`, whose name) is the spec's
      repo is the answer, project first.
    - Otherwise the checkout is looked up across the company's workspaces, because
      a repo can be checked out by another project.
    - A project checkout that provably holds a *different* repo is not used, and
      the answer is refused rather than guessed: a wrong tree produces an empty
      `red` stage and a fake pass, which is what GUL-1340 did.
    - Two checkouts of the same repo are refused too. One checkout, one diff
      (ADR-095), and two work orders must not cut branches in one tree.
    """
    want = repo_slug(repo)
    own = _project_workspaces(api, issue.get("projectId"))
    execution = issue.get("currentExecutionWorkspace")
    ordered = ([execution] if isinstance(execution, dict) else []) + own

    def holds(workspace) -> bool:
        slug = _workspace_slug(workspace)
        if slug:
            return slug == want
        return bool(want) and repo_slug(workspace.get("name")) == want

    for workspace in ordered:
        if _workspace_cwd(workspace) and holds(workspace):
            return _workspace_cwd(workspace), "issue workspace holds %s" % want

    if not want:
        for workspace in ordered:
            if _workspace_cwd(workspace) and workspace.get("isPrimary"):
                return _workspace_cwd(workspace), "project workspace (spec names no repo)"
        return (os.environ.get("FACTORY_REPO")
                or os.path.abspath(os.path.join(FACTORY_DIR, "..", ".."))), "FACTORY_REPO"

    factory_root = os.path.realpath(os.path.abspath(os.path.join(FACTORY_DIR, "..", "..")))
    checkouts, seen = [], set()
    for workspace in own + _company_workspaces(api, company_id):
        cwd = _workspace_cwd(workspace)
        if not cwd or not holds(workspace):
            continue
        real = os.path.realpath(cwd)
        if real in seen or real == factory_root:
            continue
        seen.add(real)
        checkouts.append(real)
    if len(checkouts) == 1:
        return checkouts[0], "company workspace holds %s" % want
    if len(checkouts) > 1:
        raise SetupError(
            "%s spec names repo %s and %d checkouts hold it (%s); pass --repo to pick one, "
            "because two work orders in one checkout cut branches in the same tree"
            % (issue.get("identifier") or issue.get("id"), want, len(checkouts), ", ".join(checkouts)))

    known_wrong = sorted({_workspace_slug(ws) or _workspace_cwd(ws) for ws in own
                          if _workspace_cwd(ws) and _workspace_slug(ws)})
    if known_wrong:
        raise SetupError(
            "%s spec names repo %s but its project checks out %s and no workspace in this "
            "company holds %s: move the issue to the project that checks it out, or pass --repo"
            % (issue.get("identifier") or issue.get("id"), want, ", ".join(known_wrong), want))

    for workspace in own:
        if _workspace_cwd(workspace):
            return _workspace_cwd(workspace), "project workspace (repo %s unverified)" % want
    return (os.environ.get("FACTORY_REPO")
            or os.path.abspath(os.path.join(FACTORY_DIR, "..", ".."))), "FACTORY_REPO"


def open_work_orders(api, company_id: str, cfg: dict, exclude_id: str, project_id,
                     cwd: str = "") -> list:
    """Every other open issue assigned to Majster that carries a `spec` document and
    would fight this one for a checkout: same project, or another project pointed at
    the same `cwd` (`cwd` is what the ledger records, so it is what is compared).

    Document check is per issue: the company list does not include document
    summaries.

    A work order parked as `blocked` before it ever started holds no branch and no
    checkout: the shared checkout is only taken by `start`, and `start` is what
    writes the ledger (GUL-951). Counting such a work order as "open" deadlocks the
    project it waits on — 948 waits for 875, so 875 cannot start because 948 is
    "open", and 948 cannot start because 875 is not done. A blocked work order that
    has already started still counts: its diff may be the one in the checkout.
    """
    wanted_cwd = os.path.realpath(cwd) if cwd else ""
    found = []
    for item in api.issues(company_id):
        if item.get("id") == exclude_id:
            continue
        if item.get("status") not in OPEN_STATUSES:
            continue
        if item.get("assigneeAgentId") != cfg["majster"]:
            continue
        same_project = bool(project_id) and item.get("projectId") == project_id
        if not same_project and not wanted_cwd:
            continue
        if item.get("status") == "blocked" and not api.document(item["id"], "ledger"):
            continue
        if not same_project:
            ledger = load_json_document(api, item["id"], "ledger") or {}
            other = ledger.get("cwd") if isinstance(ledger, dict) else ""
            if not other or os.path.realpath(other) != wanted_cwd:
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
    # GUL-1267 G2: a fix round ends in a gate of its own. Without one, a clean
    # verify r2 approved the chain on the *round-1* gate, which had already
    # decided the head the fix round rewrote — nobody re-ran `check-gate`.
    plan = []
    order = STAGE_ORDER if round_no == 1 else ("green", "review", "verify", "gate")
    for stage in order:
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


def settle_stage_descriptions(api, cfg: dict, spec: dict, ledger: dict, work_order: dict,
                              round_no: int, findings_block: str, plan: list,
                              created: list) -> list:
    """Render the stage descriptions a second time, now that every id exists (GUL-989).

    `plan_stages` runs before the stage issues are created, so a description that
    names *another* stage can only carry a placeholder: at `start` time the ledger
    has no `review` entry yet, so the verify description shipped
    "The review stage is issue `?`" into the issue forever and the Verifier spent
    its turns hunting for it (40-turn cap, no `verdicts`, GUL-965).

    Everything the templates need is known the moment `create_stages` returns, so
    render again and patch what changed, before any agent is woken. Returns the
    stage keys whose description was rewritten.

    Only untouched stages are patched: a stage an agent is already working must
    never have its instructions changed under it.
    """
    settled = plan_stages(cfg, spec, ledger, work_order, round_no, findings_block)
    before = {item["key"]: item["description"] for item in plan}
    by_key = {item["key"]: item for item in created}
    patched = []
    for item in settled:
        target = by_key.get(item["key"])
        if target is None or item["description"] == before.get(item["key"]):
            continue
        issue = target["issue"]
        if issue.get("status") not in ("todo", "blocked"):
            continue
        api.patch_issue(issue["id"], {"description": item["description"]})
        patched.append(item["key"])
        if item["key"] == stage_key("review", round_no):
            target["issue"]["identifier"] = issue.get("identifier")

    # The one link the whole verify round rests on: if the review identifier did
    # not make it in, fail loudly here rather than hand a Verifier a description
    # that names an issue it cannot read.
    verify_key = stage_key("verify", round_no)
    verify_item = next((i for i in settled if i["key"] == verify_key), None)
    review_item = next((i for i in created if i["key"] == stage_key("review", round_no)), None)
    if verify_item is not None and review_item is not None:
        identifier = (review_item["issue"].get("identifier") or "")
        if identifier and identifier not in verify_item["description"]:
            raise SetupError(
                "the verify description does not name the review issue %s; refusing to "
                "start a verify round that cannot find its findings document"
                % identifier)
    return patched


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


def _review_line(text: str) -> str:
    for line in (text or "").splitlines():
        if "review stage is issue" in line:
            return line.strip()
    return ""


def _current_round(ledger: dict) -> int:
    rounds = [int(key.split(":r")[1]) for key in (ledger.get("stages") or {})
              if ":r" in key and key.split(":r")[1].isdigit()]
    return max(rounds) if rounds else 1


def _live_run(api, issue_id):
    """True when the issue has a run that is still going (or queued to start).

    A factory stage can sit `in_progress` with nothing actually running: the last
    run ended without a verdict, so the status is stale. The run rows are the
    honest test of "is an agent working this right now" (GUL-989).
    """
    try:
        payload = api.runs(issue_id)
    except Exception:  # noqa: BLE001 - an unreadable run list must not block a repair
        return False
    items = payload if isinstance(payload, list) else (
        payload.get("runs") or payload.get("data") or []) if isinstance(payload, dict) else []
    for run in items:
        if str(run.get("status") or "") in ("running", "queued", "pending", "starting"):
            return True
    return False


def cmd_factory_settle(args) -> int:
    """Rewrite the verify description of a started work order from its ledger (GUL-989).

    `start` settles the descriptions the moment the stage identifiers exist, so a
    fresh work order is fine. A work order started before that fix still carries a
    literal `?` where the review issue id belongs, and a Verifier woken on it burns
    its turns hunting for a stage it cannot identify. The ledger is the only place
    the review identifier is stored, so re-render from it here.

    Only the verify stage is rewritten: the others were complete at create time,
    and a round-2 fix description embeds findings this command cannot rebuild.
    """
    _sys_path_for_modules()
    import pc

    try:
        api = pc.Api()
    except LookupError as exc:
        sys.stderr.write("factory settle: %s\n" % exc)
        return 2
    company = os.environ.get("PAPERCLIP_COMPANY_ID") or args.company
    cfg = load_agent_config()

    issue_arg = resolve_issue(api, company, args.work_order)
    work_order = issue_arg
    spec_doc = api.document(work_order["id"], "spec")
    if (not spec_doc or not spec_doc.get("body")) and issue_arg.get("parentId"):
        # An operator naturally names the stage that carries the broken text
        # (GUL-965), not the work order. Walk up once rather than refusing.
        work_order = api.issue(issue_arg["parentId"])
        spec_doc = api.document(work_order["id"], "spec")
    if not spec_doc or not spec_doc.get("body"):
        raise SetupError("%s has no `spec` document" % args.work_order)
    spec, spec_reasons = extract_json_block(spec_doc["body"], "spec")
    if spec is None:
        raise SetupError("spec document does not parse: %s" % "; ".join(spec_reasons))
    ledger = load_json_document(api, work_order["id"], "ledger")
    if not ledger or not ledger.get("stages"):
        raise SetupError("%s has no factory ledger: nothing was started" % args.work_order)

    round_no = args.round or _current_round(ledger)
    key = stage_key("verify", round_no)
    verify = ledger["stages"].get(key)
    review = ledger["stages"].get(stage_key("review", round_no))
    if not verify:
        raise SetupError("round %d has no verify stage in the ledger" % round_no)
    if not review:
        raise SetupError("round %d has no review stage in the ledger" % round_no)

    plan = plan_stages(cfg, spec, ledger, work_order, round_no, "")
    item = next((i for i in plan if i["key"] == key), None)
    if item is None:
        raise SetupError("the plan has no verify stage for round %d" % round_no)

    identifier = review.get("identifier") or ""
    if identifier and identifier not in item["description"]:
        raise SetupError(
            "the rendered verify description does not name %s: refusing to write a "
            "description a Verifier cannot follow" % identifier)

    issue = api.issue(verify["issueId"])
    live = _live_run(api, verify["issueId"])
    if (issue.get("status") not in ("todo", "blocked") or live) and not args.force:
        raise SetupError(
            "%s is %r%s: an agent may already be working it, so its instructions are "
            "no longer ours to rewrite (pass --force if the stage is stuck)"
            % (verify.get("identifier"), issue.get("status"),
               " with a live run" if live else ""))

    before = issue.get("description") or ""
    changed = before != item["description"]
    applied = False
    if changed and args.apply:
        api.patch_issue(verify["issueId"], {"description": item["description"]})
        api.comment(work_order["id"],
                    "factory settle: %s now names the review issue `%s` (GUL-989)."
                    % (verify.get("identifier"), identifier))
        issue = api.issue(verify["issueId"])
        applied = identifier in (issue.get("description") or "")
        if not applied:
            raise SetupError("%s still does not name %s after the PATCH"
                             % (verify.get("identifier"), identifier))
    emit(True, "settle",
         [] if changed else ["%s already names %s" % (verify.get("identifier"), identifier)],
         {"workOrder": (work_order or {}).get("identifier", args.work_order)
          if isinstance(work_order, dict) else args.work_order,
          "requested": args.work_order, "round": round_no,
          "verifyIssue": verify.get("identifier"), "reviewIssue": identifier,
          "applied": applied,
          "before": _review_line(before), "after": _review_line(item["description"])})
    return 0


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
    if not isinstance(work_order, dict):
        raise SetupError("%s did not resolve to an issue" % args.work_order)
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

    if args.repo:
        cwd, cwd_note = args.repo, "--repo"
    else:
        cwd, cwd_note = work_order_cwd(api, work_order, spec.get("repo") or "", company)
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
    busy = open_work_orders(api, company, cfg, work_order["id"], project_id, cwd)
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
        "cwdSource": cwd_note,
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
    # GUL-989: the ledger now holds every stage identifier, so render the
    # descriptions that name another stage a second time (verify → review).
    patched = settle_stage_descriptions(api, cfg, spec, ledger, work_order, 1, "",
                                        plan, created)
    review_ref = (ledger["stages"].get(stage_key("review", 1)) or {}).get("identifier")
    api.comment(work_order["id"],
                "factory start: 5 stage issues created, chained %s. Checkout `%s`, branch `%s`."
                % (" → ".join(i["issue"].get("identifier", "?") for i in created), cwd, ledger["branch"])
                + (" Verify names the review issue `%s`." % review_ref if review_ref else ""))
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


def _unblock_descriptor(api, action: str) -> dict:
    """A `blocked` write the server will actually store (GUL-898).

    Paperclip refuses `PATCH {"status": "blocked"}` when the issue is entering
    blocked from any other status unless it carries an unresolved blocker edge,
    a pending interaction/approval, or an `unblockDescriptor`
    (`server/src/routes/issues.ts`, "Entering blocked requires unresolved
    blockers, a pending interaction/approval, or unblockDescriptor"). The
    factory parks three things that have none of the first three: an escalated
    work order, an escalated stage issue, and a work order whose PR was closed
    unmerged. The fourth rule is the awkward one: an agent may only name
    ITSELF as the owner, so the owner is whoever's key is running this command,
    not the board and not the stage's assignee.
    """
    return {"owner": {"agentId": api.self_agent_id()}, "action": action}


def _escalate(api, work_order_id: str, ledger: dict, reason: str, identifier: str) -> None:
    ledger["outcome"] = "escalate"
    ledger["escalated"] = reason
    save_ledger(api, work_order_id, ledger, "escalate %s" % identifier)
    api.patch_issue(work_order_id, {
        "status": "blocked",
        "executionPolicy": None,
        "unblockDescriptor": _unblock_descriptor(
            api, "Wojtek decides on the escalated stage %s; then clear this block (or re-run "
                 "`factory decide %s --apply`) so the work order can move." % (identifier, identifier)),
        "comment": "factory escalate: %s — no more retries. Wojtek decides." % reason,
    })


# GUL-889: a stage issue that still carries a pending review stage cannot be
# written `blocked`, and the reason is Paperclip's stage resolution, not the echo
# check.
#
# `PATCH {"status": "blocked", "executionPolicy": null}` is resolved against the
# stage first: the issue is `in_review` and carries an executionState with a
# return assignee, so clearing the policy dissolves the review *back to that
# assignee* — the server sets `in_progress`, reassigns the stage agent, and
# overwrites the requested `blocked`. The echo check then raises, the stage never
# settles, its agent re-runs and hands it back, and the next wake escalates
# again: a loop that burns a run every few minutes on a decision already made.
# (Kept in `pc.patch_issue`: a status the server silently drops is a failed write,
# not a style issue.)
#
# A policy whose executionState stage no longer exists leaves the server nothing
# to dissolve: it clears executionState, keeps the requested `blocked`, and arms
# nobody.
#
# GUL-969: empty stages alone are *not* enough any more. The server normalises a
# policy with no stages and no monitor/reviewPreset/authorizationPolicy/maxReviewRounds
# to null, and a null policy on an `in_review` issue takes the *other* branch: it
# dissolves the review back to `returnAssignee` and overwrites the requested status
# with `in_progress` — which is what made the park 422 on `unblockDescriptor requires
# blocked status`. `maxReviewRounds` is not the answer either: paperclipai 2026.1012.0
# reads that field only in its zod schema, never in the normaliser, so a stage-less
# policy still collapses to null on the running server.
#
# So the park sends the stage's *own* stages with their ids stripped: the policy
# stays non-null, the live `executionState.currentStageId` no longer resolves, and
# the server takes the clear-the-state branch above — `executionState` cleared,
# requested `blocked` kept, nobody armed. The stage definition survives, so a
# re-arm starts from the same review rather than a redefined one.


def _park_policy(stage_issue: dict) -> dict:
    """The park's policy: this stage issue's own stages, re-identified (GUL-969).

    Stage ids are dropped on purpose — a fresh id is what makes the live
    `executionState` point at a stage that no longer exists, which is the branch
    that clears the state and keeps `blocked`. Participants and `approvalsNeeded`
    are kept so the stage still describes the review it came from.
    """
    policy = stage_issue.get("executionPolicy") or {}
    stages = []
    for stage in policy.get("stages") or []:
        participants = [p for p in (stage.get("participants") or []) if p]
        if not participants:
            continue
        kept = {"type": stage.get("type") or "review",
                "participants": participants,
                "approvalsNeeded": stage.get("approvalsNeeded", 1)}
        if stage.get("name"):
            kept["name"] = stage["name"]
        stages.append(kept)
    return {"mode": policy.get("mode") or "normal",
            "commentRequired": bool(policy.get("commentRequired", True)),
            "stages": stages}


def _block_stage_issue(api, stage_issue: dict, comment: str) -> None:
    """Park an escalated stage issue: `blocked`, no pending stage, no re-arm.

    GUL-898: `blocked` alone is not enough. The empty-stage policy fixes the
    stage *resolution* bug (GUL-889), but Paperclip answers the write one rule
    later — a blocked issue must say what would unblock it, or the whole PATCH
    is refused 422 and the stage stays `in_progress`. The factory has no
    blocker edge on a stage issue and raises no card here, so the park carries
    a self-owned descriptor: the agent running `factory decide` owns reopening
    it once the work order is decided.

    GUL-1128: `executionPolicy` goes on the wire only when the policy actually
    carries a participant-bearing stage. A stage whose policy has none — the
    common case for a stage that never named a reviewer — leaves `_park_policy`
    with `stages: []`, and paperclip 2026.1012.0 normalises that to null before
    it applies the write. A null policy on an `in_review` issue takes the
    dissolve branch: the server reads the PATCH as "moving to in_progress",
    reassigns the stage agent, and then refuses the whole write with
    `422 unblockDescriptor requires blocked status` — nothing recorded, stage
    still `in_review`. Omitting the key is not the same as sending null: with
    the policy untouched the server has no stage transition to resolve and
    stores the requested `blocked` as asked. `_park_policy` keeps returning the
    empty list; it just must never reach the wire.
    """
    identifier = stage_issue.get("identifier", "?")
    body = {
        "status": "blocked",
        "unblockDescriptor": _unblock_descriptor(
            api, "Re-run `factory decide %s --apply` once the factory tooling can park this "
                 "stage; that agent owns clearing this block." % identifier),
        "comment": comment,
    }
    policy = _park_policy(stage_issue)
    if policy["stages"]:
        body["executionPolicy"] = policy
    api.patch_issue(stage_issue["id"], body)


def _stage_document_missing(api, work_order: dict, ledger: dict, stage_issue: dict,
                           stage: str, reason: str, apply: bool) -> int:
    """GUL-868: a stage that never wrote its artefact is an escalation, not a quiet `ok: false`.

    `decide` used to `return 1` before any board write, so the stage parked with
    nobody told: no blocked, no comment, no wake, and the work order sat still
    until a human noticed by hand. A stage with no document is a stage nobody can
    judge, so apply mode escalates it exactly like a third failure and the reason
    says which artefact is missing.
    """
    result = {
        "ok": False,
        "check": "decide",
        "reasons": [reason],
        "stage": stage,
        "decision": "escalate",
        "applied": bool(apply),
        "workOrder": work_order.get("identifier"),
    }
    if apply:
        identifier = stage_issue.get("identifier", "?")
        # GUL-969: the escalation is two writes — the work order and the ledger,
        # then the park. When the park died on the 422 the engine was left
        # half-applied: escalate recorded, stage still `in_review`. Re-running it
        # must finish the missing write only; re-escalating would post a second
        # "Wojtek decides" comment and clear the work order's executionState.
        if ledger.get("outcome") != "escalate":
            _escalate(api, work_order["id"], ledger, reason, identifier)
        _block_stage_issue(api, stage_issue,
                           "escalated: %s — the stage produced no artefact, so there is nothing to "
                           "decide. This stage is parked, not returned to its agent: the work order "
                           "is blocked on Wojtek's decision. Re-arm it only after that." % reason)

    emit(False, "decide", [reason], result)
    return 1


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

    # GUL-889: an escalation that already landed must not be re-run. The loop
    # that followed the broken escalate write was driven by a wake that repeated
    # this decision; even with the write fixed, a second `decide --apply` on a
    # settled stage has nothing to decide and must not touch the board.
    if ledger.get("outcome") == "escalate" and \
            stage_issue.get("status") in ("blocked", "done", "cancelled"):
        reason = "already escalated: %s" % (ledger.get("escalated") or "see the ledger")
        emit(False, "decide", [reason], {
            "ok": False, "check": "decide", "reasons": [reason], "stage": stage,
            "round": round_no, "decision": "escalate", "applied": False,
            "workOrder": work_order.get("identifier"),
        })
        return 1

    cwd = ledger["cwd"]
    # GUL-949: `tick` reads the PR before settling a work order; `decide` never
    # did, so a verify stage opened a fix round (then escalated four times) on
    # a branch that had already merged — riff_radar #18, 3 Nov. The PR is read
    # before any stage is opened or any escalation is posted, with the same
    # call `settle_merge()` uses, and a merged or closed PR goes straight to
    # that settlement path instead of being decided again.
    pr = ledger.get("pr") or {}
    if pr.get("number"):
        settled = ledger.get("merge") or {}
        if settled.get("state"):
            reason = "already settled: PR #%s %s" % (pr["number"], settled["state"])
            emit(False, "decide", [reason], {
                "ok": False, "check": "decide", "reasons": [reason], "stage": stage,
                "round": round_no, "decision": settled["state"], "applied": False,
                "workOrder": work_order.get("identifier"),
            })
            return 1
        try:
            view = pr_merge_view(ledger.get("repo") or "", pr["number"])
        except SetupError as exc:
            # refusing beats deciding blind: a fix round on a merged PR costs a
            # day of confusion, and exit 2 leaves the stage untouched and re-runnable.
            raise SetupError("cannot read PR #%s state, refusing to decide: %s"
                             % (pr["number"], str(exc)[:200]))
        if str(view.get("state") or "").upper() in ("MERGED", "CLOSED"):
            merge_state = settle_merge(api, work_order, ledger, pr, view, bool(args.apply))
            reason = "PR #%s is %s: settled, no stage opened" % (pr["number"], merge_state)
            if args.apply:
                api.patch_issue(stage_issue["id"], {
                    "status": "cancelled",
                    "comment": ("cancelled: PR #%s is %s, so the work order moved on "
                                "without a decision on this stage (GUL-949)."
                                % (pr["number"], merge_state)),
                })
            result = {
                "ok": merge_state == "merged",
                "check": "decide",
                "reasons": [reason],
                "stage": stage,
                "round": round_no,
                "decision": merge_state,
                "applied": bool(args.apply),
                "merge": merge_state,
                "workOrder": work_order.get("identifier"),
            }
            emit(merge_state == "merged", "decide", [reason], result)
            return 0 if merge_state == "merged" else 1

    if stage == "gate":
        # GUL-1267 G1: a gate decides the whole chain, so it is superseded the
        # moment a later round opens — the head it would judge is the one the
        # fix round is rewriting. GUL-1199 merged PR #189 thirty-seven seconds
        # after verify round 1 opened round 2. Refuse as a setup error and write
        # nothing: this is not a verdict on the diff, and booking it as a failed
        # check would spend one of the three attempts the gate never got
        # (GUL-1155).
        later = open_later_round_stages(api, ledger, work_order, round_no)
        if later:
            rounds = ", ".join(str(r) for r in sorted({r for r, _k, _i in later}))
            opened = ", ".join("%s (%s) is %s" % (k, i.get("identifier") or "?", i.get("status"))
                               for _r, k, i in later)
            raise SetupError(
                "superseded: round %s is open (%s), so the gate for round %d decides no "
                "head; it decides once every stage of round %s is done or cancelled"
                % (rounds, opened, round_no, rounds))

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
            return _stage_document_missing(
                api, work_order, ledger, stage_issue, "review",
                "review issue %s has no `findings` document" % stage_issue.get("identifier", "?"),
                args.apply)
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
            missing = []
            if not review_doc:
                missing.append("review `findings`")
            if not verdicts:
                missing.append("own `verdicts`")
            return _stage_document_missing(
                api, work_order, ledger, stage_issue, "verify",
                "verify issue %s is missing its %s document"
                % (stage_issue.get("identifier", "?"), " and ".join(missing)),
                args.apply)
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
    if code not in (0, 1):
        # Exit 2 is this CLI's own protocol for "the check could not judge"
        # (SetupError). It is not a failed check: booking it as one spends a
        # round the stage never got, and three of them escalate the work order
        # with the wrong reason on a diff nobody has read (GUL-1155). Leave the
        # ledger and the stage exactly as they are and let the caller retry.
        reason = ((parsed or {}).get("reasons")
                  or ["%s exited %d without a decision" % (check_args[0], code)])[0]
        result = {
            "ok": False,
            "check": "decide",
            "reasons": [reason],
            "stage": stage,
            "round": round_no,
            "decision": "setup_error",
            "applied": False,
            "workOrder": work_order.get("identifier"),
        }
        emit(False, "decide", [reason], result)
        return 2
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
            reason = reasons[0] if reasons else "escalated"
            _escalate(api, work_order["id"], ledger, reason,
                      stage_issue.get("identifier", "?"))
            _block_stage_issue(api, stage_issue,
                               "escalated: %s — this stage is parked, not returned to its agent, "
                               "and it will not be decided again. The work order is blocked on "
                               "Wojtek's decision." % reason)
        emit(False, "decide", reasons, result)
        return 1

    if not args.apply:
        emit(passed, "decide", reasons, result)
        return 0 if passed else 1

    if decision == "request_changes":
        # ledger first here too: a lost attempts counter would let the same
        # stage past its third failure without escalating (GUL-497).
        save_ledger(api, work_order["id"], ledger, "request changes %s" % key)
        api.patch_issue(stage_issue["id"], {"status": "in_progress", "comment": comment})
        emit(False, "decide", reasons, result)
        return 1

    # approve — prepare the ledger, make it durable, and only then mark the
    # stage `done` (GUL-497). A stage patched `done` whose ledger write then
    # fails never runs again: the board looks fine, the ledger keeps
    # `sha: null`, and the next stage refuses with "no red commit recorded in
    # the ledger". So each branch below only *prepares* its ledger row; the
    # `done` PATCH and every side effect that is not the record itself (work
    # product, merge card, work-order status) come after `save_ledger`
    # returned. A failed write leaves the stage `in_progress` with its commit
    # already made, and the re-run is safe: `commit` hands back HEAD for this
    # stage (GUL-496) and a recorded `pr` is reused instead of opening a
    # second one (GUL-497).
    after_ledger: list = []
    if stage == "red":
        ccode, cparsed, cout = _run_self(["commit", "--repo", cwd, "--stage", "red",
                                          "--issue", work_order["identifier"]])
        if ccode != 0:
            raise SetupError("red commit refused: %s" % ((cparsed or {}).get("reasons")))
        ledger["stages"].setdefault(key, {"issueId": stage_issue["id"], "round": round_no,
                                          "attempts": 0})
        ledger["stages"][key]["sha"] = (cparsed or {}).get("sha")
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
            # a decide re-run must not open a second PR for the same branch, but
            # the commit still has to reach that PR's head (GUL-1267 F-1): a
            # green r2 that never pushed left the round-1 head on the PR, so
            # the gate passed round-1 code and re-armed its merge monitor.
            hcode, hparsed, hout = _run_self(["push", "--repo", cwd,
                                              "--issue", work_order["identifier"]])
            if hcode != 0:
                raise SetupError("push refused: %s" % ((hparsed or {}).get("reasons")))
            # `pr.head` is the sha the PR head carries; a reader (the gate) can
            # compare it with the latest green row instead of trusting the round.
            ledger["pr"]["head"] = (hparsed or {}).get("sha") or ledger["stages"][key].get("sha")
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
            ledger["pr"] = {"number": number, "url": url,
                            "head": ledger["stages"][key].get("sha")}
            # the work product links the PR to the board; it is not the record
            # the next stage reads, so it lands after the ledger is durable. A
            # re-run reuses ledger["pr"] and leaves the link to be re-added by
            # hand rather than opening a second PR.
            after_ledger.append(lambda _url=url, _num=number: api.create_work_product(
                work_order["id"], {
                    "type": "pull_request", "provider": "github",
                    "title": "PR for %s" % work_order["identifier"],
                    "url": _url, "externalId": str(_num) if _num else None,
                    "status": "ready_for_review", "isPrimary": True,
                    "reviewState": "needs_board_review",
                }))
    elif stage == "review":
        pass
    elif stage == "verify":
        if open_fix_round:
            new_round = round_no + 1
            superseded = latest_gate_row(ledger, round_no)
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
            # GUL-989: the round's stage ids exist now, so the verify description
            # can name its own review stage instead of a `?`.
            settle_stage_descriptions(api, cfg, spec, ledger, work_order, new_round,
                                      findings_block, plan, created)
            # GUL-1267 G3: the round that just closed left a gate behind. Side
            # effects, not the record: they run after the ledger write, like the
            # gate's own monitor (GUL-497).
            after_ledger.append(
                lambda _row=superseded, _n=new_round: supersede_gate(
                    api, _row, _n, work_order["id"]))
            api.comment(work_order["id"], "fix round %d opened: %s"
                        % (new_round, ", ".join(i["issue"].get("identifier", "?")
                                                 for i in created)))
    else:  # gate
        pr = ledger.get("pr") or {}

        def _watch_merge(_pr=pr, _wo=work_order["id"]):
            # No card (GUL-553): a card that merges nothing only teaches the
            # board to click through cards. The work order instead waits
            # `in_review` on a real issue monitor, and `tick` reads the PR with
            # `gh` and moves the work order on when the merge lands.
            api.patch_issue(_wo, {
                "status": "in_review",
                "executionPolicy": {"monitor": monitor_payload(_pr)},
                "comment": ("gate passed. Merge PR #%s on GitHub: %s\n\n"
                            "There is no card to accept: `factory tick` reads the PR "
                            "and moves this work order on by itself."
                            % (_pr.get("number"), _pr.get("url") or "(no url recorded)")),
            })

        after_ledger.append(_watch_merge)

    ledger["outcome"] = "pass"
    try:
        save_ledger(api, work_order["id"], ledger, "approve %s" % key)
    except pc.ApiError as exc:
        raise SetupError("ledger write failed, stage left in_progress: %s" % exc)

    api.patch_issue(stage_issue["id"], {"status": "done", "comment": comment})
    for step in after_ledger:
        step()
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


def _stage_issue(api, entry, flags, work_order, label):
    """Resolve one ledger row's stage issue; a 404 is a flag, not a dead sweep.

    A deleted or moved stage issue used to raise out of `tick` and blind every
    other work order (GUL-557). Only a 404 is survivable: any other API error
    still means the sweep cannot be trusted.
    """
    import pc
    issue_id = (entry or {}).get("issueId")
    if not issue_id:
        return None
    try:
        return api.issue(issue_id)
    except pc.ApiError as exc:
        if exc.status != 404:
            raise
        if "stage-missing" not in flags:
            flags.append("stage-missing")
        sys.stderr.write("factory tick: %s: stage issue %s (%s) is gone: %s\n"
                         % (work_order, issue_id, label, exc))
        return None


def latest_gate_row(ledger: dict, upto_round: int | None = None):
    """The newest gate row in the ledger, as `(round, key, row)` or None (GUL-1267).

    A fix round carries a gate of its own, so "the gate stage" is no longer one
    key: `upto_round` picks the newest gate at or before that round — the one a
    new fix round supersedes — and no bound picks the newest overall, which is the
    one that settles the merge in `tick`.
    """
    rows = []
    for key, row in (ledger.get("stages") or {}).items():
        if not isinstance(row, dict) or not (key == "gate" or key.startswith("gate:r")):
            continue
        row_round = int(row.get("round") or 1)
        if upto_round is not None and row_round > upto_round:
            continue
        rows.append((row_round, key, row))
    rows.sort(key=lambda item: (item[0], item[1]))
    return rows[-1] if rows else None


def open_later_round_stages(api, ledger: dict, work_order: dict, round_no: int) -> list:
    """Later-round stage issues that are still open: `[(round, key, issue)]`.

    GUL-1267 G1: a gate for round N is superseded by round N+1. The guard reads
    the live stage issues, not the ledger alone, because a row stays in the
    ledger after its issue is cancelled or done. A row whose issue is gone (404)
    counts as closed: a deleted stage must not block the gate forever.
    """
    flags: list = []
    open_rows = []
    for key, row in sorted((ledger.get("stages") or {}).items()):
        if not isinstance(row, dict):
            continue
        row_round = int(row.get("round") or 1)
        if row_round <= round_no:
            continue
        issue = _stage_issue(api, row, flags, work_order.get("identifier", "?"), key)
        if issue is None or issue.get("status") in ("done", "cancelled"):
            continue
        open_rows.append((row_round, key, issue))
    return open_rows


def supersede_gate(api, gate_row, new_round: int, work_order_id: str) -> None:
    """Cancel the gate a fix round supersedes and stop its merge watch (GUL-1267 G3).

    GUL-1199: verify round 1 opened round 2 thirty-seven seconds after the round-1
    gate had put PR #189 `in_review` with a merge monitor — a live offer to merge
    a head the fix round was about to rewrite. So opening a round cancels the gate
    it supersedes, with a comment that names the new round, and clears the work
    order's monitor. The monitor clear is a policy-only PATCH: the work order's
    status is not the factory's to change here (GUL-1128).
    """
    import pc
    if gate_row is not None:
        _round, key, row = gate_row
        issue_id = row.get("issueId")
        if issue_id:
            try:
                issue = api.issue(issue_id)
            except pc.ApiError as exc:
                if exc.status != 404:
                    raise
                issue = None
            if issue and issue.get("status") not in ("done", "cancelled"):
                api.patch_issue(issue_id, {
                    "status": "cancelled",
                    "comment": ("superseded: fix round %d opened, so this gate (%s) no "
                                "longer decides this work order; the round-%d gate does."
                                % (new_round, key, new_round)),
                })
    try:
        order = api.issue(work_order_id)
    except pc.ApiError:
        order = None
    if (order or {}).get("executionPolicy"):
        api.patch_issue(work_order_id, {"executionPolicy": None})


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
    # tick is read-only unless Majster asks to apply, and never applies while
    # the factory is stopped (GUL-553).
    apply = bool(getattr(args, "apply", False)) and not stop

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
        flags = []
        resolved = {}

        def stage_issue(entry, key):
            # one API call per ledger row: the stage resolution and the merge
            # watch must not look up the same row twice (GUL-557).
            if key not in resolved:
                resolved[key] = _stage_issue(api, entry, flags, item.get("identifier"), key)
            return resolved[key]

        current_key, current = None, None
        order = list(stages.keys())
        for key in reversed(order):
            child = stage_issue(stages[key], key)
            if child and child.get("status") not in ("done", "cancelled"):
                current_key, current = key, child
                break
        if current is None and order:
            current_key = order[-1]
            current = stage_issue(stages[order[-1]], order[-1])
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
        # the merge watch (GUL-553): a gate-passed work order waits `in_review`
        # for a merge on GitHub, and this is what notices it. GUL-1267 G4: the
        # gate that matters is the newest round's, not the round-1 `gate` row —
        # opening a fix round cancels that one.
        merge_state = None
        pr = ledger.get("pr") or {}
        newest_gate = latest_gate_row(ledger)
        gate_entry = newest_gate[2] if newest_gate else {}
        if pr.get("number") and not ledger.get("merge") and gate_entry.get("issueId"):
            gate_issue = stage_issue(gate_entry, newest_gate[1])
            if gate_issue and gate_issue.get("status") == "done":
                try:
                    view = pr_merge_view(ledger.get("repo") or "", pr["number"])
                except SetupError as exc:
                    flags.append("merge-unknown")
                    sys.stderr.write("factory tick: %s: %s\n"
                                     % (item.get("identifier"), str(exc)[:200]))
                else:
                    merge_state = settle_merge(api, item, ledger, pr, view, apply)
                    flags.append("pr-%s" % merge_state)
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
        if merge_state:
            rows[-1]["merge"] = merge_state
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

    s = sub.add_parser("push")
    s.add_argument("--repo", required=True)
    s.add_argument("--issue", required=True)
    s.set_defaults(fn=cmd_push)

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

    s = sub.add_parser("settle", parents=[common])
    s.add_argument("work_order", help="work order identifier, e.g. GUL-439")
    s.add_argument("--round", type=int, default=0, help="fix round (default: the latest)")
    s.add_argument("--apply", action="store_true", help="rewrite the verify description")
    s.add_argument("--force", action="store_true",
                   help="rewrite even a stage that is not todo/blocked (stuck stage)")
    s.set_defaults(fn=cmd_factory_settle)

    s = sub.add_parser("decide", parents=[common])
    s.add_argument("stage_issue", help="stage issue identifier, e.g. GUL-441")
    s.add_argument("--apply", action="store_true", help="make the Paperclip PATCH")
    s.set_defaults(fn=cmd_factory_decide)

    s = sub.add_parser("tick", parents=[common])
    s.add_argument("--apply", action="store_true",
                   help="settle merges: withdraw leftover cards, move a merged or closed work order on")
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
