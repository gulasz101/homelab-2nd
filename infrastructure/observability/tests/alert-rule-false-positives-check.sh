#!/usr/bin/env bash
# Red-stage check for GUL-1625 (CNPG backup / RiffRadar readiness / itsaplan CPU).
#
# Lives in infrastructure/observability/tests/ so scripts/check.sh discovers it
# with no edit there: auto-discovery picks up every */tests/*-check.sh under
# apps, infrastructure, docs, agents, scripts and host.
#
# One file on purpose: the work order's spec allows exactly this test path, so
# the assertions live in the inline python below instead of a sibling .py. The
# expressions have to be read structurally (which branch of the `or` the
# `unless` sits in), which bash cannot do without a character-mangling loop.
#
# One `AC-<n>: PASS|FAIL <reason>` line per acceptance criterion on stdout,
# exit 0 only when all five pass, exit 1 when any fails, exit 2 when the check
# itself cannot run.
#
# Usage: bash infrastructure/observability/tests/alert-rule-false-positives-check.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec python3 - "$here" <<'PY'
"""GUL-1625 red-stage check: false-positive guards on three alert rules.

AC-1  CNPGBackupFailed: `unless on (namespace, cluster)` followed by
      barman_cloud_cloudnative_pg_io_last_available_backup_timestamp, sitting
      INSIDE the cnpg_collector branch of the `or`, not after the whole `or`.
AC-2  The comment above CNPGBackupFailed no longer claims the legacy
      cnpg_collector_* branch is already guarded (the wording on main is gone).
AC-3  RiffRadarPodNotReady excludes Job-owned pods:
      `unless on (namespace, pod) kube_pod_owner{namespace="riffradar",
      owner_kind="Job"}`.
AC-4  itsaplan web container: limits.cpu 600m, requests.cpu 50m.
AC-5  All three files still parse with yq, this check sits where
      scripts/check.sh auto-discovers it (no edit there), and AC-1..AC-4 all
      hold in the same run.
"""

import os
import re
import shutil
import subprocess
import sys

HERE = os.path.abspath(sys.argv[1])
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

CNPG = os.path.join(ROOT, "infrastructure/observability/cnpg-backup-prometheus-rules.yaml")
RIFF = os.path.join(ROOT, "apps/riffradar/riffradar-prometheus-rules.yaml")
PLAN = os.path.join(ROOT, "apps/itsaplan/itsaplan-helm-release.yaml")
SELF = os.path.join(HERE, "alert-rule-false-positives-check.sh")
CHECK_SH = os.path.join(ROOT, "scripts/check.sh")

# The comment wording on main at a03a07b, normalised to one line. AC-2 says it
# has to be gone: it claims the latched legacy collector timestamp cannot cause
# a false positive, which is exactly the claim the `unless` guard adds.
STALE_COMMENT = (
    "The legacy branch is guarded by last_available > 0 so the latched "
    "deprecated collector timestamp on plugin clusters cannot produce a "
    "false positive."
)

DISCOVER_TOP = ("apps", "infrastructure", "docs", "agents", "scripts", "host")


def setup_error(msg):
    sys.stderr.write("setup error: %s\n" % msg)
    sys.exit(2)


def rel(path):
    return os.path.relpath(path, ROOT).replace(os.sep, "/")


def yq(expression, path):
    """yq eval; None when the file does not parse."""
    proc = subprocess.run(
        ["yq", "eval", expression, path], capture_output=True, text=True
    )
    if proc.returncode != 0:
        return None
    return proc.stdout


def flat(text):
    """Collapse all whitespace (the exprs are folded block scalars)."""
    return " ".join(text.split())


def depth_at(text, index):
    """Paren depth at `index` (0 = top level, outside every group)."""
    depth = 0
    for ch in text[:index]:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
    return depth


