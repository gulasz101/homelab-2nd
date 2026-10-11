# ADR-046: The zigbee namespace storage model — durability per workload, not per namespace

## Status

Accepted — 2026-10-11. Written while completing the `zigbee` namespace (H2-214), after H2-210 had
already landed the zigbee2mqtt scaffold with a storage choice of its own. The InfluxDB half is
provisional and the Supreme Leader can override it before the data restore (H2-216).

## Context

homelab-one (a Surface Pro 4 running five docker-compose containers) is being retired and its
home-automation stack moved into k3s: zigbee2mqtt → Mosquitto → Node-RED → InfluxDB v2 → Grafana.
That stack is not a set of interchangeable containers. Three of the four workloads own state that
**cannot be re-derived**:

- `zigbee2mqtt` `/app/data` holds the Zigbee network key, `database.db` (all 17 paired devices) and
  `coordinator_backup.json`. Lose them and every device is re-paired by hand.
- `node-red` `/data` holds `flows.json` (110 nodes, 7 tabs), `flows_cred.json` and the generated
  credential key. This is the house's automation logic; there is no upstream copy.
- `InfluxDB` holds the sensor history: the `default` bucket, infinite retention, ~91 MB today and
  growing on its own.

Mosquitto is the odd one out: the source broker ran with persistence disabled, and its retained
messages are republished by zigbee2mqtt on every start.

Two physical constraints pull in opposite directions:

- The Zigbee coordinator dongle lives on the Orange Pi Zero 2W ("radio head"), so zigbee2mqtt must
  be pinned to that node — and that node's only storage is a 119 GB microSD card. A node-local
  volume for zigbee2mqtt therefore means "the Zigbee network lives on the least reliable storage in
  the fleet".
- InfluxDB's metadata store is BoltDB and its TSM data files are mmap'd. Neither is reliable over
  NFS, so for InfluxDB the node-local volume is the *only* sound option.

Guardrail 4 says homelab-2nd's disks are not durable and OMV is the only durable store — but that
rule was written for data with a backup path. Where the backup path does not exist yet, the
distinction between "durable" and "single copy" is what actually matters.

## Decision

Durability is decided **per workload**, not per namespace:

