# Phase 2: Session Management & Idle Recycling

Goal: Full session lifecycle, idle detection, automatic container stop/restart, concurrency control, and credential handling.

Duration: 2-3 weeks

Implementation Details

1. Session State Machine

```
CREATED → CLONING → IDLE (container stopped)
           ↑           ↓ user message
           │         RUNNING (container active, streaming)
           │           ↓ process exit
           │         WARM (container alive, < 5 min idle window)
           │           ↓ idle timeout (5 min)
           │         IDLE (container stopped)
           │           ↓ user message → new container from volume
           │         RUNNING (cold start)
           │
           │         (any state) → user deletes → DESTROYED
```

Database schema (SQLite):

```sql
CREATE TABLE sessions (
    id TEXT PRIMARY KEY,
    github_user_id INTEGER NOT NULL,
    repo_url TEXT,
    branch TEXT DEFAULT 'main',
    status TEXT,
    container_id TEXT,
    volume_name TEXT,
    created_at TIMESTAMP,
    last_message_at TIMESTAMP
);
```

2. Idle Timeout Manager

A background timer checks:

· Sessions in WARM with last_message_at > 5 min → stop container, set IDLE.
· Sessions in IDLE with no messages for 1 hour → remove container metadata, consider “cold”.

Use a per-session mutex to prevent race conditions during state transitions.

3. Session Restore (Cold Start)

When a message arrives for an IDLE session:

1. Lock session.
2. Create a new container with the same volume mounts.
3. Execute entrypoint; --resume reads .claude/history.jsonl automatically.
4. Stream response as usual.
5. On exit, set state to WARM.

Cold start latency: ~2-5 seconds. Frontend shows “Resuming session…” indicator.

4. Concurrency Control

Per-session message queue: if a message arrives while the session is RUNNING or WARM, enqueue it. The SSE stream is returned only after the previous execution finishes.

Implementation: in-memory map of session locks using promise-based queues.

5. Credential Management (Preliminary)

· User home folder is stored on a named volume per user (claude-home-<githubId>).
· For Phase 2, manual script to copy the folder onto the server and create the volume.
· Phase 3 will add encrypted upload.

6. Volume Cleanup

Delete workspace volume on session deletion. User home volume remains (shared across sessions).

Max workspace size limit or cleanup policy can be added later.

Constraints

· HTTP timeout must be high (10+ minutes) for long Claude invocations.
· Docker daemon restart: recovery routine sets any RUNNING/WARM session to IDLE.

Rejected Alternatives

· Keep containers always running: Waste of memory.
· docker pause/unpause: Doesn’t free memory.
· No warm period: Every follow-up message would incur a cold start; short warm window improves UX.

Deliverables

· Complete session lifecycle with idle recycling.
· Concurrency protection.
· Frontend session status display and cold start handling.
