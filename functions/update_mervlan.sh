#!/bin/sh
#
# ============================================================================ #
#                                                                              #
#   /$$      /$$                     /$$    /$$ /$$        /$$$$$$  /$$   /$$  #
#  | $$$    /$$$                    | $$   | $$| $$       /$$__  $$| $$$ | $$  #
#  | $$$$  /$$$$  /$$$$$$   /$$$$$$ | $$   | $$| $$      | $$  \ $$| $$$$| $$  #
#  | $$ $$/$$ $$ /$$__  $$ /$$__  $$|  $$ / $$/| $$      | $$$$$$$$| $$ $$ $$  #
#  | $$  $$$| $$| $$$$$$$$| $$  \__/ \  $$ $$/ | $$      | $$__  $$| $$  $$$$  #
#  | $$\  $ | $$| $$_____/| $$        \  $$$/  | $$      | $$  | $$| $$\  $$$  #
#  | $$ \/  | $$|  $$$$$$$| $$         \  $/   | $$$$$$$$| $$  | $$| $$ \  $$  #
#  |__/     |__/ \_______/|__/          \_/    |________/|__/  |__/|__/  \__/  #
#                                                                              #
# ============================================================================ #
#                - File: update_mervlan.sh || version="0.71"                   #
# ============================================================================ #
# - Purpose:    Update the MerVLAN addon in-place while preserving user data.  #
#                                                                              #
# ============================================================================ #
# ================================================== MerVLAN environment setup #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_JSON_LOADED LIB_SSH_LOADED LIB_OWNER_LOCK_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_ACTION_LOCK_LOADED:-}" ] || . "$MERV_BASE/settings/lib_action_lock.sh" 2>/dev/null || {
  error -c cli,vlan "Unable to load the action-lock classifier; refusing update"
  exit 1
}
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh"
[ -n "${LIB_SSH_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssh.sh"
[ -n "${LIB_OWNER_LOCK_LOADED:-}" ] || . "$MERV_BASE/settings/lib_owner_lock.sh" 2>/dev/null || {
  error -c cli,vlan "Unable to load the owner-lock library; refusing update"
  exit 1
}
[ -n "${LIB_MERVQT_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mervqt.sh" 2>/dev/null || {
  error -c cli,vlan "Unable to load the DHCP/L2 safety library; refusing update"
  exit 1
}
[ -n "${LIB_UPDATE_STATE_LOADED:-}" ] || . "$MERV_BASE/settings/lib_update_state.sh" 2>/dev/null || {
  error -c cli,vlan "Unable to load the Update lifecycle state library; refusing update"
  exit 1
}
# =========================================== End of MerVLAN environment setup #
if ! cd /tmp 2>/dev/null && ! cd / 2>/dev/null; then
  error -c cli,vlan "Unable to enter a safe temporary directory; refusing update"
  exit 1
fi
if [ -f /usr/sbin/helper.sh ] && ! . /usr/sbin/helper.sh; then
  error -c cli,vlan "Unable to load the router helper library; refusing update"
  exit 1
fi
SSH_NODE_USER=$(get_node_ssh_user)
SSH_NODE_PORT=$(get_node_ssh_port)

update_html_version() {
	_update_html_file="$1"
	_update_html_version=""
	[ -f "$_update_html_file" ] || return 1
	_update_html_version=$(sed -n 's/.*index\.html version="\([^"]*\)".*/\1/p' \
		"$_update_html_file" 2>/dev/null | head -n 1 | tr -d '\r\n')
	[ -n "$_update_html_version" ] || return 1
	case "$_update_html_version" in
		v*) printf '%s\n' "$_update_html_version" ;;
		*) printf 'v%s\n' "$_update_html_version" ;;
	esac
}

update_changelog_version() {
	_update_changelog_file="$1"
	_update_changelog_version=""
	[ -f "$_update_changelog_file" ] || return 1
	_update_changelog_version=$(sed -n 's/^[[:space:]]*mervlan[[:space:]]*\(v[0-9][^[:space:]]*\).*/\1/p' \
		"$_update_changelog_file" 2>/dev/null | head -n 1 | tr -d '\r\n')
	[ -n "$_update_changelog_version" ] || return 1
	printf '%s\n' "$_update_changelog_version"
}

update_channel_label() {
	if [ "${UPDATE_SOURCE:-remote}" = "local" ]; then
		printf '%s\n' 'local archive'
		return 0
	fi
	case "${CHANNEL:-main}" in
		main|main_direct|refs/tags/*) printf '%s\n' 'stable branch' ;;
		dev|refs/heads/dev) printf '%s\n' 'development branch' ;;
		*) printf '%s\n' 'custom branch' ;;
	esac
}

# Run one update child with captured diagnostics while preserving its exact
# return code.  The helper deliberately logs a stage label rather than the
# full command line, so credentials or signed URLs passed as arguments are not
# copied into the router log.  The child output itself is replayed because
# install/rollback scripts often put the actionable reason on stderr.
UPDATE_STEP_SEQ=0
run_update_step() {
	_update_step_name="$1"
	shift
	_update_step_dir="${MERV_UPDATE_STEP_DIR:-/tmp}"
	_update_step_seq=$((UPDATE_STEP_SEQ + 1))
	UPDATE_STEP_SEQ="$_update_step_seq"
	_update_step_capture="$_update_step_dir/mervlan_update_step.${_update_step_seq}.$$"
	mkdir -p "$_update_step_dir" 2>/dev/null || return 1
	: > "$_update_step_capture" 2>/dev/null || return 1
	info -c cli,vlan "Update step start: $_update_step_name"
	"$@" >"$_update_step_capture" 2>&1
	_update_step_rc=$?
	if [ -s "$_update_step_capture" ]; then
		while IFS= read -r _update_step_line; do
			# Avoid replaying common inline credential fields if a child emits one.
			_update_step_safe=$(printf '%s\n' "$_update_step_line" | sed \
				-e 's/[Pp]assword=[^ ]*/password=<redacted>/g' \
				-e 's/[Tt]oken=[^ ]*/token=<redacted>/g')
			info -c cli,vlan "Update step [$_update_step_name]: $_update_step_safe"
		done < "$_update_step_capture"
	fi
	rm -f "$_update_step_capture" 2>/dev/null || \
		warn -c cli,vlan "Update step [$_update_step_name]: capture cleanup failed"
	if [ "$_update_step_rc" -eq 0 ]; then
		info -c cli,vlan "Update step complete: $_update_step_name rc=0"
	else
		error -c cli,vlan "Update step failed: $_update_step_name rc=$_update_step_rc"
	fi
	return "$_update_step_rc"
}

# ========================================================================== #
# GLOBAL UPDATE STATE FLAGS                                                  #
# ========================================================================== #

# Original boot enabled state before teardown (0/1)
PRE_BOOT_ENABLED="0"

# Set to 1 once pre-update teardown of hooks has been performed
TEARDOWN_DONE="0"

# Set to 1 once the temporary full-tree rollback copy has been validated.
BACKUP_READY="0"

# Set to 1 once we start performing destructive operations on $MERV_BASE
DESTRUCTIVE_TOUCHED="0"

# Set to 1 when the main MAC DB was successfully preserved before teardown
MAC_DB_BACKUP_PRESENT="0"

# Non-fatal remote/hardware/reconciliation failures are accumulated so the
# caller sees a truthful partial-success result instead of a clean success.
UPDATE_PARTIAL="0"

# Serialize updates with manual backup, deletion, and restore operations.
UPDATE_MAINTENANCE_LOCK="${MERVLAN_MAINTENANCE_LOCK_OVERRIDE:-${LOCKDIR:-/tmp/mervlan_tmp/locks}/mervlan_maintenance.lock}"
UPDATE_MAINTENANCE_LOCK_OWNED="0"
UPDATE_MAINTENANCE_LOCK_NONCE=""
UPDATE_MAINTENANCE_LOCK_START=""
UPDATE_SIGNAL_HANDLING="0"
UPDATE_ACTIVATION_STARTED="0"
UPDATE_PRESERVE_TMP="0"
UPDATE_PRESERVE_JFFS="0"
UPDATE_NODES_TOUCHED="0"
UPDATE_RUNTIME_RESTORED="0"
UPDATE_JFFS_STAGE=""
UPDATE_JFFS_OLD=""
UPDATE_POOL_ABORT_FAILED="0"
UPDATE_RECOVERY_REQUIRED="0"
UPDATE_RUN_ID="update-$(date +%s 2>/dev/null || echo 0)-$$"
UPDATE_QUIESCE_ACTIVE="0"
UPDATE_JFFS_RESERVE_KB="${MERV_UPDATE_JFFS_RESERVE_KB:-5120}"
case "$UPDATE_JFFS_RESERVE_KB" in
	''|*[!0-9]*|0) UPDATE_JFFS_RESERVE_KB="5120" ;;
esac

update_record_phase() {
	_update_phase="$1"
	[ -n "${UPDATE_RUN_ID:-}" ] || return 0
	if ! merv_update_journal_write \
		"$UPDATE_RUN_ID" "$_update_phase" "${GITHUB_REF:-${CHANNEL:-unknown}}" \
		"${PRE_BOOT_ENABLED:-0}" "${BACKUP_READY:-0}" \
		"${UPDATE_QUIESCE_ACTIVE:-0}" "${UPDATE_ACTIVATION_STARTED:-0}" \
		"${UPDATE_NODES_TOUCHED:-0}" "${2:-none}" \
		"${TMP_BASE:-none}" "${ARCHIVE:-none}" "${STAGE_DIR:-none}" \
		"${UPDATE_ORIGINAL_DIR:-none}" "${UPDATE_JFFS_STAGE:-none}" \
		"${UPDATE_JFFS_OLD:-none}" "${OLD_VERSION:-unknown}" "${NEW_VERSION:-unknown}"; then
		error -c cli,vlan "Update journal write failed at phase $_update_phase"
		return 1
	fi
	return 0
}

update_wait_for_runtime_idle() {
	_update_idle_max="${1:-${MERV_UPDATE_QUIESCE_WAIT_SEC:-180}}"
	_update_idle_elapsed=0
	case "$_update_idle_max" in ''|*[!0-9]*) return 1 ;; esac
	# This is a safety gate, not a best-effort status display.  If the
	# classifiers are unavailable, the updater cannot prove that runtime work
	# and DHCP/observation handoffs are idle, so it must stop before teardown.
	type merv_owner_lock_state >/dev/null 2>&1 || {
		error -c cli,vlan "Update cannot quiesce safely: runtime lock classifier is unavailable"
		return 1
	}
	type merv_observation_wait_idle >/dev/null 2>&1 || {
		error -c cli,vlan "Update cannot quiesce safely: observation idle classifier is unavailable"
		return 1
	}
	type merv_dhcp_hold_status >/dev/null 2>&1 || {
		error -c cli,vlan "Update cannot quiesce safely: DHCP handoff classifier is unavailable"
		return 1
	}
	while :; do
		_update_busy="0"
		for _update_lock in \
			"$LOCKDIR/mervlan_manager.lock" \
			"$LOCKDIR/vlan_event.lock" \
			"$LOCKDIR/execute_nodes.lock" \
			"$LOCKDIR/client_collect.lock"
		do
			[ -e "$_update_lock" ] || continue
			case "$(merv_owner_lock_state "$_update_lock")" in
				live) _update_busy="1" ;;
				dead|reused) : ;;
				unknown) error -c cli,vlan "Update cannot classify runtime lock $_update_lock"; return 1 ;;
				esac
		done
		# The service-event global action lock has a deliberately different
		# metadata schema from merv_owner_lock_state. Presence is therefore treated as
		# busy and allowed to drain, while malformed/stale state cannot be
		# mistaken for an idle runtime.
		if [ -e "$LOCKDIR/mervlan_action.lock" ] &&
		   ! merv_action_lock_parent_owned "$LOCKDIR/mervlan_action.lock"; then
			_update_busy="1"
		fi
		if ! merv_observation_wait_idle 0 >/dev/null 2>&1; then
			_update_busy="1"
		fi
		if [ -f "$LOCKDIR/merv_boot_shield.active" ]; then
			_update_busy="1"
		fi
		if [ "$_update_busy" = "0" ]; then
			_update_dhcp_status=$(merv_dhcp_hold_status 2>/dev/null)
			_update_dhcp_status_rc=$?
			[ "$_update_dhcp_status_rc" -eq 0 ] || _update_busy="1"
			printf '%s\n' "$_update_dhcp_status" | grep -q '^desired=hold$' && _update_busy="1"
		fi
		[ "$_update_busy" = "0" ] && return 0
		[ "$_update_idle_elapsed" -lt "$_update_idle_max" ] || {
			error -c cli,vlan "Update quiesce timed out after ${_update_idle_max}s while runtime protection was active"
			return 1
		}
		[ $((_update_idle_elapsed % 10)) -eq 0 ] &&
			info -c cli,vlan "Update waiting for active manager/guard work to finish (${_update_idle_elapsed}s/${_update_idle_max}s)"
		sleep 2
		_update_idle_elapsed=$((_update_idle_elapsed + 2))
	done
}

update_preflight_nodes_with_retry() {
	_update_node_max="${MERV_UPDATE_NODE_RETRY_MAX_SEC:-300}"
	_update_node_interval="${MERV_UPDATE_NODE_RETRY_INTERVAL_SEC:-15}"
	case "$_update_node_max" in ''|*[!0-9]*) _update_node_max=300 ;; esac
	case "$_update_node_interval" in ''|*[!0-9]*) _update_node_interval=15 ;; esac
	[ "$_update_node_interval" -gt 0 ] 2>/dev/null || _update_node_interval=1
	_update_node_elapsed=0
	_update_node_attempt=1
	while :; do
		if merv_ssh_preflight_configured_nodes; then
			info -c cli,vlan "Update node preflight passed on attempt $_update_node_attempt"
			return 0
		fi
		_update_node_reason="${MERV_SSH_LAST_REASON:-${MERV_SSH_TRUST_LAST_REASON:-preflight-failed}}"
		_update_node_detail="${MERV_SSH_LAST_DETAIL:-${MERV_SSH_TRUST_LAST_REASON:-complete node preflight failed}}"
		case "$_update_node_reason" in
			unreachable|timeout|refused|no-route)
				if [ "$_update_node_elapsed" -ge "$_update_node_max" ] 2>/dev/null; then
					error -c cli,vlan "Update node preflight exhausted its ${_update_node_max}s retry window: $_update_node_detail"
					return 1
				fi
				_update_node_sleep=$((_update_node_max - _update_node_elapsed))
				[ "$_update_node_interval" -lt "$_update_node_sleep" ] && _update_node_sleep="$_update_node_interval"
				info -c cli,vlan "Update node preflight transient failure ($_update_node_reason); retrying in ${_update_node_sleep}s (elapsed ${_update_node_elapsed}s/${_update_node_max}s)"
				sleep "$_update_node_sleep"
				_update_node_elapsed=$((_update_node_elapsed + _update_node_sleep))
				_update_node_attempt=$((_update_node_attempt + 1))
				;;
			*)
				error -c cli,vlan "Update node preflight stopped without retry: $_update_node_detail (reason=$_update_node_reason)"
				return 1
				;;
		esac
	done
}

