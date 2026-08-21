# State and data files

## Persistent addon state

The addon normally lives below `/jffs/addons/mervlan/` on a device.

- `settings/settings.json`: user configuration; preserve during deployment.
  `VLAN.WAN_Native` stores the per-device native uplink request as
  `WAN_NATIVE_MAIN`, `MAIN_WAN_NATIVE_IP`, `MAIN_ASUS_IP`, `PERSISTENT_DEBUG_LOGGING`, and
  `WAN_NATIVE_NODE1..NODE10`;
  the MAIN endpoints are the exact DHCP IPv4s required after numeric and
  ASUS/default MAIN handoffs. ASUS/default is supported only when `br0` uses
  the positively identified physical WAN uplink; unknown tagged-native topology
  is not inferred. `Nodes.NODE<n>_ROLE` is `aimesh` or `standalone`; AiMesh
  derives effective WAN Native from MAIN while Standalone uses its own value.
  Legacy role-less nodes read as Standalone for compatibility.
- `settings/`: shared libraries and runtime defaults.
- `logs/debug/`: bounded persistent WAN Native diagnostic records, created only
  when the explicitly opt-in setting is enabled.
- `tmp/`: persistent databases and generated addon data where configured,
  including MAC Shield and metadata stores.
- `www/`: main-router WebUI and static assets.

## Volatile runtime state

Runtime state is normally below `/tmp/mervlan_tmp/`:

| Area | Purpose |
|---|---|
| `logs/` | CLI, VLAN, general, and isolated worker log channels. |
| `locks/` | Manager, node, observation, DHCP Hold, and recovery ownership. |
| `progress/` | Atomic WebUI action progress records. |
| `results/` | Public merged client JSON and action status results. |
| `client_collection/` | Local/node observation artifacts and temporary files. |
| `node_jobs/` | Isolated per-run node worker directories and terminal results. |
| `selftest.<run-id>/` | Fake backend and state for deterministic tests. |

`locks/dhcp_hold/` is a fail-closed protocol state, not disposable temporary
data. A retained recovery marker and DHCP hold may be cleared only by the
token-owned MerVLAN recovery API after its final topology verification; direct
file or ebtables deletion is not a supported recovery action.

## Ownership and publication

- Lock directories are owned and released by the process that acquired them.
- Generic locks publish one authoritative v2 `owner` record with exactly five
  fields: `pid`, `proc_start_time`, `owner_nonce`, `created`, and `heartbeat`.
  Fields are validated as untrusted text, published atomically, and mode 0600.
  Compatibility sidecars may remain for named readers but never establish
  liveness or reclaimability.
- A complete owner is reclaimed only after exact PID/start identity proves it
  dead or PID-reused. Incomplete claims use bounded publication grace and
  fail closed when age is unavailable. Failed release restores the complete
  owner record before returning failure.
- Worker completion is an explicit validated terminal result, not merely a
  missing PID or lock.
- Shared files are written to a same-directory temporary file and published by
  atomic rename.
- Client JSON must remain readable if a new generation fails; a required
  collector failure must not publish a partial replacement generation.
- Progress and result files are parsed as data, never executed as shell.
- Update maintenance has a journal-bound owner/quiesce marker under the
  maintenance state root; ordinary mutation and observation requests remain
  blocked until terminal cleanup. Observation ownership uses the generic
  identity/owner primitives but keeps generation and coalescing state local to
  the observation worker.

## Useful diagnostics

```sh
sh /jffs/addons/mervlan/functions/post_apply_worker.sh status
cat /tmp/mervlan_tmp/progress/<token>.json
tail -n 100 /tmp/mervlan_tmp/logs/cli_output.log
tail -n 100 /tmp/mervlan_tmp/logs/vlan_manager.log
```

Use exact known paths and bounded reads. Do not dump whole worker directories
or publish raw worker metadata to the WebUI.

## Canonical paths and important variables

`settings/var_settings.sh` defines the runtime contract. The important roots
are:

- persistent addon: `/jffs/addons/mervlan`;
- volatile runtime: `/tmp/mervlan_tmp`;
- logs: `/tmp/mervlan_tmp/logs` (`cli_output.log`, `vlan_manager.log`);
- locks: `/tmp/mervlan_tmp/locks`;
- progress: `/tmp/mervlan_tmp/progress`;
- results: `/tmp/mervlan_tmp/results` and `results/node_runs`;
- client generations: `/tmp/mervlan_tmp/client_collection`;
- selftest state: `/tmp/mervlan_tmp/selftest.<run-id>`;
- evidence: `/tmp/mervlan_tmp/evidence/<run-id>/...`.

The full Sync Nodes runtime manifest stages `settings/lib_owner_lock.sh` as a
0644 library and verifies it on the node. Settings-only Sync intentionally
stages only `settings/settings.json`; developer documentation, plans, and raw
evidence are not runtime payload.

Use variables such as `TMPDIR`, `LOGDIR`, `LOCKDIR`, `RESULTDIR`, `COLLECTDIR`,
and `MERV_PROGRESS_ROOT` after loading `var_settings.sh`; this keeps tests
redirectable and avoids path drift. Maintenance has additional persistent
backup/restore markers. Inspect the action token and result marker before
assuming a backup or restore completed. Never delete a lock or recovery marker
merely to make the UI green.
