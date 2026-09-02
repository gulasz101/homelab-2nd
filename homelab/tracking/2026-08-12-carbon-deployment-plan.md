# Carbon code-screenshot self-host deployment plan

**Date:** 2026-08-12
**Status:** Plan / awaiting approval
**Service:** Carbon code-image generator
**Upstream:** https://github.com/carbon-app/carbon
**Pragmatic self-host target:** `petersolopov/carbonara` (API that renders code screenshots using Puppeteer + Chromium)
**Proposed namespace:** `carbon`
**Proposed public URL:** `https://carbon.voitech.dev`

---

## 1. Goal

Give the homelab a working, GitOps-managed Carbon-like code-screenshot service that:

- Accepts a POST with code and styling params and returns a PNG/SVG.
- Is reachable publicly via Cloudflare Tunnel on `carbon.voitech.dev`.
- Needs no database and no durable storage.
- Follows the homelab guardrails: Flux, SOPS, observability, no plaintext secrets.

## 2. What we found upstream

The repo the Supreme Leader linked — `carbon-app/carbon` — is the Next.js application behind `https://carbon.now.sh`. It is designed to run on Vercel, not as a container:

- No `Dockerfile`, no `docker-compose.yml`, no Helm chart, no Kubernetes examples.
- `package.json` exposes `next build` / `next start` on port `3000`.
- The image-export API (`pages/api/image`) depends on `chrome-aws-lambda` + `puppeteer-core`. That combination is built for AWS Lambda and does **not** work out of the box in a generic container without code changes.
- Saved snippets and login use Firebase, so a self-hosted full editor would also lose snippet persistence unless we re-implemented storage.

In other words, deploying the literal `carbon-app/carbon` repo in k3s means building and maintaining our own container image, patching the screenshot backend, and accepting that user accounts/saved snippets will not work. That is a lot of moving parts for a tool whose main feature is "make a pretty picture of code".

## 3. Pragmatic decision: use `petersolopov/carbonara`

`carbonara` is a small, MIT-licensed community API for Carbon. It takes a JSON or multipart POST on `/api/cook` and returns a code image. It already ships a working Dockerfile based on `node:18-alpine3.17` with Chromium installed and Puppeteer configured.

**Why this is the right first step:**

- It solves the actual need (generate code images) without re-implementing the upstream app.
- It is stateless: no Postgres, no PVC, no backups, no database guardrail concerns.
- It is resource-light enough for `homelab-2nd` (single pod, ~512Mi–1Gi memory).
- It can be deployed with raw Kubernetes manifests (no Helm chart exists, but this is a simple enough stack that a `Deployment` + `Service` + `Cloudflared` is cleaner than wrapping a one-off chart).

**Trade-off:** `carbonara` is an API, not the full Carbon editor UI. If the Supreme Leader later wants the interactive editor, we will need a separate Phase 2 to containerize `carbon-app/carbon` itself. This plan explicitly scopes that out.

*I asked which path to take and got no answer within 10 minutes, so I am documenting the pragmatic path. Switching to the full editor is a documented future option, not a hidden shortcut.*

## 4. Proposed architecture

```
Internet ──► Cloudflare edge (TLS) ──► cloudflared pod (carbon namespace)
                                          │
                                          ▼
                              http://carbon.carbon.svc.cluster.local:3000
                                          │
                                          ▼
                              carbonara Deployment / Pod
                              (Node + Chromium, port 3000)
```

- **Compute:** `homelab-2nd` k3s, namespace `carbon`.
- **Storage:** none. The pod is stateless.
- **Database:** none.
- **Ingress:** dedicated Cloudflare Tunnel, public hostname `carbon.voitech.dev` → internal service `carbon.carbon.svc.cluster.local:3000`.
- **Secrets:** one SOPS-encrypted Secret for the Cloudflare tunnel token.
- **Observability:** container logs → OpenTelemetry Collector → Loki; cadvisor/kubelet CPU/memory metrics → Prometheus; namespace-scoped `PrometheusRule` for resource alerts; `AlertmanagerConfig` to route to Mattermost; provisioned Grafana dashboard in folder `carbon`.

