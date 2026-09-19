# Itsaplan → Hermes (Andrzej) task flow

How a delegated issue in Itsaplan project **H2** reaches the Mac Hermes profile
`andrzej`, and how the result gets back into Itsaplan. Companion to
[ADR-017](./adr/adr-017-itsaplan-h2-reconstruction.md) (H2 reconstruction) and
[ADR-018](./adr/adr-018-openchamber-worker-on-t460.md) (OpenChamber worker).

**Status:** verified against the repo and the live API on 2026-09-15.

## Topology

- Itsaplan API is `https://plan-api.voitech.dev`; the web UI is `https://plan.voitech.dev`.
- `itsaplan-andrzej-runner` (ns `itsaplan`, node `arr-box`) polls the API and turns each
  claimed run into an outbound webhook.
- Mac Hermes profile `andrzej` receives that webhook and reports back through the Itsaplan
  MCP/HTTP API with its personal `itp_…` key.
- A second, parallel runner `openchamber-itsaplan-runner` (ns `openchamber`, node `t460`)
  uses the same `@itsaplan/runner` with a different command (`bridge.js`), which launches an
  OpenChamber session instead of a webhook.

## Delivery (Itsaplan → Andrzej)

1. An H2 issue is delegated to the external agent **Andrzej**.
2. Runner config `itsaplan-runner.json` (ConfigMap `itsaplan-andrzej-runner`):
   `url https://plan-api.voitech.dev`, `command node /etc/itsaplan-runner/post-to-andrzej.js`,
   `cwd /tmp`, `concurrency 1`, `pollIntervalMs 5000`, `timeoutMs 14400000`, `outputFormat text`
   (4 h since 2026-09-15; was 30 min).
3. Auth: `ITSAPLAN_API_KEY` + `ITSAPLAN_URL` from SOPS secret `itsaplan-andrzej-agent-key`.
   The runner claims work via `POST /agent-runs/claim` and `POST /agent-chats/claim`.
4. On claim it pipes the task body to the command on **stdin** and exports
   `ITSAPLAN_TRIGGER`, `ITSAPLAN_RUN_ID`, `ITSAPLAN_ISSUE`, `ITSAPLAN_ISSUE_ID`.
5. `post-to-andrzej.js` POSTs this exact JSON:
   `{"event":"task","trigger":…,"run_id":…,"issue":…,"issue_id":…,"task":…}`,
   signed with HMAC-SHA256 (hex) over `` `${timestamp}.${body}` ``, headers
   `X-Webhook-Timestamp` (unix seconds) and `X-Webhook-Signature-V2`, `Content-Type: application/json`.
6. `WEBHOOK_URL` / `WEBHOOK_SECRET` come from SOPS `itsaplan-andrzej-webhook-creds`; the
   webhook target is the Mac at `192.168.1.148:8644` (ADR-017).
7. Mac Hermes routes it to `itsaplan-andrzej` and answers
   `{"status":"accepted","route":"itsaplan-andrzej"}` (ADR-017, verified on H2-13).

## Results (Andrzej → Itsaplan)

- Mac Hermes holds an `itp_…` personal MCP key (`MCP_ITSAPLAN_API_KEY`) and calls the
  Itsaplan MCP endpoint `/mcp` with `Authorization: Bearer`.
- The REST primitives behind the MCP tools (the OpenAPI `x-mcp` field names each tool):
  - **add_comment:** `POST /issues/{issueId}/comments` body
    `{ "body": string, "replyToId"?: number }`. `replyToId` answers an existing comment of
    that issue instead of starting a new thread.
  - **update_issue (move column):** `PATCH /issues/{issueId}` body `{ "columnId": <number> }`
    (H2 columns: Backlog 6 · Todo 7 · In Progress 8 · Done 9 · Canceled 10 — ADR-017)
- Direct API callers send the key as the `x-api-key` header; the MCP transport accepts the
  same key as `Authorization: Bearer`. `securitySchemes` also define a `workerToken`
  (`x-worker-token`) used only by the worker/bot services.
- The runner reports the run outcome separately to
  `POST /agent-runs/{runId}/result` `{ "status": "success"|"failed", "output"?: string }`.
- End-to-end verified on **H2-13**: `agent_run.id=1 status=success`, webhook accepted (ADR-017).

## Mentions (agent chats)

An `@Andrzej`/`@OpenChamber` mention creates an **agent chat**, a separate queue from runs:

1. The runner claims it with `POST /agent-chats/claim`; the message carries the `prompt` and
   the bound `sessionId` (null means start a fresh session and report the id it got).
2. The command's output is streamed back as `POST /agent-chats/{messageId}/events`
   (`RUN_STARTED` / `TEXT_MESSAGE_*` / `RUN_FINISHED`), then finished with
   `POST /agent-chats/{messageId}/result` `{ "status": "success"|"failed" }`.
