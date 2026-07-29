# Node orchestration and parallel work

Use when editing `sync_nodes.sh`, `execute_nodes.sh`, SSH job handling, or detached node execution.

- Validate all node IDs/IPs before SSH. Reject duplicates before any remote mutation.
- Maximum supported node SSH parallelism is two; invalid configuration falls back safely to one.
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
