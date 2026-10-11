#!/bin/sh
# Shared post-owner F/M admission. Callers must already own their normal R;
# these checks never wait for either maintenance authority.

if [ -n "${LIB_MUTATION_ADMISSION_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

: "${MERV_BASE:=/jffs/addons/mervlan}"
[ -n "${LIB_OWNER_LOCK_LOADED:-}" ] ||
  . "$MERV_BASE/settings/lib_owner_lock.sh" 2>/dev/null || return 1 2>/dev/null || exit 1
[ -n "${LIB_ACTION_LOCK_LOADED:-}" ] ||
  . "$MERV_BASE/settings/lib_action_lock.sh" 2>/dev/null || return 1 2>/dev/null || exit 1
[ -n "${LIB_UPDATE_STATE_LOADED:-}" ] ||
  . "$MERV_BASE/settings/lib_update_state.sh" 2>/dev/null || return 1 2>/dev/null || exit 1
[ -n "${LIB_FULL_FENCE_LOADED:-}" ] ||
  . "$MERV_BASE/settings/lib_full_fence.sh" 2>/dev/null || return 1 2>/dev/null || exit 1
[ -n "${LIB_CONTINUATION_LOADED:-}" ] ||
  . "$MERV_BASE/settings/lib_continuation.sh" 2>/dev/null || return 1 2>/dev/null || exit 1
LIB_MUTATION_ADMISSION_LOADED=1

MERV_MUTATION_ADMISSION_REASON=${MERV_MUTATION_ADMISSION_REASON:-}

merv_mutation_admission_check_fm() {
  _mmacf_fence=$(merv_full_fence_classify 2>/dev/null || printf unknown)
  [ "$_mmacf_fence" = absent ] || {
    MERV_MUTATION_ADMISSION_REASON="full-fence-${_mmacf_fence:-unknown}"
    return 1
  }
  _mmacf_maintenance=$(merv_update_maintenance_lock_state 2>/dev/null || printf unknown)
  case "$_mmacf_maintenance" in
    absent|dead|reused) ;;
    *)
      MERV_MUTATION_ADMISSION_REASON="maintenance-${_mmacf_maintenance:-unknown}"
      return 1
      ;;
  esac
  _mmacf_continuations=$(merv_continuation_quiescence \
    "${MERV_CONTINUATION_TOKEN:-}" 2>/dev/null || printf blocking)
  [ "$_mmacf_continuations" = idle ] || {
    MERV_MUTATION_ADMISSION_REASON="continuation-${_mmacf_continuations:-blocking}"
    return 1
  }
  MERV_MUTATION_ADMISSION_REASON=
  return 0
}

merv_mutation_admission_check_fence() {
  _mmacf_fence=$(merv_full_fence_classify 2>/dev/null || printf unknown)
  [ "$_mmacf_fence" = absent ] || {
    MERV_MUTATION_ADMISSION_REASON="full-fence-${_mmacf_fence:-unknown}"
    return 1
  }
  MERV_MUTATION_ADMISSION_REASON=
  return 0
}

# merv_mutation_admit_r <owner-path> <pid> <start> <nonce>
# The caller is responsible for acquiring R before this authoritative gate
# and retaining it until every covered mutation is terminal.
merv_mutation_admit_r() {
  _mmar_path=${1:-}
  _mmar_pid=${2:-}
  _mmar_start=${3:-}
  _mmar_nonce=${4:-}
  MERV_MUTATION_ADMISSION_REASON=
  [ -n "$_mmar_path" ] || {
    MERV_MUTATION_ADMISSION_REASON=runtime-owner-missing
    return 1
  }
  _mmar_proc=$(merv_owner_lock_proc_root "${MERV_OWNER_LOCK_PROC_ROOT:-/proc}") || {
    MERV_MUTATION_ADMISSION_REASON=process-identity-unobservable
    return 1
  }
  merv_owner_v2_matches "$_mmar_path" "$_mmar_pid" "$_mmar_start" \
    "$_mmar_nonce" "$_mmar_proc" || {
      MERV_MUTATION_ADMISSION_REASON=runtime-owner-unverified
      return 1
    }
  if [ -n "${MERV_CONTINUATION_TOKEN:-}" ]; then
    if ! merv_continuation_activate_wait "$MERV_CONTINUATION_TOKEN"; then
      MERV_MUTATION_ADMISSION_REASON=continuation-unverified
      return 1
    fi
  fi
  merv_mutation_admission_check_fm
}

