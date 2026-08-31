#!/bin/sh
#
# ============================================================================ #
#                - File: mervlan_backup.sh || version="0.4"                   #
# ============================================================================ #
# Backup inventory, manual backup, deletion, and transactional restore engine. #
# Public CLI entry remains functions/update_mervlan.sh.                        #
# ============================================================================ #

: "${MERV_BASE:=/jffs/addons/mervlan}"
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh"
[ -n "${LIB_SSH_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssh.sh"
[ -n "${LIB_OWNER_LOCK_LOADED:-}" ] || . "$MERV_BASE/settings/lib_owner_lock.sh" 2>/dev/null || {
  error -c cli,vlan "Unable to load the owner-lock library; refusing maintenance operation"
  exit 1
}
[ -n "${LIB_MERVQT_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mervqt.sh" 2>/dev/null || {
  error -c cli,vlan "Unable to load the DHCP/L2 safety library; refusing maintenance operation"
  exit 1
}

cd /tmp 2>/dev/null || cd / 2>/dev/null || {
  error -c cli,vlan "Unable to enter a safe temporary directory; refusing maintenance operation"
  exit 1
}
[ -f /usr/sbin/helper.sh ] && . /usr/sbin/helper.sh

readonly MB_TMP_ROOT="${MERVLAN_TMP_ROOT_OVERRIDE:-${TMPDIR:-/tmp/mervlan_tmp}}"
readonly MB_WORK_ROOT="$MB_TMP_ROOT/backup_manager.$$"
readonly MB_BACKUP_ROOT="${MERVLAN_BACKUP_DIR_OVERRIDE:-${MERV_BASE%/*}/mervlan_backups}"
readonly MB_PUBLIC_ROOT="${MERVLAN_PUBLIC_ROOT_OVERRIDE:-${PUBLIC_MERV_BASE:-/www/user/mervlan}}"
readonly MB_WWW_USER_ROOT="${MERVLAN_WWW_USER_ROOT_OVERRIDE:-/www/user}"
readonly MB_PUBLIC_RESULTS="${MERVLAN_PUBLIC_RESULTS_OVERRIDE:-$MB_PUBLIC_ROOT/tmp/results}"
readonly MB_INVENTORY_FILE="$MB_PUBLIC_RESULTS/backup_inventory.json"
readonly MB_RESULT_FILE="$MB_PUBLIC_RESULTS/maintenance_result.json"
readonly MB_LOCK="${MERVLAN_MAINTENANCE_LOCK_OVERRIDE:-${LOCKDIR:-$MB_TMP_ROOT/locks}/mervlan_maintenance.lock}"
readonly MB_UNDO_ROOT="${MERVLAN_UNDO_DIR_OVERRIDE:-$MB_TMP_ROOT/undo}"
readonly MB_UNDO_RESTORE_ARCHIVE="$MB_UNDO_ROOT/mervlan.undo.restore.tar.gz"
readonly MB_UNDO_RESTORE_META="$MB_UNDO_ROOT/restore.meta"
readonly MB_UNDO_UPDATE_MARKER="$MB_UNDO_ROOT/update.meta"
readonly MB_RECOVERY_SOURCE="$MERV_BASE/functions/mervlan_recover.sh"
readonly MB_RECOVERY_SCRIPT="$MB_BACKUP_ROOT/recover.sh"
readonly MB_JFFS_STAGE="$MB_BACKUP_ROOT/.mervlan.new.$$"
readonly MB_JFFS_OLD="$MB_BACKUP_ROOT/.mervlan.old.$$"
readonly MB_MANUAL_LIMIT=3
readonly MB_AUTO_LIMIT=3
readonly MB_TEST_MODE="${MERVLAN_BACKUP_TEST_MODE:-0}"
MB_JFFS_RESERVE_KB="${MERV_BACKUP_JFFS_RESERVE_KB:-5120}"
case "$MB_JFFS_RESERVE_KB" in
  ''|*[!0-9]*|0) MB_JFFS_RESERVE_KB="5120" ;;
esac
readonly MB_TEST_FAIL_PHASE="${MERVLAN_BACKUP_TEST_FAIL_PHASE:-}"
readonly MB_TEST_PAUSE_PHASE="${MERVLAN_BACKUP_TEST_PAUSE_PHASE:-}"
readonly MB_TEST_PAUSE_SECONDS="${MERVLAN_BACKUP_TEST_PAUSE_SECONDS:-5}"

MB_LOCK_OWNED=0
MB_REQUEST_TOKEN=""
MB_OPERATION=""
MB_TARGET=""
MB_UNDO_CLEANUP_WARNING=0
MB_SIGNAL_HANDLING=0
MB_ACTIVATION_STARTED=0
MB_ROLLBACK_DONE=0
MB_PRESERVE_WORK=0
MB_PRESERVE_JFFS=0
MB_RESTORE_ORIGINAL=""
MB_RESTORE_ORIGINAL_BOOT=0
MB_POOL_ABORT_FAILED=0
mb_pool_state_unresolved() {
  if type mnj_pool_state_unresolved >/dev/null 2>&1; then
    mnj_pool_state_unresolved
    return $?
  fi
  case "${MNJ_POOL_ACTIVE:-0}" in ''|0) return 1 ;; *) return 0 ;; esac
}

mb_abort_node_pool() {
  mb_pool_state_unresolved || return 0
  if ! type mnj_pool_abort_active >/dev/null 2>&1; then
    MB_POOL_ABORT_FAILED=1
    error -c cli,vlan "Maintenance cleanup could not reconcile active node workers; retaining locks and recovery state"
    return 1
  fi
  if ! mnj_pool_abort_active failed backup-exit; then
    MB_POOL_ABORT_FAILED=1
    error -c cli,vlan "Maintenance cleanup could not stop and reconcile active node workers; retaining locks and recovery state"
    return 1
  fi
  if ! mb_pool_state_unresolved; then MB_POOL_ABORT_FAILED=0; return 0; fi
  MB_POOL_ABORT_FAILED=1
  error -c cli,vlan "Maintenance cleanup left active node workers unresolved; retaining locks and recovery state"
  return 1
}

mb_remove_jffs_stage() {
  _mb_stage_path="$1"
    case "$_mb_stage_path" in
    "$MB_BACKUP_ROOT"/.mervlan.new.*|"$MB_BACKUP_ROOT"/.mervlan.old.*)
      [ -e "$_mb_stage_path" ] || return 0
      rm -rf "$_mb_stage_path" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

mb_reconcile_stale_stages() {
  _mb_active_valid=1
  _mb_stale_cleanup_failed=0
  for _mb_required in install.sh uninstall.sh changelog.txt mervlan.asp \
    functions/update_mervlan.sh functions/mervlan_boot.sh settings/settings.json www/index.html
  do
    [ -f "$MERV_BASE/$_mb_required" ] || _mb_active_valid=0
  done
  if [ "$_mb_active_valid" != "1" ]; then
    warn -c cli,vlan "Active installation is incomplete; preserving all .mervlan.new/.mervlan.old recovery trees"
    return 0
  fi
  for _mb_stale in "$MB_BACKUP_ROOT"/.mervlan.new.*; do
    [ -d "$_mb_stale" ] || continue
    if ! mb_remove_jffs_stage "$_mb_stale"; then
      warn -c cli,vlan "Could not remove stale restore stage $_mb_stale"
      _mb_stale_cleanup_failed=1
    fi
  done
  for _mb_stale in "$MB_BACKUP_ROOT"/.mervlan.old.*; do
    [ -d "$_mb_stale" ] || continue
    if ! mb_remove_jffs_stage "$_mb_stale"; then
      warn -c cli,vlan "Could not remove stale rollback tree $_mb_stale"
      _mb_stale_cleanup_failed=1
    fi
  done
  [ "$_mb_stale_cleanup_failed" -eq 0 ]
}

mb_cleanup() {
  _mb_cleanup_rc=$?
  _mb_cleanup_failed=0
  _mb_pool_cleanup_ready=1
  if ! mb_abort_node_pool; then
    _mb_pool_cleanup_ready=0
    _mb_cleanup_failed=1
    MB_PRESERVE_WORK=1
    MB_PRESERVE_JFFS=1
  fi
  if [ "$_mb_pool_cleanup_ready" = "1" ]; then
    if [ "$MB_PRESERVE_JFFS" != "1" ]; then
      mb_remove_jffs_stage "$MB_JFFS_STAGE" || _mb_cleanup_failed=1
    fi
    if [ "$MB_PRESERVE_JFFS" != "1" ] && [ "$MB_ACTIVATION_STARTED" != "1" ]; then
      mb_remove_jffs_stage "$MB_JFFS_OLD" || _mb_cleanup_failed=1
    fi
    if [ "$MB_PRESERVE_WORK" != "1" ] && [ -d "$MB_WORK_ROOT" ]; then
      rm -rf "$MB_WORK_ROOT" 2>/dev/null || _mb_cleanup_failed=1
    fi
    if [ "$MB_LOCK_OWNED" = "1" ]; then
      if type merv_owner_lock_release >/dev/null 2>&1 && merv_owner_lock_release "$MB_LOCK" "${MERV_LOCK_NONCE:-}" 2>/dev/null; then
        MB_LOCK_OWNED=0
      else
        _mb_cleanup_failed=1
        error -c cli,vlan "Maintenance cleanup could not release its owner lock; recovery is required"
      fi
    fi
    case "${MB_OPERATION:-}" in
      ""|backup_inventory) ;;
      *) if type log_maintain_all >/dev/null 2>&1; then log_maintain_all || _mb_cleanup_failed=1; fi ;;
    esac
  else
    error -c cli,vlan "Maintenance cleanup preserved recovery data and owner lock because active node workers remain unresolved"
  fi
  [ "$_mb_cleanup_failed" -eq 0 ] || _mb_cleanup_rc=1
  return "$_mb_cleanup_rc"
}

mb_handle_signal() {
  _mb_signal_status="$1"
  [ "$MB_SIGNAL_HANDLING" = "0" ] || exit "$_mb_signal_status"
  MB_SIGNAL_HANDLING=1
  trap - INT TERM
  warn -c cli,vlan "Maintenance operation interrupted; stopping safely"
  _mb_signal_pool_ready=1
  if ! mb_abort_node_pool; then
    _mb_signal_pool_ready=0
    MB_PRESERVE_WORK=1
    MB_PRESERVE_JFFS=1
  fi
  if [ "$_mb_signal_pool_ready" = "1" ] && [ "$MB_ACTIVATION_STARTED" = "1" ] && [ "$MB_ROLLBACK_DONE" != "1" ] && \
     [ -n "$MB_RESTORE_ORIGINAL" ] && [ -d "$MB_RESTORE_ORIGINAL" ]; then
    if ! mb_rollback_restore "$MB_RESTORE_ORIGINAL" "$MB_RESTORE_ORIGINAL_BOOT"; then
      MB_PRESERVE_WORK=1
      error -c cli,vlan "Automatic rollback failed; temporary recovery data remains at $MB_WORK_ROOT"
    fi
  fi
  if [ "$_mb_signal_pool_ready" = "1" ]; then
    mb_write_result interrupted signal "Operation interrupted. Automatic rollback was attempted when required."
  else
    mb_write_result interrupted signal "Operation interrupted. Active node workers could not be reconciled; recovery data and the owner lock were preserved."
  fi
  exit "$_mb_signal_status"
}

trap mb_cleanup EXIT
trap 'mb_handle_signal 130' INT
trap 'mb_handle_signal 143' TERM

mb_json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g; s/\t/\\t/g'
}

mb_make_token() {
  _mb_token=$(printf '%s' "$1" | tr -cd 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-')
  [ -n "$_mb_token" ] || _mb_token="cli-$$-$(date +%s 2>/dev/null)"
  printf '%s' "$_mb_token"
}

mb_test_pause() {
  [ "$MB_TEST_MODE" = "1" ] || return 0
  [ "$MB_TEST_PAUSE_PHASE" = "$1" ] || return 0
  _mb_pause_seconds="$MB_TEST_PAUSE_SECONDS"
  case "$_mb_pause_seconds" in ''|*[!0-9]*) _mb_pause_seconds=5 ;; esac
  [ "$_mb_pause_seconds" -le 30 ] || _mb_pause_seconds=30
  sleep "$_mb_pause_seconds"
}

