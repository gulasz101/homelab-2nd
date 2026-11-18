# Runbook: moving a local-path volume to another node

A local-path PV is a directory on one node with a hard `nodeAffinity`; rescheduling never moves it.
**CNPG databases don't use this runbook**: they move by replica + switchover
(`decommission-node.md`, step 3). Everything else does.

## Steps

1. **Pin first** (in Git): the owner's `nodeSelector` → the destination node, merged and reconciled.
   The new pod goes `Pending` until its volume follows. That's the safe state.
2. **Keep Flux from scaling it back** if the manifest sets `replicas:`: suspend the Kustomization
   (`kubectl -n flux-system patch kustomization apps --type merge -p '{"spec":{"suspend":true}}'`)
   for the window, and resume it at the end. HelmReleases here have no drift detection and leave a
   scaled-down Deployment alone.
3. **Move:**
   ```sh
   scripts/pvmove-group.sh <ns> "deploy/<owner> ..." "<cronjob> ..." "<pvc>:<dest> ..."
   # one claim with its owner already stopped:
   scripts/pvmove.sh <ns> <pvc> <dest>
   ```
   Done when every claim prints `bound to <pv>-<dest> on <dest>` and the owner is Running there.
4. **Resume Flux** and check every Kustomization goes `Ready` (if one reports
   `PersistentVolumeClaim … spec is immutable`, the field-manager step didn't run; see below).
5. Verify the app from a client (UI, API, a query), not just the pod status.

## What the scripts handle (and why)

- **Data path:** a privileged busybox pod on each node (`nodeName`, so cordons don't stop it), the
  source mounted read-only. `kubectl exec … tar` → a local staging file (`STAGE_DIR`, needs room for
  the volume) → `kubectl exec -i … tar x`. kubectl-only, so it works from anywhere with a kubeconfig.
- **`kubectl exec` truncates stdout** when the remote process exits before the stream drains (it
  delivered 75% of a 21 MB stream over a phone hotspot, websocket and SPDY alike). The remote shell
  lingers after `tar` (`PVMOVE_LINGER`), and the staged file must match an in-pod `sha1sum` (4 tries).
- **Refusals:** a live pod on the claim, a non-empty destination (a half-copy from a failed run:
  inspect and clear it by hand), an entry-count mismatch after extraction. All of them leave the old
  claim and PV untouched.
- **Swap:** a new PV `<old>-<dest>` with the same directory path, `nodeAffinity` on the destination
  and a `claimRef` to the same namespace/name. That pre-binds it, so whatever recreates the PVC (the
  script, Flux, a StatefulSet template) binds to it. The old PV is set to `Retain` *before* its claim
  goes: the source directory stays on the old disk as a cold copy (delete it by hand later).
- **Finished Job pods** still hold `kubernetes.io/pvc-protection`; they're deleted first.
- **Flux field ownership:** a PVC recreated by hand gets `volumeName` (and on some PVCs
  `storageClassName`, which the Git manifest leaves to the default class) co-owned by the field
  manager `node-move-pv-binding`. Without it Flux adopts those fields and its next apply tries to
  remove them: `spec is immutable`.

## Special owners

- **Prometheus** (prometheus-operator undoes a StatefulSet scale): `kubectl -n observability patch
  prometheus <name> --type merge -p '{"spec":{"replicas":0}}'`, move, then back to `1`.
- **Pi-hole** and anything else the house depends on: `service-cutover.md` (pre-pull, deadman).
