# ADR-055: SOU Event Schema v1 — Agent-Agnostic JSON

**Date:** 2026-10-12  

> **Renumbered 2026-10-14:** originally authored as ADR-034/035/036 in the Obsidian
> vault's `homelab/docs/adr/` (a stale snapshot whose numbers were later reused in
> this repo). Moved here and renumbered to avoid collisions; vault copy removed.

**Status:** Proposed  
**Deciders:** akadmin (Supreme Leader), Szarik  
**Project:** SOU (Star-Office-UI fork)

---

## Context

The upstream `Star-Office-UI` uses a **state-only model** with 6 states (`idle`, `writing`, `researching`, `executing`, `syncing`, `error`). Agents push state changes via `POST /set_state` with:

```json
{
  "state": "writing",
  "detail": "正在整理文档",
  "progress": 0,
  "updated_at": "2026-10-12T20:00:00"
}
```

This is **insufficient** for the SOU fork's goal of visualizing **agent activity chains** (e.g., Hermes opens 5 files → OpenChamber writes 2 → Andrzej commits). We need:
1. **Event granularity:** All tool calls, not just state changes
2. **Agent-agnostic schema:** Works for Hermes, OpenChamber, OpenCode, Pi, Claude, etc.
3. **Versioned payloads:** Schema can evolve without breaking old clients
4. **Extensible event types:** `tool_call`, `state_change`, `file_edit`, `command_run`, `itsaplan_issue_transition`, etc.

---

## Decision

We define **Event Schema v1** — a versioned JSON structure for agent events sent to `POST /events`.

### Core schema (required fields)

```json
{
  "version": 1,
  "agent": "hermes",
  "event_type": "tool_call",
  "timestamp": "2026-10-12T20:00:00.123Z",
  "payload": {
    ...
  }
}
```

**Fields:**
- `version` (integer, required): Schema version (always `1` for now)
- `agent` (string, required): Agent identifier (`hermes`, `openchamber`, `opencode`, `pi`, `claude`, etc.)
- `event_type` (string, required): Event type (see registry below)
- `timestamp` (ISO 8601 string, required): Event creation time (UTC, with milliseconds)
- `payload` (object, required): Event-specific data (structure depends on `event_type`)

### Event type registry (initial set)

| `event_type` | Description | Payload schema |
|--------------|-------------|----------------|
| `tool_call` | Agent invoked a tool (read_file, terminal, web_search, etc.) | `{"tool": "read_file", "args": {...}, "result": {...}}` |
| `state_change` | Agent changed state (backward compat with upstream) | `{"state": "writing", "detail": "...", "progress": 0}` |
| `file_edit` | Agent edited a file | `{"path": "app.py", "action": "patch", "lines_changed": 12}` |
| `command_run` | Agent ran a shell command | `{"command": "pytest", "exit_code": 0, "duration_ms": 1234}` |
| `itsaplan_issue_transition` | Agent moved an issue on the board | `{"issue_key": "SOU-12", "from_column": "Todo", "to_column": "In Progress"}` |
| `session_start` | Agent session started | `{"session_id": "uuid", "context": "..."}` |
| `session_end` | Agent session ended | `{"session_id": "uuid", "duration_ms": 123456}` |

**Extensibility:** New event types can be added without breaking existing clients (backend stores `payload` as JSONB, frontend ignores unknown types).

### Payload structure (event-specific)

#### `tool_call` payload

```json
{
  "tool": "read_file",
  "args": {
    "path": "~/Projects/star-office-ui-fork/backend/app.py",
    "offset": 1,
    "limit": 300
  },
  "result": {
    "status": "success",
    "output": "...",
    "error": null
  },
  "duration_ms": 123
}
```

#### `state_change` payload (backward compat)

```json
{
  "state": "writing",
  "detail": "正在整理文档",
  "progress": 0
}
```

**Note:** `state_change` events are mapped to the upstream 6-state model for backward compat during transition. Once all agents migrate to `tool_call` events, we can deprecate `state_change` and infer state from tool activity.

#### `file_edit` payload

```json
{
  "path": "backend/app.py",
  "action": "patch",
  "old_lines": 100,
  "new_lines": 112,
  "lines_changed": 12
}
```

#### `command_run` payload

```json
{
  "command": "pytest tests/",
  "exit_code": 0,
  "output": "...truncated...",
  "duration_ms": 1234,
  "workdir": "/Users/wojciechgula/Projects/star-office-ui-fork"
}
```

---

## Consequences

