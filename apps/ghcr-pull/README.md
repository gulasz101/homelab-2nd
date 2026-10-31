# `ghcr-pull` — the platform's one credential for private images

Decision: [ADR-103](../../docs/adr/adr-103-one-read-only-pull-credential-for-every-private-image.md).
First consumer: Riff Radar ([GUL-550](/GUL/issues/GUL-550)).

Private images (`ghcr.io/gulasz101/<repo>`, private package per ADR-101) cannot be pulled by the
kubelet without a credential, and GitHub only mints that credential in a browser. So the platform
holds **one** narrow credential and every private service reuses it. This directory is where the
encrypted Secret lives.

```
apps/ghcr-pull/ghcr-pull.sops.yaml
  Secret/ghcr-pull, type kubernetes.io/dockerconfigjson
    namespace: flux-system   <- ImageRepository.secretRef (image-reflector-controller)
    namespace: <app ns>      <- imagePullSecrets on the pod spec
```

It lives under `apps/` because those namespaces are created by the app roots and `infrastructure`
is reconciled first — a Secret for a not-yet-existing namespace freezes that whole Kustomization on
a rebuild. The `apps` root creates the namespaces and this Secret in one apply.

## What the token is

A **classic** GitHub PAT, owner `gulasz101`, scope **`read:packages` only**. Nothing else: no
`repo`, no `workflow`, no `write:packages`, no `admin:*`. It is a pull credential for private
packages, not a deploy key and not a replacement for `gh`.

## One-time setup (the only human step that exists)

Mint the token at <https://github.com/settings/tokens/new> (classic, expiry: 1 year, tick
`read:packages`), then, in a clone of this repo with the repo age key available:

```bash
scripts/ghcr-pull-credential.sh mint riffradar
```

It prompts for the token with echo off, writes the SOPS file, and refuses to continue if the
plaintext ever appears in the output file. Paste the token from your password manager — never into
chat, an issue comment or a commit. Then commit the ciphertext. The file is already listed by
`apps/ghcr-pull/kustomization.yaml` and wired into the `apps` root as `- ghcr-pull/`.

## Adding a namespace later (no human, no new token)

```bash
scripts/ghcr-pull-credential.sh add <namespace>
```

The token is decrypted from the existing ciphertext with the repo age key and re-encrypted into the
new namespace (the file keeps every namespace it already had). An agent can run this alone; the
plaintext never leaves the process.

Then, in the service's manifests:

```yaml
# pod spec
imagePullSecrets:
  - name: ghcr-pull
```
```yaml
# ImageRepository
spec:
  secretRef:
    name: ghcr-pull
```

Note that the pull secret alone is not enough for the image automation: `image-reflector-controller`
resolves tags from its own namespace, so `ghcr-pull` must exist in `flux-system` too — the script
writes it there by default, keep it that way.

## Rotation

Re-run `mint` with the full namespace list (the token in your password manager changes, the shape
does not):

```bash
scripts/ghcr-pull-credential.sh mint flux-system riffradar <...>
```

One commit rotates every consumer. Bump any `secret-version` pod-template annotation on the pods
that mount the Secret as a volume; `imagePullSecrets` is read at pull time, so a running pod keeps
its existing image and only the *next* pull uses the new credential.

## Why not an in-house registry

Because it would not remove the credential: the images are built in Actions and published to GHCR
(ADR-101), so an in-cluster registry is a mirror, and a mirror of a private package must
authenticate to GHCR to fetch it. The credential disappears only when the build moves in-house —
that is the revisit trigger recorded in ADR-103, not a reason to run a registry today.

## Test

```bash
bash scripts/tests/ghcr-pull-credential-check.sh
```

Uses an ephemeral age key and a fake token; proves mint/add/rotation shape without the real
credential. Runs as part of `scripts/check.sh`.
