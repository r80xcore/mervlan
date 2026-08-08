# Project Core Technology

## Runtime platform

- Production target: Asuswrt-Merlin firmware on the main router and optional
  AiMesh nodes.
- Production shell: POSIX `/bin/sh` on ASUSWRT BusyBox. Runtime code cannot
  assume Bash arrays, GNU `timeout`, `flock`, process substitution, or other
  desktop utilities.
- The main-router WebUI is `www/index.html` behind the `mervlan.asp` bridge;
  `functions/service-event-handler.sh` is the validated backend action router.
- Persistent addon state normally resides at `/jffs/addons/mervlan`; volatile
  locks, progress, results, logs, workers, and observation state reside under
  `/tmp/mervlan_tmp`.

## Ownership and lifecycle primitives

`settings/lib_identity.sh` is the normal source of PID/start-time identity and
per-process nonces. PID alone never authorizes signalling, reclaim, or release.
`settings/lib_owner_lock.sh` provides the generic v2 owner protocol. Its
authoritative record contains exactly:

```text
pid=<positive decimal>
proc_start_time=<positive decimal>
owner_nonce=<validated token>
created=<positive decimal>
heartbeat=<positive decimal>
```

Owner records are strictly parsed as data, atomically published, and matched by
the complete identity tuple. A complete live owner is not reclaimed by age;
failed release restores authoritative ownership. Compatibility sidecars, when
retained for named readers, are never authoritative.

`settings/lib_action_lock.sh` is the thin action policy layer. It authenticates
inherited parent ownership, distinguishes self-owned and parent-owned modes,
and lets only a self owner release. `settings/lib_mervqt.sh` remains the
specialized DHCP Hold/MAC Shield/ebtables and failsafe layer; it is not replaced
by a generic mutex.

`settings/lib_update_state.sh` owns the durable Update journal, quiescence
marker, authenticated live-child context, journal-bound boot recovery, and
delayed reconciliation marker. `post_apply_worker.sh` reuses common ownership
mechanics but retains observation-specific generation, coalescing, deferral,
and snapshot-versus-collection policy.

## Data and publication

Settings are data, not shell code. Shared state and client JSON are written via
validated temporary files and same-directory atomic rename. Progress and result
records are untrusted data and are never sourced as shell. Node jobs use
isolated directories, bounded concurrency (at most two simultaneous SSH
sessions), and explicit validated terminal result records.
