# Script tree and entry points

```text
www/index.html
└── JavaScript action handlers and client UI
    └── mervlan.asp / parent-frame bridge
        └── service-event-handler.sh
            ├── save_settings.sh
            ├── mervlan_manager.sh
            ├── execute_nodes.sh
            │   ├── mervlan_manager.sh on the main router
            │   └── mervlan_manager.sh through node_runner on nodes
            ├── sync_nodes.sh
            ├── post_apply_worker.sh
            ├── mac_refresh.sh
            ├── mac_client_meta.sh
            ├── hw_probe.sh
            ├── dropbear_sshkey_gen.sh
            ├── update_mervlan.sh / mervlan_backup.sh / mervlan_recover.sh
            └── heal_event.sh through Merlin hooks and health cron
```

## Main runtime entry points

| Script | Responsibility |
|---|---|
| `mervlan_manager.sh` | Local VLAN, bridge, SSID, shield, and final security verification. |
| `execute_nodes.sh` | Bounded multi-node Apply orchestration and aggregation. |
| `sync_nodes.sh` | Staged, verified node synchronization. |
| `post_apply_worker.sh` | Snapshot and client collection coordinator. |
| `collect_clients.sh` | Main-router merge of local and node observations. |
| `collect_local_clients.sh` | One-device MAC-only observation artifact. |
| `heal_event.sh` | Merlin event and health-cron healing/snapshot requests. |
| `service-event-handler.sh` | Validated service/action dispatch boundary. |
| `dev-tools/tests/router/mervlan_selftest.sh` | Isolated deterministic regression tests against the installed runtime. |

The live-test safety helper is `dev-tools/safety/mervlan_live_test_guard.sh`.
These developer tools are not runtime dependencies. Development `Sync Nodes`
copies them to the matching addon paths on nodes; production synchronization
does not require them.

## How to trace a change

1. Find the UI trigger or firmware hook.
2. Find the service-handler action name and progress token.
3. Follow the called shell entry point and its sourced libraries.
4. Locate lock ownership, worker launch, and terminal result publication.
5. Trace UI completion, error, timeout, and state release paths.

Use `rg` for action names, progress actions, function names, and runtime paths.

## Complete development tree

```text
dev-tools/
  docs/        numbered notes, README, and troubleshooting
  tests/
    local/     PC-only isolated harnesses
    router/    executable selftest copied by development Sync Nodes
    specs/     matrices and coverage expectations
  safety/      executable live-test guard copied to development devices
  evidence/    ignored downloaded evidence plus README
  to-do/       implementation plans and test records
```

The two executable device-side tools are intentionally separated from
documentation and PC-only material. A new router test belongs in
`tests/router/`, must have an explicit copy path in `sync_nodes.sh`, and must
document its safety boundary before being used.

## Action-to-script tracing

Use this sequence for every button audit or code change:

`www/index.html` button/handler → `mervlan.asp` action bridge →
`functions/service-event-handler.sh` action case → worker/library →
`/tmp/mervlan_tmp` progress/result/log artifact → UI poll and final refresh.

For Apply, inspect all three action cases and `post_apply_worker.sh`; for Sync
Nodes, inspect staging/activation and the optional development test manifest;
for maintenance, inspect backup/recover/update and rollback markers, not just
the visible button handler.
