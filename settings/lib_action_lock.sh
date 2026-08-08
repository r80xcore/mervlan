#!/bin/sh
# MerVLAN action-serialization policy.
#
# This is deliberately a thin layer over the canonical v2 owner-record
# implementation in lib_owner_lock.sh.  It authenticates inherited parent
# ownership, acquires a self-owned action lock when no parent context exists,
# exports the true owner to children, and releases only self-owned locks.

[ -n "${LIB_ACTION_LOCK_LOADED:-}" ] && return 0 2>/dev/null
LIB_ACTION_LOCK_LOADED=1

: "${LOCKDIR:=/tmp/mervlan_tmp/locks}"
: "${MERV_ACTION_LOCK_PATH:=$LOCKDIR/mervlan_action.lock}"

if [ -z "${LIB_OWNER_LOCK_LOADED:-}" ]; then
  _mal_base="${MERV_BASE:-/jffs/addons/mervlan}"
  [ -r "$_mal_base/settings/lib_owner_lock.sh" ] || return 1 2>/dev/null || exit 1
  . "$_mal_base/settings/lib_owner_lock.sh" 2>/dev/null || return 1 2>/dev/null || exit 1
fi

# Keep the public state names used by existing callers, while making mode
# explicit so a child can never release an inherited parent lock.
MERV_ACTION_LOCK_MODE="${MERV_ACTION_LOCK_MODE:-none}"
MERV_ACTION_LOCK_NONCE="${MERV_ACTION_LOCK_NONCE:-}"
MERV_ACTION_LOCK_START="${MERV_ACTION_LOCK_START:-}"
MERV_ACTION_LOCK_PATH_ACTIVE="${MERV_ACTION_LOCK_PATH_ACTIVE:-}"
MERV_ACTION_LOCK_LAST_FAILURE="${MERV_ACTION_LOCK_LAST_FAILURE:-}"