def is_word(text, i):
    before = text[i - 1] if i else " "
    after = text[i + 2] if i + 2 < len(text) else " "
    return not (before.isalnum() or before == "_") and not (
        after.isalnum() or after == "_"
    )


def top_level_ors(text):
    """Offsets of every `or` operator token at paren depth 0."""
    out, depth, i = [], 0, 0
    while i < len(text):
        ch = text[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif depth == 0 and text.startswith("or", i) and is_word(text, i):
            out.append(i)
        i += 1
    return out


def branch_bounds(text, index, ors):
    """The top-level `or` operand that contains `index`, as (start, end)."""
    bounds, start = [], 0
    for or_pos in ors:
        bounds.append((start, or_pos))
        start = or_pos + 2
    bounds.append((start, len(text)))
    for lo, hi in bounds:
        if lo <= index < hi:
            return lo, hi
    return 0, len(text)


def expr_of(path, alert):
    return yq(
        '.spec.groups[].rules[] | select(.alert == "%s") | .expr' % alert, path
    )


def check_ac1():
    raw = expr_of(CNPG, "CNPGBackupFailed")
    if raw is None or not raw.strip():
        return False, "%s: CNPGBackupFailed expr unreadable with yq" % rel(CNPG)
    text = flat(raw)

    guard = re.search(
        r"unless\s+on\s*\(\s*namespace\s*,\s*cluster\s*\)\s+"
        r"barman_cloud_cloudnative_pg_io_last_available_backup_timestamp",
        text,
    )
    if not guard:
        return False, (
            "CNPGBackupFailed expr has no `unless on (namespace, cluster) "
            "barman_cloud_cloudnative_pg_io_last_available_backup_timestamp`"
        )
    unless = guard.start()

    legacy = text.find("cnpg_collector_last_available_backup_timestamp")
    if legacy < 0:
        return False, "CNPGBackupFailed expr no longer has a cnpg_collector branch"
    if unless < legacy:
        return False, (
            "the `unless ... barman_cloud_...last_available` guard sits before the "
            "cnpg_collector branch of the `or`"
        )

    lo, hi = branch_bounds(text, legacy, top_level_ors(text))
    if not (lo <= unless < hi):
        return False, (
            "the `unless ... barman_cloud_...last_available` guard is in a different "
            "operand of the top-level `or` than the cnpg_collector branch"
        )
    if depth_at(text, unless) < 1:
        return False, (
            "the `unless ... barman_cloud_...last_available` guard is appended after the "
            "whole `or`; it must sit inside the cnpg_collector branch"
        )
    return True, ""


def cnpg_backupfailed_comment():
    """The comment block directly under `- alert: CNPGBackupFailed`."""
    with open(CNPG, encoding="utf-8") as handle:
        lines = handle.readlines()
    for i, line in enumerate(lines):
        if line.strip() == "- alert: CNPGBackupFailed":
            block = []
            for nxt in lines[i + 1:]:
                stripped = nxt.strip()
                if stripped.startswith("#"):
                    block.append(stripped.lstrip("#").strip())
                    continue
                break
            return " ".join(block)
    return None


def check_ac2():
    comment = cnpg_backupfailed_comment()
    if comment is None:
        return False, "no `- alert: CNPGBackupFailed` rule found in " + rel(CNPG)
    if flat(STALE_COMMENT).lower() in flat(comment).lower():
        return False, (
            "the comment above CNPGBackupFailed still carries the main wording claiming "
            "the legacy cnpg_collector_* branch is already guarded"
        )
    return True, ""


def check_ac3():
    raw = expr_of(RIFF, "RiffRadarPodNotReady")
    if raw is None or not raw.strip():
        return False, "%s: RiffRadarPodNotReady expr unreadable with yq" % rel(RIFF)
    text = flat(raw)

    guard = re.search(
        r"unless\s+on\s*\(\s*namespace\s*,\s*pod\s*\)\s*"
        r"kube_pod_owner\s*\{([^}]*)\}",
        text,
    )
    if not guard:
        return False, (
            "RiffRadarPodNotReady expr has no `unless on (namespace, pod) "
            "kube_pod_owner{...}` - Job-owned pods are not excluded"
        )
    selector = guard.group(1)
    if not re.search(r'namespace\s*=\s*"riffradar"', selector):
        return False, (
            'the kube_pod_owner selector in the unless does not pin namespace="riffradar"'
        )
    if not re.search(r'owner_kind\s*=\s*"Job"', selector):
        return False, (
            'the kube_pod_owner selector in the unless does not filter owner_kind="Job"'
        )
    return True, ""


def check_ac4():
    limits = (yq(".spec.values.web.resources.limits.cpu", PLAN) or "").strip()
    requests = (yq(".spec.values.web.resources.requests.cpu", PLAN) or "").strip()
    problems = []
    if limits != "600m":
        problems.append("limits.cpu is %s, want 600m" % (limits or "<unset>"))
    if requests != "50m":
        problems.append("requests.cpu is %s, want 50m" % (requests or "<unset>"))
    if problems:
        return False, "itsaplan web container: " + "; ".join(problems)
    return True, ""


def yq_parses(path):
    proc = subprocess.run(
        ["yq", "eval", ".", path], capture_output=True, text=True
    )
    if proc.returncode == 0:
        return True, ""
    return False, " ".join(proc.stderr.split())[:160]


def check_ac5(results):
    problems = []

    for path in (CNPG, RIFF, PLAN):
        ok, err = yq_parses(path)
        if not ok:
            problems.append("%s does not parse with yq (%s)" % (rel(path), err))

    if not os.path.isfile(SELF):
        problems.append("%s is missing" % rel(SELF))
    else:
        rel_self = rel(SELF)
        top = rel_self.split("/", 1)[0]
        if not re.search(r"/tests/[^/]+-check\.sh$", rel_self) or top not in DISCOVER_TOP:
            problems.append(
                "this check at %s is not auto-discovered by scripts/check.sh" % rel_self
            )

    if not os.path.isfile(CHECK_SH):
        problems.append("%s is missing" % rel(CHECK_SH))
    else:
        with open(CHECK_SH, encoding="utf-8") as handle:
            body = handle.read()
        if "alert-rule-false-positives-check.sh" in body:
            problems.append(
                "%s names this check explicitly; discovery must need no edit there"
                % rel(CHECK_SH)
            )
        if "-path '*/tests/*-check.sh'" not in body:
            problems.append(
                "%s no longer auto-discovers */tests/*-check.sh" % rel(CHECK_SH)
            )

    red = [ac for ac in ("AC-1", "AC-2", "AC-3", "AC-4") if not results[ac][0]]
    if red:
        problems.append("%s still fail in this run" % " / ".join(red))

    if problems:
        return False, "; ".join(problems)
    return True, ""


def main():
    if shutil.which("yq") is None:
        setup_error("yq (mikefarah v4) is not on PATH; the manifests cannot be read")
    for path in (CNPG, RIFF, PLAN):
        if not os.path.isfile(path):
            setup_error("missing manifest %s" % rel(path))

    results = {}
    for ac, fn in (
        ("AC-1", check_ac1),
        ("AC-2", check_ac2),
        ("AC-3", check_ac3),
        ("AC-4", check_ac4),
    ):
        try:
            results[ac] = fn()
        except Exception as exc:  # noqa: BLE001 - a crash is a failing criterion, not a pass
            results[ac] = (False, "check crashed: %s" % exc)
    results["AC-5"] = check_ac5(results)

    for ac in ("AC-1", "AC-2", "AC-3", "AC-4", "AC-5"):
        ok, reason = results[ac]
        if ok:
            print("%s: PASS" % ac)
        else:
            print("%s: FAIL %s" % (ac, reason))

    return 0 if all(ok for ok, _ in results.values()) else 1


sys.exit(main())
PY
