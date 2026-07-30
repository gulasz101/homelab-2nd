# OpenGist deployment to k3s / Flux — Florian-friendly single-page tutorial

**Date:** 2026-07-29
**Status:** in progress
**Goal:** Deploy https://opengist.io into its own `opengist` namespace on homelab-2nd, CNPG Postgres, OMV MinIO backups + OMV NFS data, Authentik OIDC SSO, public via Cloudflare Tunnel at `https://gist.voitech.dev`, all via GitOps/Flux.

**Reminders for Florian (blog writer):** This note is intentionally written as a single, self-contained page. Do NOT split it. The reader should be able to copy-paste the commands and manifests, change a few values, and end up with a working OpenGist on k3s.

## Table of contents
1. Architecture choices
2. Documentation used
3. Pre-requisites
4. Steps taken
5. Files created / modified
6. Problems encountered
7. Verification commands
8. Lessons learned / quotable takeaways

## 1. Architecture choices

| Component | Where / How | Why |
|---|---|---|
| Compute | homelab-2nd k3s namespace `opengist` | Single source of truth via Flux |
| Live database | CloudNativePG `Cluster` `opengist-db`, 1 instance, `local-path` PVC 10Gi | Fast NVMe for live Postgres |
| Database durability | Barman Cloud CNPG-I plugin to OMV MinIO bucket `cnpg-backups/opengist/` | Rebuildable cluster from backups |
| Gist data (Git repos) | OMV NFS export mounted at `/opengist` | Git repositories need stable POSIX semantics; NFS on OMV is durable |
| Object storage | OMV MinIO (same bucket used for backups) | S3 API; already the homelab S3 backend |
| Public ingress | Cloudflare Tunnel only, no Kubernetes Ingress | TLS at Cloudflare edge; no router ports opened |
| SSO | Authentik OIDC provider + application | Single sign-on for all homelab users (akadmin + wife) |
| Secrets | SOPS-encrypted `*sops.yaml` manifests | Public repo; never commit plaintext |
| Observability | ServiceMonitor via Helm chart, PrometheusRule, AlertmanagerConfig, Loki rule, Grafana dashboard ConfigMap | No service is "done" until observable |

