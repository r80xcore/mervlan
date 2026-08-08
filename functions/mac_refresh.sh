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
[ -n "${LIB_ACTION_PROGRESS_LOADED:-}" ] || . "$MERV_BASE/settings/lib_action_progress.sh" 2>/dev/null || :
if ! type merv_action_progress_init >/dev/null 2>&1; then
  merv_action_progress_init() { :; }
  merv_action_progress_phase() { :; }
  merv_action_progress_complete() { :; }
  merv_action_progress_fail() { :; }
fi

merv_action_progress_init "${MERV_PROGRESS_TOKEN:-}" "macrefresh_vlanmgr" "Rebuild MAC Shield" \
  "Preparing MAC shield refresh..."
if merv_update_mutation_blocked; then
  merv_action_progress_fail "MAC shield refresh refused while Update maintenance is active"
  exit 75
fi

mac_refresh_progress_exit() {
  _mr_rc=$?
  trap - EXIT
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
merv_action_progress_phase "Requesting snapshot reset and client collection..."
if ! MERV_OBS_NO_AUTOSTART=1 sh "$WORKER" request snapshot-reset collect >/dev/null 2>&1; then
  error -c cli,vlan "MAC Refresh: failed to publish observation generations"
  exit 1
fi

merv_action_progress_phase "Rebuilding MAC shield and collecting clients..."
if sh "$WORKER" run; then
  _status=$(sh "$WORKER" status 2>/dev/null | tr '\n' ';' | sed 's/;*$//')
  info -c cli,vlan "MAC Refresh: complete - ${_status:-observation generations complete}"
  exit 0
else
  _rc=$?
fi

_status=$(sh "$WORKER" status 2>/dev/null | tr '\n' ';' | sed 's/;*$//')
warn -c cli,vlan "MAC Refresh: deferred/failed (rc=$_rc); pending generation retained - ${_status:-status unavailable}"
exit "$_rc"
