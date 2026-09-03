#!/bin/sh
#
# ============================================================================ #
#                - File: mervlan_recover.sh || version="0.1"                  #
# ============================================================================ #
# Standalone emergency recovery from a validated persistent MerVLAN backup.    #
# This file must remain usable when /jffs/addons/mervlan is missing or broken.  #
# ============================================================================ #

: "${MERVLAN_RECOVERY_BACKUP_ROOT:=/jffs/addons/mervlan_backups}"
: "${MERVLAN_RECOVERY_ACTIVE_ROOT:=/jffs/addons/mervlan}"
: "${MERVLAN_RECOVERY_TMP_ROOT:=/tmp/mervlan_recovery}"
: "${MERVLAN_RECOVERY_STATE_ROOT:=/jffs/addons/mervlan_state}"
: "${MERVLAN_RECOVERY_TEST_MODE:=0}"

RECOVERY_WORK="$MERVLAN_RECOVERY_TMP_ROOT/restore.$$"
RECOVERY_STAGE="$RECOVERY_WORK/stage"
RECOVERY_ORIGINAL="$RECOVERY_WORK/original"
RECOVERY_TREE=""
RECOVERY_JFFS_STAGE="$MERVLAN_RECOVERY_BACKUP_ROOT/.mervlan.new.$$"
RECOVERY_JFFS_OLD="$MERVLAN_RECOVERY_BACKUP_ROOT/.mervlan.old.$$"
RECOVERY_LOCK="${MERVLAN_RECOVERY_LOCK_OVERRIDE:-${MERVLAN_MAINTENANCE_LOCK_OVERRIDE:-${LOCKDIR:-/tmp/mervlan_tmp/locks}/mervlan_maintenance.lock}}"
RECOVERY_LOCK_OWNED=0
RECOVERY_LOCK_NONCE=""
RECOVERY_LOCK_START=""
RECOVERY_NONCE_SEQ="${RECOVERY_NONCE_SEQ:-0}"
RECOVERY_OWNER_TMP_SEQ="${RECOVERY_OWNER_TMP_SEQ:-0}"
RECOVERY_PRESERVE_JFFS=0
RECOVERY_REPLACED=0
RECOVERY_ROLLING_BACK=0
RECOVERY_RECOVERY_REQUIRED=0
RECOVERY_DURABLE_RECOVERY_OWNED=0
RECOVERY_EXISTING_DURABLE_RECOVERY=0
RECOVERY_EXISTING_UPDATE_RECOVERY=0
RECOVERY_STATE_HELPER="${MERVLAN_RECOVERY_STATE_HELPER:-$MERVLAN_RECOVERY_BACKUP_ROOT/recovery_state.sh}"
RECOVERY_UPDATE_STATE_HELPER="${MERVLAN_RECOVERY_UPDATE_STATE_HELPER:-$MERVLAN_RECOVERY_BACKUP_ROOT/update_state.sh}"

recovery_log() { printf '[MerVLAN recovery] %s\n' "$*"; }
recovery_error() { printf '[MerVLAN recovery] ERROR: %s\n' "$*" >&2; }

recovery_now() {
  recovery_now_value=$(date +%s 2>/dev/null || printf '')
  recovery_positive_uint "$recovery_now_value" || return 1
  printf '%s\n' "$recovery_now_value"
}

# Recovery must remain usable when the installed settings tree is missing or
# damaged.  Its small v2 protocol copy is intentionally not a second generic
# ownership framework; normal maintenance uses settings/lib_owner_lock.sh.
recovery_positive_uint() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  case "$1" in *[1-9]*) return 0 ;; *) return 1 ;; esac
}

recovery_nonce_valid() {
  case "${1:-}" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  [ "${#1}" -le 160 ]
}

