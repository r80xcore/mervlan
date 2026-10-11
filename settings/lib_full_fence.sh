#!/bin/sh
# Full admission fence. Unlike ordinary owner locks this fence is
# absent-only: any pre-existing object blocks, including a dead owner.

if [ -n "${LIB_FULL_FENCE_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
: "${MERV_BASE:=/jffs/addons/mervlan}"
[ -n "${LIB_OWNER_LOCK_LOADED:-}" ] ||
  . "$MERV_BASE/settings/lib_owner_lock.sh" 2>/dev/null || return 1 2>/dev/null || exit 1
LIB_FULL_FENCE_LOADED=1

MERV_FULL_FENCE_CANONICAL_PATH=/tmp/.mervlan-full-uninstall.lock

merv_full_fence_path() {
  _mffp_requested=${1:-${MERV_FULL_FENCE_PATH:-$MERV_FULL_FENCE_CANONICAL_PATH}}
  if [ "$_mffp_requested" = "$MERV_FULL_FENCE_CANONICAL_PATH" ]; then
    printf '%s\n' "$MERV_FULL_FENCE_CANONICAL_PATH"
    return 0
  fi
  type merv_selftest_context_path_allowed >/dev/null 2>&1 || return 1
  merv_selftest_context_path_allowed "$_mffp_requested" || return 1
  merv_owner_lock_path_chain_safe "$_mffp_requested" || return 1
  printf '%s\n' "$_mffp_requested"
}

merv_full_fence_mode() {
  _mffm_path=${1:-}
  [ -n "$_mffm_path" ] && [ ! -L "$_mffm_path" ] || return 1
  LC_ALL=C ls -ldn "$_mffm_path" 2>/dev/null | awk 'NR == 1 { print $1 }'
}

merv_full_fence_fault() {
  _mfff_stage=${1:-}
  [ -n "$_mfff_stage" ] || return 1
  type merv_selftest_context_valid >/dev/null 2>&1 &&
    merv_selftest_context_valid || return 1
  case ",${MERV_FULL_FENCE_FAULT:-}," in *",$_mfff_stage,"*) return 0 ;; esac
  return 1
}

