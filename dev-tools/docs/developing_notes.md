# MerVLAN developer notes

> This file remains as a compatibility overview. The focused developer
> reference now lives in [`dev-tools/`](../README.md); start there for
> architecture, runtime flows, limitations, testing, deployment, and
> troubleshooting. The material below remains useful as a compact project map.

This is a practical map of the project for someone making their first change.
It describes the normal runtime path, where state lives, and how to test safely.
It is intentionally shorter than the design plans in `dev-tools/to-do/`.

## Start here

1. Read `README.md` and `docs/HELP.md` for the user-facing behavior.
2. Read the relevant file before changing it. MerVLAN runs on BusyBox `sh`, not
   Bash: keep shell code portable and avoid assuming desktop tools are present.
3. Treat the main router as production. Prefer isolated tests or the node for
   disruptive work.
4. Keep `settings/settings.json` user data intact during deployments. Scripts
   and the web page may be updated independently of a user's settings.

## Repository map

| Area | What it contains |
|---|---|
| `www/` | The MerVLAN page. `index.html` loads settings, invokes backend actions, and renders status and client data. |
| `functions/` | Runtime entry points: applying VLANs, reacting to events, collecting clients, syncing nodes, boot handling, and maintenance. |
| `settings/` | Defaults plus shared shell libraries. This is where configuration parsing, locks, DHCP-hold state, SSH helpers, and MAC-shield helpers live. |
| `templates/` | Template content installed into Asuswrt-Merlin hook scripts. |
| `docs/` | User documentation, design notes, and developer material. Nothing below `docs/` is required by the router at runtime. |

## The normal runtime flow

```text
settings.json
    │
    ├── index.html reads settings and sends UI actions
    │       │
    │       └── service-event-handler.sh
    │               ├── mervlan_manager.sh / execute_nodes.sh (apply work)
    │               └── post_apply_worker.sh (observation work)
    │
    ├── heal_event.sh receives Merlin events and the five-minute health cron
    │       ├── checks/heals VLAN placement when required
    │       └── requests a MAC snapshot only on the regular health cron
    │
    └── collect_clients.sh merges router and node observations
            └── tmp/results/vlan_clients.json → index.html client panel
```

### Applying configuration

- `mervlan_manager.sh` is the main configuration engine. It changes bridges,
  SSID placement, VLAN interfaces, and related firewall state on the local
  device.
- `execute_nodes.sh` coordinates a multi-device apply. It prepares configured
  nodes, runs their manager work, verifies them, then requests one coordinated
  observation pass.
- `sync_nodes.sh` copies the curated runtime subset to each node. It preserves
  node-specific hardware information while synchronizing shared settings.
- `mervlan_boot.sh` and `mervlan_boot_wrap.sh` are the boot entry points. They
  protect the boot-time handoff into the manager.

### DHCP-hold and healing

- `settings/lib_mervqt.sh` owns the shared lock and DHCP-hold protocol. It
  provides token-owned leases, exact ebtables rule checks, handoffs, and
  reconciliation after an interrupted process.
- `heal_event.sh` handles Merlin events and the health cron. It must not make
  untracked bridge changes while another manager run owns the configuration
  lock.
- `mervlan_manager.sh` acquires protection before configuration mutation and
  releases it only after final verification succeeds. If verification is
  uncertain, it remains fail-closed and records recovery state.

When changing one of these files, preserve lock order and ownership checks.
Do not replace token ownership with a shared marker file or an unconditional
cleanup action.

### Observations: MAC snapshots and Active VLAN Clients

`post_apply_worker.sh` is the coordinator for non-mutating observation work.
It coalesces duplicate requests and prevents a snapshot or client collection
from overlapping configuration work.

- A **snapshot** updates the MAC-shield view. Its active data is in tmpfs; its
  JFFS checkpoint is updated only when the meaningful MAC/VLAN assignment
  changes.
- A **collection** gathers router and node client observations, resolves client
  location and metadata, and atomically publishes
  `tmp/results/vlan_clients.json` for the web page.
- The regular five-minute health cron requests only a snapshot. Client
  collection is requested by the existing page-load/manual paths and by the
  established apply/metadata paths.

`collect_local_clients.sh` creates one local observation artifact. On a node,
the main router passes the configured node IP through `post_apply_worker.sh` so
the merged result has stable identity. `collect_clients.sh` then merges the
main-router and node artifacts.

The client UI uses this identity hierarchy:

```text
node slot/IP → configured alias (or “Node N”) → Hardware.PRODUCTID_NODE<N>
```