mb_path_size_kb() {
  _mb_size_path="$1"
  [ -e "$_mb_size_path" ] || { printf '0'; return 0; }
  _mb_size_value=$(du -sk "$_mb_size_path" 2>/dev/null | awk 'NR == 1 { print $1 }')
  case "$_mb_size_value" in ''|*[!0-9]*) _mb_size_value=0 ;; esac
  printf '%s' "$_mb_size_value"
}

mb_fs_stats_kb() {
  _mb_stats_path="$1"
  while [ ! -e "$_mb_stats_path" ] && [ "$_mb_stats_path" != "/" ]; do
    _mb_stats_path=${_mb_stats_path%/*}
    [ -n "$_mb_stats_path" ] || _mb_stats_path=/
  done
  df -Pk "$_mb_stats_path" 2>/dev/null | awk 'NR == 2 { print $2 "|" $4 }'
}

mb_fs_id() {
  _mb_id_path="$1"
  while [ ! -e "$_mb_id_path" ] && [ "$_mb_id_path" != "/" ]; do
    _mb_id_path=${_mb_id_path%/*}
    [ -n "$_mb_id_path" ] || _mb_id_path=/
  done
  df -Pk "$_mb_id_path" 2>/dev/null | awk 'NR == 2 { print $1 }'
}

mb_number_or_zero() {
  case "$1" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$1" ;; esac
}

mb_settings_file_valid() {
  _mb_settings_file="$1"
  [ -s "$_mb_settings_file" ] || return 1
  for _mb_settings_key in General SSH Nodes SSH_USER SSH_PORT; do
    grep -q "\"${_mb_settings_key}\"[[:space:]]*:" "$_mb_settings_file" 2>/dev/null || return 1
  done
  _mb_settings_opens=$(tr -cd '{' < "$_mb_settings_file" 2>/dev/null | wc -c | tr -d '[:space:]')
  _mb_settings_closes=$(tr -cd '}' < "$_mb_settings_file" 2>/dev/null | wc -c | tr -d '[:space:]')
  [ -n "$_mb_settings_opens" ] && [ "$_mb_settings_opens" = "$_mb_settings_closes" ]
}

mb_checksum_value() {
  type md5sum >/dev/null 2>&1 || return 1
  md5sum "$1" 2>/dev/null | awk 'NR == 1 { print $1 }'
}

mb_prepare_archive_metadata() {
  _mb_meta_archive="$1"
  _mb_meta_id="$2"
  _mb_meta_output="$3"
  mb_is_archive_id "$_mb_meta_id" || return 1
  _mb_meta_checksum=$(mb_checksum_value "$_mb_meta_archive") || return 1
  case "$_mb_meta_checksum" in ''|*[!0123456789abcdefABCDEF]*) return 1 ;; esac
  [ "${#_mb_meta_checksum}" -eq 32 ] || return 1
  {
    printf 'format=1\n'
    printf 'archive=%s\n' "$_mb_meta_id"
    printf 'algorithm=md5\n'
    printf 'checksum=%s\n' "$_mb_meta_checksum"
    printf 'created=%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
  } > "$_mb_meta_output" 2>/dev/null || return 1
  chmod 600 "$_mb_meta_output" 2>/dev/null || return 1
}

mb_metadata_value() {
  _mb_metadata_file="$1"
  _mb_metadata_key="$2"
  [ -f "$_mb_metadata_file" ] || return 1
  sed -n "s/^${_mb_metadata_key}=//p" "$_mb_metadata_file" 2>/dev/null | tail -n1
}

mb_verify_archive_integrity() {
  _mb_integrity_archive="$1"
  _mb_integrity_id=${_mb_integrity_archive##*/}
  _mb_integrity_meta="${_mb_integrity_archive}.meta"
  [ -f "$_mb_integrity_archive" ] || return 1
  # Backups created before integrity metadata was introduced remain supported;
  # their archive tree is still fully validated before restore.
  [ -f "$_mb_integrity_meta" ] || return 0
  [ "$(mb_metadata_value "$_mb_integrity_meta" format)" = "1" ] || return 1
  [ "$(mb_metadata_value "$_mb_integrity_meta" archive)" = "$_mb_integrity_id" ] || return 1
  [ "$(mb_metadata_value "$_mb_integrity_meta" algorithm)" = "md5" ] || return 1
  _mb_integrity_expected=$(mb_metadata_value "$_mb_integrity_meta" checksum)
  _mb_integrity_actual=$(mb_checksum_value "$_mb_integrity_archive") || return 1
  [ -n "$_mb_integrity_expected" ] && [ "$_mb_integrity_expected" = "$_mb_integrity_actual" ]
}

mb_install_recovery_helper() {
  [ -f "$MB_RECOVERY_SOURCE" ] || return 1
  mkdir -p "$MB_BACKUP_ROOT" 2>/dev/null || return 1
  chmod 700 "$MB_BACKUP_ROOT" 2>/dev/null || return 1
  _mb_recovery_tmp="$MB_BACKUP_ROOT/.recover.sh.partial.$$"
  rm -f "$_mb_recovery_tmp" 2>/dev/null || return 1
  cp -p "$MB_RECOVERY_SOURCE" "$_mb_recovery_tmp" 2>/dev/null || return 1
  chmod 700 "$_mb_recovery_tmp" 2>/dev/null || {
    if ! rm -f "$_mb_recovery_tmp" 2>/dev/null; then
      warn -c cli,vlan "Recovery helper permission setup failed and its temporary file could not be removed"
    fi
    return 1
  }
  mv -f "$_mb_recovery_tmp" "$MB_RECOVERY_SCRIPT" 2>/dev/null || {
    if ! rm -f "$_mb_recovery_tmp" 2>/dev/null; then
      warn -c cli,vlan "Recovery helper publication failed and its temporary file could not be removed"
    fi
    return 1
  }
}

mb_remove_archive_artifacts() {
  _mb_remove_archive="$1"
  rm -f "$_mb_remove_archive" "${_mb_remove_archive}.meta" 2>/dev/null
}

mb_public_asp_path() {
  _mb_asp="${MERVLAN_PUBLIC_ASP_OVERRIDE:-}"
  if [ -z "$_mb_asp" ] && type am_settings_get >/dev/null 2>&1; then
    _mb_page=$(am_settings_get mervlan_page 2>/dev/null)
    _mb_page_number=${_mb_page#user}
    _mb_page_number=${_mb_page_number%.asp}
    case "$_mb_page" in
      user*.asp)
        case "$_mb_page_number" in ''|*[!0-9]*) : ;; *) _mb_asp="$MB_WWW_USER_ROOT/$_mb_page" ;; esac
        ;;
    esac
  fi
  [ -n "$_mb_asp" ] && [ -f "$_mb_asp" ] && printf '%s' "$_mb_asp"
}

# Collect broad informational storage totals without changing the exact
# destination-specific preflight checks used by backup, update, and restore.
# Public links are measured without -L, so JFFS settings and /tmp logs are not
# followed and counted a second time.
mb_collect_managed_storage() {
  _mb_jffs_used=$(mb_path_size_kb "$MERV_BASE")
  case "$MB_BACKUP_ROOT/" in
    "$MERV_BASE/"*) ;;
    *) _mb_jffs_used=$((_mb_jffs_used + $(mb_path_size_kb "$MB_BACKUP_ROOT"))) ;;
  esac
  for _mb_residue in \
    "${MERV_BASE%/*}"/.mervlan.restore-stage.* \
    "${MERV_BASE%/*}"/.mervlan.restore-old.*
  do
    [ -e "$_mb_residue" ] || continue
    _mb_jffs_used=$((_mb_jffs_used + $(mb_path_size_kb "$_mb_residue")))
  done

  _mb_tmp_used=$(mb_path_size_kb "$MB_TMP_ROOT")
  _mb_www_used=$(mb_path_size_kb "$MB_PUBLIC_ROOT")
  _mb_public_asp=$(mb_public_asp_path)
  if [ -n "$_mb_public_asp" ]; then
    case "$_mb_public_asp/" in
      "$MB_PUBLIC_ROOT/"*) ;;
      *) _mb_www_used=$((_mb_www_used + $(mb_path_size_kb "$_mb_public_asp"))) ;;
    esac
  fi

  _mb_jffs_stats=$(mb_fs_stats_kb "$MERV_BASE")
  MB_STORAGE_JFFS_TOTAL=$(mb_number_or_zero "${_mb_jffs_stats%%|*}")
  MB_STORAGE_JFFS_AVAILABLE=$(mb_number_or_zero "${_mb_jffs_stats#*|}")
  MB_STORAGE_JFFS_USED=$(mb_number_or_zero "$_mb_jffs_used")

  _mb_tmp_stats=$(mb_fs_stats_kb "$MB_TMP_ROOT")
  MB_STORAGE_TMP_TOTAL=$(mb_number_or_zero "${_mb_tmp_stats%%|*}")
  MB_STORAGE_TMP_AVAILABLE=$(mb_number_or_zero "${_mb_tmp_stats#*|}")
  MB_STORAGE_TMP_USED=$(mb_number_or_zero "$_mb_tmp_used")

  _mb_www_stats=$(mb_fs_stats_kb "$MB_PUBLIC_ROOT")
  MB_STORAGE_WWW_TOTAL=$(mb_number_or_zero "${_mb_www_stats%%|*}")
  MB_STORAGE_WWW_AVAILABLE=$(mb_number_or_zero "${_mb_www_stats#*|}")
  MB_STORAGE_WWW_USED=$(mb_number_or_zero "$_mb_www_used")

  MB_STORAGE_RAM_COMBINED=false
  MB_STORAGE_RAM_USED=0
  MB_STORAGE_RAM_TOTAL=0
  MB_STORAGE_RAM_AVAILABLE=0
  _mb_tmp_fs=$(mb_fs_id "$MB_TMP_ROOT")
  _mb_www_fs=$(mb_fs_id "$MB_PUBLIC_ROOT")
  if [ -n "$_mb_tmp_fs" ] && [ "$_mb_tmp_fs" = "$_mb_www_fs" ]; then
    MB_STORAGE_RAM_COMBINED=true
    MB_STORAGE_RAM_USED=$((MB_STORAGE_TMP_USED + MB_STORAGE_WWW_USED))
    MB_STORAGE_RAM_TOTAL=$MB_STORAGE_TMP_TOTAL
    MB_STORAGE_RAM_AVAILABLE=$MB_STORAGE_TMP_AVAILABLE
  fi
}

