# ADR-056: SOU OpenClaw Decoupling — Ruthless Divergence

**Date:** 2026-10-12  

> **Renumbered 2026-10-14:** originally authored as ADR-034/035/036 in the Obsidian
> vault's `homelab/docs/adr/` (a stale snapshot whose numbers were later reused in
> this repo). Moved here and renumbered to avoid collisions; vault copy removed.

**Status:** Proposed  
**Deciders:** akadmin (Supreme Leader), Szarik  
**Project:** SOU (Star-Office-UI fork)

---

## Context

The upstream `ringhyacinth/Star-Office-UI` is **deeply integrated with OpenClaw**:
- Reads agent name from `~/.openclaw/workspace/IDENTITY.md`
- Uses `OPENCLAW_WORKSPACE` env var
- Ships `SKILL.md` for OpenClaw agent deployment
- Recommends `set_state.py` script invocation from OpenClaw agent rules

The SOU fork aims to be **agent-agnostic** (Hermes, OpenChamber, OpenCode, Pi, Claude, etc.). OpenClaw is **one possible agent**, not the default.

**Question:** Do we preserve backward compatibility with OpenClaw (keep `/set_state`, `IDENTITY.md` reading, etc.), or ruthlessly decouple and break upstream compatibility?

**Supreme Leader's decision (2026-10-12):**
> "the goal is to make it agent/harness agnostic"

**Interpretation:** Ruthless divergence. OpenClaw compatibility is **not** a requirement. We delete OpenClaw-specific code and docs.

---

## Decision

We **ruthlessly decouple from OpenClaw**. This is a **one-way fork** — we will **not** contribute patches upstream, and we **do not** preserve drop-in compatibility.

### What gets deleted (Phase 3)

1. **`IDENTITY.md` reading** — `backend/app.py` lines 49-50, 204-217 (reads agent name from OpenClaw workspace). **Delete.** Agent name comes from event payload (`agent` field in JSON, see ADR-055).

2. **`OPENCLAW_WORKSPACE` env var** — `backend/app.py` line 49. **Delete.** No hardcoded workspace paths.

3. **`set_state.py` script** — root-level script for OpenClaw agents to push state. **Delete.** Replace with generic `push_event.py` (see ADR-055).

4. **`SKILL.md`** — OpenClaw skill file with deployment instructions. **Delete.** Replace with generic `docs/agent-integration.md` covering Hermes, OpenChamber, OpenCode.

5. **`office-agent-push.py`** — visitor agent push script (OpenClaw-specific). **Refactor** to be agent-agnostic (remove OpenClaw references, make `AGENT_NAME` and `JOIN_KEY` the only required config).

6. **Upstream README references** — OpenClaw installation steps, Skill usage, `set_state.py` examples. **Delete.** Replace with agent-agnostic quick start.

### What gets refactored (not deleted)

1. **Multi-agent join flow** — `/join-agent` and `/agent-push` endpoints are **agent-agnostic** (already generic). **Keep**, but rename variables from `agent` → `visitor` for clarity.

2. **6-state model** (`idle`, `writing`, `researching`, `executing`, `syncing`, `error`) — this is **upstream UI design**, not OpenClaw-specific. **Keep** for Phase 1, map `tool_call` events to states (see ADR-055). Eventually infer state from event activity instead of explicit state changes.

3. **Phaser.js renderer** — area-based positioning (`breakroom`, `writing`, `error`) is **agent-agnostic**. **Keep** as-is, refactor in Phase 4 to consume `/events` API instead of `/status`.

---

## Consequences

### Positive
- **Clean slate** — no OpenClaw baggage, easier to onboard new agents (Hermes, OpenChamber, OpenCode)
- **Simplified codebase** — delete ~500 lines of OpenClaw-specific logic (IDENTITY.md reading, SKILL.md, etc.)
- **Agent-agnostic docs** — new users see "integrate any agent" quick start, not "install OpenClaw first"

### Negative
- **Upstream incompatibility** — existing OpenClaw users cannot use SOU as a drop-in replacement for upstream
- **No upstream patches** — we cannot contribute SOU improvements back to `ringhyacinth/Star-Office-UI` (different architecture)
- **Maintenance burden** — we maintain a fork indefinitely (no upstream merge path)

