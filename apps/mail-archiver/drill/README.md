# Mail-Archiver restore drill (H2-145 / ST3)

**What this is:** the recipe and the evidence procedure that prove the Barman objects in
OMV MinIO are an actual restorable PostgreSQL database. Written by the ST3 worker run;
executed by whoever holds cluster access (the worker pod has discovery-only RBAC, so it
cannot run the drill itself).

**What this is not:** desired state. `restore-drill.yaml` is deliberately **not** listed
in `apps/kustomization.yaml`. A drill cluster is transient: reconciling a second Postgres
forever would burn NVMe, sit in the primary's backup prefix and turn a one-off test into
permanent drift. The recipe is versioned in git, the object is hand-applied and deleted
again — the documented, intentional guardrail-1 exception.

---

## What the drill proves (and which acceptance criterion it serves)

| Claim | How the drill proves it |
|---|---|
| H2-148 AC4 — Cluster Healthy | `verify-backups.sh` section 1: phase + `Ready=True` + all instances ready |
| H2-148 AC5 — WAL segments landing in MinIO | `verify-backups.sh` section 3 (psql `pg_stat_archiver`) + section 4 (`mc ls`) |
| H2-148 AC6 — one base backup completes | `verify-backups.sh` section 2: a `Backup` CR with `phase: completed` + the ObjectStore's `lastSuccessfulBackupTime` |
| H2-148 AC7 — restore drill done to a scratch cluster | the run order below, ending in an **identical PostgreSQL system identifier** on drill and primary — identical values are only possible for a genuine physical restore, never for a silent `initdb` |

## Prerequisites

- `kubectl` with access to the homelab cluster (the drill lives in namespace `mail-archiver`).
- Optional, for the MinIO half of the evidence: `mc`. Create a throwaway alias — pull the
  credentials yourself, never through chat:

  ```sh
  sops -d apps/mail-archiver/mailarchiver-minio-backup-creds.sops.yaml   # read the two values here
  mc alias set omv http://openmediavault.local:9000 <ACCESS_KEY_ID> <ACCESS_SECRET_KEY>
  ```

## Run order

### 0. Baseline — the primary must be healthy before a restore can be trusted

```sh
cd <repo>
MC_ALIAS=omv ./apps/mail-archiver/drill/verify-backups.sh        # expect: PASS, exit 0
```

Do not continue on FAIL: a failed drill on top of an unhealthy primary proves nothing.

### 1. Record the primary's identity

```sh
kubectl -n mail-archiver exec mailarchiver-db-1 -c postgres -- \
  psql -U postgres -d postgres -tAc "select system_identifier from pg_control_system()"
```

Write it down — it must match the drill's value in step 3.

### 2. Create the scratch cluster

```sh
kubectl apply -f apps/mail-archiver/drill/restore-drill.yaml
kubectl -n mail-archiver wait --for=condition=Ready cluster/mailarchiver-db-drill --timeout=15m
```

Expected: `mailarchiver-db-drill-1` starts, its `-full-recovery` init job restores the
latest base backup for `serverName mailarchiver-db` and replays WAL, then the cluster goes
Ready and starts archiving into its own fresh `mailarchiver-db-drill` namespace. Watch it:

```sh
kubectl -n mail-archiver logs mailarchiver-db-drill-1 -c postgres --tail=50
kubectl -n mail-archiver get cluster mailarchiver-db-drill -o wide
```

If it stalls in `Setting up primary` with `Expected empty archive`, the drill target was
not empty (a previous drill ran) — see *Re-running* below.

### 3. Prove it is a restore, not a fresh database

```sh
# must be identical to step 1
kubectl -n mail-archiver exec mailarchiver-db-drill-1 -c postgres -- \
  psql -U postgres -d postgres -tAc "select system_identifier from pg_control_system()"

# the application schema came back with it
kubectl -n mail-archiver exec mailarchiver-db-drill-1 -c postgres -- \
  psql -U postgres -d mailarchiver -tAc \
  "select count(*) from information_schema.tables where table_schema='public'"

# row count of the high-value table (0 is a PASS before Gmail onboarding, > 0 after)
kubectl -n mail-archiver exec mailarchiver-db-drill-1 -c postgres -- \
  psql -U postgres -d mailarchiver -tAc 'select count(*) from "MailAccounts"'
```

Also confirm the recovery really read from the archive:

```sh
mc ls --recursive omv/cnpg-backups/mail-archiver/mailarchiver-db/base/
```

### 4. Record the evidence

Paste the raw output of steps 0-3 into the tracking note under
`homelab/tracking/YYYY-MM-DD-*.md` (never into the public repo). Note the elapsed time from
`kubectl apply` to `Ready` — that is the real RTO number for a rebuild, and it is the
number worth quoting in the blog post.

### 5. Clean up (the drill must not survive the day)

```sh
kubectl -n mail-archiver delete cluster mailarchiver-db-drill
kubectl -n mail-archiver get pvc | grep drill            # should be empty; delete if not
mc rm --recursive --force omv/cnpg-backups/mail-archiver/mailarchiver-db-drill/
mc ls omv/cnpg-backups/mail-archiver/                    # expected: only mailarchiver-db/
```

The primary (`mailarchiver-db`), its PVC and its archive tree are never touched by the
drill.

## Re-running the drill

`serverName: mailarchiver-db-drill` must point at an **empty** destination. A second run
either bumps the generation (`mailarchiver-db-drill2`) or removes the tree in step 5
first. Bumping it is the cleaner habit — it is the same convention every rebuild follows.

## Turning this into a real rebuild

The drill is the rebuild rehearsed. To rebuild the primary for real, take the same shape
into `apps/mail-archiver/postgres-cluster.yaml`: add the `bootstrap.recovery` +
`externalClusters` blocks pointing at the primary's current generation, set the archiver
`serverName` to a fresh `<name>-genN`, commit, and let Flux apply it — the full convention
is in `docs/cnpg-backup-servername-generations.md`.
