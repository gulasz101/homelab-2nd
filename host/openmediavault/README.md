# openmediavault (OMV) — NAS + MinIO

`192.168.1.180`, `root@192.168.1.180` (laptop key, homelab key). MinIO: `omv/minio/`.

## Grants keyed on node IPs

When a k3s node is added, replaced or retired, these lists change with it. Nothing on the cluster
side will tell you, because a missing grant shows up as `mount.nfs: access denied` or a pod stuck in
`ContainerCreating`.

**`/etc/exports`** is hand-managed (OMV's database has no NFS shares). After editing,
`exportfs -ra`. Backups sit next to it in `/root/exports.bak-*`. As of 2026-11-12:

| export (under `/srv/dev-disk-by-uuid-…/`) | granted to |
|---|---|
| nextcloud/{html,data,migration-staging}, karakeep/data, opengist/data, speaches/model-cache, openchamber/data, mail-archiver/keys | `192.168.1.145` (mimir), `192.168.1.190` (loki) |
| zigbee/node-red | `.120` (zigbee-node), `.145`, `.190` |
| downloads, media (other disk) | `.162` (arr-box), `all_squash` 1100 |

The kernel NFS client mounts from the node's **primary** address. A secondary IP (mimir's `.179`)
never appears as a client.

**MinIO users** scoped per consumer (CNPG backups per cluster, `k3s-etcd` for mimir's etcd snapshots;
see `host/mimir/README.md`).

## tang (network-bound disk unlock)

`tangd.socket` on `192.168.1.180:7500` lets encrypted k3s nodes unlock LUKS at boot without a human.
Keys are backed up SOPS-encrypted. See `tang/README.md`. If OMV is down, nodes fall back to the
passphrase prompt (JetKVM).
