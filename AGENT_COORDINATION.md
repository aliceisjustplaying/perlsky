# Agent Coordination

Purpose: lightweight shared log for agents working in this repo at the same time.

Rules:
- Before editing, add or update your entry under `Active Work`.
- Treat files listed in another agent's `Locks` as reserved unless you intentionally coordinate a handoff.
- After finishing a batch, move the note to `Recent Handoffs` or update the status in place.
- Keep entries short and append-only where possible.
- Use UTC or include timezone in timestamps.
- Always generate timestamps from the machine clock, for example with `date -u '+%Y-%m-%d %H:%M:%S UTC'`. Do not hand-type or estimate times.
- Each agent must use a distinct agent name. Do not reuse the generic name `Codex` once another agent has claimed it.

Suggested entry format:

```md
## Agent Name
- Updated: 2026-03-11 12:43:44 UTC
- Status: exploring | editing | verifying | blocked | done
- Task: one-line summary
- Locks:
  - path/to/file
  - path/to/other/file
- Notes: anything another agent should know
```

## Active Work

## Recent Handoffs