| Workload | Where the live data lives | Durability story | Why |
|---|---|---|---|
| zigbee2mqtt `/app/data` | `local-path` on the radio head, 1Gi (H2-210's decision, kept) | **must** come from a `database.db` + state backup CronJob to OMV MinIO — **not implemented yet** | the volume sits next to the serial device and z2m writes the registry continuously; the state is small (tens of KB) and the backup pattern is the one already accepted for openGym |
| Node-RED `/data` | static OMV NFS PV `node-red-data`, 5Gi | the volume itself is on OMV | irreplaceable flow logic; same pattern as karakeep/opengist, and Node-RED tolerates NFS fine |
| InfluxDB `/var/lib/influxdb2` | `local-path` on homelab-2nd, 5Gi, pod pinned to that node | scheduled `influx backup` of the `default` bucket to OMV MinIO — **not implemented yet**; **provisional** | BoltDB + mmap are not NFS-safe, and the source stack ran on local disk for the same reason |
| Mosquitto | nothing — `persistence false`, no PVC | none needed | stateless by design; retained state is republished by zigbee2mqtt (`advanced.cache_state_send_on_startup`) |

Two further decisions came with it:

- **zigbee2mqtt's configuration is code, not a restored file.** The non-secret half lives in the
  HelmRelease values, the secret half (network key, PAN IDs) in a SOPS-encrypted `valuesFrom`
  Secret, and the chart renders both into its own ConfigMap. The restored `database.db` and
  `coordinator_backup.json` still have to land on the PVC (H2-216), but `configuration.yaml` is no
  longer something to restore. This supersedes the earlier plan of restoring a byte-identical
  configuration.yaml and switching the chart's ConfigMap off; the trade-off is that the chart's
  ConfigMap now carries the network key in-cluster (namespace-local, not a repo leak), and that the
  chart's `devices: devices.yaml` / `groups: groups.yaml` keys change where z2m looks for the
  device registry compared to the retired config.
- **A restore gate sits in front of zigbee2mqtt.** The container command runs a preflight script
  that refuses to start until `configuration.yaml`, `database.db` and `coordinator_backup.json` are
  on the volume, so a half-restored volume shows up as a loud CrashLoop instead of a bridge that
  re-interviews every device. It costs one ConfigMap and a shell test.
- **Node-RED's data is bound by name**: `storageClassName: ""` plus `volumeName` on a hand-written
  PVC, because the chart's PVC template cannot express a static PV.

## Consequences

**Good**

- Each decision is a reviewable file in the repo rather than a side effect of a chart default.
- InfluxDB keeps the storage profile its engine requires (fast local disk, mmap-safe) instead of
  being forced onto a filesystem it does not tolerate.
- Node-RED's flows — the piece with no backup path at all — live on the durable store today.
- `Retain` on the NFS PV: a botched PVC or Helm release cannot delete the flows.
- The restore gate makes the migration's progress visible in the cluster, not just in a tracking
  note.

**Bad / accepted costs**

- **zigbee2mqtt's Zigbee network is a single copy on a microSD card today.** The backup CronJob
  that this decision leans on does not exist. This is the largest residual risk in the namespace
  and it is recorded in the H2-214 result comment as the first follow-up.
- InfluxDB's history is on a disk that is not backed up yet either; the same follow-up applies.
- The Node-RED volume is a hard NFS mount: if OMV is unreachable, Node-RED stalls rather than
  writing into a local scratch volume. Intended, but it gives an OMV outage a visible blast radius
  in the automation path.
- Two different storage patterns in one namespace (NFS for Node-RED, local-path for the other two)
  is more to explain than one rule. The table above is the explanation.
- The chart's ConfigMap carries the network key in-cluster. Anyone with read access to ConfigMaps in
  the `zigbee` namespace can read the Zigbee network key. Accepted for a single-tenant homelab;
  the alternative (`configmap.enabled: false` + a restored configuration.yaml) is documented in the
  HelmRelease header.

## Alternatives considered

- **Everything on OMV NFS.** Rejected for InfluxDB: BoltDB over NFS is a known way to lose a
  database, and mmap over NFS is not sound. Rejected for zigbee2mqtt: it would work, but it puts
  the Zigbee network behind a hard NFS mount on a node whose network runs through a USB Ethernet
  dock, and H2-210 had already committed the local-path design with a backup as the durability
  story.
- **Everything on `local-path` with backups to MinIO.** This is close to what was chosen, and it is
  the pattern guardrail 4 prescribes for live databases — but it only limits damage where the
  backup exists, and Node-RED had no reason to accept a node-local volume for data that fits in
  kilobytes.
- **zigbee2mqtt on `local-path` on homelab-2nd with the pod pinned there.** Impossible: the
  coordinator is on the Orange Pi, and a node-local volume cannot be mounted from another node.
- **A serial-over-network bridge (ser2net / socat) so the dongle could stay on homelab-2nd.**
  Rejected upstream and in ADR-045: zigbee2mqtt's own documentation discourages serial-to-IP
  bridges for the coordinator.
- **Restoring a byte-identical `configuration.yaml` and disabling the chart's ConfigMap.** This was
  the original plan; superseded by config-as-code (see above) because the config is then reviewable
  in Git. Reinstating it is a one-value change plus a PVC restore, and it is the fix if the
  in-cluster network key exposure is ever judged unacceptable.
- **Keeping Mosquitto's retained-message store on a PVC.** Rejected as unnecessary: the source
  stack ran stateless, and zigbee2mqtt republishes device state on every start. If it ever matters,
  it is one NFS PV plus one volumeMount.

## When to revisit

- **Before H2-216 restores anything** — the deadline for the InfluxDB decision. A PVC cannot be
  repointed at a different volume afterwards, so switching to OMV NFS is a now-or-never edit.
- **The moment the two backup CronJobs exist.** Until then, both local-path choices are promises
  rather than properties, and this ADR should be read as "planned", not "done".
- If the restored `database.db` does not surface the 17 devices (the `devices: devices.yaml`
  question above), the config-as-code decision is what gets revisited first.
- If InfluxDB 2.x is replaced (the line is feature-frozen and the official chart has not been
  released since 2023-12): a move to InfluxDB 3 Core or another TSDB re-opens the storage question
  entirely.
- If the radio head's microSD proves unreliable in practice: zigbee2mqtt is the workload to move,
  and the NFS PV already used for Node-RED is the destination.
- If a second Zigbee coordinator or a second radio head appears: one volume per coordinator, and the
  naming scheme (`<workload>-data`) needs a suffix.