### Positive
- **Agent-agnostic** — any agent can push events via `POST /events` with its own `agent` identifier
- **Versioned** — schema can evolve (v2, v3) without breaking old clients (backend checks `version` field)
- **Rich activity history** — all tool calls logged, not just state changes → enables activity chain visualization
- **Extensible** — new event types (`git_commit`, `api_call`, `web_scrape`) can be added without schema migration
- **Backward compat** — `state_change` events map to upstream 6-state model during transition

### Negative
- **Payload validation complexity** — backend must validate event-specific payload schemas (use JSON Schema or Pydantic)
- **Storage growth** — logging all tool calls → more DB rows than state-only model. Mitigation: add retention policies (delete events older than 30 days).
- **Frontend complexity** — Phaser.js must handle multiple event types, not just 6 states. Mitigation: start with `state_change` → `tool_call` mapping, defer rich rendering.

### Risks
- **Schema drift** — if agents send malformed payloads, backend must reject them (validation required). Mitigation: strict JSON Schema validation on `POST /events`.
- **Event flood** — if Hermes sends 1000 events/min, DB write throughput may spike. Mitigation: batch writes, async queue (Redis Streams, NATS JetStream).

---

## Implementation Notes

### API endpoint (Flask)

```python
# backend/app.py
from flask import request, jsonify
import jsonschema

EVENT_SCHEMA_V1 = {
    "type": "object",
    "required": ["version", "agent", "event_type", "timestamp", "payload"],
    "properties": {
        "version": {"type": "integer", "const": 1},
        "agent": {"type": "string", "minLength": 1},
        "event_type": {"type": "string", "minLength": 1},
        "timestamp": {"type": "string", "format": "date-time"},
        "payload": {"type": "object"}
    }
}

@app.route("/events", methods=["POST"])
def ingest_event():
    data = request.get_json()
    try:
        jsonschema.validate(data, EVENT_SCHEMA_V1)
    except jsonschema.ValidationError as e:
        return jsonify({"ok": False, "error": str(e)}), 400
    
    # Write to DB (see ADR-054 for db.py adapter)
    db.insert_event(
        agent=data["agent"],
        event_type=data["event_type"],
        payload=data["payload"],
        timestamp=data["timestamp"]
    )
    return jsonify({"ok": True}), 201
```

### Hermes integration (post-tool hook)

Option 1: **Webhook skill** (manual)
```bash
# After every tool call
hermes webhook post https://sou.homelab.local/events \
  --data '{"version":1,"agent":"hermes","event_type":"tool_call","timestamp":"...","payload":{...}}'
```

Option 2: **Post-tool hook** (automatic, preferred)
```yaml
# ~/.hermes/profiles/szarik/config.yaml
hooks:
  post_tool:
    - url: "http://localhost:5000/events"
      method: "POST"
      body:
        version: 1
        agent: "hermes"
        event_type: "tool_call"
        timestamp: "{{timestamp}}"
        payload:
          tool: "{{tool_name}}"
          args: "{{tool_args}}"
          result: "{{tool_result}}"
```

**Note:** Hermes post-tool hook implementation is out of scope for this ADR (belongs in Hermes core, not SOU). For Phase 1, we use manual webhook calls.

---

## Alternatives Considered

### 1. Protobuf instead of JSON
**Rejected.** Early debugging is easier with JSON (human-readable, `curl`, browser devtools). Protobuf is premature optimization. Revisit if network bandwidth becomes a bottleneck.

### 2. Keep upstream 6-state model, infer activity from state transitions
**Rejected.** State transitions lose granularity (can't distinguish "read 5 files" from "wrote 2 files" — both are `writing` state). Tool-level events are required for activity chains.

### 3. Event sourcing (append-only log, no state snapshots)
**Deferred.** Full event sourcing (rebuild state from event log) is overkill for Phase 1. We store events **and** agent state (derived from latest event). If replay becomes critical, refactor later.

### 4. GraphQL subscription instead of polling
**Deferred.** Polling (`/events?agent=X&since=T`) is simpler for Phase 1. WebSocket or GraphQL subscription adds complexity. Revisit if real-time latency (<2s) becomes a requirement.

---

## References

- **ADR-054:** Database layer (Postgres primary, SQLite fallback) — defines `events` table schema
- **ADR-056:** OpenClaw decoupling — deprecates `/set_state` in favor of `/events`
- **Tracking note:** `2026-10-12-sou-agent-agnostic-redesign.md`
- **JSON Schema spec:** https://json-schema.org/

---

**Next steps:**
1. Write JSON Schema validation for `POST /events` endpoint
2. Add `db.insert_event()` method to `backend/db.py`
3. Write `push_event.py` script (generic replacement for `set_state.py`)
4. Test event ingest with manual `curl` calls (Hermes hook deferred)
5. Update Phaser.js frontend to poll `/events?agent=X&limit=1` instead of `/status`
