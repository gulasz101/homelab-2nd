# ADR-004: Honcho runs on k3s with CNPG and local-only NodePort access

## Status

Accepted

## Context

Honcho was running on the Hermes host under OrbStack Docker Compose (`~/Projects/honcho-experiment`). That gave us:
- A local Postgres 15 container with the actual memory data.
- A deriver and API pair running from source.
- Hand-managed `.env` credentials and a direct LiteLLM key.

The rest of the homelab is GitOps-managed on `homelab-2nd` k3s via Flux. Keeping Honcho outside that pattern meant:
- It was not rebuildable from the repo.
- It mixed with the Hermes host's lifecycle.
- It could not use the durable CNPG + OMV MinIO backup pattern already established for Mattermost and Nextcloud.

We needed to migrate it into the k3s platform.

## Decision

Move Honcho to k3s `homelab-2nd` as a set of plain Kubernetes manifests managed by Flux in `gulasz101/homelab-2nd`.

### Component choices

- **Postgres:** CloudNativePG `Cluster` (PG16), single instance on `local-path` for live data. WAL archiving + daily base backups to OMV MinIO `s3://cnpg-backups/honcho/`.
- **Redis:** plain Deployment + PVC for cache/queue (rebuildable; no backup needed).
- **Image:** fork `gulasz101/honcho` of `plastic-labs/honcho`, build via GitHub Actions to `ghcr.io/gulasz101/honcho:latest`.
- **Secrets:** SOPS/age Kubernetes Secrets using `stringData:`.
- **Ingress:** none. Honcho is exposed only via NodePort `192.168.1.179:30800` on the LAN. No Cloudflare Tunnel.
- **LLM routing:** LiteLLM proxy in the `llm-hub` namespace remains the single router. Honcho points to the in-cluster service `http://litellm.llm-hub.svc.cluster.local:4000`.

### Why not a Helm chart

There is no stable upstream Helm chart for Honcho. We therefore use raw manifests under Flux, which is permitted by Guardrail 2 with justification documented here.

### Why not public ingress

Honcho stores memory summaries of all chat history. It is intentionally not exposed to the public internet. TLS termination at Cloudflare would also insert WAF between Honcho and LiteLLM, which turned out to break the OpenAI SDK's requests.

### Why the in-cluster LiteLLM URL

During testing, `https://llm.voitech.dev` returned `Your request was blocked` for the OpenAI SDK from inside the cluster, even though curl with the same key and body succeeded. The same request to `http://litellm.llm-hub.svc.cluster.local:4000` worked immediately. Cloudflare WAF appears to fingerprint the OpenAI Python SDK differently than curl. For service-to-service traffic inside k3s, the in-cluster DNS name is both faster and more reliable.

## Consequences

### Positive

- Honcho is now fully in GitOps: rebuildable from `gulasz101/homelab-2nd`.
- Postgres durability follows the established CNPG + OMV MinIO pattern.
- Credentials are SOPS-encrypted; the public repo contains no plaintext secrets.
- LLM routing stays centralized through LiteLLM.
- No router ports or public tunnels opened for Honcho.

### Negative

- Raw Kubernetes manifests require more maintenance than a Helm chart.
- Access is LAN-only; remote use requires VPN/Tailscale to `192.168.1.179:30800`.
- The fork must be kept in sync with upstream for security fixes.

## Alternatives considered

- **Keep OrbStack.** Rejected: it is hand-managed, not GitOps, and tied to the Hermes host.
- **Use a public Cloudflare Tunnel.** Rejected: increases attack surface for a memory system and triggered Cloudflare WAF issues with the OpenAI SDK.
- **Use a standalone Postgres Helm chart.** Rejected: Guardrail 3 mandates CNPG for all Postgres.
- **Use the `postgresql:16-standard-trixie` CNPG image.** Tried and rejected: it includes pgvector but not `barman-cli-cloud`, so S3 backups fail. The default `postgresql:16` image contains both.
- **Run uv inside the container at startup.** Tried and rejected: `uv run` attempts to rewrite `/app/uv.lock` and rebuild workspace members on a read-only root filesystem. We now invoke the baked venv binaries directly.

## When to revisit

- If an official Honcho Helm chart appears.
- If Honcho needs public access (would require a tunnel plus auth review).
- If we move LiteLLM off k3s (then the in-cluster service name would change).
- If CNPG introduces a `barman-cli-cloud` sidecar pattern that lets us use a smaller image.
