---
title: "Fix plaintext Mattermost webhook URL Secret flagged by nightly security scan"
status: done
priority: high
created: 2026-08-17
labels:
  - security
  - secrets
  - sops
  - observability
  - mattermost
assigned: andrzej
source: nightly-security-scan
scan_date: 2026-08-17
scan_commit: fa43e42
---

## Context

The nightly security scan (`homelab-security-scan` cronjob, job `89499b7d034b`) reported a **critical** finding:

```
Plaintext Secret: infrastructure/observability/homelab-node-mattermost-webhook-url-secret.yaml
```

The repo is public, so any Kubernetes `Secret` resource must be SOPS-encrypted with age. Guardrail #5 is non-negotiable.

## What the Secret does

- **Name:** `homelab-node-mattermost-webhook-url`
- **Namespace:** `observability`
- **Consumer:** `AlertmanagerConfig` `homelab-node-mattermost-alerts` in `infrastructure/observability/homelab-node-alertmanager-config.yaml`, which routes `alertgroup: homelab-node` alerts to a Mattermost channel via a Slack-compatible webhook.

The Secret value is a webhook URL for `chat.voitech.dev`. If left plaintext in the repo, anyone could read it and spam the alert channel.

## Root cause

The file `homelab-node-mattermost-webhook-url-secret.yaml` was a plain Kubernetes `Secret` with base64-encoded `data.url`. It had no `sops:` block and did not follow the repo convention of naming SOPS-encrypted files `*.sops.yaml`.

An older tracking note (`2026-07-30-homelab-2nd-thermal-crash-barman-plugin.md`) references a previous encrypted version named `homelab-node-mattermost-webhook-url.sops.yaml`, so the encryption was likely lost during a later rename or regeneration.

## Fix

1. Created a SOPS-encrypted replacement at `infrastructure/observability/homelab-node-mattermost-webhook-url.sops.yaml` using the repo's age public key from `.sops.yaml`:
   ```bash
   cd /Users/wojciechgula/Projects/homelab-2nd
   sops --encrypt infrastructure/observability/homelab-node-mattermost-webhook-url-secret.yaml \
        > infrastructure/observability/homelab-node-mattermost-webhook-url.sops.yaml
   git rm infrastructure/observability/homelab-node-mattermost-webhook-url-secret.yaml
   ```
2. Updated `infrastructure/kustomization.yaml` to reference the new `.sops.yaml` file.
3. Verified the encrypted file contains no plaintext URL:
   ```bash
   grep -i 'chat.voitech.dev\|hooks/' infrastructure/observability/homelab-node-mattermost-webhook-url.sops.yaml || echo 'OK: no plaintext webhook URL'
   ```
4. Verified `kubectl kustomize infrastructure` still renders correctly.
5. Committed and pushed:
   ```bash
   git add infrastructure/observability/homelab-node-mattermost-webhook-url.sops.yaml \
           infrastructure/kustomization.yaml
   git commit -m "security: SOPS-encrypt Mattermost webhook URL Secret" \
              -m "Replaces plaintext infrastructure/observability/homelab-node-mattermost-webhook-url-secret.yaml" \
              -m "with an age-encrypted *.sops.yaml file referenced by the infrastructure Kustomization." \
              -m "Fixes nightly security scan finding: Plaintext Secret manifests = 1."
   git push
   ```
   Commit: `a109884`
6. Reconciled Flux on `homelab-2nd`:
   ```bash
   ssh -i ~/.ssh/id_ed25519.homelab-2nd gulasz101@192.168.1.179 \
       'sudo kubectl -n flux-system annotate --overwrite gitrepository flux-system reconcile.fluxcd.io/requestedAt=$(date +%s)'
   ssh -i ~/.ssh/id_ed25519.homelab-2nd gulasz101@192.168.1.179 \
       'sudo kubectl -n flux-system annotate --overwrite kustomization infrastructure reconcile.fluxcd.io/requestedAt=$(date +%s)'
   ```
7. Verified the `infrastructure` Kustomization reached the new revision and the Secret still exists with the `url` key:
   ```bash
   ssh -i ~/.ssh/id_ed25519.homelab-2nd gulasz101@192.168.1.179 \
       'sudo kubectl get kustomization infrastructure -n flux-system'
   # Applied revision: main@sha1:a109884a2f534834384e14230868e4b973e56d7b
   ssh -i ~/.ssh/id_ed25519.homelab-2nd gulasz101@192.168.1.179 \
       'sudo kubectl get secret -n observability homelab-node-mattermost-webhook-url'
   ```
8. Re-ran the nightly security scan locally:
   ```bash
   "$HOME/.hermes/profiles/andrzej/scripts/homelab-security-scan.sh"
   ```
   Result:
   - `Plaintext Secret manifests`: **0**
   - `Critical issues`: **0**
   - `Warnings`: **4** (one actionable Trivy KSV-0109 misconfig, plus upstream defaults)

## Remaining actionable warning

The scan still reports one non-secret actionable misconfig:

```
KSV-0109: ConfigMap with secrets in Kubernetes/general
apps/llm-hub/litellm-key-provisioner-configmap.yaml
```

This is the LiteLLM key-provisioner ConfigMap. It contains a Python script that references `LITELLM_MASTER_KEY` and virtual-key env var names, but the actual credentials live in the SOPS-encrypted `litellm-user-keys` Secret. Trivy flags the ConfigMap because the script talks about secrets. This is a false-positive/scan-noise issue, not a credential leak, and should be handled under task `004-reduce-security-scan-noise.md` if we want to suppress it.

## Recommended follow-up

Because the webhook URL was visible in the public repo for an unknown period, consider **rotating the Mattermost webhook**:
1. In Mattermost System Console → Integrations → Incoming Webhooks, disable/delete the existing webhook and create a new one.
2. Update `infrastructure/observability/homelab-node-mattermost-webhook-url.sops.yaml` with the new URL using the same SOPS/age recipe.
3. Commit, push, and reconcile.
4. Send a test alert (e.g. via `curl` to Prometheus Alertmanager) to confirm the new webhook works.

I did **not** rotate it automatically because doing so would briefly break homelab-node alerting until the new URL is committed and reconciled, and because the Supreme Leader may prefer to handle webhook rotation in Mattermost directly.

## Lessons

- A public repo should never contain `kind: Secret` without a `sops:` block, even for "just a webhook URL." Scanners catch it, and readers can abuse it.
- Renaming SOPS-encrypted files or recreating Secrets from templates must preserve the `*.sops.yaml` extension and the `sops:` metadata. The missing extension (`-secret.yaml`) is what allowed the plaintext file to slip in.
- SOPS encryption with the age public key does not require the private key on the workstation, so fixes like this can be done safely without exposing the age key.

## Files changed

- Deleted: `infrastructure/observability/homelab-node-mattermost-webhook-url-secret.yaml`
- Added: `infrastructure/observability/homelab-node-mattermost-webhook-url.sops.yaml`
- Modified: `infrastructure/kustomization.yaml`

## Verification

- [x] `kubectl kustomize infrastructure` renders the new encrypted Secret.
- [x] Security scan reports `Plaintext Secret manifests: 0`.
- [x] Flux reconciled the `infrastructure` Kustomization to `main@a109884`.
- [x] `homelab-node-mattermost-webhook-url` Secret exists in `observability` namespace with the `url` key.
