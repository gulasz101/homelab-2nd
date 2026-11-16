# k3s-node — bootstrap and verify kit for cluster nodes

Every requirement below was learned on a live node. The kit applies them (`bootstrap.sh`) and checks
them (`verify.sh`). Order for a new box:

1. `grant-access.sh user@host`: once, interactive, from the laptop (keys + passwordless sudo).
2. `bootstrap.sh`: piped to the node with the join token prepended (usage in its header).
3. `verify.sh` must print no FAIL. Then grant the node in OMV `/etc/exports`
   (`host/openmediavault/README.md`) and write `host/<hostname>/README.md`.

| requirement | why |
|---|---|
| key SSH + passwordless sudo | migrations and checks run unattended; mimir/loki had neither on 2026-11-12 |
| `nfs-common` | the kubelet shells out to `mount.nfs` for the OMV PVs; minimal trixie lacks it |
| `/etc/hosts`: `192.168.1.180 openmediavault.local` | every NFS PV names `openmediavault.local`; it resolved only over mDNS, which fresh boxes lacked |
| `avahi-daemon` + `libnss-mdns` | other `.local` names (parity with the old nodes) |
| NetBird `DisableFirewall: true` | ADR-013: NetBird's nftables rules break k3s's iptables-nft and crash-loop k3s on the next NetBird restart (Clevo 2026-09, T460 2026-10; mimir/loki were found exposed 2026-11-12) |
| no swap on servers | etcd/apiserver paged out = API stalls on a single-member etcd. Agents: WARN, decide per node |
| `INSTALL_K3S_VERSION` = the servers' version | `get.k3s.io` installs "stable"; a kubelet newer than the apiserver is unsupported (zigbee-node runs v1.36.5 against v1.35.5 servers: open item) |
| `node-ip` pinned | `docker0` / `wt0` can win the default-route IP lottery |
| servers: `disable: [traefik, servicelb]`, `flannel-backend: vxlan`, `192.168.1.179` in `tls-san` | flags must be identical across servers; `.179` is the front door every kubeconfig/agent uses |
