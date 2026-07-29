# Function libraries

Shared shell libraries live in `settings/`. Runtime scripts load only the
libraries needed for their role, and many use an exported loaded marker to
avoid sourcing the same library repeatedly.

| Library | Main contract |
|---|---|
| `var_settings.sh` | Establishes runtime paths, settings locations, hardware context, and node identity. |
| `log_settings.sh` | Configures log channels, files, retention, and `info`/`warn`/`error`. |
| `lib_json.sh` | Reads validated values from JSON/settings files without sourcing data as shell. |
| `lib_mervqt.sh` | DHCP Hold, ownership leases, exact ebtables state, quarantine, recovery, and process identity. |
| `lib_action_progress.sh` | Atomic WebUI progress initialization, phase updates, completion, and failure. |
| `lib_action_runtime.sh` | Runtime markers used to suppress redundant page refreshes during Apply. |
| `lib_action_ack.sh` | Correlated service-action acknowledgements and safe messages. |
| `lib_node_jobs.sh` | Isolated bounded node workers, result validation, reconciliation, and retention. |
| `lib_ssh.sh` | Node validation, bounded SSH, and connection helpers. |
| `lib_ssid_filter.sh` | Configured SSID filtering and node-aware SSID identity. |
| `mac_shield_snapshot.sh` | Snapshot generation, MAC Shield database state, and observation identity. |
| `lib_stp.sh` | Bridge/STP policy and stable bridge identity. |
| `lib_radio.sh` | Radio/interface readiness and restart-related helpers. |

## Load-order rules

- Set/export `MERV_BASE` before sourcing `var_settings.sh` in a direct shell
  diagnostic.
- Load settings and logging before calling shared log or path helpers.
- Load `lib_mervqt.sh` before using DHCP Hold, process identity, or exact rule
  functions.
- Treat settings, marker, progress, and result files as untrusted text. Parse
  and validate them; never source them as shell code.
- Preserve the library's loaded-marker convention and avoid hidden duplicate
  implementations in individual entry-point scripts.

## Choosing the right layer

Put reusable policy in a settings library. Keep orchestration and final
aggregation in the parent script. Keep device-specific behavior in the
manager/node runner. Keep display and browser lifecycle in `www/index.html` or
the parent page; do not make shell scripts responsible for UI state.

## Settings and load markers

`settings/var_settings.sh` is the path and environment contract. Set
`MERV_BASE` before sourcing it; production normally points to
`/jffs/addons/mervlan`, while tests point to an isolated checkout/runtime
fixture. `settings/log_settings.sh` defines log channels and trimming. Do not
hard-code a different temporary root in a production caller.

Libraries use loaded markers such as `VAR_SETTINGS_LOADED` and
`LOG_SETTINGS_LOADED`. Preserve those markers and source order because a worker
graph may source a library more than once; top-level initialization must be
idempotent.

`lib_progress.sh` is the lower-level progress/file primitive. The action
libraries (`lib_action_progress.sh`, `lib_action_runtime.sh`, and
`lib_action_ack.sh`) implement the UI-facing token, lifecycle, and
acknowledgement contract. Use that layer for a button action instead of an
ad-hoc status file.

Settings are data, not shell code. Read/write JSON through existing helpers,
validate types/ranges, and publish managed settings atomically. When adding a
UI setting, update all four conversions in `www/index.html`: structured-to-flat
payload, defaults, flat-to-structured load, and managed-save verification.
