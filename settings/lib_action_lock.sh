#!/bin/sh
# Lightweight global mutating-action lock for the service-event handler.
# It has the same ownership rules as the full manager lock but does not source
# the VLAN libraries in the DHCP-sensitive dispatch path.

[ -n "${LIB_ACTION_LOCK_LOADED:-}" ] && return 0 2>/dev/null
LIB_ACTION_LOCK_LOADED=1
: "${LOCKDIR:=/tmp/mervlan_tmp/locks}"
: "${MERV_ACTION_LOCK_PATH:=$LOCKDIR/mervlan_action.lock}"

if [ -z "${LIB_IDENTITY_LOADED:-}" ]; then
  _mal_base="${MERV_BASE:-/jffs/addons/mervlan}"
  [ -f "$_mal_base/settings/lib_identity.sh" ] && . "$_mal_base/settings/lib_identity.sh" 2>/dev/null || return 1 2>/dev/null || exit 1
fi

merv_action_lock_read() {
  _mal_lock="$1"; [ -f "$_mal_lock/owner" ] || return 1
  # Four complete, ordered fields are required. A partial or extra field is
  # unknown and must not be treated as a reclaimable old lock.
  _mal_lines=$(wc -l < "$_mal_lock/owner" 2>/dev/null) || return 1
  [ "$_mal_lines" = 4 ] || return 1
  MERV_ACTION_LOCK_PID=$(sed -n '1s/^pid=\([0-9][0-9]*\)$/\1/p' "$_mal_lock/owner" 2>/dev/null)
  MERV_ACTION_LOCK_START=$(sed -n '2s/^start=\([0-9][0-9]*\)$/\1/p' "$_mal_lock/owner" 2>/dev/null)
  MERV_ACTION_LOCK_NONCE=$(sed -n '3s/^nonce=\([A-Za-z0-9._:-][A-Za-z0-9._:-]*\)$/\1/p' "$_mal_lock/owner" 2>/dev/null)
  MERV_ACTION_LOCK_CREATED=$(sed -n '4s/^created=\([0-9][0-9]*\)$/\1/p' "$_mal_lock/owner" 2>/dev/null)
  case "$MERV_ACTION_LOCK_PID:$MERV_ACTION_LOCK_START:$MERV_ACTION_LOCK_CREATED" in *[!0-9:]*|:*|*::*) return 1 ;; esac
  [ -n "$MERV_ACTION_LOCK_NONCE" ]
}

_merv_action_lock_claim_cleanup() {
  _mal_lock="$1"
  _mal_tmp="$2"
  _mal_cleanup_rc=0
  [ -z "$_mal_tmp" ] || rm -f "$_mal_tmp" 2>/dev/null || _mal_cleanup_rc=1
  [ -e "$_mal_lock/owner" ] && _mal_cleanup_rc=1
  rmdir "$_mal_lock" 2>/dev/null || _mal_cleanup_rc=1
  return "$_mal_cleanup_rc"
}

