#!/usr/bin/env python3
"""
Filter helper for homelab-security-scan.sh.
Reads raw scanner JSON/text from stdin and applies the allowlist from
.security-scan-exclusions.yaml, printing a suppressed section and a
headline summary.
"""
import json, sys, yaml, re, os

EXCLUSIONS_FILE = ".security-scan-exclusions.yaml"


def load_exclusions():
    with open(EXCLUSIONS_FILE, "r") as f:
        return yaml.safe_load(f) or {}


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


def filter_kube_score(text, exclusions):
    suppress = set(exclusions.get("kube_score", {}).get("suppress_ids", []))
    kept, suppressed = [], []
    for line in text.splitlines():
        m = re.search(r"\[(WARNING|CRITICAL)\]\s+([^\]]+)", line)
        if not m:
            continue
        check = m.group(2).strip().split(" ")[0]
        if check in suppress:
            suppressed.append(line)
        else:
            kept.append(line)
    return kept, suppressed


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "help"
    exc = load_exclusions()
    data = sys.stdin.read()
    if mode == "trivy":
        j = json.loads(data)
        kept, suppressed = filter_trivy_misconfigs(j, exc)
        print(json.dumps({"kept": kept, "suppressed": suppressed}))
    elif mode == "kscore":
        kept, suppressed = filter_kube_score(data, exc)
        print(json.dumps({"kept_count": len(kept), "suppressed_count": len(suppressed)}))
    else:
        print("usage: python3 homelab-security-scan-filter.py {trivy|kscore}")
        sys.exit(1)
