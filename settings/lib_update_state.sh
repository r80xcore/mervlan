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

# The Update journal is policy, but live maintenance ownership is still the
# canonical v2 owner record.  Load it here so every Update-aware entry point
# uses the same authenticated predicate rather than reimplementing a flag
# check.  A missing/invalid library fails closed for maintenance contexts.
[ -n "${LIB_OWNER_LOCK_LOADED:-}" ] ||
  [ ! -r "${MERV_BASE:-/jffs/addons/mervlan}/settings/lib_owner_lock.sh" ] ||
  . "${MERV_BASE:-/jffs/addons/mervlan}/settings/lib_owner_lock.sh"

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
  merv_update_journal_state
  [ "${MERV_UPDATE_JOURNAL_STATE:-absent}" = active ]
}

merv_update_journal_requires_safe_boot() {
  merv_update_quiesce_state
  case "${MERV_UPDATE_QUIESCE_STATE:-absent}" in active|malformed) return 0 ;; esac
  merv_update_journal_state
  case "${MERV_UPDATE_JOURNAL_STATE:-absent}" in
    malformed) return 0 ;;
    active)
      [ "${MERV_UPDATE_JOURNAL_QUIESCED:-0}" = "1" ] ||
        [ "${MERV_UPDATE_JOURNAL_ACTIVATION:-0}" = "1" ]
      ;;
    *) return 1 ;;
  esac
}

# A completed journal is harmless when its quiesce marker is absent. Every
# other existing journal must be strictly parseable before it can be classified
# as pre-activation and therefore safe to leave behind after a dead owner.
merv_update_journal_state() {
  MERV_UPDATE_JOURNAL_STATE=absent
  MERV_UPDATE_JOURNAL_QUIESCED=0
  MERV_UPDATE_JOURNAL_ACTIVATION=0
  [ -e "$MERV_UPDATE_JOURNAL" ] || return 1
  [ -f "$MERV_UPDATE_JOURNAL" ] || { MERV_UPDATE_JOURNAL_STATE=malformed; return 2; }
  _mujs_lines=$(wc -l < "$MERV_UPDATE_JOURNAL" 2>/dev/null | tr -d '[:space:]')
  [ "$_mujs_lines" = "19" ] || { MERV_UPDATE_JOURNAL_STATE=malformed; return 2; }
  _mujs_seen=""
  _mujs_format="" _mujs_phase="" _mujs_quiesced="" _mujs_activation=""
  for _mujs_key in format run_id phase ref boot_enabled backup_ready quiesced activation_started nodes_touched detail tmp_base archive_path stage_path original_path jffs_stage_path jffs_old_path old_version new_version updated_epoch; do
    _mujs_count=$(grep -c "^${_mujs_key}=" "$MERV_UPDATE_JOURNAL" 2>/dev/null)
    [ "$_mujs_count" = "1" ] || { MERV_UPDATE_JOURNAL_STATE=malformed; return 2; }
    _mujs_value=$(sed -n "s/^${_mujs_key}=//p" "$MERV_UPDATE_JOURNAL" 2>/dev/null)
    merv_update_state_value "$_mujs_value" >/dev/null || { MERV_UPDATE_JOURNAL_STATE=malformed; return 2; }
    case "$_mujs_key" in
      format) _mujs_format=$_mujs_value ;;
      phase) _mujs_phase=$_mujs_value ;;
      quiesced) _mujs_quiesced=$_mujs_value ;;
      activation_started) _mujs_activation=$_mujs_value ;;
    esac
  done
  [ "$_mujs_format" = "1" ] || { MERV_UPDATE_JOURNAL_STATE=malformed; return 2; }
  case "$_mujs_phase" in completed|workspace|quiescing|quiesced|preflight|downloading|extracting|staged|durable-backup|backup|activation-started|activated|public-refresh|main-verified|failed-*) ;; *) MERV_UPDATE_JOURNAL_STATE=malformed; return 2 ;; esac
  case "$_mujs_quiesced:$_mujs_activation" in 0:0|0:1|1:0|1:1) ;; *) MERV_UPDATE_JOURNAL_STATE=malformed; return 2 ;; esac
  MERV_UPDATE_JOURNAL_QUIESCED=$_mujs_quiesced
  MERV_UPDATE_JOURNAL_ACTIVATION=$_mujs_activation
  case "$_mujs_phase" in completed) MERV_UPDATE_JOURNAL_STATE=completed ;; *) MERV_UPDATE_JOURNAL_STATE=active ;; esac
  return 0
}

