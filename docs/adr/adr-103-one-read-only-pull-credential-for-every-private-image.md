# ADR-103: One read-only pull credential for every private image, not one per service

- **Status:** Accepted, implemented
- **Date:** 2026-10-29
- **Deciders:** Wojtek (owner), Andrzej (CTO, homelab-2nd)
- **Tracked by:** GUL-579; first application: Riff Radar (GUL-550)
- **Amends:** ADR-101 ("its own pull secret when the package is private" — the pull side is now a
  platform concern, the publish side stays per-app). ADR-101 was still open in PR #95 when this
  landed; the practice it describes is what we already run.

## Context

ADR-101 settled how our own images are **built and published**: Actions builds, a version tag
publishes `ghcr.io/gulasz101/<repo>:<version>`, and the package stays private because the source is
private. It left the **pull** side as an exercise for each service, and that is where Riff Radar
stopped dead: the package is private, `imagePullSecrets` pointed at a Secret that cannot exist,
and the kubelet answered `403 Forbidden` forever.

Why the agent could not simply fix it:

- GitHub issues personal access tokens only through a browser session. An agent with `gh`
  authenticated as the owner can read a package and push one, but cannot mint a narrower credential.
- The token that *is* on the box is the owner's `gh` token: `write:packages`, `admin:org`, wide
  repo access. Putting that in a cluster Secret (or a GitHub Actions secret) is exactly the failure
  this homelab is built to avoid — a public repo and a small cluster do not get to share one
  all-powerful credential.
- So every private in-house image needed a human to click before its pod could start. That is a
  platform gap, not a Riff Radar bug: it repeats for every private image, forever.

The three shapes considered were: an in-house OCI registry in k3s, one platform-level read-only
package token, or public packages. Public packages are out — the source is private, so a public
image is a source leak wearing a different hat.

## Decision

**Exactly one pull credential for every private image the cluster runs.** A classic GitHub PAT on
the owner's account with `read:packages` **and nothing else**, stored as one SOPS file:

```
apps/ghcr-pull/ghcr-pull.sops.yaml
  Secret/ghcr-pull (type kubernetes.io/dockerconfigjson)
    - namespace: flux-system   (image-reflector-controller reads it via ImageRepository.secretRef)
    - namespace: <each app namespace that runs a private image>
```

**Why it sits under `apps/` and not `infrastructure/`.** The file carries one Secret per consuming
namespace, and those namespaces are created by the app roots. `infrastructure` is reconciled before
`apps` (`apps` has `dependsOn: infrastructure`), so on a rebuild from Git a Secret aimed at a
namespace that does not exist yet fails the whole `infrastructure` Kustomization — and every
dependent with it. Resource kind ordering puts `Namespace` before `Secret` inside one apply, so the
`apps` root creates both in the same pass. A platform object delivered in the app root is a wart;
a cluster that cannot rebuild is worse.

Mechanics that make it a platform primitive rather than one more snowflake:

- **Minted once, by the owner, through `scripts/ghcr-pull-credential.sh mint <ns>...`.** The token
  is read silently from the terminal, encrypted straight into the SOPS file, and never touches disk
  in plaintext or a shell history.
- **New consumers need no human.** `scripts/ghcr-pull-credential.sh add <ns>` decrypts the existing
  ciphertext with the repo age key, writes the same dockerconfigjson into the new namespace and
  re-encrypts. The agent can do that alone; the token never leaves SOPS.
- **A new private service consumes it by name only:** `imagePullSecrets: [ { name: ghcr-pull } ]` on
  the pod spec and `secretRef: { name: ghcr-pull }` on its `ImageRepository`.
- **One namespace list, one rotation.** Rotating the token re-runs `mint` with the full namespace
  list; the ciphertext of every namespace changes in one commit.
- **GHCR stays the only registry.** No in-cluster registry, no pull-through mirror.