mb_require_space_kb() {
  _mb_space_path="$1"
  _mb_space_required="$2"
  _mb_space_label="$3"
  [ "$MB_TEST_MODE" = "1" ] && return 0
  case "$_mb_space_required" in ''|*[!0-9]*) _mb_space_required=0 ;; esac
  _mb_space_stats=$(mb_fs_stats_kb "$_mb_space_path")
  _mb_space_total=${_mb_space_stats%%|*}
  _mb_space_available=${_mb_space_stats#*|}
  case "$_mb_space_total" in ''|*[!0-9]*) MB_SPACE_MESSAGE="Could not determine total space for $_mb_space_label."; return 1 ;; esac
  case "$_mb_space_available" in ''|*[!0-9]*) MB_SPACE_MESSAGE="Could not determine available space for $_mb_space_label."; return 1 ;; esac
  case "$_mb_space_path" in
    /jffs|/jffs/*) _mb_space_reserve="$MB_JFFS_RESERVE_KB" ;;
    *)
      _mb_space_reserve=$((_mb_space_total / 20))
      [ "$_mb_space_reserve" -ge 2048 ] || _mb_space_reserve=2048
      ;;
  esac
  _mb_space_needed=$((_mb_space_required + _mb_space_reserve))
  if [ "$_mb_space_available" -lt "$_mb_space_needed" ]; then
    MB_SPACE_MESSAGE="Insufficient $_mb_space_label space: need ${_mb_space_needed} KB including reserve ${_mb_space_reserve} KB, available ${_mb_space_available} KB."
    return 1
  fi
  return 0
}

mb_archive_expanded_kb() {
  _mb_expanded_bytes=$(gzip -dc "$1" 2>/dev/null | wc -c | tr -d '[:space:]')
  case "$_mb_expanded_bytes" in ''|*[!0-9]*) printf '0'; return ;; esac
  printf '%s' "$(((_mb_expanded_bytes + 1023) / 1024))"
}

mb_meta_line() {
  _mb_meta_file="$1"
  _mb_meta_number="$2"
  [ -f "$_mb_meta_file" ] || return 0
  sed -n "${_mb_meta_number}p" "$_mb_meta_file" 2>/dev/null
}

mb_update_undo_archive() {
  _mb_update_id=$(mb_meta_line "$MB_UNDO_UPDATE_MARKER" 1)
  mb_is_archive_id "$_mb_update_id" || return 1
  [ -f "$MB_BACKUP_ROOT/$_mb_update_id" ] || return 1
  printf '%s' "$MB_BACKUP_ROOT/$_mb_update_id"
}

mb_write_result() {
  _mb_state="$1"
  _mb_phase="$2"
  shift 2
  _mb_message="$*"
  mkdir -p "$MB_PUBLIC_RESULTS" 2>/dev/null || return 1
  _mb_tmp="$MB_RESULT_FILE.$$"
  printf '{"request_token":"%s","operation":"%s","state":"%s","phase":"%s","target":"%s","message":"%s","timestamp":%s}\n' \
    "$(mb_json_escape "$MB_REQUEST_TOKEN")" \
    "$(mb_json_escape "$MB_OPERATION")" \
    "$(mb_json_escape "$_mb_state")" \
    "$(mb_json_escape "$_mb_phase")" \
    "$(mb_json_escape "$MB_TARGET")" \
    "$(mb_json_escape "$_mb_message")" \
    "$(date +%s 2>/dev/null || echo 0)" > "$_mb_tmp" 2>/dev/null || return 1
  if ! chmod 644 "$_mb_tmp" 2>/dev/null; then
    rm -f "$_mb_tmp" 2>/dev/null
    return 1
  fi
  if ! mv -f "$_mb_tmp" "$MB_RESULT_FILE" 2>/dev/null; then
    if ! rm -f "$_mb_tmp" 2>/dev/null; then
      warn -c cli,vlan "Maintenance result publication failed and its temporary file could not be removed"
    fi
    return 1
  fi
  return 0
}

mb_fail() {
  _mb_phase="$1"
  shift
  _mb_message="$*"
  error -c cli,vlan "$_mb_message"
  if ! mb_write_result error "$_mb_phase" "$_mb_message"; then
    warn -c cli,vlan "Could not publish the maintenance failure result"
  fi
  return 1
}

mb_acquire_lock() {
  mkdir -p "${MB_LOCK%/*}" 2>/dev/null || return 1
  type merv_owner_lock_acquire >/dev/null 2>&1 || return 1
  if merv_owner_lock_acquire "$MB_LOCK" 1800 2 "mervlan_maintenance"; then
    MB_LOCK_OWNED=1
    MB_LOCK_NONCE="${MERV_LOCK_NONCE:-}"
    # Public refresh children must prove this exact live owner tuple.  A
    # Boolean maintenance flag alone is intentionally not authority.
    MERV_MAINTENANCE_DELEGATED=1
    MERV_MAINTENANCE_DELEGATION_KIND=backup
    MERV_BACKUP_DELEGATION=1
    MERV_MAINTENANCE_OWNER_PID="$$"
    MERV_MAINTENANCE_OWNER_START="${MERV_LOCK_START:-}"
    MERV_MAINTENANCE_OWNER_NONCE="$MB_LOCK_NONCE"
    export MERV_MAINTENANCE_DELEGATED MERV_MAINTENANCE_DELEGATION_KIND \
      MERV_BACKUP_DELEGATION \
      MERV_MAINTENANCE_OWNER_PID MERV_MAINTENANCE_OWNER_START \
      MERV_MAINTENANCE_OWNER_NONCE
    return 0
  fi
  return 1
}

mb_require_lock() {
  if mb_acquire_lock; then
    if ! mb_reconcile_stale_stages; then
      error -c cli,vlan "Stale restore or rollback trees could not be reconciled; maintenance is blocked"
      if type merv_owner_lock_release >/dev/null 2>&1 && merv_owner_lock_release "$MB_LOCK" "${MERV_LOCK_NONCE:-}" 2>/dev/null; then
        MB_LOCK_OWNED=0
      else
        error -c cli,vlan "Maintenance cleanup could not release its owner lock after stale-tree failure"
      fi
      return 1
    fi
    return 0
  fi
  _mb_busy_message="Another MerVLAN update, backup, restore, or deletion is already running."
  warn -c cli,vlan "$_mb_busy_message"
  mb_write_result busy busy "$_mb_busy_message"
  return 1
}

mb_is_archive_id() {
  _mb_id="$1"
  [ -n "$_mb_id" ] || return 1
  [ "${_mb_id##*/}" = "$_mb_id" ] || return 1
  case "$_mb_id" in *..*|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*) return 1 ;; esac
  printf '%s\n' "$_mb_id" | grep -Eq '^mervlan\.backup\.[A-Za-z0-9_-]+\.tar\.gz$|^mervlan\.manual\.backup\.[0-9]{8}-[0-9]{6}\.[A-Za-z0-9][A-Za-z0-9_-]{0,23}\.tar\.gz$'
}

mb_archive_type() {
  case "$1" in mervlan.manual.backup.*) printf 'manual' ;; *) printf 'automatic' ;; esac
}

mb_archive_timestamp() {
  _mb_id="$1"
  case "$_mb_id" in
    mervlan.manual.backup.*) _mb_tail=${_mb_id#mervlan.manual.backup.} ;;
    mervlan.backup.*) _mb_tail=${_mb_id#mervlan.backup.} ;;
    *) _mb_tail="" ;;
  esac
  printf '%s' "$_mb_tail" | cut -c1-15
}

mb_archive_tag() {
  _mb_id="$1"
  case "$_mb_id" in
    mervlan.manual.backup.*.tar.gz)
      _mb_tag=${_mb_id#mervlan.manual.backup.}
      _mb_tag=${_mb_tag#????????-??????.}
      _mb_tag=${_mb_tag%.tar.gz}
      printf '%s' "$_mb_tag"
      ;;
    *) printf '' ;;
  esac
}

mb_timestamp_display() {
  _mb_ts="$1"
  if printf '%s\n' "$_mb_ts" | grep -Eq '^[0-9]{8}-[0-9]{6}$'; then
    printf '%s-%s-%s %s:%s:%s' \
      "$(printf '%s' "$_mb_ts" | cut -c1-4)" \
      "$(printf '%s' "$_mb_ts" | cut -c5-6)" \
      "$(printf '%s' "$_mb_ts" | cut -c7-8)" \
      "$(printf '%s' "$_mb_ts" | cut -c10-11)" \
      "$(printf '%s' "$_mb_ts" | cut -c12-13)" \
      "$(printf '%s' "$_mb_ts" | cut -c14-15)"
  else
    printf 'unknown'
  fi
}

mb_list_paths() {
  [ -d "$MB_BACKUP_ROOT" ] || return 0
  for _mb_path in "$MB_BACKUP_ROOT"/mervlan.backup.*.tar.gz "$MB_BACKUP_ROOT"/mervlan.manual.backup.*.tar.gz; do
    [ -f "$_mb_path" ] || continue
    mb_is_archive_id "${_mb_path##*/}" || continue
    printf '%s\n' "$_mb_path"
  done | sort -r
}

mb_count_type() {
  _mb_wanted="$1"
  _mb_count=0
  for _mb_path in $(mb_list_paths); do
    [ "$(mb_archive_type "${_mb_path##*/}")" = "$_mb_wanted" ] || continue
    _mb_count=$((_mb_count + 1))
  done
  printf '%s' "$_mb_count"
}

mb_resolve_selection() {
  _mb_selection="$1"
  case "$_mb_selection" in
    ''|*[!0-9]*) ;;
    *)
      _mb_index=0
      for _mb_path in $(mb_list_paths); do
        _mb_index=$((_mb_index + 1))
        if [ "$_mb_index" = "$_mb_selection" ]; then
          printf '%s' "$_mb_path"
          return 0
        fi
      done
      return 1
      ;;
  esac
  mb_is_archive_id "$_mb_selection" || return 1
  _mb_path="$MB_BACKUP_ROOT/$_mb_selection"
  [ -f "$_mb_path" ] || return 1
  printf '%s' "$_mb_path"
}

mb_archive_member_types_safe() {
  _mb_archive="$1"
  mkdir -p "$MB_WORK_ROOT" 2>/dev/null || return 1
  LC_ALL=C tar -tvzf "$_mb_archive" > "$MB_WORK_ROOT/archive.verbose" 2>/dev/null || return 1
  [ -s "$MB_WORK_ROOT/archive.verbose" ] || return 1
  # Restore archives only need directories and regular files. Reject links,
  # devices, and other special members before extraction so they cannot affect
  # paths outside the same-filesystem staging directory.
  awk '
    {
      member_type = substr($0, 1, 1)
      if (member_type != "-" && member_type != "d") unsafe = 1
    }
    END { exit unsafe }
  ' "$MB_WORK_ROOT/archive.verbose"
}

