# Project Structure

## Runtime layout

```text
www/index.html                         WebUI state, payloads, polling, clients
mervlan.asp                            ASP/parent-frame bridge
functions/service-event-handler.sh    action validation and dispatch
functions/mervlan_manager.sh           local VLAN/bridge mutation and verify
functions/execute_nodes.sh             main-router/node Apply orchestration
functions/sync_nodes.sh                staged, verified node synchronization
functions/post_apply_worker.sh         serialized observation generations
functions/collect_clients.sh            main-router merge/publication
functions/collect_local_clients.sh     one-device observation artifact
functions/update_mervlan.sh             staged Update and maintenance quiesce
functions/mervlan_backup.sh             addon backup/archive operations
functions/mervlan_recover.sh            standalone validated Recovery/restore
functions/mervlan_boot*.sh, heal_event.sh boot/healing entry points
settings/*.sh                           shared paths, identity, locks, safety,
                                        progress, SSH, settings, and node jobs
```

## Ownership boundaries

- The browser/ASP layer owns interaction state, payload presentation, polling,
  and final refresh display; it does not own firewall truth or backend locks.
- The service handler owns action routing and input validation; worker policy
  remains in the owning runtime script.
- Parent workers own global action/manager locks, DHCP/MAC safety handoff,
  aggregation, shared cleanup, and final summaries.
- Node workers own only local operation, isolated job directories, and terminal
  result markers. They never write merged cluster JSON or parent logs directly.
- The observation worker owns snapshot/collection serialization and generation
  completion, not VLAN mutation.
- `settings/settings.json` is user data and survives normal runtime deployment.

## State roots

`settings/var_settings.sh` defines redirectable roots. The normal device paths
are `/jffs/addons/mervlan` (persistent addon), `/tmp/mervlan_tmp/logs`,
`/tmp/mervlan_tmp/locks`, `/tmp/mervlan_tmp/progress`,
`/tmp/mervlan_tmp/results`, `/tmp/mervlan_tmp/client_collection`, and
`/tmp/mervlan_tmp/node_jobs`. Observation generations and node artifacts are
staged before atomic publication; prior valid client JSON remains available if
collection fails.

## Synchronization boundary

`sync_nodes.sh` stages an explicit curated runtime manifest, verifies size,
hash, mode, ownership, and BusyBox `sh -n`, then activates atomically with
rollback information. The full runtime manifest includes
`settings/lib_owner_lock.sh` (mode 0644). Settings-only sync transfers only
`settings/settings.json`. On development branches, only
`dev-tools/tests/router/mervlan_selftest.sh` and
`dev-tools/safety/mervlan_live_test_guard.sh` may be copied to nodes;
documentation, plans, evidence, local tests, and specifications stay on the
developer computer.
