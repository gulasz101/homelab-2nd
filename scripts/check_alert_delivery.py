#!/usr/bin/env python3
"""Audit every AlertmanagerConfig in the cluster, and optionally prove each hook works.

Why this exists
---------------
Two silent failures have bitten us on alert routing:

1. The label trap. An AlertmanagerConfig whose labels do not match the Alertmanager
   CR's ``alertmanagerConfigSelector`` is simply not loaded. The rules fire, the pods
   look green, and no message is ever sent. (GUL-643)
2. The client trap. ``https://chat.voitech.dev`` sits behind Cloudflare, which answers
   **403** to Python's TLS fingerprint. A probe written with ``requests``/``urllib``
   reports a perfectly healthy Mattermost hook as dead, and somebody "fixes" a
   webhook that was never broken. (GUL-712 finding, disproved on GUL-726)

Both checks are read-only. The hook probe is opt-in (``--probe``) because it posts a
real message to the channel.

Usage
-----
    scripts/check_alert_delivery.py              # static audit, no messages sent
    scripts/check_alert_delivery.py --probe      # also POST one labelled probe per hook
    scripts/check_alert_delivery.py -v           # show every AMC, not only failures

Exit codes: 0 every check passed, 1 at least one FAIL, 2 the audit could not run.

Webhook URLs are never printed. The output carries the host, the value length and a
sha256 prefix, which is enough to tell two hooks apart and not enough to use one.
"""

from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import json
import os
import subprocess
import sys
import time
from typing import Any, NoReturn
from urllib.parse import urlparse

# Overridable so the fixture test can run without a cluster.
KUBECTL = os.environ.get("KUBECTL", "kubectl")


def kubectl(*args: str) -> Any:
    """Run kubectl and parse JSON. Raises SystemExit(2) when the cluster is out of reach."""
    cmd = [KUBECTL, *args, "-o", "json"]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except FileNotFoundError:
        fail("kubectl is not installed or not on PATH")
    if out.returncode != 0:
        fail(f"{' '.join(cmd)} failed: {out.stderr.strip()[:300]}")
    try:
        return json.loads(out.stdout or "{}")
    except json.JSONDecodeError as exc:
        fail(f"{' '.join(cmd)} returned non-JSON: {exc}")


def fail(message: str) -> NoReturn:
    print(f"ERROR: {message}")
    raise SystemExit(2)


def selector_matches(selector: dict | None, labels: dict) -> bool:
    """Kubernetes LabelSelector semantics, the subset this estate actually uses."""
    if selector is None:
        return False
    for key, value in (selector.get("matchLabels") or {}).items():
        if labels.get(key) != value:
            return False
    for expr in selector.get("matchExpressions") or []:
        operator = expr.get("operator")
        key = expr.get("key")
        values = expr.get("values") or []
        present = key in labels
        if operator == "In" and labels.get(key) not in values:
            return False
        if operator == "NotIn" and present and labels.get(key) in values:
            return False
        if operator == "Exists" and not present:
            return False
        if operator == "DoesNotExist" and present:
            return False
    return True


def secret_value(namespace: str, name: str, key: str) -> str | None:
    """Read one key out of a Secret. The value stays in memory; only a digest is printed."""
    try:
        out = subprocess.run(
            [KUBECTL, "-n", namespace, "get", "secret", name, "-o", "jsonpath={.data}"],
            capture_output=True,
            text=True,
            timeout=60,
        )
    except subprocess.TimeoutExpired:
        return None
    if out.returncode != 0 or not out.stdout.strip():
        return None
    try:
        data = json.loads(out.stdout)
        return base64.b64decode(data[key]).decode()
    except (json.JSONDecodeError, KeyError, ValueError):
        return None


def describe_secret(value: str) -> str:
    """Host, length and digest. Never the URL."""
    host = urlparse(value).hostname or "?"
    digest = hashlib.sha256(value.encode()).hexdigest()[:8]
    return f"host={host} len={len(value)} sha256={digest}"


def hook_refs(amc: dict) -> list[tuple[str, str, str, str]]:
    """Every (receiver, kind, secretName, secretKey) a config points at."""
    found = []
    for receiver in amc.get("spec", {}).get("receivers") or []:
        name = receiver.get("name", "?")
        for slack in receiver.get("slackConfigs") or []:
            api = slack.get("apiURL") or {}
            if api.get("name"):
                found.append((name, "slack", api["name"], api.get("key", "url")))
        for hook in receiver.get("webhookConfigs") or []:
            secret = hook.get("urlSecret") or {}
            if secret.get("name"):
                found.append((name, "webhook", secret["name"], secret.get("key", "url")))
    return found


