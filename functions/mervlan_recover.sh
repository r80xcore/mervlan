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
: "${MERVLAN_RECOVERY_TEST_MODE:=0}"

RECOVERY_WORK="$MERVLAN_RECOVERY_TMP_ROOT/restore.$$"
RECOVERY_STAGE="$RECOVERY_WORK/stage"
RECOVERY_ORIGINAL="$RECOVERY_WORK/original"
RECOVERY_TREE=""
RECOVERY_JFFS_STAGE="$MERVLAN_RECOVERY_BACKUP_ROOT/.mervlan.new.$$"
RECOVERY_JFFS_OLD="$MERVLAN_RECOVERY_BACKUP_ROOT/.mervlan.old.$$"
RECOVERY_LOCK="${MERVLAN_RECOVERY_LOCK_OVERRIDE:-/tmp/mervlan_tmp/locks/mervlan_maintenance.lock}"
RECOVERY_LOCK_OWNED=0
RECOVERY_LOCK_NONCE=""
RECOVERY_PRESERVE_JFFS=0
RECOVERY_REPLACED=0
RECOVERY_ROLLING_BACK=0

recovery_log() { printf '[MerVLAN recovery] %s\n' "$*"; }
recovery_error() { printf '[MerVLAN recovery] ERROR: %s\n' "$*" >&2; }

recovery_now() {
  date +%s 2>/dev/null || printf '0'
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
  case "$recovery_pid" in ''|*[!0-9]*) return 1 ;; esac
  recovery_stat=$(cat "/proc/$recovery_pid/stat" 2>/dev/null) || return 1
  case "$recovery_stat" in *") "*) recovery_tail=${recovery_stat##*) } ;; *) return 1 ;; esac
  recovery_start=$(printf '%s\n' "$recovery_tail" | awk '{print $20}')
  case "$recovery_start" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$recovery_start"
}

recovery_lock_read() {
  recovery_lock_pid=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' "$RECOVERY_LOCK/owner" 2>/dev/null | head -n 1)
  recovery_lock_start=$(sed -n 's/^start=\([0-9][0-9]*\)$/\1/p' "$RECOVERY_LOCK/owner" 2>/dev/null | head -n 1)
  recovery_lock_nonce=$(sed -n 's/^nonce=\([A-Za-z0-9._:-][A-Za-z0-9._:-]*\)$/\1/p' "$RECOVERY_LOCK/owner" 2>/dev/null | head -n 1)
  case "$recovery_lock_pid:$recovery_lock_start" in *[!0-9:]*|:*|*::*) return 1 ;; esac
  [ -n "$recovery_lock_nonce" ]
}

recovery_lock_identity_matches() {
  recovery_actual_start=$(recovery_proc_start "$1" 2>/dev/null) || return 1
  [ "$recovery_actual_start" = "$2" ]
}

recovery_acquire_lock() {
  recovery_lock_path_valid || { recovery_error "Unsafe recovery lock path; refusing to run."; return 1; }
  mkdir -p "${RECOVERY_LOCK%/*}" 2>/dev/null || return 1
  recovery_attempt=0
  while ! mkdir "$RECOVERY_LOCK" 2>/dev/null; do
    recovery_lock_read || {
      recovery_error "Recovery lock owner metadata is unknown; refusing to reclaim it."
      return 1
    }
    if recovery_lock_identity_matches "$recovery_lock_pid" "$recovery_lock_start"; then
      recovery_error "Another MerVLAN update, backup, restore, or deletion is already running."
      return 1
    fi
    recovery_quarantine="${RECOVERY_LOCK}.quarantine.$$.$recovery_attempt"
    mv "$RECOVERY_LOCK" "$recovery_quarantine" 2>/dev/null || return 1
    recovery_attempt=$((recovery_attempt + 1))
    [ "$recovery_attempt" -lt 8 ] || return 1
  done
  recovery_lock_start=$(recovery_proc_start "$$" 2>/dev/null) || {
    if ! rmdir "$RECOVERY_LOCK" 2>/dev/null; then recovery_error "Could not remove the unowned recovery lock directory"; fi
    return 1
  }
  recovery_lock_nonce="$(recovery_now).$$.${RANDOM:-0}"
  recovery_lock_tmp="$RECOVERY_LOCK/.owner.tmp.$$"
  ( umask 077; printf 'pid=%s\nstart=%s\nnonce=%s\ncreated=%s\n' "$$" "$recovery_lock_start" "$recovery_lock_nonce" "$(recovery_now)" > "$recovery_lock_tmp" ) 2>/dev/null || {
    if ! rm -f "$recovery_lock_tmp" 2>/dev/null; then recovery_error "Could not remove the failed recovery lock metadata"; fi
    if ! rmdir "$RECOVERY_LOCK" 2>/dev/null; then recovery_error "Could not remove the failed recovery lock directory"; fi
    return 1
  }
  chmod 600 "$recovery_lock_tmp" 2>/dev/null || {
    if ! rm -f "$recovery_lock_tmp" 2>/dev/null; then recovery_error "Could not remove the failed recovery lock metadata"; fi
    if ! rmdir "$RECOVERY_LOCK" 2>/dev/null; then recovery_error "Could not remove the failed recovery lock directory"; fi
    return 1
  }
  mv -f "$recovery_lock_tmp" "$RECOVERY_LOCK/owner" 2>/dev/null || {
    if ! rm -f "$recovery_lock_tmp" 2>/dev/null; then recovery_error "Could not remove the failed recovery lock metadata"; fi
    if ! rmdir "$RECOVERY_LOCK" 2>/dev/null; then recovery_error "Could not remove the failed recovery lock directory"; fi
    return 1
  }
  RECOVERY_LOCK_NONCE="$recovery_lock_nonce"
  RECOVERY_LOCK_OWNED=1
  return 0
}

