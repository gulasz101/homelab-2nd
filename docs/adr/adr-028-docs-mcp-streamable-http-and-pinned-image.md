# ADR-028: docs-mcp-server on streamable HTTP `/mcp`, pinned image, Recreate strategy

- **Status:** Accepted
- **Date:** 2026-10-03
- **Supersedes:** nothing (amends the deployment pattern set by ADR-002-era docs-mcp local deployment)
- **Related:** ADR-024 (OpenChamber 2.1.0 upgrade), ADR-027 (Bun header limits), Itsaplan H2-95
- **Tracking note:** `homelab/tracking/2026-10-03-docs-mcp-opencode-mcp-transport-fix.md` (vault)

## Context

Guardrail 6 makes docs-mcp-server the first stop for documentation lookups, but
two independent failures kept it dead for everything except Hermes:

1. **OpenChamber's opencode 2.x could never connect to it.** The worker's
   seeded `opencode.json` pointed `docs-mcp` at
   `http://…:6280/sse` — the *legacy SSE transport* endpoint. OpenCode 2.x
   speaks *streamable HTTP* (MCP spec ≥ 2025-03-26, which deprecated the old
   HTTP+SSE transport): it POSTs `initialize` **directly to the configured
   URL**. docs-mcp serves `/sse` for the GET stream only — a POST to it returns
   404 — so every session logged `mcp connect failed server=docs-mcp … (HTTP
   404)`; the worker's `opencode.log` accumulated 18 such failures across both
   the 2.0.4 and 2.1.0 eras (filed as H2-95). Measured on the wire:
   `POST /sse` → 404, `POST /mcp` → 200, `GET /sse` → 200 + `event: endpoint`
   (the legacy transport works for GET-first clients, which is why Hermes-style
   stdio/SSE consumers kept functioning). The tidy answer: use the one endpoint
   designed for this — `/mcp`.

2. **The `:latest` image was lying, and the hostPort rollout was a trap.**
   The Deployment pinned `ghcr.io/arabold/docs-mcp-server:latest` with
   `imagePullPolicy: IfNotPresent`. The node kept resolving `:latest` to a
   **local stale digest** (v3.1.0) while the registry's `latest` had moved to
   v3.2.1 — so a `kubectl rollout restart` pulled nothing new and the tag told
   no truth about what ran. During debugging, a manual `rollout restart`
   created a second pod template (the restart annotation) while the old pod
   still held `hostPort: 6280`; RollingUpdate surge then became impossible
   ("didn't have free ports"), Flux saw the live template diverge from Git and
   reverted the annotation, and the DeploymentControllers tug-of-war left a
   permanently `Pending` pod. `kubectl delete pod` broke the deadlock, but the
   class of bug is structural: **hostPort pods cannot rolling-update against
   themselves.**

   (One more trap for the record: switching the Deployment to `strategy:
   Recreate` via Flux failed server-side apply with
   `spec.strategy.rollingUpdate: Forbidden: may not be specified when strategy
   type is 'Recreate'` — the old defaulted `rollingUpdate` block is *not
   managed* by the declared YAML, so SSA won't drop it. A one-time
   `kubectl patch … {"rollingUpdate":null}` was needed, then Flux converged.)

## Decision

1. **All opencode-family MCP clients connect to docs-mcp over streamable HTTP
   `/mcp`**, not `/sse`:
   - OpenChamber worker seed (`openchamber-config-configmap.yaml`):
     `…:6280/sse` → `…:6280/mcp`, `seed-version` 2 → 3, plus a new pod-template
     annotation `homelab.voitech.dev/opencode-seed-version: "3"` so a seed bump
     rolls the worker **declaratively** (Flux, not `kubectl rollout restart`).
   - opencode on external laptops must use `http://192.168.1.179:6280/mcp`
     (LAN) or `http://100.96.90.128:6280/mcp` (netbird) — both verified.
   - Open WebUI (`openwebui-helm-release.yaml`) already used `/mcp`; untouched.
   - Hermes (`config.yaml` `mcp_servers.docs`) already used `/mcp`; untouched.

2. **docs-mcp image is pinned to a real version tag** —
   `ghcr.io/arabold/docs-mcp-server:3.2.1` (current upstream release,
   2026-09-27). Upgrades are deliberate tag bumps through GitOps. Never
   re-pin to `:latest`.

3. **docs-mcp Deployment strategy is `Recreate`.** A single-replica hostPort
   workload must terminate its old pod before the new one can schedule;
   RollingUpdate can never converge for it. The short (~1 min) outage during
   upgrades is acceptable for a LAN-only docs service.

4. **`docs-mcp` MCP config in opencode must never be hand-patched in the pod
   again.** The seed flow (ConfigMap `seed-version` + template annotation) is
   the supported path.

## Consequences

**Positive:**
- OpenChamber sessions get working docs search (10 tools, `mcp connected`,
  verified in `opencode.log` 2026-10-03T09:47:23Z).
- The image tag finally describes the running container (v3.2.1 == v3.2.1).
- Template changes on hostPort workloads actually roll instead of wedging.
- Seed bumps propagate via Flux reconcile only — no break-glass restarts.

**Negative:**
- `Recreate` means an upgrade window with docs-mcp down (~60–90 s).
- Pinning means upgrades are manual tag bumps (that's the point, but it's
  chores now, not automation).
- The opencode-seed annotation duplicates the ConfigMap `seed-version` string
  by design — if they drift, you get a seed change without a rollout. Keep
  them equal when bumping.

**Alternatives considered:**
- *Keep `/sse` and patch docs-mcp* — the legacy SSE path works for GET-first
  clients but opencode 2.x's streamable-HTTP-first handshake doesn't match
  it; fighting the server to appease an old transport is backwards.
- *NodePort/ClusterIP + ingress instead of hostPort* — solves port collisions
  but re-architects a service whose netbird/LAN hostPort exposure is already
  documented (ADR-002 era) and works; Recreate is the cheaper, honest fix.
- *Image update automation (Flux image-reflector/policy)* — deferred; would
  reintroduce surprise upgrades, the exact class of drift H2-87/H2-93 just
  burned us with (in-pod CLI self-upgrade). Pin first, automate (if ever)
  later with deliberate PRs.

## When to revisit

- docs-mcp drops `/mcp` or changes transports again (check on version bumps).
- OpenCode upstream adds explicit SSE support again or changes MCP client
  behaviour (their docs: `opencode.ai/docs/mcp-servers/`).
- If docs-mcp ever needs >1 replica or a rolling upgrade without outage —
  then drop `hostPort` for a Service/Ingress path and revisit strategy.
- If Flux image automation is adopted homelab-wide (guardrail: it must land
  as PRs, not silent tag writes).
