# tang on OMV — network-bound disk unlock for the k3s nodes

Pending ADR `lan-dns-fails-over-off-mimir-keepalived-vip`, item 5. On 2026-11-16 mimir hard-reset at
02:37 and waited 16 h at the LUKS prompt. With clevis + tang, an encrypted node unlocks itself at
boot **only while it can reach OMV on the home LAN**. A stolen node stays locked. The passphrase
keyslot is never removed, so JetKVM + passphrase is still the fallback.

## Server (OMV, 192.168.1.180)

- Debian package `tang` 15 (`apt install tang`), systemd socket activation.
- Port **7500**, bound to `192.168.1.180` only: `tangd.socket.override.conf` →
  `/etc/systemd/system/tangd.socket.d/override.conf`. Port 80 is the OMV web UI.
- Keys: `/var/lib/tang/*.jwk` (`_tang:_tang`, 0440), created on the first request 2026-11-16.
  Signing key thumbprint `FY73uBGDfKQon8U2Ewe5IED3kmWGBbR3FOYzj0i00N8` (public, used in `clevis` bind).
- Backup: `tang-keys.sops.yaml` (Secret-shaped so SOPS encrypts `stringData`; **not** a cluster object).

```sh
curl -s http://192.168.1.180:7500/adv | head -c 60     # tang answers
systemctl status tangd.socket
```

### Restore (OMV rebuilt, or the keys lost)
Without these exact keys no node unlocks by itself (the passphrase still works).

```sh
sops -d host/openmediavault/tang/tang-keys.sops.yaml \
  | python3 -c 'import sys,yaml; [open(f"/tmp/{k}","w").write(v) for k,v in yaml.safe_load(sys.stdin)["stringData"].items()]'
scp /tmp/*.jwk root@192.168.1.180:/var/lib/tang/ && rm /tmp/*.jwk
ssh root@192.168.1.180 'chown _tang:_tang /var/lib/tang/*.jwk && chmod 0440 /var/lib/tang/*.jwk'
```

**Never rotate the keys** (`tangd-rotate-keys`) without re-binding every node first.

## Client (per encrypted node, e.g. mimir)

1. `apt install clevis clevis-luks clevis-initramfs` (needs NIC firmware in the initramfs: mimir is
   `r8169` → `firmware-realtek`).
2. Pin early-boot networking to the wired NIC: `DEVICE=enp1s0` in
   `/etc/initramfs-tools/initramfs.conf` (mimir also has `wlp2s0`). tang is addressed **by IP**, since
   DNS (Pi-hole) runs on mimir itself.
3. Bind. This asks for the existing LUKS passphrase, so the **owner runs it**, never an agent:
   ```sh
   ssh -t mimir@192.168.1.145 'sudo clevis luks bind -d /dev/nvme0n1p3 tang \
     "{\"url\":\"http://192.168.1.180:7500\",\"thp\":\"FY73uBGDfKQon8U2Ewe5IED3kmWGBbR3FOYzj0i00N8\"}" \
     && sudo update-initramfs -u -k all'
   ```
4. Check: `sudo clevis luks list -d /dev/nvme0n1p3` shows a `tang` slot; `lsinitramfs
   /boot/initrd.img-$(uname -r) | grep -E 'clevis|rtl_nic'` is not empty.
5. Test with a reboot **while someone can reach JetKVM**.

| node | disk | bound | reboot-tested |
|---|---|---|---|
| mimir | `/dev/nvme0n1p3` (LUKS2) | pending (owner) | no |