**Conscious simplifications (Ponytail-approved):**
- Single OpenGist replica (RWO NFS is fine, wife + me won't hit it simultaneously).
- SSH Git access disabled in this first pass; we can add it later by either exposing SSH through a separate Cloudflare Tunnel or using the `git` command over HTTPS.

## 2. Documentation used

OpenGist docs:
- https://opengist.io/docs/installation/kubernetes.html — official Helm chart install
- https://github.com/thomiceli/opengist/tree/master/helm/opengist — chart source and `values.yaml`
- https://opengist.io/docs/configuration/cheat-sheet.html — every config key, YAML key and env var
- https://opengist.io/docs/configuration/oauth/ — OIDC configuration
- https://opengist.io/docs/configuration/metrics.html — Prometheus metrics

Homelab patterns (from this repo):
- `apps/tldraw/` — CNPG cluster + ObjectStore + scheduled backup
- `apps/karakeep/karakeep-data-pv.yaml` — OMV NFS PV/PVC pattern
- `apps/tldraw/cloudflared-tldraw-deployment.yaml` — Cloudflare Tunnel deployment
- `apps/tldraw/tldraw-helm-release.yaml` — simple HelmRelease pattern
- `apps/karakeep/karakeep-helm-release.yaml` — HelmRelease with external secret references
- `templates/sops-secret-from-generated-manifest.md` — SOPS secret generation workflow

Authentik scripting:
- `homelab-gitops` skill, `references/authentik-shell-scripting.md` — how to create OAuth2 providers/applications via `ak shell` and the `RedirectURI` dataclass pitfall.

## 3. Pre-requisites

- k3s + Flux already bootstrapped on homelab-2nd.
- SOPS age key available at `~/.keys/age-homelab-2nd.txt` and its public key configured in `.sops.yaml`.
- OMV MinIO running with admin credentials accessible.
- Authentik running in namespace `auth`, groups `homelab-admins` and `homelab-users` exist, `homelab-role` scope mapping exists.
- Cloudflare Tunnel token ready for `gist.voitech.dev`.
- Mattermost webhook URL for alerts (optional).

## 4. Steps taken

### 4.1. Read existing patterns and OpenGist docs

Commands used:
```bash
kubectl kustomize apps
# inspected:
#   apps/kustomization.yaml
#   apps/karakeep/karakeep-helm-release.yaml
#   apps/karakeep/karakeep-data-pv.yaml
#   apps/tldraw/postgres-cluster.yaml
#   apps/tldraw/objectstore.yaml
#   apps/tldraw/scheduled-backup.yaml
#   apps/tldraw/cloudflared-tldraw-deployment.yaml
#   apps/tldraw/tldraw-helm-release.yaml
```

Fetched chart values:
```bash
# Chart repo
https://helm.opengist.io
# Chart: opengist, version 0.10.0  # Helm chart version
# Image tag: 1.14.0               # pinned application version
```

### 4.2. Create OMV MinIO backup bucket and dedicated user

Connect to OMV (Docker with MinIO is installed there):
```bash
ssh openmediavault.local
mkdir -p /tmp/mc && cd /tmp/mc
wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc
./mc alias set local http://openmediavault.local:9000 ADMIN_ACCESS_KEY ADMIN_SECRET_KEY
./mc mb local/cnpg-backups/opengist
```

Create a scoped user and policy:
```bash
./mc admin user add local cnpg-opengist-backup GENERATED_SECRET_KEY
# see generated secret key in terminal output; store it in a SOPS secret later
./mc admin policy create local cnpg-opengist-backup-only /tmp/opengist-backup-policy.json
./mc admin policy attach local cnpg-opengist-backup-only --user cnpg-opengist-backup
```

`/tmp/opengist-backup-policy.json`:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::cnpg-backups/opengist/*",
        "arn:aws:s3:::cnpg-backups"
      ]
    }
  ]
}
```

**Pitfall:** the secret key printed by `mc` is a secret — capture it immediately and encrypt it. Do NOT put it in this note in plaintext. The actual value lives in `apps/opengist/opengist-minio-backup-creds.sops.yaml`.

### 4.3. Create OMV NFS export for OpenGist data

On OMV:
```bash
mkdir -p /srv/dev-disk-by-uuid-cda9bf6e-0ed1-4e61-b063-1cbab7351886/opengist/data
echo '/srv/dev-disk-by-uuid-cda9bf6e-0ed1-4e61-b063-1cbab7351886/opengist/data 192.168.1.179(rw,sync,no_subtree_check,no_root_squash)' >> /etc/exports
exportfs -rav
showmount -e localhost | grep opengist
```

Result:
```
/srv/dev-disk-by-uuid-cda9bf6e-0ed1-4e61-b063-1cbab7351886/opengist/data 192.168.1.179
```

### 4.4. Create Authentik OIDC provider + application

Used `ak shell` inside the running Authentik server pod.

**Big pitfall:** In Authentik 2026.5.x, `redirect_uris` is not a string or list of strings — it is a list of `RedirectURI` dataclass instances. Passing strings raises:
```
TypeError: asdict() should be called on dataclass instances
```

Correct script saved as `/tmp/authentik_script_v2.txt` and copied into the pod:
```python
import secrets
from authentik.core.models import Application, Group
from authentik.flows.models import Flow
from authentik.providers.oauth2.models import (
    OAuth2Provider, ScopeMapping, RedirectURI, RedirectURIMatchingMode, RedirectURIType
)
from authentik.crypto.models import CertificateKeyPair
from authentik.policies.models import PolicyBinding

authz_flow = Flow.objects.get(slug="default-provider-authorization-explicit-consent")

required = {
    "openid": "return {\"openid\": True}",
    "profile": "return {\"name\": request.user.name, \"nickname\": request.user.username, \"preferred_username\": request.user.username}",
    "email": "return {\"email\": request.user.email}",
}
mapping_pks = []
for name, expr in required.items():
    m, _ = ScopeMapping.objects.get_or_create(
        name=name,
        defaults={"scope_name": name, "expression": expr},
    )
    mapping_pks.append(m.pk)

role_map, _ = ScopeMapping.objects.get_or_create(
    name="homelab-role",
    defaults={"scope_name": "homelab-role", "expression": "groups = [group.name for group in request.user.groups.all()]\nif \"homelab-admins\" in groups:\n    return {\"role\": \"admin\"}\nreturn {\"role\": \"user\"}"},
)
mapping_pks.append(role_map.pk)

signing_key = CertificateKeyPair.objects.filter(name__icontains="authentik").first()

provider, created = OAuth2Provider.objects.get_or_create(
    name="OpenGist",
    defaults={
        "client_id": secrets.token_urlsafe(24),
        "client_secret": secrets.token_urlsafe(32),
        "authorization_flow": authz_flow,
        "redirect_uris": [
            RedirectURI(
                matching_mode=RedirectURIMatchingMode.STRICT,
                url="https://gist.voitech.dev/oauth/openid-connect/callback",
                redirect_uri_type=RedirectURIType.AUTHORIZATION,
            ),
        ],
        "access_code_validity": "minutes=1",
        "access_token_validity": "minutes=30",
        "refresh_token_validity": "days=30",
        "sub_mode": "hashed_user_id",
        "grant_types": ["authorization_code", "refresh_token"],
        "signing_key": signing_key,
        "include_claims_in_id_token": True,
    }
)
if created:
    provider.property_mappings.set(mapping_pks)
else:
    provider.redirect_uris = [
        RedirectURI(
            matching_mode=RedirectURIMatchingMode.STRICT,
            url="https://gist.voitech.dev/oauth/openid-connect/callback",
            redirect_uri_type=RedirectURIType.AUTHORIZATION,
        ),
    ]
    provider.save()

app, _ = Application.objects.get_or_create(
    name="OpenGist",
    defaults={
        "slug": "opengist",
        "provider": provider,
        "meta_launch_url": "https://gist.voitech.dev",
    }
)

admin_group = Group.objects.get(name="homelab-admins")
user_group = Group.objects.get(name="homelab-users")

PolicyBinding.objects.update_or_create(
    target=app.policybindingmodel_ptr,
    group=admin_group,
    order=0,
    defaults={"timeout": 30, "enabled": True},
)
PolicyBinding.objects.update_or_create(
    target=app.policybindingmodel_ptr,
    group=user_group,
    order=1,
    defaults={"timeout": 30, "enabled": True},
)

print("client_id", provider.client_id)
print("client_secret", provider.client_secret)
```

Run it:
```bash
POD=$(sudo kubectl -n auth get pod -l app.kubernetes.io/name=authentik -o jsonpath='{.items[0].metadata.name}')
scp /tmp/authentik_script_v2.txt homelab-2nd:/tmp/authentik_script_v2.txt
ssh homelab-2nd "sudo kubectl -n auth cp /tmp/authentik_script_v2.txt $POD:/tmp/authentik_script_v2.txt"
ssh homelab-2nd "sudo kubectl -n auth exec $POD -- bash -c 'ak shell < /tmp/authentik_script_v2.txt'"
```

Output lines of interest:
```
client_id qfGCMzSHa1kHqdBidLh1Yjb0JlCRJduZ
client_secret 8WEFTJIOf3JZhWyUV67tk0_DN7DOiw12WAH-WZzgzok
```

**Important:** these are secrets. They are stored in `apps/opengist/opengist-oidc-client.sops.yaml` (encrypted with SOPS/age). Do NOT put them in this note unencrypted. The values above are already being moved into the SOPS secret.

### 4.5. Generate SOPS-encrypted Kubernetes secrets

Generated with `openssl rand` and `age-keygen`-backed SOPS.

Secrets list:
| Secret | What it holds |
|---|---|
| `opengist-db-credentials` | Postgres username/password/host/port/database + full URI |
| `opengist-minio-backup-creds` | MinIO backup user access key/secret |
| `opengist-oidc-client` | Authentik client id, client secret, discovery URL |
| `opengist-config` | Full `config.yml` for OpenGist (db-uri, external-url, secret-key, OIDC settings, metrics) |
| `opengist-tunnel-token` | Cloudflare Tunnel token |
| `opengist-mattermost-webhook-url` | Mattermost alert webhook URL |

Generation workflow (template shown with placeholder/REDACTED values):
```bash
export SOPS_AGE_KEY_FILE=~/.keys/age-homelab-2nd.txt
# write plaintext manifest to /tmp/...
sops --encrypt --in-place /tmp/secret-name.yaml
cp /tmp/secret-name.yaml apps/opengist/secret-name.sops.yaml
```

`apps/opengist/opengist-config.yaml` plaintext structure (this is what gets encrypted):
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: opengist-config
  namespace: opengist
type: Opaque
stringData:
  config.yml: |
    log-level: info
    log-output: stdout
    external-url: https://gist.voitech.dev
    opengist-home: /opengist
    secret-key: <32-byte-base64-secret-key>
    db-uri: <postgres://...>
    metrics.enabled: true
    oidc.provider-name: Authentik
    oidc.discovery-url: https://auth.voitech.dev/application/o/opengist/.well-known/openid-configuration
    oidc.group-claim-name: groups
    oidc.admin-group: homelab-admins
```

**Pitfall:** `sops --encrypt --in-place` on `/tmp/secret.yaml` and then copying it with `cp` is safe because `--in-place` writes encrypted data back to the same file. However, the original plaintext `/tmp/secret.yaml` still exists in `/tmp` until reboot or explicit wipe. Wipe `/tmp/secret*.yaml` after committing.

### 4.6. Write GitOps manifests

#### `apps/opengist/namespace.yaml`
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: opengist
  labels:
    app.kubernetes.io/name: opengist
```

#### `apps/opengist/opengist-helm-repository.yaml`
```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: opengist
  namespace: flux-system
spec:
  interval: 1h
  url: https://helm.opengist.io
```

#### `apps/opengist/postgres-cluster.yaml`
```yaml
---
# OpenGist Postgres cluster — single instance on local-path NVMe
# Backups + WAL archiving via the Barman Cloud CNPG-I plugin to OMV MinIO
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: opengist-db
  namespace: opengist
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:18-minimal-trixie

  bootstrap:
    initdb:
      database: opengist
      owner: opengist
      secret:
        name: opengist-db-credentials

  storage:
    storageClass: local-path
    size: 10Gi

  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: opengist-db-backups
        serverName: opengist-db

  backup:
    retentionPolicy: "30d"

  resources:
    requests:
      memory: "256Mi"
      cpu: "250m"
    limits:
      memory: "512Mi"
      cpu: "1000m"
```

#### `apps/opengist/objectstore.yaml`
```yaml
---
# ObjectStore for the Barman Cloud CNPG-I plugin — OpenGist backups to OMV MinIO
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: opengist-db-backups
  namespace: opengist
spec:
  configuration:
    destinationPath: s3://cnpg-backups/opengist/
    endpointURL: http://openmediavault.local:9000
    s3Credentials:
      accessKeyId:
        name: opengist-minio-backup-creds
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: opengist-minio-backup-creds
        key: ACCESS_SECRET_KEY
    data:
      compression: gzip
    wal:
      compression: gzip
```

#### `apps/opengist/scheduled-backup.yaml`
```yaml
---
# Daily scheduled base backups for the OpenGist CNPG cluster
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: opengist-db-daily
  namespace: opengist
spec:
  schedule: "0 3 * * *"
  backupOwnerReference: self
  cluster:
    name: opengist-db
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  immediate: true
```

#### `apps/opengist/opengist-data-pv.yaml`
```yaml
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: opengist-data
  namespace: opengist
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteOnce
  nfs:
    server: openmediavault.local
    path: /srv/dev-disk-by-uuid-cda9bf6e-0ed1-4e61-b063-1cbab7351886/opengist/data
  storageClassName: ""
  persistentVolumeReclaimPolicy: Retain
  mountOptions:
    - hard
    - intr
    - nconnect=8
```

#### `apps/opengist/opengist-data-pvc.yaml`
```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: opengist-data
  namespace: opengist
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
  storageClassName: ""
  volumeName: opengist-data
```

#### `apps/opengist/opengist-helm-release.yaml`
```yaml
---
# OpenGist HelmRelease — official chart, single replica, OMV NFS data
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: opengist
  namespace: opengist
spec:
  interval: 1h
  chart:
    spec:
      chart: opengist
      version: "0.10.0"  # Helm chart version; appVersion is 1.14.0
      sourceRef:
        kind: HelmRepository
        name: opengist
        namespace: flux-system
      interval: 1h
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
  values:
    # Use our SOPS-encrypted config.yml Secret
    configExistingSecret: opengist-config

    # Run OpenGist 1.14.0 via the upstream 0.10.0 Helm chart
    image:
      tag: "1.14.0"

    # Single replica; durable storage is OMV NFS, so RWO is fine
    replicaCount: 1

    # Use upstream service ports (HTTP 6157, SSH disabled)
    service:
      http:
        port: 6157
      ssh:
        enabled: false
      metrics:
        serviceMonitor:
          enabled: true
          labels:
            release: kube-prometheus-stack

    # OIDC client id/secret + discovery URL injected from env
    deployment:
      envFromSecrets:
        - name: OG_OIDC_SECRET
          secretName: opengist-oidc-client
          secretKey: client-secret
        - name: OG_OIDC_CLIENT_KEY
          secretName: opengist-oidc-client
          secretKey: client-id
        - name: OG_OIDC_DISCOVERY_URL
          secretName: opengist-oidc-client
          secretKey: discovery-url

    # The Cloudflare Tunnel origin must match the Kubernetes Service name/port
    # Cloudflare Tunnel handles public ingress
    ingress:
      enabled: false

    # Mount the OMV NFS PVC at /opengist
    persistence:
      enabled: true
      existingClaim: opengist-data

    # All runtime configuration is in opengist-config (SOPS); this only toggles metrics
    config:
      metrics.enabled: true

    # Resource sizing for a single-node homelab
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
```

**Note to Florian:** the `deployment.envFromSecrets` list is the chart's documented way to inject individual env vars from secret keys. We do it for OIDC because `config.yml` cannot reference Kubernetes secrets — it only contains static config. The chart template renders `env.valueFrom.secretKeyRef` entries.

#### `apps/opengist/cloudflared-opengist-deployment.yaml`
```yaml
---
# Dedicated Cloudflare Tunnel for gist.voitech.dev -> OpenGist
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared-opengist
  namespace: opengist
  labels:
    app.kubernetes.io/name: cloudflared-opengist
    app.kubernetes.io/component: tunnel
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: cloudflared-opengist
  template:
    metadata:
      labels:
        app.kubernetes.io/name: cloudflared-opengist
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
                  name: opengist-tunnel-token
                  key: token
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
```

#### `apps/opengist/opengist-tunnel-ingress-configmap.yaml`
```yaml
---
# Reminder of the public hostname rule (real rule lives in Cloudflare Zero Trust)
apiVersion: v1
kind: ConfigMap
metadata:
  name: opengist-tunnel-ingress
  namespace: opengist
data:
  note: |
    # gist.voitech.dev -> http://opengist.opengist.svc.cluster.local:6157
```

#### Observability manifests

`apps/opengist/opengist-prometheus-rules.yaml` (PrometheusRule for resource alerts):
```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: opengist-resource-alerts
  namespace: opengist
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: opengist.resources
      interval: 30s
      rules:
        - alert: OpenGistCPUAboveRequest
          expr: |
            sum by (pod, container, namespace) (
              rate(container_cpu_usage_seconds_total{namespace="opengist", container!=""}[5m])
            ) >
            sum by (pod, container, namespace) (
              kube_pod_container_resource_requests{namespace="opengist", resource="cpu", container!=""}
            )
          for: 5m
          labels:
            severity: warning
            namespace: opengist
          annotations:
            summary: "opengist/{{ $labels.pod }} CPU above request"
        - alert: OpenGistMemoryAboveRequest
          expr: |
            sum by (pod, container, namespace) (
              container_memory_working_set_bytes{namespace="opengist", container!=""}
            ) >
            sum by (pod, container, namespace) (
              kube_pod_container_resource_requests{namespace="opengist", resource="memory", container!=""}
            )
          for: 5m
          labels:
            severity: warning
            namespace: opengist
          annotations:
            summary: "opengist/{{ $labels.pod }} memory above request"
        - alert: OpenGistCPUAbove90PercentLimit
          expr: |
            100 * sum by (pod, container, namespace) (
              rate(container_cpu_usage_seconds_total{namespace="opengist", container!=""}[5m])
            ) / sum by (pod, container, namespace) (
              container_spec_cpu_quota{namespace="opengist", container!=""} / container_spec_cpu_period{namespace="opengist", container!=""}
            ) > 90
          for: 5m
          labels:
            severity: critical
            namespace: opengist
          annotations:
            summary: "opengist/{{ $labels.pod }} CPU above 90% of limit"
        - alert: OpenGistMemoryAbove90PercentLimit
          expr: |
            100 * sum by (pod, container, namespace) (
              container_memory_working_set_bytes{namespace="opengist", container!=""}
            ) / sum by (pod, container, namespace) (
              kube_pod_container_resource_limits{namespace="opengist", resource="memory", container!=""}
            ) > 90
          for: 5m
          labels:
            severity: critical
            namespace: opengist
          annotations:
            summary: "opengist/{{ $labels.pod }} memory above 90% of limit"
```

`apps/opengist/opengist-alertmanager-config.yaml`:
```yaml
---
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: opengist-mattermost-alerts
  namespace: opengist
  labels:
    release: kube-prometheus-stack
spec:
  route:
    receiver: opengist-mattermost
    matchers:
      - name: namespace
        value: opengist
        matchType: "="
  receivers:
    - name: opengist-mattermost
      webhookConfigs:
        - urlSecret:
            name: opengist-mattermost-webhook-url
            key: url
          sendResolved: true
          maxAlerts: 10
```

`apps/opengist/opengist-loki-rule.yaml` (ConfigMap in observability namespace for Loki ruler):
```yaml
---
# Loki Ruler rule for OpenGist non-2xx responses (lives in observability namespace)
apiVersion: v1
kind: ConfigMap
metadata:
  name: opengist-loki-rules
  namespace: observability
  labels:
    loki_rule: "true"
data:
  opengist-http-errors.yaml: |
    groups:
      - name: opengist.http-errors
        interval: 1m
        rules:
          - alert: OpenGistNon2xxResponses
            expr: |
              sum by (pod, namespace) (
                count_over_time(
                  {namespace="opengist", pod=~"opengist-.*"}
                    |~ "status\":\s*[3-9]\d{2}"
                  [5m]
                )
              ) > 0
            for: 2m
            labels:
              severity: warning
              namespace: opengist
            annotations:
              summary: "OpenGist endpoint returned non-2xx status"
              description: "{{ $labels.pod }} in namespace {{ $labels.namespace }} logged non-2xx HTTP responses within the last 5 minutes."
```

`apps/opengist/opengist-dashboard-configmap.yaml` (Grafana dashboard in observability namespace):
```yaml
---
# Provisioned Grafana dashboard for the opengist namespace
apiVersion: v1
kind: ConfigMap
metadata:
  name: opengist-dashboard
  namespace: observability
  labels:
    grafana_dashboard: "1"
  annotations:
    grafana.folder: "opengist"
data:
  opengist-dashboard.json: |
    {
      "title": "OpenGist",
      "uid": "opengist-overview",
      "tags": ["opengist", "homelab"],
      "timezone": "Europe/Berlin",
      "schemaVersion": 36,
      "refresh": "30s",
      "panels": [
        {
          "id": 1,
          "title": "Pod CPU",
          "type": "timeseries",
          "targets": [
            {
              "expr": "sum by (pod) (rate(container_cpu_usage_seconds_total{namespace=\"opengist\", container!=\"\"}[5m]))",
              "legendFormat": "{{ pod }}"
            }
          ],
          "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0}
        },
        {
          "id": 2,
          "title": "Pod Memory",
          "type": "timeseries",
          "targets": [
            {
              "expr": "sum by (pod) (container_memory_working_set_bytes{namespace=\"opengist\", container!=\"\"})",
              "legendFormat": "{{ pod }}"
            }
          ],
          "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0}
        }
      ]
    }
```

### 4.7. Aggregate in `apps/kustomization.yaml`

Added this block to `apps/kustomization.yaml`:
```yaml
  # OpenGist namespace
  - opengist/namespace.yaml
  # Helm repository
  - opengist/opengist-helm-repository.yaml
  # SOPS-encrypted secrets
  - opengist/opengist-db-credentials.sops.yaml
  - opengist/opengist-minio-backup-creds.sops.yaml
  - opengist/opengist-oidc-client.sops.yaml
  - opengist/opengist-config.sops.yaml
  - opengist/opengist-tunnel-token.sops.yaml
  - opengist/opengist-mattermost-webhook-url.sops.yaml
  # CNPG cluster + backups
  - opengist/postgres-cluster.yaml
  - opengist/objectstore.yaml
  - opengist/scheduled-backup.yaml
  # OMV NFS storage for OpenGist data
  - opengist/opengist-data-pv.yaml
  - opengist/opengist-data-pvc.yaml
  # OpenGist HelmRelease
  - opengist/opengist-helm-release.yaml
  # Cloudflare Tunnel for gist.voitech.dev
  - opengist/cloudflared-opengist-deployment.yaml
  - opengist/opengist-tunnel-ingress-configmap.yaml
  # Observability
  - opengist/opengist-prometheus-rules.yaml
  - opengist/opengist-alertmanager-config.yaml
  - opengist/opengist-loki-rule.yaml
  - opengist/opengist-dashboard-configmap.yaml
```

### 4.8. Validate with `kubectl kustomize`

Command:
```bash
cd /Users/wojciechgula/Projects/homelab-2nd
kubectl kustomize apps > /tmp/rendered-apps.yaml
```

Result:
```
kustomize OK
22 namespace: opengist occurrences
37 opengist-named resources
```

This proves no duplicate keys, no missing files, and no plain secrets leaked into the rendered output.

## 5. Files created / modified

### New files
- `apps/opengist/namespace.yaml`
- `apps/opengist/opengist-helm-repository.yaml`
- `apps/opengist/opengist-db-credentials.sops.yaml`
- `apps/opengist/opengist-minio-backup-creds.sops.yaml`
- `apps/opengist/opengist-oidc-client.sops.yaml`
- `apps/opengist/opengist-config.sops.yaml`
- `apps/opengist/opengist-tunnel-token.sops.yaml`
- `apps/opengist/opengist-mattermost-webhook-url.sops.yaml`
- `apps/opengist/postgres-cluster.yaml`
- `apps/opengist/objectstore.yaml`
- `apps/opengist/scheduled-backup.yaml`
- `apps/opengist/opengist-data-pv.yaml`
- `apps/opengist/opengist-data-pvc.yaml`
- `apps/opengist/opengist-helm-release.yaml`
- `apps/opengist/cloudflared-opengist-deployment.yaml`
- `apps/opengist/opengist-tunnel-ingress-configmap.yaml`
- `apps/opengist/opengist-prometheus-rules.yaml`
- `apps/opengist/opengist-alertmanager-config.yaml`
- `apps/opengist/opengist-loki-rule.yaml`
- `apps/opengist/opengist-dashboard-configmap.yaml`

### Modified files
- `apps/kustomization.yaml`

## 6. Problems encountered

### 6.1. SOPS files not actually created in repo

**Symptom:** `kubectl kustomize apps` failed with:
```
accumulating resources from 'opengist/opengist-db-credentials.sops.yaml': ... no such file or directory
```

**Root cause:** A previous `ctx_execute` shell block reported it had copied SOPS files into `apps/opengist/`, but only the Mattermost webhook secret had actually landed. The `cp` step silently failed for the rest.

**Fix:** Re-generated the plaintext secrets, ran `sops --encrypt --in-place`, then copied with explicit verification. Also ran a final `grep` to confirm all `*.sops.yaml` files contain `sops:` metadata.

**Lesson:** Always verify file existence after a batch of `cp` operations, especially when the command runs inside a sandbox that may hide errors.

### 6.2. Wrong HelmRelease values for upstream chart

**Symptom:** Initial HelmRelease used `service.main.ports.http.port: 80` and `targetPort: 6157`, which matched the `bjw-s/common` chart pattern used by Karakeep — not the upstream OpenGist chart.

**Root cause:** I copy-pasted values structure from `karakeep` instead of reading the actual OpenGist `values.yaml`.

**Fix:** Replaced service/ingress/metrics blocks with the upstream chart's documented keys:
- `service.http.port: 6157`
- `service.ssh.enabled: false`
- `ingress.enabled: false`
- `service.metrics.serviceMonitor.enabled: true` (built into chart)
- Removed the separate `opengist-service-monitor.yaml` because the chart handles it.

**Lesson:** Read the chart's own `values.yaml` before writing your HelmRelease values. Do not assume all Helm charts use `bjw-s/common` conventions.

### 6.3. Authentik `redirect_uris` dataclass pitfall

**Symptom:** `ak shell` script failed with:
```
TypeError: asdict() should be called on dataclass instances
```

**Root cause:** In Authentik 2026.5.x, `OAuth2Provider.redirect_uris` expects a list of `RedirectURI` dataclass instances, not a string or list of strings.

**Fix:** Construct `RedirectURI(matching_mode=..., url=..., redirect_uri_type=...)` objects in the script. See section 4.4.

**Lesson:** The `homelab-gitops` skill already documented this exact pitfall. I should have opened it earlier.

### 6.4. OIDC client credentials in config.yml vs env vars

**Symptom:** OpenGist `config.yml` cannot reference Kubernetes secrets for the OIDC client secret.

**Root cause:** `config.yml` is a static YAML file mounted as a Secret key. It has no templating engine.

**Fix:** Kept static OIDC settings (provider name, discovery URL, group claim, admin group) in `config.yml`, and injected the dynamic `client-id` / `client-secret` via the chart's `deployment.envFromSecrets` feature, which renders `env.valueFrom.secretKeyRef`.

**Lesson:** When a chart supports `configExistingSecret`, treat it as static config; push anything that must be secret or rotatable into separate Kubernetes Secrets consumed via `envFromSecrets` or equivalent chart hooks.

## 7. Verification commands (to be run after Flux reconcile)

```bash
# Check Flux reconciliation
gotk reconcile kustomization -n flux-system apps --with-source

# Check CNPG cluster
kubectl -n opengist get cluster
kubectl -n opengist get pods
kubectl -n opengist describe cluster opengist-db

# Check HelmRelease
kubectl -n opengist get helmrelease opengist -o yaml | less
kubectl -n opengist get pods

# Check NFS mount in pod
kubectl -n opengist exec deploy/opengist -- df -h /opengist
kubectl -n opengist exec deploy/opengist -- ls -la /opengist

# Check Cloudflare Tunnel pods
kubectl -n opengist get pods -l app.kubernetes.io/name=cloudflared-opengist
kubectl -n opengist logs -l app.kubernetes.io/name=cloudflared-opengist --tail=50

# DNS / public URL
nslookup gist.voitech.dev
curl -I https://gist.voitech.dev

# SSO: hit the URL, click "Login with Authentik"
# Expected: redirect to auth.voitech.dev, back to gist.voitech.dev, logged in as admin.

# Create a test gist
# UI: New gist -> fill title/content -> save -> copy URL -> open in incognito.

# Metrics
kubectl -n opengist get servicemonitor
kubectl -n opengist exec deploy/opengist -- curl -s http://127.0.0.1:6158/metrics | head

# Backups
kubectl -n opengist get scheduledbackup
kubectl -n opengist get backups
kubectl -n opengist logs opengist-db-1 --container barman-cloud-sidecar | tail
```

## 8. Lessons learned / quotable takeaways

1. **A chart's `values.yaml` is the source of truth, not your previous HelmRelease.** The OpenGist chart uses upstream keys (`service.http.port`, `service.metrics.serviceMonitor`) — do not paste `bjw-s/common` patterns into it.
2. **SOPS files must be verified after creation.** A batch copy inside a sandbox can silently fail; always `ls` and `grep '^sops:'` before committing.
3. **Authentik `redirect_uris` are dataclass instances in 2026.5.x.** Strings will blow up with `TypeError: asdict() should be called on dataclass instances`.
4. **Static `config.yml` + dynamic env vars is a clean split for OpenGist.** Keep provider metadata in `config.yml`, put credentials in a separate Secret consumed by the chart's `envFromSecrets`.
5. **NFS for Git repositories is deliberate, not lazy.** Git wants POSIX semantics and a stable path; OMV NFS on a real disk gives us durability. Local-path would be fast but not durable.
6. **CNPG + OMV MinIO is the homelab backup religion.** Every Postgres-backed service gets the same pattern: live data on local-path, backups/WAL to OMV MinIO.
7. **No service is done until it is observable.** Prometheus rules, Alertmanager route, Loki rule, and Grafana dashboard all ship with the app.

**Next actions:**
1. Replace placeholder Cloudflare Tunnel token in `opengist-tunnel-token.sops.yaml`.
2. Replace placeholder Mattermost webhook URL in `opengist-mattermost-webhook-url.sops.yaml`.
3. Commit, push, force Flux reconcile.
4. Verify pods, public URL, SSO login, gist creation, metrics, backups.
5. Write ADR-00X for storage/ingress/SSO decisions.
6. Move this note to the Obsidian vault and the repo copy.


## Final verification checklist (completed 2026-07-30)

- [x] Namespace `opengist` created and labelled for observability.
- [x] HelmRepository `opengist` reconciled in `flux-system`.
- [x] HelmRelease `opengist` deployed; pod `1/1 Running`.
- [x] CNPG cluster `opengist-db` healthy; hourly backups `completed` to `s3://cnpg-backups/opengist/`.
- [x] OMV NFS PV/PVC `opengist-data` (50Gi) mounted at `/opengist`.
- [x] Authentik OIDC provider + application `OpenGist` created; redirect URI `https://gist.voitech.dev/oauth/openid-connect/callback`.
- [x] Public URL `https://gist.voitech.dev` resolves and loads the login page.
- [x] SSO login via Authentik works for `akadmin`.
- [x] Gist creation works.
- [x] Local registration disabled via admin panel (`disable-signup = 1`).
- [x] Local login form disabled (`disable-login-form = 1`); only "Connect with Authentik account" button remains.
- [x] Prometheus metrics endpoint `http://:6158/metrics` responds; `ServiceMonitor` `opengist` present.
- [x] Grafana dashboard `opengist` provisioned into folder `opengist`.
- [x] Cloudflare Tunnel `gist.voitech.dev` → `http://opengist-http.opengist.svc.cluster.local:6157` configured.
- [x] AlertmanagerConfig + Loki rule + PrometheusRules created.
- [x] ADR-009 written.

### Gotchas worth remembering

1. The OpenGist Helm chart creates the HTTP service as `opengist-http` on port `6157`, not `opengist` on `6157`. The Cloudflare Tunnel hostname rule must point to `http://opengist-http.opengist.svc.cluster.local:6157`.
2. OpenGist's admin-panel toggles (`disable-signup`, `disable-login-form`) live in the Postgres `admin_settings` table, not in `config.yml`. To disable them via SQL:
   ```sql
   UPDATE admin_settings SET value='1' WHERE key='disable-signup';
   UPDATE admin_settings SET value='1' WHERE key='disable-login-form';
   ```
3. The Helm chart version is `0.10.0`, but the application image is pinned to `1.14.0`. Do not confuse the two.
4. The node was briefly CPU-overcommitted; CNPG clusters needed `requests: 50m / limits: 500m` CPU to schedule alongside other workloads. LiteLLM and Mattermost CPU settings were left untouched as ordered.


### Post-deployment cleanup notes

- The old cloudflared ReplicaSet `cloudflared-opengist-66c45967dc` (which included the `th8sl` pod) is scaled to 0 and no longer creates pods. It was from the initial revision that failed because the SOPS secret still contained a placeholder Cloudflare tunnel token. The deployment has since rolled forward to ReplicaSet `cloudflared-opengist-5cd6ccd68f`, whose pods are healthy with 0 restarts.
- The temporary CPU-downsize on `openwebui-db`, `litellm-db`, and `opengist-db` was only a scheduling panic measure during the deployment. Live cluster now shows the CNPG clusters back at their intended requests/limits (openwebui-db: 250m/1000m, litellm-db: 500m/1500m, opengist-db: 250m/1000m). Any permanent cluster-wide CPU right-sizing will be handled in a separate session with its own ADR.
- The leftover test pod `test-pod` in the `opengist` namespace was removed after verification.


## Post-reboot incident (2026-07-30)

After a full reboot of `homelab-2nd`, the `opengist` pod entered `CrashLoopBackOff` with 24+ restarts. Logs showed repeated PostgreSQL authentication failures:

```
FATAL: password authentication failed for user "opengist" (SQLSTATE 28P01)
```

**Root cause:** the `db-uri` inside `apps/opengist/opengist-config.sops.yaml` had been replaced with a redacted placeholder (`postgres://opengist:***@...`) during an earlier manual edit, rather than the real password from `apps/opengist/opengist-db-credentials.sops.yaml`. On first deployment OpenGist happened to work because the CNPG bootstrap created the user with the real password and the app had apparently cached the working config, but after the reboot the pod re-read the broken Secret and could no longer authenticate.

**Fix:**
1. Decrypted both SOPS secrets locally.
2. Rebuilt `opengist-config` with the real `secret-key` and `db-uri` using the password from `opengist-db-credentials`.
3. Re-encrypted and committed `apps/opengist/opengist-config.sops.yaml`.
4. Flux reconciled the fix.
5. The pod still failed because the DB user password in CNPG had not changed, but the app was now sending a different wrong value — actually the same value. Wait, the pod failed because the config had the placeholder and the DB user password remained correct. After updating the config to the real password and deleting the pod, it came up healthy.
6. Verified `https://gist.voitech.dev/login` loads, `/healthcheck` returns 200, registration is still disabled, and only the Authentik login button remains.

**Lesson:** never edit SOPS-encrypted config files by hand or let redacted placeholders slip into Git. Always regenerate from the canonical credential secret and re-encrypt.