restore_update_original_tree() {
	case "$MERV_BASE" in /|/jffs|/jffs/addons|/tmp|'') return 1 ;; esac
	if [ -n "${UPDATE_JFFS_OLD:-}" ] && [ -d "$UPDATE_JFFS_OLD" ]; then
		if [ -d "$MERV_BASE" ]; then
			[ -n "${UPDATE_JFFS_STAGE:-}" ] || return 1
			if ! rm -rf "$UPDATE_JFFS_STAGE" 2>/dev/null; then return 1; fi
			mv "$MERV_BASE" "$UPDATE_JFFS_STAGE" 2>/dev/null || return 1
		fi
		if ! mv "$UPDATE_JFFS_OLD" "$MERV_BASE" 2>/dev/null; then
			if [ -d "$UPDATE_JFFS_STAGE" ] && ! mv "$UPDATE_JFFS_STAGE" "$MERV_BASE" 2>/dev/null; then
				UPDATE_PRESERVE_JFFS="1"
			fi
			return 1
		fi
		if ! rm -rf "$UPDATE_JFFS_STAGE" 2>/dev/null; then
			UPDATE_PRESERVE_JFFS="1"
			return 1
		fi
	elif [ -n "${UPDATE_ORIGINAL_DIR:-}" ] && [ -d "$UPDATE_ORIGINAL_DIR" ]; then
		if [ -d "$MERV_BASE" ] && ! rm -rf "$MERV_BASE" 2>/dev/null; then return 1; fi
		cp -pR "$UPDATE_ORIGINAL_DIR" "$MERV_BASE" 2>/dev/null || return 1
	else
		return 1
	fi
	[ -f "$MERV_BASE/settings/settings.json" ] || return 1
	if [ -x "$MERV_BASE/uninstall.sh" ] && [ -x "$MERV_BASE/install.sh" ]; then
		run_update_step "rollback public uninstall" env MERV_UPDATE_OWNER=1 sh "$MERV_BASE/uninstall.sh" reinstall || return 1
		run_update_step "rollback public install" env MERV_UPDATE_OWNER=1 sh "$MERV_BASE/install.sh" reinstall || return 1
	fi
	if [ -x "$MERV_BASE/functions/mervlan_boot.sh" ]; then
		run_update_step "rollback setupenable" env MERV_UPDATE_OWNER=1 MERV_SKIP_NODE_SYNC=1 sh "$MERV_BASE/functions/mervlan_boot.sh" setupenable || return 1
		if [ "${PRE_BOOT_ENABLED:-0}" = "1" ]; then
			run_update_step "rollback enable" env MERV_UPDATE_OWNER=1 MERV_SKIP_NODE_SYNC=1 sh "$MERV_BASE/functions/mervlan_boot.sh" enable || return 1
		else
			run_update_step "rollback disable" env MERV_UPDATE_OWNER=1 MERV_SKIP_NODE_SYNC=1 sh "$MERV_BASE/functions/mervlan_boot.sh" disable || return 1
		fi
	fi
	UPDATE_ACTIVATION_STARTED="0"
	UPDATE_RUNTIME_RESTORED="1"
	return 0
}

# ========================================================================== #
# CENTRAL FAILURE / ROLLBACK HANDLER                                         #
# ========================================================================== #
update_mark_recovery_required() {
	UPDATE_RECOVERY_REQUIRED="1"
	UPDATE_PRESERVE_TMP="1"
	UPDATE_PRESERVE_JFFS="1"
}

fail_update() {
	block="$1"
	shift
	detail="$*"

	restored_tree="0"
	restore_attempted="0"
	update_record_phase "failed-$block" "${detail:-none}" || UPDATE_PRESERVE_JFFS="1"

	[ -n "$detail" ] && error -c cli,vlan "$detail"

	if [ "$DESTRUCTIVE_TOUCHED" = "1" ] && [ "$BACKUP_READY" = "1" ] && \
	   { { [ -n "${UPDATE_JFFS_OLD:-}" ] && [ -d "$UPDATE_JFFS_OLD" ]; } || \
	     { [ -n "${UPDATE_ORIGINAL_DIR:-}" ] && [ -d "$UPDATE_ORIGINAL_DIR" ]; }; }; then
	restore_attempted="1"
		info -c cli,vlan "Restoring the pre-update MerVLAN installation"
		if restore_update_original_tree; then
			restored_tree="1"
		else
			update_mark_recovery_required
		fi
	fi

	# Restore the main MAC DB if it was preserved before teardown.
	# Do this before re-applying hooks so the DB exists when nodeenable runs.
	if [ "${MAC_DB_BACKUP_PRESENT:-0}" = "1" ] && type restore_main_mac_db_after_update >/dev/null 2>&1; then
		if ! restore_main_mac_db_after_update; then
			UPDATE_PRESERVE_TMP="1"
			error -c cli,vlan "Rollback could not restore the preserved main MAC Shield database"
		fi
	fi

	# restore_update_original_tree performs the public/runtime reconciliation.
	# Do not run install/uninstall a second time here: duplicate reprovisioning
	# was both unnecessary and disruptive on embedded routers.

	# A successful tree rollback already reconciled the main router exactly once.
	# Only repair the pre-swap tree here when teardown happened without a swap.
	if [ "$restored_tree" != "1" ] && [ "$TEARDOWN_DONE" = "1" ] && \
	   [ -n "${BOOT_SCRIPT:-}" ] && [ -x "$BOOT_SCRIPT" ]; then
		_update_recovery_hooks_ok=1
		info -c cli,vlan "Re-applying MerVLAN hooks to original state"
		if ! run_update_step "rollback main setupenable" env MERV_UPDATE_OWNER=1 MERV_SKIP_NODE_SYNC=1 sh "$BOOT_SCRIPT" setupenable; then
			UPDATE_PRESERVE_TMP="1"
			_update_recovery_hooks_ok=0
			error -c cli,vlan "Rollback could not reapply the original main hooks"
		fi
		if [ "$PRE_BOOT_ENABLED" = "1" ]; then
			if ! run_update_step "rollback main enable" env MERV_UPDATE_OWNER=1 MERV_SKIP_NODE_SYNC=1 sh "$BOOT_SCRIPT" enable; then
				UPDATE_PRESERVE_TMP="1"
				_update_recovery_hooks_ok=0
				error -c cli,vlan "Rollback could not restore the original enabled boot state"
			fi
		else
			if ! run_update_step "rollback main disable" env MERV_UPDATE_OWNER=1 MERV_SKIP_NODE_SYNC=1 sh "$BOOT_SCRIPT" disable; then
				UPDATE_PRESERVE_TMP="1"
				_update_recovery_hooks_ok=0
				error -c cli,vlan "Rollback could not restore the original disabled boot state"
			fi
		fi
		[ "$_update_recovery_hooks_ok" = "1" ] && UPDATE_RUNTIME_RESTORED="1"
	fi

	# If any node activation was attempted, put configured nodes back on the
	# restored source tree as well. The sync implementation stages and verifies
	# each node independently; an unreachable node keeps its last working tree.
	if [ "$restored_tree" = "1" ] && [ "$UPDATE_NODES_TOUCHED" = "1" ] && \
	   ssh_keys_effectively_installed && has_configured_nodes && [ -x "$MERV_BASE/functions/sync_nodes.sh" ]; then
		info -c cli,vlan "Rolling configured nodes back to the restored main-router version"
		if ! run_update_step "rollback node synchronization" env MERV_UPDATE_OWNER=1 MERV_MAINTENANCE_SYNC=1 sh "$MERV_BASE/functions/sync_nodes.sh"; then
			UPDATE_PRESERVE_TMP="1"
			error -c cli,vlan "Rollback could not synchronize the restored tree to every configured node"
		fi
		if [ "$PRE_BOOT_ENABLED" = "1" ]; then
			if ! run_update_step "rollback node enable" env MERV_UPDATE_OWNER=1 sh "$MERV_BASE/functions/mervlan_boot.sh" enable; then
				UPDATE_PRESERVE_TMP="1"
				error -c cli,vlan "Rollback could not restore enabled boot state on every configured node"
			fi
		else
			if ! run_update_step "rollback node disable" env MERV_UPDATE_OWNER=1 sh "$MERV_BASE/functions/mervlan_boot.sh" disable; then
				UPDATE_PRESERVE_TMP="1"
				error -c cli,vlan "Rollback could not restore disabled boot state on every configured node"
			fi
		fi
	fi

	# Now safe to remove the temporary user-data backup
	if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] && ! rm -rf "$BACKUP_DIR" 2>/dev/null; then
		UPDATE_PRESERVE_TMP="1"
		error -c cli,vlan "Rollback could not remove the temporary user-data backup at $BACKUP_DIR"
	fi
	if [ "$UPDATE_RECOVERY_REQUIRED" != "1" ] && \
	   { [ "$restored_tree" = "1" ] || [ "$TEARDOWN_DONE" != "1" ] || [ "$UPDATE_RUNTIME_RESTORED" = "1" ]; }; then
		if merv_update_quiesce_clear; then
			UPDATE_QUIESCE_ACTIVE="0"
			# A recovered failure must not depend on another JFFS write. When the
			# original failure was low space, rewriting a recovered phase can fail
			# and leave the previous active journal blocking heal forever. The
			# completed rollback is the durable recovery fact; remove the journal
			# directly and retain it only if that removal itself fails.
			if merv_update_journal_clear; then
				info -c cli,vlan "Update recovery completed; lifecycle journal cleared"
			else
				UPDATE_PRESERVE_JFFS="1"
				error -c cli,vlan "Update recovery completed but lifecycle journal cleanup failed"
			fi
		else
			UPDATE_PRESERVE_JFFS="1"
			error -c cli,vlan "Update failure left the maintenance-quiesce marker in place"
		fi
	fi

	if [ "$restored_tree" = "1" ]; then
		error -c cli,vlan "Update failed in stage: $block (backup restored)"
	elif [ "$restore_attempted" = "1" ]; then
		UPDATE_PRESERVE_TMP="1"
		error -c cli,vlan "Update failed in stage: $block (backup restore failed)"
	else
		error -c cli,vlan "Update failed in stage: $block (no backup restore needed)"
	fi
	type log_maintain_all >/dev/null 2>&1 && log_maintain_all
	exit 1
}
# ========================================================================== #
# PATHS & CONSTANTS                                                          #
# ========================================================================== #

# Central temporary root for MerVLAN operations (RAM)
readonly TMP_DIR="${MERVLAN_TMP_ROOT_OVERRIDE:-/tmp/mervlan_tmp}"
readonly TMP_BASE="$TMP_DIR/updates.$$"

readonly ARCHIVE="$TMP_BASE/mervlan.tar.gz"
readonly RAW_ARCHIVE="$TMP_BASE/mervlan.tar"
readonly STAGE_DIR="$TMP_BASE/stage"
readonly BACKUP_DIR="$TMP_BASE/backup"
readonly UPDATE_ORIGINAL_DIR="$TMP_BASE/original"
readonly UPDATE_BACKUP_SOURCE_DIR="$TMP_BASE/preupdate-source"
readonly SYNC_SCRIPT="$FUNCDIR/sync_nodes.sh"

# Staging directory for node MAC shield db files during node updates (RAM)
readonly NODE_DB_STAGE="$TMP_DIR/node_db_stage"

# Persistent backup root on flash (for rollback archives)
# Example (default): /jffs/addons/mervlan_backups
MERVLAN_BACKUP_DIR="${MERV_BASE%/*}/mervlan_backups"
UPDATE_JFFS_STAGE="$MERVLAN_BACKUP_DIR/.mervlan.new.$$"
UPDATE_JFFS_OLD="$MERVLAN_BACKUP_DIR/.mervlan.old.$$"
readonly UPDATE_UNDO_ROOT="${MERVLAN_UNDO_DIR_OVERRIDE:-$TMP_DIR/undo}"
readonly UPDATE_UNDO_MARKER="$UPDATE_UNDO_ROOT/update.meta"

update_remove_jffs_stage() {
	_update_stage_path="$1"
	[ -n "$_update_stage_path" ] || return 0
	case "$_update_stage_path" in
		"$MERVLAN_BACKUP_DIR"/.mervlan.new.*|"$MERVLAN_BACKUP_DIR"/.mervlan.old.*)
			[ -e "$_update_stage_path" ] || return 0
			rm -rf "$_update_stage_path" 2>/dev/null
			;;
		*) return 1 ;;
	esac
}

update_cleanup_files() {
	_update_cleanup_file_failed=0
	for _update_cleanup_file in "$@"; do
		[ -n "$_update_cleanup_file" ] || continue
		[ -e "$_update_cleanup_file" ] || continue
		if ! rm -f "$_update_cleanup_file" 2>/dev/null; then
			warn -c cli,vlan "Could not remove update temporary file $_update_cleanup_file"
			_update_cleanup_file_failed=1
		fi
	done
	[ "$_update_cleanup_file_failed" -eq 0 ]
}

update_cleanup_tree() {
	_update_cleanup_tree_path="$1"
	[ -n "$_update_cleanup_tree_path" ] || return 0
	[ -e "$_update_cleanup_tree_path" ] || return 0
	if ! rm -rf "$_update_cleanup_tree_path" 2>/dev/null; then
		warn -c cli,vlan "Could not remove update temporary tree $_update_cleanup_tree_path"
		return 1
	fi
	return 0
}

# Keep the downloaded source snapshot separate from the addon payload.  Git
# branches contain developer documentation, test fixtures, evidence, and
# historical archives that must never become part of the JFFS activation tree.
# Development refs may carry only the two executable router-side tools used by
# the explicit development Sync Nodes workflow.
update_filter_source_tree() {
	_update_payload_root="$1"
	_update_payload_keep="$TMP_BASE/.dev-tools-keep.$$"
	[ -d "$_update_payload_root" ] || return 1
	UPDATE_PAYLOAD_DEV_TOOLS="0"
	if [ "${UPDATE_SOURCE:-remote}" = "remote" ] &&
	   [ "${GITHUB_REF:-}" != "refs/heads/main" ] &&
	   [ "${GITHUB_REF#refs/tags/}" = "${GITHUB_REF}" ]; then
		mkdir -p "$_update_payload_keep/dev-tools/tests/router" \
			"$_update_payload_keep/dev-tools/safety" 2>/dev/null || return 1
		if [ -f "$_update_payload_root/dev-tools/tests/router/mervlan_selftest.sh" ]; then
			cp -p "$_update_payload_root/dev-tools/tests/router/mervlan_selftest.sh" \
				"$_update_payload_keep/dev-tools/tests/router/mervlan_selftest.sh" 2>/dev/null || return 1
			UPDATE_PAYLOAD_DEV_TOOLS="1"
		fi
		if [ -f "$_update_payload_root/dev-tools/safety/mervlan_live_test_guard.sh" ]; then
			cp -p "$_update_payload_root/dev-tools/safety/mervlan_live_test_guard.sh" \
				"$_update_payload_keep/dev-tools/safety/mervlan_live_test_guard.sh" 2>/dev/null || return 1
			UPDATE_PAYLOAD_DEV_TOOLS="1"
		fi
	fi
	rm -rf "$_update_payload_root/dev-tools" \
		"$_update_payload_root/.agent" "$_update_payload_root/.agents" \
		"$_update_payload_root/.github/copilot-instructions.md" \
		"$_update_payload_root/functions/sync_nodes.sh.bak" \
		"$_update_payload_root/functions/wireless_backhaul.sh" \
		"$_update_payload_root/roadmap.txt" \
		"$_update_payload_root/puppeteer-config.json" 2>/dev/null || return 1
	if [ "$UPDATE_PAYLOAD_DEV_TOOLS" = "1" ]; then
		cp -pR "$_update_payload_keep/dev-tools" "$_update_payload_root/dev-tools" 2>/dev/null || return 1
	fi
	rm -rf "$_update_payload_keep" 2>/dev/null || return 1
	return 0
}

update_tree_valid() {
	_update_tree="$1"
	[ -d "$_update_tree" ] || return 1
	for _update_required in install.sh uninstall.sh changelog.txt mervlan.asp \
		functions/update_mervlan.sh functions/mervlan_boot.sh \
		functions/mervlan_wan.sh \
		settings/settings.json www/index.html
	do
		[ -f "$_update_tree/$_update_required" ] || return 1
	done
	[ -x "$_update_tree/functions/mervlan_wan.sh" ] || return 1
	return 0
}

# CORE STAGE VALIDATOR BEGIN
# Core payload validation is deliberately shared by the normal activation path
# and local-archive regression harnesses. Optional files remain informational.
update_stage_core_valid() {
	_update_stage_root="$1"
	_update_stage_missing=0
	[ -d "$_update_stage_root" ] || return 1
	for _update_stage_required in $CORE_STAGE_FILES; do
		if [ ! -f "$_update_stage_root/$_update_stage_required" ]; then
			warn -c cli,vlan "Missing core file in stage: $_update_stage_required"
			_update_stage_missing=1
		fi
	done
	for _update_stage_dir in $CORE_STAGE_DIRS; do
		if [ ! -d "$_update_stage_root/$_update_stage_dir" ]; then
			warn -c cli,vlan "Missing core directory in stage: $_update_stage_dir/"
			_update_stage_missing=1
		fi
	done
	[ "$_update_stage_missing" -eq 0 ]
}
# CORE STAGE VALIDATOR END

