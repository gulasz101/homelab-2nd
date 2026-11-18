# loki — k3s worker

Debian 13, i5-6500T 4c/4t, 15 GB, 128 GB SSD. LAN `192.168.1.190`, NetBird `100.96.99.210`.
SSH `loki@192.168.1.190` (laptop key + homelab key, passwordless sudo). Joined 2026-11-12.
`loki` is the machine, not the Grafana log store in `observability`.

## Roles outside the pod list

These are what breaks if this box goes away, beyond its workloads. Check them when replacing it
(`docs/runbooks/decommission-node.md`).

- **OMV NFS grants by IP**: every export in OMV `/etc/exports` lists `192.168.1.190`
  (`host/openmediavault/README.md`).
- **NetBird**: `DisableFirewall: true` (ADR-013). No network routes served.
- **Node-pinned workloads** (`kubernetes.io/hostname: loki` in the repo): firecrawl-api, the
  qbittorrent share-limit enforcer, the whole openchamber set, hindsight oauth2-proxy + cloudflared,
  CNPG authentik/itsaplan/litellm/opengist/star-office.
- **local-path volumes**: Prometheus TSDB, Tempo, Grafana, openchamber-storage, firecrawl state,
  karakeep meilisearch, authentik redis. List them with
  `kubectl get pv -o wide | grep loki`.

## Host config

- k3s **agent**, `/etc/rancher/k3s/config.yaml`: `server: https://192.168.1.145:6443`, `node-ip`.
- `/etc/hosts`: `192.168.1.180 openmediavault.local` (kubelet NFS mounts must not depend on mDNS);
  `avahi-daemon` + `libnss-mdns` for other `.local` names.
- Bootstrap and verify: `host/k3s-node/` (`bootstrap.sh`, `verify.sh`).
