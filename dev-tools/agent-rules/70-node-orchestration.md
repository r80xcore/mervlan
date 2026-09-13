# Node orchestration and parallel work

Use when editing `sync_nodes.sh`, `execute_nodes.sh`, SSH job handling, or detached node execution.

- Validate all node IDs/IPs before SSH. Reject duplicates before any remote mutation.
- Node-operation parallelism is controlled by the structured
  `General.NODE_PARALLELISM` setting. The supported range is 1 through 5, with
  a default of 2 for missing legacy settings. This is a MAIN-local scheduler
  control: Save treats it as a main-router/WebUI-local change and node-sync
  change detection excludes it. `MERV_NODE_PARALLELISM` is an optional runtime
  override; malformed runtime or persisted input resolves fail-closed to one
  worker, while Save rejects values outside 1 through 5.
- Sync, Execute's prepare/launch/status phases, client collection, and MAC
  Shield node collection/push use the shared bounded pool. MAIN-local work is
  outside the remote worker slots.
- Complete-node SSH trust preflight is a serial gate before node work. Workers
  write only isolated payloads and terminal results; the MAIN parent validates
  and aggregates those results serially. MAIN MAC Shield enforcement must
  succeed before the node push pool is started; a local enforcement failure
  suppresses node propagation.
- Every worker has an isolated job directory with separate CLI/VLAN/stdout/SSH-temp files and atomic result state.
- Use explicit worker result files for normal completion. PID/start identity is only for safe signaling and crash/PID-reuse handling.
- Do not free a worker slot until a valid terminal result is published, the wrapper and tracked active child are both verified gone by PID/start identity, and the wrapper has been reaped.
- All timeout, missing-result, and parent-death paths must use the same reconciliation sequence: TERM, bounded wait, KILL if required, verify wrapper and child gone, atomically publish/validate one terminal result, then reap and free the slot.
- Detached launch means only `started`; success requires a valid atomic `complete` status for the current run and node.
- Run status must include validated run ID, node ID, state, PID/start identity, timestamps, exit code, and safe reason.
- Never accept stale, malformed, wrong-run, or wrong-node status.
- Preserve staged sync verification/rollback. A failure on one node must not corrupt another node's installation.
- Retention may prune only validated, terminal, old run directories. Never prune live, malformed, unknown, or unverified worker state.
- Follow the current node-operation plan or test matrix in
  `dev-tools/tests/specs/` when a gated node-operation change is being
  implemented; do not rely on ignored completed plans as current instructions.