## 5. Files to add to the repo

All under `apps/carbon/` (new directory). None of them are added to `apps/kustomization.yaml` until the plan is approved, so Flux will ignore them during review.

| File | Purpose |
|---|---|
| `apps/carbon/namespace.yaml` | Create `carbon` namespace |
| `apps/carbon/carbon-deployment.yaml` | Run `petersolopov/carbonara` container |
| `apps/carbon/carbon-service.yaml` | ClusterIP service on port 3000 |
| `apps/carbon/carbon-tunnel-token.sops.yaml` | SOPS-encrypted Cloudflare tunnel token |
| `apps/carbon/cloudflared-carbon-deployment.yaml` | Cloudflare Tunnel pod |
| `apps/carbon/carbon-tunnel-ingress-configmap.yaml` | Reminder of the public hostname rule |
| `apps/carbon/carbon-prometheus-rules.yaml` | CPU/memory alerts |
| `apps/carbon/carbon-alertmanager-config.yaml` | Route carbon alerts to Mattermost |
| `apps/carbon/carbon-loki-rule.yaml` | HTTP error / crash log alerts |
| `apps/carbon/carbon-dashboard-configmap.yaml` | Provisioned Grafana dashboard |

After approval, add these lines to `apps/kustomization.yaml`:

```yaml
  # Carbon namespace
  - carbon/namespace.yaml
  # SOPS-encrypted secrets
  - carbon/carbon-tunnel-token.sops.yaml
  # Carbonara API deployment + service
  - carbon/carbon-deployment.yaml
  - carbon/carbon-service.yaml
  # Cloudflare Tunnel for carbon.voitech.dev
  - carbon/cloudflared-carbon-deployment.yaml
  - carbon/carbon-tunnel-ingress-configmap.yaml
  # Observability
  - carbon/carbon-prometheus-rules.yaml
  - carbon/carbon-alertmanager-config.yaml
  - carbon/carbon-loki-rule.yaml
  - carbon/carbon-dashboard-configmap.yaml
```

## 6. Proposed manifests

### 6.1 Namespace

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: carbon
  labels:
    app.kubernetes.io/name: carbon
```

### 6.2 Deployment

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: carbon
  namespace: carbon
  labels:
    app.kubernetes.io/name: carbon
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 0
      maxUnavailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: carbon
  template:
    metadata:
      labels:
        app.kubernetes.io/name: carbon
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: carbon
          image: petersolopov/carbonara:latest
          ports:
            - name: http
              containerPort: 3000
          env:
            - name: HOST
              value: "0.0.0.0"
            - name: PORT
              value: "3000"
            - name: CARBON_URL
              value: "https://carbon.now.sh/"
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: 1000m
              memory: 1Gi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            readOnlyRootFilesystem: false
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: dshm
              mountPath: /dev/shm
          livenessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 30
            periodSeconds: 30
          readinessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
      volumes:
        - name: tmp
          emptyDir: {}
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 512Mi
```

**Notes:**

- `petersolopov/carbonara:latest` only publishes `latest`. After the first successful run we should pin the digest (see skill pitfall on `latest`-only images).
- The carbonara image runs as `pptruser` (uid 1000) and launches Chromium with `--no-sandbox` / `--disable-setuid-sandbox`. We match that uid/gid.
- `/dev/shm` is mounted as a memory-backed emptyDir because Puppeteer/Chromium are notorious for crashing when `/dev/shm` is only 64MB.
- TCP probes are used because the app only exposes `/api/cook`; an HTTP probe would require sending a real screenshot request on every check.

### 6.3 Service

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: carbon
  namespace: carbon
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: carbon
  ports:
    - name: http
      port: 3000
      targetPort: http
```

### 6.4 Cloudflare Tunnel

Create a new tunnel in Cloudflare Zero Trust named `carbon`, copy its token, then encrypt it:

```bash
# Create plain Secret locally
kubectl create secret generic carbon-tunnel-token \
  --namespace=carbon \
  --from-literal=token=<PASTE_TOKEN> \
  --dry-run=client -o yaml > /tmp/carbon-tunnel-token.yaml

