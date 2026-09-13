# Function libraries

Shared shell libraries live in `settings/`. Runtime scripts load only the
libraries needed for their role, and many use an exported loaded marker to
avoid sourcing the same library repeatedly.

| Library | Main contract |
|---|---|
| `var_settings.sh` | Establishes runtime paths, settings locations, hardware context, and node identity. |
| `log_settings.sh` | Configures log channels, files, retention, and `info`/`warn`/`error`. |
| `lib_json.sh` | Reads validated values from JSON/settings files without sourcing data as shell. |
| `lib_identity.sh` | Canonical PID/start identity matching and current-shell nonce generation. |
| `lib_owner_lock.sh` | Strict v2 generic owner grammar, atomic publication, bounded acquire/reclaim, quarantine, and authenticated release. |
| `lib_action_lock.sh` | Thin action policy wrapper for self-owned and authenticated parent-owned action locks. |
| `lib_mervqt.sh` | Specialized DHCP Hold/phase ownership, exact ebtables state, quarantine, recovery, and compatibility wrappers to canonical identity/owner helpers. |
| `lib_action_progress.sh` | Atomic WebUI progress initialization, phase updates, completion, and failure. |
| `lib_action_runtime.sh` | Runtime markers used to suppress redundant page refreshes during Apply. |
| `lib_action_ack.sh` | Correlated service-action acknowledgements and safe messages. |
| `lib_node_jobs.sh` | Shared 1–5-worker node-operation pool, isolated workers, result validation, reconciliation, and retention. |
| `lib_ssh.sh` | Node validation, bounded SSH, and connection helpers. |
| `lib_ssid_filter.sh` | Configured SSID filtering and node-aware SSID identity. |
| `mac_shield_snapshot.sh` | Snapshot generation, MAC Shield database state, and observation identity. |
| `lib_stp.sh` | Bridge/STP policy and stable bridge identity. |
| `lib_radio.sh` | Radio/interface readiness and restart-related helpers. |
| `lib_update_state.sh` | Durable Update phase journal and explicit maintenance-quiesce state. |
| `lib_node_reconcile.sh` | Atomic, bounded node-action retry marker used by boot/health reconciliation. |

## Load-order rules

- Set/export `MERV_BASE` before sourcing `var_settings.sh` in a direct shell
  diagnostic.
- Load settings and logging before calling shared log or path helpers.
- Load `lib_mervqt.sh` before using DHCP Hold, process identity, or exact rule
- Load `lib_identity.sh` before requesting process identity or nonces, and
  call `merv_identity_nonce_next` directly in the current shell. Never put a
  sequence-mutating nonce helper in command substitution.
- Load `lib_owner_lock.sh` before generic lock acquire/release or v2 owner
  parsing. Its five-field `owner` record is authoritative; compatibility
  sidecars are not parsed for liveness or reclaim.
- Load `lib_action_lock.sh` for action enter/export/leave. Parent context must
  match PID/start/nonce and must not fall back to self-acquisition.
- Load `lib_mervqt.sh` before using DHCP Hold or exact rule functions. DHCP
  remains specialized and fail-closed, but uses the canonical identity nonce.
- Treat settings, marker, progress, and result files as untrusted text. Parse
  and validate them; never source them as shell code.
- Preserve the library's loaded-marker convention and avoid hidden duplicate
  implementations in individual entry-point scripts.

## Node-job pool

`lib_node_jobs.sh` resolves the effective width for each `mnj_pool_run` call
from the MAIN-local `General.NODE_PARALLELISM` setting. Values 1 through 5 are
supported; a missing legacy setting defaults to 2. The optional
`MERV_NODE_PARALLELISM` environment value is a runtime override. Malformed
runtime or persisted input resolves to one worker, and the Save path rejects
values outside the supported range. Save and node-sync change detection treat
the setting as MAIN/WebUI-local. Sync, Execute, client collection, and MAC
Shield node collect/push share this pool; MAIN-local work does not consume a
remote slot.

The pool owns worker scheduling and isolated terminal results only. Complete
node trust preflight occurs serially before node work, and each MAIN parent
validates and aggregates worker artifacts serially. MAC Shield applies the
authoritative database on MAIN before propagating it through the node pool.

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

Libraries use loaded markers such as `VAR_SETTINGS_LOADED`,
`LOG_SETTINGS_LOADED`, `LIB_IDENTITY_LOADED`, and `LIB_OWNER_LOCK_LOADED`.
Preserve those markers and source order because a worker graph may source a
library more than once; top-level initialization must be idempotent.

`lib_progress.sh` is the lower-level progress/file primitive. The action
libraries (`lib_action_progress.sh`, `lib_action_runtime.sh`, and
`lib_action_ack.sh`) implement the UI-facing token, lifecycle, and
acknowledgement contract. Use that layer for a button action instead of an
ad-hoc status file.

Settings are data, not shell code. Read/write JSON through existing helpers,
validate types/ranges, and publish managed settings atomically. When adding a
UI setting, update all four conversions in `www/index.html`: structured-to-flat
payload, defaults, flat-to-structured load, and managed-save verification.