merv_action_lock_acquire() {
  _mal_lock="${1:-$MERV_ACTION_LOCK_PATH}"; _mal_parent=${_mal_lock%/*}
  case "$_mal_lock" in *..*|*[!A-Za-z0-9_./-]*) return 4 ;; esac
  mkdir -p "$_mal_parent" 2>/dev/null || return 4
  if mkdir "$_mal_lock" 2>/dev/null; then
    _mal_start=$(merv_identity_current_start 2>/dev/null || printf '')
    _mal_nonce=$(merv_identity_nonce 2>/dev/null || printf '')
    [ -n "$_mal_start" ] && [ -n "$_mal_nonce" ] || {
      _merv_action_lock_claim_cleanup "$_mal_lock" "" >/dev/null 2>&1 || printf '%s\n' "[ERROR] action-lock claim cleanup failed; unknown lock state retained" >&2
      return 4
    }
    _mal_tmp="$_mal_lock/.owner.tmp.$$"
    _mal_created=$(date +%s 2>/dev/null || printf 0)
    case "$_mal_created" in ''|*[!0-9]*) _mal_created=0 ;; esac
    ( umask 077; printf 'pid=%s\nstart=%s\nnonce=%s\ncreated=%s\n' "$$" "$_mal_start" "$_mal_nonce" "$_mal_created" > "$_mal_tmp" ) 2>/dev/null || {
      _merv_action_lock_claim_cleanup "$_mal_lock" "$_mal_tmp" >/dev/null 2>&1 || printf '%s\n' "[ERROR] action-lock claim cleanup failed; unknown lock state retained" >&2
      return 4
    }
    chmod 600 "$_mal_tmp" 2>/dev/null || {
      _merv_action_lock_claim_cleanup "$_mal_lock" "$_mal_tmp" >/dev/null 2>&1 || printf '%s\n' "[ERROR] action-lock claim cleanup failed; unknown lock state retained" >&2
      return 4
    }
    mv -f "$_mal_tmp" "$_mal_lock/owner" 2>/dev/null || {
      _merv_action_lock_claim_cleanup "$_mal_lock" "$_mal_tmp" >/dev/null 2>&1 || printf '%s\n' "[ERROR] action-lock claim cleanup failed; unknown lock state retained" >&2
      return 4
    }
    MERV_ACTION_LOCK_NONCE="$_mal_nonce"; MERV_ACTION_LOCK_START="$_mal_start"; MERV_ACTION_LOCK_EXPECTED_NONCE="$_mal_nonce"; MERV_ACTION_LOCK_EXPECTED_START="$_mal_start"; MERV_ACTION_LOCK_OWNED=1
    return 0
  fi
  merv_action_lock_read "$_mal_lock" 2>/dev/null || return 4
  if merv_identity_matches "$MERV_ACTION_LOCK_PID" "$MERV_ACTION_LOCK_START" 2>/dev/null; then
    return 3
  fi
  _mal_try=0
  while [ "$_mal_try" -lt 8 ]; do
    _mal_dest="${_mal_lock}.quarantine.$$.$_mal_try"
    if mv "$_mal_lock" "$_mal_dest" 2>/dev/null; then
      mkdir "$_mal_lock" 2>/dev/null || return 4
      _mal_start=$(merv_identity_current_start 2>/dev/null || printf '')
      _mal_nonce=$(merv_identity_nonce 2>/dev/null || printf '')
      [ -n "$_mal_start" ] && [ -n "$_mal_nonce" ] || {
        _merv_action_lock_claim_cleanup "$_mal_lock" "" >/dev/null 2>&1 || printf '%s\n' "[ERROR] action-lock claim cleanup failed; unknown lock state retained" >&2
        return 4
      }
      _mal_tmp="$_mal_lock/.owner.tmp.$$"
      _mal_created=$(date +%s 2>/dev/null || printf 0)
      case "$_mal_created" in ''|*[!0-9]*) _mal_created=0 ;; esac
      ( umask 077; printf 'pid=%s\nstart=%s\nnonce=%s\ncreated=%s\n' "$$" "$_mal_start" "$_mal_nonce" "$_mal_created" > "$_mal_tmp" ) 2>/dev/null || {
        _merv_action_lock_claim_cleanup "$_mal_lock" "$_mal_tmp" >/dev/null 2>&1 || printf '%s\n' "[ERROR] action-lock claim cleanup failed; unknown lock state retained" >&2
        return 4
      }
      chmod 600 "$_mal_tmp" 2>/dev/null || {
        _merv_action_lock_claim_cleanup "$_mal_lock" "$_mal_tmp" >/dev/null 2>&1 || printf '%s\n' "[ERROR] action-lock claim cleanup failed; unknown lock state retained" >&2
        return 4
      }
      mv -f "$_mal_tmp" "$_mal_lock/owner" 2>/dev/null || {
        _merv_action_lock_claim_cleanup "$_mal_lock" "$_mal_tmp" >/dev/null 2>&1 || printf '%s\n' "[ERROR] action-lock claim cleanup failed; unknown lock state retained" >&2
        return 4
      }
      MERV_ACTION_LOCK_NONCE="$_mal_nonce"; MERV_ACTION_LOCK_START="$_mal_start"; MERV_ACTION_LOCK_EXPECTED_NONCE="$_mal_nonce"; MERV_ACTION_LOCK_EXPECTED_START="$_mal_start"; MERV_ACTION_LOCK_OWNED=1
      return 0
    fi
    _mal_try=$((_mal_try + 1))
  done
  return 4
}

merv_action_lock_release() {
  _mal_lock="${1:-$MERV_ACTION_LOCK_PATH}"; _mal_expected_nonce="${2:-${MERV_ACTION_LOCK_EXPECTED_NONCE:-}}"; _mal_expected_start="${3:-${MERV_ACTION_LOCK_EXPECTED_START:-}}"
  merv_action_lock_read "$_mal_lock" 2>/dev/null || return 1
  [ -n "$_mal_expected_nonce" ] && [ -n "$_mal_expected_start" ] || return 1
  [ "$MERV_ACTION_LOCK_PID" = "$$" ] && [ "$MERV_ACTION_LOCK_START" = "$_mal_expected_start" ] &&
    [ "$MERV_ACTION_LOCK_NONCE" = "$_mal_expected_nonce" ] || return 1
  merv_identity_matches "$$" "$_mal_expected_start" 2>/dev/null || return 1
  rm -f "$_mal_lock/owner" 2>/dev/null || return 1
  rmdir "$_mal_lock" 2>/dev/null || return 1
  MERV_ACTION_LOCK_OWNED=0
  return 0
}
