# Bounded node operations test matrix

Round 0 design record. These are deterministic local tests to add to
`dev-tools/tests/router/mervlan_selftest.sh`; live router validation remains separately
approved and is not covered by this matrix.

| Case | Scope | Required proof |
| --- | --- | --- |
| `node-job-validation` | node list and job paths | Reject malformed/duplicate IDs and IPs, invalid parallelism/timeouts, unsafe roots, and stale or inconsistent fields before work begins. |
| `node-job-logging` | worker log setup | Each worker has distinct CLI, VLAN, and stdout files; `info -c cli,vlan` never targets one file twice. |
| `node-job-ssh-temp` | SSH helper | Concurrent calls use separate, job-contained stderr paths and clean only their own files. |
| `node-runner-status` | detached runner protocol | Atomically accept valid current-run `started`, `complete`, and `failed` status only; reject partial, duplicate, unknown, malformed, wrong-run, and wrong-node fields. |
| `node-runner-lifecycle` | runner | Verify start acknowledgement, zero-exit completion, manager failure, killed runner, and that a wrapper exit alone is not completion. |
| `node-worker-pool` | scheduler helper | Bound active work to one/two slots, reuse a reaped terminal slot, preserve parent lock ownership, and isolate cleanup. |
| `node-worker-timeout` | scheduler helper | Exercise absolute deadline, TERM, bounded wait, KILL where identity still matches, result publication, child/wrapper verification, reaping, missing result, and PID reuse. |

Required pre-integration coverage adds serial `execute_nodes` status outcomes
(Round 4), two-worker `execute_nodes` preparation/launch/query failures
(Round 5), and staged-sync success/failure/rollback isolation (Round 6).
Every affected runtime shell file must pass `sh -n` on a POSIX/BusyBox-capable
environment; a Windows shell result is not evidence of ASUSWRT compatibility.
