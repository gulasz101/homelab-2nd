# Runbook: decommissioning or replacing a k3s node

**Written after:** the 2026-11-12 retirement of the Clevo (`homelab-2nd`, the old sole control plane)
and the T460. `kubectl drain` moved the pods, but the box was also doing five jobs no pod list shows,
and each was found by breaking it. Tracking note:
`homelab/tracking/2026-11-11-control-plane-move-clevo-t460-to-mimir-loki.md`.

## 1. Inventory: what the node does besides pods

```sh
scripts/node-refs.sh <hostname> <lan-ip> <netbird-ip>     # read-only
```

Done when every line it prints has an owner on the replacement node or is deliberately retired,
**and** every `manual:` checklist item is ticked: NetBird routing peers, OPNsense DHCP/firewall,
agents pointing at this server, etcd membership, house devices. Record the list in the tracking note.
The node's `host/<hostname>/README.md` should already name these roles. Update it if the sweep found
more.

## 2. Prepare the replacement

- New node: `host/k3s-node/bootstrap.sh`, then `host/k3s-node/verify.sh` green. Then add its LAN IP
  to every OMV export the old node had (`host/openmediavault/README.md`).
- Anything the house reaches by address (DNS, MQTT, NodePorts, the API) stays on
  `192.168.1.179`, which moves with `homelab-frontdoor-ip.service`. Never re-point clients to a node IP.

## 3. Move the state

- CNPG: in Git, `instances: 2` + `affinity.nodeSelector` on the new node +
  `primaryUpdateMethod: switchover`; CNPG builds a replica and switches over. Then `instances: 1`.
  If the orphan `-1` pod sits `Pending`, delete its PVC and pod (the equivalent of `cnpg destroy`).
- Other local-path volumes: `scripts/pvmove.sh` (`docs/runbooks/move-local-path-volume.md`).
- Set every PV on the old node to `Retain` first, so the old disk stays a cold copy.

## 4. Cut over anything the house depends on

Follow `service-cutover.md`: pre-pull images, a path that cannot prompt, a deadman revert.

## 5. Remove the node

- **Server (etcd member):** `kubectl delete node <name>` **while every etcd member is still up**;
  k3s removes the member (`Removing etcd member from cluster due to node delete`). Then stop k3s
  on the box (`systemctl disable --now k3s`) or power it off.
- **Agent:** **unplug or stop `k3s-agent` first, then** `kubectl delete node <name>`. A running
  agent re-registers itself fresh and *uncordoned*.
- Delete the leftover `Released` PV objects that point at the node (the data stays on its disk).

## 6. Verify

Re-run `scripts/node-refs.sh`: only historical mentions remain. Then from a client: DNS on `.179`,
public URLs, `kubectl get --raw /healthz/etcd`, all CNPG clusters healthy with WAL archiving on.