merv_update_maintenance_lock_path() {
  if [ "${MERV_RECOVERY_DELEGATION:-0}" = "1" ] &&
    [ -n "${MERVLAN_RECOVERY_LOCK_OVERRIDE:-}" ]; then
    printf '%s\n' "$MERVLAN_RECOVERY_LOCK_OVERRIDE"
  else
    printf '%s\n' "${MERVLAN_MAINTENANCE_LOCK_OVERRIDE:-${MERV_UPDATE_MAINTENANCE_LOCK:-${LOCKDIR:-/tmp/mervlan_tmp/locks}/mervlan_maintenance.lock}}"
  fi
}

# A live Update child must present the exact canonical owner tuple.  In
# particular, MERV_UPDATE_OWNER alone is only an unauthenticated hint and
# never permits a mutating entry point to bypass maintenance quiescence.
merv_update_owner_context_valid() {
  [ "${MERV_UPDATE_OWNER:-0}" = "1" ] || return 1
  type merv_owner_v2_positive_uint >/dev/null 2>&1 || return 1
  type merv_owner_v2_nonce_valid >/dev/null 2>&1 || return 1
  type merv_owner_v2_matches >/dev/null 2>&1 || return 1
  merv_owner_v2_positive_uint "${MERV_UPDATE_OWNER_PID:-}" || return 1
  merv_owner_v2_positive_uint "${MERV_UPDATE_OWNER_START:-}" || return 1
  merv_owner_v2_nonce_valid "${MERV_UPDATE_OWNER_NONCE:-}" || return 1
  _muoc_lock=$(merv_update_maintenance_lock_path) || return 1
  merv_owner_v2_matches "$_muoc_lock" "$MERV_UPDATE_OWNER_PID" \
    "$MERV_UPDATE_OWNER_START" "$MERV_UPDATE_OWNER_NONCE"
}

# v0.53.26 Update parents predate the explicit delegation-kind marker.  After
# activating a newer tree they still invoke only the public/runtime
# `reinstall` children, inheriting the complete owner tuple and durable Update
# state.  Keep this bridge deliberately narrower than normal delegation: the
# caller must prove the marker is absent (so current parents use the normal
# path), the canonical owner is still live, the quiesce run matches the active
# journal, and activation has reached the durable `activated` phase.
merv_update_legacy_reinstall_context_valid() {
  local _mulr_run _mulr_quiesce_run
  [ "${MERV_UPDATE_OWNER:-0}" = "1" ] || return 1
  [ -z "${MERV_MAINTENANCE_DELEGATION_KIND:-}" ] || return 1
  merv_update_owner_context_valid || return 1
  merv_update_quiesce_active || return 1
  merv_update_journal_active || return 1
  [ "$(merv_update_journal_get phase unknown)" = "activated" ] || return 1
  [ "$(merv_update_journal_get quiesced 0)" = "1" ] || return 1
  [ "$(merv_update_journal_get activation_started 0)" = "1" ] || return 1

  _mulr_run=$(merv_update_journal_get run_id "") || return 1
  [ -n "$_mulr_run" ] || return 1
  _mulr_quiesce_run=$(sed -n 's/^run_id=//p' "$MERV_UPDATE_QUIESCE_FILE" 2>/dev/null | head -n 1)
  [ "$_mulr_quiesce_run" = "$_mulr_run" ] || return 1
  return 0
}

