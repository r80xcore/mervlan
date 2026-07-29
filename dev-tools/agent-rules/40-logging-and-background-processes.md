# Logging and background-process safety

Use when changing logs, background work, command substitutions, manager execution, or monitoring.

Runtime logs are under `/tmp/mervlan_tmp/logs/`:

- CLI: `cli_output.log`
- VLAN manager: `vlan_manager.log`
- General: `mervlan.log`

- `info`, `warn`, and `error` normally write to log channels; non-TTY SSH stdout is not reliable progress output.
- Inspect the relevant device log periodically during long tests. Count monitoring sessions toward the two-session SSH limit.
- Do not hardcode or create `$LOGDIR/vlan.log`; use the configured VLAN channel/path.
- `CLI_LOG` is readonly. Worker isolation uses separate `LOG_chan_cli`, `LOG_chan_vlan`, stdout/stderr, and SSH-temp files.
- Do not point CLI and VLAN task channels to the same file; `info -c cli,vlan` would duplicate entries.
- Workers must never write directly to shared CLI/VLAN logs. If live worker visibility is needed, the parent may relay newly appended private worker lines to a shared log.
- The WebUI may publish copied worker CLI/VLAN/stdout logs through the `logs/node_workers` JSON index. Never publish a raw worker-job directory: it can contain SSH temporary paths, PID/start-time identity, result records, and other private metadata.
- Keep the `install.sh` runtime/public projection for `logs/node_workers` intact when changing the log viewer or reinstall checks.
- Mobile log pages need a viewport meta tag, dynamic viewport sizing, and a scrollable outer page on narrow screens; fixed `100vh` minus a desktop constant can clip Firefox Android with its bottom address bar.
- Every intentional background command must redirect stdin/stdout/stderr to `/dev/null` or explicit owned logs.
- Avoid launching background processes inside or near `$(...)` unless their descriptors are explicitly redirected; BusyBox command substitution can wait for inherited pipe descriptors to close.
- Wireless/bridge restart phases can be quiet for about 1.5–2 minutes on node hardware. Check state/logs before treating a quiet period as a hang.
