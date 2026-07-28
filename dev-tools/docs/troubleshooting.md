# Troubleshooting guide

## Loading panel never completes

Check the progress JSON for the action token, then compare its terminal state
with the CLI/VLAN log. For Apply, confirm the final
`Refreshing client inventory...` phase and observation generation counters.
Check that the UI is polling the same token and that no backend failure was
logged.

## Client data is stale or missing

Run `post_apply_worker.sh status`, inspect pending snapshot/collection
generations, and check `collect_clients.sh` plus node `collect_local_clients.sh`
logs. Do not invoke collection directly if the request belongs to an Apply or
metadata workflow; use the coordinator.

## Apply reports partial success

Inspect node terminal result records, the main execution result, and Phase 3
verification. A node warning or absent configured SSID may be expected, but a
missing result, stale lock, bridge leak, or failed final security check is not.

## SSH or sync fails

Verify the exact target/key, host key, parent directory, protocol (`scp -O`),
remote free space, staged file size, and router-side `/bin/sh -n`. Check only
the permitted number of SSH sessions. Do not disable host-key checking or
switch to an unverified direct node edit.

## Test suite times out

Treat a broad timeout as inconclusive. Preserve output, verify no child test
processes or locks remain, then run the focused affected cases and shell syntax
checks. Do not convert a timeout into a code change without a reproducible
failure.

## Recovery state is present

Stop normal testing. Inspect DHCP Hold ownership, failsafe, recovery-pending,
bridge placement, and management access. Preserve evidence and follow the
approved recovery path; a physical reboot or power cycle requires the user.

## Fast symptom map

| Symptom | Inspect first | Interpretation/next action |
|---|---|---|
| Spinner never ends | same token in progress/ack/result and `cli_output.log` | distinguish active worker, failed terminal state, stale polling, or missing result |
| UI says complete but clients are old | post-apply status and client generation | completion is invalid if final refresh was skipped or an older generation published |
| Node test cannot find `execute_nodes.sh` | node selftest classification and copied manifest | node-only is allowed to omit the main-router orchestration helper |
| Dev test missing after Sync Nodes | Sync log, manifest, node hash/mode/path | rerun verification; do not edit the node directly |
| `SSID_04` absent on a node | per-node apply/result log | expected lab topology anomaly; warning is acceptable, panic/unsafe cleanup is not |
| Host test timed out | child processes, locks, DHCP Hold, selftest root | mark inconclusive and run focused cases after cleanup |
| Evidence consumes router space | exact remote evidence run directory | download/verify, then delete only that run directory |

Use exact paths and bounded reads. Preserve the run ID and evidence before
attempting recovery or cleanup.
