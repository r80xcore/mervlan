# Code limitations and invariants

These are the practical constraints that shape implementation and their
development impact.

## Runtime platform

- Production shell is ASUSWRT BusyBox `/bin/sh`; write POSIX shell only.
- Do not rely on Bash arrays, process substitution, `wait -n`, `flock`, GNU
  options, or desktop utilities.
- Validate numeric input before arithmetic, sleep, timeout, PID, or path use.
- Do not use `$$` alone for concurrent temporary names.
- Avoid background processes near command substitution unless all descriptors
  are explicitly redirected.

## Safety and ownership

- DHCP Hold and MAC Shield are fail-closed during mutation, healing, wireless
  restart, boot, and recovery.
- Exact bridge and ebtables state matters; substring or approximate matching is
  unsafe.
- Only the owner may release a lock or signal a process. Validate PID plus
  process start identity before reclaiming state.
- Configuration work must defer/coalesce observation work rather than race it.
- Never report success from a missing PID, missing marker, or incomplete result.

## Router and node boundaries

- The main router owns merged client JSON and node orchestration.
- Nodes use stable configured identity and publish local artifacts.
- Sync only through the approved staged workflow; never hand-edit a node to
  repair a divergent installation.
- `SSID_04` may intentionally be configured on a node where the SSID is absent;
  that warning is an expected anomaly test case and must not cause a panic or
  unsafe cleanup.

## UI and observation

- Every long-running action needs completion, failure, timeout, and exception
  paths that release its button/loading state.
- Apply modes must perform one final client refresh and wait for its generation.
- Client publication is atomic and successful routine logs stay concise.
- Do not log secrets, private keys, or full user-provided metadata names.

## Repository and API constraints

- `functions/service-event-handler.sh` is the canonical backend action router;
  update it, the ASP bridge, loading configuration, and focused tests together.
- Use exact action identifiers, not labels, when tracing or adding behavior.
- Validate every numeric ID, node ID, path component, and optional payload key
  before using it in a path or shell command. Empty lists and absent SSIDs are
  valid states in some configurations and must be handled deliberately.
- The known `SSID_04` absent-on-one-node condition is an expected topology
  anomaly in the lab. Log it as a warning and continue with safe per-node
  handling; never turn it into a panic, unsafe cleanup, or false global
  success.
- Production code must not depend on `dev-tools`; only explicitly copied
  router-capable executables may be used on development devices.
- Do not make a background launch the success criterion. Persist a bounded
  terminal marker/result and have the caller verify it.

## Settings changes

The consolidated JSON settings model is mirrored by UI conversion code. A new
setting is incomplete until defaults, structured-to-flat serialization,
flat-to-structured loading, and managed-save verification all agree. Add a
focused regression test for empty, missing, special-character, and out-of-range
values where the setting affects shell or node behavior.