mb_archive_version() {
  _mb_archive="$1"
  mkdir -p "$MB_WORK_ROOT/version" 2>/dev/null || { printf 'unknown'; return; }
  rm -rf "$MB_WORK_ROOT/version"/* 2>/dev/null || { printf 'unknown'; return; }
  mb_archive_member_types_safe "$_mb_archive" || { printf 'unknown'; return; }
  _mb_changelog=$(tar -tzf "$_mb_archive" 2>/dev/null | awk '/(^|\/)changelog\.txt$/ { print; exit }')
  case "$_mb_changelog" in ''|/*|*../*) printf 'unknown'; return ;; esac
  tar -xzf "$_mb_archive" -C "$MB_WORK_ROOT/version" "$_mb_changelog" >/dev/null 2>&1 || { printf 'unknown'; return; }
  _mb_line=$(sed -n '1{/^[[:space:]]*$/d;p;q}' "$MB_WORK_ROOT/version/$_mb_changelog" 2>/dev/null)
  _mb_candidate=${_mb_line##* }
  case "$_mb_candidate" in v[0-9]*) printf '%s' "$_mb_candidate" ;; *) printf 'unknown' ;; esac
}

mb_write_inventory() {
  _mb_output="${1:-$MB_INVENTORY_FILE}"
  mkdir -p "$MB_PUBLIC_RESULTS" "$MB_WORK_ROOT" 2>/dev/null || return 1
  _mb_tmp="$MB_WORK_ROOT/inventory.json"
  _mb_first=1
  _mb_auto=$(mb_count_type automatic)
  _mb_manual=$(mb_count_type manual)
  _mb_persistent_stats=$(mb_fs_stats_kb "$MB_BACKUP_ROOT")
  _mb_persistent_total=${_mb_persistent_stats%%|*}
  _mb_persistent_available=${_mb_persistent_stats#*|}
  _mb_temporary_stats=$(mb_fs_stats_kb "$MB_UNDO_ROOT")
  _mb_temporary_total=${_mb_temporary_stats%%|*}
  _mb_temporary_available=${_mb_temporary_stats#*|}
  for _mb_number_name in _mb_persistent_total _mb_persistent_available _mb_temporary_total _mb_temporary_available; do
    eval "_mb_number_value=\${$_mb_number_name}"
    case "$_mb_number_value" in ''|*[!0-9]*) _mb_number_value=0 ;; esac
    eval "$_mb_number_name=\$_mb_number_value"
  done
  _mb_persistent_used=$(mb_path_size_kb "$MB_BACKUP_ROOT")
  _mb_temporary_used=$(mb_path_size_kb "$MB_UNDO_ROOT")
  mb_collect_managed_storage
  _mb_undo_restore_available=false
  _mb_undo_restore_size=0
  _mb_undo_restore_version=unknown
  _mb_undo_restore_created=unknown
  if [ -f "$MB_UNDO_RESTORE_ARCHIVE" ]; then
    _mb_undo_restore_available=true
    _mb_undo_restore_size=$(wc -c < "$MB_UNDO_RESTORE_ARCHIVE" 2>/dev/null | tr -d '[:space:]')
    case "$_mb_undo_restore_size" in ''|*[!0-9]*) _mb_undo_restore_size=0 ;; esac
    _mb_undo_restore_version=$(mb_meta_line "$MB_UNDO_RESTORE_META" 2)
    [ -n "$_mb_undo_restore_version" ] || _mb_undo_restore_version=$(mb_archive_version "$MB_UNDO_RESTORE_ARCHIVE")
    _mb_undo_restore_created=$(mb_meta_line "$MB_UNDO_RESTORE_META" 1)
    [ -n "$_mb_undo_restore_created" ] || _mb_undo_restore_created=unknown
  fi
  _mb_undo_update_available=false
  _mb_undo_update_id=""
  _mb_undo_update_version=unknown
  _mb_undo_update_created=unknown
  _mb_undo_update_archive=""
  if ! _mb_undo_update_archive=$(mb_update_undo_archive 2>/dev/null); then
    warn -c cli,vlan "The temporary Undo Update reference could not be read while refreshing inventory"
  fi
  if [ -n "$_mb_undo_update_archive" ]; then
    _mb_undo_update_available=true
    _mb_undo_update_id=${_mb_undo_update_archive##*/}
    _mb_undo_update_created=$(mb_meta_line "$MB_UNDO_UPDATE_MARKER" 2)
    _mb_undo_update_version=$(mb_meta_line "$MB_UNDO_UPDATE_MARKER" 3)
    [ -n "$_mb_undo_update_created" ] || _mb_undo_update_created=unknown
    [ -n "$_mb_undo_update_version" ] || _mb_undo_update_version=$(mb_archive_version "$_mb_undo_update_archive")
  fi
  printf '{"generated":%s,"automatic_count":%s,"automatic_limit":%s,"manual_count":%s,"manual_limit":%s,' \
    "$(date +%s 2>/dev/null || echo 0)" "$_mb_auto" "$MB_AUTO_LIMIT" "$_mb_manual" "$MB_MANUAL_LIMIT" > "$_mb_tmp" || return 1
  printf '"storage":{"persistent":{"used_bytes":%s,"available_bytes":%s,"total_bytes":%s},"temporary":{"used_bytes":%s,"available_bytes":%s,"total_bytes":%s},' \
    "$((_mb_persistent_used * 1024))" "$((_mb_persistent_available * 1024))" "$((_mb_persistent_total * 1024))" \
    "$((_mb_temporary_used * 1024))" "$((_mb_temporary_available * 1024))" "$((_mb_temporary_total * 1024))" >> "$_mb_tmp"
  printf '"managed":{"jffs":{"used_bytes":%s,"available_bytes":%s,"total_bytes":%s},"tmp":{"used_bytes":%s,"available_bytes":%s,"total_bytes":%s},' \
    "$((MB_STORAGE_JFFS_USED * 1024))" "$((MB_STORAGE_JFFS_AVAILABLE * 1024))" "$((MB_STORAGE_JFFS_TOTAL * 1024))" \
    "$((MB_STORAGE_TMP_USED * 1024))" "$((MB_STORAGE_TMP_AVAILABLE * 1024))" "$((MB_STORAGE_TMP_TOTAL * 1024))" >> "$_mb_tmp"
  printf '"www":{"used_bytes":%s,"available_bytes":%s,"total_bytes":%s},"ram":{"combined":%s,"used_bytes":%s,"available_bytes":%s,"total_bytes":%s}}},' \
    "$((MB_STORAGE_WWW_USED * 1024))" "$((MB_STORAGE_WWW_AVAILABLE * 1024))" "$((MB_STORAGE_WWW_TOTAL * 1024))" \
    "$MB_STORAGE_RAM_COMBINED" "$((MB_STORAGE_RAM_USED * 1024))" "$((MB_STORAGE_RAM_AVAILABLE * 1024))" "$((MB_STORAGE_RAM_TOTAL * 1024))" >> "$_mb_tmp"
  printf '"undo":{"restore":{"available":%s,"version":"%s","created":"%s","size_bytes":%s},"update":{"available":%s,"backup_id":"%s","version":"%s","created":"%s"}},"backups":[' \
    "$_mb_undo_restore_available" "$(mb_json_escape "$_mb_undo_restore_version")" "$(mb_json_escape "$_mb_undo_restore_created")" "$_mb_undo_restore_size" \
    "$_mb_undo_update_available" "$(mb_json_escape "$_mb_undo_update_id")" "$(mb_json_escape "$_mb_undo_update_version")" "$(mb_json_escape "$_mb_undo_update_created")" >> "$_mb_tmp"
  for _mb_path in $(mb_list_paths); do
    _mb_id=${_mb_path##*/}
    _mb_type=$(mb_archive_type "$_mb_id")
    _mb_tag=$(mb_archive_tag "$_mb_id")
    _mb_ts=$(mb_archive_timestamp "$_mb_id")
    _mb_created=$(mb_timestamp_display "$_mb_ts")
    _mb_version=$(mb_archive_version "$_mb_path")
    _mb_size=$(wc -c < "$_mb_path" 2>/dev/null | tr -d '[:space:]')
    case "$_mb_size" in ''|*[!0-9]*) _mb_size=0 ;; esac
    [ "$_mb_first" = "1" ] || printf ',' >> "$_mb_tmp"
    _mb_first=0
    printf '{"id":"%s","type":"%s","tag":"%s","version":"%s","created":"%s","timestamp":"%s","size_bytes":%s,"restorable":true}' \
      "$(mb_json_escape "$_mb_id")" "$_mb_type" "$(mb_json_escape "$_mb_tag")" \
      "$(mb_json_escape "$_mb_version")" "$(mb_json_escape "$_mb_created")" \
      "$(mb_json_escape "$_mb_ts")" "$_mb_size" >> "$_mb_tmp"
  done
  printf ']}\n' >> "$_mb_tmp"
  if [ "$_mb_output" = "-" ]; then
    cat "$_mb_tmp" || return 1
  else
    chmod 644 "$_mb_tmp" 2>/dev/null || return 1
    mv -f "$_mb_tmp" "$_mb_output" 2>/dev/null || return 1
  fi
  return 0
}

