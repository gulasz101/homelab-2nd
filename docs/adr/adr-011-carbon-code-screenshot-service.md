# ADR-011: Carbon code-screenshot service on homelab-2nd

Date: 2026-08-12
Status: Proposed
Supersedes: nothing
Superseded by: nothing

## Context

The Supreme Leader asked to deploy `https://github.com/carbon-app/carbon` into `homelab-2nd` so the homelab can generate code screenshots locally. The homelab guardrails require Flux + SOPS + observability + Cloudflare Tunnel ingress. Every durable workload needs CNPG + OMV MinIO backups.

Three questions arose immediately:

1. Does `carbon-app/carbon` ship a container or Helm chart?
2. If not, is building one worth the effort?
3. What is the smallest stateless version that satisfies the actual use case?

## Decision

Deploy the community `petersolopov/carbonara` API image in a new `carbon` namespace, not the full `carbon-app/carbon` editor, and expose it as `https://carbon.voitech.dev` via a dedicated Cloudflare Tunnel.

### Rationale

1. **No official container for the upstream repo.** `carbon-app/carbon` is a Next.js app built for Vercel. It has no `Dockerfile`, no `docker-compose.yml`, and its image-export code relies on `chrome-aws-lambda` + `puppeteer-core`, which are AWS-Lambda-specific. Making it run in Kubernetes requires a custom container and patches.
2. **No database or state needed.** The service is a pure code→image transformer. A stateless Deployment with an emptyDir for `/tmp` and `/dev/shm` is sufficient.
3. **carbonara already works.** `petersolopov/carbonara` is a small MIT-licensed API that accepts a POST on `/api/cook` and returns a Carbon-style screenshot. It publishes a working Dockerfile based on `node:18-alpine3.17` with Chromium pre-installed.
4. **Fits the homelab topology.** No durable data means no PVC, no CNPG, no MinIO backups, no NFS mount.
5. **SSO is unnecessary.** The service has no user accounts or admin panel, so there is no identity provider to wire up.

## Consequences

### Positive

- Fast to deploy: a single Deployment + Service + Cloudflared.
- No database, no backup, no persistent storage complexity.
- Fully aligned with GitOps, SOPS, Cloudflare Tunnel, and observability rules.
- Memory footprint is modest (~512Mi–1Gi).

### Negative / Risks

- The public Carbon website (`https://carbon.now.sh`) is a hard dependency. If the layout changes, `carbonara` screenshots may break.
- Only an API: no interactive editor, no saved snippets, no user accounts.
- Image uses `petersolopov/carbonara:latest`, which has no stable tags. We must pin by digest after the first run.
- Chromium inside the container runs with `--no-sandbox`, which is a known security trade-off for containerized headless browsers.

## Alternatives considered

| Option | Why rejected |
|---|---|
| Build/push own container from `carbon-app/carbon` | Would need custom Dockerfile, patch the screenshot backend, disable Firebase, and still not save snippets. Much more work for the same core feature. |
| Use Kubernetes Ingress + cert-manager | Violates the Cloudflare Tunnel-only public ingress guardrail. |
| Add a Postgres/CNPG cluster “just in case” | No state to store; adds unnecessary backups and ops burden. |
| Deploy the carbonara API without observability | Violates the “every service observable” guardrail. |

## When to revisit

Revisit this ADR if:

- The Supreme Leader wants the interactive Carbon editor UI (Phase 2).
- `carbon.now.sh` layout changes and break screenshots.
- The `latest` image becomes unreliable or unpublishable.
- We need to add snippet persistence, which would introduce a database and invalidate the stateless design.

## References

- Upstream Carbon repo: https://github.com/carbon-app/carbon
- Carbonara repo: https://github.com/petersolopov/carbonara
- Proposed manifests: `apps/carbon/` (to be created after plan approval)
- Tracking note: `homelab/tracking/2026-08-12-carbon-deployment-plan.md`
- `apps/kustomization.yaml`

## Open decision

This ADR is in **Proposed** status because the Supreme Leader has not yet confirmed whether the API-only path is acceptable or if he wants the full Carbon editor. Approve this ADR to proceed with Phase 1.
