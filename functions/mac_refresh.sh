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

WORKER="$MERV_BASE/functions/post_apply_worker.sh"
if [ ! -x "$WORKER" ]; then
  error -c cli,vlan "MAC Refresh: observation coordinator is unavailable"
  exit 1
fi

# Manual refresh is synchronous for the UI. snapshot-reset is still only a
# generation request: the worker owns both the observation lock and the inner
# snapshot/collection locks, preserving the global lock order.
info -c cli,vlan "MAC Refresh: requesting reset snapshot and client collection"
if ! MERV_OBS_NO_AUTOSTART=1 "$WORKER" request snapshot-reset collect >/dev/null 2>&1; then
  error -c cli,vlan "MAC Refresh: failed to publish observation generations"
  exit 1
fi

if "$WORKER" run; then
  _status=$("$WORKER" status 2>/dev/null | tr '\n' ';' | sed 's/;*$//')
  info -c cli,vlan "MAC Refresh: complete - ${_status:-observation generations complete}"
  exit 0
else
  _rc=$?
fi

_status=$("$WORKER" status 2>/dev/null | tr '\n' ';' | sed 's/;*$//')
warn -c cli,vlan "MAC Refresh: deferred/failed (rc=$_rc); pending generation retained - ${_status:-status unavailable}"
exit "$_rc"
