# arr-box — k3s worker (media stack)

Debian 13, 16 GB. LAN `192.168.1.162`, NetBird `100.96.191.232`. SSH `gulasz101@arr-box` with the
homelab key from paperclip (`~/.ssh/config` there). **No passwordless sudo**; the NetBird daemon
socket is world-writable (`netbird down; netbird up --disable-firewall` works as the user, ADR-013).

## Roles outside the pod list

- **OMV NFS grants by IP**: `downloads` and `media` are exported to `192.168.1.162` only
  (`all_squash`, anonuid/gid 1100), see `host/openmediavault/README.md`.
- **Docker is installed** (`docker0` 172.17.0.1). That's why `node-ip` is pinned: the bridge can win
  the default-route IP lottery.
- **LAN NodePorts** for the arr apps (30076, 30030, 30096, 30069, 30080, 30078, 30089) answer on every
  node, but bookmarks historically point here or at `.179`.
- **local-path volumes**: arr app configs, `mailarchiver-db-1`, `shlink-db-1`, Grafana Loki
  `storage-loki-0`.
- **Memory headroom is thin** (~92% of allocatable at times): heavy pods are pinned elsewhere on
  purpose (firecrawl-api, the qbittorrent enforcer).

## Host config

- k3s **agent**: `server: https://192.168.1.179:6443` (the front-door alias on mimir, in its cert
  SANs), `node-ip: 192.168.1.162`.
- Name resolution via mDNS (`avahi-daemon`, `libnss-mdns`); `nfs-common` installed.