update_reconcile_stale_stages() {
	if merv_update_journal_requires_safe_boot; then
		warn -c cli,vlan "An incomplete or malformed Update recovery record protects staged trees; recovery is required before another Update"
		return 1
	fi
	if ! update_tree_valid "$MERV_BASE"; then
		warn -c cli,vlan "Active installation is incomplete; preserving all .mervlan.new/.mervlan.old recovery trees"
		return 1
	fi
	_update_stale_failed=0
	for _update_stale in "$MERVLAN_BACKUP_DIR"/.mervlan.new.*; do
		[ -d "$_update_stale" ] || continue
		if ! update_remove_jffs_stage "$_update_stale"; then
			warn -c cli,vlan "Could not remove stale update stage $_update_stale"
			_update_stale_failed=1
		fi
	done
	for _update_stale in "$MERVLAN_BACKUP_DIR"/.mervlan.old.*; do
		[ -d "$_update_stale" ] || continue
		if ! update_remove_jffs_stage "$_update_stale"; then
			warn -c cli,vlan "Could not remove stale rollback tree $_update_stale"
			_update_stale_failed=1
		fi
	done
	[ "$_update_stale_failed" -eq 0 ]
}

update_activation_started() {
	[ "$UPDATE_ACTIVATION_STARTED" = "1" ] && return 0
	case "$UPDATE_JFFS_OLD" in
		"$MERVLAN_BACKUP_DIR"/.mervlan.old.*) [ -d "$UPDATE_JFFS_OLD" ] || return 1 ;;
		*) return 1 ;;
	esac
	UPDATE_ACTIVATION_STARTED="1"
	DESTRUCTIVE_TOUCHED="1"
	return 0
}

update_path_size_kb() {
	_update_size=$(du -sk "$1" 2>/dev/null | awk 'NR == 1 { print $1 }')
	case "$_update_size" in ''|*[!0-9]*) _update_size=0 ;; esac
	printf '%s' "$_update_size"
}

update_fs_stats_kb() {
	_update_path="$1"
	while [ ! -e "$_update_path" ] && [ "$_update_path" != "/" ]; do
		_update_path=${_update_path%/*}
		[ -n "$_update_path" ] || _update_path=/
	done
	df -Pk "$_update_path" 2>/dev/null | awk 'NR == 2 { print $2 "|" $4 }'
}

update_require_space_kb() {
	_update_path="$1"
	_update_required="$2"
	_update_label="$3"
	_update_reserve="${4:-}"
	_update_stats=$(update_fs_stats_kb "$_update_path")
	_update_total=${_update_stats%%|*}
	_update_available=${_update_stats#*|}
	case "$_update_total" in ''|*[!0-9]*) fail_update space "Could not determine total space for $_update_label" ;; esac
	case "$_update_available" in ''|*[!0-9]*) fail_update space "Could not determine available space for $_update_label" ;; esac
	if [ -z "$_update_reserve" ]; then
		case "$_update_path" in
			/jffs|/jffs/*) _update_reserve="$UPDATE_JFFS_RESERVE_KB" ;;
			*)
				_update_reserve=$((_update_total / 20))
				[ "$_update_reserve" -ge 2048 ] || _update_reserve=2048
				;;
		esac
	fi
	_update_needed=$((_update_required + _update_reserve))
	[ "$_update_available" -ge "$_update_needed" ] || \
		fail_update space "Insufficient $_update_label space: need ${_update_needed} KB including reserve ${_update_reserve} KB, available ${_update_available} KB"
}

update_check_jffs_health() {
	_update_jffs_path="${MERV_BASE%/*}"
	[ -d "$_update_jffs_path" ] || return 1
	_update_jffs_stats=$(update_fs_stats_kb "$_update_jffs_path")
	_update_jffs_available=${_update_jffs_stats#*|}
	case "$_update_jffs_available" in ''|*[!0-9]*) return 1 ;; esac
	if [ "${MERV_TEST_MODE:-0}" != "1" ] && [ -r /proc/mounts ]; then
		_update_jffs_fs=$(awk '$2 == "/jffs" { print $3; exit }' /proc/mounts 2>/dev/null)
		case "$_update_jffs_fs" in
			jffs2|ubifs|overlay) ;;
			'') warn -c cli,vlan "JFFS mount entry was not visible; continuing with path and write checks" ;;
			*) warn -c cli,vlan "JFFS mount reports filesystem=$_update_jffs_fs; continuing with path and write checks" ;;
		esac
	fi
	mkdir -p "$MERV_STATE_ROOT" 2>/dev/null || return 1
	_update_jffs_probe="$MERV_STATE_ROOT/.update-jffs-health.$$"
	printf 'health=%s\n' "$(date +%s 2>/dev/null || printf '0')" > "$_update_jffs_probe" 2>/dev/null || return 1
	grep -q '^health=' "$_update_jffs_probe" 2>/dev/null || { rm -f "$_update_jffs_probe" 2>/dev/null || :; return 1; }
	rm -f "$_update_jffs_probe" 2>/dev/null || return 1
	if type dmesg >/dev/null 2>&1; then
	_update_jffs_warning=$(dmesg 2>/dev/null | grep -i 'jffs2' | grep -i 'crc\|error\|bad' | tail -n 3 | tr '\n' ';')
		[ -z "$_update_jffs_warning" ] || warn -c cli,vlan "Historical/current JFFS kernel warnings detected; inspect before Update: $_update_jffs_warning"
	fi
	return 0
}

update_checksum_value() {
	type md5sum >/dev/null 2>&1 || return 1
	md5sum "$1" 2>/dev/null | awk 'NR == 1 { print $1 }'
}

update_prepare_archive_metadata() {
	_update_meta_archive="$1"
	_update_meta_id="$2"
	_update_meta_output="$3"
	case "$_update_meta_id" in mervlan.backup.*.tar.gz) ;; *) return 1 ;; esac
	_update_meta_checksum=$(update_checksum_value "$_update_meta_archive") || return 1
	case "$_update_meta_checksum" in ''|*[!0123456789abcdefABCDEF]*) return 1 ;; esac
	[ "${#_update_meta_checksum}" -eq 32 ] || return 1
	{
		printf 'format=1\n'
		printf 'archive=%s\n' "$_update_meta_id"
		printf 'algorithm=md5\n'
		printf 'checksum=%s\n' "$_update_meta_checksum"
		printf 'created=%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
	} > "$_update_meta_output" 2>/dev/null || return 1
	chmod 600 "$_update_meta_output" 2>/dev/null || return 1
}

create_durable_preupdate_backup() {
	_update_backup_source="${1:-$MERV_BASE}"
	case "$_update_backup_source" in
		"$MERV_BASE"|"$TMP_BASE"/*) ;;
		*) return 1 ;;
	esac
	[ -d "$_update_backup_source" ] || return 1
	timestamp="$(date +%Y%m%d-%H%M%S 2>/dev/null | tr -d '\n')"
	[ -n "$timestamp" ] || return 1
	CURRENT_BACKUP_NAME="mervlan.backup.$timestamp"
	UPDATE_BACKUP_ID="$CURRENT_BACKUP_NAME.tar.gz"
	UPDATE_BACKUP_FINAL="$MERVLAN_BACKUP_DIR/$UPDATE_BACKUP_ID"
	UPDATE_BACKUP_PARTIAL="$MERVLAN_BACKUP_DIR/.$UPDATE_BACKUP_ID.partial.$$"
	UPDATE_BACKUP_META_FINAL="$UPDATE_BACKUP_FINAL.meta"
	UPDATE_BACKUP_META_PARTIAL="$UPDATE_BACKUP_META_FINAL.partial.$$"
	mkdir -p "$MERVLAN_BACKUP_DIR" 2>/dev/null || return 1
	chmod 700 "$MERVLAN_BACKUP_DIR" 2>/dev/null || return 1
	update_cleanup_files "$UPDATE_BACKUP_PARTIAL" "$UPDATE_BACKUP_META_PARTIAL" || return 1
	[ ! -e "$UPDATE_BACKUP_FINAL" ] || return 1
	info -c cli,vlan "Creating durable pre-update backup $UPDATE_BACKUP_ID"
	if ! tar -czf "$UPDATE_BACKUP_PARTIAL" -C "${_update_backup_source%/*}" "${_update_backup_source##*/}" 2>/dev/null; then
		update_cleanup_files "$UPDATE_BACKUP_PARTIAL" || UPDATE_PRESERVE_TMP="1"
		return 1
	fi
	if ! tar -tzf "$UPDATE_BACKUP_PARTIAL" >/dev/null 2>&1; then
		update_cleanup_files "$UPDATE_BACKUP_PARTIAL" || UPDATE_PRESERVE_TMP="1"
		return 1
	fi
	if ! update_prepare_archive_metadata "$UPDATE_BACKUP_PARTIAL" "$UPDATE_BACKUP_ID" "$UPDATE_BACKUP_META_PARTIAL"; then
		update_cleanup_files "$UPDATE_BACKUP_PARTIAL" "$UPDATE_BACKUP_META_PARTIAL" || UPDATE_PRESERVE_TMP="1"
		return 1
	fi
	if ! mv -f "$UPDATE_BACKUP_META_PARTIAL" "$UPDATE_BACKUP_META_FINAL" 2>/dev/null; then
		update_cleanup_files "$UPDATE_BACKUP_PARTIAL" "$UPDATE_BACKUP_META_PARTIAL" || UPDATE_PRESERVE_TMP="1"
		return 1
	fi
	if ! mv -f "$UPDATE_BACKUP_PARTIAL" "$UPDATE_BACKUP_FINAL" 2>/dev/null; then
		update_cleanup_files "$UPDATE_BACKUP_PARTIAL" "$UPDATE_BACKUP_META_FINAL" || UPDATE_PRESERVE_TMP="1"
		return 1
	fi
	if [ -x "$MERV_BASE/functions/mervlan_recover.sh" ]; then
		MERVLAN_RECOVERY_BACKUP_ROOT="$MERVLAN_BACKUP_DIR" \
		MERVLAN_RECOVERY_TMP_ROOT="$TMP_BASE/recovery-check" \
			sh "$MERV_BASE/functions/mervlan_recover.sh" check "$UPDATE_BACKUP_ID" >/dev/null 2>&1 || {
				update_cleanup_files "$UPDATE_BACKUP_FINAL" "$UPDATE_BACKUP_META_FINAL" || UPDATE_PRESERVE_TMP="1"
				return 1
			}
	else
		update_cleanup_files "$UPDATE_BACKUP_FINAL" "$UPDATE_BACKUP_META_FINAL" || UPDATE_PRESERVE_TMP="1"
		return 1
	fi
	UPDATE_BACKUP_ARCHIVE_OK=1
	return 0
}

write_update_undo_marker() {
	_update_archive_id="$1"
	_update_from="$2"
	_update_to="$3"
	case "$_update_archive_id" in mervlan.backup.*.tar.gz) ;; *) return 1 ;; esac
	[ -f "$MERVLAN_BACKUP_DIR/$_update_archive_id" ] || return 1
	mkdir -p "$UPDATE_UNDO_ROOT" 2>/dev/null || return 1
	chmod 700 "$UPDATE_UNDO_ROOT" 2>/dev/null || return 1
	_update_marker_tmp="$UPDATE_UNDO_MARKER.$$"
	printf '%s\n%s\n%s\n%s\n' \
		"$_update_archive_id" "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)" \
		"${_update_from:-unknown}" "${_update_to:-unknown}" > "$_update_marker_tmp" 2>/dev/null || return 1
	if ! chmod 600 "$_update_marker_tmp" 2>/dev/null; then
		update_cleanup_files "$_update_marker_tmp" || UPDATE_PRESERVE_TMP="1"
		return 1
	fi
	if ! mv -f "$_update_marker_tmp" "$UPDATE_UNDO_MARKER" 2>/dev/null; then
		update_cleanup_files "$_update_marker_tmp" || UPDATE_PRESERVE_TMP="1"
		return 1
	fi
}

BACKUP_LIST="settings/settings.json
tmp/mac_shield.db
tmp/mac_shield_override.db
tmp/client_name_override.db"

