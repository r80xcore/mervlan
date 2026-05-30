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
#                 - File: mac_refresh.sh || version="0.2"                      #
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
# This flushes and rebuilds the MERV_MAC db + ebtables chain. Two concurrent
# refreshes would race the same db files and chain, so take a NON-BLOCKING
# self-lock: a second refresh skips rather than corrupting state. Skip-on-
# contention can never deadlock, and a crashed refresh is reclaimed after the
# stale window. Best-effort — if the lib is somehow absent we proceed unguarded
# rather than block a security-relevant rebuild.
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
_mac_pre_f="${MERV_MAC_DB_ACTIVE}.pre.$$"
_mac_post_f="${MERV_MAC_DB_ACTIVE}.post.$$"

# Snapshot the current MAC set before clearing (empty sorted file if db absent)
if [ -f "$MERV_MAC_DB_ACTIVE" ]; then
  awk 'NF==4{print $2}' "$MERV_MAC_DB_ACTIVE" 2>/dev/null | sort -u > "$_mac_pre_f" 2>/dev/null
else
  : > "$_mac_pre_f"
fi
_old_count=$(wc -l < "$_mac_pre_f" 2>/dev/null | tr -d ' ')

info -c cli,vlan "MAC Refresh: starting — db has ${_old_count:-0} MAC(s), flushing and rebuilding"

rm -f "$MERV_MAC_DB_ACTIVE" "$MERV_MAC_DB_JFFS" 2>/dev/null || true

# Flush the chain rules (chain stays alive — no enforcement gap)
ebt_mac_shield_flush

# Build fresh snapshot from current VLAN bridge state and reload rules.
# If preconditions fail (e.g. wireless mid-restart), merv_mac_snapshot logs
# the skip reason and returns 0. Chain remains empty until next heal cycle.
merv_mac_snapshot

# Build post-snapshot MAC set for diff reporting
if [ -f "$MERV_MAC_DB_ACTIVE" ]; then
  awk 'NF==4{print $2}' "$MERV_MAC_DB_ACTIVE" 2>/dev/null | sort -u > "$_mac_post_f" 2>/dev/null
else
  : > "$_mac_post_f"
fi
_new_count=$(wc -l < "$_mac_post_f" 2>/dev/null | tr -d ' ')

# Diff: comm requires sorted inputs — both files are sorted -u above
_added=$(  comm -13 "$_mac_pre_f" "$_mac_post_f" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')
_removed=$(comm -23 "$_mac_pre_f" "$_mac_post_f" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')
_unch=$(   comm -12 "$_mac_pre_f" "$_mac_post_f" 2>/dev/null | wc -l | tr -d ' ')
rm -f "$_mac_pre_f" "$_mac_post_f" 2>/dev/null

if [ -n "$_added" ] || [ -n "$_removed" ]; then
  [ -n "$_added"   ] && info -c cli,vlan "MAC Refresh: added   — ${_added}"
  [ -n "$_removed" ] && info -c cli,vlan "MAC Refresh: removed — ${_removed}"
  info -c cli,vlan "MAC Refresh: shield rebuilt — ${_new_count:-0} MAC(s) active (${_unch:-0} unchanged)"
elif [ "${_new_count:-0}" -eq 0 ]; then
  info -c cli,vlan "MAC Refresh: shield empty — no clients in VLAN bridges (snapshot skipped or no clients)"
else
  info -c cli,vlan "MAC Refresh: MAC set unchanged — ${_new_count:-0} MAC(s)"
fi

# Propagate MAC refresh to all configured nodes (skip when running as a node)
if [ "${MERV_NODE_CONTEXT:-0}" != "1" ] && \
   [ "$(json_get_flag "IS_NODE" "0" "$SETTINGS_FILE" 2>/dev/null)" != "1" ] && \
   [ ! -f "$MERV_BASE/.is_node" ] && \
   type merv_ssh_exec >/dev/null 2>&1; then
  _node_ips=$(grep -o '"NODE[1-5]"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" | \
    sed -n 's/"NODE\([1-5]\)"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1 \2/p' | \
    awk '$2 != "none" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $1, $2 }')
  if [ -n "$_node_ips" ]; then
    info -c cli,vlan "MAC Refresh: propagating to nodes..."
    while read -r _nid _nip; do
      [ -n "$_nip" ] || continue
      if merv_ssh_exec "$_nid" "$_nip" \
           "cd '$MERV_BASE/functions' && MERV_NODE_CONTEXT=1 sh ./mac_refresh.sh" \
           >/dev/null 2>&1; then
        info -c cli,vlan "MAC Refresh: ✓ node ${_nip} refreshed"
      else
        warn -c cli,vlan "MAC Refresh: ✗ node ${_nip} failed or unreachable"
      fi
    done <<EOF
$_node_ips
EOF
  fi
fi

info -c cli,vlan "MAC Refresh: complete"
exit 0
