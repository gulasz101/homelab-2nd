# zigbee-node — k3s worker (Zigbee only)

Armbian trixie on an ARM SBC, 2 GB. LAN `192.168.1.120`. SSH `copyparty@192.168.1.120` with the
homelab key from paperclip, passwordless sudo. No NetBird. **k3s v1.36.5**, one minor ahead of the
servers (v1.35.5): keep upgrades in step.

## Roles outside the pod list

- **The Zigbee coordinator is plugged in here**:
  `/dev/serial/by-id/usb-Itead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_V2_...`. zigbee2mqtt can't run
  anywhere else.
- **Taint** `dedicated=zigbee:NoSchedule` (in the k3s agent config): only zigbee workloads land here.
- **OMV NFS grant by IP**: `zigbee/node-red` is exported to `192.168.1.120`.
- Tasmota/MQTT devices and Node-RED bookmarks target `192.168.1.179` (NodePorts 30188/30180/30181),
  not this box.

## Host config

- k3s agent: `K3S_URL=https://192.168.1.179:6443` in `/etc/systemd/system/k3s-agent.service.env`
  (not `config.yaml`); `node-taint` in `/etc/rancher/k3s/config.yaml`.
- `/etc/hosts`: `192.168.1.180 openmediavault.local` (no mDNS on this image).
