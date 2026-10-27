# Renovate

Renovate watches the `cloudflare/cloudflared` image tag in the Kubernetes manifests. When
Cloudflare publishes a newer tag, it opens one PR that bumps every tunnel to that tag. It never
merges the PR; a human does.

## What it watches

- `apps/**/*.yaml`
- `infrastructure/**/*.yaml`
- only the `image:` lines, through Renovate's `kubernetes` manager
- `cloudflare/cloudflared` is grouped as `cloudflared tunnels`, so all 19 manifests land in one PR

It does not touch `:latest`, digests, or any other image. Other images in those folders are
disabled for now; add another package rule in `renovate.json` to bring them in later.

## Run it by hand

In GitHub: **Actions -> Renovate -> Run workflow**.

Locally, from the repo root:

```bash
npx --yes renovate --platform=github --token="$(gh auth token)" \
  --dry-run=lookup --log-level=debug gulasz101/homelab-2nd
```

The dry run prints what Renovate would propose and changes nothing. To test a branch that is not
`main`, add `--platform=local` and run it inside that checkout.

## When it opens a PR

1. Check that the diff only changes `image: cloudflare/cloudflared:<tag>` lines.
2. Read the Cloudflare release notes for breaking changes.
3. Merge the PR. Flux applies the new tag on the next reconcile.

If the update is wrong, close the PR. Renovate will not recreate it for the same version.

## One-time setting for the owner

GitHub Actions cannot open PRs by default. Pick one:

- **Settings -> Actions -> General -> Workflow permissions -> "Allow GitHub Actions to create and
  approve pull requests"**, or
- create a fine-grained personal access token with `contents: write` and `pull_requests: write`,
  and save it as the repository secret `RENOVATE_TOKEN`.

The workflow uses `RENOVATE_TOKEN` when it exists and falls back to `GITHUB_TOKEN` otherwise. With
neither the setting nor the token, the run logs a warning and cannot create the PR.

The schedule runs daily at 04:00 UTC.
