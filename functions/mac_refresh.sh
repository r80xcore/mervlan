#!/bin/sh
# ============================================================================ #
#                                                                              #
#   /$$      /$$                     /$$    /$$ /$$        /$$$$$$  /$$   /$$  #
#  | $$$    /$$$                    | $$   | $$| $$       /$$__  $$| $$$ | $$  #
#  | $$$$  /$$$$  /$$$$$$   /$$$$$$ | $$   | $$| $$      | $$  \ $$| $$$$| $$  #
#  | $$ $$/$$ $$ /$$__  $$ /$$__  $$|  $$ / $$/| $$      | $$$$$$$$| $$ $$ $$  #
#  | $$  $$$| $$| $$$$$$$$| $$  \__/ \  $$ $$/ | $$      | $$__  $$| $$  $$$$  #
#  | $$\  $ | $$| $$_____/| $$        \  $$$/  | $$      | $$  | $$| $$\  $$$  #
#  | $$ \/  | $$|  $$$$$$$| $$         \  $/   | $$$$$$$$| $$  | $$| $$ \  $$  #
#  |__/     |__/ \_______/|__/          \_/    |________/|__/  |__/|__/  \__/  #
#                                                                              #
# ============================================================================ #
#                 - File: mac_refresh.sh || version="0.21"                      #
# ============================================================================ #
# Purpose: Clear the MERV_MAC client db and rebuild from a fresh wl assoclist
#   snapshot. Called from the UI "MAC Shield Refresh" button.
#
#   Useful when the db is suspected stale: e.g., after decommissioning a device,
#   after a long outage, or after the snapshot window was missed due to empty
#   bridge (all clients disconnected before snapshot ran).
#
# Exit behaviour: always exits 0 — UI caller ignores exit codes.
# ============================================================================ #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_JSON_LOADED LIB_SSID_FILTER_LOADED LIB_MERVQT_LOADED LIB_MAC_SHIELD_SNAPSHOT_LOADED LIB_SSH_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ]            || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ]            || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_JSON_LOADED:-}" ]                || . "$MERV_BASE/settings/lib_json.sh"
[ -n "${LIB_SSID_FILTER_LOADED:-}" ]         || . "$MERV_BASE/settings/lib_ssid_filter.sh"
[ -n "${LIB_MERVQT_LOADED:-}" ]              || . "$MERV_BASE/settings/lib_mervqt.sh"
[ -n "${LIB_MAC_SHIELD_SNAPSHOT_LOADED:-}" ] || . "$MERV_BASE/settings/mac_shield_snapshot.sh"
[ -n "${LIB_SSH_LOADED:-}" ]                 || . "$MERV_BASE/settings/lib_ssh.sh" 2>/dev/null || true

# --------------------------------------------------------- Bootstrap config --
: "${HW_SETTINGS_FILE:=$SETTINGS_FILE}"
if [ -z "${MAX_SSIDS:-}" ]; then
  MAX_SSIDS=$(json_get_int MAX_SSIDS 12 "$HW_SETTINGS_FILE")
fi

# merv_mac_snapshot checks DRY_RUN internally; force to "no" for this script
DRY_RUN="no"

# SSID filter must be initialized for get_ssid_slot_value / get_vlan_slot_value
MERV_NODE_ID="$(json_get_flag NODE_ID "" "$SETTINGS_FILE")"
ssid_filter_init "$MERV_NODE_ID"

# ----------------------------------------------------------- Concurrency lock --
# Two concurrent manual refreshes would race the same rebuild, so take a
# NON-BLOCKING self-lock: a second refresh skips rather than corrupting state.
# Skip-on-contention can never deadlock, and a crashed refresh is reclaimed
# after the stale window. Best-effort — if the lib is somehow absent we proceed
# unguarded rather than block a security-relevant rebuild.
#
# We no longer pre-acquire mac_snapshot.lock here: merv_mac_snapshot now owns
# the entire destructive critical section (reset/empty-clear happen inside it)
# and takes that lock itself, reporting MERV_MAC_LAST_STATUS=busy on contention.
MAC_REFRESH_LOCK="$LOCKDIR/mac_refresh.lock"
MAC_REFRESH_LOCK_ACQUIRED=0
if type merv_lock_acquire >/dev/null 2>&1; then
  mkdir -p "$LOCKDIR" 2>/dev/null || :
  if merv_lock_acquire "$MAC_REFRESH_LOCK" "${MERV_MAC_REFRESH_LOCK_STALE_SEC:-60}" 0 "mac_refresh"; then
    MAC_REFRESH_LOCK_ACQUIRED=1
    trap '[ "$MAC_REFRESH_LOCK_ACQUIRED" -eq 1 ] && merv_lock_release "$MAC_REFRESH_LOCK" 2>/dev/null' EXIT INT TERM
  else
    info -c cli,vlan "MAC Refresh: another refresh is in progress — skipping"
    exit 0
  fi
