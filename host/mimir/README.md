# mimir — k3s server host state

Host-level configuration for `mimir` (192.168.1.145), the k3s control plane since 2026-11-12
(pending ADR `k3s-control-plane-moves-to-mimir`). Nothing here is applied by Flux.

## etcd snapshots → OMV MinIO

mimir is a **single-member etcd**, so the local snapshots in
`/var/lib/rancher/k3s/server/db/snapshots` are not enough. k3s also uploads every scheduled and
manual snapshot to MinIO on OMV.

- Bucket `k3s-etcd-snapshots`, folder `mimir`. MinIO user `k3s-etcd`, policy `k3s-etcd-rw`
  (List/Get/Put/Delete on that bucket only).
- Credentials: `k3s-etcd-s3.sops.yaml` (Secret-shaped so SOPS encrypts `stringData`; **not** a
  cluster object). They live in mimir's `/etc/rancher/k3s/config.yaml` as `etcd-s3-*` keys
  (`etcd-s3: true`, `etcd-s3-endpoint: 192.168.1.180:9000`, `etcd-s3-insecure: true`, `etcd-s3-bucket`,
  `etcd-s3-folder: mimir`, `etcd-s3-region: us-east-1`, access/secret key).
- Schedule and retention: k3s defaults (every 12 h, 5 kept), local and S3.

```sh
sudo k3s etcd-snapshot ls                 # shows file:// and s3:// entries
sudo k3s etcd-snapshot save --name manual # uploads too
# restore on a rebuilt server: k3s server --cluster-reset --etcd-s3 ... \
#   --cluster-reset-restore-path=<snapshot name>
```

## Front-door address

`homelab-frontdoor-ip.service` + `homelab-frontdoor-ip.sh` (this directory) add `192.168.1.179/24`
to `enp1s0` and source routes `1.1.1.1/32` and `1.0.0.1/32` via `src 192.168.1.179` (OPNsense lets
only .179 send DNS to the internet; Pi-hole runs hostNetwork here). The script waits for the DHCP
default route and verifies the routes; on 2026-11-16 the old inline unit raced DHCP, failed with
`Nexthop has invalid gateway`, hid it behind `|| true`, and the house had no DNS after a reboot.

```sh
sudo install -m 755 homelab-frontdoor-ip.sh /usr/local/sbin/homelab-frontdoor-ip.sh
sudo install -m 644 homelab-frontdoor-ip.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable homelab-frontdoor-ip
ip route | grep -E '^1\.[01]\.'   # both routes must show src 192.168.1.179
```

## Boot: disk is LUKS-encrypted

mimir waits at the LUKS passphrase prompt after any reboot (unlock over JetKVM). That is what made
the 2026-11-16 reset look like a dead box for 16 h. MAC `04:7b:cb:45:f9:00` (WoL only helps when it's
powered off). Unattended unlock: clevis + tang on OMV (`host/openmediavault/tang/README.md`); clevis packages
installed and `DEVICE=enp1s0` set in `/etc/initramfs-tools/initramfs.conf` (2026-11-16); the LUKS
bind is the owner's step (needs the passphrase).

## k3s config note

`/etc/rancher/k3s/config.yaml` still carries `server: https://192.168.1.179:6443` from the join;
`.179` is now mimir itself. Restarts work (existing etcd data wins), but drop the line the next time
the config is touched on purpose, and never copy it to a fresh single server.

## NetBird

`DisableFirewall: true` (ADR-013): `sudo netbird down && sudo netbird up --disable-firewall`.
Never `netbird up` without the flag on a k3s node. Swap is off (fstab line commented, 2026-11-15).
Check everything with `host/k3s-node/verify.sh`.