def generated_config(am: dict) -> str | None:
    """Decode the operator-generated alertmanager.yaml for one Alertmanager CR."""
    ns = am["metadata"]["namespace"]
    name = am["metadata"]["name"]
    secret = f"alertmanager-{name}-generated"
    raw = subprocess.run(
        [KUBECTL, "-n", ns, "get", "secret", secret, "-o", "jsonpath={.data}"],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if raw.returncode != 0:
        return None
    try:
        data = json.loads(raw.stdout)
        blob = base64.b64decode(data.get("alertmanager.yaml.gz", ""))
        return gzip.decompress(blob).decode()
    except (json.JSONDecodeError, KeyError, ValueError, OSError):
        return None


def probe(value: str, label: str) -> tuple[str, int]:
    """POST one real message with curl. Returns (status, http code).

    curl on purpose: Cloudflare blocks Python's TLS fingerprint with a 403 that looks
    exactly like a dead webhook. Using anything but curl here re-creates the bug this
    script exists to catch.
    """
    text = f"probe from scripts/check_alert_delivery.py ({label}) at {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}"
    body = json.dumps({"text": text})
    out = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST",
         "-H", "Content-Type: application/json", "-d", body, value],
        capture_output=True,
        text=True,
        timeout=30,
    )
    code = (out.stdout or "000").strip()
    if code == "200":
        return "PASS", 200
    return f"FAIL (HTTP {code})", int(code) if code.isdigit() else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--probe", action="store_true", help="POST one real message per distinct hook")
    parser.add_argument("-v", "--verbose", action="store_true", help="list passing configs too")
    parser.add_argument("--kubeconfig", help="kubeconfig to use (default: current context)")
    args = parser.parse_args()

    if args.kubeconfig:
        os.environ["KUBECONFIG"] = args.kubeconfig

    alertmanagers = kubectl("get", "alertmanager", "-A").get("items") or []
    if not alertmanagers:
        fail("no Alertmanager CR found in the cluster")
    amcs = kubectl("get", "alertmanagerconfig", "-A").get("items") or []

    failures = 0
    probed: dict[str, str] = {}

    for am in alertmanagers:
        am_ns = am["metadata"]["namespace"]
        am_name = am["metadata"]["name"]
        spec = am.get("spec") or {}
        selector = spec.get("alertmanagerConfigSelector")
        ns_selector = spec.get("alertmanagerConfigNamespaceSelector")
        strategy = spec.get("alertmanagerConfigMatcherStrategy") or {}
        config_text = generated_config(am)

        print(f"Alertmanager {am_ns}/{am_name}")
        print(f"  alertmanagerConfigSelector:        {json.dumps(selector)}")
        print(f"  alertmanagerConfigNamespaceSelector: {json.dumps(ns_selector)}"
              + ("   (null -> only the Alertmanager's own namespace is loaded)" if ns_selector is None else ""))
        print(f"  alertmanagerConfigMatcherStrategy:  {strategy.get('type', 'OnNamespace (default)')}")
        print()

        if selector is None:
            print("  FAIL no alertmanagerConfigSelector: no AlertmanagerConfig can be loaded")
            failures += 1

        if config_text is None:
            print("  FAIL could not read the generated alertmanager config secret")
            failures += 1

        for amc in amcs:
            meta = amc["metadata"]
            ns, name = meta["namespace"], meta["name"]
            labels = meta.get("labels") or {}
            receivers = amc.get("spec", {}).get("receivers") or []
            receiver_names = [r.get("name", "?") for r in receivers]

            problems = []
            if selector_matches(selector, labels):
                pass
            else:
                problems.append(
                    f"labels {json.dumps(labels, sort_keys=True)} do not match the selector "
                    f"{json.dumps(selector)} -> this config is NEVER loaded"
                )
            if ns_selector is None and ns != am_ns:
                problems.append(
                    f"in namespace {ns} but the namespace selector is null, so only {am_ns} is loaded"
                )
            if ns_selector is not None and not selector_matches(ns_selector, {"kubernetes.io/metadata.name": ns}):
                problems.append(f"namespace {ns} does not match alertmanagerConfigNamespaceSelector")

            if config_text:
                for receiver in receiver_names:
                    route = f"{ns}/{name}/{receiver}"
                    if route not in config_text:
                        problems.append(f"receiver {route} is missing from the generated config")

            hooks = hook_refs(amc)
            for receiver, kind, secret_name, key in hooks:
                value = secret_value(ns, secret_name, key)
                if value is None:
                    problems.append(f"receiver {receiver}: Secret {ns}/{secret_name} key {key} is missing")
                    continue
                digest = describe_secret(value)
                if args.verbose and not args.probe:
                    print(f"  hook {ns}/{name} receiver {receiver}: {digest}")
                if args.probe:
                    if value not in probed:
                        status, _code = probe(value, f"{ns}/{name}/{receiver}")
                        probed[value] = status
                        if not status.startswith("PASS"):
                            failures += 1
                    status = probed[value]
                    if not status.startswith("PASS"):
                        problems.append(f"receiver {receiver}: {kind} hook {digest} -> {status}")
                    elif args.verbose:
                        print(f"  PASS {ns}/{name} receiver {receiver}: {kind} hook {digest} -> {status}")

            if problems:
                failures += len(problems)
                print(f"  FAIL {ns}/{name}")
                for problem in problems:
                    print(f"       - {problem}")
            elif args.verbose:
                print(f"  PASS {ns}/{name}: labels match, routes present"
                      + (f", {len(hooks)} hook(s) answered 200" if args.probe else ""))

    print()
    print(f"{len(amcs)} AlertmanagerConfig(s) inspected, {len(probed)} distinct hook(s) probed"
          if args.probe else f"{len(amcs)} AlertmanagerConfig(s) inspected, no messages sent")
    if failures:
        print(f"{failures} problem(s) found")
        return 1
    print("no delivery problem found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
