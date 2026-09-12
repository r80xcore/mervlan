# Runtime flows

## Apply

There are three user-visible modes:

1. **Local Apply** invokes `mervlan_manager.sh` on the main router.
2. **Nodes Only** invokes `execute_nodes.sh nodesonly`, skipping local VLAN
   mutation.
3. **Main + Nodes** invokes `execute_nodes.sh`, which coordinates both sides.

Every mode must end with exactly one coordinated snapshot/client refresh. The
loading task remains active until that final observation generation completes.
The progress phase is `Refreshing client inventory...`.

Each asynchronous action has one authenticated owner and one terminal result.
Busy, malformed, unknown-owner, invalid-parent, and cleanup-failure outcomes
are explicit failures; an accepted token is never left running because a
worker disappeared. INT/TERM handlers terminate after bounded child
reconciliation and cannot resume normal work after cleanup.

Main + Nodes and Nodes Only use `execute_nodes.sh` Phase 4. A direct local
manager run performs the same request and waits through `post_apply_worker.sh
run-wait`. Combined runs pass `--no-collect` to the local manager so collection
is not duplicated.

### WAN Native transport

`functions/mervlan_wan.sh` is the sole runtime owner of the optional native
WAN/uplink transport. `mervlan_manager.sh` retains lifecycle ownership only:
it performs read-only preflight, preserves the actual live `br0` uplink VLAN
member during generic cleanup, invokes WAN convergence before ordinary VLAN
creation, reapplies it after ASUS rc/trunk work, and includes WAN verification
in the final fail-closed gate.

The persisted keys live under `VLAN.WAN_Native` as `WAN_NATIVE_MAIN`,
`MAIN_WAN_NATIVE_IP`, `MAIN_ASUS_IP`, and `WAN_NATIVE_NODE1..NODE10`.
The two MAIN endpoints are explicit IPv4-only expectations for the numeric and
ASUS/default DHCP domains respectively. Any MAIN domain transition requires
ASUS LAN DHCP and acquisition of the target-domain endpoint before commit.
`PERSISTENT_DEBUG_LOGGING` is an independent troubleshooting switch: it is
disabled by default and, when explicitly enabled, records only selected WAN
Native lifecycle boundaries in a bounded JFFS diagnostic stream. It never
enables boot/heal, resumes a transaction, or participates in recovery logic.
The node endpoint resolver does not consume either MAIN-only endpoint. The
current supported ASUS/default restoration boundary is `br0 -> WAN_IF` on the
positively detected physical uplink; unknown firmware-owned tagged-native
topology is rejected rather than inferred. A numeric value (2-4094) may replace an existing native `br0` uplink
path with `WAN_IF.VID`, but must fail closed if there is no existing native
path to replace. The selected VID is exclusive on that device and cannot also
be used by a managed SSID, access port, or trunk membership.

Transitions are convergent from live topology rather than a remembered prior
setting: create/validate the replacement upper first, perform a short
break-before-make bridge swap, preserve the `br0` MAC, verify exact membership,
and roll back to the captured prior path on failure. Returning to ASUS removes
only an active MerVLAN tagged-native upper; otherwise it is a no-op.

For either MAIN transport-domain transition, DHCP lifecycle is part of that same rollback
transaction. MerVLAN authenticates the existing ASUS `udhcpc` by PID, process
start identity, and allowlisted `br0` argv; sends `SIGUSR2` to release and
waits for the old address to disappear. A released client may either exit or
remain alive. A live client is authenticated again immediately before one
`SIGTERM`, and a replacement is started only after the old process is gone and
no `udhcpc` remains on `br0`. A proven-dead PID file may be removed only when
it still names that dead client. On any failure, `br0` is restored to its
original L2 member first; a released-but-live exact client is then renewed on
that original domain. There is no SIGKILL fallback and no concurrent DHCP
client launch. The helper `health` mode is read-only and provides strict L2
verification for fast/full heal checks; MAIN additionally verifies its explicit
expected DHCP address and default route when configured. Heal detects a mismatch
but hands any mutation back to the normal manager owner.

## Save Settings

`index.html` validates and prepares the settings payload, then submits it
through the parent/service action path. The UI waits for acknowledged backend
completion and, where applicable, verifies that persisted settings match the
requested managed values before releasing the action state.

When `AUTO_SYNC_SETTINGS` is enabled and a save changes node-relevant
settings, the local save reaches a terminal acknowledgement first. The UI
then starts a separate `syncsettings_vlanmgr` action, which owns its own
progress panel and complete-set SSH preflight. If host-key trust is required,
that settings-only action pauses for review and resumes as settings-only; it
must not fall back to a full Sync Nodes deployment. Changes limited to
`AUTO_SYNC_SETTINGS`, `HTML_CLIENT_REFRESH_MINUTES`, or `EXPERIMENTAL` remain
local and do not start the node action. APMO uses the same settings-only
follow-up after its override/probe sequence. Boot Enable retains its existing
system-wide synchronization behavior.

