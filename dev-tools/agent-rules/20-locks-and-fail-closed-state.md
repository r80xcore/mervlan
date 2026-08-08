# Locks, ownership, and fail-closed state

Use when changing DHCP Hold, ebtables, locks, workers, manager lifecycle, or recovery.

- DHCP protection is fail-closed. Do not release a Hold until final placement and exact rule verification succeed.
- Match ebtables rules exactly; approximate/substring matching is unsafe.
- Validate process ownership with PID plus `/proc` start time before signaling, reclaiming, or releasing ownership.
- Normal runtime identity and nonce generation is provided by
  `settings/lib_identity.sh`; call `merv_identity_nonce_next` in the current
  shell and consume `MERV_IDENTITY_NONCE`. Do not recreate nonce state or use
  command substitution around sequence-mutating helpers.
- Generic locks use the strict five-field v2 `owner` record from
  `settings/lib_owner_lock.sh` (`pid`, `proc_start_time`, `owner_nonce`,
  `created`, `heartbeat`). Compatibility sidecars are not authoritative.
- Reclaim only a complete owner proven dead or PID-reused. Live owners remain
  protected regardless of heartbeat age; incomplete or unverifiable claims
  fail closed and are quarantined only under their bounded policy.
- Generic release must verify exact PID/start/nonce and restore the complete
  owner record if directory removal fails. Child processes never release a
  parent-owned action lock.
- Action parent context is authenticated by exact PID/start/nonce through
  `lib_action_lock.sh`; a parent-held child must not fall back to self-acquire.
- Update maintenance is stronger than the ordinary action lock. A bare
  `MERV_UPDATE_OWNER=1` flag authorizes nothing; child context must match the
  live maintenance owner and journal/quiesce state.
- Observation reuses the canonical identity/owner mechanics but retains its
  own generation, coalescing, and deferral policy. Failed or blocked
  observation does not advance the published generation.
- A normal background-worker completion must be an explicit atomic result, not merely a missing PID.
- Background workers must reset inherited `EXIT`, `INT`, and `TERM` traps before work.
- Only the parent owns orchestration locks, shared cleanup, global aggregation, and final summaries.
- Never release a parent lock from a child process or delete another worker's state.
- Validate every cleanup path as a descendant of an approved root. Do not use broad globs or unvalidated `find ... rm -rf`.