recovery_lock_path_valid() {
  case "$RECOVERY_LOCK" in
    /tmp/mervlan_tmp/locks/mervlan_maintenance.lock|/tmp/mervlan_tmp/selftest.*/*) ;;
    *) return 1 ;;
  esac
  case "$RECOVERY_LOCK" in *..*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
}

recovery_proc_start() {
  recovery_pid="$1"
  recovery_positive_uint "$recovery_pid" || return 1
  recovery_stat=$(cat "/proc/$recovery_pid/stat" 2>/dev/null) || return 1
  case "$recovery_stat" in *") "*) recovery_tail=${recovery_stat##*) } ;; *) return 1 ;; esac
  recovery_start=$(printf '%s\n' "$recovery_tail" | awk '{print $20}')
  recovery_positive_uint "$recovery_start" || return 1
  printf '%s\n' "$recovery_start"
}

recovery_owner_v2_read() {
  recovery_owner_file="$1"
  RECOVERY_OWNER_PID=''; RECOVERY_OWNER_START=''; RECOVERY_OWNER_NONCE=''
  RECOVERY_OWNER_CREATED=''; RECOVERY_OWNER_HEARTBEAT=''
  [ -r "$recovery_owner_file" ] || return 1
  recovery_owner_size=$(wc -c < "$recovery_owner_file" 2>/dev/null | awk '{print $1}') || return 1
  case "$recovery_owner_size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$recovery_owner_size" -gt 0 ] 2>/dev/null && [ "$recovery_owner_size" -le 512 ] 2>/dev/null || return 1
  LC_ALL=C grep -q '[^ -~]' "$recovery_owner_file" 2>/dev/null && return 1
  recovery_seen_pid=0; recovery_seen_start=0; recovery_seen_nonce=0
  recovery_seen_created=0; recovery_seen_heartbeat=0; recovery_lines=0
  while IFS= read -r recovery_line || [ -n "$recovery_line" ]; do
    recovery_lines=$((recovery_lines + 1))
    case "$recovery_line" in
      pid=*) [ "$recovery_seen_pid" -eq 0 ] || return 1; recovery_seen_pid=1; recovery_pid=${recovery_line#pid=} ;;
      proc_start_time=*) [ "$recovery_seen_start" -eq 0 ] || return 1; recovery_seen_start=1; recovery_start=${recovery_line#proc_start_time=} ;;
      owner_nonce=*) [ "$recovery_seen_nonce" -eq 0 ] || return 1; recovery_seen_nonce=1; recovery_nonce=${recovery_line#owner_nonce=} ;;
      created=*) [ "$recovery_seen_created" -eq 0 ] || return 1; recovery_seen_created=1; recovery_created=${recovery_line#created=} ;;
      heartbeat=*) [ "$recovery_seen_heartbeat" -eq 0 ] || return 1; recovery_seen_heartbeat=1; recovery_heartbeat=${recovery_line#heartbeat=} ;;
      *) return 1 ;;
    esac
  done < "$recovery_owner_file" || return 1
  [ "$recovery_lines" -eq 5 ] && [ "$recovery_seen_pid" -eq 1 ] &&
    [ "$recovery_seen_start" -eq 1 ] && [ "$recovery_seen_nonce" -eq 1 ] &&
    [ "$recovery_seen_created" -eq 1 ] && [ "$recovery_seen_heartbeat" -eq 1 ] || return 1
  recovery_positive_uint "$recovery_pid" && recovery_positive_uint "$recovery_start" &&
    recovery_nonce_valid "$recovery_nonce" && recovery_positive_uint "$recovery_created" &&
    recovery_positive_uint "$recovery_heartbeat" || return 1
  RECOVERY_OWNER_PID="$recovery_pid"; RECOVERY_OWNER_START="$recovery_start"
  RECOVERY_OWNER_NONCE="$recovery_nonce"; RECOVERY_OWNER_CREATED="$recovery_created"
  RECOVERY_OWNER_HEARTBEAT="$recovery_heartbeat"
}

# This exact four-field compatibility reader belongs only to emergency
# maintenance recovery.  Do not migrate it to the generic owner library.
recovery_owner_legacy_read() {
  recovery_owner_file="$1"
  RECOVERY_OWNER_PID=''; RECOVERY_OWNER_START=''; RECOVERY_OWNER_NONCE=''; RECOVERY_OWNER_CREATED=''
  [ -r "$recovery_owner_file" ] || return 1
  recovery_owner_size=$(wc -c < "$recovery_owner_file" 2>/dev/null | awk '{print $1}') || return 1
  case "$recovery_owner_size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$recovery_owner_size" -gt 0 ] 2>/dev/null && [ "$recovery_owner_size" -le 512 ] 2>/dev/null || return 1
  LC_ALL=C grep -q '[^ -~]' "$recovery_owner_file" 2>/dev/null && return 1
  recovery_seen_pid=0; recovery_seen_start=0; recovery_seen_nonce=0; recovery_seen_created=0; recovery_lines=0
  while IFS= read -r recovery_line || [ -n "$recovery_line" ]; do
    recovery_lines=$((recovery_lines + 1))
    case "$recovery_line" in
      pid=*) [ "$recovery_seen_pid" -eq 0 ] || return 1; recovery_seen_pid=1; recovery_pid=${recovery_line#pid=} ;;
      start=*) [ "$recovery_seen_start" -eq 0 ] || return 1; recovery_seen_start=1; recovery_start=${recovery_line#start=} ;;
      nonce=*) [ "$recovery_seen_nonce" -eq 0 ] || return 1; recovery_seen_nonce=1; recovery_nonce=${recovery_line#nonce=} ;;
      created=*) [ "$recovery_seen_created" -eq 0 ] || return 1; recovery_seen_created=1; recovery_created=${recovery_line#created=} ;;
      *) return 1 ;;
    esac
  done < "$recovery_owner_file" || return 1
  [ "$recovery_lines" -eq 4 ] && [ "$recovery_seen_pid" -eq 1 ] &&
    [ "$recovery_seen_start" -eq 1 ] && [ "$recovery_seen_nonce" -eq 1 ] && [ "$recovery_seen_created" -eq 1 ] || return 1
  recovery_positive_uint "$recovery_pid" && recovery_positive_uint "$recovery_start" &&
    recovery_nonce_valid "$recovery_nonce" && recovery_positive_uint "$recovery_created" || return 1
  RECOVERY_OWNER_PID="$recovery_pid"; RECOVERY_OWNER_START="$recovery_start"
  RECOVERY_OWNER_NONCE="$recovery_nonce"; RECOVERY_OWNER_CREATED="$recovery_created"
}

recovery_lock_read() {
  RECOVERY_LOCK_FORMAT=''
  recovery_owner_v2_read "$RECOVERY_LOCK/owner" && { RECOVERY_LOCK_FORMAT=v2; return 0; }
  # A malformed v2 candidate may not silently fall through to legacy parsing.
  grep -q '^\(proc_start_time\|owner_nonce\|heartbeat\)=' "$RECOVERY_LOCK/owner" 2>/dev/null && return 1
  recovery_owner_legacy_read "$RECOVERY_LOCK/owner" && { RECOVERY_LOCK_FORMAT=legacy; return 0; }
  return 1
}

recovery_lock_owner_state() {
  recovery_lock_read || { printf 'malformed'; return 0; }
  recovery_actual_start=$(recovery_proc_start "$RECOVERY_OWNER_PID" 2>/dev/null)
  if recovery_positive_uint "$recovery_actual_start"; then
    [ "$recovery_actual_start" = "$RECOVERY_OWNER_START" ] || { printf 'reused'; return 0; }
    kill -0 "$RECOVERY_OWNER_PID" 2>/dev/null && { printf 'live'; return 0; }
    printf 'unknown'
  elif [ -e "/proc/$RECOVERY_OWNER_PID/stat" ]; then
    printf 'unknown'
  else
    printf 'dead'
  fi
}

recovery_lock_quarantine() {
  recovery_quarantine_reason="$1"; recovery_quarantine_attempt="$2"
  recovery_now_value=$(recovery_now 2>/dev/null) || return 1
  recovery_quarantine="${RECOVERY_LOCK}.quarantine.${recovery_quarantine_reason}.$$.${recovery_now_value}.${recovery_quarantine_attempt}"
  mv "$RECOVERY_LOCK" "$recovery_quarantine" 2>/dev/null
}

recovery_nonce_next() {
  recovery_start=$(recovery_proc_start "$$" 2>/dev/null) || return 1
  case "$RECOVERY_NONCE_SEQ" in ''|*[!0-9]*) RECOVERY_NONCE_SEQ=0 ;; esac
  RECOVERY_NONCE_SEQ=$((RECOVERY_NONCE_SEQ + 1))
  recovery_now_value=$(recovery_now 2>/dev/null) || return 1
  RECOVERY_NEXT_NONCE="${recovery_now_value}.$$.${recovery_start}.${RECOVERY_NONCE_SEQ}"
  recovery_nonce_valid "$RECOVERY_NEXT_NONCE"
}

recovery_owner_v2_write_atomic() {
  recovery_write_pid="$1"; recovery_write_start="$2"; recovery_write_nonce="$3"
  recovery_write_created="$4"; recovery_write_heartbeat="$5"
  recovery_positive_uint "$recovery_write_pid" && recovery_positive_uint "$recovery_write_start" &&
    recovery_nonce_valid "$recovery_write_nonce" && recovery_positive_uint "$recovery_write_created" && recovery_positive_uint "$recovery_write_heartbeat" || return 1
  case "$RECOVERY_OWNER_TMP_SEQ" in ''|*[!0-9]*) RECOVERY_OWNER_TMP_SEQ=0 ;; esac
  RECOVERY_OWNER_TMP_SEQ=$((RECOVERY_OWNER_TMP_SEQ + 1))
  recovery_tmp="$RECOVERY_LOCK/.owner.tmp.$$.$RECOVERY_OWNER_TMP_SEQ"
  ( umask 077
    printf 'pid=%s\nproc_start_time=%s\nowner_nonce=%s\ncreated=%s\nheartbeat=%s\n' \
      "$recovery_write_pid" "$recovery_write_start" "$recovery_write_nonce" "$recovery_write_created" "$recovery_write_heartbeat" > "$recovery_tmp"
  ) 2>/dev/null || { rm -f "$recovery_tmp" 2>/dev/null; return 1; }
  chmod 600 "$recovery_tmp" 2>/dev/null || { rm -f "$recovery_tmp" 2>/dev/null; return 1; }
  recovery_owner_v2_read "$recovery_tmp" 2>/dev/null || { rm -f "$recovery_tmp" 2>/dev/null; return 1; }
  mv -f "$recovery_tmp" "$RECOVERY_LOCK/owner" 2>/dev/null || { rm -f "$recovery_tmp" 2>/dev/null; return 1; }
}

recovery_acquire_lock() {
  recovery_lock_path_valid || { recovery_error "Unsafe recovery lock path; refusing to run."; return 1; }
  mkdir -p "${RECOVERY_LOCK%/*}" 2>/dev/null || return 1
  recovery_attempt=0
  while ! mkdir "$RECOVERY_LOCK" 2>/dev/null; do
    recovery_lock_state=$(recovery_lock_owner_state)
    case "$recovery_lock_state" in
      live)
        recovery_error "Another MerVLAN update, backup, restore, or deletion is already running."
        return 1
        ;;
      dead|reused)
        recovery_lock_quarantine "$recovery_lock_state" "$recovery_attempt" || return 1
        recovery_attempt=$((recovery_attempt + 1))
        [ "$recovery_attempt" -lt 8 ] || return 1
        ;;
      malformed|unknown|*)
        recovery_error "Recovery lock owner metadata is unknown; refusing to reclaim it."
        return 1
        ;;
    esac
  done
  recovery_lock_start=$(recovery_proc_start "$$" 2>/dev/null) || {
    if ! rmdir "$RECOVERY_LOCK" 2>/dev/null; then recovery_error "Could not remove the unowned recovery lock directory"; fi
    return 1
  }
  recovery_nonce_next || {
    if ! rmdir "$RECOVERY_LOCK" 2>/dev/null; then recovery_error "Could not remove the failed recovery lock directory"; fi
    return 1
  }
  recovery_lock_now=$(recovery_now 2>/dev/null) || { rmdir "$RECOVERY_LOCK" 2>/dev/null || :; return 1; }
  recovery_owner_v2_write_atomic "$$" "$recovery_lock_start" "$RECOVERY_NEXT_NONCE" "$recovery_lock_now" "$recovery_lock_now" || {
    rm -f "$RECOVERY_LOCK/owner" 2>/dev/null || :
    if ! rmdir "$RECOVERY_LOCK" 2>/dev/null; then recovery_error "Could not remove the failed recovery lock directory"; fi
    return 1
  }
  RECOVERY_LOCK_NONCE="$RECOVERY_NEXT_NONCE"
  RECOVERY_LOCK_START="$recovery_lock_start"
  RECOVERY_LOCK_OWNED=1
  return 0
}

recovery_release_lock() {
  [ "$RECOVERY_LOCK_OWNED" = "1" ] || return 0
  recovery_owner_v2_read "$RECOVERY_LOCK/owner" || return 1
  recovery_current_start=$(recovery_proc_start "$$" 2>/dev/null) || return 1
  [ "$RECOVERY_OWNER_PID" = "$$" ] && [ "$RECOVERY_OWNER_START" = "$recovery_current_start" ] && \
    [ -n "$RECOVERY_LOCK_NONCE" ] && [ "$RECOVERY_OWNER_NONCE" = "$RECOVERY_LOCK_NONCE" ] || return 1
  case "$RECOVERY_OWNER_TMP_SEQ" in ''|*[!0-9]*) RECOVERY_OWNER_TMP_SEQ=0 ;; esac
  RECOVERY_OWNER_TMP_SEQ=$((RECOVERY_OWNER_TMP_SEQ + 1))
  recovery_restore="${RECOVERY_LOCK%/*}/.${RECOVERY_LOCK##*/}.owner.restore.$$.${RECOVERY_OWNER_TMP_SEQ}"
  cp -p "$RECOVERY_LOCK/owner" "$recovery_restore" 2>/dev/null || return 1
  rm -f "$RECOVERY_LOCK/owner" 2>/dev/null || { rm -f "$recovery_restore" 2>/dev/null; return 1; }
  if ! rmdir "$RECOVERY_LOCK" 2>/dev/null; then
    mv -f "$recovery_restore" "$RECOVERY_LOCK/owner" 2>/dev/null || return 1
    return 1
  fi
  rm -f "$recovery_restore" 2>/dev/null || :
  RECOVERY_LOCK_OWNED=0
  RECOVERY_LOCK_NONCE=""
  RECOVERY_LOCK_START=""
}

