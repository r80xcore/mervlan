#!/bin/sh
# ============================================================================ #
# MerVLAN Update lifecycle state and maintenance-quiesce helpers             #
# ============================================================================ #
# This file stores only small, non-secret phase metadata. It is deliberately
# separate from the addon's real backup archives and never copies a source
# tree to the router.

[ -n "${LIB_UPDATE_STATE_LOADED:-}" ] && return 0 2>/dev/null

: "${MERV_STATE_ROOT:=/jffs/addons/mervlan_state}"
: "${MERV_UPDATE_JOURNAL:=$MERV_STATE_ROOT/update.journal}"
: "${MERV_UPDATE_QUIESCE_FILE:=$MERV_STATE_ROOT/update.quiesce}"

merv_update_state_path_valid() {
  local _mus_path="${1:-}"
  case "$_mus_path" in
    "$MERV_STATE_ROOT"/*) return 0 ;;
    *) return 1 ;;
  esac
}

merv_update_state_value() {
  # Journal values are one-line metadata. Reject control characters and the
  # delimiter so a malformed branch/path cannot change the journal grammar.
  local _mus_value="${1:-}"
  _mus_value=$(printf '%s' "$_mus_value" | tr ' ' '_')
  case "$_mus_value" in
    *[!A-Za-z0-9._:/-]*) return 1 ;;
  esac
  printf '%s' "$_mus_value"
}

merv_update_journal_write() {
  local _muj_run="$1" _muj_phase="$2" _muj_ref="$3"
  local _muj_boot="$4" _muj_backup="$5" _muj_quiesced="$6"
  local _muj_activation="$7" _muj_nodes="$8" _muj_detail="$9"
  local _muj_tmp_base="${10:-none}" _muj_archive="${11:-none}"
  local _muj_stage="${12:-none}" _muj_original="${13:-none}"
  local _muj_jffs_stage="${14:-none}" _muj_jffs_old="${15:-none}"
  local _muj_old_version="${16:-unknown}" _muj_new_version="${17:-unknown}"
  local _muj_tmp

  merv_update_state_path_valid "$MERV_UPDATE_JOURNAL" || return 1
  [ -n "$_muj_run" ] && [ -n "$_muj_phase" ] || return 1
  _muj_run=$(merv_update_state_value "$_muj_run") || return 1
  _muj_phase=$(merv_update_state_value "$_muj_phase") || return 1
  _muj_ref=$(merv_update_state_value "${_muj_ref:-unknown}") || return 1
  _muj_boot=$(merv_update_state_value "${_muj_boot:-0}") || return 1
  _muj_backup=$(merv_update_state_value "${_muj_backup:-0}") || return 1
  _muj_quiesced=$(merv_update_state_value "${_muj_quiesced:-0}") || return 1
  _muj_activation=$(merv_update_state_value "${_muj_activation:-0}") || return 1
  _muj_nodes=$(merv_update_state_value "${_muj_nodes:-0}") || return 1
  _muj_detail=$(merv_update_state_value "${_muj_detail:-none}") || return 1
  _muj_tmp_base=$(merv_update_state_value "${_muj_tmp_base:-none}") || return 1
  _muj_archive=$(merv_update_state_value "${_muj_archive:-none}") || return 1
  _muj_stage=$(merv_update_state_value "${_muj_stage:-none}") || return 1
  _muj_original=$(merv_update_state_value "${_muj_original:-none}") || return 1
  _muj_jffs_stage=$(merv_update_state_value "${_muj_jffs_stage:-none}") || return 1
  _muj_jffs_old=$(merv_update_state_value "${_muj_jffs_old:-none}") || return 1
  _muj_old_version=$(merv_update_state_value "${_muj_old_version:-unknown}") || return 1
  _muj_new_version=$(merv_update_state_value "${_muj_new_version:-unknown}") || return 1
  mkdir -p "$MERV_STATE_ROOT" 2>/dev/null || return 1
  chmod 700 "$MERV_STATE_ROOT" 2>/dev/null || return 1
  : "${MERV_UPDATE_STATE_SEQ:=0}"
  MERV_UPDATE_STATE_SEQ=$((MERV_UPDATE_STATE_SEQ + 1))
  _muj_tmp="$MERV_UPDATE_JOURNAL.tmp.$$.$MERV_UPDATE_STATE_SEQ"
  ( umask 077
    {
      printf 'format=1\n'
      printf 'run_id=%s\n' "$_muj_run"
      printf 'phase=%s\n' "$_muj_phase"
      printf 'ref=%s\n' "$_muj_ref"
      printf 'boot_enabled=%s\n' "$_muj_boot"
      printf 'backup_ready=%s\n' "$_muj_backup"
      printf 'quiesced=%s\n' "$_muj_quiesced"
      printf 'activation_started=%s\n' "$_muj_activation"
      printf 'nodes_touched=%s\n' "$_muj_nodes"
      printf 'detail=%s\n' "$_muj_detail"
      printf 'tmp_base=%s\n' "$_muj_tmp_base"
      printf 'archive_path=%s\n' "$_muj_archive"
      printf 'stage_path=%s\n' "$_muj_stage"
      printf 'original_path=%s\n' "$_muj_original"
      printf 'jffs_stage_path=%s\n' "$_muj_jffs_stage"
      printf 'jffs_old_path=%s\n' "$_muj_jffs_old"
      printf 'old_version=%s\n' "$_muj_old_version"
      printf 'new_version=%s\n' "$_muj_new_version"
      printf 'updated_epoch=%s\n' "$(date +%s 2>/dev/null || printf '0')"
    } > "$_muj_tmp"
  ) 2>/dev/null || { rm -f "$_muj_tmp" 2>/dev/null || :; return 1; }
  chmod 600 "$_muj_tmp" 2>/dev/null || { rm -f "$_muj_tmp" 2>/dev/null || :; return 1; }
  mv -f "$_muj_tmp" "$MERV_UPDATE_JOURNAL" 2>/dev/null || {
    rm -f "$_muj_tmp" 2>/dev/null || :
    return 1
  }
  return 0
}

merv_update_journal_get() {
  local _muj_key="$1" _muj_default="${2:-}"
  [ -f "$MERV_UPDATE_JOURNAL" ] || { printf '%s' "$_muj_default"; return 1; }
  _muj_value=$(sed -n "s/^${_muj_key}=//p" "$MERV_UPDATE_JOURNAL" 2>/dev/null | tail -n 1)
  [ -n "$_muj_value" ] || _muj_value="$_muj_default"
  printf '%s' "$_muj_value"
}

merv_update_journal_active() {
  [ -f "$MERV_UPDATE_JOURNAL" ] || return 1
  [ "$(merv_update_journal_get format 0)" = "1" ] || return 1
  case "$(merv_update_journal_get phase unknown)" in
    completed) return 1 ;;
    *) return 0 ;;
  esac
}

merv_update_journal_requires_safe_boot() {
  merv_update_quiesce_active && return 0
  merv_update_journal_active || return 1
  [ "$(merv_update_journal_get quiesced 0)" = "1" ] ||
    [ "$(merv_update_journal_get activation_started 0)" = "1" ]
}

# Normal mutating workers use this gate before touching settings, hooks, VLAN
# state, or nodes. The Update owner is the only caller allowed to continue
# through its own quiesced maintenance window; all ordinary callers stop when
# the maintenance lock, quiesce marker, or incomplete-update recovery state is
# active. An unreadable owner record is treated as blocked rather than safe.
merv_update_mutation_blocked() {
  [ "${MERV_UPDATE_OWNER:-0}" = "1" ] && return 1
  merv_update_journal_requires_safe_boot && return 0
  _mumb_lock="${MERV_UPDATE_MAINTENANCE_LOCK:-${LOCKDIR:-/tmp/mervlan_tmp/locks}/mervlan_maintenance.lock}"
  [ -e "$_mumb_lock" ] || return 1
  type merv_lock_state >/dev/null 2>&1 || return 0
  case "$(merv_lock_state "$_mumb_lock" 2>/dev/null)" in
    active|unknown) return 0 ;;
    stale|absent) return 1 ;;
    *) return 0 ;;
  esac
}

merv_update_quiesce_begin() {
  local _muq_run="${1:-}" _muq_tmp
  merv_update_state_path_valid "$MERV_UPDATE_QUIESCE_FILE" || return 1
  [ -n "$_muq_run" ] || return 1
  _muq_run=$(merv_update_state_value "$_muq_run") || return 1
  mkdir -p "$MERV_STATE_ROOT" 2>/dev/null || return 1
  : "${MERV_UPDATE_STATE_SEQ:=0}"
  MERV_UPDATE_STATE_SEQ=$((MERV_UPDATE_STATE_SEQ + 1))
  _muq_tmp="$MERV_UPDATE_QUIESCE_FILE.tmp.$$.$MERV_UPDATE_STATE_SEQ"
  ( umask 077; printf 'format=1\nrun_id=%s\ncreated_epoch=%s\n' \
      "$_muq_run" "$(date +%s 2>/dev/null || printf '0')" > "$_muq_tmp" ) \
    2>/dev/null || { rm -f "$_muq_tmp" 2>/dev/null || :; return 1; }
  chmod 600 "$_muq_tmp" 2>/dev/null || { rm -f "$_muq_tmp" 2>/dev/null || :; return 1; }
  mv -f "$_muq_tmp" "$MERV_UPDATE_QUIESCE_FILE" 2>/dev/null || {
    rm -f "$_muq_tmp" 2>/dev/null || :
    return 1
  }
}

merv_update_quiesce_active() {
  [ -f "$MERV_UPDATE_QUIESCE_FILE" ] || return 1
  [ "$(sed -n 's/^format=//p' "$MERV_UPDATE_QUIESCE_FILE" 2>/dev/null | head -n 1)" = "1" ] || return 1
  [ -n "$(sed -n 's/^run_id=//p' "$MERV_UPDATE_QUIESCE_FILE" 2>/dev/null | head -n 1)" ]
}

merv_update_quiesce_clear() {
  [ -e "$MERV_UPDATE_QUIESCE_FILE" ] || return 0
  merv_update_state_path_valid "$MERV_UPDATE_QUIESCE_FILE" || return 1
  rm -f "$MERV_UPDATE_QUIESCE_FILE" 2>/dev/null
}

merv_update_journal_clear() {
  [ -e "$MERV_UPDATE_JOURNAL" ] || return 0
  merv_update_state_path_valid "$MERV_UPDATE_JOURNAL" || return 1
  rm -f "$MERV_UPDATE_JOURNAL" 2>/dev/null
}

LIB_UPDATE_STATE_LOADED=1
