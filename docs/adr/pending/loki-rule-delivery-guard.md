# ADR: Loki rule delivery is monitored as a pipeline, not as a pod

- **Status**: Pending
- **Date**: 2026-11-02
- **Issue**: GUL-805
- **Related**: GUL-783 (the rule that was dead on arrival), ADR-013 (mesh), the loki HelmRelease in `infrastructure/observability/loki-helm-release.yaml`

## Context

Loki is the precision tool in this homelab: provider-wall alerts, runner-session alerts and the
fleet-fallback alert all live in its ruler. Every one of them arrives through the same pipeline:

```
ConfigMap (label loki_rule, observability ns)
   -> loki-sc-rules sidecar in loki-0 (k8s-sidecar 2.8.0, WATCH) writes /rules/fake/<key>
      -> Loki ruler loads the directory (rule-sync-period ~1m) and evaluates it
```

On 2026-11-01 that sidecar stopped reacting to ConfigMap changes. Measured facts: no restart
(`restarts=0`, `startedAt 18:31:08`), last log line `18:36`, and the ruler kept serving the 31 rules
it had loaded that morning. The `LiteLLM1017ChainFellBack` rule merged in GUL-783 existed as a
ConfigMap and never reached `/rules`, so it was dead on arrival. Nothing said so. Every object read
green because every object *was* green — the broken part was a write that never happened.

The pod-restart signals cannot see this: the container never restarted, its liveness/health port was
answering, and it had not crashed. What was missing was a consumer for "the files stopped arriving".

## Decision

Treat rule delivery as a pipeline with a canary, and check it from the *outside* of the part that can
break.

1. **`loki-rule-guard` CronJob** (`observability`, every 5 minutes, delivered by Flux from
   `infrastructure/observability/loki-rule-guard/`). Each run:
   - rewrites a canary rule (`loki-rule-canary` ConfigMap, label `loki_rule`, rule group
     `observability.loki-rule-delivery-canary` whose `canary_stamp` label carries the epoch) — a rule
     change the sidecar MUST notice;
   - reads the ruler's own API (`/prometheus/api/v1/rules`) — never the sidecar's log, because the
     sidecar is the suspect;
   - compares **coverage** (every data key of every ConfigMap labelled `loki_rule` must appear as a
     rule-group `file` in the ruler's answer) and **freshness** (the canary stamp must be younger than
     15 minutes);
   - posts to Mattermost directly, on state change and every 6 h while broken, and once on recovery.
     State lives in the canary's annotations, so a guard restart does not re-page.

2. **The canary ConfigMap is runtime state, not a GitOps object.** The guard owns it. A ConfigMap
   that Flux also manages would be reverted to its committed (old) stamp on every reconcile, and the
   guard would read that revert as a stale delivery path. Deleting it is harmless: the next run
   recreates it under its own `create` permission.

3. **Prometheus carries the backstop, not the primary.** Two rules in
   `infrastructure/observability/loki-rule-guard/prometheus-rules.yaml`:
   - `LokiRuleReloadStalled` — `loki_ruler_config_last_reload_successful_seconds` frozen for 20 min
     **while** `loki_ruler_sync_rules_total{reason="periodic"}` keeps climbing (the ruler is polling,
     so the ruler is fine) **and** the guard ran in the last 15 min (so the canary was rewritten).
     That triple condition is the wedge signature, measured, not assumed: on a healthy ruler the
     periodic-sync counter ticks about once a minute while the reload timestamp sits still for an
     hour when nothing rewrites a file.
   - `LokiRuleGuardNotRunning` — no successful guard run for 30 min, because a dead detector is the
     original bug wearing a different hat.
   Routed to Mattermost through an `AlertmanagerConfig` matching `alertgroup=loki-rule-guard`.

4. **Two delivery paths on purpose.** The guard posts directly; the Prometheus backstop goes through
   Alertmanager. A detector whose message depends on the alerting hop cannot report a broken alerting
   hop. Overlap is avoided by threshold (guard 15 min, Prometheus 20 min) rather than by hope.

5. **The Prometheus/OTel rule path is not the same mechanism and needs no guard.** Prometheus rules
   are `PrometheusRule` CRs applied directly by the Prometheus Operator; there is no sidecar writing
   files and no second hop to wedge. The equivalent failure (the operator failing to regenerate the
   config) is covered by `prometheus_config_last_reload_successful`, which is a genuinely different
   signal and already exists.

## Consequences

- A merged Loki rule that never reaches the ruler is reported in Mattermost within ~15 minutes
  instead of never. A rule ConfigMap landing with no rule group is reported at the next run (≤5 min).
- One extra CronJob pod every 5 minutes in `observability`, ~10 mCPU and 32 MiB for a few seconds, plus
  one small ConfigMap write per run. The ConfigMap write also gives the ruler a rule change to reload
  every cycle, so "rule files were reloaded" becomes a live signal rather than a monthly accident.
- The guard is now a single point of detection, so it carries its own watchdog
  (`LokiRuleGuardNotRunning`) and fails its Job (exit 2) when it cannot verify, rather than logging a
  green line.
- The canary rule group is visible in the ruler's rule list (`observability.loki-rule-delivery-canary`).
  It is deliberately inert: `expr: vector(0) > 1` has no series, so it cannot fire.

## Alternatives

- **Alert on `kube_pod_container_status_restarts_total`** — useless here, and measured useless: the
  sidecar did not restart. It also cannot fire while the pod is healthy-but-wedged.
- **Alert on `loki_ruler_rules` / rule count** — the count is stable when a *new* rule is missing and
  the old ones keep being served; it only moves when a rule is added or removed, which is exactly the
  event that can be swallowed. It cannot distinguish "nothing merged" from "merge did not arrive".
- **Read `/rules/fake` inside `loki-0` and compare with the ConfigMaps** — detects the wedge but not
  whether the ruler loaded what was written; and it needs an exec into the pod that may itself be the
  broken thing. The ruler API is the consumer's own statement of truth.
- **A Prometheus scrape of the sidecar's health port** — the port answered throughout the incident.
- **Make the sidecar's health probe stricter** — the health endpoint is a process check; the failure
  was a stalled watch loop, not a dead process. Nothing probeable from inside changed.

## When to revisit

- If the sidecar is upgraded (k8s-sidecar > 2.8.0) and the wedge turns out to be a fixed upstream bug,
  the guard stays: it is also the check that a *new* rule ConfigMap is served at all.
- If Loki moves to a multi-replica ruler or a real rule store (S3-backed ruler instead of the local
  directory), the coverage comparison has to read the same store the ruler reads, and this ADR's
  "file" comparison becomes a "rule group" comparison.
- If a second tenant appears, `CANARY_GROUP` and the file map are per-tenant and need one guard run
  per tenant.