recovery_path_size_kb() {
  recovery_size=$(du -sk "$1" 2>/dev/null | awk 'NR == 1 { print $1 }')
  case "$recovery_size" in ''|*[!0-9]*) recovery_size=0 ;; esac
  printf '%s' "$recovery_size"
}

recovery_require_space() {
  recovery_space_path="$1"
  recovery_required="$2"
  recovery_label="$3"
  recovery_stats=$(df -Pk "$recovery_space_path" 2>/dev/null | awk 'NR == 2 { print $2 "|" $4 }')
  recovery_total=${recovery_stats%%|*}
  recovery_available=${recovery_stats#*|}
  case "$recovery_total" in ''|*[!0-9]*) recovery_error "Could not measure $recovery_label space."; return 1 ;; esac
  case "$recovery_available" in ''|*[!0-9]*) recovery_error "Could not measure available $recovery_label space."; return 1 ;; esac
  recovery_reserve=$((recovery_total / 20))
  [ "$recovery_reserve" -ge 2048 ] || recovery_reserve=2048
  recovery_needed=$((recovery_required + recovery_reserve))
  if [ "$recovery_available" -lt "$recovery_needed" ]; then
    recovery_error "Not enough $recovery_label space: need ${recovery_needed} KB including reserve; ${recovery_available} KB is available."
    return 1
  fi
}

