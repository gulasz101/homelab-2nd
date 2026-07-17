# Authentik deployment gotchas

Lessons learned while running Authentik on the homelab-2nd cluster.

## Gotcha #1 — Skipping the web setup wizard leaves the setup flag `False`

When `akadmin` is created manually via `ak shell` instead of the web OOBE, Authentik’s internal `Setup` flag on the default tenant stays `False`. This makes `/setup` return **"Server is starting up..."** forever and redirects `/` to `/setup`.

**Fix:**

```bash
ssh homelab-2nd "sudo kubectl -n auth exec deployment/authentik-server -- ak shell -c 'from authentik.core.apps import Setup; from authentik.tenants.models import Tenant; t=Tenant.objects.get(schema_name=\"public\"); Setup.set(True, tenant=t)'"
```

## Gotcha #2 — The `initial-setup` flow is not needed after manual bootstrap

The `initial-setup` flow is only useful for the web wizard. If it is present and a user accidentally reaches it, it can create confusion. For a GitOps/manual bootstrap deployment, the setup flag fix above is sufficient; the flow itself can be left alone or removed.

## Gotcha #3 — Superusers do not automatically see all applications

Authentik evaluates application visibility from explicit **PolicyBindings** (group, user, or policy). Being `is_superuser=True` or in `authentik Admins` does **not** bypass app bindings. If `akadmin` should see an app, either:

- bind the app to a group he is in (e.g. `homelab-users`, `homelab-admins`), or
- add him to the group the app is already bound to.

## Gotcha #4 — Applications with no bindings are visible to everyone

An app without any binding is effectively public in the user dashboard. This is why `grafana` was showing up for `sylwia` before we added a `homelab-admins` binding.

## Gotcha #5 — Cloudflare caching can break the flow executor

The flow executor endpoint `/api/v3/flows/executor/<flow-slug>/` stores the stage plan in the Django session when it serves the initial `GET`. If Cloudflare caches that `GET`, the browser receives the challenge HTML but the session plan is never created. The subsequent `POST` then fails with **"No identification data provided."**

**Rule you need in Cloudflare:**

| Field | Operator | Value | Action |
|---|---|---|---|
| Host | equals | `auth.voitech.dev` | — |
| URL path | contains | `/api/v3/flows/executor/` | Bypass cache |

Make sure the path has the trailing wildcard/slash pattern so it actually matches the per-flow URLs. `/api/v3/flows/executor/` alone is not enough if Cloudflare’s matcher treats it as a literal prefix that still allows caching of sub-paths. Use `/api/v3/flows/executor/*` if your Cloudflare plan supports wildcards in Cache Rules.

Purge cache for `auth.voitech.dev` after changing the rule.

## Gotcha #6 — `ak shell` runtime changes are not GitOps

Everything done with `ak shell` (users, groups, app bindings, tenant flags) is runtime state in the CNPG database. Rebuilding the cluster from the repo will recreate Authentik via the HelmRelease, but it will not recreate these objects unless we commit them as Authentik Blueprints or Terraform. Keep the repo in sync.