3. Itsaplan renders the returned assistant text as the agent's answer on the issue.

## OpenChamber twin

Same runner, different command: `apps/openchamber/openchamber-itsaplan-bridge-configmap.yaml`
(`bridge.js`) logs into OpenChamber, creates a session titled `[itsaplan] …`, sends the task
prompt, waits until the session is idle, and writes the final assistant text to stdout. The
runner then reports that stdout through `POST /agent-runs/{runId}/result` (delegations) or the
`/agent-chats/{messageId}/events` + `/result` pair (mentions), so the final assistant text is
the answer that lands on the issue.

Unlike Mac Hermes, this worker historically had no Itsaplan credentials. Since
ADR-022 (vault `homelab/docs/adr/`) the `itsaplan-worker`
session runs with the OpenChamber agent's own key through a remote **`itsaplan`
MCP server** (`https://plan-api.voitech.dev/mcp`, `Authorization: Bearer`), and
loads the **`itsaplan-tasks` skill** (ConfigMap `openchamber-itsaplan-skill`,
`/storage/opencode-config/skill/itsaplan-tasks/SKILL.md`). The skill makes the
worker: extract acceptance criteria, plan, create real H2 subtasks with
`parentId`, link dependencies via `link_issues`, drive them Todo -> In Progress ->
Done, keep the board truthful on failure, and close with per-criterion evidence.
The bridge prefixes the session prompt with
`[itsaplan issue_id=<n> identifier=<H2-n> run_id=<n> trigger=<t>]` so the skill
knows which issue it runs.

The bridge still posts the run outcome back to the issue itself:
- on success: `@admin Deliverable — OpenChamber session <id>` + the final assistant text
  (truncated at 12 000 chars), via `POST /issues/{ITSAPLAN_ISSUE_ID}/comments`
  with the `x-api-key` header (the runner pod's own `ITSAPLAN_API_KEY`);
- on failure/timeout: the error head (first 4 lines / 800 chars) as a comment;
- agent handles (`@openchamber`, `@andrzej`) are neutralised with a zero-width space —
  mention triggers fire on bot-authored comments too (verified on H2-19), so a literal
  handle in a comment would re-spawn the runner in an infinite loop;
- the stdout → `POST /agent-runs/{runId}/result` channel is unchanged; comments are additive.
Verified live on 2026-09-15 (issues H2-20/21/22): comments landed authored by **OpenChamber**,
not Administrator.

## Operational note

`timeoutMs` is enforced by the runner **and** independently by `bridge.js`
(`OPENCHAMBER_TASK_TIMEOUT_MS`). Since commit `8a1cb93` (ADR-019) the bridge budget is
**14100000** — the runner's 14400000 lease **minus a 5-minute margin** — so the bridge times
out first and its failure comment lands **before** the runner reaps the process.
(`ITSAPLAN_TIMEOUT_MS` is **not** exported to the command child env by `@itsaplan/runner`
v0.5.0, so the margin must be set in the deployment env, not derived in-script.)
A timed-out run leaves the session running; raise both together if longer tasks are expected.

## Provenance

- Payload + runner config: `apps/itsaplan/itsaplan-andrzej-runner-configmap.yaml`.
- Env/secret wiring: `apps/itsaplan/itsaplan-andrzej-runner-deployment.yaml`;
  `itsaplan-andrzej-agent-key.sops.yaml`, `itsaplan-andrzej-webhook-creds.sops.yaml`.
- Result API: live OpenAPI `https://plan-api.voitech.dev/docs/json`
  (`/issues/{issueId}/comments`, `/issues/{issueId}`, `/agent-runs/{runId}/result`,
  `/agent-chats/{messageId}/events`, `/agent-chats/{messageId}/result`).
- Timeout raise: commit `ec9e9df` (`apps/itsaplan/itsaplan-andrzej-runner-configmap.yaml`,
  `apps/openchamber/openchamber-itsaplan-runner-configmap.yaml`,
  `apps/openchamber/openchamber-itsaplan-runner-deployment.yaml`).
- OpenChamber twin: `apps/openchamber/openchamber-itsaplan-bridge-configmap.yaml`,
  `apps/openchamber/openchamber-itsaplan-runner-configmap.yaml`.
- Board autonomy: ADR-022 (vault `homelab/docs/adr/`),
  skill `apps/openchamber/openchamber-itsaplan-skill-configmap.yaml`, MCP +
  `skills.paths` in `apps/openchamber/openchamber-config-configmap.yaml`,
  key injection in `apps/openchamber/openchamber-deployment.yaml`.
- Not readable from the worker: the Mac Hermes skill source itself. (Before
  ADR-022 the OpenChamber worker also had no Itsaplan key/tools; it now has the
  agent's own key scoped by its H2 role.)
