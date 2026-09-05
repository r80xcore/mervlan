#!/bin/sh
#
# ============================================================================ #
#         - File: mervlan_live_test_guard.sh || version="0.2"                  #
# ============================================================================ #
# Persistent safety timer for deliberately disruptive live tests. ASUSWRT cru
# invokes `expire` independently of the initiating SSH session.
# ============================================================================ #

: "${MERV_BASE:=/jffs/addons/mervlan}"
: "${DEV_TOOLS_ROOT:=$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)}"
: "${LIVE_TEST_GUARD_SCRIPT:=$DEV_TOOLS_ROOT/safety/mervlan_live_test_guard.sh}"
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh" 2>/dev/null || true
[ -n "${LIB_MERVQT_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mervqt.sh"

GUARD_ACTION="${1:-status}"
GUARD_ROOT="${MERV_LIVE_TEST_GUARD_ROOT:-/tmp/mervlan_tmp/live_test_guard}"
GUARD_ARMED="$GUARD_ROOT/armed"
GUARD_HISTORY="$GUARD_ROOT/history"
GUARD_RECOVERY_PENDING="${MERV_DHCP_HOLD_STATE_ROOT:-$LOCKDIR/dhcp_hold}/recovery.pending"
GUARD_CRON="${MERV_LIVE_TEST_GUARD_CRON_NAME:-MerVLANLiveTestGuard}"
# The scheduler must not execute a path inside MERV_BASE: Update replaces that
# tree while a live test may still be active. Stage a private executable only
# when arming; it is removed on every terminal guard path.
GUARD_EXECUTABLE="${MERV_LIVE_TEST_GUARD_EXECUTABLE:-$GUARD_ROOT/mervlan_live_test_guard.sh}"

guard_log() {
  _gl_level="$1"
  shift
  if type "$_gl_level" >/dev/null 2>&1; then
    "$_gl_level" -c vlan,cli "Live test guard: $*"
  else
    printf 'Live test guard: %s\n' "$*" >&2
  fi
}

guard_now() {
  _gn_now=$(date +%s 2>/dev/null || printf '0')
  case "$_gn_now" in ''|*[!0-9]*) _gn_now=0 ;; esac
  printf '%s\n' "$_gn_now"
}

guard_cru() {
  if type cru >/dev/null 2>&1; then
    cru "$@"
  elif [ -x /usr/sbin/cru ]; then
    /usr/sbin/cru "$@"
  else
    return 127
  fi
}

guard_value() {
  _gv_key="$1"
  _gv_file="$2"
  sed -n "s/^${_gv_key}=//p" "$_gv_file" 2>/dev/null | tail -n1
}

guard_write_history() {
  _gwh_event="$1"
  shift
  mkdir -p "$GUARD_HISTORY" 2>/dev/null || return 1
  _gwh_now=$(guard_now)
  _gwh_tmp="$GUARD_HISTORY/.${_gwh_now}.$$.tmp"
  _gwh_dst="$GUARD_HISTORY/${_gwh_now}.$$"
  {
    printf 'event=%s\n' "$_gwh_event"
    printf 'epoch=%s\n' "$_gwh_now"
    printf '%s\n' "$*"
  } > "$_gwh_tmp" 2>/dev/null || return 1
  mv "$_gwh_tmp" "$_gwh_dst" 2>/dev/null
}

