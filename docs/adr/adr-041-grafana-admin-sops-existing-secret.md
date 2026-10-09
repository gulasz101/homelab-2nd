# ADR-041: Grafana's local admin consumes the SOPS secret (`admin.existingSecret`), never the chart's generated one

## Status

Accepted — 2026-10-09 · Issue H2-110 (verification of the openGym observability package,
parent H2-106). Applies the homelab-wide "SOPS is the source of truth for every credential"
rule to the Grafana Helm release.

## Context

While verifying H2-110's third acceptance criterion (the `fitness-overview` Grafana
dashboard is provisioned), a hash comparison exposed a silent credential drift:

- The live `observability/grafana` Secret's `admin-password` hash was **not** the hash of
  the value in the repo's SOPS-encrypted `observability/grafana-admin-credentials`.
- The SOPS Secret and `grafana-admin-credentials` existed in the cluster and appeared in
  `infrastructure/kustomization.yaml` — but **nothing consumed it**. It was dead weight.

The cause: `infrastructure/observability/grafana-helm-release.yaml` set

```yaml
admin:
  userKey: admin-user
  passwordKey: admin-password
  password: "not-used"
```

`admin.password` is not a key the chart honours when `admin.existingSecret` is empty —
and the chart only suppresses its **own** auto-generated `grafana` Secret when
`admin.existingSecret` is set. So on install the chart minted a random admin password of
its own, stored it in its generated `grafana` Secret, and ran on that. The repo looked
correct; the live system ignored it. A "secret in the repo" is not a "secret that is used".

This drift was found while responding to a credential **leak**: a verification probe
(BusyBox `wget --password` on the dashboards sidecar, which has no `--user/--password`
options) echoed the live admin password into a shell transcript. Because the value was
treated as compromised, the rotation and the wiring fix shipped together.

## Decision

**Set `admin.existingSecret: grafana-admin-credentials` on the Grafana HelmRelease**, keep
`userKey: admin-user` / `passwordKey: admin-password`, and drop the vestigial
`admin.password: "not-used"`.

The chart then builds `valueFrom.secretKeyRef {name: grafana-admin-credentials, key: …}`
for `GF_SECURITY_ADMIN_USER`/`GF_SECURITY_ADMIN_PASSWORD` and, because `existingSecret` is
set, **suppresses its auto-generated `grafana` Secret**. The local admin user now tracks
the SOPS value by construction, and a password rotation is a one-file GitOps change.

Basic auth stays disabled (`GF_AUTH_BASIC_ENABLED=false`) — Authentik OIDC is the only
interactive login path. The local admin is retained solely for API/automation access.

## Consequences

**Positive**

- The repo value and the live value can no longer diverge silently: the chart has no
  password of its own to drift to, and `secret/grafana` no longer exists.
- Rotating the admin password is a normal SOPS edit + push (commit `4bb36ca` did exactly
  that), verified by comparing sha256 of repo vs live without printing either.
- Removes a class of "I set it in GitOps but the app ignores it" surprise for any chart
  with an `existingSecret`-style knob.

**Negative**

- Chart upgrades must keep honoring `admin.existingSecret`; a future major bump that
  renames the value would need the same re-verification (see "When to revisit").
- One more place where Grafana's local admin exists. Accepted because it is now the
  SOPS value, not an opaque generated one.

## Alternatives considered

1. **Leave the chart's generated Secret and add `existingSecret` later.** Rejected: that
   is exactly the drift we just paid to discover. Fix it at the same commit as the
   rotation.
2. **Keep `admin.password` inline.** Rejected: a plaintext password would enter the public
   repo, violating the SOPS-only rule; and the chart does not reliably honour that key
   anyway.
3. **`GF_SECURITY_DISABLE_INITIAL_ADMIN_CREATION: "true"` and rely on OIDC only.**
   Considered. Rejected for now: it removes the API/automation admin path used for
   verification and scripted reads. Revisit if the homelab moves all automation to
   service accounts.

## When to revisit

- A Grafana chart major version changes how `admin.existingSecret` is consumed (re-prove
  by hash: repo SOPS value vs live Secret, and confirm `secret/grafana` stays absent).
- The homelab standardizes on service accounts / API tokens for all automation and the
  local admin can be disabled entirely
  (`GF_SECURITY_DISABLE_INITIAL_ADMIN_CREATION=true`, `admin.existingSecret` removed).
- A general secret-consumption checker is added to CI that would catch this class
  automatically (preferred long-term fix — this ADR then becomes one instance of it).
