# MerVLAN developer overview

This is the short orientation guide for the addon. It explains the main code
layers and where to continue reading. The focused documents, current source,
and tests provide the detailed behavior; do not maintain a second copy of
their contracts here.

## First steps

1. Read `dev-tools/docs/README.md` and choose the route for the change.
2. Read the relevant focused notes before opening large source files.
3. Use `rg` to find the exact action, function, setting, result file, or log
   name in the current source.
4. Read the owning shell function and its callers before editing.
5. Run the narrowest relevant local test first, then the required POSIX,
   router, node, or human validation layers.

Mandatory operating constraints are maintained separately from the focused
developer reference; follow the applicable project rules before editing.

## Layer inspection

Trace a UI or API action through these layers:

```text
www/index.html
  → mervlan.asp
  → functions/service-event-handler.sh
  → action-specific function or worker
  → settings/ shared libraries
  → progress, acknowledgement, result, and log files
  → index.html polling and final UI state release
```

Inspect the matching layer here:

| Layer | Start with | Then inspect |
|---|---|---|
| UI controls, payloads, polling | `www/index.html` | `dev-tools/docs/50-ui-action-pipelines.md`, `60-state-and-data.md` |
| ASP bridge and action dispatch | `mervlan.asp` | `functions/service-event-handler.sh` |
| Apply and node orchestration | `functions/mervlan_manager.sh` | `functions/execute_nodes.sh`, `functions/sync_nodes.sh` |
| Observation and client data | `functions/post_apply_worker.sh` | `functions/collect_local_clients.sh`, `functions/collect_clients.sh` |
| Shared state and safety | `settings/lib_mervqt.sh` | `settings/lib_progress.sh`, `settings/lib_action_progress.sh`, lock/progress libraries |
| Boot and healing | `functions/mervlan_boot.sh` | `functions/mervlan_boot_wrap.sh`, `functions/heal_event.sh` |
| Maintenance and recovery | `functions/update_mervlan.sh` | backup, restore, and acknowledgement helpers |
| Developer validation | `dev-tools/tests/` | `90-testing-and-evidence.md`, `92-test-workflows.md` |

When documentation and code disagree, treat the current source and tests as
the behavioral authority, preserve the safety rules, and update the affected
developer note when the difference is a durable workflow change.

## Runtime mental model

- The main router owns the web UI, merged client data, orchestration, and
  shared settings.
- Nodes run a curated runtime subset and publish local observation artifacts;
  they do not own the web UI or merged cluster result.
- `mervlan_manager.sh` mutates local VLAN/bridge state under DHCP Hold and
  lock protection.
- `execute_nodes.sh` coordinates node work and requires validated terminal
  results; a detached launch is not completion.
- `post_apply_worker.sh` serializes observation work and publishes client data
  atomically after configuration work is safe to observe.
- `sync_nodes.sh` stages and verifies a node runtime before activation. On
  development branches it may also copy only the approved executable router
  test tools from `dev-tools/`.

## Settings and identity boundaries

`settings/settings.json` is user data and must survive normal code deployment.
When adding a setting, inspect the structured model, flat form conversion,
defaults, loading conversion, and managed-save verification in
`www/index.html`.

The main router and each node have distinct hardware and identity data. Do not
use a product ID as a unique node identity, and do not repair a divergent node
with an untracked direct edit. Use the approved synchronization flow.

## Focused references

- `00-project-overview.md` — product scope and device roles.
- `10-architecture.md` — component ownership and boundaries.
- `20-runtime-flows.md` — Save, Sync, Apply, refresh, APMO, and maintenance.
- `30-script-tree.md` — entry points and callers.
- `40-function-libraries.md` — shared shell libraries and load order.
- `80-code-limitations.md` — BusyBox, safety, state, and UI invariants.
- `90-testing-and-evidence.md` — validation policy and evidence handling.
- `92-test-workflows.md` — practical test selection and commands.
- `95-deployment-checklist.md` — staged deployment and rollout.
- `troubleshooting.md` — symptom-driven diagnostics.

Keep this file short. Add detail to the focused document that owns it instead
of expanding this overview into another implementation specification.
