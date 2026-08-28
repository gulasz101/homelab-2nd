# 2026-08-28 — Karakeep crash-looping on liveness probe timeout

## Symptom

`akadmin` asked why Karakeep (`https://keep.voitech.dev`) was down.

Cluster-side the pod looked `Running` but had **11 restarts** and the last restart was only ~70s old. The `HelmRelease` was `Ready`, so it was not a manifest/config error from Flux.

## Diagnosis

```bash
export KUBECONFIG=~/.kube/config-homelab-2nd
kubectl get pods -n karakeep -o wide
kubectl describe pod -n karakeep karakeep-0 | tail -40
kubectl logs -n karakeep karakeep-0 --previous --tail=80
```

Key findings from `kubectl describe`:

- `Liveness probe failed: Get "http://10.42.0.247:3000/api/health": context deadline exceeded`
- `Readiness probe failed: ... context deadline exceeded`
- Container killed and restarted because of failed liveness probes.

The app logs looked normal right up to shutdown: Karakeep was crawling a YouTube URL (`https://www.youtube.com/watch?v=vxrZWbZ2fZA`), spawning the parse subprocess, doing inference, and while that was running it stopped answering `/api/health` quickly enough.

Looking at the HelmRelease, the probes did **not** set `timeoutSeconds`, so Kubernetes defaulted to **1 second**. With `cpu: 500m` and `memory: 1Gi`, the single container was CPU-starved during inference and the health endpoint couldn't respond in 1s. Kubelet killed it, the pod restarted, and immediately got another heavy job — repeat cycle.

Cloudflared logs confirmed the public impact:

```
Unable to reach the origin service ... dial tcp 10.43.200.214:3000: connect: connection refused
```

## Fix

Updated `apps/karakeep/karakeep-helm-release.yaml`:

- Liveness: `timeoutSeconds: 10`, `failureThreshold: 3`, `periodSeconds: 15`
- Readiness: `timeoutSeconds: 5`, `periodSeconds: 10`
- Resources: `cpu: "1"`, `memory: 2Gi` (up from `500m` / `1Gi`)

Commit: `09895f9`

```bash
cd ~/Projects/homelab-2nd
git add apps/karakeep/karakeep-helm-release.yaml
git commit -m "karakeep: fix liveness/readiness probe timeouts and bump resources"
git push
```

Reconciliation:

```bash
export KUBECONFIG=~/.kube/config-homelab-2nd
flux reconcile kustomization apps -n flux-system --with-source
flux reconcile helmrelease karakeep -n karakeep --with-source
kubectl delete pod -n karakeep karakeep-0
kubectl wait --for=condition=Ready pod/karakeep-0 -n karakeep --timeout=180s
```

## Verification

```bash
kubectl get pods -n karakeep -o wide
# karakeep-0   1/1   Running   0   102s

kubectl run -n karakeep --rm -it curl-test --image=curlimages/curl --restart=Never -- http://karakeep.karakeep.svc.cluster.local:3000/api/health
# {"status":"ok","message":"Web app is working"}
# HTTP:200
```

Public URL should now load via the Cloudflare Tunnel; the tunnel pods were already healthy.

## Side observations

- `/api/metrics` currently returns `401`. The Prometheus scrape annotation uses `prometheus.io/path: /api/metrics` with no auth secret, so metrics scraping is broken until we either expose an unauthenticated metrics endpoint or add the auth header to the scrape config. Not the cause of the outage, but worth fixing separately.
- The `Karakeep` pod is a single-container StatefulSet doing web, workers, crawler, inference, and search all in one. Heavy bookmarks can still block the loop; the probe fix should keep Kubernetes from killing it, but real scaling separation would need splitting web and worker roles (out of scope today).

## Lesson

Default probe timeouts are dangerous for single-node, CPU-constrained apps that do CPU-heavy background work on the same container. Always set `timeoutSeconds` explicitly when the app can be busy. 1 second is not enough for a pod that parses HTML and runs an LLM inference job at the same time.