mb_print_inventory() {
  _mb_index=0
  printf 'Available MerVLAN backups:\n'
  for _mb_path in $(mb_list_paths); do
    _mb_index=$((_mb_index + 1))
    _mb_id=${_mb_path##*/}
    printf '  %d) %-9s %-18s %-19s %s\n' \
      "$_mb_index" "$(mb_archive_type "$_mb_id")" "$(mb_archive_version "$_mb_path")" \
      "$(mb_timestamp_display "$(mb_archive_timestamp "$_mb_id")")" "$_mb_id"
  done
  [ "$_mb_index" -gt 0 ] || printf '  No backups found.\n'
  printf '\nAutomatic: %s/%s  Manual: %s/%s\n' \
    "$(mb_count_type automatic)" "$MB_AUTO_LIMIT" "$(mb_count_type manual)" "$MB_MANUAL_LIMIT"
  mb_collect_managed_storage
  printf 'MerVLAN storage use:\n'
  printf '  JFFS: %s KB used, %s KB free\n' "$MB_STORAGE_JFFS_USED" "$MB_STORAGE_JFFS_AVAILABLE"
  if [ "$MB_STORAGE_RAM_COMBINED" = "true" ]; then
    printf '  RAM:  %s KB used, %s KB free\n' "$MB_STORAGE_RAM_USED" "$MB_STORAGE_RAM_AVAILABLE"
  else
    printf '  /tmp: %s KB used, %s KB free\n' "$MB_STORAGE_TMP_USED" "$MB_STORAGE_TMP_AVAILABLE"
    printf '  /www: %s KB used, %s KB free\n' "$MB_STORAGE_WWW_USED" "$MB_STORAGE_WWW_AVAILABLE"
  fi
  if [ -f "$MB_UNDO_RESTORE_ARCHIVE" ]; then
    printf '  Undo Restore available (temporary; lost on reboot).\n'
  fi
  if mb_update_undo_archive >/dev/null 2>&1; then
    printf '  Undo Update available (shortcut expires on reboot).\n'
  fi
}

mb_update_legacy_metadata() {
  _mb_settings="$MERV_BASE/settings/settings.json"
  [ -f "$_mb_settings" ] || return 0
  type json_set_array >/dev/null 2>&1 || return 0
  _mb_metadata_failed=0
  if ! json_set_array BACKUP_1 "none none none" "$_mb_settings" 2>/dev/null; then _mb_metadata_failed=1; fi
  if ! json_set_array BACKUP_2 "none none none" "$_mb_settings" 2>/dev/null; then _mb_metadata_failed=1; fi
  if ! json_set_array BACKUP_3 "none none none" "$_mb_settings" 2>/dev/null; then _mb_metadata_failed=1; fi
  _mb_index=0
  for _mb_path in $(mb_list_paths); do
    [ "$(mb_archive_type "${_mb_path##*/}")" = automatic ] || continue
    _mb_index=$((_mb_index + 1))
    [ "$_mb_index" -le 3 ] || break
    _mb_version=$(mb_archive_version "$_mb_path")
    _mb_created=$(mb_timestamp_display "$(mb_archive_timestamp "${_mb_path##*/}")")
    _mb_date=${_mb_created% *}
    _mb_time=${_mb_created#* }
    if ! json_set_array "BACKUP_$_mb_index" "$_mb_version $_mb_date ${_mb_time%:*}" "$_mb_settings" 2>/dev/null; then
      _mb_metadata_failed=1
    fi
  done
  if [ "$_mb_metadata_failed" -ne 0 ]; then
    warn -c cli,vlan "Legacy backup metadata could not be fully refreshed"
    return 1
  fi
  return 0
}

mb_refresh_inventory() {
  _mb_inventory_failed=0
  if ! mb_write_inventory "$MB_INVENTORY_FILE"; then
    warn -c cli,vlan "Could not refresh backup inventory JSON"
    _mb_inventory_failed=1
  fi
  if ! mb_update_legacy_metadata; then
    _mb_inventory_failed=1
  fi
  [ "$_mb_inventory_failed" -eq 0 ]
}

mb_confirm() {
  _mb_supplied="$1"
  _mb_prompt="$2"
  if [ -n "$_mb_supplied" ]; then
    _mb_answer="$_mb_supplied"
  else
    printf '%s [y/N]: ' "$_mb_prompt"
    read _mb_answer
  fi
  case "$_mb_answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

mb_validate_tag() {
  printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]{0,23}$'
}

mb_create_manual() {
  _mb_tag="$1"
  _mb_confirm="$2"
  MB_REQUEST_TOKEN=$(mb_make_token "$3")
  MB_OPERATION=backup_create
  MB_TARGET="$_mb_tag"
  if [ -z "$_mb_tag" ]; then
    printf 'Manual backup tag (1-24 letters, numbers, _ or -): '
    read _mb_tag
    MB_TARGET="$_mb_tag"
  fi
  mb_validate_tag "$_mb_tag" || { mb_fail validation "Invalid manual backup tag. Use 1-24 letters, numbers, _ or -."; return 1; }
  if ! mb_confirm "$_mb_confirm" "Create a manual backup tagged '$_mb_tag'?"; then
    info -c cli,vlan "Manual backup cancelled"
    mb_write_result cancelled confirmation "Manual backup cancelled."
    return 2
  fi
  mb_require_lock || return 1
  if [ "$(mb_count_type manual)" -ge "$MB_MANUAL_LIMIT" ]; then
    mb_fail limit "Manual backup limit reached ($MB_MANUAL_LIMIT). Delete a manual backup before creating another."
    return 1
  fi
  mkdir -p "$MB_BACKUP_ROOT" "$MB_WORK_ROOT" 2>/dev/null || { mb_fail workspace "Could not prepare the backup directory."; return 1; }
  _mb_source_kb=$(mb_path_size_kb "$MERV_BASE")
  if ! mb_require_space_kb "$MB_BACKUP_ROOT" "$_mb_source_kb" "persistent backup"; then
    mb_fail space "$MB_SPACE_MESSAGE"
    return 1
  fi
  _mb_timestamp=$(date +%Y%m%d-%H%M%S 2>/dev/null)
  [ -n "$_mb_timestamp" ] || { mb_fail timestamp "Could not create a backup timestamp."; return 1; }
  _mb_id="mervlan.manual.backup.${_mb_timestamp}.${_mb_tag}.tar.gz"
  _mb_final="$MB_BACKUP_ROOT/$_mb_id"
  _mb_partial="$MB_BACKUP_ROOT/.${_mb_id}.partial.$$"
  MB_TARGET="$_mb_id"
  [ ! -e "$_mb_final" ] || { mb_fail collision "Backup $_mb_id already exists."; return 1; }
  mb_write_result running archiving "Creating manual backup $_mb_id."
  info -c cli,vlan "Creating manual backup $_mb_id"
  if ! tar -czf "$_mb_partial" -C "${MERV_BASE%/*}" "${MERV_BASE##*/}" 2>/dev/null; then
    if ! rm -f "$_mb_partial" 2>/dev/null; then
      MB_PRESERVE_WORK=1
      warn -c cli,vlan "Manual backup archiving failed and its partial archive could not be removed"
    fi
    mb_fail archiving "Failed to create the manual backup archive. Check available flash space."
    return 1
  fi
  if ! tar -tzf "$_mb_partial" >/dev/null 2>&1; then
    if ! rm -f "$_mb_partial" 2>/dev/null; then
      MB_PRESERVE_WORK=1
      warn -c cli,vlan "Manual backup validation failed and its partial archive could not be removed"
    fi
    mb_fail validation "The created manual backup failed archive validation."
    return 1
  fi
  if ! rm -rf "$MB_WORK_ROOT/manual-verify" 2>/dev/null; then
    MB_PRESERVE_WORK=1
    mb_fail validation "Could not remove the previous manual-backup validation tree."
    return 1
  fi
  if ! mb_validate_archive_tree "$_mb_partial" "$MB_WORK_ROOT/manual-verify"; then
    if ! rm -f "$_mb_partial" 2>/dev/null; then
      MB_PRESERVE_WORK=1
      warn -c cli,vlan "Manual backup validation failed and its partial archive could not be removed"
    fi
    mb_fail validation "The created manual backup is unsafe, incomplete, or contains invalid settings."
    return 1
  fi
  _mb_meta_final="${_mb_final}.meta"
  _mb_meta_partial="${_mb_meta_final}.partial.$$"
  if ! mb_prepare_archive_metadata "$_mb_partial" "$_mb_id" "$_mb_meta_partial"; then
    if ! rm -f "$_mb_partial" "$_mb_meta_partial" 2>/dev/null; then
      MB_PRESERVE_WORK=1
      warn -c cli,vlan "Manual backup metadata creation failed and its partial files could not be removed"
    fi
    mb_fail validation "Could not calculate integrity metadata for the manual backup."
    return 1
  fi
  if ! mv -f "$_mb_meta_partial" "$_mb_meta_final" 2>/dev/null; then
    if ! rm -f "$_mb_partial" "$_mb_meta_partial" 2>/dev/null; then
      MB_PRESERVE_WORK=1
      warn -c cli,vlan "Manual backup metadata publication failed and its partial files could not be removed"
    fi
    mb_fail publishing "Could not publish manual backup integrity metadata."
    return 1
  fi
  if ! mv -f "$_mb_partial" "$_mb_final" 2>/dev/null; then
    if ! rm -f "$_mb_partial" "$_mb_meta_final" 2>/dev/null; then
      MB_PRESERVE_WORK=1
      warn -c cli,vlan "Manual backup publication failed and its partial files could not be removed"
    fi
    mb_fail publishing "Could not publish the completed manual backup."
    return 1
  fi
  if ! mb_verify_archive_integrity "$_mb_final"; then
    if ! mb_remove_archive_artifacts "$_mb_final" 2>/dev/null; then
      warn -c cli,vlan "Manual backup integrity verification failed and the invalid archive could not be removed"
    fi
    mb_fail validation "The published manual backup failed its integrity check."
    return 1
  fi
  mb_install_recovery_helper || warn -c cli,vlan "Backup created, but the emergency recovery helper could not be refreshed"
  if ! mb_refresh_inventory; then
    warn -c cli,vlan "Manual backup was created, but backup inventory refresh reported errors"
  fi
  # Inventory generation iterates archives with shared POSIX-shell variables.
  # MB_TARGET is the stable operation identifier and cannot be replaced by the
  # last archive visited while refreshing the UI inventory.
  info -c cli,vlan "Manual backup completed successfully: $MB_TARGET"
  mb_write_result success complete "Manual backup created successfully."
  return 0
}

mb_delete_one() {
  _mb_selection="$1"
  _mb_confirm="$2"
  MB_REQUEST_TOKEN=$(mb_make_token "$3")
  MB_OPERATION=backup_delete
  if [ -z "$_mb_selection" ]; then
    mb_print_inventory
    printf 'Select backup to delete: '
    read _mb_selection
  fi
  _mb_path=$(mb_resolve_selection "$_mb_selection") || { MB_TARGET="$_mb_selection"; mb_fail selection "Selected backup was not found."; return 1; }
  _mb_id=${_mb_path##*/}
  MB_TARGET="$_mb_id"
  if ! mb_confirm "$_mb_confirm" "Permanently delete $_mb_id?"; then
    info -c cli,vlan "Backup deletion cancelled"
    mb_write_result cancelled confirmation "Backup deletion cancelled."
    return 2
  fi
  mb_require_lock || return 1
  _mb_path=$(mb_resolve_selection "$_mb_id") || { mb_fail selection "Selected backup no longer exists."; return 1; }
  mb_write_result running deleting "Deleting $_mb_id."
  mb_remove_archive_artifacts "$_mb_path" 2>/dev/null || { mb_fail deleting "Failed to delete $_mb_id."; return 1; }
  [ ! -e "$_mb_path" ] || { mb_fail deleting "Backup still exists after deletion attempt."; return 1; }
  if [ "$(mb_meta_line "$MB_UNDO_UPDATE_MARKER" 1)" = "$_mb_id" ]; then
    if ! rm -f "$MB_UNDO_UPDATE_MARKER" 2>/dev/null; then
      mb_fail deleting "Backup was deleted, but its Undo Update marker could not be removed."
      return 1
    fi
  fi
  if ! mb_refresh_inventory; then
    warn -c cli,vlan "Backup was deleted, but backup inventory refresh reported errors"
  fi
  info -c cli,vlan "Backup deleted successfully: $MB_TARGET"
  mb_write_result success complete "Backup deleted successfully."
  return 0
}

mb_delete_all() {
  _mb_confirm="$1"
  MB_REQUEST_TOKEN=$(mb_make_token "$2")
  MB_OPERATION=backup_delete_all
  MB_TARGET="$MB_BACKUP_ROOT"
  if ! mb_confirm "$_mb_confirm" "Permanently delete ALL persistent MerVLAN backups and clear Undo Update?"; then
    info -c cli,vlan "Delete-all cancelled"
    mb_write_result cancelled confirmation "Delete-all cancelled."
    return 2
  fi
  mb_require_lock || return 1
  mb_write_result running deleting "Deleting all persistent MerVLAN backups."
  mkdir -p "$MB_BACKUP_ROOT" 2>/dev/null || { mb_fail deleting "Backup directory is unavailable."; return 1; }
  chmod 700 "$MB_BACKUP_ROOT" 2>/dev/null || { mb_fail deleting "Could not secure the backup directory."; return 1; }
  _mb_delete_failed=0
  for _mb_delete_path in $(mb_list_paths); do
    mb_remove_archive_artifacts "$_mb_delete_path" 2>/dev/null || _mb_delete_failed=1
  done
  [ "$_mb_delete_failed" = "0" ] || { mb_fail deleting "One or more recognized backup files could not be deleted."; return 1; }
  mb_install_recovery_helper || warn -c cli,vlan "Persistent backups were deleted, but the emergency recovery helper could not be refreshed"
  if ! rm -f "$MB_UNDO_UPDATE_MARKER" 2>/dev/null; then
    mb_fail deleting "Persistent backups were deleted, but the Undo Update marker could not be removed."
    return 1
  fi
  if ! mb_refresh_inventory; then
    warn -c cli,vlan "Persistent backups were deleted, but backup inventory refresh reported errors"
  fi
  info -c cli,vlan "All persistent MerVLAN backups deleted successfully"
  mb_write_result success complete "All persistent backups deleted successfully. Temporary Undo Restore was retained."
  return 0
}

mb_validate_archive_tree() {
  _mb_archive="$1"
  _mb_stage="$2"
  mb_archive_member_types_safe "$_mb_archive" || return 1
  tar -tzf "$_mb_archive" > "$MB_WORK_ROOT/archive.list" 2>/dev/null || return 1
  [ -s "$MB_WORK_ROOT/archive.list" ] || return 1
  if grep -Eq '(^/|(^|/)\.\.(/|$)|[[:cntrl:]])' "$MB_WORK_ROOT/archive.list" 2>/dev/null; then
    return 1
  fi
  _mb_root=$(awk -F/ 'NF { print $1; exit }' "$MB_WORK_ROOT/archive.list")
  [ -n "$_mb_root" ] || return 1
  awk -F/ -v root="$_mb_root" 'NF && $1 != root { bad=1 } END { exit bad }' "$MB_WORK_ROOT/archive.list" || return 1
  mkdir -p "$_mb_stage" 2>/dev/null || return 1
  tar -xzf "$_mb_archive" -C "$_mb_stage" >/dev/null 2>&1 || return 1
  MB_RESTORE_TREE="$_mb_stage/$_mb_root"
  [ -d "$MB_RESTORE_TREE" ] || return 1
  for _mb_required in install.sh uninstall.sh changelog.txt mervlan.asp functions/update_mervlan.sh functions/mervlan_boot.sh settings/settings.json www/index.html; do
    [ -f "$MB_RESTORE_TREE/$_mb_required" ] || return 1
  done
  mb_settings_file_valid "$MB_RESTORE_TREE/settings/settings.json" || return 1
  return 0
}

mb_read_boot_state() {
  _mb_settings="$1/settings/settings.json"
  if [ -f "$_mb_settings" ] && grep -q '"BOOT_ENABLED"[[:space:]]*:[[:space:]]*"1"' "$_mb_settings" 2>/dev/null; then
    printf '1'
  else
    printf '0'
  fi
}

mb_refresh_public_tree() {
  _mb_tree="$1"
  [ "$MB_TEST_FAIL_PHASE" = "refreshing_public" ] && return 1
  [ "$MB_TEST_MODE" = "1" ] && return 0
  [ -x "$_mb_tree/uninstall.sh" ] || return 1
  [ -x "$_mb_tree/install.sh" ] || return 1
  sh "$_mb_tree/uninstall.sh" reinstall >/dev/null 2>&1 || return 1
  sh "$_mb_tree/install.sh" reinstall >/dev/null 2>&1 || return 1
  return 0
}

mb_apply_boot_state() {
  _mb_tree="$1"
  _mb_state="$2"
  _mb_skip_nodes="${3:-0}"
  [ "$MB_TEST_MODE" = "1" ] && return 0
  _mb_boot="$_mb_tree/functions/mervlan_boot.sh"
  [ -x "$_mb_boot" ] || return 1
  if [ "$_mb_skip_nodes" = "1" ]; then
    MERV_SKIP_NODE_SYNC=1 sh "$_mb_boot" setupenable >/dev/null 2>&1 || return 1
  else
    sh "$_mb_boot" setupenable >/dev/null 2>&1 || return 1
  fi
  if [ "$_mb_state" = "1" ]; then
    if [ "$_mb_skip_nodes" = "1" ]; then
      MERV_SKIP_NODE_SYNC=1 sh "$_mb_boot" enable >/dev/null 2>&1 || return 1
    else
      sh "$_mb_boot" enable >/dev/null 2>&1 || return 1
    fi
  else
    if [ "$_mb_skip_nodes" = "1" ]; then
      MERV_SKIP_NODE_SYNC=1 sh "$_mb_boot" disable >/dev/null 2>&1 || return 1
    else
      sh "$_mb_boot" disable >/dev/null 2>&1 || return 1
    fi
  fi
  return 0
}

mb_list_configured_nodes() {
  [ -f "${SETTINGS_FILE:-$MERV_BASE/settings/settings.json}" ] || return 1
  type merv_node_list >/dev/null 2>&1 || return 1
  merv_node_list
}

mb_push_restored_mac_db() {
  _mb_nodes="$1"
  [ -f "${MERV_MAC_DB_ACTIVE:-}" ] || return 0
  if [ -z "${LIB_MAC_SHIELD_SNAPSHOT_LOADED:-}" ]; then
    . "$MERV_BASE/settings/mac_shield_snapshot.sh" 2>/dev/null || return 1
  fi
  type merv_mac_push_db_to_nodes >/dev/null 2>&1 || return 1
  MERV_MAC_LAST_PUSH_TOTAL=0
  MERV_MAC_LAST_PUSH_OK=0
  MERV_MAC_LAST_PUSH_FAILED=0
  merv_mac_push_db_to_nodes "$_mb_nodes"
  info -c cli,vlan "Restored MAC Shield database pushed to nodes ${MERV_MAC_LAST_PUSH_OK:-0}/${MERV_MAC_LAST_PUSH_TOTAL:-0}"
  [ "${MERV_MAC_LAST_PUSH_FAILED:-0}" = "0" ] && \
    [ "${MERV_MAC_LAST_PUSH_TOTAL:-0}" -gt 0 ]
}

mb_apply_restored_node_boot_state() {
  _mb_nodes="$1"
  _mb_state="$2"
  if [ "$_mb_state" = "1" ]; then
    _mb_node_action=enable
  else
    _mb_node_action=disable
  fi
  _mb_node_failed=0
  while read -r _mb_node_id _mb_node_ip; do
    [ -n "$_mb_node_ip" ] || continue
    if merv_ssh_exec "$_mb_node_id" "$_mb_node_ip" \
         "cd '$MERV_BASE/functions' && MERV_NODE_CONTEXT=1 sh ./mervlan_boot.sh nodeenable --local && MERV_NODE_CONTEXT=1 sh ./mervlan_boot.sh $_mb_node_action" >/dev/null 2>&1; then
      info -c cli,vlan "Restored boot state '${_mb_node_action}' on NODE${_mb_node_id} ($_mb_node_ip)"
    else
      type merv_ssh_skip_log >/dev/null 2>&1 && \
        merv_ssh_skip_log "$_mb_node_id" "$_mb_node_ip" "restore boot state $_mb_node_action"
      _mb_node_failed=1
    fi
  done <<EOF
$_mb_nodes
EOF
  [ "$_mb_node_failed" = "0" ]
}

mb_runtime_report_matches() {
  _mb_report="$1"
  _mb_role="$2"
  _mb_expected_boot="$3"
  _mb_expected_cron=absent
  [ "$_mb_expected_boot" = "1" ] && _mb_expected_cron=present
  case "$_mb_report" in REPORT\ *) ;; *) return 1 ;; esac
  case " $_mb_report " in *" boot=$_mb_expected_boot "*) ;; *) return 1 ;; esac
  case " $_mb_report " in *" event=active "*) ;; *) return 1 ;; esac
  case " $_mb_report " in *" cron=$_mb_expected_cron "*) ;; *) return 1 ;; esac
  case "$_mb_role" in
    main)
      case " $_mb_report " in *" addon=active "*) ;; *) return 1 ;; esac
      case " $_mb_report " in *" is_node=no "*) return 0 ;; *) return 1 ;; esac
      ;;
    node)
      case " $_mb_report " in *" addon=node-on "*) ;; *) return 1 ;; esac
      case " $_mb_report " in *" is_node=yes "*) return 0 ;; *) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
}