guard_path_outside_addon() {
  case "$1" in
    "$MERV_BASE"|"$MERV_BASE"/*|'') return 1 ;;
    /*) return 0 ;;
    *) return 1 ;;
  esac
}

guard_cleanup_executable() {
  rm -f "$GUARD_EXECUTABLE" "${GUARD_EXECUTABLE}.tmp.$$" 2>/dev/null || :
  _gce_parent=${GUARD_EXECUTABLE%/*}
  [ "$_gce_parent" != "$GUARD_EXECUTABLE" ] && rmdir "$_gce_parent" 2>/dev/null || :
}

guard_remove_empty_state() {
  [ -f "$GUARD_ARMED" ] && return 0
  rmdir "$GUARD_HISTORY" 2>/dev/null || :
  rmdir "$GUARD_ROOT" 2>/dev/null || :
}

guard_stage_executable() {
  guard_path_outside_addon "$GUARD_EXECUTABLE" || return 1
  [ -f "$LIVE_TEST_GUARD_SCRIPT" ] || return 1
  [ -L "$LIVE_TEST_GUARD_SCRIPT" ] && return 1
  _gse_parent=${GUARD_EXECUTABLE%/*}
  [ "$_gse_parent" != "$GUARD_EXECUTABLE" ] || _gse_parent=.
  mkdir -p "$_gse_parent" 2>/dev/null || return 1
  _gse_tmp="${GUARD_EXECUTABLE}.tmp.$$"
  rm -f "$_gse_tmp" 2>/dev/null || return 1
  cp -p "$LIVE_TEST_GUARD_SCRIPT" "$_gse_tmp" 2>/dev/null || return 1
  chmod 755 "$_gse_tmp" 2>/dev/null || return 1
  [ -x "$_gse_tmp" ] || return 1
  mv -f "$_gse_tmp" "$GUARD_EXECUTABLE" 2>/dev/null || {
    rm -f "$_gse_tmp" 2>/dev/null || :
    return 1
  }
  [ -x "$GUARD_EXECUTABLE" ]
}

guard_queue_recovery() {
  _gqr_reason="$1"
  _gqr_parent=${GUARD_RECOVERY_PENDING%/*}
  mkdir -p "$_gqr_parent" 2>/dev/null || return 1
  _gqr_tmp="${GUARD_RECOVERY_PENDING}.tmp.$$"
  {
    printf 'reason=%s\n' "$_gqr_reason"
    printf 'requested_epoch=%s\n' "$(guard_now)"
    printf 'source=live-test-guard\n'
  } > "$_gqr_tmp" 2>/dev/null || return 1
  mv "$_gqr_tmp" "$GUARD_RECOVERY_PENDING" 2>/dev/null
}

guard_schedule() {
  guard_cru d "$GUARD_CRON" 2>/dev/null || :
  guard_cru a "$GUARD_CRON" "* * * * * sh $GUARD_EXECUTABLE expire" ||
    return 1
  guard_cru l 2>/dev/null | grep -Fq "$GUARD_EXECUTABLE expire"
}

guard_unschedule() {
  guard_cru d "$GUARD_CRON" 2>/dev/null || return 1
  return 0
}

guard_arm() {
  _ga_seconds="${1:-300}"
  _ga_mode="${2:-}"
  case "$_ga_seconds" in ''|*[!0-9]*) guard_log error "duration must be an integer"; return 1 ;; esac
  [ "$_ga_seconds" -ge 30 ] && [ "$_ga_seconds" -le 3600 ] || {
    guard_log error "duration must be between 30 and 3600 seconds"
    return 1
  }
  case "$_ga_mode" in
    '') _ga_mode=fail-closed ;;
    --break-glass-dhcp-release) _ga_mode=break-glass-dhcp-release ;;
    *) guard_log error "unknown arm option: $_ga_mode"; return 1 ;;
  esac

  mkdir -p "$GUARD_ROOT" "$GUARD_HISTORY" 2>/dev/null || return 2
  guard_stage_executable || {
    guard_cleanup_executable
    guard_remove_empty_state
    guard_log error "could not stage an executable guard outside the addon tree"
    return 2
  }
  _ga_now=$(guard_now)
  _ga_deadline=$((_ga_now + _ga_seconds))
  _ga_tmp="${GUARD_ARMED}.tmp.$$"
  {
    printf 'armed_epoch=%s\n' "$_ga_now"
    printf 'deadline_epoch=%s\n' "$_ga_deadline"
    printf 'duration_seconds=%s\n' "$_ga_seconds"
    printf 'mode=%s\n' "$_ga_mode"
    printf 'pid=%s\n' "$$"
  } > "$_ga_tmp" 2>/dev/null || {
    rm -f "$_ga_tmp" 2>/dev/null || :
    guard_cleanup_executable
    guard_remove_empty_state
    return 2
  }
  mv "$_ga_tmp" "$GUARD_ARMED" 2>/dev/null || {
    rm -f "$_ga_tmp" 2>/dev/null || :
    guard_cleanup_executable
    guard_remove_empty_state
    return 2
  }

  if ! guard_schedule; then
    rm -f "$GUARD_ARMED" 2>/dev/null || :
    guard_unschedule || :
    guard_cleanup_executable
    guard_remove_empty_state
    guard_log error "ASUSWRT cru scheduler is unavailable; guard was not armed"
    return 3
  fi
  guard_write_history armed "deadline=$_ga_deadline mode=$_ga_mode" || :
  if [ "$_ga_mode" = break-glass-dhcp-release ]; then
    guard_log warn "SECURITY OVERRIDE ARMED: expiry may remove DHCP protection while interface placement is unverified"
  fi
  printf 'armed=yes deadline_epoch=%s mode=%s\n' "$_ga_deadline" "$_ga_mode"
  return 0
}

guard_status() {
  if [ ! -f "$GUARD_ARMED" ]; then
    printf 'armed=no\n'
    _gs_last_name=$(ls -1t "$GUARD_HISTORY" 2>/dev/null | head -n1)
    [ -n "$_gs_last_name" ] && _gs_last="$GUARD_HISTORY/$_gs_last_name" || _gs_last=""
    [ -n "$_gs_last" ] && {
      printf 'last_event=%s\n' "$(guard_value event "$_gs_last")"
      printf 'last_epoch=%s\n' "$(guard_value epoch "$_gs_last")"
    }
    [ -f "$GUARD_RECOVERY_PENDING" ] && printf 'recovery_pending=yes\n' || printf 'recovery_pending=no\n'
    return 0
  fi
  _gs_now=$(guard_now)
  _gs_deadline=$(guard_value deadline_epoch "$GUARD_ARMED")
  _gs_mode=$(guard_value mode "$GUARD_ARMED")
  case "$_gs_deadline" in ''|*[!0-9]*) _gs_remaining=invalid ;; *)
    _gs_remaining=$((_gs_deadline - _gs_now))
    [ "$_gs_remaining" -ge 0 ] || _gs_remaining=0
    ;;
  esac
  printf 'armed=yes\n'
  printf 'deadline_epoch=%s\n' "$_gs_deadline"
  printf 'remaining_seconds=%s\n' "$_gs_remaining"
  printf 'mode=%s\n' "$_gs_mode"
  return 0
}

guard_disarm() {
  if [ ! -f "$GUARD_ARMED" ]; then
    guard_unschedule || :
    guard_cleanup_executable
    guard_remove_empty_state
    printf 'armed=no\n'
    return 0
  fi
  guard_unschedule || {
    guard_log error "ASUSWRT cru scheduler could not be disarmed; guard remains armed"
    return 1
  }
  _gd_now=$(guard_now)
  mv "$GUARD_ARMED" "$GUARD_HISTORY/disarmed.${_gd_now}.$$" 2>/dev/null || {
    guard_log error "could not record the disarmed guard state"
    return 1
  }
  guard_cleanup_executable
  guard_write_history disarmed "operator-requested=yes" || :
  printf 'armed=no\n'
  return 0
}

guard_expire() {
  if [ ! -f "$GUARD_ARMED" ]; then
    guard_unschedule || :
    guard_cleanup_executable
    guard_remove_empty_state
    return 0
  fi
  _ge_now=$(guard_now)
  _ge_deadline=$(guard_value deadline_epoch "$GUARD_ARMED")
  _ge_mode=$(guard_value mode "$GUARD_ARMED")
  case "$_ge_deadline" in ''|*[!0-9]*) _ge_deadline=0 ;; esac
  [ "$_ge_now" -ge "$_ge_deadline" ] || return 0

  mkdir -p "$GUARD_HISTORY" 2>/dev/null || return 2
  guard_unschedule || {
    guard_log error "ASUSWRT cru scheduler could not be disarmed at expiry; guard remains armed"
    return 2
  }
  _ge_claim="$GUARD_HISTORY/expiring.${_ge_now}.$$"
  mv "$GUARD_ARMED" "$_ge_claim" 2>/dev/null || return 0
  guard_cleanup_executable
  guard_log warn "deadline expired; running known-good manager recovery"

  _ge_recovered=0
  if sh "$MERV_BASE/functions/mervlan_manager.sh" --no-collect; then
    if merv_dhcp_hold_reconcile live-guard &&
       [ ! -f "$MERV_DHCP_HOLD_LEGACY_MARKER" ] &&
       merv_dhcp_hold_rules_absent; then
      _ge_recovered=1
    fi
  fi

  if [ "$_ge_recovered" -eq 1 ]; then
    guard_write_history recovery-succeeded "manager_and_exact_audit=passed" || :
    guard_log info "recovery and exact DHCP-hold audit succeeded"
    return 0
  fi

  guard_queue_recovery live-test-guard-expired || :
  if [ "$_ge_mode" = break-glass-dhcp-release ]; then
    guard_log error "SECURITY OVERRIDE EXECUTING: interface placement is unverified; removing DHCP hold for administrative access"
    rm -f "$MERV_DHCP_HOLD_LEGACY_MARKER" 2>/dev/null || :
    merv_dhcp_hold_rules_remove || :
    guard_write_history break-glass-executed \
      "security_warning=interface-placement-unverified recovery_pending=yes" || :
    return 5
  fi

  # Default is fail-closed. Re-enforcement failure is logged and faulted by the
  # shared library; no availability-over-security action is taken implicitly.
  merv_dhcp_hold_arm quiet || :
  guard_write_history recovery-failed "fail_closed=yes recovery_pending=yes" || :
  guard_log error "recovery failed; DHCP protection retained and recovery queued"
  return 5
}

case "$GUARD_ACTION" in
  arm) guard_arm "${2:-300}" "${3:-}" ;;
  status) guard_status ;;
  disarm) guard_disarm ;;
  expire) guard_expire ;;
  *)
    printf 'Usage: %s {arm <30-3600> [--break-glass-dhcp-release]|status|disarm}\n' "$0" >&2
    exit 1
    ;;
esac