Implemented the same day: Riff Radar (GUL-550) had already shipped a per-service
`riffradar-ghcr-pull` Secret, minted from the owner's `read:packages` token. The platform file was
built from that same token — verified byte-identical by hashing the decrypted credential, so **no
rotation and no downtime** — the deployment and its `ImageRepository` now name `ghcr-pull`, and the
per-service file is deleted. That is the whole migration for a new consumer from now on: a name and
a script run.

## Consequences

- A private image is a five-minute job for an agent again: reference the Secret, add the namespace,
  push. Zero GitHub clicks per service.
- Blast radius of the credential: read-only access to the owner's private container packages, i.e.
  the images themselves. No source, no push, no repo, no org, no workflows. That is a far smaller
  surface than the `gh` token it replaces as the "obvious" alternative.
- The credential is long-lived and lives in a public repo — as ciphertext, encrypted to the repo age
  key, exactly like every other secret here. Rotation is one command, not a controller.
- Riff Radar stays blocked until the owner spends the one click. After that, never again — and the
  proof obligation is on the next private service, not on this ADR.
- Nothing new runs in the cluster: no registry to back up, no bucket, no PVC, no second failure mode
  on the storage box.

## Alternatives considered

- **In-house OCI registry in k3s (Zot or `registry:2`, S3-backed on OMV MinIO)** — GUL-579 option 1.
  Attractive because the cluster would pull over the ClusterIP with no credential at all. It does not
  survive contact with ADR-101: the images are built in Actions and published to GHCR, so an
  in-cluster registry holding them is a **mirror**, and a mirror of a private package must
  authenticate to GHCR to fetch the tag — the same credential, one hop earlier. Removing the
  credential entirely requires moving the *build* in-house too, which ADR-101 rejected (the cluster
  consumes images, it does not produce them) and which needs a runner, layer cache and build
  privileges the homelab does not have. On top of that: a stateful service, a MinIO bucket, a backup
  story, an upgrade path and a public push endpoint for CI (or a push credential sitting in GitHub,
  which is worse than a read credential in SOPS). Deferred, not refuted — see *When to revisit*.
- **Make the packages public** — GUL-579 option 3. Rejected by ADR-101 and by `riff_radar` being a
  private repo: a public image publishes the source it was built from.
- **Per-service PAT** — the shape ADR-101 implied, and what GUL-550 was about to do. Rejected: N
  clicks, N rotations, N credentials to forget, and no single command that proves the fleet is
  consistent.
- **Put the owner's `gh` token in a Secret.** Banned by the house rules and by common sense:
  `write:packages` plus `admin:org` in a cluster is a lateral-movement kit.
- **A GitHub App with `Packages: read`, minting short-lived installation tokens in a CronJob.**
  Strictly better credential hygiene (nothing long-lived, rotation is automatic) and the right answer
  if we ever run this at a scale that needs it. Rejected for now because creating the App is another
  browser flow, its private key is another SOPS secret, and it adds a controller-shaped Job whose
  failure mode is "every image stops pulling in 55 minutes". Two moving parts to save one click.
- **Registry credentials in each node's containerd config.** Rejected: invisible to GitOps, one box
  to hand-fix after a rebuild, and it silently diverges from the repo.

## When to revisit

- **Builds move in-house** (self-hosted Actions runner or a build Job on a k3s node) and push to an
  in-cluster registry. At that moment the pull credential disappears entirely and Zot/`registry:2`
  becomes the right answer — this is the trigger that flips option 1 from "one more service" to
  "one less credential".
- **We need packages from an account we cannot mint a personal token for** (an org with SSO
  enforcement, or a shared machine user).
- **More than ~8 namespaces** consume the credential: the one-file-many-docs shape stops being
  readable, and `kubernetes-replicator` (copy from `flux-system`) starts to win.
- **`read:packages` proves too wide** (packages we would not want the cluster to read at all): split
  per owner-org, not per service.
- **GitHub changes package permissions** such that a fine-grained or App-scoped read token stops
  needing a browser; the decision stands, only the minting step shrinks.