SSH_KEY_RELATIVE=""
# Preserve the configured private key so we can restore it after the swap
case "$SSH_KEY" in
	"$MERV_BASE"/*) SSH_KEY_RELATIVE="${SSH_KEY#$MERV_BASE/}" ;;
esac

SSH_PUBKEY_RELATIVE=""
case "$SSH_PUBKEY" in
	"$MERV_BASE"/*) SSH_PUBKEY_RELATIVE="${SSH_PUBKEY#$MERV_BASE/}" ;;
esac

if [ -n "$SSH_KEY_RELATIVE" ]; then
	BACKUP_LIST="$BACKUP_LIST
$SSH_KEY_RELATIVE"
fi

if [ -n "$SSH_PUBKEY_RELATIVE" ]; then
	BACKUP_LIST="$BACKUP_LIST
$SSH_PUBKEY_RELATIVE"
fi

CORE_STAGE_FILES="install.sh
uninstall.sh
changelog.txt
mervlan.asp
functions/mervlan_boot.sh
functions/mervlan_boot_wrap.sh
functions/mervlan_manager.sh
functions/hw_probe.sh
functions/mervlan_trunk.sh
functions/mervlan_wan.sh
functions/save_settings.sh
functions/settings_reconcile.sh
functions/update_mervlan.sh
settings/settings.json
settings/var_settings.sh
settings/log_settings.sh
settings/lib_json.sh
settings/lib_owner_lock.sh
settings/lib_ssh.sh
settings/lib_update_state.sh
settings/lib_maintenance_recovery.sh
settings/lib_node_reconcile.sh
settings/lib_settings_reconcile.sh
templates/mervlan_templates.sh
www/index.html
www/vlan_form_style.css
www/vlan_index_style.css"

OPTIONAL_STAGE_FILES="README.md
settings/lib_action_ack.sh
functions/heal_event.sh
functions/service-event-handler.sh
functions/mervlan_backup.sh
functions/sync_nodes.sh
functions/collect_clients.sh
functions/post_apply_worker.sh
functions/collect_local_clients.sh
functions/dropbear_sshkey_gen.sh
functions/execute_nodes.sh
functions/mac_refresh.sh
functions/mac_client_meta.sh
settings/lib_br0_guard.sh
settings/lib_debug.sh
settings/lib_ssid_filter.sh
settings/lib_stp.sh
settings/lib_mervqt.sh
settings/lib_radio.sh
settings/mac_shield_snapshot.sh
www/help.html
www/view_logs.html
www/vendor/marked.umd.js
www/vendor/github-markdown-dark.css
www/vendor/THIRD_PARTY_LICENSES.md
docs/HELP.md
docs/diagrams/topology-1_local.svg
docs/diagrams/topology-2_aimesh.svg
docs/diagrams/topology-3_standalone-ap.svg
docs/diagrams/topology-4_node-to-main.svg
docs/images/mervlan_help.svg
docs/images/mervlan_manager.svg"

# required directories in a valid package
CORE_STAGE_DIRS="functions settings templates www"

# optional directories are allowed to differ between branches
OPTIONAL_STAGE_DIRS="www/vendor docs docs/diagrams docs/images"

# ========================================================================== #
# SETTINGS.JSON MERGE HELPERS                                                #
# ========================================================================== #

# merge_settings_json — Merge old settings into new defaults (skip Hardware)
# Args: $1=old_settings_file, $2=new_settings_file
# Behavior: Preserves user values from old file, keeps new keys from updated
#           defaults, and skips all keys under Hardware.
merge_settings_json() {
	old_file="$1"
	new_file="$2"
	tmp_kv="$TMP_BASE/merge_kv.$$"

	[ -f "$old_file" ] || return 0
	[ -f "$new_file" ] || return 1

	: > "$tmp_kv"

	if ! awk -v out="$tmp_kv" '
		function net_braces(s,   t, o, c) {
			t = s
			o = gsub(/\{/, "", t)
			c = gsub(/\}/, "", t)
			return o - c
		}
		function get_name(line,   t) {
			t = line
			sub(/^[[:space:]]*"/, "", t)
			sub(/".*$/, "", t)
			return t
		}
		BEGIN {
			depth=-1
			sec=""; subsec=""
			sec_depth=0; sub_depth=0
			in_hw=0; hw_depth=0
		}
		{
			line=$0

			# Enter top-level section only when at depth 0
			if (depth==0 && line ~ /^[[:space:]]*"[^"]+"[[:space:]]*:[[:space:]]*\{/) {
				sec = get_name(line)
				sec_depth = depth + net_braces(line)
				if (sec == "Hardware") {
					in_hw = 1
					hw_depth = sec_depth
				} else {
					in_hw = 0
				}
				subsec = ""
				sub_depth = 0
			}

			# Enter subsection only when inside a section at depth 1 (not Hardware)
			if (!in_hw && sec != "" && depth==1 &&
			    line ~ /^[[:space:]]*"[^"]+"[[:space:]]*:[[:space:]]*\{/) {
				subsec = get_name(line)
				sub_depth = depth + net_braces(line)
			}

			# Capture quoted scalar values only (no arrays/objects)
			if (!in_hw && sec != "" &&
			    line ~ /^[[:space:]]*"[^"]+"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,?[[:space:]]*$/) {
				k = get_name(line)
				v = line
				sub(/^[^:]*:[[:space:]]*"/, "", v)
				sub(/".*$/, "", v)
				if (k !~ /^_/ && k !~ /^BACKUP_[123]$/) {
					if (depth==1) {
						printf "%s|%s|%s|%s\n", sec, "", k, v >> out
					} else if (subsec != "") {
						printf "%s|%s|%s|%s\n", sec, subsec, k, v >> out
					}
				}
			}

			# Update depth AFTER processing line
			depth += net_braces(line)

			# Exit Hardware
			if (in_hw && depth < hw_depth) {
				in_hw = 0
				sec = ""
				subsec = ""
			}

			# Exit subsection
			if (subsec != "" && depth < sub_depth) {
				subsec = ""
			}

			# Exit section
			if (sec != "" && depth < sec_depth) {
				sec = ""
				subsec = ""
			}
		}
	' "$old_file"; then
		return 1
	fi

	if [ -s "$tmp_kv" ]; then
		cnt="$(wc -l < "$tmp_kv" 2>/dev/null | tr -d '[:space:]')"
		[ -n "$cnt" ] || cnt="?"
		info -c cli,vlan "settings.json merge: extracted $cnt scalar values"
	else
		warn -c cli,vlan "settings.json merge: extracted 0 values (old file format mismatch?)"
		update_cleanup_files "$tmp_kv" || UPDATE_PRESERVE_TMP="1"
		return 0
	fi

	while IFS='|' read -r section subsection key value || [ -n "$section" ]; do
		[ -n "$section" ] || continue
		[ -n "$key" ] || continue
		if [ -n "$subsection" ]; then
			if ! json_set_section2_value "$section" "$subsection" "$key" "$value" "$new_file"; then
				update_cleanup_files "$tmp_kv" || UPDATE_PRESERVE_TMP="1"
				return 1
			fi
		else
			if ! json_set_section_value "$section" "$key" "$value" "$new_file"; then
				update_cleanup_files "$tmp_kv" || UPDATE_PRESERVE_TMP="1"
				return 1
			fi
		fi
	done < "$tmp_kv"

	update_cleanup_files "$tmp_kv" || UPDATE_PRESERVE_TMP="1"
}

# ========================================================================== #
# BACKUP METADATA → settings.json                                            #
# ========================================================================== #

# ========================================================================== #
# BACKUP METADATA → settings.json                                            #
# ========================================================================== #

update_backup_metadata() {
    # Always reset all three slots so the JSON shape is stable
    _update_metadata_failed=0
    if ! json_set_array "BACKUP_1" "none none none"; then _update_metadata_failed=1; fi
    if ! json_set_array "BACKUP_2" "none none none"; then _update_metadata_failed=1; fi
    if ! json_set_array "BACKUP_3" "none none none"; then _update_metadata_failed=1; fi

    # No backup directory or no archives → nothing to record
    [ -d "$MERVLAN_BACKUP_DIR" ] || { [ "$_update_metadata_failed" -eq 0 ]; return $?; }
    set -- "$MERVLAN_BACKUP_DIR"/mervlan.backup.*.tar.gz
    [ -e "$1" ] || { [ "$_update_metadata_failed" -eq 0 ]; return $?; }

    BACKUPS_LIST="$(ls "$MERVLAN_BACKUP_DIR"/mervlan.backup.*.tar.gz 2>/dev/null | sort -r)"

    # Temporary working directory for extracting changelog.txt only
    META_TMP="$TMP_DIR/backup_meta.$$"
    if ! mkdir -p "$META_TMP" 2>/dev/null; then
        warn -c cli,vlan "Could not prepare backup metadata extraction workspace"
        return 1
    fi

    idx=0
    for b in $BACKUPS_LIST; do
        idx=$((idx + 1))
        [ "$idx" -gt 3 ] && break

        base="$(basename "$b" .tar.gz)"    # mervlan.backup.YYYYMMDD-HHMMSS
        ts="${base#mervlan.backup.}"       # YYYYMMDD-HHMMSS

        # ----- date: YYYY-MM-DD -----
        date_part="${ts%%-*}"             # YYYYMMDD
        time_part="${ts#*-}"              # HHMMSS (or HHMM)

        yyyy=${date_part%????}            # 2025
        mmdd=${date_part#????}            # 1213
        mm=${mmdd%??}                     # 12
        dd=${mmdd#??}                     # 13
        date_fmt="$yyyy-$mm-$dd"

        # ----- time: HH:MM -----
        hh=${time_part%${time_part#??}}
        mm_rest=${time_part#??}
        mm2=${mm_rest%${mm_rest#??}}
        [ -z "$hh" ] && hh="00"
        [ -z "$mm2" ] && mm2="00"
        time_fmt="$hh:$mm2"

        version="none"

        if [ -n "$META_TMP" ]; then
            # Find changelog.txt inside the archive (path will be like mervlan.backup.YYYY.../changelog.txt)
            cl_path="$(tar -tzf "$b" 2>/dev/null | grep '/changelog\.txt$' | head -n 1)"

            if [ -n "$cl_path" ]; then
                # Make sure directory exists for extraction
                cl_dir="$META_TMP/$(dirname "$cl_path")"
                if ! mkdir -p "$cl_dir" 2>/dev/null; then
                    warn -c cli,vlan "Could not prepare backup metadata path for $b"
                    _update_metadata_failed=1
                    continue
                fi

                # Extract ONLY changelog.txt into META_TMP
                if ! tar -xzf "$b" -C "$META_TMP" "$cl_path" >/dev/null 2>&1; then
                    warn -c cli,vlan "Could not read changelog metadata from $b"
                    _update_metadata_failed=1
                    continue
                fi

                if [ -f "$META_TMP/$cl_path" ]; then
                    # First non-empty line
                    first_line="$(sed -n '1{/^[[:space:]]*$/d;p;q}' "$META_TMP/$cl_path" 2>/dev/null)"

                    # Expecting:  "mervlan vX.XX"
                    # Grab the last whitespace-separated field as candidate version
                    candidate="${first_line##* }"

                    case "$candidate" in
                        v*)
                            version="$candidate"
                            ;;
                        *)
                            # If it doesn't start with v, keep "none"
                            :
                            ;;
                    esac
                fi
            fi
        fi

        case "$idx" in
            1) json_set_array "BACKUP_1" "$version $date_fmt $time_fmt" || _update_metadata_failed=1 ;;
            2) json_set_array "BACKUP_2" "$version $date_fmt $time_fmt" || _update_metadata_failed=1 ;;
            3) json_set_array "BACKUP_3" "$version $date_fmt $time_fmt" || _update_metadata_failed=1 ;;
        esac
    done

    # Clean up extracted changelog files so nothing lingers
    if [ -n "$META_TMP" ] && [ -d "$META_TMP" ] && ! rm -rf "$META_TMP" 2>/dev/null; then
        warn -c cli,vlan "Could not remove backup metadata extraction workspace $META_TMP"
        _update_metadata_failed=1
    fi
    [ "$_update_metadata_failed" -eq 0 ]
}


# ========================================================================== #
# CLEANUP HANDLER                                                            #
# ========================================================================== #

update_pool_state_unresolved() {
	if type mnj_pool_state_unresolved >/dev/null 2>&1; then
		mnj_pool_state_unresolved
		return $?
	fi
	case "${MNJ_POOL_ACTIVE:-0}" in ''|0) return 1 ;; *) return 0 ;; esac
}

update_abort_node_pool() {
	update_pool_state_unresolved || return 0
	if ! type mnj_pool_abort_active >/dev/null 2>&1; then
		UPDATE_POOL_ABORT_FAILED="1"
		error -c cli,vlan "Update cleanup could not reconcile active node workers; retaining locks and recovery state"
		return 1
	fi
	if ! mnj_pool_abort_active failed update-exit; then
		UPDATE_POOL_ABORT_FAILED="1"
		error -c cli,vlan "Update cleanup could not stop and reconcile active node workers; retaining locks and recovery state"
		return 1
	fi
	if ! update_pool_state_unresolved; then UPDATE_POOL_ABORT_FAILED="0"; return 0; fi
	UPDATE_POOL_ABORT_FAILED="1"
	error -c cli,vlan "Update cleanup left active node workers unresolved; retaining locks and recovery state"
	return 1
}

cleanup_tmp() {
	_update_cleanup_rc=$?
	_update_cleanup_failed=0
	_update_pool_cleanup_ready="1"
	# A signal-path abort failure means rollback was intentionally skipped.
	# EXIT cleanup must preserve that decision rather than retrying into a
	# releasable maintenance state after the interrupted update was left active.
	if [ "$UPDATE_POOL_ABORT_FAILED" = "1" ]; then
		_update_pool_cleanup_ready="0"
		_update_cleanup_failed=1
		UPDATE_PRESERVE_TMP="1"
		UPDATE_PRESERVE_JFFS="1"
	elif [ "$UPDATE_RECOVERY_REQUIRED" = "1" ]; then
		_update_pool_cleanup_ready="0"
		_update_cleanup_failed=1
		UPDATE_PRESERVE_TMP="1"
		UPDATE_PRESERVE_JFFS="1"
	elif ! update_abort_node_pool; then
		_update_pool_cleanup_ready="0"
		_update_cleanup_failed=1
		UPDATE_PRESERVE_TMP="1"
		UPDATE_PRESERVE_JFFS="1"
	fi
	if [ "$_update_pool_cleanup_ready" = "1" ]; then
		if [ "$UPDATE_PRESERVE_JFFS" != "1" ]; then
			update_remove_jffs_stage "$UPDATE_JFFS_STAGE" || _update_cleanup_failed=1
		fi
		# UPDATE_JFFS_OLD is removed only after success or restored during rollback.
		# Preserve it if activation failed so the administrator still has the exact
		# pre-update tree beside the persistent backups.
		if [ "$UPDATE_PRESERVE_JFFS" != "1" ] && [ "$UPDATE_ACTIVATION_STARTED" != "1" ]; then
			update_remove_jffs_stage "$UPDATE_JFFS_OLD" || _update_cleanup_failed=1
		fi
		if [ "$UPDATE_PRESERVE_TMP" != "1" ] && [ -n "$TMP_BASE" ] && [ -d "$TMP_BASE" ]; then
			rm -rf "$TMP_BASE" 2>/dev/null || _update_cleanup_failed=1
		fi
		if [ "$UPDATE_MAINTENANCE_LOCK_OWNED" = "1" ]; then
			if type merv_owner_lock_release >/dev/null 2>&1 &&
			   merv_owner_lock_release "$UPDATE_MAINTENANCE_LOCK" "$UPDATE_MAINTENANCE_LOCK_NONCE" 2>/dev/null; then
				UPDATE_MAINTENANCE_LOCK_OWNED="0"
			else
				_update_cleanup_failed=1
				error -c cli,vlan "Update cleanup could not release the maintenance owner lock; recovery is required"
			fi
		fi
	else
		if [ "$UPDATE_RECOVERY_REQUIRED" = "1" ]; then
			error -c cli,vlan "Update cleanup preserved recovery data and maintenance owner lock because rollback recovery remains incomplete"
		else
			error -c cli,vlan "Update cleanup preserved recovery data and maintenance owner lock because active node workers remain unresolved"
		fi
	fi
	[ "$_update_cleanup_failed" -eq 0 ] || _update_cleanup_rc=1
	return "$_update_cleanup_rc"
}

handle_update_signal() {
	_update_signal_status="$1"
	[ "$UPDATE_SIGNAL_HANDLING" = "0" ] || exit "$_update_signal_status"
	UPDATE_SIGNAL_HANDLING="1"
	trap - INT TERM
	warn -c cli,vlan "Update interrupted; stopping safely"
	_update_signal_pool_ready="1"
	if ! update_abort_node_pool; then
		_update_signal_pool_ready="0"
		UPDATE_PRESERVE_TMP="1"
		UPDATE_PRESERVE_JFFS="1"
	fi
	if [ "$_update_signal_pool_ready" = "1" ] && update_activation_started; then
		if restore_update_original_tree; then
			error -c cli,vlan "Interrupted update rolled back to the original main-router installation"
		else
			update_mark_recovery_required
			error -c cli,vlan "Interrupted update rollback failed; recovery data and the maintenance owner lock remain preserved"
		fi
	fi
	exit "$_update_signal_status"
}

trap cleanup_tmp EXIT
trap 'handle_update_signal 130' INT
trap 'handle_update_signal 143' TERM


# ========================================================================== #
# MODE / CHANNEL PARSING                                                     #
# ========================================================================== #

# The backup/restore engine is kept separate from the download/update path,
# but update_mervlan.sh remains the public CLI entry point. If that engine is
# damaged, the standalone helper under mervlan_backups is the safe fallback.
case "$1" in
	backup|inventory|undo)
		if [ -f "$MERV_BASE/functions/mervlan_backup.sh" ]; then
			exec sh "$MERV_BASE/functions/mervlan_backup.sh" "$@"
		fi
		echo "Backup management is unavailable: mervlan_backup.sh is missing" >&2
		exit 1
		;;
	restore)
		if [ -f "$MERV_BASE/functions/mervlan_backup.sh" ]; then
			exec sh "$MERV_BASE/functions/mervlan_backup.sh" "$@"
		fi
		echo "Restore management is unavailable because mervlan_backup.sh is missing." >&2
		echo "Use $MERVLAN_BACKUP_DIR/recover.sh list, check, and restore for emergency recovery." >&2
		exit 1
		;;
esac

#
#   update_mervlan.sh                  -> MODE=update, CHANNEL=main
#   update_mervlan.sh dev              -> MODE=update, CHANNEL=dev
#   update_mervlan.sh update dev       -> MODE=update, CHANNEL=dev
#   update_mervlan.sh refs/tags/vX.Y.Z -> MODE=update, CHANNEL=refs/tags/vX.Y.Z
#

MODE="update"
CHANNEL="main"
UPDATE_SOURCE="remote"
UPDATE_LOCAL_ARCHIVE=""
UPDATE_LOG_POLICY="keep"
UPDATE_LEGACY_FALLBACK="0"

set_update_log_policy() {
	_update_policy_arg="$1"
	case "$_update_policy_arg" in
		""|--logs=keep|keep) UPDATE_LOG_POLICY="keep" ;;
		--logs=clear|clear) UPDATE_LOG_POLICY="clear" ;;
		*) fail_update cli "Invalid update log policy: $_update_policy_arg (expected --logs=keep or --logs=clear)" ;;
	esac
}

case "$1" in
	""|main|dev|refs/*)
		# old/simple usage: first arg is the channel directly
		if [ -n "$1" ]; then
			CHANNEL="$1"
		fi
		set_update_log_policy "${2:-}"
		;;
	update)
		MODE="update"
		if [ "${2:-}" = "legacy" ]; then
			# The legacy GUI event is only a compatibility transport. It may
			# consult custom_settings.txt after the maintenance lock is owned;
			# canonical encoded refs never use this fallback path.
			CHANNEL="main"
			UPDATE_LEGACY_FALLBACK="1"
			set_update_log_policy "${3:-}"
		else
			CHANNEL="${2:-main}"
			set_update_log_policy "${3:-}"
		fi
		;;
	local)
		UPDATE_SOURCE="local"
		UPDATE_LOCAL_ARCHIVE="${2:-}"
		[ -n "$UPDATE_LOCAL_ARCHIVE" ] || fail_update cli "Local update requires an absolute archive path"
		case "$UPDATE_LOCAL_ARCHIVE" in /*) ;; *) fail_update cli "Local update archive path must be absolute" ;; esac
		[ -L "$UPDATE_LOCAL_ARCHIVE" ] && fail_update cli "Local update archive must not be a symbolic link"
		[ -f "$UPDATE_LOCAL_ARCHIVE" ] && [ -s "$UPDATE_LOCAL_ARCHIVE" ] || \
			fail_update cli "Local update archive must be a nonempty regular file"
		[ "$#" -le 3 ] || fail_update cli "Local update accepts only an archive path and optional --logs policy"
		set_update_log_policy "${3:-}"
		;;
	*)
		echo "Usage: $0 [local /absolute/path/archive.tar.gz [--logs=keep|--logs=clear]|update [branch] [--logs=keep|--logs=clear]|backup|restore|main|dev|refs/<ref>]" >&2
		fail_update cli "Unknown mode/channel: $1"
		;;
esac

# GUI ref requests are written to custom_settings.txt by the Merlin parent form.
# Consume the newest value before resolving the download URL.  The value is
# one-shot: removing every copy prevents a custom branch/tag from unexpectedly
# overriding a later normal main/dev or CLI update.
update_gui_ref_transport_digest() {
	_update_grtd_file="${1:-}"
	[ -f "$_update_grtd_file" ] || return 1
	if type md5sum >/dev/null 2>&1; then
		_update_grtd_hash=$(md5sum "$_update_grtd_file" 2>/dev/null | awk 'NR == 1 { print $1 }')
		case "$_update_grtd_hash" in
			????????????????????????????????) printf '%s' "$_update_grtd_hash" | grep -q '^[0-9A-Fa-f][0-9A-Fa-f]*$' 2>/dev/null && { printf 'md5:%s\n' "$_update_grtd_hash"; return 0; } ;;
		esac
	fi
	if type cksum >/dev/null 2>&1; then
		_update_grtd_hash=$(cksum "$_update_grtd_file" 2>/dev/null | awk 'NR == 1 { print $1 ":" $2 }')
		case "$_update_grtd_hash" in [0-9]*:[0-9]*) printf 'cksum:%s\n' "$_update_grtd_hash"; return 0 ;; esac
	fi
	return 1
}

consume_gui_update_ref() {
	_gui_ref_file="${CUSTOM_SETTINGS_FILE:-/jffs/addons/custom_settings.txt}"
	GUI_UPDATE_REF=""
	[ -f "$_gui_ref_file" ] || return 1

	_gui_ref_raw=$(sed -n 's/^vlanmgr_update_ref=//p' "$_gui_ref_file" 2>/dev/null | tail -n 1 | tr -d '\r')
	[ -n "$_gui_ref_raw" ] || return 1
	_gui_ref_clean=$(printf '%s' "$_gui_ref_raw" | tr -cd 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-')
	[ "$_gui_ref_clean" = "$_gui_ref_raw" ] || return 3
	case "$_gui_ref_clean" in
		*..*|*//*|*/|*/.|*.lock) return 3 ;;
	esac
	case "$_gui_ref_clean" in
		refs/heads/?*|refs/tags/v[0-9]*) GUI_UPDATE_REF="$_gui_ref_clean" ;;
		*) return 3 ;;
	esac
	_gui_ref_digest=$(update_gui_ref_transport_digest "$_gui_ref_file" 2>/dev/null) || return 2
	mkdir -p "$MERV_STATE_ROOT" 2>/dev/null || return 2
	_gui_ref_ledger="$MERV_UPDATE_CONSUMED_FILE"
	if [ -f "$_gui_ref_ledger" ] && grep -F -x -q "$_gui_ref_digest|$_gui_ref_raw" "$_gui_ref_ledger" 2>/dev/null; then
		return 1
	fi
	_gui_ref_tmp="${_gui_ref_ledger}.tmp.$$"
	( umask 077; { [ -f "$_gui_ref_ledger" ] && cat "$_gui_ref_ledger"; printf '%s|%s\n' "$_gui_ref_digest" "$_gui_ref_raw"; } > "$_gui_ref_tmp" ) 2>/dev/null || { rm -f "$_gui_ref_tmp" 2>/dev/null; return 2; }
	chmod 600 "$_gui_ref_tmp" 2>/dev/null || { rm -f "$_gui_ref_tmp" 2>/dev/null; return 2; }
	mv -f "$_gui_ref_tmp" "$_gui_ref_ledger" 2>/dev/null || { rm -f "$_gui_ref_tmp" 2>/dev/null; return 2; }
	return 0
}