# Encrypt with SOPS
sops --encrypt --in-place /tmp/carbon-tunnel-token.yaml

# Move into repo
mv /tmp/carbon-tunnel-token.yaml \
   ~/Projects/homelab-2nd/apps/carbon/carbon-tunnel-token.sops.yaml
```

`apps/carbon/carbon-tunnel-token.sops.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: carbon-tunnel-token
  namespace: carbon
type: Opaque
stringData:
  token: ENC[...]
sops:
  ...
```

`apps/carbon/cloudflared-carbon-deployment.yaml`:

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared-carbon
  namespace: carbon
  labels:
    app.kubernetes.io/name: cloudflared-carbon
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: cloudflared-carbon
  template:
    metadata:
      labels:
        app.kubernetes.io/name: cloudflared-carbon
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
            - --url
            - http://carbon.carbon.svc.cluster.local:3000
          env:
            - name: TUNNEL_TOKEN
              valueFrom:
                secretKeyRef:
                  name: carbon-tunnel-token
                  key: token
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
```

`apps/carbon/carbon-tunnel-ingress-configmap.yaml`:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: carbon-tunnel-ingress
  namespace: carbon
data:
  note: |
    # carbon.voitech.dev -> http://carbon.carbon.svc.cluster.local:3000
    # Create this public hostname rule in Cloudflare Zero Trust for the carbon tunnel.
```

## 7. Cloudflare Zero Trust steps

1. Create tunnel `carbon` in Cloudflare Zero Trust → Networks → Tunnels.
2. Add public hostname: `carbon.voitech.dev` → `http://carbon.carbon.svc.cluster.local:3000`.
3. Copy the tunnel token.
4. Ensure DNS record `carbon.voitech.dev` exists (CNAME to `<tunnel-id>.cfargotunnel.com` or let Zero Trust create it).

## 8. Observability package

Carbonara exposes no application `/metrics` endpoint, so we rely on node-level container metrics plus logs.

### 8.1 Prometheus resource alerts

`apps/carbon/carbon-prometheus-rules.yaml`:

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: carbon-resource-alerts
  namespace: carbon
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: carbon.resources
      interval: 30s
      rules:
        - alert: CarbonCPUAboveRequest
          expr: |
            sum by (pod, container, namespace) (
              rate(container_cpu_usage_seconds_total{namespace="carbon", container!=""}[5m])
            ) >
            sum by (pod, container, namespace) (
              kube_pod_container_resource_requests{namespace="carbon", resource="cpu", container!=""}
            )
          for: 5m
          labels:
            severity: warning
            namespace: carbon
          annotations:
            summary: "carbon/{{ $labels.pod }} CPU above request"
        - alert: CarbonMemoryAboveRequest
          expr: |
            sum by (pod, container, namespace) (
              container_memory_working_set_bytes{namespace="carbon", container!=""}
            ) >
            sum by (pod, container, namespace) (
              kube_pod_container_resource_requests{namespace="carbon", resource="memory", container!=""}
            )
          for: 5m
          labels:
            severity: warning
            namespace: carbon
          annotations:
            summary: "carbon/{{ $labels.pod }} memory above request"
```

### 8.2 Alertmanager routing

`apps/carbon/carbon-alertmanager-config.yaml`:

```yaml
---
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: carbon-mattermost-alerts
  namespace: carbon
  labels:
    release: kube-prometheus-stack
spec:
  route:
    receiver: carbon-mattermost
    matchers:
      - name: namespace
        value: carbon
        matchType: "="
  receivers:
    - name: carbon-mattermost
      webhookConfigs:
        - urlSecret:
            name: carbon-mattermost-webhook-url
            key: url
          sendResolved: true
          maxAlerts: 10