## Sync Nodes

`sync_nodes.sh` validates the node list, stages a curated runtime subset,
verifies each staged installation, activates it atomically, and reports
per-node terminal results. The main router is validated first. Node-specific
settings and hardware identity are preserved.

The full runtime manifest includes `settings/lib_owner_lock.sh` with mode
0644, and staged validation checks it. Settings-only Sync remains a
`settings/settings.json`-only operation; developer documentation and evidence
are never copied to nodes.

## Refresh Clients

Manual and page-load refreshes request the observation coordinator. The worker
serializes snapshot and collection generations, and the WebUI waits for fresh
client data or a bounded, visible timeout. Health cron normally requests a
snapshot only; it does not turn into a recurring client collection job.

When a paused client refresh resumes after SSH trust enrollment, the resume
action remains the browser-visible progress owner. Its nested host-key recheck
uses an isolated child progress record, while the observation coordinator
relays queued, configuration-wait, snapshot, and collection phases back to the
resume action. This prevents a verified recheck from leaving a false running
progress record or making queued snapshot work look like a stalled resume.

For a normal progress-backed refresh, the browser owns the meaningful client
stages and ignores transient nested SSH-probe progress. A verified parent
preflight grants only the immediately spawned, unchanged node set a short-lived
reuse token, avoiding a second full host-key probe before collection. Each
node command still enforces its pinned host key independently.

## APMO, MAC Shield, and metadata

- APMO persists the requested hardware settings, waits for persistence, then
  requests a verified hardware probe with a correlated terminal acknowledgement.
- MAC Shield rebuild requests a coordinated snapshot and reports backend failure
  before dependent client freshness work is treated as successful.
- Metadata save preserves valid updates, reports partial/failure outcomes, and
  avoids placing full user-provided names in logs.

## Update, restore, keys, and service actions

Maintenance actions use the shared loading/progress lifecycle and bounded
polling. Update/restore activation is staged and validated; Update records a
durable phase journal, performs a measured RAM/tmp-space check, enters an
explicit maintenance-quiesce state before extraction, and keeps the manager,
healer, boot wrapper, Save/APMO, Apply, and ordinary node-sync workers from
starting new mutations during that window. The normal addon backup/archive and
activation recovery paths remain the only router-side copies owned by the
addon; lifecycle journals and retry markers contain metadata only.

Update child context is authenticated against the live maintenance owner;
`MERV_UPDATE_OWNER=1` by itself is only an untrusted hint. Boot recovery is a
separate journal-bound path, and a failed or interrupted cleanup preserves the
owner/quiesce state for reconciliation instead of reporting success.

Update retries transient node reachability failures within a bounded
pre-mutation window and reports trust, authentication, malformed configuration,
and remote-runtime failures separately. A boot-time node outage creates one
owned delayed reconciliation marker for the health cron; it does not create an
untracked background sleep or retry indefinitely. SSH key generation and
service checks report explicit terminal success or failure. Restore, undo, and
other disruptive actions require the appropriate human-controlled gate.

## UI action matrix

| User action | Backend action(s) | Completion contract | Human gate |
|---|---|---|---|
| Save | `save_vlanmgr` | persist, verify managed settings, reload UI state | no, unless followed by Apply |
| Sync Nodes | `sync_vlanmgr` | staged copy, activation, per-node verification | no; avoid concurrent node work |
| Apply local | `apply_vlanmgr` | manager verification, then one client refresh | yes before live test |
| Apply nodes | `executenodesonly_vlanmgr` | node results, then one client refresh | yes before live test |
| Apply main + nodes | `executenodes_vlanmgr` | parent/node results, then one client refresh | yes before live test |
| All Settings | save plus selected follow-up | acknowledged save before follow-up | depends on follow-up |
| APMO | hardware probe/action path (`hwprobe_vlanmgr` where selected) | verified hardware result and UI state | only if hardware changes |
| Update/Restore | update/backup/recover actions | staged validation, activation, terminal result | restore/undo/update requires preparation |
| SSH key install | `genkey_vlanmgr` and publication path | key generated, published, connectivity verified | no, node connectivity required |
| Rebuild MAC Shield | `macrefresh_vlanmgr` | rebuild, atomic publish, one client refresh | stop on br0/security anomaly |
| Edit Metadata | `macclientmeta_vlanmgr` | persist, apply annotation, one client refresh | no |
| Refresh Clients | `collectclients_vlanmgr` | new client generation published | no |

The exact visible label may vary. The action identifier in
`service-event-handler.sh` and `www/settings/loading_actions.json` is the
contract to trace. All three Apply paths must end with the same observation
contract; node-only is not fire-and-forget.
