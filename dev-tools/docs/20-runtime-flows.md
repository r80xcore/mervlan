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

Main + Nodes and Nodes Only use `execute_nodes.sh` Phase 4. A direct local
manager run performs the same request and waits through `post_apply_worker.sh
run-wait`. Combined runs pass `--no-collect` to the local manager so collection
is not duplicated.

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
