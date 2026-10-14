# ADR-054: SOU Database Layer — Postgres Primary, SQLite Fallback

**Date:** 2026-10-12  

> **Renumbered 2026-10-14:** originally authored as ADR-034/035/036 in the Obsidian
> vault's `homelab/docs/adr/` (a stale snapshot whose numbers were later reused in
> this repo). Moved here and renumbered to avoid collisions; vault copy removed.

**Status:** Proposed  
**Deciders:** akadmin (Supreme Leader), Szarik  
**Project:** SOU (Star-Office-UI fork)

---

## Context

The upstream `Star-Office-UI` stores all agent state in JSON files (`state.json`, `agents-state.json`). This does not scale and lacks:
- ACID guarantees
- Time-series query capability (event replay, retention policies)
- Concurrent write safety
- Relational integrity

The SOU fork aims to become an **agent-agnostic activity dashboard** for Hermes, OpenChamber, OpenCode, and future agents. We need a database layer that:
1. **Works in homelab-2nd k3s** (production) — CloudNativePG Postgres clusters
2. **Works on M1 Max localhost** (development) — SQLite for `docker run` testing
3. **Supports time-series event logging** — agent activity chains, tool call history
4. **Supports concurrent multi-agent writes** — N agents pushing events in parallel

---

## Decision

We adopt a **dual-backend database layer**:

### Postgres (primary)
- **Production backend** for homelab k3s deployment
- Deployed via **CloudNativePG** cluster (existing homelab pattern, proven backup/restore on the deployed CloudNativePG clusters)
- Schema: `agents`, `events`, `sessions` tables (see ADR-055 for event schema)
- Connection: psycopg2 or psycopg3 (async if needed later)

### SQLite (fallback)
- **Development backend** for local `docker run` testing on M1 Max
- Single-file database (`sou.db` in project root, gitignored)
- Same schema as Postgres (SQLAlchemy ORM or raw SQL with compatibility shims)
- **Not for production** — no concurrent write safety, no replication

### Adapter layer
We write a **database adapter** (`backend/db.py`) that:
- Detects backend via env var `DATABASE_URL` (Postgres connection string) or falls back to SQLite
- Provides a unified API for CRUD operations on `agents`, `events`, `sessions`
- Uses SQLAlchemy ORM (recommended) or raw SQL with dialect-specific queries isolated

**No JSON file fallback in production.** The upstream JSON file approach is deprecated. During the transition (Phases 1-2), we may write both DB + JSON for backward compat, but JSON files are removed before Phase 4.

---

## Consequences

### Positive
- **Proven homelab pattern** — CloudNativePG clusters already deployed for Mattermost, Nextcloud, OpenChamber, Karakeep (the existing CloudNativePG deployments: Mattermost, Nextcloud, OpenChamber, Karakeep)
- **Time-series ready** — can add event retention policies, partitioning, replay later without redesign
- **Concurrent writes** — N agents can push events in parallel without file locking
- **Local testing** — developers can `docker run` with SQLite, no Postgres dependency
- **Future k8s agent pods** — when agents move from M1 Max to k3s (distant future), they can all write to the same CNPG cluster

### Negative
- **Schema duplication** — SQLAlchemy models or raw SQL must support both Postgres and SQLite dialects
- **Migration complexity** — Alembic migrations must be tested against both backends
- **No JSON file compatibility** — existing upstream users (if any) must migrate

### Risks
- **SQLite concurrency limits** — if multiple agents hammer SQLite in local dev, writes may serialize or fail. Mitigation: local dev = single agent (Hermes), production = Postgres.
- **Schema drift** — if migrations are only tested on Postgres, SQLite may break. Mitigation: CI runs migrations on both backends.

---

## Implementation Notes

### Schema (sketch, refined in ADR-055)

```sql
CREATE TABLE agents (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    agent_type VARCHAR(50) NOT NULL,  -- 'hermes', 'openchamber', 'opencode', etc.
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE events (
    id SERIAL PRIMARY KEY,
    agent_id INTEGER NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    event_type VARCHAR(100) NOT NULL,  -- 'tool_call', 'state_change', 'file_edit', etc.
    payload JSONB NOT NULL,            -- agent-specific event data
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    INDEX idx_events_agent_created (agent_id, created_at DESC)
);

CREATE TABLE sessions (
    id SERIAL PRIMARY KEY,
    agent_id INTEGER NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    started_at TIMESTAMP NOT NULL,
    ended_at TIMESTAMP,
    INDEX idx_sessions_agent_started (agent_id, started_at DESC)
);
```

**SQLite adaptations:**
- `SERIAL` → `INTEGER PRIMARY KEY AUTOINCREMENT`
- `JSONB` → `TEXT` (store JSON as string, parse on read)
- `NOW()` → `CURRENT_TIMESTAMP`

### Connection detection (env var)

```python
# backend/db.py
import os
from sqlalchemy import create_engine

DATABASE_URL = os.getenv("DATABASE_URL")  # e.g., "postgresql://user:pass@host/sou"

if DATABASE_URL:
    engine = create_engine(DATABASE_URL)
    backend = "postgres"
else:
    engine = create_engine("sqlite:///sou.db")
    backend = "sqlite"
```

### Migration tool
- **Alembic** (SQLAlchemy-based) for schema versioning
- Migrations live in `backend/migrations/`
- CI runs `alembic upgrade head` on both Postgres and SQLite before tests

---

## Alternatives Considered

### 1. Postgres-only (no SQLite fallback)
**Rejected.** Requires developers to run `docker-compose` with Postgres for local testing, adding friction. SQLite fallback makes `docker run` trivial.

### 2. Keep JSON files, add DB as optional backend
**Rejected.** JSON files don't scale and create maintenance burden (two write paths). Ruthlessly delete them.

### 3. NoSQL (MongoDB, Redis)
**Rejected.** Homelab has no existing NoSQL infrastructure. Postgres JSONB covers schemaless payloads. Redis may be added later for event queue (NATS JetStream preferred), not primary storage.

### 4. Time-series DB (TimescaleDB, InfluxDB)
**Deferred.** Postgres with partitioning and retention policies is sufficient for Phase 1. If event volume grows (>1M events/day), revisit TimescaleDB extension.

---

## References

- CloudNativePG cluster deployment + backup/restore (Mattermost, Nextcloud, Karakeep)
  — the established homelab pattern this ADR follows
- **ADR-055:** Event schema v1 (agent-agnostic JSON) — defines `events.payload` structure
- **Tracking note:** `2026-10-12-sou-agent-agnostic-redesign.md`

---

**Next steps:**
1. Draft `backend/db.py` adapter with SQLAlchemy models
2. Write Alembic migration for initial schema
3. Add CI job to test migrations on Postgres + SQLite
4. Refactor `store_utils.py` calls to use `db.py`
