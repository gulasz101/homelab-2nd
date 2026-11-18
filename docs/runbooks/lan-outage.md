# Runbook: whole LAN looks dead but every device is healthy

**Scope:** the home LAN (OPNsense, the two small 8-port switches, Pi-hole on `mimir` behind the
`192.168.1.179` front-door address, and what depends on them). Node names updated 2026-11-15: the
Clevo `homelab-2nd` was retired on 2026-11-12; the 2026-11-05 symptoms below are as observed then. **Written after:** the 2026-11-05 outage, 17:11 to about 19:55 CET.

**Status of the root cause: unknown.** Power-cycling both switches restored the LAN with no config
change. Both were reset together, so we do not know which one was at fault.

## Fast path

1. **Power-cycle both switches first.** Pull power, wait 30 seconds, plug back in. Note the lights
   before you do it. This is the cheapest test, and it is what fixed 2026-11-05.
2. Wait 5 minutes before judging the cluster.
3. Run the verification list below.

Blinking switch lights prove power, not forwarding. Do not use them as evidence.

## What it looks like

- "No internet", but `ping 1.1.1.1` works through OPNsense. DHCP hands out only Pi-hole
  (`192.168.1.179`), so if the `.179` holder (`mimir` since 2026-11-12) is unreachable, names stop resolving while routing is fine.
  Since 2026-11-12 `.179` is a secondary IP on `mimir` (`homelab-frontdoor-ip.service`).
- Nothing gets a DHCP lease through the switches, but a laptop plugged straight into OPNsense does.
- `homelab-2nd` is up on `169.254.x.x` and ARPs for everything, including `1.1.1.1` and its own
  `.179`.
- Workers go `Unknown` together within seconds. Control plane stays Ready.
- `zigbee-node` ARPs every second for `.179`, `.180` and `.111`.
- Devices can be heard in `tcpdump` but do not answer ARP.

## Access while the network is down

From the Framework laptop:

- OPNsense root SSH is publickey only, and this laptop's key is not authorised. The SOPS password
  in `infrastructure/auth/` does not work over SSH.
- The laptop's key **is** authorised on `mimir@192.168.1.145`, `loki@192.168.1.190` and `root@192.168.1.180`
  (OMV), and its kubeconfig works. Point it at whichever address mimir has (both are in the cert SANs):

  ```bash
  kubectl --context homelab-2nd --server=https://192.168.1.145:6443 get nodes     # LAN
  kubectl --context homelab-2nd --server=https://100.96.12.30:6443 get nodes     # NetBird
  ```

- To reach a `169.254` address over a direct cable, stop NetworkManager from wiping manual
  addresses first, and restore it afterwards:

  ```bash
  sudo nmcli device set <if> managed no
  sudo ip addr add 169.254.10.10/16 dev <if>
  # when done
  sudo ip addr flush dev <if> scope link
  sudo nmcli device set <if> managed yes
  ```

  If NetworkManager has given up on DHCP, run `sudo nmcli device connect <if>`.

## After the network returns

The cluster heals itself in about 5 minutes. On 2026-11-05 there were 17 pods in CrashLoopBackOff
and 8 of 12 CNPG clusters not yet healthy, and all of it cleared without intervention.

Check these by hand, because cluster health does not cover them:

| Check | Why | Fix |
|---|---|---|
| Paperclip `/api/health`, not `/` | `/` answers 200 while the API is hung. All 10 pool connections got stuck after Postgres restarted: 2 `idle in transaction`, 8 blocked on row locks. | `sudo launchctl kickstart -k system/dev.voitech.homelab.paperclip` (see `host/paperclip-air/RUNBOOK.md`) |
| `zigbee-node` ping | It dropped off after the switch power-cycle, with no remote power control. | Physical power-cycle, then check zigbee2mqtt reports 18 devices |
| M1 Max | It may need waking. | JetKVM |
| Hindsight in agent sessions | MCP does not reconnect in sessions started during the outage. | `/mcp` or a new session |

## Verification

```bash
kubectl --context homelab-2nd get nodes
kubectl --context homelab-2nd get clusters.postgresql.cnpg.io -A
curl -s -m 10 http://192.168.1.191:3100/api/health
```

Pi-hole must answer on `192.168.1.179`, and `.120`, `.180` and `.191` must ping.

## Known false leads from 2026-11-05

- The laptop's USB-C adapter showed transmit errors (0 to 195). They stopped after the switch reset.
- The Huawei at `.109` sent PPPoE discovery on the LAN while DHCP was out. Nothing tied it to the
  fault.
- Dead sockets to Postgres: Postgres had all of Paperclip's connections.
