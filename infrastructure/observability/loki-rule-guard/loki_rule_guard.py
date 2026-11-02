#!/usr/bin/env python3
"""loki-rule-guard -- prove that Loki rule updates actually reach the Ruler (GUL-805).

Why this exists
---------------
The Loki Ruler reads its rule files from /rules. The `loki-sc-rules` sidecar in
`loki-0` fills that directory by watching ConfigMaps labelled `loki_rule` in the
`observability` namespace. On 2026-11-01 the sidecar silently stopped reacting to
ConfigMap changes: no crash, no restart, no error line, last log line at 18:36.
A rule merged that day (LiteLLM1017ChainFellBack) existed in the cluster as a
ConfigMap and was never written to /rules, so it was dead on arrival while every
object still read green.

What one run does
-----------------
1. Rewrites the canary ConfigMap's rule file with a fresh epoch stamp. Its whole
   purpose is to be a rule change the sidecar MUST notice.
2. Compares the ConfigMap side with the Ruler side, taken from the ruler's own API
   (/prometheus/api/v1/rules) and never from the sidecar's log -- the sidecar is the
   part that can be broken:
     * coverage  -- every data key of every ConfigMap labelled `loki_rule` must
                    appear as a rule-group `file` in the ruler's answer;
     * freshness -- the canary's rule group must carry a stamp no older than
                    STALE_SECONDS, which proves the update path is alive.
3. Posts to Mattermost on a state change, re-posts every REMIND_SECONDS while still
   broken, and posts once on recovery. The state lives in the canary ConfigMap's
   annotations, so a guard pod restart does not re-page.

Exit 0: the check ran (whatever it found). Exit 2: it could not run, or the message
could not be delivered -- that fails the Job, which is what LokiRuleGuardNotRunning
watches, and a failed delivery must never look like a green run.
"""

from __future__ import annotations

import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
RULER_URL = os.environ.get(
    "RULER_URL", "http://loki.observability.svc.cluster.local:3100/prometheus/api/v1/rules"
)
NAMESPACE = os.environ.get("GUARD_NAMESPACE", "observability")
CANARY_NAME = os.environ.get("CANARY_CONFIGMAP", "loki-rule-canary")
CANARY_KEY = os.environ.get("CANARY_DATA_KEY", "loki-rule-canary.yaml")
CANARY_GROUP = "observability.loki-rule-delivery-canary"
STALE_SECONDS = int(os.environ.get("STALE_SECONDS", "900"))
REMIND_SECONDS = int(os.environ.get("REMIND_SECONDS", "21600"))
WEBHOOK = os.environ.get("MATTERMOST_WEBHOOK_URL", "")
# A descriptive User-Agent is mandatory: Cloudflare's Browser Integrity Check
# answers 403 (error code 1010) to the stock `Python-urllib/<ver>` signature.
USER_AGENT = "homelab-loki-rule-guard/1.0"


def log(message: str) -> None:
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {message}", flush=True)


# --------------------------------------------------------------------------- k8s

def _kube_ctx() -> tuple[str, ssl.SSLContext, str]:
    host = os.environ["KUBERNETES_SERVICE_HOST"]
    port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
    with open(f"{SA_DIR}/token", encoding="utf-8") as fh:
        token = fh.read().strip()
    return f"https://{host}:{port}", ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt"), token


def kube(method: str, path: str, body: dict | None = None, ctype: str = "application/json"):
    base, ctx, token = _kube_ctx()
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        base + path,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "Content-Type": ctype,
            "User-Agent": USER_AGENT,
        },
    )
    with urllib.request.urlopen(req, context=ctx, timeout=20) as resp:
        raw = resp.read()
    return json.loads(raw) if raw else {}


def canary_rule(stamp: int) -> str:
    # `vector(0) > 1` has no series, so this rule can never fire: its purpose is to
    # carry a stamp through the ConfigMap -> file -> ruler pipeline, nothing else.
    return (
        "groups:\n"
        f"  - name: {CANARY_GROUP}\n"
        "    interval: 1m\n"
        "    rules:\n"
        "      - alert: LokiRuleDeliveryCanary\n"
        "        expr: vector(0) > 1\n"
        "        for: 5m\n"
        "        labels:\n"
        "          severity: none\n"
        "          canary: \"true\"\n"
        f"          canary_stamp: \"{stamp}\"\n"
        "        annotations:\n"
        "          summary: Loki rule delivery canary (must never fire)\n"
        "          description: Reward for the guard CronJob. Do not edit by hand.\n"
    )