mb_verify_restored_runtime() {
  _mb_nodes="$1"
  _mb_expected_boot="$2"
  MB_VERIFY_PARTIAL=0
  [ "$MB_TEST_MODE" = "1" ] && return 0
  _mb_boot_script="$MERV_BASE/functions/mervlan_boot.sh"
  _mb_action=disable
  [ "$_mb_expected_boot" = "1" ] && _mb_action=enable

  _mb_main_report=$(sh "$_mb_boot_script" report 2>/dev/null)
  _mb_main_report_rc=$?
  [ "$_mb_main_report_rc" -eq 0 ] || warn -c cli,vlan "Restored main runtime report command failed (rc=$_mb_main_report_rc)"
  if ! mb_runtime_report_matches "$_mb_main_report" main "$_mb_expected_boot"; then
    warn -c cli,vlan "Restored main runtime mismatch; retrying hook reconciliation"
    MERV_SKIP_NODE_SYNC=1 sh "$_mb_boot_script" setupenable >/dev/null 2>&1 ||
      warn -c cli,vlan "Restored main hook reconciliation setup failed"
    MERV_SKIP_NODE_SYNC=1 sh "$_mb_boot_script" "$_mb_action" >/dev/null 2>&1 ||
      warn -c cli,vlan "Restored main boot-state reconciliation failed"
    _mb_main_report=$(sh "$_mb_boot_script" report 2>/dev/null)
    _mb_main_report_rc=$?
    [ "$_mb_main_report_rc" -eq 0 ] || warn -c cli,vlan "Restored main retry report command failed (rc=$_mb_main_report_rc)"
  fi
  if ! mb_runtime_report_matches "$_mb_main_report" main "$_mb_expected_boot"; then
    error -c cli,vlan "Restored main runtime verification failed after retry: ${_mb_main_report:-no report}"
    return 1
  fi
  info -c cli,vlan "Verified restored main runtime: configured-node baseline active, BOOT_ENABLED=$_mb_expected_boot"

  [ -n "$_mb_nodes" ] || return 0
  if ! type ssh_keys_effectively_installed >/dev/null 2>&1 || ! ssh_keys_effectively_installed; then
    MB_VERIFY_PARTIAL=1
    return 0
  fi
  while read -r _mb_node_id _mb_node_ip; do
    [ -n "$_mb_node_ip" ] || continue
    _mb_remote="cd '$MERV_BASE/functions' && MERV_NODE_CONTEXT=1 sh ./mervlan_boot.sh report"
    _mb_node_report=$(merv_ssh_exec "$_mb_node_id" "$_mb_node_ip" "$_mb_remote" 2>/dev/null)
    _mb_node_report_rc=$?
    [ "$_mb_node_report_rc" -eq 0 ] || warn -c cli,vlan "NODE${_mb_node_id} restored runtime report failed (rc=$_mb_node_report_rc)"
    if ! mb_runtime_report_matches "$_mb_node_report" node "$_mb_expected_boot"; then
      warn -c cli,vlan "NODE${_mb_node_id} ($_mb_node_ip) restored runtime mismatch; retrying reconciliation"
      _mb_remote="cd '$MERV_BASE/functions' && MERV_NODE_CONTEXT=1 sh ./mervlan_boot.sh nodeenable --local && MERV_NODE_CONTEXT=1 sh ./mervlan_boot.sh '$_mb_action' && MERV_NODE_CONTEXT=1 sh ./mervlan_boot.sh report"
      _mb_node_report=$(merv_ssh_exec "$_mb_node_id" "$_mb_node_ip" "$_mb_remote" 2>/dev/null)
      _mb_node_report_rc=$?
      [ "$_mb_node_report_rc" -eq 0 ] || warn -c cli,vlan "NODE${_mb_node_id} restored retry report failed (rc=$_mb_node_report_rc)"
    fi
    if mb_runtime_report_matches "$_mb_node_report" node "$_mb_expected_boot"; then
      info -c cli,vlan "Verified restored NODE${_mb_node_id} ($_mb_node_ip): baseline active, BOOT_ENABLED=$_mb_expected_boot"
    else
      warn -c cli,vlan "NODE${_mb_node_id} ($_mb_node_ip) restored runtime verification failed after retry: ${_mb_node_report:-no report}"
      MB_VERIFY_PARTIAL=1
    fi
  done <<EOF
$_mb_nodes
EOF
  return 0
}

mb_rollback_restore() {
  _mb_old_tree="$1"
  _mb_old_boot="$2"
  warn -c cli,vlan "Restore failed after activation; rolling back the original installation"
  _mb_rollback_failed=0
  if [ "$MB_TEST_MODE" != "1" ] && [ -x "$MERV_BASE/functions/mervlan_boot.sh" ]; then
    # Quiesce the failed target and remove its exact template generation before
    # the original source is put back.  Keep node teardown explicit so a local
    # setup action cannot hide or duplicate the remote lifecycle.
    if ! MERV_SKIP_NODE_SYNC=1 sh "$MERV_BASE/functions/mervlan_boot.sh" disable >/dev/null 2>&1; then
      error -c cli,vlan "Rollback could not disable the failed MerVLAN runtime"
      _mb_rollback_failed=1
    fi
    if ! MERV_SKIP_NODE_SYNC=1 sh "$MERV_BASE/functions/mervlan_boot.sh" setupdisable >/dev/null 2>&1; then
      error -c cli,vlan "Rollback could not remove the failed MerVLAN hooks"
      _mb_rollback_failed=1
    fi
  fi
  if ! mb_remove_jffs_stage "$MB_JFFS_STAGE"; then
    error -c cli,vlan "Rollback could not remove the failed activation stage"
    _mb_rollback_failed=1
  fi
  if [ -d "$MERV_BASE" ]; then
    if ! mv "$MERV_BASE" "$MB_JFFS_STAGE" 2>/dev/null; then
      MB_PRESERVE_WORK=1
      error -c cli,vlan "CRITICAL: rollback could not preserve the failed active installation"
      return 1
    fi
  fi
  if mv "$_mb_old_tree" "$MERV_BASE" 2>/dev/null; then
    if ! mb_remove_jffs_stage "$MB_JFFS_STAGE"; then
      error -c cli,vlan "Rollback restored the original tree but could not remove the failed tree"
      _mb_rollback_failed=1
    fi
    MB_ROLLBACK_DONE=1
    MB_ACTIVATION_STARTED=0
    if ! mb_refresh_public_tree "$MERV_BASE" >/dev/null 2>&1; then
      error -c cli,vlan "Rollback restored the original tree but could not refresh the public installation"
      _mb_rollback_failed=1
    fi
    if ! mb_apply_boot_state "$MERV_BASE" "$_mb_old_boot" 1 >/dev/null 2>&1; then
      error -c cli,vlan "Rollback restored the original tree but could not reapply its boot state"
      _mb_rollback_failed=1
    fi
    _mb_rollback_nodes=""
    if ! _mb_rollback_nodes=$(mb_list_configured_nodes 2>/dev/null); then
      error -c cli,vlan "Rollback restored the original tree but could not read its configured nodes"
      _mb_rollback_failed=1
    fi
    if [ -n "$_mb_rollback_nodes" ] && type ssh_keys_effectively_installed >/dev/null 2>&1 && ssh_keys_effectively_installed; then
      if [ -x "$MERV_BASE/functions/sync_nodes.sh" ]; then
        if ! MERV_MAINTENANCE_SYNC=1 sh "$MERV_BASE/functions/sync_nodes.sh" >/dev/null 2>&1; then
          error -c cli,vlan "Rollback restored the original tree but node synchronization failed"
          _mb_rollback_failed=1
        fi
      fi
      if ! mb_apply_restored_node_boot_state "$_mb_rollback_nodes" "$_mb_old_boot" >/dev/null 2>&1; then
        error -c cli,vlan "Rollback restored the original tree but node boot-state reconciliation failed"
        _mb_rollback_failed=1
      fi
    fi
    if [ "$_mb_rollback_failed" -eq 0 ]; then
      error -c cli,vlan "Restore failed; original installation was restored"
      return 0
    fi
    MB_PRESERVE_WORK=1
    error -c cli,vlan "CRITICAL: original installation was restored, but rollback reconciliation failed"
    return 1
  fi
  MB_PRESERVE_WORK=1
  error -c cli,vlan "CRITICAL: restore and rollback both failed; temporary original remains at $_mb_old_tree"
  return 1
}

