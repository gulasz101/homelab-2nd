# CNPG barman serverName generations (per-rebuild isolation)

Status: adopted 2026-09-12. Supersedes the blanket
`cnpg.io/skipEmptyWalArchiveCheck: "enabled"` annotation on every cluster.

## Why

Barman namespaces the WAL/backup tree inside an object store by a `serverName`.
CloudNativePG guards two operations against clobbering a non-empty destination:

1. **WAL archiving** after a cluster is (re)initialized. The instance manager
   writes a marker file `.check-empty-wal-archive` into `$PGDATA` after
   `initdb`/recovery and removes it after the first WAL is successfully
   archived. While the marker exists, the archiver runs
   `barman-cloud-check-wal-archive` against the **target** `serverName` and
   aborts with `Expected empty archive` if history is already present.
2. **Recovery bootstrap**. Before restoring, the operator checks that the
   **target** destination is empty. This check is *not* gated on the marker
   file.

Both checks are disabled by the annotation
`cnpg.io/skipEmptyWalArchiveCheck: "enabled"` (see
`utils.IsEmptyWalArchiveCheckEnabled`). We relied on that annotation after the
2026-09-11 incident because every rebuilt cluster archived back into the same
`serverName` it was recovering from — a destination that already contained
history.

The annotation is a blunt instrument: it also disables the guard on a genuinely
empty destination and hides real misconfiguration.

## The convention

Give every rebuild its own object-store namespace:

- `plugins[].parameters.serverName` (plugin) / `backup.barmanObjectStore.serverName`
  (in-tree, honcho) is the **current generation** and must point at a **fresh,
  empty** destination when the cluster is created.
- `externalClusters[].plugin.parameters.serverName` /
  `externalClusters[].barmanObjectStore.serverName` is the **previous
  generation** and points at the history being recovered.

The un-suffixed cluster name is generation 1 (`<cluster>`). Each rebuild bumps
the generation: `-gen2`, `-gen3`, … The new cluster restores from
`gen(N-1)` and archives into `genN`. Because the target is empty, both guards
pass naturally and no `skipEmptyWalArchiveCheck` annotation is needed.

### At rest (steady state)

Manifests keep the un-suffixed name in **both** places, e.g.:

```yaml
externalClusters:
  - name: origin
    plugin:
      name: barman-cloud.cloudnative-pg.io
      parameters:
        barmanObjectName: opengist-db-backups
        serverName: opengist-db        # previous gen (= current until a rebuild)
plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: opengist-db-backups
      serverName: opengist-db          # current gen
```

This is safe because a healthy cluster has already had its marker file removed
(verified: `.check-empty-wal-archive` is absent on every running pod), so
steady-state archiving performs no empty-archive check. The annotation removal
was pilot-tested on `opengist-db` (WAL switch + on-demand base backup both
succeeded with the annotation gone).

### Rebuild runbook (mechanical, copy-paste)

Say `opengist-db` (generation 1) must be rebuilt. Before deleting the cluster's
PVC / letting CNPG bootstrap an empty instance:

1. In `apps/<app>/postgres-cluster.yaml`, set the **recovery source** to the
   previous generation:
   ```yaml
   externalClusters:
     - name: origin
       plugin:
         parameters:
           serverName: opengist-db        # gen 1, contains history
   ```
2. Set the **archiver target** to a fresh generation:
   ```yaml
   plugins:
     - name: barman-cloud.cloudnative-pg.io
       isWALArchiver: true
       parameters:
         serverName: opengist-db-gen2      # gen 2, empty -> guards pass
   ```
3. `git commit` + push and let Flux apply it **before** the instance is
   re-created (the `initdb`/recovery path is what reads these values).
4. After recovery, the next rebuild is generation 3: source
   `opengist-db-gen2`, target `opengist-db-gen3`.

> Do **not** bump only one side. If target == source and the target is
> non-empty, recovery/archiving aborts with `Expected empty archive`.

### In-tree (honcho)

`honcho-db` uses the deprecated in-tree `backup.barmanObjectStore` instead of a
plugin. The same rules apply, using the `serverName` field it supports:

- current: `spec.backup.barmanObjectStore.serverName: honcho-db`
- previous: `spec.externalClusters[].barmanObjectStore.serverName: honcho-db`
- rebuild: current `honcho-db-gen2`, previous `honcho-db`.

`honcho-db` currently omits `serverName`, which defaults to the cluster name;
the manifests spell it out explicitly so the convention is visible.

## Auditing current state

```sh
# No cluster should carry the skip annotation any more.
kubectl get clusters.postgresql.cnpg.io -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" skip="}{.metadata.annotations.cnpg\.io/skipEmptyWalArchiveCheck}{"\n"}{end}'

# The marker must be absent on healthy clusters (it only exists between
# initdb/recovery and the first archived WAL).
kubectl -n <ns> exec <cluster>-1 -c postgres -- \
  test ! -e "$PGDATA/.check-empty-wal-archive" && echo marker_absent
```

## When to revisit

If CNPG gains a first-class way to pin a recovery source independently of the
archiver namespace, or if we adopt a per-generation ObjectStore, this manual
convention can be replaced.
