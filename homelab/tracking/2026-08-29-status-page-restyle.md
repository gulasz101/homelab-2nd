---
date: 2026-08-29
tags: [homelab, status, flux, gitops, ui]
---

# Status Page Restyle After catdevops Metrics Design

## Goal

Restyle the public homelab status page at `https://status.voitech.dev` to visually match the live metrics dashboard at `https://metrics.catdevops.net/`. Also add the missing footer link to the Supreme Leader's blog/about page.

## Before

The existing page was a dark, Tailwind-based dashboard, but it was visually sparse:

- Header: `voitech.dev - Homelab Status`
- Cluster Overview row: Nodes Online, Avg CPU, Avg Memory, Avg Load, Cluster Age, Pods Running
- Per-node cards: CPU %, Memory %, Load Avg, Uptime, plus load breakdown footer
- Footer: Morning Brew, LinkedIn, GitHub, Home
- No progress bars, no CPU mode breakdown, no absolute memory numbers

It worked, but it did not look like the reference page the Supreme Leader wanted.

## After

The page now uses the same visual language as `metrics.catdevops.net`:

- Dark cards with accent-coloured metric values
- Progress bars under CPU and Memory on each node card
- CPU breakdown per node: `User: X%, Sys: Y%, IO: Z%`
- Memory absolute value per node: `Used GB / Total GB`
- Cluster Overview cards unchanged in content, but labels styled consistently
- Footer now includes **About** (`https://gulasz101.github.io/about/`)
- Header now reads: `voitech.dev - Homelab-2nd Status`

## Files Changed

1. `apps/status/status-website-configmap.yaml`
   - Rewrote `index.html`
   - Added CSS for `.metric-label`, `.metric-sub`, `.progress-bg`, `.progress-fill`
   - Updated header title and subtitle
   - Added `renderBar()` helper and CPU/memory breakdown rendering
   - Added `About` link in footer

2. `apps/status/status-metrics-script-configmap.yaml`
   - Added Prometheus queries for `cpu_user`, `cpu_system`, `cpu_iowait`, `mem_total`, `mem_available`
   - Added `fmt_bytes_gb()` helper
   - Extended node objects with `cpu_user`, `cpu_system`, `cpu_iowait`, `memory_used_gb`, `memory_total_gb`

## Commands Used

```bash
# edit apps/status/status-website-configmap.yaml
# edit apps/status/status-metrics-script-configmap.yaml

cd ~/Projects/homelab-2nd
git add apps/status/status-website-configmap.yaml apps/status/status-metrics-script-configmap.yaml
git commit -m "style(status): restyle status page after catdevops metrics design"
git push origin main

# Flux was stuck at an older revision, so reconcile was forced
ssh homelab-2nd 'sudo flux reconcile kustomization apps --with-source'

# ConfigMap change does not roll pods, so restart the Deployment
ssh homelab-2nd 'sudo kubectl rollout restart deployment/status-website -n status'
ssh homelab-2nd 'sudo kubectl rollout status deployment/status-website -n status --timeout=120s'
```

## Verification

- `https://status.voitech.dev` title now reads `voitech.dev - Homelab-2nd Status`
- Cluster Overview shows real values: 2/2 nodes, 22.0% CPU, 36.0% memory, 2.10 load, 71 days, 89/89 pods
- Node cards show progress bars, CPU breakdown, and `GB / GB` memory values
- Footer contains Morning Brew, About, LinkedIn, GitHub, Home

## Surprises / Gotchas

1. **Flux did not auto-reconcile immediately.** The `apps` kustomization was stuck at `main@sha1:e6f9c2d`. A manual `flux reconcile kustomization apps --with-source` was required.
2. **ConfigMap update does not roll pods.** Even after Flux applied the new ConfigMap, the running Nginx pods still served the old `index.html`. A `kubectl rollout restart deployment/status-website` was needed to remount the ConfigMap.

## References

- Reference page: `https://metrics.catdevops.net/`
- Reference repo: `https://github.com/catdevops1/k8s-baremetal-dashboard`
- Live page: `https://status.voitech.dev`