mb_publish_restore_undo() {
  _mb_old_tree="$1"
  _mb_old_version="$2"
  mkdir -p "$MB_UNDO_ROOT" 2>/dev/null || return 1
  chmod 700 "$MB_UNDO_ROOT" 2>/dev/null || return 1
  _mb_undo_partial="$MB_UNDO_RESTORE_ARCHIVE.partial.$$"
  _mb_meta_partial="$MB_UNDO_RESTORE_META.partial.$$"
  rm -f "$_mb_undo_partial" "$_mb_meta_partial" 2>/dev/null || return 1
  if ! tar -czf "$_mb_undo_partial" -C "${_mb_old_tree%/*}" "${_mb_old_tree##*/}" 2>/dev/null || \
     ! tar -tzf "$_mb_undo_partial" >/dev/null 2>&1; then
    if ! rm -f "$_mb_undo_partial" "$_mb_meta_partial" 2>/dev/null; then
      MB_PRESERVE_WORK=1
      warn -c cli,vlan "Undo Restore archive creation failed and its temporary files could not be removed"
    fi
    return 1
  fi
  printf '%s\n%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)" "${_mb_old_version:-unknown}" > "$_mb_meta_partial" 2>/dev/null || {
    if ! rm -f "$_mb_undo_partial" "$_mb_meta_partial" 2>/dev/null; then
      MB_PRESERVE_WORK=1
      warn -c cli,vlan "Undo Restore metadata creation failed and its temporary files could not be removed"
    fi
    return 1
  }
  if ! chmod 600 "$_mb_undo_partial" "$_mb_meta_partial" 2>/dev/null; then
    if ! rm -f "$_mb_undo_partial" "$_mb_meta_partial" 2>/dev/null; then
      MB_PRESERVE_WORK=1
      warn -c cli,vlan "Undo Restore permission setup failed and its temporary files could not be removed"
    fi
    return 1
  fi
  mv -f "$_mb_undo_partial" "$MB_UNDO_RESTORE_ARCHIVE" 2>/dev/null || {
    if ! rm -f "$_mb_undo_partial" "$_mb_meta_partial" 2>/dev/null; then
      MB_PRESERVE_WORK=1
      warn -c cli,vlan "Undo Restore publication failed and its temporary files could not be removed"
    fi
    return 1
  }
  if ! mv -f "$_mb_meta_partial" "$MB_UNDO_RESTORE_META" 2>/dev/null; then
    if ! rm -f "$MB_UNDO_RESTORE_ARCHIVE" "$_mb_meta_partial" "$MB_UNDO_RESTORE_META" 2>/dev/null; then
      MB_PRESERVE_WORK=1
      warn -c cli,vlan "Undo Restore metadata publication failed and its partial files could not be removed"
    fi
    return 1
  fi
  MB_UNDO_CLEANUP_WARNING=0
  if ! rm -rf "$_mb_old_tree" 2>/dev/null; then
    MB_UNDO_CLEANUP_WARNING=1
    warn -c cli,vlan "Undo Restore was published, but the displaced working tree could not be removed"
  fi
  [ ! -e "$_mb_old_tree" ] || MB_UNDO_CLEANUP_WARNING=1
  return 0
}

