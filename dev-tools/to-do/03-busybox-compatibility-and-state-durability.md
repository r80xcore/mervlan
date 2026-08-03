# Plan 03 — BusyBox compatibility and state durability

Priority: 3 — supported-platform correctness

Audit items: #6 launch-timeout naming/semantics, #8 ANSI-C quoting in
`save_settings.sh`, #11 silent JSON helper behavior, #13 progress pruning and
permissions, and #17 `source` in installer/uninstaller.

Dependencies: Plan 1 for the ownership/result vocabulary and Plan 2 for the
progress lifecycle. This plan may be implemented independently of live device
testing, but final ASUSWRT BusyBox validation remains required.

## Objective

Remove shell assumptions that are not guaranteed by ASUSWRT `/bin/sh`, make
settings helpers report whether they actually read or changed data, make
progress retention portable and private, and separate node launch timing from
node completion timing.

## Implementation sequence

### 1. Make the affected shell files POSIX/BusyBox-safe

1. Replace every ANSI-C quote such as `$'\t'` in `functions/save_settings.sh`
   with a POSIX construction such as `TAB=$(printf '\t')` and use it without
   changing the tab-delimited data contract.
2. Replace `source /usr/sbin/helper.sh` in `install.sh` and `uninstall.sh` with
   the POSIX dot command, preserving the existing conditional/error behavior.
3. Search the complete affected call graph for Bash-only syntax, arrays,
   process substitution, `wait -n`, GNU `find`/`sed` options, and command
   assumptions. Fix only issues in scope for these plans; record unrelated
   findings separately.
4. Keep all temporary files below validated roots and avoid `$$` alone for
   concurrent names. Preserve the existing installer/settings behavior.
5. Keep the implementation dependency-free on ASUSWRT: do not replace one
   unsupported construct with GNU `find`, non-portable `sed`, Bash-only
   quoting, `flock`, `wait -n`, `timeout`, arrays, process substitution, or
   a parser that requires tools not present on the target. When a capability is
   unavailable, fail closed or use the documented portable fallback.

### 2. Define explicit JSON helper result contracts

1. Document and implement separate outcomes for the extended JSON helpers:
   found with value, valid missing key, malformed input, and unsupported layout.
   A missing or unsupported key must not return success with an empty value
   unless the caller explicitly requested an optional key. Use an unambiguous
   contract such as exit 0 for found, exit 1 for absent, and exit 2 for
   malformed/unsupported; keep output limited to the value on success.
2. Make extended setters report whether they replaced an existing value,
   inserted a new value, or could not perform the requested operation. Use
   exact outcomes: exit 0 for replaced/inserted, exit 1 for absent or
   unsupported target, exit 2 for malformed input, and exit 3 for temporary or
   publication failure. A missing section/key must not silently return success
   while leaving the file unchanged.
3. Support the layouts that the project intentionally accepts: quoted strings,
   bare numeric/boolean scalars where existing settings can contain them, and
   the current nested sections. Preserve JSON escaping, ordering expectations,
   and atomic same-directory publication.
4. Keep settings as data; never source JSON or use a parser that executes its
   contents. Validate the output after every write and preserve the original
   file if the rewrite fails.
5. Apply the same explicit contract to every `json_get_*` and `json_set_*`
   helper, including section, nested-section, flag, and scalar variants. Do
   not change legacy helper return behavior halfway through the migration.
   Either update every caller in the same implementation round or introduce
   explicitly named extended helpers and migrate callers deliberately. Audit
   all callers of `lib_json.sh`; optional values must be handled explicitly
   rather than by conflating empty output with failure. Add compatibility tests
   for every current settings-save, migration, hardware-probe, and update path.

### 3. Make progress pruning portable and permissions deliberate

1. Replace `find -maxdepth 1` in `lib_progress.sh` with a POSIX immediate-child
   iteration or a capability-probed fallback. Validate each candidate basename,
   require it to be below `MERV_PROGRESS_ROOT`, and prune only terminal,
   validated, old records. Do not rely on a failed capability probe being
   harmless; the chosen path must work on the observed ASUSWRT BusyBox build.
2. Suppress only expected “nothing to prune” conditions. Surface or record
   permission/command errors so a failed prune is diagnosable rather than
   silently treated as complete.
3. Set a restrictive `umask` while creating private progress/state files and
   apply explicit modes. Scope the `umask` to a subshell or save/restore the
   caller's prior value so a progress write cannot change modes of later
   unrelated files. Preserve whatever controlled read access the WebUI
   requires; if public reads are required, expose a sanitized/atomic result
   rather than making the private owner record world-writable.
4. Add a bounded retention cap so unsupported pruning cannot grow `/tmp` or
   JFFS indefinitely. Never delete a live, malformed, unknown, or unverified
   record merely to satisfy the cap. “Validated” for quarantine means only a
   validated basename, approved runtime root, and safe atomic rename; it does
   not mean trusting malformed record contents. Move such evidence to a
   separately bounded quarantine policy, or report a durable recovery fault;
   do not allow “preserve evidence” to become unlimited growth.