recovery_archive_id_valid() {
  case "$1" in ''|*/*|*..*|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*) return 1 ;; esac
  printf '%s\n' "$1" | grep -Eq '^mervlan\.backup\.[A-Za-z0-9_-]+\.tar\.gz$|^mervlan\.manual\.backup\.[0-9]{8}-[0-9]{6}\.[A-Za-z0-9][A-Za-z0-9_-]{0,23}\.tar\.gz$'
}

recovery_path_safe() {
  case "$1" in
    "$MERVLAN_RECOVERY_TMP_ROOT"/restore.*|"$MERVLAN_RECOVERY_TMP_ROOT"/restore.*/*) return 0 ;;
    *) return 1 ;;
  esac
}

recovery_load_durable_state() {
  MERV_MAINTENANCE_RECOVERY_ROOT="$MERVLAN_RECOVERY_BACKUP_ROOT"
  MERV_MAINTENANCE_RECOVERY_MARKER="$MERVLAN_RECOVERY_BACKUP_ROOT/.mervlan.recovery"
  [ -r "$RECOVERY_STATE_HELPER" ] || return 1
  [ -n "${LIB_MAINTENANCE_RECOVERY_LOADED:-}" ] || . "$RECOVERY_STATE_HELPER" || return 1
}

# Recovery may run after the active tree was damaged, so use the atomically
# published copy beside the backup archive rather than trusting that tree.
recovery_load_update_state() {
  MERV_STATE_ROOT="$MERVLAN_RECOVERY_STATE_ROOT"
  MERV_UPDATE_JOURNAL="$MERV_STATE_ROOT/update.journal"
  MERV_UPDATE_QUIESCE_FILE="$MERV_STATE_ROOT/update.quiesce"
  [ -r "$RECOVERY_UPDATE_STATE_HELPER" ] || return 1
  [ -n "${LIB_UPDATE_STATE_LOADED:-}" ] || . "$RECOVERY_UPDATE_STATE_HELPER" || return 1
}

# Return 0 for a valid unresolved Update, 1 for no Update recovery requirement,
# and 2 for malformed durable Update state.  The latter must never be guessed
# away by an emergency Recovery invocation.
recovery_update_recovery_status() {
  merv_update_quiesce_state
  case "${MERV_UPDATE_QUIESCE_STATE:-absent}" in
    malformed) return 2 ;;
    active) return 0 ;;
  esac
  merv_update_journal_state
  case "${MERV_UPDATE_JOURNAL_STATE:-absent}" in
    malformed) return 2 ;;
    active)
      if merv_update_journal_requires_safe_boot; then return 0; fi
      ;;
  esac
  return 1
}

# An Update journal is durable transaction truth.  On a successful explicit
# Recovery, retire only its exact recorded JFFS stages before clearing that
# journal; never glob unrelated interrupted transactions.
recovery_drop_update_recorded_stages() {
  for recovery_update_stage in \
    "$(merv_update_journal_get jffs_stage_path none)" \
    "$(merv_update_journal_get jffs_old_path none)"; do
    case "$recovery_update_stage" in
      none|'') continue ;;
      "$MERVLAN_RECOVERY_BACKUP_ROOT"/.mervlan.new.*|"$MERVLAN_RECOVERY_BACKUP_ROOT"/.mervlan.old.*)
        [ -e "$recovery_update_stage" ] && rm -rf "$recovery_update_stage" 2>/dev/null || :
        ;;
      *) return 1 ;;
    esac
  done
  return 0
}

recovery_begin_durable_recovery() {
  merv_maintenance_recovery_write recovery prepared "$RECOVERY_JFFS_OLD" "$RECOVERY_JFFS_STAGE" || return 1
  RECOVERY_DURABLE_RECOVERY_OWNED=1
}

recovery_mark_durable_recovery_displaced() {
  [ "$RECOVERY_DURABLE_RECOVERY_OWNED" = "1" ] || return 0
  merv_maintenance_recovery_matches recovery "$RECOVERY_JFFS_OLD" "$RECOVERY_JFFS_STAGE" || return 1
  merv_maintenance_recovery_write recovery displaced "$RECOVERY_JFFS_OLD" "$RECOVERY_JFFS_STAGE"
}

recovery_clear_durable_recovery() {
  [ "$RECOVERY_DURABLE_RECOVERY_OWNED" = "1" ] || return 0
  merv_maintenance_recovery_matches recovery "$RECOVERY_JFFS_OLD" "$RECOVERY_JFFS_STAGE" || return 1
  merv_maintenance_recovery_clear || return 1
  RECOVERY_DURABLE_RECOVERY_OWNED=0
}

recovery_activation_started() {
  [ "$RECOVERY_REPLACED" = "1" ] && return 0
  case "$RECOVERY_JFFS_OLD" in
    "$MERVLAN_RECOVERY_BACKUP_ROOT"/.mervlan.old.*) [ -d "$RECOVERY_JFFS_OLD" ] || return 1 ;;
    *) return 1 ;;
  esac
  RECOVERY_REPLACED=1
  return 0
}