### Risks
- **Wasted upstream work** — if upstream evolves rapidly (new features, bug fixes), we miss out. Mitigation: upstream is **already mature** (v2 rewrite completed 2026-03-01, changelog shows stabilization). We're not forking a moving target.
- **Documentation divergence** — if we keep "Star Office UI" branding, users may confuse SOU with upstream. Mitigation: rename to **"SOU Dashboard"** or **"Agent Activity Dashboard"**, drop "Star Office" branding.

---

## Implementation Plan (Phase 3)

### Step 1: Delete OpenClaw-specific files
```bash
cd ~/Projects/star-office-ui-fork/
rm SKILL.md
rm set_state.py
rm -rf docs/CHANGELOG*.md docs/UPDATE_REPORT*.md  # upstream changelogs
```

### Step 2: Refactor `backend/app.py`
- Delete `IDENTITY.md` reading (lines 49-50, 204-217)
- Delete `OPENCLAW_WORKSPACE` env var reference (line 49)
- Delete `get_office_name_from_identity()` function (lines 204-217)
- Agent name now comes from DB (`agents.name` column), set via first `POST /events` call

### Step 3: Replace `set_state.py` with `push_event.py`
```python
#!/usr/bin/env python3
"""push_event.py - Generic event pusher for SOU dashboard"""
import requests
import sys
from datetime import datetime

AGENT = "hermes"  # or "openchamber", "opencode", etc.
SOU_URL = "http://localhost:5000/events"

def push_event(event_type, payload):
    data = {
        "version": 1,
        "agent": AGENT,
        "event_type": event_type,
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "payload": payload
    }
    resp = requests.post(SOU_URL, json=data)
    resp.raise_for_status()
    print(f"Event pushed: {event_type}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: push_event.py <event_type> [detail]")
        sys.exit(1)
    
    event_type = sys.argv[1]
    detail = sys.argv[2] if len(sys.argv) > 2 else ""
    
    # Backward compat: if event_type is a state name, map to state_change event
    if event_type in ["idle", "writing", "researching", "executing", "syncing", "error"]:
        push_event("state_change", {"state": event_type, "detail": detail, "progress": 0})
    else:
        push_event(event_type, {"detail": detail})
```

### Step 4: Update README.md
- Remove OpenClaw installation steps
- Add agent-agnostic quick start:
  ```bash
  # Start SOU dashboard
  docker run -p 5000:5000 ghcr.io/gulasz101/star-office-ui-fork

  # Push an event (any agent)
  python3 push_event.py state_change writing "Editing app.py"
  ```

### Step 5: Rename project (optional, deferred)
- Consider renaming from "Star Office UI" → "SOU Dashboard" or "Agent Activity Dashboard"
- Update branding in README, frontend HTML, Docker image tags
- **Deferred to Phase 4** (focus on mechanics first)

---

## Alternatives Considered

### 1. Keep OpenClaw compat layer (dual mode)
**Rejected.** Maintaining two integration paths (OpenClaw via `set_state.py` + generic via `POST /events`) doubles complexity. Ruthless divergence is cleaner.

### 2. Upstream pull request (contribute agent-agnostic refactor)
**Rejected.** Upstream is stable and OpenClaw-focused. Our redesign (DB layer, event schema, ruthless decoupling) is a **different product**. A PR would be rejected or require massive compromise.

### 3. Keep "Star Office UI" branding, add "powered by" attribution
**Deferred.** We keep the upstream LICENSE (MIT) and attribution in README. Rebranding (if needed) happens in Phase 4.

---

## References

- **ADR-054:** Database layer (Postgres primary, SQLite fallback)
- **ADR-055:** Event schema v1 (agent-agnostic JSON)
- **Tracking note:** `2026-10-12-sou-agent-agnostic-redesign.md`
- **Upstream repo:** `https://github.com/ringhyacinth/Star-Office-UI`
- **Fork repo:** `https://github.com/gulasz101/star-office-ui-fork`

---

**Next steps:**
1. Execute Phase 3 cleanup (delete OpenClaw files, refactor `app.py`)
2. Write `push_event.py` script
3. Update README with agent-agnostic quick start
4. Commit changes with message: "Phase 3: Ruthless OpenClaw decoupling (ADR-056)"
5. Verify local `docker run` still works (SQLite backend, `push_event.py` test)