def load_canary() -> dict:
    try:
        return kube("GET", f"/api/v1/namespaces/{NAMESPACE}/configmaps/{CANARY_NAME}")
    except urllib.error.HTTPError as err:
        if err.code != 404:
            raise
        log(f"canary ConfigMap {NAMESPACE}/{CANARY_NAME} is missing, creating it")
        return kube(
            "POST",
            f"/api/v1/namespaces/{NAMESPACE}/configmaps",
            {
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {
                    "name": CANARY_NAME,
                    "namespace": NAMESPACE,
                    "labels": {"loki_rule": "true", "app.kubernetes.io/name": "loki-rule-guard"},
                    "annotations": {"guard-first-seen": str(int(time.time()))},
                },
                "data": {CANARY_KEY: canary_rule(int(time.time()))},
            },
        )


def save_canary(data_value: str, annotations: dict) -> None:
    # JSON merge patch: a nested map is merged key by key, so only the canary's own
    # data key and its guard-* annotations are touched.
    kube(
        "PATCH",
        f"/api/v1/namespaces/{NAMESPACE}/configmaps/{CANARY_NAME}",
        {"data": {CANARY_KEY: data_value}, "metadata": {"annotations": annotations}},
        ctype="application/merge-patch+json",
    )


def labelled_rule_files() -> dict[str, str]:
    """data key -> ConfigMap name, for every ConfigMap the sidecar is meant to collect."""
    found: dict[str, str] = {}
    cms = kube("GET", f"/api/v1/namespaces/{NAMESPACE}/configmaps?labelSelector=loki_rule")
    for cm in cms.get("items", []):
        name = cm["metadata"]["name"]
        for key in (cm.get("data") or {}):
            found[key] = name
    return found


# ------------------------------------------------------------------------- ruler

def ruler_rules() -> tuple[dict[str, list[str]], int | None]:
    """(file name -> group names, canary stamp) exactly as the ruler serves them."""
    req = urllib.request.Request(RULER_URL, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=20) as resp:
        payload = json.loads(resp.read())
    if payload.get("status") != "success":
        raise RuntimeError(f"ruler API answered {payload.get('status')!r}")
    groups: dict[str, list[str]] = {}
    stamp: int | None = None
    for group in payload["data"]["groups"]:
        groups.setdefault(group.get("file") or "?", []).append(group.get("name", "?"))
        if group.get("name") != CANARY_GROUP:
            continue
        for rule in group.get("rules") or []:
            raw = (rule.get("labels") or {}).get("canary_stamp")
            if raw:
                try:
                    stamp = int(raw)
                except ValueError:
                    stamp = None
    return groups, stamp


# --------------------------------------------------------------------- mattermost