# Recovery is deliberately not an Update-owner bypass.  It is bound to the
# interrupted journal and to the still-live boot parent, and is refused while
# a live/unknown maintenance owner may still be operating.
merv_update_recovery_context_valid() {
  [ "${MERV_UPDATE_RECOVERY:-0}" = "1" ] || return 1
  type merv_identity_positive_uint >/dev/null 2>&1 || return 1
  type merv_identity_matches >/dev/null 2>&1 || return 1
  merv_update_journal_requires_safe_boot || return 1
  _murc_run=$(merv_update_journal_get run_id '') || return 1
  [ -n "$_murc_run" ] && [ "${MERV_UPDATE_RECOVERY_RUN_ID:-}" = "$_murc_run" ] || return 1
  merv_update_state_value "$MERV_UPDATE_RECOVERY_RUN_ID" >/dev/null || return 1
  merv_identity_positive_uint "${MERV_UPDATE_RECOVERY_PARENT_PID:-}" || return 1
  merv_identity_positive_uint "${MERV_UPDATE_RECOVERY_PARENT_START:-}" || return 1
  merv_identity_matches "$MERV_UPDATE_RECOVERY_PARENT_PID" \
    "$MERV_UPDATE_RECOVERY_PARENT_START" || return 1
  _murc_lock=$(merv_update_maintenance_lock_path) || return 1
  if type merv_owner_lock_state >/dev/null 2>&1; then
    case "$(merv_owner_lock_state "$_murc_lock" 2>/dev/null)" in
      live|unknown|malformed|incomplete-*) return 1 ;;
    esac
  elif [ -e "$_murc_lock" ]; then
    return 1
  fi
  return 0
}

merv_update_maintenance_sync_context_valid() {
  [ "${MERV_MAINTENANCE_SYNC:-0}" = "1" ] || return 1
  merv_update_owner_context_valid
}

# Direct install/uninstall entry points use this single delegated-owner
# contract.  The environment is only an authenticated transport for the
# exact canonical owner tuple; it is never authority by itself.  Update
# children additionally require the durable journal/quiesce state that makes
# it safe to mutate while the Update owner is live.  Backup and standalone
# recovery children are bound to the same live owner record and explicit kind.
# A standalone installer may likewise delegate only to a direct child after it
# has acquired the exact maintenance owner record itself.  This is needed for
# the installer's hardware-profile worker; it must not mistake its own parent
# owner for an unrelated active Update.
merv_maintenance_delegation_valid() {
  local _mmd_kind _mmd_lock
  _mmd_kind="${MERV_MAINTENANCE_DELEGATION_KIND:-}"
  _mmd_lock=$(merv_update_maintenance_lock_path) || return 1
  case "$_mmd_kind" in
    update)
      merv_update_owner_context_valid || return 1
      merv_update_quiesce_active || return 1
      merv_update_journal_requires_safe_boot || return 1
      ;;
    backup|recovery|install|uninstall)
      [ "${MERV_MAINTENANCE_DELEGATED:-0}" = "1" ] || return 1
      case "$_mmd_kind" in
        backup) [ "${MERV_BACKUP_DELEGATION:-0}" = "1" ] || return 1 ;;
        recovery) [ "${MERV_RECOVERY_DELEGATION:-0}" = "1" ] || return 1 ;;
        install) [ "${MERV_INSTALL_DELEGATION:-0}" = "1" ] || return 1 ;;
        uninstall) [ "${MERV_UNINSTALL_DELEGATION:-0}" = "1" ] || return 1 ;;
        *) return 1 ;;
      esac
      type merv_owner_v2_positive_uint >/dev/null 2>&1 || return 1
      type merv_owner_v2_nonce_valid >/dev/null 2>&1 || return 1
      type merv_owner_v2_matches >/dev/null 2>&1 || return 1
      merv_owner_v2_positive_uint "${MERV_MAINTENANCE_OWNER_PID:-}" || return 1
      merv_owner_v2_positive_uint "${MERV_MAINTENANCE_OWNER_START:-}" || return 1
      merv_owner_v2_nonce_valid "${MERV_MAINTENANCE_OWNER_NONCE:-}" || return 1
      merv_owner_v2_matches "$_mmd_lock" \
        "$MERV_MAINTENANCE_OWNER_PID" \
        "$MERV_MAINTENANCE_OWNER_START" \
        "$MERV_MAINTENANCE_OWNER_NONCE"
      ;;
    *)
      return 1
      ;;
  esac
}