merv_full_fence_absent_authoritative() {
  _mffa_path=${1:-}
  [ -n "$_mffa_path" ] || return 1
  _mffa_parent=${_mffa_path%/*}
  [ -d "$_mffa_parent" ] && [ ! -L "$_mffa_parent" ] &&
    [ -r "$_mffa_parent" ] && [ -x "$_mffa_parent" ] || return 1
  ! ls -ld "$_mffa_path" >/dev/null 2>&1 && [ ! -L "$_mffa_path" ]
}

# State is diagnostic only; no state except absent permits a claim.
merv_full_fence_classify() {
  _mffc_path=$(merv_full_fence_path "${1:-}") || {
    printf '%s' obstructed
    return 0
  }
  if merv_full_fence_fault path-unobservable; then
    printf '%s' unobservable
    return 0
  fi
  _mffc_parent=${_mffc_path%/*}
  [ -d "$_mffc_parent" ] && [ ! -L "$_mffc_parent" ] &&
    [ -r "$_mffc_parent" ] && [ -x "$_mffc_parent" ] || {
      printf '%s' unobservable
      return 0
    }
  if ! ls -ld "$_mffc_path" >/dev/null 2>&1; then
    if merv_full_fence_absent_authoritative "$_mffc_path"; then
      printf '%s' absent
    else
      printf '%s' unobservable
    fi
    return 0
  fi
  [ ! -L "$_mffc_path" ] && [ -d "$_mffc_path" ] || {
    printf '%s' obstructed
    return 0
  }
  _mffc_mode=$(merv_full_fence_mode "$_mffc_path" 2>/dev/null || printf '')
  [ "$_mffc_mode" = drwx------ ] || {
    printf '%s' malformed
    return 0
  }
  if ! ls -ld "$_mffc_path/owner" >/dev/null 2>&1; then
    if [ -L "$_mffc_path/owner" ]; then
      printf '%s' malformed
      return 0
    fi
    _mffc_now=$(merv_owner_lock_now 2>/dev/null || printf '')
    _mffc_mtime=$(merv_owner_lock_timestamp "$_mffc_path" 2>/dev/null || printf '')
    case "$_mffc_now:$_mffc_mtime:${MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC:-}" in
      *[!0-9:]*) printf '%s' incomplete-unknown; return 0 ;;
    esac
    [ -n "$_mffc_now" ] && [ -n "$_mffc_mtime" ] || {
      printf '%s' incomplete-unknown
      return 0
    }
    [ "$_mffc_now" -ge "$_mffc_mtime" ] 2>/dev/null || {
      printf '%s' incomplete-unknown
      return 0
    }
    _mffc_age=$((_mffc_now - _mffc_mtime))
    if [ "$_mffc_age" -le "$MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC" ] 2>/dev/null; then
      printf '%s' incomplete-grace
    else
      printf '%s' incomplete-expired
    fi
    return 0
  fi
  [ ! -L "$_mffc_path/owner" ] && [ -f "$_mffc_path/owner" ] || {
    printf '%s' malformed
    return 0
  }
  if merv_full_fence_fault owner-unreadable || [ ! -r "$_mffc_path/owner" ]; then
    printf '%s' unreadable
    return 0
  fi
  _mffc_mode=$(merv_full_fence_mode "$_mffc_path/owner" 2>/dev/null || printf '')
  [ "$_mffc_mode" = -rw------- ] || {
    printf '%s' malformed
    return 0
  }
  merv_owner_v2_read "$_mffc_path/owner" 2>/dev/null || {
    printf '%s' malformed
    return 0
  }
  _mffc_pid=$MERV_OWNER_V2_PID
  _mffc_start=$MERV_OWNER_V2_PROC_START_TIME
  _mffc_proc=$(merv_owner_lock_proc_root "${2:-${MERV_OWNER_LOCK_PROC_ROOT:-/proc}}" 2>/dev/null || printf '')
  [ -n "$_mffc_proc" ] || {
    printf '%s' unobservable
    return 0
  }
  _mffc_actual=$(merv_identity_proc_start "$_mffc_pid" "$_mffc_proc" 2>/dev/null || printf '')
  if merv_owner_v2_positive_uint "$_mffc_actual"; then
    if [ "$_mffc_actual" != "$_mffc_start" ]; then
      printf '%s' reused
    elif [ "$_mffc_proc" != /proc ] || kill -0 "$_mffc_pid" 2>/dev/null; then
      printf '%s' live
    else
      printf '%s' unobservable
    fi
    return 0
  fi
  if [ -e "$_mffc_proc/$_mffc_pid/stat" ]; then
    printf '%s' unobservable
  else
    printf '%s' dead
  fi
  return 0
}

merv_full_fence_owner_is() {
  _mffo_path=$(merv_full_fence_path "${1:-}") || return 1
  _mffo_pid=${2:-}
  _mffo_start=${3:-}
  _mffo_nonce=${4:-}
  [ "$(merv_full_fence_classify "$_mffo_path")" = live ] || return 1
  merv_owner_v2_matches "$_mffo_path/owner" "$_mffo_pid" \
    "$_mffo_start" "$_mffo_nonce" /proc
}

# Claim the exact absent path once. No stale/dead/reused/incomplete object is
# ever reclaimed. A publication failure leaves the fence in place.
merv_full_fence_claim() {
  _mffc_claim_path=$(merv_full_fence_path "${1:-}") || return 1
  [ "$(merv_full_fence_classify "$_mffc_claim_path")" = absent ] || return 1
  _mffc_parent=${_mffc_claim_path%/*}
  [ -d "$_mffc_parent" ] && [ ! -L "$_mffc_parent" ] &&
    [ -r "$_mffc_parent" ] && [ -w "$_mffc_parent" ] && [ -x "$_mffc_parent" ] || return 1
  ( umask 077; mkdir "$_mffc_claim_path" 2>/dev/null ) || return 1
  [ ! -L "$_mffc_claim_path" ] && [ -d "$_mffc_claim_path" ] || return 1
  chmod 700 "$_mffc_claim_path" 2>/dev/null || return 1
  [ "$(merv_full_fence_mode "$_mffc_claim_path" 2>/dev/null)" = drwx------ ] || return 1
  _mffc_start=$(merv_identity_current_start /proc 2>/dev/null) || return 1
  merv_owner_v2_positive_uint "$_mffc_start" || return 1
  merv_identity_nonce_next || return 1
  _mffc_nonce=$MERV_IDENTITY_NONCE
  _mffc_now=$(merv_owner_lock_now 2>/dev/null) || return 1
  merv_owner_v2_write_atomic "$_mffc_claim_path" "$$" "$_mffc_start" \
    "$_mffc_nonce" "$_mffc_now" "$_mffc_now" || return 1
  [ "$(merv_full_fence_classify "$_mffc_claim_path")" = live ] || return 1
  merv_owner_v2_matches "$_mffc_claim_path/owner" "$$" "$_mffc_start" \
    "$_mffc_nonce" /proc || return 1
  MERV_FULL_FENCE_PATH_ACTIVE=$_mffc_claim_path
  MERV_FULL_FENCE_PID=$$
  MERV_FULL_FENCE_START=$_mffc_start
  MERV_FULL_FENCE_NONCE=$_mffc_nonce
  return 0
}

# Remove only this process's exact fence after its supervised destructive work
# is terminal. An unexpected entry, replacement, or failed rmdir leaves F.
merv_full_fence_release() {
  _mffr_path=$(merv_full_fence_path "${1:-${MERV_FULL_FENCE_PATH_ACTIVE:-}}") || return 1
  _mffr_pid=${2:-${MERV_FULL_FENCE_PID:-}}
  _mffr_start=${3:-${MERV_FULL_FENCE_START:-}}
  _mffr_nonce=${4:-${MERV_FULL_FENCE_NONCE:-}}
  [ "$_mffr_pid" = "$$" ] || return 1
  merv_owner_v2_positive_uint "$_mffr_start" || return 1
  merv_owner_v2_nonce_valid "$_mffr_nonce" || return 1
  [ "$(merv_full_fence_mode "$_mffr_path" 2>/dev/null)" = drwx------ ] || return 1
  [ "$(merv_full_fence_mode "$_mffr_path/owner" 2>/dev/null)" = -rw------- ] || return 1
  merv_owner_v2_matches "$_mffr_path/owner" "$_mffr_pid" \
    "$_mffr_start" "$_mffr_nonce" /proc || return 1
  _mffr_entries=$(LC_ALL=C ls -A "$_mffr_path" 2>/dev/null) || return 1
  [ "$_mffr_entries" = owner ] || return 1
  # Recheck the exact record immediately before unlink. Never recursively
  # remove the lock directory or follow either path component.
  merv_owner_v2_matches "$_mffr_path/owner" "$_mffr_pid" \
    "$_mffr_start" "$_mffr_nonce" /proc || return 1
  rm -f "$_mffr_path/owner" 2>/dev/null || return 1
  rmdir "$_mffr_path" 2>/dev/null || return 1
  MERV_FULL_FENCE_PATH_ACTIVE=
  MERV_FULL_FENCE_PID=
  MERV_FULL_FENCE_START=
  MERV_FULL_FENCE_NONCE=
  return 0
}