merv_action_lock_path_valid() {
  _malp_path="${1:-}"
  case "$_malp_path" in
    ''|*..*|*[!A-Za-z0-9_./-]*) return 1 ;;
  esac
  case "$_malp_path" in */*) return 0 ;; *) return 1 ;; esac
}

# Validate only the authenticated parent context.  A present but invalid
# parent marker is an unknown owner and must never fall back to self-
# acquisition.
merv_action_lock_parent_owned() {
  _mal_parent_lock="${1:-${MERV_ACTION_LOCK_PATH:-}}"
  merv_action_lock_path_valid "$_mal_parent_lock" || return 1
  [ "${MERV_ACTION_LOCK_PARENT_HELD:-0}" = 1 ] || return 1
  merv_owner_v2_positive_uint "${MERV_ACTION_LOCK_PARENT_PID:-}" || return 1
  merv_owner_v2_positive_uint "${MERV_ACTION_LOCK_PARENT_START:-}" || return 1
  merv_owner_v2_nonce_valid "${MERV_ACTION_LOCK_PARENT_NONCE:-}" || return 1
  # merv_owner_v2_matches checks the exact five-field record and validates the
  # PID/start identity against the live process.  No age/heartbeat shortcut is
  # permitted here.
  merv_owner_v2_matches "$_mal_parent_lock" \
    "$MERV_ACTION_LOCK_PARENT_PID" "$MERV_ACTION_LOCK_PARENT_START" \
    "$MERV_ACTION_LOCK_PARENT_NONCE" "${MERV_ACTION_LOCK_PROC_ROOT:-/proc}" || return 1
  MERV_ACTION_LOCK_MODE=parent
  MERV_ACTION_LOCK_PATH_ACTIVE="$_mal_parent_lock"
  MERV_ACTION_LOCK_NONCE="$MERV_ACTION_LOCK_PARENT_NONCE"
  MERV_ACTION_LOCK_START="$MERV_ACTION_LOCK_PARENT_START"
  MERV_ACTION_LOCK_OWNED=0
  return 0
}

# Enter one action lock.  Return codes are intentionally stable for callers:
# 0 acquired/validated, 3 busy live owner, 4 unknown/malformed/unavailable.
# If parent context is advertised but cannot be authenticated, return 4 and do
# not attempt a self-acquisition.
merv_action_lock_enter() {
  _mal_lock="${1:-${MERV_ACTION_LOCK_PATH:-}}"
  _mal_requested_mode="${2:-auto}"
  MERV_ACTION_LOCK_LAST_FAILURE=""
  if ! merv_action_lock_path_valid "$_mal_lock"; then
    MERV_ACTION_LOCK_LAST_FAILURE=action-lock-owner-unknown
    return 4
  fi
  MERV_ACTION_LOCK_MODE=none
  MERV_ACTION_LOCK_NONCE=""
  MERV_ACTION_LOCK_START=""
  MERV_ACTION_LOCK_PATH_ACTIVE="$_mal_lock"
  MERV_ACTION_LOCK_OWNED=0

  if [ "$_mal_requested_mode" != self ] && [ "${MERV_ACTION_LOCK_PARENT_HELD:-0}" = 1 ]; then
    if ! merv_action_lock_parent_owned "$_mal_lock"; then
      MERV_ACTION_LOCK_LAST_FAILURE=action-lock-parent-invalid
      return 4
    fi
    return 0
  fi

  # The generic owner library performs atomic publication, dead/reused-owner
  # quarantine, and exact owner cleanup.  A zero retry budget keeps this
  # action mutex non-blocking, matching the historical dispatch contract.
  merv_owner_lock_acquire "$_mal_lock" 0 0 mervlan_action >/dev/null 2>&1
  _mal_rc=$?
  if [ "$_mal_rc" -eq 0 ]; then
    MERV_ACTION_LOCK_MODE=self
    MERV_ACTION_LOCK_NONCE="${MERV_LOCK_NONCE:-}"
    MERV_ACTION_LOCK_START="${MERV_LOCK_START:-}"
    [ -n "$MERV_ACTION_LOCK_NONCE" ] && [ -n "$MERV_ACTION_LOCK_START" ] || {
      MERV_ACTION_LOCK_MODE=none
      MERV_ACTION_LOCK_LAST_FAILURE=action-lock-owner-unknown
      return 4
    }
    MERV_ACTION_LOCK_OWNED=1
    return 0
  fi

  # Distinguish a known live/in-progress owner from malformed or inaccessible
  # metadata.  Unknown owners fail closed and are never reclaimed here.
  _mal_state=$(merv_owner_lock_state "$_mal_lock" 2>/dev/null || printf 'unknown')
  case "$_mal_state" in
    live|incomplete-grace)
      MERV_ACTION_LOCK_LAST_FAILURE=action-lock-busy
      return 3
      ;;
    *)
      MERV_ACTION_LOCK_LAST_FAILURE=action-lock-owner-unknown
      return 4
      ;;
  esac
}

# Export the authenticated owner for a child process.  In self mode the
# current process is the owner; in parent mode the received parent identity is
# forwarded unchanged.  This function never invents a child identity.
merv_action_lock_export_child_context() {
  [ "${MERV_ACTION_LOCK_MODE:-none}" = self ] ||
    [ "${MERV_ACTION_LOCK_MODE:-none}" = parent ] || return 1
  MERV_ACTION_LOCK_PARENT_HELD=1
  if [ "$MERV_ACTION_LOCK_MODE" = self ]; then
    MERV_ACTION_LOCK_PARENT_PID="$$"
    MERV_ACTION_LOCK_PARENT_START="$MERV_ACTION_LOCK_START"
    MERV_ACTION_LOCK_PARENT_NONCE="$MERV_ACTION_LOCK_NONCE"
  else
    [ -n "${MERV_ACTION_LOCK_PARENT_PID:-}" ] || return 1
    [ -n "${MERV_ACTION_LOCK_PARENT_START:-}" ] || return 1
    [ -n "${MERV_ACTION_LOCK_PARENT_NONCE:-}" ] || return 1
  fi
  export MERV_ACTION_LOCK_PARENT_HELD MERV_ACTION_LOCK_PARENT_PID \
    MERV_ACTION_LOCK_PARENT_START MERV_ACTION_LOCK_PARENT_NONCE
  return 0
}

merv_action_lock_clear_child_context() {
  MERV_ACTION_LOCK_PARENT_HELD=0
  MERV_ACTION_LOCK_PARENT_PID=""
  MERV_ACTION_LOCK_PARENT_START=""
  MERV_ACTION_LOCK_PARENT_NONCE=""
  export MERV_ACTION_LOCK_PARENT_HELD MERV_ACTION_LOCK_PARENT_PID \
    MERV_ACTION_LOCK_PARENT_START MERV_ACTION_LOCK_PARENT_NONCE
}

# Leave one action lock.  Parent-owned mode is a deliberate no-op: only the
# process that acquired the lock may release it.  Optional nonce/start/mode
# arguments let callers retain two independent nested lock contexts (the
# service dispatcher has an event lock and a global lock).
merv_action_lock_leave() {
  _mall_lock="${1:-${MERV_ACTION_LOCK_PATH_ACTIVE:-${MERV_ACTION_LOCK_PATH:-}}}"
  _mall_nonce="${2:-${MERV_ACTION_LOCK_NONCE:-}}"
  _mall_start="${3:-${MERV_ACTION_LOCK_START:-}}"
  _mall_mode="${4:-${MERV_ACTION_LOCK_MODE:-none}}"
  [ "$_mall_mode" = parent ] && return 0
  [ "$_mall_mode" = self ] || return 0
  merv_action_lock_path_valid "$_mall_lock" || return 1
  [ -n "$_mall_nonce" ] && [ -n "$_mall_start" ] || return 1
  merv_owner_v2_positive_uint "$_mall_start" || return 1
  _mall_current_start=$(merv_identity_current_start 2>/dev/null) || return 1
  [ "$_mall_current_start" = "$_mall_start" ] || return 1
  merv_owner_lock_release "$_mall_lock" "$_mall_nonce" >/dev/null 2>&1 || return 1
  if [ "${MERV_ACTION_LOCK_PATH_ACTIVE:-}" = "$_mall_lock" ]; then
    MERV_ACTION_LOCK_MODE=none
    MERV_ACTION_LOCK_NONCE=""
    MERV_ACTION_LOCK_START=""
    MERV_ACTION_LOCK_OWNED=0
  fi
  return 0
}

# Compatibility names for older installed callers.  New callers use the
# policy names above; these aliases retain a safe migration boundary.
merv_action_lock_acquire() { merv_action_lock_enter "$@"; }
merv_action_lock_release() { merv_action_lock_leave "$@" self; }
