# Project overview

## Purpose

MerVLAN manages VLAN placement for SSIDs and Ethernet interfaces on an
Asuswrt-Merlin main router and optional AiMesh nodes. It also maintains the
security rules that prevent clients from escaping to `br0`, observes active
VLAN clients, and presents the state through the WebUI.

## Device roles

- The **main router** owns the WebUI, merged client inventory, configuration
  orchestration, node SSH operations, and cluster-wide observation.
- A **node** runs a curated runtime subset. It applies local VLAN placement and
  publishes local client observations when requested.
- The node does not need the main router's WebUI or cluster merge logic.

## Core mental model

Configuration mutation and observation are separate workloads:

1. A UI or firmware event requests work.
2. The service handler dispatches the appropriate runtime script.
3. The manager acquires ownership and fail-closed protection before mutation.
4. VLAN/bridge configuration is applied and verified.
5. Observation is requested only after configuration reaches a safe boundary.
6. Client data is collected, merged, and atomically published.
7. Progress, logs, locks, and UI state reach an explicit terminal result.

## Where to begin

- Change to VLAN or bridge behavior: start with `functions/mervlan_manager.sh`
  and [the Apply flow](20-runtime-flows.md#apply).
- Change to node orchestration: start with `functions/execute_nodes.sh`,
  `functions/sync_nodes.sh`, and [node operations](70-node-sync-and-ssh.md).
- Change to client data: start with `functions/post_apply_worker.sh`,
  `functions/collect_clients.sh`, and `functions/collect_local_clients.sh`.
- Change to a button or loading state: start with `www/index.html`,
  `mervlan.asp`, and [UI action pipelines](50-ui-action-pipelines.md).
- Change to safety ownership or recovery: start with `settings/lib_mervqt.sh`
  and the fail-closed ownership behavior.

## Repository versus installed addon

The repository contains the complete development surface. Runtime files are
under `functions/`, `settings/`, `www/`, `mervlan.asp`, and the installer/update
scripts. `dev-tools/` is development material: its notes, plans, evidence,
local harnesses, and specifications stay on the developer computer.
Development `Sync Nodes` copies only router-capable executables under
`dev-tools/tests/router/` and `dev-tools/safety/` to development devices.

The main router is the coordinator and source of merged state. A node receives
curated runtime files and settings through Sync Nodes; it is not a second
source checkout. Never edit a node's copied file as a permanent fix.

## Action starting points

For a UI action, start at `www/index.html`, then follow the action name into
`mervlan.asp` and `functions/service-event-handler.sh`. Backend identifiers
such as `apply_vlanmgr`, `executenodesonly_vlanmgr`, and `macrefresh_vlanmgr`
are the trace keys; do not infer a backend path from a visible button label.
Use `rg` on the exact identifier to find frontend, service, progress, and test
references.
