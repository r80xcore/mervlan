# Code limitations and invariants

These are the practical constraints that shape implementation and their
development impact.

## Runtime platform

- Production shell is ASUSWRT BusyBox `/bin/sh`; write POSIX shell only.
- Do not rely on Bash arrays, process substitution, `wait -n`, `flock`, GNU
  options, or desktop utilities.
- The tested ASUSWRT RT-AX95Q endpoint runs BusyBox 1.25.1 without an `id`
  command or applet. Update ownership checks read the effective UID from the
  shell's `/proc/<pid>/status` `Uid:` tuple instead of requiring `id -u`.
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
- Node-operation workers share a bounded pool of 1–5 workers, resolved from
  MAIN-local `General.NODE_PARALLELISM` (default 2; malformed input resolves
  to one). Complete trust preflight and parent result aggregation remain
  serial; MAIN MAC Shield enforcement is authoritative before node push.

## Update package permissions

- Admit the exact cleaner archive member before extraction. Pair the existing
  plain/verbose tar listings by order, verify names/counts, and accept only
  regular `0755` or Git/codeload `0775`. Missing, duplicate, linked or other
  mode entries fail before tar can erase permission intent through umask.
- Create a fresh updater-owned `0700` transaction directory beneath the shared
  temporary root; do not broaden or chmod that shared root. The parent must
  prevent ordinary users from renaming the private entry. Concurrent MerVLAN
  workers are excluded by maintenance/quiesce ownership.
- Open the acquired archive on reserved descriptor 9, require `/proc/<pid>/fd`,
  then unlink its pathname before listing. Validation and extraction both read
  through that descriptor. The raw fallback decompresses the held gzip object
  once into private storage, freezes that raw object on descriptor 9, unlinks
  its path, then lists and extracts the same raw object. Close the descriptor
  immediately after extraction and before later update workers.
- Normalize the cleaner through a fresh private quarantine. Rename the
  archive-derived directory entry into quarantine, validate its type and
  allowed extracted mode, copy its bytes into a new updater-created file, set
  that file to exact `0755`, verify bytes/syntax/protocol, and atomically move
  it back. Never chmod an archive-derived path or add execute bits to content
  from an invalid source mode.
- Strict staged `0755`, syntax and protocol validation remains authoritative.
  The shared boundary applies to remote main/dev/custom/tag and local Update
  archives. Backup restore and maintenance recovery do not use this extractor.
  `update_stage_package_contract_test.sh` covers independent malformed archive
  fixtures, pathname replacement, the gzip/raw descriptor path, cleaner
  quarantine races, available root/non-root contexts and non-root `0777`
  laundering. This protects against
  ordinary unprivileged processes and excluded concurrent MerVLAN workers; it
  does not claim to defend against arbitrary hostile root or a same-UID process
  that already holds a writable descriptor to the archive inode.

## Router and node boundaries

- The main router owns merged client JSON and node orchestration.
- Nodes use stable configured identity and publish local artifacts.
- `General.NODE_PARALLELISM` is a MAIN-local scheduler setting; node-sync
  change detection excludes it, and node-side behavior must not rely on it.
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
