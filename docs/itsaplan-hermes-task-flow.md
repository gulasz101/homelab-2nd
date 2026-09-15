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
   `cwd /tmp`, `concurrency 1`, `pollIntervalMs 5000`, `timeoutMs 1800000`, `outputFormat text`.
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
- The API primitives behind the agent tools:
  - **comment:** `POST /issues/{issueId}/comments` body `{ "body": string, "replyToId"?: number }`
  - **move column:** `PATCH /issues/{issueId}` body `{ "columnId": <number> }`
    (H2 columns: Backlog 6 · Todo 7 · In Progress 8 · Done 9 · Canceled 10 — ADR-017)
- The runner reports the run outcome separately to
  `POST /agent-runs/{runId}/result` `{ "status": "success"|"failed", "output"?: string }`
  (chats use `/agent-chats/{messageId}/…`).
- End-to-end verified on **H2-13**: `agent_run.id=1 status=success`, webhook accepted (ADR-017).

## OpenChamber twin

Same runner, different command: `apps/openchamber/openchamber-itsaplan-bridge-configmap.yaml`
(`bridge.js`) logs into OpenChamber, creates a session titled `[itsaplan] …`, sends the task
prompt, waits until the session is idle, and writes the final assistant text to stdout, which
the runner returns as the run output.

## Operational note

`timeoutMs: 1800000` (30 min) is enforced by the runner **and** independently by `bridge.js`
(`OPENCHAMBER_TASK_TIMEOUT_MS`, default 1800000). A long research run can exceed it and be
reported as failed even though the OpenChamber session keeps working — raise both together if
longer tasks are expected.

## Provenance

- Payload + runner config: `apps/itsaplan/itsaplan-andrzej-runner-configmap.yaml`.
- Env/secret wiring: `apps/itsaplan/itsaplan-andrzej-runner-deployment.yaml`;
  `itsaplan-andrzej-agent-key.sops.yaml`, `itsaplan-andrzej-webhook-creds.sops.yaml`.
- Result API: live OpenAPI `https://plan-api.voitech.dev/docs/json`
  (`/issues/{issueId}/comments`, `/issues/{issueId}`, `/agent-runs/{runId}/result`).
- OpenChamber twin: `apps/openchamber/openchamber-itsaplan-bridge-configmap.yaml`,
  `apps/openchamber/openchamber-itsaplan-runner-configmap.yaml`.
- Not readable from the cluster: the Mac Hermes skill source itself, and the H2-19 issue body
  (the worker session has no issue-tracker credentials/tools provisioned).
