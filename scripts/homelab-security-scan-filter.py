#!/usr/bin/env python3
"""
Filter helper for homelab-security-scan.sh.
Reads raw scanner JSON/text from stdin and applies the allowlist from
.security-scan-exclusions.json, printing a suppressed section and a
headline summary.

This script uses only the Python standard library so it runs inside a
minimal cron environment without PyYAML.
"""
import json, sys, re

EXCLUSIONS_FILE = ".security-scan-exclusions.json"


def load_exclusions():
    with open(EXCLUSIONS_FILE, "r") as f:
        return json.load(f) or {}


def filter_trivy_misconfigs(trivy_json, exclusions):
    ids = set(exclusions.get("trivy_misconfig", {}).get("ids", []))
    results = trivy_json.get("Results", []) or []
    kept, suppressed = [], []
    for r in results:
        for m in r.get("Misconfigurations") or []:
            item = {
                "id": m.get("ID"),
                "title": m.get("Title"),
                "provider": m.get("CauseMetadata", {}).get("Provider", "unknown"),
                "service": m.get("CauseMetadata", {}).get("Service", "unknown"),
                "severity": m.get("Severity"),
            }
            if item["id"] in ids:
                suppressed.append(item)
            else:
                kept.append(item)
    return kept, suppressed


def filter_kube_score_json(kscore_json, exclusions):
    suppress = set(exclusions.get("kube_score", {}).get("suppress_ids", []))
    kept, suppressed = [], []
    for obj in kscore_json:
        for check in obj.get("checks", []):
            if check.get("skipped") or check.get("grade", 10) >= 5:
                continue
            check_id = check.get("check", {}).get("id", "")
            item = {
                "object_name": obj.get("object_name"),
                "check_id": check_id,
                "check_name": check.get("check", {}).get("name", ""),
            }
            if check_id in suppress:
                suppressed.append(item)
            else:
                kept.append(item)
    return kept, suppressed


def filter_kubeconform_json(kconform_json, exclusions):
    missing_groups = set(exclusions.get("kubeconform", {}).get("missing_schema_groups", []))
    expected_kinds = set(exclusions.get("kubeconform", {}).get("expected_invalid_kinds", []))
    expected_msgs = exclusions.get("kubeconform", {}).get("expected_messages", [])
    kept, suppressed = [], []
    for r in kconform_json.get("resources", []) or []:
        if r.get("status") == "statusValid":
            continue
        kind = r.get("kind", "")
        group = ""
        if "/" in kind:
            group = kind.rsplit("/", 1)[0]
        msg = r.get("msg", "")
        item = {
            "kind": kind,
            "name": r.get("name"),
            "status": r.get("status"),
            "msg": msg,
        }
        if group in missing_groups:
            suppressed.append(item)
            continue
        if kind in expected_kinds:
            suppressed.append(item)
            continue
        if kind.startswith("ENC["):
            # SOPS-encrypted resource: kubeconform cannot decrypt the kind/name
            suppressed.append(item)
            continue
        if any(needle in msg for needle in expected_msgs):
            suppressed.append(item)
            continue
        kept.append(item)
    return kept, suppressed


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "help"
    exc = load_exclusions()
    data = sys.stdin.read()
    if mode == "trivy":
        j = json.loads(data)
        kept, suppressed = filter_trivy_misconfigs(j, exc)
        print(json.dumps({"kept": kept, "suppressed": suppressed}))
    elif mode == "kscore-json":
        j = json.loads(data)
        kept, suppressed = filter_kube_score_json(j, exc)
        print(json.dumps({"kept_count": len(kept), "suppressed_count": len(suppressed), "kept": kept[:10]}))
    elif mode == "kubeconform":
        j = json.loads(data)
        kept, suppressed = filter_kubeconform_json(j, exc)
        print(json.dumps({"kept_count": len(kept), "suppressed_count": len(suppressed), "kept": kept[:10]}))
    else:
        print("usage: python3 homelab-security-scan-filter.py {trivy|kscore-json|kubeconform}")
        sys.exit(1)
