# Project Diary

## 2026-08-08 — Ownership and lifecycle architecture

The accepted implementation establishes one reusable ownership foundation but
keeps subsystem policy specialized. Process identity and nonce generation live
in `lib_identity.sh`; generic v2 owner records and lock lifecycle live in
`lib_owner_lock.sh`; action serialization is a thin wrapper; DHCP Hold/MAC
Shield and exact ebtables state remain in `lib_mervqt.sh`. This prevents a
generic mutex from erasing safety-specific handoff and failsafe semantics.

## 2026-08-08 — Maintenance and recovery boundary

Update is a journal-bound, authenticated maintenance owner with an explicit
quiesce marker. Ordinary mutation and observation must stop before extraction
and remain blocked until cleanup succeeds. Boot recovery is separate and only
accepts a matching interrupted journal plus a live recovery parent. Standalone
Recovery keeps a minimal compatible owner protocol so it can operate when the
installed library tree is damaged, while preserving staged rollback trees.

## 2026-08-08 — Observation and publication boundary

Observation reuses canonical identity/owner mechanics but retains its own
generation counters, request coalescing, configuration-owner deferral, and
snapshot-versus-collection policy. The main router remains the sole publisher
of merged client JSON; local and node artifacts are inputs to an atomic complete
generation. A blocked, failed, or interrupted observation does not advance
completion.

## 2026-08-08 — Deployment and compatibility boundary

The runtime manifest is explicit and verified before activation; the generic
owner library is required in every full runtime manifest. Developer tooling is
kept out of production payloads except for the two approved executable tools on
development-branch node sync. Existing user settings and node identity are
preserved; divergent nodes are repaired through staged synchronization rather
than direct edits.