This produces headings such as `Configured node, RT-AX95Q (configured-node-ip)`.
A product ID describes the model; it is not a unique node identity because
several nodes can be the same model.

## Settings and browser behavior

`settings/settings.json` is structured into sections such as `General`,
`Nodes`, `WiFi`, `VLAN`, and `Hardware`.

The web page contains both a structured-settings model and a flat form model.
When adding a setting that the page reads or saves, update all of these places
in `www/index.html`:

1. Structured JSON → flat cache conversion.
2. Default structured-settings template.
3. Flat cache → structured JSON conversion.
4. Managed-key/save-verification lists.

Otherwise a normal UI save can accidentally omit the new setting.

`General.HTML_CLIENT_REFRESH_MINUTES` controls the client-panel page-load
cooldown in minutes. The default is `5`; valid values are `1` through `1440`.
Manual refresh is intentionally not limited by this setting.

## Main router and nodes

The main router owns the public web page and the merged client JSON. Nodes run
a curated runtime subset; they do not need `www/index.html` or the cluster
merge script. Their role is to apply their local configuration and publish a
local client observation when asked.

Avoid opening many simultaneous SSH sessions to a router. `sync_nodes.sh` and
the shared SSH helpers are designed to work sequentially and to validate a node
before using it.

## Tests and safety tools

| File | Role | Normal user runtime? |
|---|---|---:|
| `functions/post_apply_worker.sh` | Required runtime coordinator for snapshots and client collection. | Yes |
| `dev-tools/tests/router/mervlan_selftest.sh` | Isolated developer test suite. Uses fake ebtables and temporary test state under `/tmp/mervlan_tmp/selftest.*`. | No |
| `dev-tools/safety/mervlan_live_test_guard.sh` | Developer live-test recovery guard. It is inert unless explicitly armed. | No |

### `mervlan_selftest.sh`

Run this first for changes to DHCP-hold ownership, locks, observation behavior,
or shell syntax:

```sh
sh dev-tools/tests/router/mervlan_selftest.sh all
```

Useful focused cases include:

```sh
sh dev-tools/tests/router/mervlan_selftest.sh dhcp-rule-exactness
sh dev-tools/tests/router/mervlan_selftest.sh post-apply
sh dev-tools/tests/router/mervlan_selftest.sh observation-concurrency
sh dev-tools/tests/router/mervlan_selftest.sh client-refresh-contract
sh dev-tools/tests/router/mervlan_selftest.sh shell-syntax
```

The suite does not install live ebtables rules. It creates a fake backend and
temporary state below `/tmp`. `live-audit` is read-only and compares live
observed state when ebtables is available.

### `mervlan_live_test_guard.sh`

Use this only for deliberately disruptive live testing. It can arrange a timed
recovery path if a live test goes wrong. Read its usage and arm it before the
test; always disarm it after successful verification. Prefer the node for this
class of test. Do not use the main router for a disruptive test without an
explicit maintenance window.

## Deployment checklist

1. Review `git diff` and run the relevant isolated tests.
2. Back up the changed router files and pull that backup to the PC.
3. Upload scripts/web assets transactionally. Do not overwrite user settings
   unless the change explicitly requires a settings migration.
4. Verify shell syntax and key runtime checks on the router.
5. Run `sync_nodes.sh` to update the node runtime.
6. Verify the node is idle and that the expected setting/files arrived.
7. Test user-visible behavior from the web page.

## Small conventions that prevent regressions

- Use atomic temporary-file-plus-rename publication for data the web page reads.
- Keep normal health logs quiet; log meaningful changes, failures, and explicit
  user actions rather than every stable polling tick.
- Preserve the existing single version-bump policy for a planned implementation.
- Make fallbacks safe: missing hardware data should degrade presentation, not
  break VLAN enforcement.
- Keep development-only tools out of normal user release payloads unless there
  is a clear support reason to include them.

## How to work in this checkout

Start with `dev-tools/docs/README.md`, then read only the focused notes for the
subsystem being changed. The numbered notes are split so an agent can remain
token-conservative without losing the option to follow a cross-cutting
reference. Use `rg` to locate an exact action/function before opening a large
file, and reread the owning note if the change crosses UI, service, worker,
node, or observation boundaries.

The canonical developer tools live under `dev-tools/`. Documentation, plans,
local tests, specifications, evidence, and developer guidance are PC-only. Only the
explicit router-capable executables are copied by development Sync Nodes.
Follow `92-test-workflows.md` for test selection and
`95-deployment-checklist.md` for rollout; do not invent a second local test or
deployment procedure.
