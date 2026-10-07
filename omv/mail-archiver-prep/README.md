# Mail-Archiver OMV prep (H2-145 / ST1)

Prep work on **openmediavault** for `s1t5/mail-archiver`:

1. a durable **NFS export** for the app's ASP.NET DataProtection keyring, and
2. a **dedicated MinIO user** scoped read/write to the `cnpg-backups/mail-archiver/`
   prefix, for CNPG WAL + base backups.

This directory exists because **the OpenChamber worker cannot execute OMV-side work**:
it runs as a pod on `t460` with no SSH key for OMV, no SOPS age key and no `op` CLI.
See `docs/` tracking note `2026-10-07-h2-146-omv-prep-*.md` in the vault. The worker
prepared this runbook; a human (or an agent with the homelab SSH key) runs it.

Anything below that touches the cluster is **ST4** / **H2-149** — not this ticket.

---

## 0. Facts you need

| Thing | Value |
|---|---|
| OMV host | `root@openmediavault.local` (192.168.1.180) |
| Durable share root | `/srv/dev-disk-by-uuid-cda9bf6e-0ed1-4e61-b063-1cbab7351886` |
| Keyring dir | `<share root>/mail-archiver/keys` |
| NFS clients | `192.168.1.179` (homelab-2nd), `192.168.1.111` (t460) |
| MinIO API / console | `http://openmediavault.local:9000` / `:9001` |
| MinIO compose dir | `/opt/homelab/minio` (`.env` holds `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`) |
| Target bucket | `cnpg-backups` (already exists) |
| Target prefix | `mail-archiver/` |
| MinIO user to create | `cnpg-mailarchiver-backup` |

The pattern is the same one used for `cnpg-openchamber-backup` (ADR-018): a scoped
MinIO **user** with a prefix-conditional policy, never the root credential.

---

## 1. Keyring directory (5 seconds)

```bash
ssh root@openmediavault.local
SHARE=/srv/dev-disk-by-uuid-cda9bf6e-0ed1-4e61-b063-1cbab7351886
install -d -o 1000 -g 1000 -m 0770 "$SHARE/mail-archiver/keys"
ls -ldn "$SHARE/mail-archiver/keys"
```

**Why uid/gid 1000:** OMV NFS exports squash root (root_squash is the OMV default;
there is no `no_root_squash` on the existing shares). A container running as root
therefore cannot write into the export — it lands as `nobody`. The mail-archiver
Deployment (**H2-149**) must run with `runAsUser: 1000, runAsGroup: 1000` so the
keyring it creates is owned by 1000. Losing this keyring means re-consenting every
OAuth mailbox, so it is a real asset — `Retain` policy on the PV.

## 2. NFS export — do it in the OMV UI

The export must be in **OMV's config database**, not just `/etc/exports`: OMV
regenerates `/etc/exports` from its DB on every "Apply" of the NFS service, so a
hand-added line silently disappears later. This is the trap the worker flagged in
ADR-018's follow-up.

1. **Storage → Shared Folders → Add**
   * Name: `mail-archiver-keys`
   * Filesystem: `cda9bf6e…` (the 3.7 TB btrfs data disk)
   * Relative path: `mail-archiver/keys`
2. **Services → NFS → Shares → Add**
   * Shared folder: `mail-archiver-keys`
   * Client: `192.168.1.179` — Privileged: off, Extra options: *(blank)*
   * Save, then **Add** a second share row for the same folder, Client
     `192.168.1.111`, same settings.
3. Apply the pending config (orange "Apply" banner) or:
   ```bash
   omv-salt deploy run nfs
   exportfs -ra
   ```
4. Verify **on OMV**:
   ```bash
   showmount -e localhost | grep mail-archiver
   # expected:
   # /srv/dev-disk-by-uuid-cda9bf6e-0ed1-4e61-b063-1cbab7351886/mail-archiver/keys 192.168.1.111,192.168.1.179
   ```

Verify from a client (e.g. homelab-2nd):
```bash
showmount -e 192.168.1.180 | grep mail-archiver
```

### Escape hatch (only if the UI is not available)

