# State and data files

## Persistent addon state

The addon normally lives below `/jffs/addons/mervlan/` on a device.

- `settings/settings.json`: user configuration; preserve during deployment.
- `settings/`: shared libraries and runtime defaults.
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

## Ownership and publication

- Lock directories are owned and released by the process that acquired them.
- Worker completion is an explicit validated terminal result, not merely a
  missing PID or lock.
- Shared files are written to a same-directory temporary file and published by
  atomic rename.
- Client JSON must remain readable if a new generation fails.
- Progress and result files are parsed as data, never executed as shell.

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

Use variables such as `TMPDIR`, `LOGDIR`, `LOCKDIR`, `RESULTDIR`, `COLLECTDIR`,
and `MERV_PROGRESS_ROOT` after loading `var_settings.sh`; this keeps tests
redirectable and avoids path drift. Maintenance has additional persistent
backup/restore markers. Inspect the action token and result marker before
assuming a backup or restore completed. Never delete a lock or recovery marker
merely to make the UI green.