5. Apply the same durability rules to the Plan 1 SSH trust state. Define the
   overrideable `MERV_STATE_ROOT`, `MERV_SSH_TRUST_ROOT`, and authoritative
   complete-database path such as `MERV_SSH_TRUST_FILE` once in
   `settings/var_settings.sh`; create the root with mode 700 and database,
   pending-request, and staging files with mode 600 using atomic
   same-directory publication. A multi-node enrollment must replace the
   complete database or publish no change. The trust records and pending
   challenges are main-router state, not progress state and not node
   configuration, so they must not be copied by `sync_nodes.sh` or exposed
   through the public settings symlink. `install.sh`,
   `functions/update_mervlan.sh`, `functions/mervlan_backup.sh`, and
   `functions/mervlan_recover.sh` must preserve/migrate them explicitly across
   active-tree replacement and restore. Preserve the pending/staging expiry
   settings and invoke the bounded Plan 1 reaper from safe boot/recovery
   maintenance; expired requests must be invalidated and staging/quarantine
   entries must be retention-limited, not allowed to accumulate or block a new
   enrollment. Add a deliberate full-uninstall policy rather than deleting
   them as incidental release files.

### 4. Define one timeout matrix and separate node launch, preparation, and completion deadlines

1. Add a clearly named `MERV_NODE_LAUNCH_MAX_SEC` for the remote runner-start
   RPC. Keep `MERV_NODE_PREPARE_MAX_SEC` for preparation,
   `MERV_NODE_COMPLETION_MAX_SEC` for detached manager completion, and
   `MERV_NODE_SYNC_MAX_SEC` for synchronization. Do not reuse any of these for
   the local/main manager.
2. Add a dedicated `MERV_MAIN_MANAGER_MAX_SEC` for the parent-supervised local
   manager. Use an initial default of 600 seconds, matching the current
   detached-completion budget numerically but not sharing its variable. Keep
   SSH connection timeout and final observation timeout separate as well. Any
   different firmware-specific default requires a documented reason and test.
3. Confirm the node runner contract: a successful launch means only `started`;
   normal Apply success still requires the current-run, current-node terminal
   `complete` result. Do not make the launch timeout a hidden cap on detached
   Apply work.
4. Validate and clamp all timeout values. A launch hang must fail and reconcile
   its worker; a long but progressing Apply must continue under the completion
   budget.
5. Update settings/default documentation and tests so a launch timeout and a
   completion timeout cannot be accidentally substituted for one another.

The implementation must publish and test this timeout ownership matrix:

| Phase | Setting | Initial default | Owner |
| --- | --- | ---: | --- |
| SSH connection establishment | capability-specific connection bound | documented capability value | SSH helper/supervisor |
| SSH remote command/transfer | `MERV_SSH_TIMEOUT` | 10s per attempt | SSH helper |
| Node preparation | `MERV_NODE_PREPARE_MAX_SEC` | 180s | prepare pool |
| Node runner launch | `MERV_NODE_LAUNCH_MAX_SEC` | 180s | launch pool |
| Detached node completion | `MERV_NODE_COMPLETION_MAX_SEC` | 600s | status pool |
| Node synchronization | `MERV_NODE_SYNC_MAX_SEC` | 720s | sync pool |
| Main/local manager | `MERV_MAIN_MANAGER_MAX_SEC` | 600s | main supervisor |
| Final observation | `MERV_OBS_AUTOSTART_WAIT_SEC` plus the observation worker deadline | 120s where currently defined | observation coordinator |

The numeric defaults preserve the current effective budgets where they are
known; the separate names prevent one phase from silently controlling another.
If the target Dropbear build has no connection-only option, the supervisor
must still distinguish the connection-establishment window from the total
remote-operation budget and report which phase expired. Do not call
`MERV_SSH_TIMEOUT` a connection timeout when it bounds the whole dbclient
operation.

## Tests and acceptance criteria

Add or extend tests for:

- `sh -n` under a POSIX/BusyBox-capable shell for `save_settings.sh`,
  `install.sh`, `uninstall.sh`, and all changed libraries;
- tab-delimited save parsing with empty fields, tabs, spaces, and special
  characters;
- JSON quoted, bare numeric, bare boolean, missing-key, missing-section,
  malformed, and atomic-write-failure cases;
- progress pruning on BusyBox-like `find` behavior, permission errors, live
  records, malformed records, wrong roots, terminal retention, and restrictive
  modes; restoration of the caller's `umask`; and bounded malformed-record
  quarantine;
- trust-root creation, restrictive permissions, atomic record replacement,
  preservation across install/update/backup/restore/rollback, and proof that
  host-key records never enter node synchronization or public settings output;
- node launch that returns `started` quickly while completion takes longer than
  the launch timeout, plus a launch RPC that genuinely hangs;
- static scans for `source`, ANSI-C quoting, GNU-only options, unsupported
  command assumptions, and unbounded deletion in the affected files;
- a timeout-matrix test proving each phase uses its own configured budget and
  that a local manager cannot inherit `MERV_NODE_PREPARE_MAX_SEC` accidentally.

Run the narrow local shell/settings/progress tests, the router shell-syntax,
action-progress, node-runner, and sync-node-pool groups. If WSL2 or a BusyBox
shell is unavailable, record the result as `INCONCLUSIVE` and schedule the
router validation; do not call a desktop shell result proof of ASUSWRT support.

## Completion gate

This plan is complete only when supported target firmware has a documented
shell capability result, settings helpers distinguish no-op/failure from an
empty value without breaking migrated callers, progress state is private and
bounded, malformed evidence has a bounded recovery policy, and launch,
preparation, synchronization, local-manager, completion, and observation
deadlines are independently tested.