recovery_cleanup() {
  recovery_cleanup_rc=$?
  recovery_cleanup_failed=0
  if [ "$RECOVERY_RECOVERY_REQUIRED" = "1" ]; then
    RECOVERY_PRESERVE_JFFS=1
    recovery_cleanup_failed=1
    recovery_error "Recovery cleanup preserved work, recovery trees, and owner lock because rollback recovery remains incomplete"
  elif recovery_path_safe "$RECOVERY_WORK" && [ -d "$RECOVERY_WORK" ]; then
    if ! rm -rf "$RECOVERY_WORK" 2>/dev/null; then
      recovery_error "Could not remove recovery workspace $RECOVERY_WORK"
      recovery_cleanup_failed=1
    fi
  fi
  if [ "$RECOVERY_RECOVERY_REQUIRED" != "1" ] && [ "$RECOVERY_PRESERVE_JFFS" != "1" ]; then
    case "$RECOVERY_JFFS_STAGE" in
      "$MERVLAN_RECOVERY_BACKUP_ROOT"/.mervlan.new.*)
        if ! rm -rf "$RECOVERY_JFFS_STAGE" 2>/dev/null; then
          recovery_error "Could not remove recovery activation stage $RECOVERY_JFFS_STAGE"
          recovery_cleanup_failed=1
        fi
        ;;
    esac
  fi
  if [ "$RECOVERY_DURABLE_RECOVERY_OWNED" = "1" ] && \
     merv_maintenance_recovery_read && \
     [ "$MERV_MAINTENANCE_RECOVERY_PHASE" = "prepared" ] && \
     [ ! -e "$MERV_MAINTENANCE_RECOVERY_OLD" ] && \
     [ ! -e "$MERV_MAINTENANCE_RECOVERY_STAGE" ]; then
    recovery_clear_durable_recovery || recovery_cleanup_failed=1
  fi
  if [ "$RECOVERY_RECOVERY_REQUIRED" != "1" ] && [ "$RECOVERY_PRESERVE_JFFS" != "1" ] && [ "$RECOVERY_REPLACED" = "0" ]; then
    case "$RECOVERY_JFFS_OLD" in
      "$MERVLAN_RECOVERY_BACKUP_ROOT"/.mervlan.old.*)
        if ! rm -rf "$RECOVERY_JFFS_OLD" 2>/dev/null; then
          recovery_error "Could not remove recovery rollback tree $RECOVERY_JFFS_OLD"
          recovery_cleanup_failed=1
        fi
        ;;
    esac
  fi
  if [ "$RECOVERY_RECOVERY_REQUIRED" != "1" ] && ! recovery_release_lock; then
    recovery_error "Recovery cleanup could not release its owner lock"
    recovery_cleanup_failed=1
  fi
  [ "$recovery_cleanup_failed" -eq 0 ] || recovery_cleanup_rc=1
  return "$recovery_cleanup_rc"
}

recovery_mark_rollback_required() {
  RECOVERY_RECOVERY_REQUIRED=1
  RECOVERY_PRESERVE_JFFS=1
  if [ "$RECOVERY_DURABLE_RECOVERY_OWNED" = "1" ] && \
     ! recovery_mark_durable_recovery_displaced; then
    recovery_error "CRITICAL: durable Recovery metadata could not record the interrupted activation"
  fi
}

recovery_reconcile_stale_stages() {
  if type recovery_update_recovery_status >/dev/null 2>&1; then
    recovery_update_recovery_status
    recovery_update_state_rc=$?
    case "$recovery_update_state_rc" in
      0) recovery_log "An unresolved Update recovery record protects recovery trees."; return 0 ;;
      1) ;;
      *) recovery_error "Durable Update recovery metadata is malformed or unreadable; preserving recovery trees."; return 1 ;;
    esac
  fi
  merv_maintenance_recovery_read
  recovery_state_rc=$?
  case "$recovery_state_rc:${MERV_MAINTENANCE_RECOVERY_STATUS:-unknown}" in
    0:active)
      if [ "$MERV_MAINTENANCE_RECOVERY_PHASE" = "prepared" ] && \
         [ ! -e "$MERV_MAINTENANCE_RECOVERY_OLD" ] && \
         [ -d "$MERV_MAINTENANCE_RECOVERY_STAGE" ] && \
         recovery_tree_valid "$MERVLAN_RECOVERY_ACTIVE_ROOT"; then
        rm -rf "$MERV_MAINTENANCE_RECOVERY_STAGE" 2>/dev/null && \
          merv_maintenance_recovery_clear || return 1
      else
        recovery_log "Durable ${MERV_MAINTENANCE_RECOVERY_KIND} recovery state is unresolved; preserving all recovery trees."
        return 0
      fi
      ;;
    1:absent) ;;
    *) recovery_error "Durable maintenance-recovery metadata is malformed or unreadable; preserving recovery trees."; return 1 ;;
  esac
  if ! recovery_tree_valid "$MERVLAN_RECOVERY_ACTIVE_ROOT"; then
    recovery_log "Active installation is incomplete; preserving all .mervlan.new/.mervlan.old recovery trees."
    return 0
  fi
  recovery_stale_failed=0
  for recovery_stale in "$MERVLAN_RECOVERY_BACKUP_ROOT"/.mervlan.new.*; do
    [ -d "$recovery_stale" ] || continue
    if ! rm -rf "$recovery_stale" 2>/dev/null; then
      recovery_error "Could not remove stale recovery stage $recovery_stale"
      recovery_stale_failed=1
    fi
  done
  for recovery_stale in "$MERVLAN_RECOVERY_BACKUP_ROOT"/.mervlan.old.*; do
    [ -d "$recovery_stale" ] || continue
    if ! rm -rf "$recovery_stale" 2>/dev/null; then
      recovery_error "Could not remove stale recovery rollback tree $recovery_stale"
      recovery_stale_failed=1
    fi
  done
  [ "$recovery_stale_failed" -eq 0 ]
}

recovery_settings_valid() {
  recovery_settings="$1"
  [ -s "$recovery_settings" ] || return 1
  for recovery_key in General SSH Nodes SSH_USER SSH_PORT; do
    grep -q "\"${recovery_key}\"[[:space:]]*:" "$recovery_settings" 2>/dev/null || return 1
  done
  recovery_opens=$(tr -cd '{' < "$recovery_settings" 2>/dev/null | wc -c | tr -d '[:space:]')
  recovery_closes=$(tr -cd '}' < "$recovery_settings" 2>/dev/null | wc -c | tr -d '[:space:]')
  [ -n "$recovery_opens" ] && [ "$recovery_opens" = "$recovery_closes" ]
}

recovery_tree_valid() {
  recovery_root="$1"
  [ -d "$recovery_root" ] || return 1
  for recovery_required in install.sh uninstall.sh changelog.txt mervlan.asp \
    functions/update_mervlan.sh functions/mervlan_boot.sh settings/settings.json www/index.html; do
    [ -f "$recovery_root/$recovery_required" ] || return 1
  done
  recovery_settings_valid "$recovery_root/settings/settings.json"
}

recovery_meta_value() {
  recovery_meta_file="$1"
  recovery_meta_key="$2"
  sed -n "s/^${recovery_meta_key}=//p" "$recovery_meta_file" 2>/dev/null | tail -n1
}

