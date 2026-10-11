#!/bin/sh
# ============================================================================
# - File: mac_refresh.sh || version="0.23"
# - Purpose: Request a destructive-safe MAC reset snapshot and client refresh.
# ============================================================================
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_UPDATE_STATE_LOADED:-}" ] || . "$MERV_BASE/settings/lib_update_state.sh" 2>/dev/null || exit 75
[ -n "${LIB_ACTION_LOCK_LOADED:-}" ] || . "$MERV_BASE/settings/lib_action_lock.sh" 2>/dev/null || exit 75
[ -n "${LIB_MUTATION_ADMISSION_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mutation_admission.sh" 2>/dev/null || exit 75
[ -n "${LIB_ACTION_PROGRESS_LOADED:-}" ] || . "$MERV_BASE/settings/lib_action_progress.sh" 2>/dev/null || :
if ! type merv_action_progress_init >/dev/null 2>&1; then
  merv_action_progress_init() { :; }
  merv_action_progress_phase() { :; }
  merv_action_progress_update() { :; }
  merv_action_progress_complete() { :; }
  merv_action_progress_fail() { :; }
fi

if merv_update_mutation_blocked; then
  exit 75
fi

MAC_REFRESH_ACTION_LOCK="${MERV_ACTION_LOCK_PATH:-$LOCKDIR/mervlan_action.lock}"
if ! merv_action_lock_enter "$MAC_REFRESH_ACTION_LOCK"; then
  error -c cli,vlan "MAC Refresh refused because its action owner could not be acquired or verified"
  exit 75
fi
MAC_REFRESH_ACTION_MODE="${MERV_ACTION_LOCK_MODE:-none}"
MAC_REFRESH_ACTION_NONCE="${MERV_ACTION_LOCK_NONCE:-}"
MAC_REFRESH_ACTION_START="${MERV_ACTION_LOCK_START:-}"
merv_action_lock_export_child_context || {
  merv_action_lock_leave "$MAC_REFRESH_ACTION_LOCK" "$MAC_REFRESH_ACTION_NONCE" \
    "$MAC_REFRESH_ACTION_START" "$MAC_REFRESH_ACTION_MODE" >/dev/null 2>&1 || :
  exit 75
}
if ! merv_mutation_admit_action "$MAC_REFRESH_ACTION_LOCK"; then
  error -c cli,vlan "MAC Refresh refused by mutation admission (${MERV_MUTATION_ADMISSION_REASON:-unknown})"
  merv_action_lock_leave "$MAC_REFRESH_ACTION_LOCK" "$MAC_REFRESH_ACTION_NONCE" \
    "$MAC_REFRESH_ACTION_START" "$MAC_REFRESH_ACTION_MODE" >/dev/null 2>&1 || :
  exit 75
fi

merv_action_progress_init "${MERV_PROGRESS_TOKEN:-}" "macrefresh_vlanmgr" "Rebuild MAC Shield" \
  "Preparing MAC shield refresh..."

# Allow the synchronous observation worker and MAC snapshot code to publish
# detailed milestones into this same backend-owned progress record.
MERV_MAC_REFRESH_PROGRESS=1
export MERV_MAC_REFRESH_PROGRESS MERV_PROGRESS_TOKEN
export MERV_ACTION_PROGRESS_STARTED_AT MERV_ACTION_PROGRESS_PID
export MERV_ACTION_PROGRESS_OWNER_START MERV_ACTION_PROGRESS_NONCE

merv_action_progress_update prepare 0 0 5 \
  "Preparing MAC Shield rebuild..."

mac_refresh_progress_exit() {
  _mr_rc=$?
  trap - EXIT
  if ! merv_action_lock_leave "$MAC_REFRESH_ACTION_LOCK" "$MAC_REFRESH_ACTION_NONCE" \
       "$MAC_REFRESH_ACTION_START" "$MAC_REFRESH_ACTION_MODE" >/dev/null 2>&1; then
    error -c cli,vlan "MAC Refresh could not release its action owner; recovery is required"
    [ "$_mr_rc" -ne 0 ] || _mr_rc=75
  fi
  if [ "$_mr_rc" -eq 0 ]; then
    merv_action_progress_complete "MAC shield refresh complete"
  else
    merv_action_progress_fail "MAC shield refresh failed; see the VLAN log for details"
  fi
  exit "$_mr_rc"
}
trap 'mac_refresh_progress_exit' EXIT

WORKER="$MERV_BASE/functions/post_apply_worker.sh"
if [ ! -x "$WORKER" ]; then
  error -c cli,vlan "MAC Refresh: observation coordinator is unavailable"
  exit 1
fi

# Manual refresh is synchronous for the UI. snapshot-reset is still only a
# generation request: the worker owns both the observation lock and the inner
# snapshot/collection locks, preserving the global lock order.
info -c cli,vlan "MAC Refresh: requesting reset snapshot and client collection"
merv_action_progress_update prepare 0 0 10 \
  "Queuing MAC Shield rebuild and client collection..."
if ! MERV_OBS_NO_AUTOSTART=1 sh "$WORKER" request snapshot-reset collect >/dev/null 2>&1; then
  error -c cli,vlan "MAC Refresh: failed to publish observation generations"
  exit 1
fi

merv_action_progress_update preflight 0 0 15 \
  "Starting MAC Shield observation worker..."
if sh "$WORKER" run-wait "${MERV_OBS_AUTOSTART_WAIT_SEC:-120}"; then
  _status=$(sh "$WORKER" status 2>/dev/null | tr '\n' ';' | sed 's/;*$//')
  info -c cli,vlan "MAC Refresh: complete - ${_status:-observation generations complete}"
  merv_action_progress_update finish 1 1 98 \
    "Finalizing MAC Shield refresh..."
  exit 0
else
  _rc=$?
fi

_status=$(sh "$WORKER" status 2>/dev/null | tr '\n' ';' | sed 's/;*$//')
warn -c cli,vlan "MAC Refresh: deferred/failed (rc=$_rc); pending generation retained - ${_status:-status unavailable}"
exit "$_rc"
