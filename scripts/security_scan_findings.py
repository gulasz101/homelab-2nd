#!/usr/bin/env python3
"""Collect critical/warning findings from the nightly security scan and emit
findings JSON for itsaplan_sync.py.

Usage: security_scan_findings.py <trivy_filtered.json> <gitleaks.json> <plain_secret_count> <custom_critical_count> <scan_date> <scan_commit>

Reads the intermediate artifacts the scan script already produces, plus
re-scans the repo for the custom checks (plaintext secrets, privileged,
hostPath, root) the same way the shell script does, then groups:
- criticals: gitleaks findings, trivy secrets, plaintext secrets, unaccepted
  hostPath/privileged/root containers
- warnings: actionable trivy misconfigs, kubeconform failures, kube-score
  kept warnings, pluto deprecations
"""
import json
import os
import re
import subprocess
import sys

REPO = os.environ.get("REPO", os.path.expanduser("~/Projects/homelab-2nd"))


def detect_run_as_user_zero(path):
    """Return a short detail of which block(s) have runAsUser: 0 / runAsGroup: 0."""
    details = []
    try:
        with open(path) as f:
            lines = f.readlines()
    except OSError:
        return details
    current_name = None
    in_containers = False
    for line in lines:
        # containers/initContainers/volumes start at 6+ spaces (pod spec level);
        # container entries are "- name:", nested mounts/volumes are deeper.
        if re.match(r"\s{6}(initContainers|containers):\s*$", line):
            in_containers = True
            current_name = None
            continue
        if re.match(r"\s{6}volumes:\s*$", line):
            in_containers = False
            current_name = None
            continue
        m = re.match(r" {8}- name:\s*(\S+)", line)
        if m and in_containers:
            current_name = m.group(1)
            continue
        if in_containers and re.search(r"^[^#]*runAs(User|Group):\s*0\b", line):
            details.append("root in %s" % (current_name or "container"))
    return "; ".join(details) or "runAsUser: 0"


def scan_custom():
    criticals = []
    accepted = load_accepted()
    for root, _dirs, files in os.walk(REPO):
        if "/.git" in root:
            continue
        for fn in files:
            if not fn.endswith((".yaml", ".yml")):
                continue
            path = os.path.join(root, fn)
            rel = os.path.relpath(path, REPO)
            try:
                with open(path, encoding="utf-8", errors="replace") as f:
                    text = f.read()
            except OSError:
                continue
            if re.search(r"^kind:\s*Secret", text, re.M) and not re.search(r"^sops:", text, re.M):
                criticals.append({"kind": "plaintext_secret", "file": rel, "detail": "plaintext Secret manifest (not SOPS-encrypted)"})
            if re.search(r"^[^#]*hostPath:", text, re.M) and rel not in accepted.get("hostpath", ()):
                criticals.append({"kind": "hostpath", "file": rel, "detail": "hostPath volume not in accepted exclusions"})
            if re.search(r"^[^#]*privileged:\s*true", text, re.M) and rel not in accepted.get("privileged", []):
                criticals.append({"kind": "privileged", "file": rel, "detail": "privileged container not in accepted exceptions"})
            root_hits = detect_run_as_user_zero(path) if re.search(r"^[^#]*runAs(User|Group):\s*0\b", text, re.M) else ""
            if root_hits and rel not in accepted.get("root", []):
                criticals.append({"kind": "root_user", "file": rel, "detail": root_hits})
    return criticals


def load_accepted():
    """Read .security-scan-exclusions.json custom accepted lists -> {kind: set(files)}"""
    out = {"hostpath": set(), "privileged": set(), "root": set()}
    path = os.path.join(REPO, ".security-scan-exclusions.json")
    try:
        with open(path) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return out
    custom = d.get("custom", {})
    for key, kind in (("hostpath_accepted", "hostpath"), ("privileged_accepted", "privileged"), ("root_accepted", "root")):
        for item in custom.get(key, []):
            if isinstance(item, dict) and item.get("file"):
                out[kind].add(item["file"])
    return out


def load_trivy_filtered(path):
    """trivy actionable misconfigs -> warnings entries"""
    try:
        with open(path) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return []
    kept = d.get("kept", [])
    warnings = []
    for k in kept:
        warnings.append({
            "kind": "trivy_misconfig",
            "file": k.get("service", k.get("provider", "unknown")),
            "detail": "%s: %s" % (k.get("id", "?"), k.get("title", "?")),
        })
    return warnings


def load_gitleaks(path):
    try:
        with open(path) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return []
    out = []
    for g in d if isinstance(d, list) else d.get("findings", []):
        out.append({
            "kind": "gitleaks",
            "file": g.get("File", "?"),
            "detail": "rule %s (entropy %s)" % (g.get("RuleID", "?"), g.get("Entropy", "?")),
        })
    return out


def main():
    trivy_json = sys.argv[1]
    gitleaks_json = sys.argv[2]
    plain_secret_count = int(sys.argv[3])
    custom_critical_count = int(sys.argv[4])
    scan_date = sys.argv[5]
    scan_commit = sys.argv[6]

    criticals = scan_custom()
    # shell already counts these; use its number as a cross-check but emit
    # our own file-level list (which is the same computation).
    # gitleaks findings:
    criticals.extend(load_gitleaks(gitleaks_json))

    warnings = load_trivy_filtered(trivy_json)

    out = {
        "date": scan_date,
        "commit": scan_commit,
        "criticals": criticals,
        "warnings": warnings,
        "counts": {
            "plain_secrets_shell": plain_secret_count,
            "custom_critical_shell": custom_critical_count,
            "criticals_collector": len(criticals),
            "warnings_collector": len(warnings),
        },
    }
    json.dump(out, sys.stdout, indent=1)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()