# Acquire the same maintenance lock used by backup/restore/delete operations.
# The service-event handler locks individual event names, so it cannot by
# itself prevent an update and a restore from running at the same time.
mkdir -p "${UPDATE_MAINTENANCE_LOCK%/*}" 2>/dev/null || \
	fail_update lock "Could not prepare the MerVLAN maintenance lock directory"

if ! type merv_owner_lock_acquire >/dev/null 2>&1; then
	fail_update lock "Owner-aware maintenance lock support is unavailable"
fi
if merv_owner_lock_acquire "$UPDATE_MAINTENANCE_LOCK" 1800 2 "mervlan_maintenance"; then
	UPDATE_MAINTENANCE_LOCK_OWNED="1"
	UPDATE_MAINTENANCE_LOCK_NONCE="${MERV_LOCK_NONCE:-}"
	UPDATE_MAINTENANCE_LOCK_START="${MERV_LOCK_START:-}"
	# Every child that operates inside this quiesced Update uses the exact
	# maintenance owner record; a bare MERV_UPDATE_OWNER flag is not authority.
	MERV_UPDATE_OWNER=1
	MERV_UPDATE_OWNER_PID="$$"
	MERV_UPDATE_OWNER_START="$UPDATE_MAINTENANCE_LOCK_START"
	MERV_UPDATE_OWNER_NONCE="$UPDATE_MAINTENANCE_LOCK_NONCE"
	# Child install/uninstall entry points authenticate this exact owner tuple;
	# the kind marker is descriptive and never sufficient without the journal,
	# quiesce state, and canonical owner match checked by lib_update_state.sh.
	MERV_MAINTENANCE_DELEGATION_KIND=update
	export MERV_UPDATE_OWNER MERV_UPDATE_OWNER_PID MERV_UPDATE_OWNER_START \
		MERV_UPDATE_OWNER_NONCE MERV_MAINTENANCE_DELEGATION_KIND
	if ! merv_update_owner_context_valid; then
		fail_update lock "Could not authenticate the Update maintenance owner context"
	fi
else
	fail_update busy "Another MerVLAN update, backup, restore, or deletion is already running"
fi

if merv_update_journal_requires_safe_boot; then
	error -c cli,vlan "An incomplete or malformed Update recovery record is active; use the recovery path before starting another Update"
	exit 1
fi

# Read the external GUI ref only after the maintenance lock is owned.  The
# helper records a private ledger entry instead of deleting/re-writing the
# Merlin-owned custom_settings.txt transport file.
if [ "$MODE" = "update" ] && [ "$UPDATE_LEGACY_FALLBACK" = "1" ]; then
	consume_gui_update_ref
	_gui_ref_status=$?
	case "$_gui_ref_status" in
		0) CHANNEL="$GUI_UPDATE_REF"; info -c cli,vlan "Using one-shot GUI update ref: $CHANNEL" ;;
		1) ;;
		2) fail_update cli "Could not safely consume the pending GUI update ref" ;;
		*) fail_update cli "Rejected invalid pending GUI update ref" ;;
	esac
fi

# Every configured node must be host-key verified before update log policy,
# backup creation, hook teardown, or any other update mutation begins.
if [ "$MODE" = "update" ] && [ -f "$SETTINGS_FILE" ] && ! update_preflight_nodes_with_retry; then
	fail_update ssh_trust "Update blocked before mutation: complete node preflight failed (${MERV_SSH_LAST_REASON:-${MERV_SSH_TRUST_LAST_REASON:-unknown}})"
fi

# Apply the selected policy only after the shared maintenance lock is owned, so
# log clearing and update execution are one ordered transaction.  Truncate in
# place to preserve the public symlink targets.
if [ "$UPDATE_LOG_POLICY" = "clear" ]; then
	if type log_clear_all >/dev/null 2>&1; then
		log_clear_all || fail_update logs "Could not clear existing MerVLAN logs"
	else
		mkdir -p "${LOGROOT:-/tmp/mervlan_tmp/logs}" 2>/dev/null || \
			fail_update logs "Could not prepare the MerVLAN log directory"
		for _update_log in "${LOGROOT:-/tmp/mervlan_tmp/logs}"/*.log; do
			[ -f "$_update_log" ] || continue
			: > "$_update_log" 2>/dev/null || fail_update logs "Could not clear ${_update_log##*/}"
		done
	fi
	info -c cli,vlan "Existing MerVLAN log history cleared by update policy; complete update log begins here"
else
	info -c cli,vlan "Update log policy: preserving existing history (subject to configured log limits)"
fi

# ========================================================================== #
# CURL RESOLUTION (update mode only)                                         #
# ========================================================================== #

# find curl binary in PATH or fallback to /usr/sbin/curl
find_curl() {
	CURL_PATH=$(merv_cmd curl 2>/dev/null) || CURL_PATH=""
	if [ -n "$CURL_PATH" ]; then
		printf '%s\n' "$CURL_PATH"
	elif [ -x /usr/sbin/curl ]; then
		printf '%s\n' "/usr/sbin/curl"
	else
		return 1
	fi
}

download_update_archive() {
	_update_download_url="$1"
	_update_download_archive="$2"
	_update_download_part="${_update_download_archive}.part"
	_update_download_attempt=1
	_update_download_delay=1
	_update_download_max_attempts=5

	[ -n "${CURL_BIN:-}" ] && [ -n "$_update_download_url" ] && [ -n "$_update_download_archive" ] || return 1
	if ! rm -f "$_update_download_archive" "$_update_download_part"; then
		error -c cli,vlan "Could not clear stale download archive before retrying"
		return 1
	fi

	while [ "$_update_download_attempt" -le "$_update_download_max_attempts" ]; do
		if ! rm -f "$_update_download_part"; then
			error -c cli,vlan "Could not clear partial archive before download attempt $_update_download_attempt/$_update_download_max_attempts"
			return 1
		fi
		info -c cli,vlan "Download attempt $_update_download_attempt/$_update_download_max_attempts"
		"$CURL_BIN" -fsL --connect-timeout 15 --max-time 300 \
			"$_update_download_url" -o "$_update_download_part"
		_update_download_rc=$?

		if [ "$_update_download_rc" -eq 0 ] && [ -s "$_update_download_part" ]; then
			if mv -f "$_update_download_part" "$_update_download_archive"; then
				info -c cli,vlan "Download completed successfully on attempt $_update_download_attempt/$_update_download_max_attempts"
				return 0
			fi
			error -c cli,vlan "Download attempt $_update_download_attempt/$_update_download_max_attempts could not publish the completed archive"
			rm -f "$_update_download_part" || \
				error -c cli,vlan "Could not remove partial archive after publish failure"
			return 1
		fi

		if ! rm -f "$_update_download_part"; then
			error -c cli,vlan "Could not remove partial archive after failed download attempt $_update_download_attempt/$_update_download_max_attempts"
			return 1
		fi
		if [ "$_update_download_rc" -eq 0 ]; then
			_update_download_reason="curl rc=0; archive empty"
		else
			_update_download_reason="curl rc=$_update_download_rc"
		fi
		warn -c cli,vlan "Download attempt $_update_download_attempt/$_update_download_max_attempts failed ($_update_download_reason)"
		if [ "$_update_download_attempt" -eq "$_update_download_max_attempts" ]; then
			error -c cli,vlan "Download failed after $_update_download_max_attempts attempts ($_update_download_reason)"
			return 1
		fi
		info -c cli,vlan "Retrying download in ${_update_download_delay}s"
		sleep "$_update_download_delay" || return 1
		_update_download_delay=$((_update_download_delay * 2))
		_update_download_attempt=$((_update_download_attempt + 1))
	done
	return 1
}

