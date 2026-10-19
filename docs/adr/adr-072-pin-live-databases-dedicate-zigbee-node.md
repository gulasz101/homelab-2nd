# ADR-072: Live databases are pinned to homelab-2nd; zigbee-node is dedicated to the Zigbee stack

**Date:** 2026-10-19
**Status:** Accepted
**Deciders:** Wojtek Gula; implemented by Claude Code (Hindsight move, taint) and Andrzej (H2-309)
**Project:** cluster topology
**Related:** H2-306 (incident), H2-309 (zigbee-node dedication), H2-310 (maintenance window), ADR-071

## Context

The architecture says live database PVCs use `local-path` on homelab-2nd's NVMe. Nothing enforced it.
`local-path` binds a volume to whichever node the first pod happens to land on, and binds it for life.

On 2026-10-19 (H2-306) the Hindsight Postgres turned out to have lived since 10-13 on `zigbee-node`, an
Orange Pi (arm64, 4 cores, **2 GB RAM**) meant to run only zigbee2mqtt. Every Hindsight timeout and
restart traced back to that. Sizing the DB for homelab-2nd plus a backfill load took the board
NotReady (kubelet silent, sshd unable to complete a banner) and with it the home automation.

The same inventory showed the drift is general: `litellm-db`, `authentik-db`, `itsaplan-db`,
`opengist-db` and `star-office-db` live on `t460`; `shlink-db` and `mailarchiver-db` on `arr-box`.

## Decision

1. **Every CNPG `Cluster` carries `affinity.nodeSelector: kubernetes.io/hostname: homelab-2nd`**
   from its first apply. A cluster without the pin is a defect.
   - `hindsight-db` was rebuilt as generation 2 (recovered from OMV MinIO, archive
     `serverName: hindsight-db-gen2`) with the pin (`4278c3c`). Restore took ~5 minutes.
   - The clusters already on t460/arr-box are moved by the same generation-N rebuild, one at a time,
     as separate approved tickets (H2-310 Part C). Until then they are known exceptions, not precedent.
2. **`zigbee-node` is tainted `dedicated=zigbee:NoSchedule`.**
   - Only zigbee2mqtt, mosquitto and Node-RED tolerate it, plus the observability DaemonSets
     (OTel agent via chart `tolerations`; node-exporter already tolerates every NoSchedule).
   - The taint is in the board's `/etc/rancher/k3s/config.yaml` (`node-taint`), so it survives a node
     re-join, not just a reboot.
   - Tolerations go in BEFORE the taint, or a restart strands zigbee2mqtt.

## Consequences

**Positive**
- A database can no longer land on a small node by accident, and the 2 GB board can no longer be
  overrun by unrelated workloads. After H2-309 it runs at ~32% RAM with exactly the Zigbee stack.
- Hindsight on NVMe: `db_acquire_ms` 3.4 → 1.0; no more probe-kill restart loops.
- The first real CNPG restore was proven under pressure, not in a drill.

**Negative**
- homelab-2nd becomes the single host for every live database. It already was the intended durable
  compute node; durability still comes from OMV (WAL + base backups), not from spreading DBs around.
- Moving each existing misplaced cluster costs a short outage per database.
- Anything that must run on zigbee-node needs an explicit toleration (one more line to forget). The
  hourly memory watchdog does not cover this; the scheduler will simply refuse, which is visible.

## Alternatives considered

- **Leave placement to the scheduler and fix incidents as they come:** rejected; that is how a DB
  ended up on a 2 GB board for six days.
- **A StorageClass with `allowedTopologies` restricted to homelab-2nd:** a cluster-wide guard, but it
  would also capture non-database local-path workloads that legitimately live elsewhere (arr-stack
  configs on arr-box, zigbee2mqtt state on zigbee-node). Revisit if per-cluster pins keep being forgotten.
- **Cordon zigbee-node instead of tainting:** cordoning blocks the Zigbee stack too, and is easily
  undone by a drain/uncordon cycle.

## When to revisit

- A second machine with fast durable local storage joins and we want to spread database load.
- A CNPG cluster is found without the pin again: then switch to the `allowedTopologies`
  StorageClass guard.
- zigbee-node is replaced by bigger hardware that could host more than the Zigbee stack.