recovery_checksum_valid() {
  recovery_archive="$1"
  recovery_meta="${recovery_archive}.meta"
  [ -f "$recovery_meta" ] || {
    recovery_log "Legacy backup without checksum metadata; using full archive validation."
    return 0
  }
  type md5sum >/dev/null 2>&1 || {
    recovery_error "md5sum is unavailable; checksum cannot be verified."
    return 1
  }
  [ "$(recovery_meta_value "$recovery_meta" format)" = "1" ] || return 1
  [ "$(recovery_meta_value "$recovery_meta" archive)" = "${recovery_archive##*/}" ] || return 1
  [ "$(recovery_meta_value "$recovery_meta" algorithm)" = "md5" ] || return 1
  recovery_expected=$(recovery_meta_value "$recovery_meta" checksum)
  recovery_actual=$(md5sum "$recovery_archive" 2>/dev/null | awk 'NR == 1 { print $1 }')
  [ -n "$recovery_expected" ] && [ "$recovery_expected" = "$recovery_actual" ]
}

recovery_validate_archive() {
  recovery_archive="$1"
  [ -f "$recovery_archive" ] || { recovery_error "Backup not found: $recovery_archive"; return 1; }
  recovery_checksum_valid "$recovery_archive" || { recovery_error "Backup checksum validation failed."; return 1; }
  mkdir -p "$RECOVERY_STAGE" 2>/dev/null || return 1
  tar -tvzf "$recovery_archive" > "$RECOVERY_WORK/archive.verbose" 2>/dev/null || return 1
  awk '{ t=substr($0,1,1); if (t != "-" && t != "d") bad=1 } END { exit bad }' \
    "$RECOVERY_WORK/archive.verbose" || { recovery_error "Backup contains links or unsupported file types."; return 1; }
  tar -tzf "$recovery_archive" > "$RECOVERY_WORK/archive.list" 2>/dev/null || return 1
  [ -s "$RECOVERY_WORK/archive.list" ] || return 1
  if grep -Eq '(^/|(^|/)\.\.(/|$)|[[:cntrl:]])' "$RECOVERY_WORK/archive.list" 2>/dev/null; then
    recovery_error "Backup contains an unsafe path."
    return 1
  fi
  recovery_archive_root=$(awk -F/ 'NF { print $1; exit }' "$RECOVERY_WORK/archive.list")
  [ -n "$recovery_archive_root" ] || return 1
  awk -F/ -v root="$recovery_archive_root" 'NF && $1 != root { bad=1 } END { exit bad }' \
    "$RECOVERY_WORK/archive.list" || { recovery_error "Backup contains more than one root directory."; return 1; }
  tar -xzf "$recovery_archive" -C "$RECOVERY_STAGE" >/dev/null 2>&1 || return 1
  RECOVERY_TREE="$RECOVERY_STAGE/$recovery_archive_root"
  recovery_tree_valid "$RECOVERY_TREE" || { recovery_error "Backup is missing required MerVLAN files or valid settings."; return 1; }
}

recovery_list() {
  recovery_count=0
  recovery_log "Available persistent backups:"
  for recovery_archive in "$MERVLAN_RECOVERY_BACKUP_ROOT"/mervlan.backup.*.tar.gz \
    "$MERVLAN_RECOVERY_BACKUP_ROOT"/mervlan.manual.backup.*.tar.gz; do
    [ -f "$recovery_archive" ] || continue
    recovery_archive_id_valid "${recovery_archive##*/}" || continue
    recovery_count=$((recovery_count + 1))
    printf '  %d) %s\n' "$recovery_count" "${recovery_archive##*/}"
  done
  [ "$recovery_count" -gt 0 ] || printf '  No backups found.\n'
}

recovery_boot_state() {
  if grep -q '"BOOT_ENABLED"[[:space:]]*:[[:space:]]*"1"' "$1/settings/settings.json" 2>/dev/null; then
    printf '1'
  else
    printf '0'
  fi
}

recovery_copy_tree() {
  recovery_source="$1"
  recovery_destination="$2"
  [ -d "$recovery_source" ] || return 1
  [ ! -e "$recovery_destination" ] || return 1
  mkdir -p "${recovery_destination%/*}" 2>/dev/null || return 1
  cp -pR "$recovery_source" "$recovery_destination" 2>/dev/null
}