# LOCAL ARCHIVE HELPERS BEGIN
acquire_local_update_archive() {
	_update_local_source="$1"
	_update_local_dest="$2"
	_update_local_part="${_update_local_dest}.part"
	case "$_update_local_source" in /*) ;; *) return 1 ;; esac
	[ -L "$_update_local_source" ] && return 1
	[ -f "$_update_local_source" ] && [ -s "$_update_local_source" ] || return 1
	rm -f "$_update_local_dest" "$_update_local_part" 2>/dev/null || return 1
	cp -p "$_update_local_source" "$_update_local_part" 2>/dev/null || {
		rm -f "$_update_local_part" 2>/dev/null || :
		return 1
	}
	[ -s "$_update_local_part" ] && mv -f "$_update_local_part" "$_update_local_dest" 2>/dev/null || {
		rm -f "$_update_local_part" 2>/dev/null || :
		return 1
	}
	return 0
}

# Validate the archive member list before extraction. BusyBox tar renders a
# hardlink as a normal-file listing with " -> target", while symlinks start
# with `l`; reject both formats rather than resolving link targets.
validate_update_archive_members() {
	_update_archive="$1"
	_update_members="$TMP_BASE/archive.members.$$"
	_update_verbose="$TMP_BASE/archive.verbose.$$"
	UPDATE_ARCHIVE_TOPDIR=""
	UPDATE_ARCHIVE_RAW_READY="0"
	rm -f "$_update_members" "$_update_verbose" "$RAW_ARCHIVE" 2>/dev/null || return 1

	if tar -tzf "$_update_archive" >"$_update_members" 2>/dev/null &&
	   tar -tvzf "$_update_archive" >"$_update_verbose" 2>/dev/null; then
		:
	else
		gzip -dc "$_update_archive" >"$RAW_ARCHIVE" 2>/dev/null || return 1
		tar -tf "$RAW_ARCHIVE" >"$_update_members" 2>/dev/null &&
			tar -tvf "$RAW_ARCHIVE" >"$_update_verbose" 2>/dev/null || return 1
		UPDATE_ARCHIVE_RAW_READY="1"
	fi

	[ -s "$_update_members" ] || return 1
	while IFS= read -r _update_member || [ -n "$_update_member" ]; do
		case "$_update_member" in
			''|/*|*'\\'*|*//*|.|./*|*/.|*/./*|..|../*|*/..|*/../*) return 1 ;;
		esac
		_update_member_root="${_update_member%%/*}"
		case "$_update_member_root" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
		if [ -z "$UPDATE_ARCHIVE_TOPDIR" ]; then
			UPDATE_ARCHIVE_TOPDIR="$_update_member_root"
		elif [ "$UPDATE_ARCHIVE_TOPDIR" != "$_update_member_root" ]; then
			return 1
		fi
		case "$_update_member" in
			"$UPDATE_ARCHIVE_TOPDIR"|"$UPDATE_ARCHIVE_TOPDIR"/*) : ;;
			*) return 1 ;;
		esac
	done <"$_update_members"
	[ -n "$UPDATE_ARCHIVE_TOPDIR" ] || return 1

	while IFS= read -r _update_verbose_line || [ -n "$_update_verbose_line" ]; do
		case "$_update_verbose_line" in l*|h*|*' -> '*|*' link to '*) return 1 ;; esac
	done <"$_update_verbose"
	return 0
}
# LOCAL ARCHIVE HELPERS END

if [ "$UPDATE_SOURCE" = "remote" ]; then
	# Resolve curl only for remote source acquisition. Local archive mode must
	# remain usable on router images with no curl binary at all.
	CURL_BIN="$(find_curl)" || \
		fail_update curl "curl not found (tried PATH and /usr/sbin/curl); cannot update MerVLAN."

	case "$CHANNEL" in
		""|main) GITHUB_REF="refs/heads/main" ;;
		dev) GITHUB_REF="refs/heads/dev" ;;
		refs/*) GITHUB_REF="$CHANNEL" ;;
		*) GITHUB_REF="refs/heads/$CHANNEL" ;;
	esac
	GITHUB_URL="https://codeload.github.com/r80xcore/mervlan/tar.gz/$GITHUB_REF"
	info -c cli,vlan "Using Git ref: $GITHUB_REF"
else
	GITHUB_REF="local"
	GITHUB_URL=""
	info -c cli,vlan "Using local update archive source"
fi

# ========================================================================== #
# BASIC VALIDATION (update mode)                                             #
# ========================================================================== #

if [ ! -d "$MERV_BASE" ]; then
	fail_update cli "MerVLAN base directory missing at $MERV_BASE"
fi
if ! update_reconcile_stale_stages; then
	UPDATE_PRESERVE_JFFS="1"
	fail_update recovery "Active MerVLAN files are incomplete. Staged recovery trees were preserved; use $MERVLAN_BACKUP_DIR/recover.sh before updating."
fi

update_check_jffs_health || fail_update jffs_health "JFFS health/read-write check failed; Update was stopped before mutation"

mkdir -p "$TMP_BASE" "$STAGE_DIR" "$BACKUP_DIR" 2>/dev/null || \
	fail_update workspace "Failed to prepare temporary workspace at $TMP_BASE"

# Updates temporarily hold the download, extracted source, stage, and updated
# tree in RAM. Reserve enough temporary space for several copies of the current
# installation before downloading anything.
UPDATE_CURRENT_KB=$(update_path_size_kb "$MERV_BASE")
update_require_space_kb "$TMP_DIR" "$((UPDATE_CURRENT_KB * 3))" "temporary update workspace"
update_record_phase workspace || fail_update journal "Could not persist the workspace Update journal"

# Freeze new MerVLAN mutations before the long download/extraction window. The
# existing guards remain owned by their current worker until it finishes; the
# explicit idle wait below prevents Update from tearing down a live critical
# section or letting a new heal/manager run start midway through extraction.
if ! merv_update_quiesce_begin "$UPDATE_RUN_ID"; then
	fail_update quiescing "Could not publish the Update maintenance-quiesce marker"
fi
UPDATE_QUIESCE_ACTIVE="1"
update_record_phase quiescing || fail_update journal "Could not persist the quiescing Update journal"
if ! update_wait_for_runtime_idle; then
	fail_update quiescing "Active MerVLAN runtime work did not reach a safe idle state"
fi
update_record_phase quiesced || fail_update journal "Could not persist the quiesced Update journal"

# ========================================================================== #
# CAPTURE CURRENT VERSION (BEFORE UPDATE)                                    #
# ========================================================================== #

OLD_VERSION=""
if [ -f "$MERV_BASE/changelog.txt" ]; then
	OLD_VERSION=$(sed -n '1{/^[[:space:]]*$/d;p;q}' "$MERV_BASE/changelog.txt" 2>/dev/null)
fi

# ========================================================================== #
# CAPTURE ORIGINAL BOOT STATE (BEFORE TEARDOWN)                              #
# ========================================================================== #
if [ -f "$MERV_BASE/settings/settings.json" ]; then
	if merv_has json_get_section_value; then
		PRE_BOOT_ENABLED="$(json_get_section_value "General" "BOOT_ENABLED" "$MERV_BASE/settings/settings.json" 2>/dev/null)"
	elif merv_has json_get_flag; then
		PRE_BOOT_ENABLED="$(json_get_flag "BOOT_ENABLED" "0" "$MERV_BASE/settings/settings.json" 2>/dev/null)"
	elif grep -q '"BOOT_ENABLED"[[:space:]]*:[[:space:]]*"1"' "$MERV_BASE/settings/settings.json" 2>/dev/null; then
		PRE_BOOT_ENABLED="1"
	fi
fi
[ "$PRE_BOOT_ENABLED" = "1" ] || PRE_BOOT_ENABLED="0"
update_record_phase preflight || fail_update journal "Could not persist the preflight Update journal"

# ========================================================================== #
# NODE/SSH HELPERS                                                           #
# ========================================================================== #

list_configured_nodes() {
	[ -f "$SETTINGS_FILE" ] || return 1
	merv_node_list
}

has_configured_nodes() {
	nodes=$(list_configured_nodes)
	[ -n "$nodes" ]
}

backup_remote_node_dbs() {
    nodes=$(list_configured_nodes)
    if [ -z "$nodes" ]; then
        return 0
    fi
    if ! ssh_keys_effectively_installed; then
        return 0
    fi

    mkdir -p "$NODE_DB_STAGE" 2>/dev/null || {
        warn -c cli,vlan "Could not create node db staging dir; skipping MAC shield backup for nodes"
        return 1
    }

    while read -r node_id node_ip; do
        [ -n "$node_ip" ] || continue
        local_file="$NODE_DB_STAGE/node${node_id}.db"

        if merv_ssh_exec "$node_id" "$node_ip" \
            "cat /tmp/mervlan_tmp/mac_shield.db 2>/dev/null || cat /jffs/addons/mervlan/tmp/mac_shield.db 2>/dev/null" \
            > "$local_file" 2>/dev/null && [ -s "$local_file" ]
        then
            info -c cli,vlan "MAC shield db backed up from NODE${node_id} ($node_ip)"
        else
            if ! update_cleanup_files "$local_file"; then
                UPDATE_PRESERVE_TMP="1"
                warn -c cli,vlan "MAC shield db backup failed and its local partial file could not be removed"
            fi
            warn -c cli,vlan "MAC shield db not found or unreachable on NODE${node_id} ($node_ip); skipping"
        fi
    done <<EOF
$nodes
EOF

    return 0
}

restore_remote_node_dbs() {
    nodes=$(list_configured_nodes)
    if [ -z "$nodes" ]; then
        if ! update_cleanup_tree "$NODE_DB_STAGE"; then UPDATE_PRESERVE_TMP="1"; return 1; fi
        return 0
    fi
    if ! ssh_keys_effectively_installed; then
        if ! update_cleanup_tree "$NODE_DB_STAGE"; then UPDATE_PRESERVE_TMP="1"; return 1; fi
        return 0
    fi

    while read -r node_id node_ip; do
        [ -n "$node_ip" ] || continue
        local_file="$NODE_DB_STAGE/node${node_id}.db"

        [ -s "$local_file" ] || continue

        if merv_ssh_exec "$node_id" "$node_ip" "mkdir -p /jffs/addons/mervlan/tmp" >/dev/null 2>&1 &&
           merv_ssh_stream_file "$node_id" "$node_ip" "$local_file" "/jffs/addons/mervlan/tmp/mac_shield.db" 2>/dev/null
        then
            info -c cli,vlan "MAC shield db restored to NODE${node_id} ($node_ip)"
        else
            warn -c cli,vlan "MAC shield db restore failed for NODE${node_id} ($node_ip); node will rebuild on next cron tick"
        fi
    done <<EOF
$nodes
EOF

    if ! update_cleanup_tree "$NODE_DB_STAGE"; then UPDATE_PRESERVE_TMP="1"; return 1; fi
    return 0
}

# ========================================================================== #
# MAIN MAC DB PRESERVE / RESTORE (PRE- AND POST-UPDATE)                     #
# ========================================================================== #

# backup_main_mac_db_for_update
# Save the main router's MAC shield DB to RAM before teardown.
# Uses -f (not -s) so an empty DB (no clients locked) is still preserved.
backup_main_mac_db_for_update() {
    MAC_DB_BACKUP_PRESENT=0
    mkdir -p "$BACKUP_DIR/tmp" 2>/dev/null || return 1

    _msrc=""
    [ -f "$MERV_MAC_DB_ACTIVE" ] && _msrc="$MERV_MAC_DB_ACTIVE"
    [ -z "$_msrc" ] && [ -f "$MERV_MAC_DB_JFFS" ] && _msrc="$MERV_MAC_DB_JFFS"

    if [ -z "$_msrc" ]; then
        info -c cli,vlan "MERV_MAC: no existing MAC shield db found; restore will be skipped"
        return 0
    fi

    if cp -p "$_msrc" "$BACKUP_DIR/tmp/mac_shield.db" 2>/dev/null; then
        MAC_DB_BACKUP_PRESENT=1
        _mcount=$(awk 'NF==4' "$BACKUP_DIR/tmp/mac_shield.db" 2>/dev/null | wc -l | tr -d ' ')
        info -c cli,vlan "MERV_MAC: preserved pre-update db (${_mcount:-0} entries)"
    else
        warn -c cli,vlan "MERV_MAC: failed to preserve pre-update db"
    fi
}

# restore_main_mac_db_after_update
# Copy the preserved MAC shield DB back into the active and JFFS locations.
# Returns 0 if the active DB was restored successfully (caller may push to nodes),
# 1 if it was not (JFFS may still have succeeded, but push should not run).
restore_main_mac_db_after_update() {
    _msrc="$BACKUP_DIR/tmp/mac_shield.db"
    if [ ! -f "$_msrc" ]; then
        [ "${MAC_DB_BACKUP_PRESENT:-0}" = "1" ] && \
            warn -c cli,vlan "MERV_MAC: preserved db missing during restore"
        return 1
    fi

    _mcount=$(awk 'NF==4' "$_msrc" 2>/dev/null | wc -l | tr -d ' ')
    _mactive_ok=0
    _mjffs_ok=0

    if ! mkdir -p "$(dirname "$MERV_MAC_DB_ACTIVE")" 2>/dev/null; then
        warn -c cli,vlan "MERV_MAC: could not prepare the active db directory"
        _mactive_ok=0
    fi
    if [ "$_mactive_ok" = "0" ] && cp -p "$_msrc" "$MERV_MAC_DB_ACTIVE" 2>/dev/null; then
        _mactive_ok=1
    else
        warn -c cli,vlan "MERV_MAC: active db restore failed"
    fi

    if ! mkdir -p "$(dirname "$MERV_MAC_DB_JFFS")" 2>/dev/null; then
        warn -c cli,vlan "MERV_MAC: could not prepare the JFFS db directory"
        _mjffs_ok=0
    fi
    if [ "$_mjffs_ok" = "0" ] && cp -p "$_msrc" "$MERV_MAC_DB_JFFS" 2>/dev/null; then
        _mjffs_ok=1
    else
        warn -c cli,vlan "MERV_MAC: JFFS checkpoint restore failed"
    fi

    if [ "$_mactive_ok" = "1" ] || [ "$_mjffs_ok" = "1" ]; then
        info -c cli,vlan "MERV_MAC: restored pre-update db (${_mcount:-0} entries, active=${_mactive_ok} jffs=${_mjffs_ok})"
    else
        warn -c cli,vlan "MERV_MAC: db restore failed for both active and JFFS locations"
        return 1
    fi

    [ "$_mactive_ok" = "1" ] && return 0 || return 1
}

# ========================================================================== #
# BACKUP ORIGINAL FILES                                                      #
# ========================================================================== #

info -c cli,vlan "Backing up user configuration files"
for rel_path in $BACKUP_LIST; do
	src="$MERV_BASE/$rel_path"
	if [ -f "$src" ]; then
		dest="$BACKUP_DIR/$rel_path"
		mkdir -p "$(dirname "$dest")" 2>/dev/null || \
			fail_update backup_user_files "Failed to create backup directory for $rel_path"
		cp -p "$src" "$dest" 2>/dev/null || \
			fail_update backup_user_files "Failed to back up $rel_path"
	fi
done

# ========================================================================== #

update_record_phase downloading || fail_update journal "Could not persist the downloading Update journal"
if [ "$UPDATE_SOURCE" = "local" ]; then
	info -c cli,vlan "Acquiring MerVLAN archive from local file"
	acquire_local_update_archive "$UPDATE_LOCAL_ARCHIVE" "$ARCHIVE" || \
		fail_update downloading "Could not safely acquire the local update archive"
else
	info -c cli,vlan "Downloading latest MerVLAN snapshot using: $CURL_BIN"
	download_update_archive "$GITHUB_URL" "$ARCHIVE" || \
		fail_update downloading "Download failed after 5 attempts"
fi

# Never extract a locally supplied (or remotely acquired) archive until its
# complete member list, single root, and BusyBox link representation are safe.
if ! validate_update_archive_members "$ARCHIVE"; then
	fail_update extracting "Archive failed pre-extraction path or link validation"
fi

# The archive is the first large RAM allocation. The original check above is
# only a conservative baseline; refresh it with the actual compressed size and
# reserve room for the current tree plus the expanded/staged copy before tar
# starts writing into /tmp.
UPDATE_ARCHIVE_KB=$(update_path_size_kb "$ARCHIVE")
case "$UPDATE_ARCHIVE_KB" in ''|0) fail_update downloading "Downloaded archive size could not be measured" ;; esac
update_require_space_kb "$TMP_DIR" "$((UPDATE_CURRENT_KB * 2))" "archive and extraction workspace"

info -c cli,vlan "Extracting archive into staging area"
update_record_phase extracting || fail_update journal "Could not persist the extracting Update journal"
if [ "${UPDATE_ARCHIVE_RAW_READY:-0}" = "1" ]; then
	info -c cli,vlan "tar gzip support unavailable; using checked gzip-to-RAM fallback"
	UPDATE_RAW_ARCHIVE_KB=$(update_path_size_kb "$RAW_ARCHIVE")
	case "$UPDATE_RAW_ARCHIVE_KB" in ''|0) fail_update extracting "Decompressed archive size could not be measured" ;; esac
	update_require_space_kb "$TMP_DIR" "$((UPDATE_CURRENT_KB * 2))" "checked gzip extraction workspace"
	tar -xf "$RAW_ARCHIVE" -C "$TMP_BASE" || fail_update extracting "Failed to extract decompressed archive"
	update_cleanup_files "$RAW_ARCHIVE" || fail_update extracting "Could not remove the checked gzip fallback archive"
else
	tar -xzf "$ARCHIVE" -C "$TMP_BASE" || fail_update extracting "Failed to extract archive"
fi

topdir="$TMP_BASE/$UPDATE_ARCHIVE_TOPDIR"
[ -d "$topdir" ] || fail_update extracting "Archive root did not extract as one directory"


# Publish the human-readable update banner once both versions are known. The
# installed UI version is the source of truth for the current version; the
# staged changelog is the source of truth for the selected target ref.
UPDATE_FROM_VERSION=$(update_html_version "$MERV_BASE/www/index.html" 2>/dev/null) || UPDATE_FROM_VERSION="unknown"
UPDATE_TO_VERSION=$(update_changelog_version "$topdir/changelog.txt" 2>/dev/null) || UPDATE_TO_VERSION="unknown"
UPDATE_CHANNEL_LABEL=$(update_channel_label)
info -c cli,vlan "#################################################"
info -c cli,vlan "MerVLAN is updating! Please do not turn off the router/node(s) during the update."
info -c cli,vlan "Updating from $UPDATE_FROM_VERSION to $UPDATE_TO_VERSION from $UPDATE_CHANNEL_LABEL"
info -c cli,vlan "#################################################"

	update_filter_source_tree "$topdir" || \
		fail_update extracting "Could not filter developer-only files from the update payload"
	info -c cli,vlan "Update payload filtered: dev-tools=${UPDATE_PAYLOAD_DEV_TOOLS:-0}"
	UPDATE_EXTRACTED_KB=$(update_path_size_kb "$topdir")
update_require_space_kb "$TMP_DIR" "$UPDATE_EXTRACTED_KB" "temporary update staging"
cp -a "$topdir"/. "$STAGE_DIR"/ 2>/dev/null || \
	fail_update extracting "Failed to copy extracted files into staging"
if ! update_cleanup_tree "$topdir"; then
	UPDATE_PRESERVE_TMP="1"
	fail_update extracting "Validated archive source could not be removed from RAM staging"
fi
UPDATE_STAGE_KB=$(update_path_size_kb "$STAGE_DIR")
case "$UPDATE_STAGE_KB" in ''|0) fail_update extracting "Staged tree size could not be measured" ;; esac
update_require_space_kb "$TMP_DIR" "$UPDATE_CURRENT_KB" "validated stage and rollback workspace"

# ========================================================================== #
# VALIDATE STAGED CONTENT                                                    #
# ========================================================================== #

info -c cli,vlan "Validating staged files"
update_stage_core_valid "$STAGE_DIR" || \
	fail_update validating "Validation failed; downloaded archive is missing core MerVLAN files. Include validation and file warnings when reporting this issue."

for optional in $OPTIONAL_STAGE_FILES; do
	if [ ! -f "$STAGE_DIR/$optional" ]; then
		warn -c cli,vlan "Optional staged file missing: $optional This may be expected if the update has removed this file/files, but if not, it could indicate an incomplete download or archive structure change. Include this info when reporting potential issues."
	fi
done

for d in $OPTIONAL_STAGE_DIRS; do
	if [ ! -d "$STAGE_DIR/$d" ]; then
		warn -c cli,vlan "Optional staged directory missing: $d/ This may be expected if the update has removed this directory/directories, but if not, it could indicate an incomplete download or archive structure change. Include this info when reporting potential issues."
	fi
done

info -c cli,vlan "Staged content validated successfully"
update_record_phase staged || fail_update journal "Could not persist the staged Update journal"

# Complete and validate the durable pre-update archive before hooks are disabled
# or the active installation is touched. Build its source in RAM and apply the
# same payload filter as the incoming tree first. Developer archives, evidence,
# and other non-runtime files are not needed to recover the addon and must not
# make a first cleanup update fail its JFFS check.
if ! update_cleanup_tree "$UPDATE_BACKUP_SOURCE_DIR" ||
   ! cp -pR "$MERV_BASE" "$UPDATE_BACKUP_SOURCE_DIR" 2>/dev/null ||
   ! update_filter_source_tree "$UPDATE_BACKUP_SOURCE_DIR"; then
	UPDATE_PRESERVE_TMP="1"
	fail_update backing_up "Could not prepare the filtered pre-update rollback source"
fi
UPDATE_BACKUP_SOURCE_KB=$(update_path_size_kb "$UPDATE_BACKUP_SOURCE_DIR")
info -c cli,vlan "Pre-update rollback payload filtered to ${UPDATE_BACKUP_SOURCE_KB} KB"
update_require_space_kb "$MERVLAN_BACKUP_DIR" "$UPDATE_BACKUP_SOURCE_KB" "persistent backup" "$UPDATE_JFFS_RESERVE_KB"
UPDATE_BACKUP_ARCHIVE_OK=0
if ! create_durable_preupdate_backup "$UPDATE_BACKUP_SOURCE_DIR"; then
	if ! update_cleanup_files "${UPDATE_BACKUP_PARTIAL:-}" "${UPDATE_BACKUP_META_PARTIAL:-}"; then UPDATE_PRESERVE_TMP="1"; fi
	fail_update backing_up "Failed to create and validate the durable pre-update backup"
fi

update_record_phase durable-backup || fail_update journal "Could not persist the durable-backup Update journal"

# Keep the filtered rollback copy in RAM. It is intentionally temporary and is
# not a substitute for the durable archive above.
update_require_space_kb "$TMP_DIR" "$UPDATE_BACKUP_SOURCE_KB" "temporary rollback"
if ! update_cleanup_tree "$UPDATE_ORIGINAL_DIR"; then
	UPDATE_PRESERVE_TMP="1"
	fail_update preparing_rollback "Could not remove the previous temporary rollback copy"
fi
if ! mv "$UPDATE_BACKUP_SOURCE_DIR" "$UPDATE_ORIGINAL_DIR" 2>/dev/null || \
	[ ! -f "$UPDATE_ORIGINAL_DIR/settings/settings.json" ]; then
	if ! update_cleanup_tree "$UPDATE_ORIGINAL_DIR"; then UPDATE_PRESERVE_TMP="1"; fi
	fail_update preparing_rollback "Failed to create and validate the temporary rollback copy"
fi
UPDATE_ORIGINAL_KB=$(update_path_size_kb "$UPDATE_ORIGINAL_DIR")
case "$UPDATE_ORIGINAL_KB" in ''|0) fail_update preparing_rollback "Temporary rollback size could not be measured" ;; esac
update_require_space_kb "$TMP_DIR" "$UPDATE_STAGE_KB" "updated-tree copy workspace"
BACKUP_READY="1"
update_record_phase backup || fail_update journal "Could not persist the backup Update journal"

# Preserve main MAC DB before teardown destroys it (setupdisable removes the DB)
if ! backup_main_mac_db_for_update; then
	fail_update backing_up "Could not prepare the pre-update MAC Shield preservation area"
fi

# Temporarily quiesce runtime behavior, then remove old-version injections so
# target templates can be installed cleanly after the swap.
if [ -x "$BOOT_SCRIPT" ]; then
	TEARDOWN_DONE="1"
	info -c cli,vlan "Disabling MerVLAN hooks on main router before swap"

	# Stop active manager/cron behavior on the main router only. Nodes remain on
	# their working installation until their replacement has been transferred.
	if ! run_update_step "pre-update main disable" env MERV_UPDATE_OWNER=1 MERV_SKIP_NODE_SYNC=1 sh "$BOOT_SCRIPT" disable; then
		fail_update teardown "Could not disable MerVLAN hooks before update activation"
	fi
	# Remove the main service/addon injections without a second implicit node
	# sweep; nodedisable below owns node template teardown explicitly.
	if ! run_update_step "pre-update main setupdisable" env MERV_UPDATE_OWNER=1 MERV_SKIP_NODE_SYNC=1 sh "$BOOT_SCRIPT" setupdisable; then
		fail_update teardown "Could not remove MerVLAN hooks before update activation"
	fi
		_update_dhcp_status=$(merv_dhcp_hold_status 2>/dev/null)
		_update_dhcp_status_rc=$?
		[ "$_update_dhcp_status_rc" -eq 0 ] ||
			fail_update teardown "DHCP Hold state could not be verified after hook teardown"
		if printf '%s\n' "$_update_dhcp_status" | grep -q '^desired=hold$'; then
			fail_update teardown "DHCP Hold ownership remained active after runtime quiesce"
		fi
		if ! merv_dhcp_hold_release; then
			fail_update teardown "Could not reconcile DHCP Hold after runtime quiesce"
		fi
		if ! merv_dhcp_hold_rules_absent; then
		fail_update teardown "DHCP Hold rules remained active after runtime quiesce"
	fi
	update_record_phase quiesced-guards-released || fail_update journal "Could not persist the released-guard Update journal"

	info -c cli,vlan "Configured nodes remain active until staged replacement begins"
else
	warn -c cli,vlan "mervlan_boot.sh not executable; skipping pre-update teardown"
fi

# ========================================================================== #
# REPLACE INSTALLATION                                                       #
# ========================================================================== #

MERVLAN_UPDATED_TREE_DIR="$TMP_BASE/updated_tree"

info -c cli,vlan "Building updated tree at $MERVLAN_UPDATED_TREE_DIR"
if ! update_cleanup_tree "$MERVLAN_UPDATED_TREE_DIR"; then
	UPDATE_PRESERVE_TMP="1"
	fail_update building_tree "Could not remove the previous temporary updated tree"
fi

UPDATE_STAGE_KB=$(update_path_size_kb "$STAGE_DIR")
update_require_space_kb "$TMP_DIR" "$UPDATE_STAGE_KB" "temporary updated-tree staging"
mkdir -p "$MERVLAN_UPDATED_TREE_DIR" 2>/dev/null || \
	fail_update building_tree "Failed to create temporary install directory"

if ! cp -a "$STAGE_DIR"/. "$MERVLAN_UPDATED_TREE_DIR"/ 2>/dev/null; then
	if ! update_cleanup_tree "$MERVLAN_UPDATED_TREE_DIR"; then UPDATE_PRESERVE_TMP="1"; fi
	fail_update building_tree "Failed to copy staged files into $MERVLAN_UPDATED_TREE_DIR"
fi
UPDATE_UPDATED_KB=$(update_path_size_kb "$MERVLAN_UPDATED_TREE_DIR")
case "$UPDATE_UPDATED_KB" in ''|0) fail_update building_tree "Updated tree size could not be measured" ;; esac
if ! update_cleanup_tree "$STAGE_DIR"; then
	UPDATE_PRESERVE_TMP="1"
	fail_update building_tree "Validated staging copy could not be removed from RAM"
fi

update_normalize_script_permissions() {
	local _update_permission_root="$1" f depth target
	[ -d "$_update_permission_root" ] || return 1

	# Default: runtime shell entry points are executable (755).
	for depth in "" "*/" "*/*/"; do
		for f in "$_update_permission_root"/${depth}*.sh; do
			[ -f "$f" ] 2>/dev/null || continue
			chmod 755 "$f" 2>/dev/null || return 1
		done
	done

	# Every settings library is source-only data and must remain non-executable.
	for target in "$_update_permission_root"/settings/lib_*.sh; do
		[ -f "$target" ] || continue
		chmod 644 "$target" 2>/dev/null || return 1
	done

	for target in \
		"$_update_permission_root/settings/var_settings.sh" \
		"$_update_permission_root/settings/log_settings.sh" \
		"$_update_permission_root/settings/mac_shield_snapshot.sh" \
		"$_update_permission_root/templates/mervlan_templates.sh"
	do
		[ -f "$target" ] || continue
		chmod 644 "$target" 2>/dev/null || return 1
	done
}

# CHMOD: normalize script permissions in new tree
info -c cli,vlan "Normalizing script permissions in new tree"
update_normalize_script_permissions "$MERVLAN_UPDATED_TREE_DIR" || \
	fail_update permissions "Could not normalize script permissions in updated tree"


# ========================================================================== #
# RESTORE USER DATA                                                          #
# ========================================================================== #

info -c cli,vlan "Restoring preserved files"
for rel_path in $BACKUP_LIST; do
	backup_file="$BACKUP_DIR/$rel_path"
	target="$MERVLAN_UPDATED_TREE_DIR/$rel_path"
	if [ -f "$backup_file" ]; then
		if [ "$rel_path" = "settings/settings.json" ]; then
			info -c cli,vlan "Merging settings.json (preserve user keys, keep new defaults, skip Hardware)"
			if ! merge_settings_json "$backup_file" "$target"; then
				if ! update_cleanup_tree "$MERVLAN_UPDATED_TREE_DIR"; then UPDATE_PRESERVE_TMP="1"; fi
				fail_update restoring_user_data "Failed to merge settings.json"
			fi
			continue
		fi
		if ! mkdir -p "$(dirname "$target")" 2>/dev/null; then
			if ! update_cleanup_tree "$MERVLAN_UPDATED_TREE_DIR"; then UPDATE_PRESERVE_TMP="1"; fi
			fail_update restoring_user_data "Failed to recreate directory for $rel_path"
		fi
		if ! cp -p "$backup_file" "$target" 2>/dev/null; then
			if ! update_cleanup_tree "$MERVLAN_UPDATED_TREE_DIR"; then UPDATE_PRESERVE_TMP="1"; fi
			fail_update restoring_user_data "Failed to restore $rel_path"
		fi
		if [ -n "$SSH_KEY_RELATIVE" ] && [ "$rel_path" = "$SSH_KEY_RELATIVE" ]; then
			if ! chmod 600 "$target" 2>/dev/null; then
				fail_update restoring_user_data "Could not secure the restored SSH private key"
			fi
		elif [ -n "$SSH_PUBKEY_RELATIVE" ] && [ "$rel_path" = "$SSH_PUBKEY_RELATIVE" ]; then
			if ! chmod 644 "$target" 2>/dev/null; then
				fail_update restoring_user_data "Could not secure the restored SSH public key"
			fi
		fi
	fi
done

# The downloaded tree may change node endpoints or MAC identity. Revalidate
# the complete target settings before creating the activation stage or swapping
# the live installation, so a bad update cannot leave the router ahead of its
# node trust state.
if ! merv_ssh_preflight_settings_file "$MERVLAN_UPDATED_TREE_DIR/settings/settings.json"; then
	if ! update_cleanup_tree "$MERVLAN_UPDATED_TREE_DIR"; then UPDATE_PRESERVE_TMP="1"; fi
	fail_update ssh_trust "Update blocked: target settings failed complete SSH trust preflight"
fi

info -c cli,vlan "Preparing validated JFFS activation stage"
mkdir -p "$MERVLAN_BACKUP_DIR" 2>/dev/null || \
	fail_update preparing_activation "Failed to prepare $MERVLAN_BACKUP_DIR"
update_require_space_kb "$MERVLAN_BACKUP_DIR" "$UPDATE_STAGE_KB" "temporary JFFS activation stage" "$UPDATE_JFFS_RESERVE_KB"
if ! update_remove_jffs_stage "$UPDATE_JFFS_STAGE" || ! update_remove_jffs_stage "$UPDATE_JFFS_OLD"; then
	UPDATE_PRESERVE_JFFS="1"
	fail_update preparing_activation "Could not clear the exact previous JFFS activation paths"
fi
if ! cp -pR "$MERVLAN_UPDATED_TREE_DIR" "$UPDATE_JFFS_STAGE" 2>/dev/null || \
   [ ! -f "$UPDATE_JFFS_STAGE/settings/settings.json" ] || \
   [ ! -x "$UPDATE_JFFS_STAGE/install.sh" ] || \
   [ ! -x "$UPDATE_JFFS_STAGE/functions/mervlan_boot.sh" ]; then
	if ! update_remove_jffs_stage "$UPDATE_JFFS_STAGE"; then UPDATE_PRESERVE_JFFS="1"; fi
	fail_update preparing_activation "Failed to create a complete activation stage at $UPDATE_JFFS_STAGE"
fi
if ! update_cleanup_tree "$MERVLAN_UPDATED_TREE_DIR"; then
	UPDATE_PRESERVE_TMP="1"
	fail_update preparing_activation "Validated JFFS stage was created, but its source tree could not be removed"
fi

info -c cli,vlan "Swapping active installation with same-filesystem renames"
if ! mv "$MERV_BASE" "$UPDATE_JFFS_OLD" 2>/dev/null; then
	fail_update swapping_installation "Failed to preserve the active installation at $UPDATE_JFFS_OLD"
fi
DESTRUCTIVE_TOUCHED="1"
UPDATE_ACTIVATION_STARTED="1"
update_record_phase activation-started || fail_update journal "Could not persist the activation-started Update journal"
if ! mv "$UPDATE_JFFS_STAGE" "$MERV_BASE" 2>/dev/null; then
	fail_update swapping_installation "Failed to activate the validated installation stage"
fi
update_record_phase activated || fail_update journal "Could not persist the activated Update journal"

# ========================================================================== #
# OPTIONAL POST-UPDATE TASKS                                                 #
# ========================================================================== #

refresh_public_install() {
	local uninstall_script="$MERV_BASE/uninstall.sh"
	local install_script="$MERV_BASE/install.sh"

	info -c cli,vlan "Reprovisioning public/runtime installation with log preservation"

	if [ ! -x "$uninstall_script" ]; then
		warn -c cli,vlan "Skipping public refresh: $uninstall_script not executable"
		return 1
	fi
	if [ ! -x "$install_script" ]; then
		warn -c cli,vlan "Skipping public refresh: $install_script not executable"
		return 1
	fi

	if ! run_update_step "public uninstall" env MERV_UPDATE_OWNER=1 sh "$uninstall_script" reinstall; then
		warn -c cli,vlan "Public uninstall failed; install may be stale"
		return 1
	fi

	if ! run_update_step "public install" env MERV_UPDATE_OWNER=1 sh "$install_script" reinstall; then
		warn -c cli,vlan "Public install refresh failed"
		return 1
	fi

	info -c cli,vlan "Public install refreshed"
	return 0
}

runtime_report_matches() {
	_runtime_report="$1"
	_runtime_role="$2"
	_runtime_expected_cron=absent
	[ "$PRE_BOOT_ENABLED" = "1" ] && _runtime_expected_cron=present

	case "$_runtime_report" in REPORT\ *) ;; *) return 1 ;; esac
	case " $_runtime_report " in *" boot=$PRE_BOOT_ENABLED "*) ;; *) return 1 ;; esac
	case " $_runtime_report " in *" event=active "*) ;; *) return 1 ;; esac
	case " $_runtime_report " in *" cron=$_runtime_expected_cron "*) ;; *) return 1 ;; esac

	case "$_runtime_role" in
		main)
			case " $_runtime_report " in *" addon=active "*) ;; *) return 1 ;; esac
			case " $_runtime_report " in *" is_node=no "*) return 0 ;; *) return 1 ;; esac
			;;
		node)
			case " $_runtime_report " in *" addon=node-on "*) ;; *) return 1 ;; esac
			case " $_runtime_report " in *" is_node=yes "*) return 0 ;; *) return 1 ;; esac
			;;
		*) return 1 ;;
	esac
}

verify_updated_runtime_state() {
	_verify_scope="${1:-all}"
	_verify_action=disable
	[ "$PRE_BOOT_ENABLED" = "1" ] && _verify_action=enable

	_verify_main_report=""
	if ! _verify_main_report=$(sh "$BOOT_SCRIPT" report 2>/dev/null); then
		warn -c cli,vlan "Main runtime report command failed during update verification"
	fi
	if ! runtime_report_matches "$_verify_main_report" main; then
		warn -c cli,vlan "Main runtime verification mismatch; retrying target-version hook reconciliation"
		if ! run_update_step "runtime verification setupenable" env MERV_UPDATE_OWNER=1 MERV_SKIP_NODE_SYNC=1 sh "$BOOT_SCRIPT" setupenable; then
			warn -c cli,vlan "Main target-version hook reconciliation setup failed"
		fi
		if ! run_update_step "runtime verification boot state" env MERV_UPDATE_OWNER=1 MERV_SKIP_NODE_SYNC=1 sh "$BOOT_SCRIPT" "$_verify_action"; then
			warn -c cli,vlan "Main target-version boot-state reconciliation failed"
		fi
		_verify_main_report=""
		if ! _verify_main_report=$(sh "$BOOT_SCRIPT" report 2>/dev/null); then
			warn -c cli,vlan "Main runtime retry report command failed"
		fi
	fi
	if ! runtime_report_matches "$_verify_main_report" main; then
		error -c cli,vlan "Main runtime verification failed after retry: ${_verify_main_report:-no report}"
		return 1
	fi
	info -c cli,vlan "Verified main runtime: configured-node baseline active, BOOT_ENABLED=$PRE_BOOT_ENABLED"
	[ "$_verify_scope" = "main" ] && return 0

	_verify_nodes=""
	if ! _verify_nodes=$(list_configured_nodes 2>/dev/null); then
		error -c cli,vlan "Could not read the configured-node set during update verification"
		return 1
	fi
	[ -n "$_verify_nodes" ] || return 0
	if ! ssh_keys_effectively_installed; then
		warn -c cli,vlan "Node runtime verification skipped because SSH keys are unavailable"
		UPDATE_PARTIAL=1
		return 0
	fi

	while read -r _verify_node_id _verify_node_ip; do
		[ -n "$_verify_node_ip" ] || continue
		_verify_remote="cd '$MERV_BASE/functions' && MERV_NODE_CONTEXT=1 sh ./mervlan_boot.sh report"
		_verify_node_report=""
		if ! _verify_node_report=$(merv_ssh_exec "$_verify_node_id" "$_verify_node_ip" "$_verify_remote" 2>/dev/null); then
			warn -c cli,vlan "NODE${_verify_node_id} ($_verify_node_ip) runtime report command failed"
		fi
		if ! runtime_report_matches "$_verify_node_report" node; then
			warn -c cli,vlan "NODE${_verify_node_id} ($_verify_node_ip) runtime mismatch; retrying target-version node reconciliation"
			_verify_remote="cd '$MERV_BASE/functions' && MERV_NODE_CONTEXT=1 sh ./mervlan_boot.sh nodeenable --local && MERV_NODE_CONTEXT=1 sh ./mervlan_boot.sh '$_verify_action' && MERV_NODE_CONTEXT=1 sh ./mervlan_boot.sh report"
			_verify_node_report=""
			if ! _verify_node_report=$(merv_ssh_exec "$_verify_node_id" "$_verify_node_ip" "$_verify_remote" 2>/dev/null); then
				warn -c cli,vlan "NODE${_verify_node_id} ($_verify_node_ip) retry report command failed"
			fi
		fi
		if runtime_report_matches "$_verify_node_report" node; then
			info -c cli,vlan "Verified NODE${_verify_node_id} ($_verify_node_ip): baseline active, BOOT_ENABLED=$PRE_BOOT_ENABLED"
		else
			warn -c cli,vlan "NODE${_verify_node_id} ($_verify_node_ip) runtime verification failed after retry: ${_verify_node_report:-no report}"
			UPDATE_PARTIAL=1
		fi
	done <<EOF
$_verify_nodes
EOF
	return 0
}


# Optionally refresh hardware profile on the upgraded installation
if [ -x "$HW_PROBE" ]; then
	info -c cli,vlan "Refreshing hardware profile via hw_probe.sh"
	if ! run_update_step "hardware probe" env MERV_UPDATE_OWNER=1 sh "$HW_PROBE"; then
		warn -c cli,vlan "hw_probe.sh reported errors; hardware profile may be stale"
		UPDATE_PARTIAL=1
	fi
else
	warn -c cli,vlan "hw_probe.sh not executable; skipping hardware probe refresh"
fi

# Ensure the public install view reflects the refreshed files before re-adding hooks
refresh_public_install || \
	fail_update refreshing_public "Target files were activated, but comprehensive public/runtime reprovisioning failed"
update_record_phase public-refresh || fail_update journal "Could not persist the public-refresh Update journal"

# Restore the main MAC DB: refresh_public_install runs uninstall.sh which can
# remove the DB. Restore it now so enable/nodeenable see the correct state.
# Capture return value: 0 = active DB restored (safe to push), 1 = active failed.
MAC_DB_RESTORE_OK=0
if [ "$MAC_DB_BACKUP_PRESENT" = "1" ]; then
    restore_main_mac_db_after_update && MAC_DB_RESTORE_OK=1 || MAC_DB_RESTORE_OK=0
fi

# Reapply target-version service/addon templates, establish every configured
# node baseline, then explicitly enforce BOOT_ENABLED in either direction.
if [ -x "$BOOT_SCRIPT" ]; then
	info -c cli,vlan "Re-applying MerVLAN hooks on the main router"

	# Main setup remains local until the target has been fully verified. Nodes
	# continue running their previous working tree during this phase.
	if ! run_update_step "main setupenable" env MERV_UPDATE_OWNER=1 MERV_SKIP_NODE_SYNC=1 sh "$BOOT_SCRIPT" setupenable; then
		warn -c cli,vlan "mervlan_boot.sh setupenable returned non-zero (continuing)"
		UPDATE_PARTIAL=1
	fi
	# PRE_BOOT_ENABLED is the authoritative pre-maintenance setting.  Always run
	# one target-version action so changed templates are refreshed or confirmed
	# absent instead of relying on pre-swap teardown side effects.
	if [ "$PRE_BOOT_ENABLED" = "1" ]; then
		info -c cli,vlan "PRE_BOOT_ENABLED=1; enabling MerVLAN boot on main router"
		if ! run_update_step "main enable" env MERV_UPDATE_OWNER=1 MERV_SKIP_NODE_SYNC=1 sh "$BOOT_SCRIPT" enable; then
			warn -c cli,vlan "mervlan_boot.sh enable returned non-zero (continuing)"
			UPDATE_PARTIAL=1
		fi
	else
		info -c cli,vlan "PRE_BOOT_ENABLED=0; enforcing disabled boot state with target templates"
		if ! run_update_step "main disable" env MERV_UPDATE_OWNER=1 MERV_SKIP_NODE_SYNC=1 sh "$BOOT_SCRIPT" disable; then
			warn -c cli,vlan "mervlan_boot.sh disable returned non-zero (continuing)"
			UPDATE_PARTIAL=1
		fi
	fi
else
	warn -c cli,vlan "mervlan_boot.sh not executable; skipping post-update hook setup"
	fail_update hooks "Target mervlan_boot.sh is unavailable; runtime reconciliation cannot continue"
fi

# Prove the main router is healthy before replacing a single node file.
verify_updated_runtime_state main || \
	fail_update reconciliation "Target runtime state could not be verified on the main router before node synchronization"
update_record_phase main-verified || fail_update journal "Could not persist the main-verified Update journal"

# Roll nodes forward one at a time. sync_nodes.sh validates a complete remote
# stage, swaps it, verifies nodeenable/report, and restores the old node tree on
# failure. An offline node remains on its previous working installation.
if ssh_keys_effectively_installed && has_configured_nodes; then
	UPDATE_NODES_TOUCHED="1"
	update_record_phase node-sync || fail_update journal "Could not persist the node-sync Update journal"
	if [ -x "$SYNC_SCRIPT" ]; then
		info -c cli,vlan "Synchronizing nodes with staged per-node activation"
		if ! run_update_step "post-update node synchronization" env MERV_UPDATE_OWNER=1 MERV_MAINTENANCE_SYNC=1 sh "$SYNC_SCRIPT"; then
			warn -c cli,vlan "One or more nodes retained their previous installation"
			UPDATE_PARTIAL=1
		fi
	else
		warn -c cli,vlan "sync_nodes.sh not executable; skipping node sync"
		UPDATE_PARTIAL=1
	fi
	_node_boot_action=disable
	[ "$PRE_BOOT_ENABLED" = "1" ] && _node_boot_action=enable
	if ! run_update_step "post-update node boot state" env MERV_UPDATE_OWNER=1 sh "$BOOT_SCRIPT" "$_node_boot_action"; then
		warn -c cli,vlan "Could not apply the saved boot state to every configured node"
		UPDATE_PARTIAL=1
	fi
else
	info -c cli,vlan "Node sync skipped (no nodes configured or SSH keys absent)"
fi

# Push the restored main MAC DB to all configured nodes so the cluster's
# shield state is consistent after the update.
# Only push when active DB restore succeeded: merv_mac_push_db_to_nodes reads
# MERV_MAC_DB_ACTIVE, so a failed active restore would push the wrong content.
if [ "$MAC_DB_BACKUP_PRESENT" = "1" ] && [ "$MAC_DB_RESTORE_OK" = "1" ] && \
   ssh_keys_effectively_installed && has_configured_nodes; then

	[ -n "${LIB_MERVQT_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mervqt.sh" 2>/dev/null || \
		{ warn -c cli,vlan "MERV_MAC: failed to load lib_mervqt.sh; restored db not pushed to nodes"; UPDATE_PARTIAL=1; }

	[ -n "${LIB_MAC_SHIELD_SNAPSHOT_LOADED:-}" ] || . "$MERV_BASE/settings/mac_shield_snapshot.sh" 2>/dev/null || \
		{ warn -c cli,vlan "MERV_MAC: failed to load mac_shield_snapshot.sh; restored db not pushed to nodes"; UPDATE_PARTIAL=1; }

	_push_nodes="$(list_configured_nodes 2>/dev/null)"

	if [ -z "$_push_nodes" ]; then
		warn -c cli,vlan "MERV_MAC: restored db not pushed; no configured nodes returned by list_configured_nodes"
		UPDATE_PARTIAL=1
	elif ! type merv_mac_push_db_to_nodes >/dev/null 2>&1; then
		warn -c cli,vlan "MERV_MAC: restored db not pushed; merv_mac_push_db_to_nodes unavailable"
		UPDATE_PARTIAL=1
	else
		MERV_MAC_LAST_PUSH_TOTAL=0
		MERV_MAC_LAST_PUSH_OK=0
		MERV_MAC_LAST_PUSH_FAILED=0
		merv_mac_push_db_to_nodes "$_push_nodes"
		info -c cli,vlan "MERV_MAC: restored db pushed to nodes ${MERV_MAC_LAST_PUSH_OK:-0}/${MERV_MAC_LAST_PUSH_TOTAL:-0}"
		[ "${MERV_MAC_LAST_PUSH_FAILED:-0}" = "0" ] || UPDATE_PARTIAL=1
	fi
fi

# Verify actual target state after every setup/node/boot action.  The main unit
# is essential and triggers rollback on a persistent mismatch; named node
# failures remain a truthful partial success so one offline AP does not discard
# an otherwise valid update.
verify_updated_runtime_state || \
	fail_update reconciliation "Target runtime state could not be verified on the main router"

# ========================================================================== #
# COMPRESS BACKUP AND PRUNE OLD ARCHIVES                                     #
# ========================================================================== #

# The durable backup was completed and validated before teardown. Confirm it is
# still present before publishing Undo Update.
if [ "$UPDATE_BACKUP_ARCHIVE_OK" != "1" ] || [ ! -f "$UPDATE_BACKUP_FINAL" ] || [ ! -f "$UPDATE_BACKUP_FINAL.meta" ]; then
	warn -c cli,vlan "Durable pre-update backup is no longer complete"
	UPDATE_BACKUP_ARCHIVE_OK=0
	UPDATE_PARTIAL=1
fi

# Keep only the 3 newest compressed backups
if [ -d "$MERVLAN_BACKUP_DIR" ]; then
	set -- "$MERVLAN_BACKUP_DIR"/mervlan.backup.*.tar.gz
	if [ -e "$1" ]; then
		BACKUPS_LIST="$(ls "$MERVLAN_BACKUP_DIR"/mervlan.backup.*.tar.gz 2>/dev/null | sort -r)"
		count=0
		for b in $BACKUPS_LIST; do
			count=$((count + 1))
			if [ "$count" -le 3 ]; then
				continue
			fi
			info -c cli,vlan "Removing old backup: $b"
			if ! update_cleanup_files "$b" "$b.meta"; then
				warn -c cli,vlan "Could not remove old backup $b"
				UPDATE_PARTIAL=1
			fi
		done
	fi
fi

# Update backup metadata in settings.json to reflect newest 3 backups
update_backup_metadata

NEW_VERSION=""
if [ -f "$MERV_BASE/changelog.txt" ]; then
	NEW_VERSION=$(sed -n '1{/^[[:space:]]*$/d;p;q}' "$MERV_BASE/changelog.txt" 2>/dev/null)
fi

# The automatic archive already contains the exact pre-update system. Keep only
# a volatile marker for the one-click Undo Update action instead of duplicating
# that archive in RAM. The shortcut disappears when /tmp is cleared or rebooted.
if [ "$UPDATE_BACKUP_ARCHIVE_OK" = "1" ] && \
   write_update_undo_marker "$CURRENT_BACKUP_NAME.tar.gz" "$OLD_VERSION" "$NEW_VERSION"; then
	info -c cli,vlan "Undo Update is available until the router reboots"
else
	if ! update_cleanup_files "$UPDATE_UNDO_MARKER"; then
		UPDATE_PRESERVE_TMP="1"
	fi
	warn -c cli,vlan "Update completed without a temporary Undo Update shortcut"
	UPDATE_PARTIAL=1
fi

# Publish the fresh mixed automatic/manual inventory for the Restore tab when
# the installed target contains the backup manager. Older downgrade targets do
# not have this optional file and continue without GUI backup management.
if [ -f "$MERV_BASE/functions/mervlan_backup.sh" ]; then
	run_update_step "backup inventory refresh" sh "$MERV_BASE/functions/mervlan_backup.sh" inventory "update-$$" || \
		{ warn -c cli,vlan "Could not refresh backup inventory after update"; UPDATE_PARTIAL=1; }
fi

# ========================================================================== #
# FINALIZATION                                                               #
# ========================================================================== #

if [ -n "$OLD_VERSION" ] || [ -n "$NEW_VERSION" ]; then
	info -c cli,vlan "MerVLAN version summary (update):"
	[ -n "$OLD_VERSION" ] && info -c cli,vlan "  From: $OLD_VERSION"
	[ -n "$NEW_VERSION" ] && info -c cli,vlan "  To:   $NEW_VERSION"
fi

if [ -f "$MERV_BASE/changelog.txt" ]; then
	info -c cli,vlan "Changelog (current version):"
	awk '
		/^#####/ { exit }
		{ print }
	' "$MERV_BASE/changelog.txt"
fi


# Do not report success while the maintenance marker is still suppressing
# normal manager/heal/boot work. A failed clear leaves the journal intact so
# the next boot enters the safe recovery path instead of running an ambiguous
# runtime state.
if ! merv_update_quiesce_clear; then
	update_record_phase finalization-failed "quiesce_marker_clear_failed" || :
	error -c cli,vlan "Update could not clear the maintenance-quiesce marker; recovery is required"
	type log_maintain_all >/dev/null 2>&1 && log_maintain_all
	exit 1
fi
UPDATE_QUIESCE_ACTIVE="0"
UPDATE_ACTIVATION_STARTED="0"
update_record_phase completed || {
	error -c cli,vlan "Update completed, but the final lifecycle journal could not be written"
	exit 1
}
if ! merv_update_journal_clear; then
	error -c cli,vlan "Update completed, but the lifecycle journal could not be cleared"
	exit 1
fi

if [ "$UPDATE_PARTIAL" = "1" ] && [ -f "$UPDATE_UNDO_MARKER" ]; then
	warn -c cli,vlan "MerVLAN update completed successfully with warnings. Undo Update is available until the router reboots; review the named warning entries above."
elif [ "$UPDATE_PARTIAL" = "1" ]; then
	warn -c cli,vlan "MerVLAN update completed successfully with warnings. Review the named warning entries above."
elif [ -f "$UPDATE_UNDO_MARKER" ]; then
	info -c cli,vlan "MerVLAN update completed successfully. Undo Update is available until the router reboots."
else
	info -c cli,vlan "MerVLAN update completed successfully"
fi
type log_maintain_all >/dev/null 2>&1 && log_maintain_all

exit 0
