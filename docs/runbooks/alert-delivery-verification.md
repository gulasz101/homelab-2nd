# Runbook: prove an alert actually reaches Mattermost

**Scope:** every `PrometheusRule` + `AlertmanagerConfig` pair in the cluster, and the Mattermost
incoming webhooks behind them.
**Not in scope:** Grafana-native alerting (abandoned 2026-07-31).

**Why this exists:** an alert that cannot page is worse than no alert, because we stop looking. Two
different defects both present as "the hook is dead", and only one of them is real:

1. **The label trap.** An `AlertmanagerConfig` whose labels do not match the Alertmanager CR's
   `alertmanagerConfigSelector` is never loaded. Nothing errors. The rule fires, the pod is green,
   the channel stays quiet. Seen on GUL-643 (`release=prometheus-stack` instead of
   `kube-prometheus-stack`); `scripts/check_alert_delivery.py` still finds one live instance of it.
2. **The client trap.** `https://chat.voitech.dev` sits behind Cloudflare, which answers **403** to
   Python's TLS fingerprint. A probe written with `requests` or `urllib` reports a perfectly healthy
   hook as dead. On GUL-712 that cost a false "Pi-hole alerts reach nobody" conclusion, and the
   follow-up ticket GUL-726 opened to repoint a webhook that had never been broken.

## Step 1: static audit (read-only, no messages sent)

```sh
scripts/check_alert_delivery.py -v
```

For every `AlertmanagerConfig` it checks:

- the labels against the Alertmanager CR's `alertmanagerConfigSelector`;
- the namespace against `alertmanagerConfigNamespaceSelector` (**null means only the Alertmanager's
  own namespace is loaded**; `{}` means all namespaces);
- that the config's receiver names appear in the operator-generated `alertmanager.yaml`
  (`alertmanager-<cr-name>-generated`, key `alertmanager.yaml.gz`);
- that the hook Secret and key it references exist.

Exit 1 lists every problem. A config that fails the label check is reported as *never loaded*, which
is the failure GUL-643 was.

## Step 2: probe the hooks (optional, posts one message per distinct hook)

```sh
scripts/check_alert_delivery.py --probe
```

The probe uses **curl**. That is the point of the script: curl gets `200` where Python gets `403`.
The URL is never printed, only its host, length and a sha256 prefix, which is enough to tell two
hooks apart and useless to anyone reading the log.

Reading status codes from a Mattermost incoming webhook:

| Response | Meaning |
| --- | --- |
| `200 ok` | hook is valid, message delivered |
| `400 web.incoming_webhook.decode.app_error` | hook reached, body was not a JSON or form payload with a `text` field |
| `400 web.incoming_webhook.general.app_error` | hook reached; payload had no usable `text` (also what a bogus token returns, so this one proves nothing) |
| `403` from Python, `200` from curl | Cloudflare TLS fingerprint block, **not** a dead hook |
| `404` | no such hook on this Mattermost |

## Step 3: prove delivery end to end with a real alert

Status codes are not delivery. Fire an alert in the target namespace and read the channel.

```sh
cat <<'EOF' > /tmp/throwaway-rule.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: delivery-proof
  namespace: <target-namespace>
  labels:
    release: prometheus-stack        # ruleSelector, NOT the alertmanagerConfigSelector
spec:
  groups:
    - name: delivery.proof
      rules:
        - alert: AlertDeliveryProof
          expr: vector(1)
          for: 0m
          labels:
            severity: warning
            namespace: <target-namespace>   # must equal the AlertmanagerConfig namespace
          annotations:
            summary: "throwaway delivery proof, delete this rule"
EOF
kubectl apply -f /tmp/throwaway-rule.yaml
```

Wait about two minutes (rule reload plus `group_wait: 30s`) and read the channel. Then **delete the
rule** and confirm it is gone:

```sh
kubectl delete -f /tmp/throwaway-rule.yaml
kubectl -n <target-namespace> get prometheusrule
```

Two labels are doing different jobs and mixing them up is a whole class of bug:

- `release: prometheus-stack` on the **PrometheusRule** is what the Prometheus CR's `ruleSelector`
  matches.
- `release: kube-prometheus-stack` on the **AlertmanagerConfig** is what the Alertmanager CR's
  `alertmanagerConfigSelector` matches.

## Step 4: read the message back (the evidence)

The read side has the same client trap: Python against the Mattermost API also gets `403`. Use curl.

```sh
set -a; . "$HERMES_HOME/.env"; set +a           # MATTERMOST_URL, MATTERMOST_TOKEN
curl -s -H "Authorization: Bearer $MATTERMOST_TOKEN" \
  "$MATTERMOST_URL/api/v4/channels/<channel-id>/posts?per_page=10" |
python3 -c 'import json,sys; d=json.load(sys.stdin); [print(p["create_at"], p["props"].get("attachments",[{}])[0].get("title"), "|", p["message"]) for p in sorted(d["posts"].values(), key=lambda x: x["create_at"])]'
```

A Slack-formatted alert arrives with `message` empty and the text inside `props.attachments[0]`:
`title` carries `[FIRING] <namespace>: N firing`, `text` carries the per-alert summary lines, and
`title_link` ends with the receiver that delivered it
(`...receiver=<namespace>%2F<config>%2F<receiver>`). That receiver string is the proof that the
route, not a default receiver, sent it.

## When the hook really is dead

Mint a new incoming webhook in the target channel, SOPS-encrypt it as a Secret in the **same
namespace as the AlertmanagerConfig** (the operator reads the secret, it is not mounted into the
pod), add the file to the namespace's `kustomization.yaml`, bump a pod-template annotation if a pod
consumes it, and reconcile. A hook that answers `404`, or `403` to a **curl** POST, is dead.

Never repoint a config on the strength of a Python probe.