mb_restore() {
  _mb_selection="$1"
  _mb_confirm="$2"
  MB_REQUEST_TOKEN=$(mb_make_token "$3")
  _mb_mode="${4:-restore}"
  _mb_create_undo=0
  _mb_undo_created=0
  case "$_mb_mode" in
    restore)
      MB_OPERATION=restore
      _mb_create_undo=1
      if [ -z "$_mb_selection" ]; then
        mb_print_inventory
        printf 'Select backup to restore: '
        read _mb_selection
      fi
      _mb_archive=$(mb_resolve_selection "$_mb_selection") || { MB_TARGET="$_mb_selection"; mb_fail selection "Selected backup was not found."; return 1; }
      _mb_id=${_mb_archive##*/}
      _mb_prompt="Continue with restore?"
      ;;
    undo_restore)
      MB_OPERATION=undo_restore
      _mb_archive="$MB_UNDO_RESTORE_ARCHIVE"
      [ -f "$_mb_archive" ] || { MB_TARGET=undo_restore; mb_fail selection "No temporary Undo Restore file is available."; return 1; }
      _mb_id="Undo Restore"
      _mb_prompt="Undo the last restore?"
      ;;
    undo_update)
      MB_OPERATION=undo_update
      _mb_archive=""
      if ! _mb_archive=$(mb_update_undo_archive 2>/dev/null); then
        warn -c cli,vlan "The temporary Undo Update reference could not be read"
      fi
      [ -n "$_mb_archive" ] || { MB_TARGET=undo_update; mb_fail selection "No temporary Undo Update reference is available."; return 1; }
      _mb_id=${_mb_archive##*/}
      _mb_prompt="Undo the last update?"
      ;;
    *) MB_TARGET="$_mb_mode"; mb_fail selection "Unknown restore mode: $_mb_mode"; return 1 ;;
  esac
  MB_TARGET="$_mb_id"
  printf '\nWARNING: This replaces the current MerVLAN installation and settings with:\n  %s\n\n' "$_mb_id"
  if ! mb_confirm "$_mb_confirm" "$_mb_prompt"; then
    info -c cli,vlan "$MB_OPERATION cancelled"
    mb_write_result cancelled confirmation "Operation cancelled."
    return 2
  fi
  mb_require_lock || return 1
  case "$_mb_mode" in
    restore) _mb_archive=$(mb_resolve_selection "$_mb_id") || { mb_fail selection "Selected backup no longer exists."; return 1; } ;;
    undo_restore) [ -f "$MB_UNDO_RESTORE_ARCHIVE" ] || { mb_fail selection "The temporary Undo Restore file is no longer available."; return 1; } ;;
    undo_update)
      _mb_archive=""
      if ! _mb_archive=$(mb_update_undo_archive 2>/dev/null); then
        mb_fail selection "The temporary Undo Update source could not be read."
        return 1
      fi
      [ -n "$_mb_archive" ] || { mb_fail selection "The Undo Update source is no longer available."; return 1; }
      ;;
  esac
  mkdir -p "$MB_WORK_ROOT" 2>/dev/null || { mb_fail workspace "Could not prepare restore workspace."; return 1; }
  if ! mb_verify_archive_integrity "$_mb_archive"; then
    mb_fail validation "Backup integrity metadata does not match the selected archive."
    return 1
  fi
  _mb_stage="$MB_WORK_ROOT/restore-stage"
  _mb_old="$MB_JFFS_OLD"
  if ! rm -rf "$_mb_stage" 2>/dev/null; then
    MB_PRESERVE_WORK=1
    mb_fail recovery "Could not remove the previous restore staging tree; no recovery data was removed."
    return 1
  fi
  if [ -e "$MB_JFFS_STAGE" ] || [ -e "$_mb_old" ]; then
    MB_PRESERVE_JFFS=1
    mb_fail recovery "A preserved activation tree uses this process slot. No recovery data was removed; run $MB_BACKUP_ROOT/recover.sh after inspection."
    return 1
  fi
  _mb_expanded_kb=$(mb_archive_expanded_kb "$_mb_archive")
  [ "$_mb_expanded_kb" -gt 0 ] || _mb_expanded_kb=$(mb_path_size_kb "$MERV_BASE")
  _mb_current_kb=$(mb_path_size_kb "$MERV_BASE")
  _mb_tmp_required=$((_mb_expanded_kb + _mb_current_kb))
  if ! mb_require_space_kb "$MB_WORK_ROOT" "$_mb_tmp_required" "temporary restore and rollback"; then
    mb_fail space "$MB_SPACE_MESSAGE"
    return 1
  fi
  mb_write_result running validating "Validating selected backup."
  info -c cli,vlan "Validating restore archive $_mb_id"
  if ! mb_validate_archive_tree "$_mb_archive" "$_mb_stage"; then
    if ! rm -rf "$_mb_stage" 2>/dev/null; then
      MB_PRESERVE_WORK=1
      warn -c cli,vlan "Restore validation failed and its staging tree could not be removed"
    fi
    mb_fail validation "Backup archive is corrupt, unsafe, or missing required MerVLAN files."
    return 1
  fi
  # Both the currently active node set and the target archive's node set must
  # be host-key verified before restore creates a stage, disables hooks, or
  # swaps the live installation. This keeps restore all-or-nothing at the
  # complete configured-node boundary.
  if [ "$MB_TEST_MODE" != "1" ]; then
    if ! merv_ssh_preflight_settings_file "$MERV_BASE/settings/settings.json" || \
       ! merv_ssh_preflight_settings_file "$MB_RESTORE_TREE/settings/settings.json"; then
      if ! rm -rf "$_mb_stage" 2>/dev/null; then
        MB_PRESERVE_WORK=1
        warn -c cli,vlan "Restore trust preflight failed and its staging tree could not be removed"
      fi
      mb_fail ssh_trust "Restore blocked: complete SSH trust preflight failed."
      return 1
    fi
  fi
  _mb_target_boot=$(mb_read_boot_state "$MB_RESTORE_TREE")
  _mb_current_boot=$(mb_read_boot_state "$MERV_BASE")
  _mb_current_version=$(sed -n '1{/^[[:space:]]*$/d;p;q}' "$MERV_BASE/changelog.txt" 2>/dev/null)
  _mb_target_version=$(sed -n '1{/^[[:space:]]*$/d;p;q}' "$MB_RESTORE_TREE/changelog.txt" 2>/dev/null)
  if ! mkdir -p "$MB_WORK_ROOT/preserve" 2>/dev/null; then
    MB_PRESERVE_WORK=1
    mb_fail preservation "Could not prepare the restore preservation area."
    return 1
  fi
  for _mb_db in mac_shield.db mac_shield_override.db client_name_override.db; do
    if [ -f "$MB_RESTORE_TREE/tmp/$_mb_db" ] && ! cp -p "$MB_RESTORE_TREE/tmp/$_mb_db" "$MB_WORK_ROOT/preserve/$_mb_db" 2>/dev/null; then
      MB_PRESERVE_WORK=1
      mb_fail preservation "Could not preserve $_mb_db before restore activation."
      return 1
    fi
  done
  mb_write_result running preparing_activation "Creating the validated temporary JFFS activation stage."
  mkdir -p "$MB_BACKUP_ROOT" 2>/dev/null || { mb_fail preparing_activation "Could not prepare the persistent backup directory."; return 1; }
  if ! mb_require_space_kb "$MB_BACKUP_ROOT" "$_mb_expanded_kb" "temporary JFFS activation stage"; then
    mb_fail space "$MB_SPACE_MESSAGE"
    return 1
  fi
  if [ -e "$MB_JFFS_STAGE" ] || [ -e "$MB_JFFS_OLD" ]; then
    MB_PRESERVE_JFFS=1
    mb_fail recovery "A preserved activation tree blocks this restore. No recovery data was removed; run $MB_BACKUP_ROOT/recover.sh after inspection."
    return 1
  fi
  if ! cp -pR "$MB_RESTORE_TREE" "$MB_JFFS_STAGE" 2>/dev/null || \
     ! mb_settings_file_valid "$MB_JFFS_STAGE/settings/settings.json"; then
    if ! mb_remove_jffs_stage "$MB_JFFS_STAGE"; then
      MB_PRESERVE_JFFS=1
      warn -c cli,vlan "Restore activation-stage validation failed and its temporary tree could not be removed"
    fi
    mb_fail preparing_activation "Could not create and validate the JFFS activation stage."
    return 1
  fi
  MB_RESTORE_ORIGINAL="$MB_JFFS_OLD"
  MB_RESTORE_ORIGINAL_BOOT="$_mb_current_boot"
  mb_write_result running disabling_hooks "Disabling current MerVLAN hooks."
  if [ "$MB_TEST_MODE" != "1" ] && [ -x "$MERV_BASE/functions/mervlan_boot.sh" ]; then
    # Stop active boot/cron work first, then remove old-version main and node
    # injections before any files are replaced.
    if ! MERV_SKIP_NODE_SYNC=1 sh "$MERV_BASE/functions/mervlan_boot.sh" disable >/dev/null 2>&1; then
      if ! mb_remove_jffs_stage "$MB_JFFS_STAGE"; then MB_PRESERVE_JFFS=1; fi
      mb_fail disabling_hooks "Could not disable the current MerVLAN runtime; restore was not activated."
      return 1
    fi
    if ! MERV_SKIP_NODE_SYNC=1 sh "$MERV_BASE/functions/mervlan_boot.sh" setupdisable >/dev/null 2>&1; then
      if ! mb_remove_jffs_stage "$MB_JFFS_STAGE"; then MB_PRESERVE_JFFS=1; fi
      mb_fail disabling_hooks "Could not remove the current MerVLAN hooks; restore was not activated."
      return 1
    fi
  fi
  mb_write_result running activating "Activating the selected backup."
  MB_ACTIVATION_STARTED=1
  case "$MERV_BASE" in /|/jffs|/jffs/addons|/tmp|'') mb_fail safety "Refusing unsafe active path: $MERV_BASE"; return 1 ;; esac
  if ! mv "$MERV_BASE" "$MB_JFFS_OLD" 2>/dev/null; then
    mb_fail activating "Could not preserve the active installation for rollback."
    return 1
  fi
  if ! mv "$MB_JFFS_STAGE" "$MERV_BASE" 2>/dev/null; then
    mb_rollback_restore "$_mb_old" "$_mb_current_boot"
    mb_fail activating "Could not activate the restored installation; rollback was attempted."
    return 1
  fi
  mb_test_pause target_active
  _mb_partial=0
  if ! rm -rf "$_mb_stage" 2>/dev/null; then
    MB_PRESERVE_WORK=1
    warn -c cli,vlan "Restore activated, but its validation staging tree could not be removed"
    _mb_partial=1
  fi
  if ! json_set_section_value General BOOT_ENABLED "$_mb_current_boot" "$_mb_old/settings/settings.json" >/dev/null 2>&1; then
    warn -c cli,vlan "Restored settings could not record the current main boot state"
    _mb_partial=1
  fi
  if ! chmod 755 "$MERV_BASE"/*.sh "$MERV_BASE"/functions/*.sh 2>/dev/null; then
    warn -c cli,vlan "Some restored executable files could not be assigned executable permissions"
    _mb_partial=1
  fi
  if ! chmod 644 "$MERV_BASE"/settings/*.sh "$MERV_BASE"/www/*.css "$MERV_BASE"/www/*.html 2>/dev/null; then
    warn -c cli,vlan "Some restored settings or web files could not be assigned safe permissions"
    _mb_partial=1
  fi
  mb_write_result running refreshing_public "Refreshing the public MerVLAN installation."
  if ! mb_refresh_public_tree "$MERV_BASE"; then
    mb_rollback_restore "$_mb_old" "$_mb_current_boot"
    mb_fail refreshing_public "Restore could not refresh the public installation; the original installation was restored."
    return 1
  fi
  mkdir -p "$MERV_BASE/tmp" 2>/dev/null || _mb_partial=1
  for _mb_db in mac_shield.db mac_shield_override.db client_name_override.db; do
    if [ -f "$MB_WORK_ROOT/preserve/$_mb_db" ] && \
       ! cp -p "$MB_WORK_ROOT/preserve/$_mb_db" "$MERV_BASE/tmp/$_mb_db" 2>/dev/null; then
      warn -c cli,vlan "Could not restore $_mb_db from the selected backup"
      _mb_partial=1
    fi
  done
  if [ -f "$MB_WORK_ROOT/preserve/mac_shield.db" ]; then
    mkdir -p "${MERV_MAC_DB_ACTIVE%/*}" 2>/dev/null || _mb_partial=1
    if ! cp -p "$MB_WORK_ROOT/preserve/mac_shield.db" "$MERV_MAC_DB_ACTIVE" 2>/dev/null; then
      warn -c cli,vlan "Could not restore the active MAC Shield database"
      _mb_partial=1
    fi
  fi
  mb_write_result running hooks "Re-applying restored hooks and boot state."
  if ! mb_apply_boot_state "$MERV_BASE" "$_mb_target_boot" 1; then
    mb_rollback_restore "$_mb_old" "$_mb_current_boot"
    mb_fail hooks "Restore could not reapply required hooks; the original installation was restored."
    return 1
  fi
  if [ "$MB_TEST_MODE" != "1" ] && [ -x "$MERV_BASE/functions/hw_probe.sh" ]; then
    sh "$MERV_BASE/functions/hw_probe.sh" >/dev/null 2>&1 || { warn -c cli,vlan "Restored hardware probe reported errors"; _mb_partial=1; }
  fi
  _mb_restored_nodes=""
  if ! _mb_restored_nodes=$(mb_list_configured_nodes 2>/dev/null); then
    mb_rollback_restore "$_mb_old" "$_mb_current_boot"
    mb_fail reconciliation "Restore could not read the restored configured-node set; the original installation was restored."
    return 1
  fi
  if [ "$MB_TEST_MODE" != "1" ] && [ -n "$_mb_restored_nodes" ]; then
    if ! type ssh_keys_effectively_installed >/dev/null 2>&1 || ! ssh_keys_effectively_installed; then
      warn -c cli,vlan "Restored settings contain nodes, but SSH keys are unavailable; node restore was skipped"
      _mb_partial=1
    elif [ ! -x "$MERV_BASE/functions/sync_nodes.sh" ]; then
      warn -c cli,vlan "Restored sync_nodes.sh is unavailable; node restore was skipped"
      _mb_partial=1
    else
      mb_write_result running syncing_nodes "Synchronizing the restored installation to configured nodes."
      MERV_MAINTENANCE_SYNC=1 sh "$MERV_BASE/functions/sync_nodes.sh" || { warn -c cli,vlan "Restored node synchronization reported errors"; _mb_partial=1; }
      mb_write_result running restoring_node_data "Restoring the shared MAC Shield database to configured nodes."
      mb_push_restored_mac_db "$_mb_restored_nodes" || { warn -c cli,vlan "Restored MAC Shield data could not be applied to every configured node"; _mb_partial=1; }
      mb_write_result running restoring_node_boot "Re-applying the restored boot state to configured nodes."
      mb_apply_restored_node_boot_state "$_mb_restored_nodes" "$_mb_target_boot" || { warn -c cli,vlan "Restored boot state could not be applied to every configured node"; _mb_partial=1; }
    fi
  fi
  mb_write_result running verifying_runtime "Verifying restored hooks and boot state."
  if ! mb_verify_restored_runtime "$_mb_restored_nodes" "$_mb_target_boot"; then
    mb_rollback_restore "$_mb_old" "$_mb_current_boot"
    mb_fail reconciliation "Restore could not verify the required runtime state; the original installation was restored."
    return 1
  fi
  [ "${MB_VERIFY_PARTIAL:-0}" = "0" ] || _mb_partial=1
  if [ "$_mb_create_undo" = "1" ]; then
    mb_write_result running undo_checkpoint "Creating the temporary Undo Restore file."
    if mb_publish_restore_undo "$_mb_old" "$_mb_current_version"; then
      _mb_undo_created=1
      info -c cli,vlan "Undo Restore is available until the router reboots"
      if [ "$MB_UNDO_CLEANUP_WARNING" = "1" ]; then
        warn -c cli,vlan "Undo Restore was created, but the displaced working tree could not be fully removed"
        _mb_partial=1
      fi
    else
      if ! rm -rf "$_mb_old" 2>/dev/null; then
        MB_PRESERVE_WORK=1
        warn -c cli,vlan "Restore succeeded, but the displaced installation could not be removed"
      fi
      warn -c cli,vlan "Restore succeeded, but the temporary Undo Restore file could not be created"
      _mb_partial=1
    fi
  else
    if ! rm -rf "$_mb_old" 2>/dev/null; then
      MB_PRESERVE_WORK=1
      warn -c cli,vlan "The displaced installation could not be removed after restore"
      _mb_partial=1
    fi
    case "$_mb_mode" in
      undo_restore)
        if ! rm -f "$MB_UNDO_RESTORE_ARCHIVE" "$MB_UNDO_RESTORE_META" 2>/dev/null; then
          warn -c cli,vlan "The temporary Undo Restore files could not be removed"
          _mb_partial=1
        fi
        ;;
      undo_update)
        if ! rm -f "$MB_UNDO_UPDATE_MARKER" 2>/dev/null; then
          warn -c cli,vlan "The temporary Undo Update marker could not be removed"
          _mb_partial=1
        fi
        ;;
    esac
  fi
  mb_refresh_inventory
  case "$_mb_mode" in
    restore)
      if [ "$_mb_undo_created" = "1" ]; then
        _mb_success_message="Restore completed successfully. Undo Restore is available until the router reboots."
      else
        _mb_success_message="Restore completed, but no temporary Undo Restore file is available."
      fi
      ;;
    undo_restore) _mb_success_message="Undo Restore completed successfully. The temporary undo point was consumed." ;;
    undo_update) _mb_success_message="Undo Update completed successfully. The temporary undo shortcut was consumed." ;;
  esac
  info -c cli,vlan "$_mb_success_message"
  [ -n "$_mb_current_version" ] && info -c cli,vlan "  From: $_mb_current_version"
  [ -n "$_mb_target_version" ] && info -c cli,vlan "  To:   $_mb_target_version"
  if [ "$_mb_partial" = "1" ]; then
    warn -c cli,vlan "$MB_OPERATION completed with warnings"
    mb_write_result partial complete "$_mb_success_message Review the CLI log for warnings."
  else
    mb_write_result success complete "$_mb_success_message"
  fi
  MB_ACTIVATION_STARTED=0
  MB_RESTORE_ORIGINAL=""
  return 0
}

mb_backup_menu() {
  while :; do
    printf '\nMerVLAN Backup Management\n  1) List backups\n  2) Create manual backup\n  3) Delete selected backup\n  4) Delete all backups\n  0) Exit\nSelect: '
    read _mb_choice
    case "$_mb_choice" in
      1) mb_print_inventory ;;
      2) mb_create_manual "" "" ""; return $? ;;
      3) mb_delete_one "" "" ""; return $? ;;
      4) mb_delete_all "" ""; return $? ;;
      0|'') return 0 ;;
      *) printf 'Invalid selection.\n' ;;
    esac
  done
}

mb_restore_menu() {
  while :; do
    printf '\nMerVLAN Restore Management\n  1) List backups\n  2) Restore selected backup\n  3) Delete selected backup\n  4) Delete all backups\n  5) Undo last restore (temporary)\n  6) Undo last update (temporary shortcut)\n  0) Exit\nSelect: '
    read _mb_choice
    case "$_mb_choice" in
      1) mb_print_inventory ;;
      2) mb_restore "" "" ""; return $? ;;
      3) mb_delete_one "" "" ""; return $? ;;
      4) mb_delete_all "" ""; return $? ;;
      5) mb_restore "" "" "" undo_restore; return $? ;;
      6) mb_restore "" "" "" undo_update; return $? ;;
      0|'') return 0 ;;
      *) printf 'Invalid selection.\n' ;;
    esac
  done
}

case "$1" in
  inventory)
    MB_REQUEST_TOKEN=$(mb_make_token "$2")
    MB_OPERATION=backup_inventory
    mb_install_recovery_helper || warn -c cli,vlan "Emergency recovery helper is unavailable"
    mb_write_inventory "$MB_INVENTORY_FILE" || { mb_fail inventory "Could not generate backup inventory."; exit 1; }
    mb_write_result success complete "Backup inventory refreshed."
    ;;
  backup)
    case "$2" in
      '') mb_backup_menu ;;
      list) if [ "$3" = "--json" ]; then mb_write_inventory -; else mb_print_inventory; fi ;;
      create) mb_create_manual "$3" "$4" "$5" ;;
      delete) mb_delete_one "$3" "$4" "$5" ;;
      delete-all) mb_delete_all "$3" "$4" ;;
      *) echo "Usage: update_mervlan.sh backup [list [--json]|create [tag [yes]]|delete [backup [yes]]|delete-all [yes]]" >&2; exit 1 ;;
    esac
    ;;
  restore)
    case "$2" in
      '') mb_restore_menu ;;
      list) if [ "$3" = "--json" ]; then mb_write_inventory -; else mb_print_inventory; fi ;;
      delete) mb_delete_one "$3" "$4" "$5" ;;
      delete-all) mb_delete_all "$3" "$4" ;;
      *) mb_restore "$2" "$3" "$4" ;;
    esac
    ;;
  undo)
    case "$2" in
      restore) mb_restore "" "$3" "$4" undo_restore ;;
      update) mb_restore "" "$3" "$4" undo_update ;;
      *) echo "Usage: update_mervlan.sh undo {restore|update} [yes]" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "Usage: mervlan_backup.sh {inventory [token]|backup ...|restore ...|undo {restore|update} [yes]}" >&2
    exit 1
    ;;
esac

exit $?
