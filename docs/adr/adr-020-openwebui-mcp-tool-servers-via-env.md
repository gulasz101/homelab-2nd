# ADR-020: Open WebUI gets cluster-internal MCP tool servers via `TOOL_SERVER_CONNECTIONS` (additive to Firecrawl)

Date: 2026-09-26
Status: Accepted
Related: ADR-002 — docs-mcp-server runs locally in k3s · ADR-010 — self-host Firecrawl and wire it to Open WebUI web search

## Context

Open WebUI supports the Model Context Protocol natively (Streamable HTTP) since
v0.6.31; the homelab runs **0.11.4** (chart `open-webui` 16.6.0). The homelab's
`docs-mcp-server` (see ADR-002) already speaks MCP at
`http://docs-mcp-server.docs-mcp.svc.cluster.local:6280/mcp` — it is ClusterIP +
hostPort only, deliberately never exposed through Cloudflare.

The operator wanted a chat in Open WebUI to be able to query the indexed docs.
On 2026-08-28 he explicitly **rejected replacing Firecrawl web search** with the
docs MCP server and asked for an **additive** integration, leaving web-search
prioritisation for him to tune later. The remaining question was how to add a tool
server without clicking through Admin → Settings → Integrations on a single-node
homelab that must be rebuildable from Git.

Constraints:
- The repo is public; no plaintext credentials may enter it.
- Every runtime change must be reconcilable by Flux from the repo (guardrail #1).
- An unauthenticated in-cluster MCP server needs no token, so there is nothing to
  put in SOPS.

## Decision

Cluster-internal MCP tool servers for Open WebUI are declared in the Open WebUI
**HelmRelease** as a JSON array in the `TOOL_SERVER_CONNECTIONS` environment
variable (`apps/llm-hub/openwebui-helm-release.yaml`, `spec.values.extraEnvVars`).
There is no UI step and no new Kubernetes object.

For the docs-mcp connection:
- `type: "mcp"`, `url: http://docs-mcp-server.docs-mcp.svc.cluster.local:6280/mcp`
  (Open WebUI is Streamable-HTTP-only for MCP — `/mcp`, not `/sse`).
- `auth_type: "none"` with an empty `key` — the service is unauthenticated inside
  the cluster.
- `config.function_name_filter_list` allow-lists exactly the four read-only query
  tools: `search_docs,list_libraries,fetch_url,find_version`. The server also
  advertises destructive tools (`remove_docs`, `cancel_job`) and heavy ones
  (`scrape_docs`), which a chat model must not be able to call.
- `config.access_grants: []` leaves the connection **admin-only**, which is Open
  WebUI's own default for a connection with no grants.

Firecrawl web search (`ENABLE_WEB_SEARCH`, `WEB_SEARCH_ENGINE=firecrawl`,
`FIRECRAWL_*`) is untouched. Adding another in-cluster MCP server later is one more
element in the same JSON array (and, if that server needs a token, a bearer auth
type plus a SOPS secret).

## Consequences

Positive:
- Fully GitOps: the connection is provisioned by Flux from the public repo, no UI
  clicking, survives a node rebuild.
- No new secret for an unauthenticated in-cluster server.
- Blast radius is deliberately small: the model can read indexed docs but cannot
  delete docs or trigger scrapes.
- Strictly additive: reverting one commit restores the previous behaviour.

Negative / limits:
- All tool server connections live in one environment value; adding or editing one
  produces a single new pod revision and one rollout.
- `function_name_filter_list` is now maintained by hand and must be updated when
  the upstream server's tool set changes (it went from 4 to 11 tools between
  planning and execution).
- `access_grants: []` means non-admin users do **not** see the docs tools; widening
  it is a deliberate follow-up, not an accident.
- The chart renders list-style `extraEnvVars` through Helm's `tpl`, so the JSON
  value must not contain a literal `{{` sequence.
- The connection is only reachable from inside the cluster, which is desirable, but
  means Open WebUI clients outside the cluster cannot use it.

## Alternatives considered

- **Add the connection in the Admin UI** (the documented quick start): rejected —
  not reproducible from Git, lost on rebuild, violates guardrail #1.
- **Put the JSON in a ConfigMap and `extraEnvFrom` it**: rejected as more moving
  parts than a single block scalar in the HelmRelease. Revisit if the array grows
  to many servers or needs templating.
- **Bridge through MCPO/OpenAPI**: rejected — Open WebUI supports MCP natively, so a
  proxy would add a component and a failure mode for no benefit.
- **Replace Firecrawl with the docs MCP server**: rejected by the operator on
  2026-08-28; web search and internal docs search serve different needs.
- **`auth_type: bearer` with a dummy/empty key**: rejected — Open WebUI would send
  `Authorization: Bearer` with an empty value, which many servers reject; `none` is
  the documented mode for local/internal servers.

## When to revisit

- If `docs-mcp-server` begins requiring authentication → switch to `bearer` plus a
  SOPS-encrypted token secret.
- If non-admin users need the docs tools → populate `access_grants` (groups/users).
- If the server's tool set keeps changing or per-tool grants are needed → move the
  filter/grants to a dedicated ConfigMap and re-evaluate the allow-list.
- If Open WebUI adds first-class chart values for tool servers → use them instead
  of raw `extraEnvVars`.
- If the number of in-cluster MCP servers grows beyond a couple → a ConfigMap (or a
  generated value) becomes cleaner than one long block scalar.