def post(text: str) -> None:
    body = json.dumps({"text": text}).encode()
    req = urllib.request.Request(
        WEBHOOK,
        data=body,
        method="POST",
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        if resp.status != 200:
            raise RuntimeError(f"webhook answered HTTP {resp.status}")


def format_message(state: str, missing: dict[str, str], served_files: int, served_groups: int,
                   canary_age: int | None, note: str) -> str:
    if state == "ok":
        return (
            "**Loki rule delivery is live again**\n"
            f"- ruler serves {served_groups} rule groups from {served_files} rule files, all "
            "ConfigMaps labelled `loki_rule` are accounted for\n"
            f"- canary stamp {canary_age}s old (threshold {STALE_SECONDS}s)\n"
            "- checked by the `loki-rule-guard` CronJob from the ruler API, not the sidecar log"
        )
    if state == "unverified":
        lines = ["**Loki rule delivery cannot be verified**"]
        lines.append(
            "- the `loki-rule-guard` CronJob could not read one of its two sources, so nothing is "
            "proven either way; the Job is failing on purpose so this does not look green"
        )
    else:
        lines = ["**Loki rule delivery is broken**"]
    if missing:
        lines.append(
            f"- {len(missing)} rule file(s) labelled `loki_rule` are not served by the ruler: "
            + ", ".join(f"`{f}` (ConfigMap `{cm}`)" for f, cm in sorted(missing.items()))
        )
    if canary_age is not None and canary_age > STALE_SECONDS:
        lines.append(
            f"- canary stamp is {canary_age // 60} min old (threshold {STALE_SECONDS // 60} min): "
            "the sidecar in `loki-0` stopped writing `/rules/fake`"
        )
    if note:
        lines.append(f"- {note}")
    if state == "unverified":
        lines.append(
            "- check the Job's own log first: `kubectl -n observability logs job/$(kubectl -n "
            "observability get jobs -l app.kubernetes.io/name=loki-rule-guard "
            "--sort-by=.metadata.creationTimestamp -o name | tail -1 | cut -d/ -f2)`"
        )
        return "\n".join(lines)
    lines.append(
        f"- ruler serves {served_groups} rule groups from {served_files} rule files right now"
    )
    lines.append(
        "- Remedy: `kubectl -n observability rollout restart statefulset/loki` makes the sidecar "
        "do a full initial sync; the guard's next run must come back green."
    )
    return "\n".join(lines)


# ---------------------------------------------------------------------- main

def main() -> int:
    now = int(time.time())
    try:
        cm = load_canary()
    except Exception as err:  # noqa: BLE001 - any failure here means "cannot verify"
        log(f"ERROR cannot read or create the canary ConfigMap: {err}")
        return 2

    annotations = cm["metadata"].get("annotations") or {}
    first_seen = int(annotations.get("guard-first-seen", now))
    previous_state = annotations.get("guard-state", "unknown")
    notified_at = int(annotations.get("guard-notified-at", "0"))

    missing: dict[str, str] = {}
    note = ""
    state = "ok"
    canary_age: int | None = None
    groups: dict[str, list[str]] = {}
    stamp: int | None = None

    try:
        groups, stamp = ruler_rules()
    except Exception as err:  # noqa: BLE001
        state = "unverified"
        note = f"the ruler API could not be read ({type(err).__name__}: {err}) -- the guard failed, not the sidecar"
        log(f"ERROR {note}")

    if state == "ok":
        if stamp is None:
            if now - first_seen > STALE_SECONDS:
                state = "stale"
                note = f"the canary rule group `{CANARY_GROUP}` is not in the ruler at all"
            else:
                note = "canary still warming up (created less than one threshold ago)"
        else:
            canary_age = now - stamp
            if canary_age > STALE_SECONDS:
                state = "stale"

    if state == "ok":
        try:
            for key, cm_name in labelled_rule_files().items():
                if key == CANARY_KEY:
                    continue
                if key not in groups:
                    missing[key] = cm_name
        except Exception as err:  # noqa: BLE001
            state = "unverified"
            note = f"the ConfigMap list could not be read ({type(err).__name__}: {err})"
            log(f"ERROR {note}")
        if missing:
            state = "drift"

    served_files = len(groups)
    served_groups = sum(len(v) for v in groups.values())
    log(
        f"state={state} labelled_files={len(groups) - (1 if CANARY_KEY in groups else 0)} "
        f"served_files={served_files} served_groups={served_groups} "
        f"canary_age={canary_age} missing={sorted(missing)}"
    )
    if note:
        log(f"note: {note}")

    # ---- notify: on a state change, and every REMIND_SECONDS while broken
    should_notify = state != previous_state or (
        state != "ok" and now - notified_at > REMIND_SECONDS
    )
    delivered = True
    if should_notify and WEBHOOK:
        if state == "ok" and previous_state in ("ok", "unknown"):
            log("healthy and nothing to announce")
        else:
            text = format_message(state, missing, served_files, served_groups, canary_age, note)
            try:
                post(text)
                log(f"posted the {state} message to Mattermost")
            except Exception as err:  # noqa: BLE001
                delivered = False
                log(f"ERROR could not post the {state} message: {err}")
    elif should_notify and not WEBHOOK:
        delivered = False
        log("ERROR MATTERMOST_WEBHOOK_URL is empty, nothing can be delivered")

    if state == "ok" and previous_state == "ok":
        new_notified = notified_at
    else:
        new_notified = now if delivered else notified_at

    # The canary rewrite is what gives the ruler something to reload every run; the
    # annotations carry the guard's state so a restart does not re-page.
    new_annotations = {
        "guard-first-seen": str(first_seen),
        "guard-state": state,
        "guard-notified-at": str(new_notified),
        "guard-last-run": str(now),
    }
    try:
        save_canary(canary_rule(now), new_annotations)
    except Exception as err:  # noqa: BLE001
        log(f"ERROR could not rewrite the canary ConfigMap: {err}")
        return 2

    return 0 if delivered else 2


if __name__ == "__main__":
    sys.exit(main())
