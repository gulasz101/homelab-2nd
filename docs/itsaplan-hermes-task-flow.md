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

Unlike Mac Hermes, this worker has **no Itsaplan MCP credentials or tools**, so it cannot call
`add_comment` itself; its replies are delivered only by the runner reporting the session's final
assistant text (2026-09-15).

## Operational note

`timeoutMs` is enforced by the runner **and** independently by `bridge.js`
(`OPENCHAMBER_TASK_TIMEOUT_MS`). Both are **14400000** (4 h) since 2026-09-15: run #4 exceeded
the old 1800000 (30 min) budget and was reported failed while the session was still working
(commit `ec9e9df`). A timed-out run leaves the session running; raise both together if longer
tasks are expected.

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
- Not readable from the worker: the Mac Hermes skill source itself and the H2-19 issue body,
  because the OpenChamber worker has no Itsaplan MCP key or issue-tracker tool (2026-09-15).