recovery_release_lock() {
  [ "$RECOVERY_LOCK_OWNED" = "1" ] || return 0
  recovery_lock_read || return 1
  [ "$recovery_lock_pid" = "$$" ] && [ "$recovery_lock_start" = "$(recovery_proc_start "$$" 2>/dev/null)" ] && \
    [ -n "$RECOVERY_LOCK_NONCE" ] && [ "$recovery_lock_nonce" = "$RECOVERY_LOCK_NONCE" ] || return 1
  rm -f "$RECOVERY_LOCK/owner" 2>/dev/null || return 1
  rmdir "$RECOVERY_LOCK" 2>/dev/null || return 1
  RECOVERY_LOCK_OWNED=0
  RECOVERY_LOCK_NONCE=""
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

recovery_cleanup() {
  recovery_cleanup_rc=$?
  recovery_cleanup_failed=0
  if recovery_path_safe "$RECOVERY_WORK" && [ -d "$RECOVERY_WORK" ]; then
    if ! rm -rf "$RECOVERY_WORK" 2>/dev/null; then
      recovery_error "Could not remove recovery workspace $RECOVERY_WORK"
      recovery_cleanup_failed=1
    fi
  fi
  if [ "$RECOVERY_PRESERVE_JFFS" != "1" ]; then
    case "$RECOVERY_JFFS_STAGE" in
      "$MERVLAN_RECOVERY_BACKUP_ROOT"/.mervlan.new.*)
        if ! rm -rf "$RECOVERY_JFFS_STAGE" 2>/dev/null; then
          recovery_error "Could not remove recovery activation stage $RECOVERY_JFFS_STAGE"
          recovery_cleanup_failed=1
        fi
        ;;
    esac
  fi
  if [ "$RECOVERY_PRESERVE_JFFS" != "1" ] && [ "$RECOVERY_REPLACED" = "0" ]; then
    case "$RECOVERY_JFFS_OLD" in
      "$MERVLAN_RECOVERY_BACKUP_ROOT"/.mervlan.old.*)
        if ! rm -rf "$RECOVERY_JFFS_OLD" 2>/dev/null; then
          recovery_error "Could not remove recovery rollback tree $RECOVERY_JFFS_OLD"
          recovery_cleanup_failed=1
        fi
        ;;
    esac
  fi
  if ! recovery_release_lock; then
    recovery_error "Recovery cleanup could not release its owner lock"
    recovery_cleanup_failed=1
  fi
  [ "$recovery_cleanup_failed" -eq 0 ] || recovery_cleanup_rc=1
  return "$recovery_cleanup_rc"
}

recovery_reconcile_stale_stages() {
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
  case "$MERVLAN_RECOVERY_ACTIVE_ROOT" in /|/jffs|/jffs/addons|/tmp|'') return 1 ;; esac
  rm -rf "$RECOVERY_JFFS_STAGE" 2>/dev/null || return 1
  if [ -d "$MERVLAN_RECOVERY_ACTIVE_ROOT" ] && ! mv "$MERVLAN_RECOVERY_ACTIVE_ROOT" "$RECOVERY_JFFS_STAGE" 2>/dev/null; then
    RECOVERY_PRESERVE_JFFS=1
    return 1
  fi
  if [ -d "$RECOVERY_JFFS_OLD" ]; then
    mv "$RECOVERY_JFFS_OLD" "$MERVLAN_RECOVERY_ACTIVE_ROOT" 2>/dev/null || return 1
  else
    recovery_copy_tree "$RECOVERY_ORIGINAL" "$MERVLAN_RECOVERY_ACTIVE_ROOT" || return 1
  fi
  if ! rm -rf "$RECOVERY_JFFS_STAGE" 2>/dev/null; then
    RECOVERY_PRESERVE_JFFS=1
    return 1
  fi
  if ! recovery_reconcile "$MERVLAN_RECOVERY_ACTIVE_ROOT" "$(recovery_boot_state "$MERVLAN_RECOVERY_ACTIVE_ROOT")"; then
    RECOVERY_PRESERVE_JFFS=1
    return 1
  fi
  RECOVERY_REPLACED=0
  return 0
}

recovery_on_signal() {
  recovery_signal="$1"
  trap - INT TERM
  if ! recovery_rollback; then
    RECOVERY_PRESERVE_JFFS=1
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
  recovery_acquire_lock || return 1
  if ! recovery_reconcile_stale_stages; then
    recovery_error "Stale recovery trees could not be reconciled; restore is blocked."
    return 1
  fi
  mkdir -p "$RECOVERY_WORK" 2>/dev/null || { recovery_error "Could not create recovery workspace in /tmp."; return 1; }
  chmod 700 "$RECOVERY_WORK" 2>/dev/null || { recovery_error "Could not secure the recovery workspace."; return 1; }
  trap 'recovery_on_signal 130' INT
  trap 'recovery_on_signal 143' TERM
  recovery_log "Validating $recovery_id"
  recovery_validate_archive "$recovery_archive" || return 1
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
  if [ -d "$MERVLAN_RECOVERY_ACTIVE_ROOT" ]; then
    mv "$MERVLAN_RECOVERY_ACTIVE_ROOT" "$RECOVERY_JFFS_OLD" 2>/dev/null || return 1
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

trap recovery_cleanup EXIT
case "$1" in
  list) recovery_list ;;
  check) [ -n "$2" ] || { recovery_usage >&2; exit 1; }; recovery_check "$2" ;;
  restore) [ -n "$2" ] || { recovery_usage >&2; exit 1; }; recovery_restore "$2" "$3" ;;
  ''|-h|--help|help) recovery_usage ;;
  *) recovery_usage >&2; exit 1 ;;
esac