fi

# -------------------------------------------------------------- Main action --
_old_count=0
[ -f "$MERV_MAC_DB_ACTIVE" ] && \
  _old_count=$(awk 'NF==4' "$MERV_MAC_DB_ACTIVE" 2>/dev/null | wc -l | tr -d ' ')

# Drive the single snapshot engine in manual/reset mode. The engine owns the
# whole lifecycle: preconditions → build → node collect → merge/reset →
# init_and_apply → node push. The db is only cleared AFTER a valid, COMPLETE
# observation, so a precondition failure or an unreachable node leaves the
# existing shield intact (the engine downgrades reset → merge automatically).
MERV_MAC_SNAPSHOT_VERBOSE=1
MERV_MAC_SNAPSHOT_LOG_CHANNELS=cli,vlan
MERV_MAC_SNAPSHOT_RESET=1
MERV_MAC_SNAPSHOT_ALLOW_EMPTY=1
export MERV_MAC_SNAPSHOT_VERBOSE MERV_MAC_SNAPSHOT_LOG_CHANNELS \
       MERV_MAC_SNAPSHOT_RESET MERV_MAC_SNAPSHOT_ALLOW_EMPTY

info -c cli,vlan "MAC Refresh: starting — reset mode, current db has ${_old_count:-0} MAC(s)"

merv_mac_snapshot

# Summarize from the engine's same-process status globals (we call snapshot
# inline, so the MERV_MAC_LAST_* values reflect what actually happened).
case "${MERV_MAC_LAST_STATUS:-}" in
  changed|reloaded|unchanged|empty)
    info -c cli,vlan "MAC Refresh: complete — status=${MERV_MAC_LAST_STATUS} active db=${MERV_MAC_LAST_DB_COUNT:-0} MAC(s) (local=${MERV_MAC_LAST_LOCAL_COUNT:-0} node=${MERV_MAC_LAST_NODE_COUNT:-0})"
    [ "${MERV_MAC_LAST_NODES_TOTAL:-0}" -gt 0 ] && \
      info -c cli,vlan "MAC Refresh: nodes collected ${MERV_MAC_LAST_NODES_OK:-0}/${MERV_MAC_LAST_NODES_TOTAL:-0}, pushed ${MERV_MAC_LAST_PUSH_OK:-0}/${MERV_MAC_LAST_PUSH_TOTAL:-0}"
    [ "${MERV_MAC_LAST_NODES_FAILED:-0}" -gt 0 ] && \
      warn -c cli,vlan "MAC Refresh: ${MERV_MAC_LAST_NODES_FAILED} node(s) unreachable during collection — db preserved from existing entries"
    ;;
  precondition_failed)
    warn -c cli,vlan "MAC Refresh: aborted — ${MERV_MAC_LAST_REASON:-interfaces not settled}; existing db kept (${_old_count:-0} MAC(s))"
    ;;
  clear_failed)
    warn -c cli,vlan "MAC Refresh: failed — could not clear active db; existing db preserved"
    ;;
  merge_failed)
    warn -c cli,vlan "MAC Refresh: failed — db write error; existing db preserved"
    ;;
  busy)
    info -c cli,vlan "MAC Refresh: a MAC snapshot is already running — try again in 15-20 seconds"
    ;;
  *)
    warn -c cli,vlan "MAC Refresh: completed with unknown status (${MERV_MAC_LAST_STATUS:-none})"
    ;;
esac

# Refresh the client inventory in the BACKGROUND so the UI's locked/override
# badges reflect the freshly rebuilt shield db. Background is intentional: the
# service-event handler dispatch must not block on a collection that can take
# up to 90s when nodes are slow. Best-effort, fire-and-forget.
if [ -x "$MERV_BASE/functions/collect_clients.sh" ]; then
  sh "$MERV_BASE/functions/collect_clients.sh" >/dev/null 2>&1 &
fi

exit 0