```bash
SHARE=/srv/dev-disk-by-uuid-cda9bf6e-0ed1-4e61-b063-1cbab7351886
cp /etc/exports /etc/exports.bak-$(date +%F)
grep -q "$SHARE/mail-archiver/keys" /etc/exports || cat >> /etc/exports <<EOF

# H2-146 mail-archiver DataProtection keyring
$SHARE/mail-archiver/keys 192.168.1.179(rw,sync,no_subtree_check) 192.168.1.111(rw,sync,no_subtree_check)
EOF
exportfs -ra
showmount -e localhost | grep mail-archiver
```

Re-do it in the UI afterwards, or the next NFS "Apply" will drop it.

## 3. MinIO user + prefix policy

Run `provision-omv.sh` **on OMV as root**. It is idempotent and reads the MinIO
root credentials from `/opt/homelab/minio/.env` (never from the repo, never from
chat).

```bash
scp omv/mail-archiver-prep/provision-omv.sh root@openmediavault.local:/root/
ssh root@openmediavault.local 'bash /root/provision-omv.sh'
```

It will:

* create the `cnpg-mailarchiver-backup` MinIO user with a freshly generated secret,
* create + attach the `cnpg-mailarchiver-backup-rw` policy
  (`cnpg-backups` ListBucket **only** for prefix `mail-archiver/*`, plus
  Get/Put/Delete/AbortMultipartUpload/ListMultipartUploadParts under
  `cnpg-backups/mail-archiver/*`),
* print the **access key / secret key once**, for you to store in 1Password.

Re-running it rotates nothing: if the user exists it only re-applies the policy.
Pass `--rotate` to mint a new secret.

### Hand-off to the executor (AC3)

Store in 1Password (vault `Homelab`, item `MinIO — cnpg-mailarchiver-backup`):

```
endpoint   http://openmediavault.local:9000
bucket     cnpg-backups
prefix     mail-archiver/
access key <printed by the script>
secret key <printed by the script>
```

**Never** paste those values into Itsaplan, chat, or the repo. ST2 (H2-147) takes
them from 1Password into `*Secret.sops.yaml` — SOPS+age, repo stays public-safe.

## 4. Proof (the ticket's acceptance criteria)

Run these with the **new** credentials, from anywhere with `mc` or the AWS CLI.
`mc` is easiest (it runs as a container on OMV, so nothing to install):

```bash
# ---- on OMV ----
cd /opt/homelab/minio
MC="docker run --rm -i --network host minio/mc:RELEASE.2025-08-13T08-35-41Z"

# 1. happy path: list the prefix -> HTTP 200, empty list is fine
$MC alias set newuser http://127.0.0.1:9000 "<ACCESS>" "<SECRET>"
$MC ls newuser/cnpg-backups/mail-archiver/ ; echo "exit=$?"
# 2. write + read + delete a canary object
echo ok | $MC pipe newuser/cnpg-backups/mail-archiver/.h2-146-probe
$MC cat newuser/cnpg-backups/mail-archiver/.h2-146-probe
$MC rm newuser/cnpg-backups/mail-archiver/.h2-146-probe
# 3. NEGATIVE control: the same creds must NOT reach a sibling prefix
$MC ls newuser/cnpg-backups/karakeep/ ; echo "exit=$?"   # expect AccessDenied, non-zero
$MC ls newuser/ ; echo "exit=$?"                          # expect AccessDenied, non-zero
```

Expected: (1) and (2) succeed; (3) fails with `Access Denied` — that is what proves
SCP-style least privilege rather than "another user with root creds".

With the AWS CLI the equivalent is:

```bash
AWS_ACCESS_KEY_ID=<ACCESS> AWS_SECRET_ACCESS_KEY=<SECRET> \
aws --endpoint-url http://openmediavault.local:9000 s3api list-objects-v2 \
  --bucket cnpg-backups --prefix mail-archiver/    # HTTP 200
```

## 5. Rollback

```bash
# MinIO: remove the scoped user only (keeps any objects already archived)
docker run --rm -i --network host minio/mc sh -c \
  'mc alias set a http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"; \
   mc admin user remove a cnpg-mailarchiver-backup; \
   mc admin policy remove a cnpg-mailarchiver-backup-rw'
# NFS: remove the two share rows in Services -> NFS -> Shares, Apply
```

Nothing here is destructive: no objects are created other than the canary probe,
and the keyring directory is empty until the app first boots.