# Acquire the shared maintenance owner for a standalone tree-mutating entry
# point, or authenticate a delegated child already running under that owner.
# Callers must invoke merv_maintenance_direct_release on every terminal path.
merv_maintenance_direct_admit() {
  local _mda_lock
  _mda_lock=$(merv_update_maintenance_lock_path) || return 1
  MERV_MAINTENANCE_ENTRY_OWNED=0
  MERV_MAINTENANCE_ENTRY_DELEGATED=0
  MERV_MAINTENANCE_ENTRY_LOCK="$_mda_lock"
  if merv_maintenance_delegation_valid; then
    MERV_MAINTENANCE_ENTRY_DELEGATED=1
    return 0
  fi
  type merv_owner_lock_acquire >/dev/null 2>&1 || return 1
  merv_owner_lock_acquire "$_mda_lock" 1800 2 "mervlan_maintenance" || return 1
  MERV_MAINTENANCE_ENTRY_NONCE="${MERV_LOCK_NONCE:-}"
  MERV_MAINTENANCE_ENTRY_START="${MERV_LOCK_START:-}"
  MERV_MAINTENANCE_ENTRY_OWNED=1
  return 0
}

# Export a narrow, authenticated direct-installer context for its children.
# The receiving process still verifies the live owner record; these environment
# values are only a transport for that exact identity and cannot authorize an
# unrelated process or stale maintenance state.
merv_maintenance_direct_export_install_context() {
  [ "${MERV_MAINTENANCE_ENTRY_OWNED:-0}" = "1" ] || return 1
  type merv_owner_v2_positive_uint >/dev/null 2>&1 || return 1
  type merv_owner_v2_nonce_valid >/dev/null 2>&1 || return 1
  merv_owner_v2_positive_uint "${MERV_MAINTENANCE_ENTRY_START:-}" || return 1
  merv_owner_v2_nonce_valid "${MERV_MAINTENANCE_ENTRY_NONCE:-}" || return 1
  MERV_MAINTENANCE_DELEGATED=1
  MERV_MAINTENANCE_DELEGATION_KIND=install
  MERV_INSTALL_DELEGATION=1
  MERV_MAINTENANCE_OWNER_PID="$$"
  MERV_MAINTENANCE_OWNER_START="$MERV_MAINTENANCE_ENTRY_START"
  MERV_MAINTENANCE_OWNER_NONCE="$MERV_MAINTENANCE_ENTRY_NONCE"
  export MERV_MAINTENANCE_DELEGATED MERV_MAINTENANCE_DELEGATION_KIND \
    MERV_INSTALL_DELEGATION MERV_MAINTENANCE_OWNER_PID \
    MERV_MAINTENANCE_OWNER_START MERV_MAINTENANCE_OWNER_NONCE
  return 0
}

# Export the same exact-owner contract for standalone uninstall children.
# Keeping uninstall distinct from install avoids turning one lifecycle's grant
# into a generic maintenance bypass.
merv_maintenance_direct_export_uninstall_context() {
  [ "${MERV_MAINTENANCE_ENTRY_OWNED:-0}" = "1" ] || return 1
  type merv_owner_v2_positive_uint >/dev/null 2>&1 || return 1
  type merv_owner_v2_nonce_valid >/dev/null 2>&1 || return 1
  merv_owner_v2_positive_uint "${MERV_MAINTENANCE_ENTRY_START:-}" || return 1
  merv_owner_v2_nonce_valid "${MERV_MAINTENANCE_ENTRY_NONCE:-}" || return 1
  MERV_MAINTENANCE_DELEGATED=1
  MERV_MAINTENANCE_DELEGATION_KIND=uninstall
  MERV_UNINSTALL_DELEGATION=1
  MERV_MAINTENANCE_OWNER_PID="$$"
  MERV_MAINTENANCE_OWNER_START="$MERV_MAINTENANCE_ENTRY_START"
  MERV_MAINTENANCE_OWNER_NONCE="$MERV_MAINTENANCE_ENTRY_NONCE"
  export MERV_MAINTENANCE_DELEGATED MERV_MAINTENANCE_DELEGATION_KIND \
    MERV_UNINSTALL_DELEGATION MERV_MAINTENANCE_OWNER_PID \
    MERV_MAINTENANCE_OWNER_START MERV_MAINTENANCE_OWNER_NONCE
  return 0
}

