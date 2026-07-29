# Locks, ownership, and fail-closed state

Use when changing DHCP Hold, ebtables, locks, workers, manager lifecycle, or recovery.

- DHCP protection is fail-closed. Do not release a Hold until final placement and exact rule verification succeed.
- Match ebtables rules exactly; approximate/substring matching is unsafe.
- Validate process ownership with PID plus `/proc` start time before signaling, reclaiming, or releasing ownership.
- A normal background-worker completion must be an explicit atomic result, not merely a missing PID.
- Background workers must reset inherited `EXIT`, `INT`, and `TERM` traps before work.
- Only the parent owns orchestration locks, shared cleanup, global aggregation, and final summaries.
- Never release a parent lock from a child process or delete another worker's state.
- Validate every cleanup path as a descendant of an approved root. Do not use broad globs or unvalidated `find ... rm -rf`.