recovery_reconcile() {
  recovery_target="$1"
  recovery_boot="$2"
  [ "$MERVLAN_RECOVERY_TEST_MODE" = "1" ] && return 0
  # Reconciliation invokes the installed tree's public maintenance entry
  # points.  Bind those children to this live recovery owner; the child guard
  # still verifies the canonical owner file and PID/start identity.
  MERV_MAINTENANCE_DELEGATED=1
  MERV_MAINTENANCE_DELEGATION_KIND=recovery
  MERV_RECOVERY_DELEGATION=1
  MERV_MAINTENANCE_OWNER_PID="$$"
  MERV_MAINTENANCE_OWNER_START="$RECOVERY_LOCK_START"
  MERV_MAINTENANCE_OWNER_NONCE="$RECOVERY_LOCK_NONCE"
  export MERV_MAINTENANCE_DELEGATED MERV_MAINTENANCE_DELEGATION_KIND \
    MERV_RECOVERY_DELEGATION \
    MERV_MAINTENANCE_OWNER_PID MERV_MAINTENANCE_OWNER_START \
    MERV_MAINTENANCE_OWNER_NONCE
  chmod 755 "$recovery_target"/*.sh "$recovery_target"/functions/*.sh 2>/dev/null || return 1
  chmod 644 "$recovery_target"/settings/*.sh "$recovery_target"/www/*.css "$recovery_target"/www/*.html 2>/dev/null || return 1
  sh "$recovery_target/uninstall.sh" reinstall >/dev/null 2>&1 || return 1
  sh "$recovery_target/install.sh" reinstall >/dev/null 2>&1 || return 1
  if [ -x "$recovery_target/functions/hw_probe.sh" ] && ! sh "$recovery_target/functions/hw_probe.sh" >/dev/null 2>&1; then
    recovery_error "Restored hardware probe failed."
    return 1
  fi
  if [ "$recovery_boot" = "1" ]; then
    MERV_SKIP_NODE_SYNC=1 sh "$recovery_target/functions/mervlan_boot.sh" setupenable >/dev/null 2>&1 || return 1
    MERV_SKIP_NODE_SYNC=1 sh "$recovery_target/functions/mervlan_boot.sh" enable >/dev/null 2>&1 || return 1
  else
    MERV_SKIP_NODE_SYNC=1 sh "$recovery_target/functions/mervlan_boot.sh" setupenable >/dev/null 2>&1 || return 1
    MERV_SKIP_NODE_SYNC=1 sh "$recovery_target/functions/mervlan_boot.sh" disable >/dev/null 2>&1 || return 1
  fi
}

recovery_rollback() {
  [ "$RECOVERY_REPLACED" = "1" ] || return 1
  [ "$RECOVERY_ROLLING_BACK" = "0" ] || return 1
  RECOVERY_ROLLING_BACK=1
  recovery_error "Recovery activation failed; restoring the installation saved in RAM."
  case "$MERVLAN_RECOVERY_ACTIVE_ROOT" in /|/jffs|/jffs/addons|/tmp|'') recovery_mark_rollback_required; return 1 ;; esac
  rm -rf "$RECOVERY_JFFS_STAGE" 2>/dev/null || { recovery_mark_rollback_required; return 1; }
  if [ -d "$MERVLAN_RECOVERY_ACTIVE_ROOT" ] && ! mv "$MERVLAN_RECOVERY_ACTIVE_ROOT" "$RECOVERY_JFFS_STAGE" 2>/dev/null; then
    recovery_mark_rollback_required
    return 1
  fi
  if [ -d "$RECOVERY_JFFS_OLD" ]; then
    mv "$RECOVERY_JFFS_OLD" "$MERVLAN_RECOVERY_ACTIVE_ROOT" 2>/dev/null || { recovery_mark_rollback_required; return 1; }
  else
    recovery_copy_tree "$RECOVERY_ORIGINAL" "$MERVLAN_RECOVERY_ACTIVE_ROOT" || { recovery_mark_rollback_required; return 1; }
  fi
  if ! rm -rf "$RECOVERY_JFFS_STAGE" 2>/dev/null; then
    recovery_mark_rollback_required
    return 1
  fi
  if ! recovery_reconcile "$MERVLAN_RECOVERY_ACTIVE_ROOT" "$(recovery_boot_state "$MERVLAN_RECOVERY_ACTIVE_ROOT")"; then
    recovery_mark_rollback_required
    return 1
  fi
  RECOVERY_REPLACED=0
  if ! recovery_clear_durable_recovery; then
    recovery_mark_rollback_required
    return 1
  fi
  return 0
}

recovery_on_signal() {
  recovery_signal="$1"
  trap - INT TERM
  if recovery_activation_started && ! recovery_rollback; then
    recovery_mark_rollback_required
    recovery_error "Interrupted recovery rollback failed; recovery trees were preserved."
  fi
  recovery_cleanup
  exit "$recovery_signal"
}

recovery_restore() {
  recovery_id="$1"
  recovery_confirm="$2"
  recovery_archive_id_valid "$recovery_id" || { recovery_error "Invalid backup identifier."; return 1; }
  recovery_archive="$MERVLAN_RECOVERY_BACKUP_ROOT/$recovery_id"
  recovery_load_durable_state || { recovery_error "Durable maintenance-recovery state is unavailable; refusing destructive recovery."; return 1; }
  recovery_load_update_state || { recovery_error "Durable Update recovery state is unavailable; refusing destructive recovery."; return 1; }
  recovery_update_recovery_status
  recovery_update_state_rc=$?
  case "$recovery_update_state_rc" in
    0) RECOVERY_EXISTING_UPDATE_RECOVERY=1 ;;
    1) RECOVERY_EXISTING_UPDATE_RECOVERY=0 ;;
    *) recovery_error "Durable Update recovery metadata is malformed or unreadable; inspect recovery state before retrying."; return 1 ;;
  esac
  merv_maintenance_recovery_read
  recovery_state_rc=$?
  case "$recovery_state_rc:${MERV_MAINTENANCE_RECOVERY_STATUS:-unknown}" in
    0:active) RECOVERY_EXISTING_DURABLE_RECOVERY=1 ;;
    1:absent) RECOVERY_EXISTING_DURABLE_RECOVERY=0 ;;
    *) recovery_error "Durable maintenance-recovery metadata is malformed or unreadable; inspect recovery trees before retrying."; return 1 ;;
  esac
  recovery_acquire_lock || return 1
  mkdir -p "$RECOVERY_WORK" 2>/dev/null || { recovery_error "Could not create recovery workspace in /tmp."; return 1; }
  chmod 700 "$RECOVERY_WORK" 2>/dev/null || { recovery_error "Could not secure the recovery workspace."; return 1; }
  trap 'recovery_on_signal 130' INT
  trap 'recovery_on_signal 143' TERM
  recovery_log "Validating $recovery_id"
  recovery_validate_archive "$recovery_archive" || return 1
  if ! recovery_reconcile_stale_stages; then
    recovery_error "Stale recovery trees could not be reconciled; restore is blocked."
    return 1
  fi
  merv_maintenance_recovery_read
  recovery_state_rc=$?
  case "$recovery_state_rc:${MERV_MAINTENANCE_RECOVERY_STATUS:-unknown}" in
    1:absent) RECOVERY_EXISTING_DURABLE_RECOVERY=0 ;;
    0:active) ;;
    *) recovery_error "Durable maintenance-recovery metadata became malformed during validation."; return 1 ;;
  esac
  recovery_target_boot=$(recovery_boot_state "$RECOVERY_TREE")
  if [ "$recovery_confirm" != "yes" ]; then
    printf 'Restore %s to %s? [y/N]: ' "$recovery_id" "$MERVLAN_RECOVERY_ACTIVE_ROOT"
    read recovery_answer
    case "$recovery_answer" in y|Y|yes|YES) ;; *) recovery_log "Recovery cancelled."; return 2 ;; esac
  fi
  recovery_current_kb=$(recovery_path_size_kb "$MERVLAN_RECOVERY_ACTIVE_ROOT")
  recovery_target_kb=$(recovery_path_size_kb "$RECOVERY_TREE")
  recovery_require_space "$MERVLAN_RECOVERY_TMP_ROOT" "$recovery_current_kb" "temporary recovery" || return 1
  recovery_require_space "$MERVLAN_RECOVERY_BACKUP_ROOT" "$recovery_target_kb" "JFFS activation staging" || return 1
  if [ -d "$MERVLAN_RECOVERY_ACTIVE_ROOT" ]; then
    recovery_log "Saving the current installation temporarily in RAM."
    recovery_copy_tree "$MERVLAN_RECOVERY_ACTIVE_ROOT" "$RECOVERY_ORIGINAL" || {
      recovery_error "Could not create the temporary rollback copy."
      return 1
    }
  fi
  mkdir -p "$MERVLAN_RECOVERY_BACKUP_ROOT" 2>/dev/null || return 1
  if [ -e "$RECOVERY_JFFS_STAGE" ] || [ -e "$RECOVERY_JFFS_OLD" ]; then
    RECOVERY_PRESERVE_JFFS=1
    recovery_error "A preserved activation tree uses this process slot. Nothing was removed; inspect the .mervlan.new/.mervlan.old directories first."
    return 1
  fi
  recovery_copy_tree "$RECOVERY_TREE" "$RECOVERY_JFFS_STAGE" || {
    recovery_error "Could not create the temporary JFFS activation stage."
    return 1
  }
  recovery_tree_valid "$RECOVERY_JFFS_STAGE" || {
    recovery_error "The temporary JFFS activation stage failed validation."
    return 1
  }
  if [ "$MERVLAN_RECOVERY_TEST_MODE" != "1" ] && [ -x "$MERVLAN_RECOVERY_ACTIVE_ROOT/functions/mervlan_boot.sh" ]; then
    if ! MERV_SKIP_NODE_SYNC=1 sh "$MERVLAN_RECOVERY_ACTIVE_ROOT/functions/mervlan_boot.sh" disable >/dev/null 2>&1; then
      recovery_error "Could not disable the current MerVLAN runtime before recovery activation."
      return 1
    fi
    if ! MERV_SKIP_NODE_SYNC=1 sh "$MERVLAN_RECOVERY_ACTIVE_ROOT/functions/mervlan_boot.sh" setupdisable >/dev/null 2>&1; then
      recovery_error "Could not remove the current MerVLAN hooks before recovery activation."
      return 1
    fi
  fi
  case "$MERVLAN_RECOVERY_ACTIVE_ROOT" in /|/jffs|/jffs/addons|/tmp|'') recovery_error "Unsafe active path."; return 1 ;; esac
  if [ "$RECOVERY_EXISTING_DURABLE_RECOVERY" = "0" ] && ! recovery_begin_durable_recovery; then
    RECOVERY_PRESERVE_JFFS=1
    recovery_error "Could not publish durable Recovery metadata before activation. No installation files were replaced."
    return 1
  fi
  if [ -d "$MERVLAN_RECOVERY_ACTIVE_ROOT" ]; then
    mv "$MERVLAN_RECOVERY_ACTIVE_ROOT" "$RECOVERY_JFFS_OLD" 2>/dev/null || return 1
  fi
  if ! recovery_mark_durable_recovery_displaced; then
    recovery_activation_started
    if ! recovery_rollback; then RECOVERY_PRESERVE_JFFS=1; fi
    return 1
  fi
  RECOVERY_REPLACED=1
  mv "$RECOVERY_JFFS_STAGE" "$MERVLAN_RECOVERY_ACTIVE_ROOT" 2>/dev/null || {
    if ! recovery_rollback; then RECOVERY_PRESERVE_JFFS=1; fi
    return 1
  }
  recovery_tree_valid "$MERVLAN_RECOVERY_ACTIVE_ROOT" || {
    if ! recovery_rollback; then RECOVERY_PRESERVE_JFFS=1; fi
    return 1
  }
  recovery_reconcile "$MERVLAN_RECOVERY_ACTIVE_ROOT" "$recovery_target_boot" || {
    if ! recovery_rollback; then RECOVERY_PRESERVE_JFFS=1; fi
    return 1
  }
  RECOVERY_REPLACED=0
  if ! rm -rf "$RECOVERY_JFFS_OLD" 2>/dev/null; then
    RECOVERY_PRESERVE_JFFS=1
    recovery_error "Recovery completed, but the displaced installation could not be removed."
    return 1
  fi
  if [ "$RECOVERY_EXISTING_DURABLE_RECOVERY" = "1" ]; then
    if ! merv_maintenance_recovery_drop_recorded_stages; then
      recovery_mark_rollback_required
      recovery_error "Recovery completed, but the previously protected transaction could not be retired."
      return 1
    fi
  elif ! recovery_clear_durable_recovery; then
    recovery_mark_rollback_required
    recovery_error "Recovery completed, but durable Recovery metadata could not be cleared."
    return 1
  fi
  if [ "$RECOVERY_EXISTING_UPDATE_RECOVERY" = "1" ] && \
     { ! recovery_drop_update_recorded_stages || ! merv_update_quiesce_clear || ! merv_update_journal_clear; }; then
    recovery_mark_rollback_required
    recovery_error "Recovery completed, but the prior Update recovery record could not be cleared."
    return 1
  fi
  recovery_log "Main-router recovery completed successfully."
  recovery_log "Run MerVLAN node synchronization after confirming the main router."
  return 0
}

recovery_check() {
  recovery_id="$1"
  recovery_archive_id_valid "$recovery_id" || { recovery_error "Invalid backup identifier."; return 1; }
  mkdir -p "$RECOVERY_WORK" 2>/dev/null || return 1
  recovery_validate_archive "$MERVLAN_RECOVERY_BACKUP_ROOT/$recovery_id" || return 1
  recovery_log "Backup validation passed: $recovery_id"
}

recovery_usage() {
  cat <<'EOF'
Usage:
  recover.sh list
  recover.sh check <archive-id>
  recover.sh restore <archive-id> [yes]

The restore command replaces the main-router MerVLAN installation. It does not
promise power-loss atomicity. Validate the backup first and restore nodes after
the main router is confirmed working.
EOF
}

if [ "${MERVLAN_RECOVERY_SOURCE_ONLY:-0}" = "1" ]; then
  # Isolated protocol tests source the standalone implementation without
  # installing or loading any settings library.
  return 0 2>/dev/null || exit 0
fi

trap recovery_cleanup EXIT
case "$1" in
  list) recovery_list ;;
  check) [ -n "$2" ] || { recovery_usage >&2; exit 1; }; recovery_check "$2" ;;
  restore) [ -n "$2" ] || { recovery_usage >&2; exit 1; }; recovery_restore "$2" "$3" ;;
  ''|-h|--help|help) recovery_usage ;;
  *) recovery_usage >&2; exit 1 ;;
esac