merv_maintenance_direct_release() {
  [ "${MERV_MAINTENANCE_ENTRY_OWNED:-0}" = "1" ] || return 0
  type merv_owner_lock_release >/dev/null 2>&1 || return 1
  merv_owner_lock_release "${MERV_MAINTENANCE_ENTRY_LOCK:-}" \
    "${MERV_MAINTENANCE_ENTRY_NONCE:-}" || return 1
  MERV_MAINTENANCE_ENTRY_OWNED=0
  MERV_MAINTENANCE_ENTRY_NONCE=""
  MERV_MAINTENANCE_ENTRY_START=""
  return 0
}

# Normal mutating workers use this gate before touching settings, hooks, VLAN
# state, or nodes. The Update owner is the only caller allowed to continue
# through its own quiesced maintenance window; all ordinary callers stop when
# the maintenance lock, quiesce marker, or incomplete-update recovery state is
# active. An unreadable owner record is treated as blocked rather than safe.
merv_update_mutation_blocked() {
  merv_update_owner_context_valid && return 1
  # A direct installer may invoke a hardware-profile child while retaining
  # the maintenance lock.  Permit only that child context after exact owner
  # verification; ordinary processes still fail closed below.
  merv_maintenance_delegation_valid && return 1
  merv_update_journal_requires_safe_boot && return 0
  _mumb_lock=$(merv_update_maintenance_lock_path) || return 0
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
  merv_update_quiesce_state
  [ "${MERV_UPDATE_QUIESCE_STATE:-absent}" = active ]
}

merv_update_quiesce_state() {
  MERV_UPDATE_QUIESCE_STATE=absent
  [ -e "$MERV_UPDATE_QUIESCE_FILE" ] || return 1
  [ -f "$MERV_UPDATE_QUIESCE_FILE" ] || { MERV_UPDATE_QUIESCE_STATE=malformed; return 2; }
  _muqs_lines=$(wc -l < "$MERV_UPDATE_QUIESCE_FILE" 2>/dev/null | tr -d '[:space:]')
  [ "$_muqs_lines" = "3" ] || { MERV_UPDATE_QUIESCE_STATE=malformed; return 2; }
  for _muqs_key in format run_id created_epoch; do
    _muqs_count=$(grep -c "^${_muqs_key}=" "$MERV_UPDATE_QUIESCE_FILE" 2>/dev/null)
    [ "$_muqs_count" = "1" ] || { MERV_UPDATE_QUIESCE_STATE=malformed; return 2; }
    _muqs_value=$(sed -n "s/^${_muqs_key}=//p" "$MERV_UPDATE_QUIESCE_FILE" 2>/dev/null)
    merv_update_state_value "$_muqs_value" >/dev/null || { MERV_UPDATE_QUIESCE_STATE=malformed; return 2; }
    case "$_muqs_key" in
      format) [ "$_muqs_value" = "1" ] || { MERV_UPDATE_QUIESCE_STATE=malformed; return 2; } ;;
      run_id) [ -n "$_muqs_value" ] || { MERV_UPDATE_QUIESCE_STATE=malformed; return 2; } ;;
      created_epoch) case "$_muqs_value" in ''|*[!0-9]*) MERV_UPDATE_QUIESCE_STATE=malformed; return 2 ;; esac ;;
    esac
  done
  MERV_UPDATE_QUIESCE_STATE=active
  return 0
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