# Standard global-action wrapper for Class B/C mutations. It authenticates
# either the current self-owned action lock or its exact inherited parent
# tuple; a child never falls back to acquiring a competing lock.
merv_mutation_admit_action() {
  _mmaa_path=${1:-${MERV_ACTION_LOCK_PATH_ACTIVE:-${MERV_ACTION_LOCK_PATH:-/tmp/mervlan_tmp/locks/mervlan_action.lock}}}
  MERV_MUTATION_ADMISSION_REASON=
  merv_action_lock_path_valid "$_mmaa_path" || {
    MERV_MUTATION_ADMISSION_REASON=action-owner-path-invalid
    return 1
  }
  if [ "${MERV_ACTION_LOCK_PARENT_HELD:-0}" = 1 ] ||
     [ "${MERV_ACTION_LOCK_MODE:-none}" = parent ]; then
    merv_action_lock_parent_owned "$_mmaa_path" || {
      MERV_MUTATION_ADMISSION_REASON=action-owner-unverified
      return 1
    }
    _mmaa_pid=$MERV_ACTION_LOCK_PARENT_PID
    _mmaa_start=$MERV_ACTION_LOCK_PARENT_START
    _mmaa_nonce=$MERV_ACTION_LOCK_PARENT_NONCE
  elif [ "${MERV_ACTION_LOCK_MODE:-none}" = self ]; then
    _mmaa_pid=$$
    _mmaa_start=${MERV_ACTION_LOCK_START:-}
    _mmaa_nonce=${MERV_ACTION_LOCK_NONCE:-}
  else
    MERV_MUTATION_ADMISSION_REASON=action-owner-not-held
    return 1
  fi
  _mmaa_proc=$(merv_owner_lock_proc_root "${MERV_OWNER_LOCK_PROC_ROOT:-/proc}") || {
    MERV_MUTATION_ADMISSION_REASON=process-identity-unobservable
    return 1
  }
  merv_owner_v2_matches "$_mmaa_path" "$_mmaa_pid" "$_mmaa_start" \
    "$_mmaa_nonce" "$_mmaa_proc" || {
      MERV_MUTATION_ADMISSION_REASON=action-owner-unverified
      return 1
    }
  if [ -n "${MERV_CONTINUATION_TOKEN:-}" ]; then
    if ! merv_continuation_activate_wait "$MERV_CONTINUATION_TOKEN"; then
      MERV_MUTATION_ADMISSION_REASON=continuation-unverified
      return 1
    fi
  fi
  # Sync Nodes may be a true Update child under the exact authenticated M
  # transaction. That Class-A work remains inside M; it still rechecks F
  # after establishing its ordinary action owner.
  if [ "${MERV_MAINTENANCE_SYNC:-0}" = 1 ] &&
     type merv_maintenance_sync_context_valid >/dev/null 2>&1 &&
     merv_maintenance_sync_context_valid; then
    merv_mutation_admission_check_fence
    return $?
  fi
  # True maintenance transactions may invoke ordinary action-locked helpers
  # only through the authenticated exact-M child delegation. The helper still
  # checks F after R is established, so Full can never race a maintenance child.
  if type merv_maintenance_delegation_valid >/dev/null 2>&1 &&
     merv_maintenance_delegation_valid; then
    merv_mutation_admission_check_fence
    return $?
  fi
  merv_mutation_admission_check_fm
}
