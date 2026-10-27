# ADR-092: Pin cloudflared image tags and ship tunnel upgrades as explicit tag bumps

- **Status:** Accepted
- **Date:** 2026-10-26
- **Deciders:** Wojtek (owner), Andrzej (CTO, homelab-2nd)
- **Tracked by:** GUL-264
- **Supersedes:** nothing

## Context

On 2026-10-19 Cloudflare disclosed that eight eMudhra (emSign) intermediate CA private keys are
weak, so anyone holding them can mint certificates that impersonate any site. `cloudflared` below
**2026.10.2** still trusts those CAs. Cloudflare emailed every account running a Tunnel and asked
for an immediate upgrade. We run **19 cloudflared Deployments over 17 namespaces** — one Tunnel per
service (ADR-032) — and every one of them pinned `cloudflare/cloudflared:latest`.

`latest` looked harmless, because "Flux always gets the newest". It does not. Kubernetes re-pulls an
image only when the **Pod template changes** or the Pod restarts, and Flux cannot even see that
`latest` moved. On the day of the advisory the fleet proved it:

| tunnel | connected version |
|---|---|
| whiteboard, auth, chat, gist, keep, plan, grafana, status | 2026.10.3 |
| nextcloud (one of two replicas) | 2026.10.3 |
| **firecrawl, fitness, hindsight, litellm, mail-archive, openchamber, nextcloud (other replica)** | **2026.10.0** |
| **star-office (lodge)** | **2026.10.1** |

Eight tunnels were below the floor and would have stayed there until something unrelated restarted
them. The manifest said "latest", the cluster said "October 5th". That gap is the bug this ADR
closes — the certificate compromise was only the thing that exposed it.

## Decision

1. **Pin an explicit version tag** — `cloudflare/cloudflared:2026.10.3` — in every cloudflared
   Deployment. `latest` is banned for this component. The version a tunnel runs is now readable in
   Git and in the Pod spec, and the two can be diffed.
2. **An upgrade is a tag bump through a PR**, merged by the owner and applied by Flux. The tag change
   alters the Pod template, so the rollout pulls the new image — the pull that `latest` never
   guaranteed. Restarting a Pod on an unchanged tag applies nothing. From now on **Renovate opens
   that PR** (GUL-315): one grouped PR covering all cloudflared manifests, never automerged.
3. **Pin the newest published release, not a floor version.** A floor (`2026.10.2` here) is what makes
   a version *unacceptable*; it is never the target. The owner's standing rule, stated 2026-10-27:
   never `:latest`, always an explicit version, and that version is the newest release. The first
   pass of this work pinned `2026.10.3` on the argument that `2026.10.4` was four hours old with no
   changelog; a day later the obvious target is `2026.10.4` and the fleet moved there. Do not carry a
   "floor" version once the newest is no longer fresh out of the oven.
4. **Rolling, never simultaneous.** Two-replica tunnels (whiteboard, auth, karakeep, gist, keep,
   status, nextcloud) roll clean. Single-replica tunnels blink for a few seconds on merge; accepted
   for a security fix. Giving chat, auth and paperclip a second connector is tracked separately.
5. **Re-check HTTPS origins before every cloudflared upgrade.** An HTTPS origin whose certificate
   chains to a revoked CA breaks on the new build, and silencing that with `noTLSVerify` is
   forbidden — it removes the protection the upgrade exists to restore. Today every ingress points
   at `http://<svc>.<ns>.svc.cluster.local`, so there was nothing to replace.

## Consequences

- **Good:** drift is visible without touching a Pod. One `grep` over the repo and one Cloudflare
  connector listing now answer "what version are we running, and where".
- **Good:** the upgrade path is reviewable. A one-line diff per namespace tells a reviewer exactly
  which tunnel moves, and 17 small PRs can be fanned out to agents in parallel instead of one
  person editing 19 files.
- **Cost:** a security patch no longer arrives by itself. A published advisory is now an explicit
  work item, with a human merge per namespace.
- **Cost:** the tag lives in 19 files. Bumping the fleet is mechanical work that wants a bot; until
  then it is agent work.

## Alternatives considered

- **Keep `latest` and add a weekly restart CronJob.** A restart does pull the newest image, but the
  cluster still reports `latest` everywhere: nobody can state a running version without `exec`ing
  into every Pod, and a 19-tunnel restart storm is not something to schedule weekly. Rejected.
- **`imagePullPolicy: Always` with `latest`.** Pulls only happen on Pod start anyway, so this
  changes nothing about drift and keeps the version unknowable from Git. Rejected.
- **Pin a digest (`@sha256:…`).** The strongest guarantee, but unreadable in review and impossible to
  reason about at a glance; with no dependency bot in place it buys nothing over a tag. Rejected for
  now; revisit if supply-chain requirements grow.
- **Renovate opening the bump PRs automatically.** Adopted as the follow-up (GUL-315) rather than left
  as an alternative: the manual fan-out proved the diff shape and the blast radius, so a bot can
  repeat it. It groups one PR for all cloudflared manifests, because 17 separate merges for a single
  version is the part that did not scale.

## When to revisit

- Renovate stops delivering (expired token, disabled workflow, withdrawn repo permission) → the
  manual per-namespace fan-out described above is the fallback.
- Every tunnel runs two or more connectors → simultaneous rolling is already safe, and the
  per-namespace split is then only about review scope.
- Cloudflare ships a release we must adopt beyond the floor faster than a calm cadence allows, or
  changes the trust-store behaviour that makes 2026.10.2 the floor.