```

The `carbon-mattermost-webhook-url` Secret can reuse the source-of-truth Mattermost webhook if one exists, or be created new. Follow the same SOPS pattern.

### 8.3 Loki log alert

`apps/carbon/carbon-loki-rule.yaml`:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: carbon-loki-rules
  namespace: observability
  labels:
    loki_rule: "true"
data:
  carbon-http-errors.yaml: |
    groups:
      - name: carbon.http-errors
        interval: 1m
        rules:
          - alert: CarbonNon2xxOrCrash
            expr: |
              sum by (pod, namespace) (
                count_over_time(
                  {namespace="carbon", pod=~"carbon-.*"}
                    |~ "Error|error|ERR|FATAL|fatal"
                  [5m]
                )
              ) > 0
            for: 2m
            labels:
              severity: warning
              namespace: carbon
            annotations:
              summary: "Carbon logged errors or crashes"
```

### 8.4 Grafana dashboard

Generate with the per-namespace dashboard script (`scripts/render_namespace_dashboard.py`) targeting `carbon`. The result is a ConfigMap in the `observability` namespace with label `grafana_dashboard: "1"` and annotation `grafana.folder: carbon`.

## 9. Verification steps

After Flux reconciles:

1. Check pods:
   ```bash
   kubectl get pods -n carbon
   ```
2. Check tunnel health:
   ```bash
   kubectl logs -n carbon deployment/cloudflared-carbon
   ```
3. Smoke-test the API from inside the cluster:
   ```bash
   kubectl run -n carbon --rm -it carbon-test --image=curlimages/curl -- sh
   curl -X POST http://carbon.carbon.svc.cluster.local:3000/api/cook \
     -H 'Content-Type: application/json' \
     -d '{"code": "console.log(\"hello\")"}' \
     -o /tmp/code.png
   ```
4. Smoke-test from the public internet (run from any machine):
   ```bash
   curl -X POST https://carbon.voitech.dev/api/cook \
     -H 'Content-Type: application/json' \
     -d '{"code": "print(\"hello\")", "theme": "seti"}' \
     -o /tmp/code.png
   file /tmp/code.png
   ```
5. Check logs in Grafana/Loki and dashboard in folder `carbon`.

## 10. Risks and gotchas

| Risk | Mitigation |
|---|---|
| `petersolopov/carbonara:latest` is a moving target | Pin to digest after first run |
| Chromium crashloops on `/dev/shm` | Mount memory emptyDir to `/dev/shm` |
| Chromium sandbox issues | Image already runs with `--no-sandbox`; do not add extra privileges |
| Carbon public site changes layout and breaks screenshots | `carbonara` uses `https://carbon.now.sh/`; if it breaks, we can point `CARBON_URL` at our own self-hosted UI later |
| Node CPU saturation | Request 250m, limit 1000m; verify node headroom before deploy |
| No saved snippets / accounts | Out of scope for Phase 1; document as trade-off |

## 11. Alternative: full Carbon editor UI (Phase 2)

If the Supreme Leader wants the actual `carbon-app/carbon` editor:

1. Fork `carbon-app/carbon` under `gulasz101/`.
2. Write a `Dockerfile` based on `node:18-alpine` or `node:18-slim` that installs dependencies, runs `next build`, and starts with `next start`.
3. Patch/replace the `/api/image` backend to use container-friendly Chromium (e.g., `puppeteer-core` + system Chromium) instead of `chrome-aws-lambda`.
4. Build and push the image to `ghcr.io/gulasz101/carbon`.
5. Deploy a second stack (or replace carbonara with it). No database needed, but Firebase auth must be disabled/ignored.
6. Update the Cloudflare tunnel to point at the new service.

This is significantly more work and is intentionally not part of Phase 1.

## 12. Decision requested

**Recommended:** Approve Phase 1 (carbonara API) as scoped above. I will then create the files, encrypt the tunnel token, update `apps/kustomization.yaml`, reconcile Flux, and verify `https://carbon.voitech.dev/api/cook` returns an image.

If the Supreme Leader wants the full Carbon editor instead, say so and I will switch to the Phase 2 containerization plan.
