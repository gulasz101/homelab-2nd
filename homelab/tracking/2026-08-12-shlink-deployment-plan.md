---
date: 2026-08-12
tags:
  - homelab
  - shlink
  - url-shortener
  - deployment-plan
  - cloudflare-tunnel
  - cnpg
  - flux
  - observability
  - lgtm
  - sso
---

# Shlink e2e deployment plan (blog-ready)

## TL;DR

Deploy [Shlink](https://shlink.io) v5.1.5 as a new public-facing URL shortener at `short.voitech.dev` using GitOps. The app is API-key-only, so SSO is impossible in the app core; we will gate the **admin interface** behind Authentik later via an OAuth2 proxy, while keeping short URL redirects public. Observability follows the established OpenGist pattern: Prometheus rules, Alertmanager → Mattermost, Loki error rule, and a namespace Grafana dashboard.

## The "before" state

The homelab already runs a handful of public services behind per-service Cloudflare Tunnels, each with CNPG Postgres, SOPS secrets, and LGTM observability. We needed a simple URL shortener that fits the same GitOps assembly line without inventing a new storage story.

## The "after" state

A Flux-managed `shlink` namespace containing:
- Shlink backend `5.1.5` from the `christianhuth/shlink-backend` Helm chart.
- A dedicated CNPG Postgres cluster `shlink-db` on `local-path` (live) with backups + WAL archive to OMV MinIO (durable).
- SOPS-encrypted secrets for DB, MinIO backups, Cloudflare tunnel token, initial API key, and Mattermost alert webhook.
- A dedicated Cloudflare Tunnel for `short.voitech.dev`.
- LGTM/OTel observability wired in from day one.
- SSO deferred to an external auth layer in front of the admin UI.

## Why Shlink

- Mature self-hosted URL shortener with REST API and an official web client.
- Stateless container; all durability lives in Postgres or object storage.
- Fits the homelab "one service, one DB, one tunnel, one set of alerts" pattern.
- Good blog material: demonstrates how to deploy an app that has no native SSO without breaking the homelab SSO-first posture.

## What we learned from the docs

Indexed `https://shlink.io/documentation/` into the homelab docs-mcp-server as library `shlink` (scrape job `4d34a71c-0260-4175-96a8-181bf965f58e`, completed 2026-08-12).

Key findings:

- **No native SSO/OIDC.** GitHub issue `shlinkio/shlink#1983` is still open as of v5.1.5. The application authenticates via API keys only.
- **Database:** external Postgres strongly recommended; SQLite is only for testing.
- **Runtime:** Docker image uses RoadRunner, so background tasks (GeoLite download, visit geolocation) run inside the container. No separate CronJob required.
- **Reverse proxy:** must forward `Host`, `X-Forwarded-For`, and `X-Forwarded-Proto`. `TRUSTED_PROXIES` must be configured so Shlink sees real visitor IPs.
- **Health:** `/rest/health` requires no authentication.
- **Metrics:** Shlink does **not** expose Prometheus-format app metrics. We only get `/rest/health` + kubelet/container metrics.
- **Web client:** can be hosted at `https://app.shlink.io` and pointed at our public API, or self-hosted. For the first deployment we will use the hosted client.
- **GeoLite2:** own MaxMind license key is basically mandatory for visit geolocation; without it, locations show "unknown".

## Architecture decisions

| Decision | Choice | Rationale |
|---|---|---|
| Database | CNPG Postgres, single instance | Homelab guardrail #3. `local-path` for live data, MinIO for backups. |
| Chart | `christianhuth/shlink-backend` | No official Shlink Helm chart. This one is a thin wrapper around the Deployment. |
| Image tag | `5.1.5` | Latest stable at evaluation time. |
| Persistence | None in the chart | Shlink data is in Postgres; the chart's default is no PVC. |
| Web client | Hosted `app.shlink.io` | Avoids running another pod for a pure UI. We can self-host later if needed. |
| SSO | Deferred to external proxy | App core has no SSO. We will put an OAuth2 proxy in front of the admin UI path later. |
| Public ingress | Dedicated Cloudflare Tunnel | Homelab guardrail #8. |

## Namespace and identity

- **Namespace:** `shlink`
- **Public hostname (proposed):** `short.voitech.dev`
- **Internal service:** `http://shlink-backend.shlink.svc.cluster.local:8080` (port matches chart default)
- **Cloudflare Tunnel name:** `shlink`

## Database — CloudNativePG

`postgres-cluster.yaml`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: shlink-db
  namespace: shlink
spec:
  instances: 1
  bootstrap:
    initdb:
      database: shlink
      owner: shlink
      secret:
        name: shlink-db-credentials
  storage:
    size: 5Gi
    storageClass: local-path
  backup:
    barmanObjectStore:
      destinationPath: s3://cnpg-backups/shlink/
      endpointURL: http://openmediavault.local:9000
      s3Credentials:
        accessKeyId:
          name: shlink-minio-backup-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: shlink-minio-backup-creds
          key: ACCESS_SECRET_KEY
      wal:
        compression: gzip
      data:
        compression: gzip
  scheduledBackup:
    - name: daily-backup
      schedule: "0 3 * * *"
      backupOwnerReference: self
```

`objectstore.yaml`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ObjectStore
metadata:
  name: shlink-db-backups
  namespace: shlink
spec:
  configuration:
    barmanObjectStore:
      destinationPath: s3://cnpg-backups/shlink/
      endpointURL: http://openmediavault.local:9000
      s3Credentials:
        accessKeyId:
          name: shlink-minio-backup-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: shlink-minio-backup-creds
          key: ACCESS_SECRET_KEY
      wal:
        compression: gzip
      data:
        compression: gzip
```

`scheduled-backup.yaml`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: shlink-db-daily
  namespace: shlink
spec:
  schedule: "0 3 * * *"
  backupOwnerReference: self
  cluster:
    name: shlink-db
```

## Secrets (SOPS-encrypted age)

| File | Purpose | Key names |
|---|---|---|
| `shlink-db-credentials.sops.yaml` | CNPG initdb + chart DB password | `username`, `password`, `database`, `database-password` |
| `shlink-minio-backup-creds.sops.yaml` | CNPG → OMV MinIO | `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY` |
| `shlink-tunnel-token.sops.yaml` | Cloudflare Tunnel token | `token` |
| `shlink-initial-api-key.sops.yaml` | First admin API key | `INITIAL_API_KEY` |
| `shlink-mattermost-webhook-url.sops.yaml` | Alertmanager webhook | `url` |

## HelmRelease

`shlink-helm-release.yaml`:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: shlink-backend
  namespace: shlink
spec:
  interval: 1h
  chart:
    spec:
      chart: shlink-backend
      version: "11.8.0"
      sourceRef:
        kind: HelmRepository
        name: christianhuth
        namespace: flux-system
      interval: 1h
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
  values:
    replicaCount: 1
    image:
      tag: "5.1.5"
      pullPolicy: IfNotPresent
    service:
      type: ClusterIP
      port: 8080
    ingress:
      enabled: false
    podAnnotations:
      prometheus.io/scrape: "true"
      prometheus.io/port: "8080"
      prometheus.io/path: "/rest/health"
    resources:
      requests:
        cpu: 50m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi
    config:
      database:
        driver: postgres
        host: shlink-db-rw.shlink.svc.cluster.local
        port: 5432
        auth:
          database: shlink
          username: shlink
          existingSecret: shlink-db-credentials
      general:
        defaultDomain: short.voitech.dev
        isHttpsEnabled: true
        memoryLimit: "512M"
        timezone: "Europe/Berlin"
      geolite:
        licenseKey: ""   # disable until a MaxMind key is provided
        skipInitialDownload: true
      urlShortening:
        autoResolveTitles: true
        defaultShortCodesLength: 5
    extraEnv:
      - name: TRUSTED_PROXIES
        value: "172.16.0.0/12,10.0.0.0/8,192.168.0.0/16"
      - name: INITIAL_API_KEY
        valueFrom:
          secretKeyRef:
            name: shlink-initial-api-key
            key: INITIAL_API_KEY
```

`shlink-helm-repository.yaml`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: christianhuth
  namespace: flux-system
spec:
  interval: 1h
  url: https://charts.christianhuth.de
```

## Cloudflare Tunnel

`cloudflared-shlink-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared-shlink
  namespace: shlink
  labels:
    app.kubernetes.io/name: cloudflared-shlink
    app.kubernetes.io/component: tunnel
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: cloudflared-shlink
  template:
    metadata:
      labels:
        app.kubernetes.io/name: cloudflared-shlink
        app.kubernetes.io/component: tunnel
    spec:
      containers:
        - name: cloudflared
          image: cloudflare/cloudflared:latest
          args:
            - tunnel
            - --no-autoupdate
            - run
            - --token
            - $(TUNNEL_TOKEN)
          env:
            - name: TUNNEL_TOKEN
              valueFrom:
                secretKeyRef:
                  name: shlink-tunnel-token
                  key: token
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
```

`shlink-tunnel-ingress-configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: shlink-tunnel-ingress
  namespace: shlink
data:
  public-hostname: "short.voitech.dev"
  origin: "http://shlink-backend.shlink.svc.cluster.local:8080"
  note: "Configure this origin in Cloudflare Zero Trust -> Networks -> Tunnels -> shlink"
```

## Observability (LGTM)

### Logs

Container stdout/stderr is automatically collected by the OpenTelemetry Collector DaemonSet and shipped to Loki. No extra config needed.

### Metrics

Shlink has no Prometheus `/metrics` endpoint. We scrape what we can:

- Pod annotation `prometheus.io/scrape: "true"`, port `8080`, path `/rest/health`.
- This gives us `up{}`, container CPU/memory metrics, and request latency from cAdvisor/OTel.

`shlink-prometheus-rules.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: shlink-resource-alerts
  namespace: shlink
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: shlink.resources
      interval: 30s
      rules:
        - alert: ShlinkCPUAboveRequest
          expr: |
            sum by (pod, container, namespace) (
              rate(container_cpu_usage_seconds_total{namespace="shlink", container!=""}[5m])
            ) >
            sum by (pod, container, namespace) (
              kube_pod_container_resource_requests{namespace="shlink", resource="cpu", container!=""}
            )
          for: 5m
          labels:
            severity: warning
            namespace: shlink
          annotations:
            summary: "shlink/{{ $labels.pod }} CPU above request"
        - alert: ShlinkMemoryAboveRequest
          expr: |
            sum by (pod, container, namespace) (
              container_memory_working_set_bytes{namespace="shlink", container!=""}
            ) >
            sum by (pod, container, namespace) (
              kube_pod_container_resource_requests{namespace="shlink", resource="memory", container!=""}
            )
          for: 5m
          labels:
            severity: warning
            namespace: shlink
          annotations:
            summary: "shlink/{{ $labels.pod }} memory above request"
        - alert: ShlinkCPUAbove90PercentLimit
          expr: |
            100 * sum by (pod, container, namespace) (
              rate(container_cpu_usage_seconds_total{namespace="shlink", container!=""}[5m])
            ) / sum by (pod, container, namespace) (
              container_spec_cpu_quota{namespace="shlink", container!=""} / container_spec_cpu_period{namespace="shlink", container!=""}
            ) > 90
          for: 5m
          labels:
            severity: critical
            namespace: shlink
          annotations:
            summary: "shlink/{{ $labels.pod }} CPU above 90% of limit"
        - alert: ShlinkMemoryAbove90PercentLimit
          expr: |
            100 * sum by (pod, container, namespace) (
              container_memory_working_set_bytes{namespace="shlink", container!=""}
            ) / sum by (pod, container, namespace) (
              kube_pod_container_resource_limits{namespace="shlink", resource="memory", container!=""}
            ) > 90
          for: 5m
          labels:
            severity: critical
            namespace: shlink
          annotations:
            summary: "shlink/{{ $labels.pod }} memory above 90% of limit"
```

### Alerts → Mattermost

`shlink-alertmanager-config.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: shlink-mattermost-alerts
  namespace: shlink
  labels:
    release: kube-prometheus-stack
spec:
  route:
    receiver: shlink-mattermost
    matchers:
      - name: namespace
        value: shlink
        matchType: "="
  receivers:
    - name: shlink-mattermost
      webhookConfigs:
        - urlSecret:
            name: shlink-mattermost-webhook-url
            key: url
          sendResolved: true
          maxAlerts: 10
```

### Loki error rule

`shlink-loki-rule.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: shlink-loki-rules
  namespace: observability
  labels:
    loki_rule: "true"
data:
  shlink-http-errors.yaml: |
    groups:
      - name: shlink.http-errors
        interval: 1m
        rules:
          - alert: ShlinkNon2xxResponses
            expr: |
              sum by (pod, namespace) (
                count_over_time(
                  {namespace="shlink", pod=~"shlink-backend-.*"}
                    |~ "status\":\\s*[3-9]\\d{2}"
                  [5m]
                )
              ) > 0
            for: 2m
            labels:
              severity: warning
              namespace: shlink
            annotations:
              summary: "Shlink endpoint returned non-2xx status"
              description: "{{ $labels.pod }} in namespace {{ $labels.namespace }} logged non-2xx HTTP responses within the last 5 minutes."
```

### Grafana dashboard

A per-namespace dashboard will be added as a ConfigMap in `observability` with label `grafana_dashboard: "1"`, following the OpenGist dashboard pattern. It will show CPU/memory for the `shlink-backend` and `cloudflared-shlink` pods plus a Loki logs panel.

## SSO — the hard truth

Shlink core does **not** support OIDC/SSO. The only authentication mechanism is API keys.

### What that means for security

- The public API endpoints (`/rest/v3/*`) and short URL redirects must remain public.
- The web admin UI (`app.shlink.io` or self-hosted) only needs an API key. If that key leaks, an attacker has full admin access.
- Therefore the admin UI must not be exposed directly to the internet.

### Recommended approach: gate the admin UI with OAuth2 Proxy

Phase 1 (this deployment): use the hosted web client at `https://app.shlink.io` only from trusted networks / Tailscale, and keep the API key in 1Password.

Phase 2 (follow-up): deploy an OAuth2 Proxy sidecar/ingress in front of a self-hosted `shlink-web-client` at a separate hostname (e.g. `shlink-admin.voitech.dev`) with Authentik OIDC. The proxy enforces login; the web client then uses the pre-configured API key from `servers.json`. Public short URLs stay on `short.voitech.dev` and bypass auth.

This keeps the homelab SSO-first posture without fighting Shlink's architecture.

## Verification plan

After Flux reconciles:

1. `kubectl get pods -n shlink`
2. `kubectl logs -n shlink deploy/shlink-backend`
3. Internal health check:
   ```bash
   kubectl exec -n shlink deploy/shlink-backend -- curl -s http://localhost:8080/rest/health
   ```
4. Public health check:
   ```bash
   curl -s https://short.voitech.dev/rest/health
   ```
5. Create a short URL:
   ```bash
   curl -s -X POST https://short.voitech.dev/rest/v3/short-urls \
     -H "X-Api-Key: <key>" \
     -H "Content-Type: application/json" \
     -d '{"longUrl":"https://example.com","title":"test"}'
   ```
6. Visit the returned short URL and confirm redirect + visit stats.

## Open questions for the Supreme Leader

1. Confirm public hostname: `short.voitech.dev`?
2. Provide Cloudflare Tunnel token once the tunnel is created.
3. Do you want a MaxMind GeoLite2 license key for visit geolocation?
4. Should I generate the initial admin API key and store it in 1Password + SOPS, or leave it empty and generate manually?

## File manifest to add

Under `apps/shlink/`:

- `namespace.yaml`
- `shlink-helm-repository.yaml`
- `shlink-helm-release.yaml`
- `postgres-cluster.yaml`
- `objectstore.yaml`
- `scheduled-backup.yaml`
- `shlink-db-credentials.sops.yaml`
- `shlink-minio-backup-creds.sops.yaml`
- `shlink-tunnel-token.sops.yaml`
- `shlink-tunnel-ingress-configmap.yaml`
- `cloudflared-shlink-deployment.yaml`
- `shlink-initial-api-key.sops.yaml`
- `shlink-mattermost-webhook-url.sops.yaml`
- `shlink-alertmanager-config.yaml`
- `shlink-prometheus-rules.yaml`
- `shlink-loki-rule.yaml`
- `shlink-dashboard-configmap.yaml`

And update `apps/kustomization.yaml` to include the new directory.

## Resource footprint estimate

| Component | CPU request/limit | Memory request/limit | Storage |
|---|---|---|---|
| Shlink backend | 50m / 500m | 256Mi / 512Mi | none |
| CNPG Postgres | 250m / 1 | 512Mi / 1Gi | 5Gi local-path |
| Cloudflared | 50m / 200m | 64Mi / 128Mi | none |

Total live PVC: 5Gi on homelab-2nd. Durable backups: OMV MinIO.

## Risks and gotchas

- **No SSO in app core.** Phase 2 OAuth2 proxy required for admin UI security.
- **API key is the only admin credential.** Must be stored in SOPS + 1Password; never logged.
- **GeoLite2 license key needed** for meaningful visit stats.
- **TRUSTED_PROXIES must be set** or every visit will appear to come from the Cloudflare/tunnel IP range.
- **DEFAULT_DOMAIN + IS_HTTPS_ENABLED** must match the public hostname; otherwise generated short URLs are wrong.
- **DB secret key mismatch:** the chart expects `database-password`, CNPG initdb expects `password`. We will include both in the same secret.
- **No Prometheus app metrics.** Dashboard and alerts rely on container/kube metrics; this is a known limitation.

## Next step

Supreme Leader: confirm `short.voitech.dev` and paste the Cloudflare Tunnel token. I will generate the secrets, commit the manifests, and deploy via Flux.
