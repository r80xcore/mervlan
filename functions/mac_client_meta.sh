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
#               - File: mac_client_meta.sh || version="0.12"                    #
# ============================================================================ #
# Purpose: Materialize the two client-metadata databases from settings.json and
#   re-enforce them, then refresh the client inventory so the UI reflects the
#   change. Triggered by the UI "Save Client Metadata" action.
#
#   1. MAC shield override DB (MERV_MAC_OVERRIDE_DB)  — CLUSTER-WIDE.
#      Lists MACs whose MERV_MAC DROP rule is suppressed. The MACs stay in the
#      shield db; only their DROP rule is withheld. Removing an override and
#      reloading re-locks the MAC. Pushed to all nodes.
#
#   2. Client display-name DB (MERV_CLIENT_NAME_DB)   — MAIN ROUTER ONLY.
#      Tab-separated "mac<TAB>name" used purely to annotate the merged client
#      JSON for display. Never pushed to nodes (annotation happens after the
#      merged collection on the main router).
#
# Storage formats in settings.json (section "ClientMeta"):
#   MAC_SHIELD_OVERRIDES : comma-separated MACs   "aa:bb:..,11:22:.."
#   CLIENT_NAME_OVERRIDES: semicolon-separated     "aa:bb:..=Name;11:22:..=Other"
#                          pairs of  <mac>=<name>
#
# Main-router only: a node run early-exits (override DB arrives via the shield
# push, name DB is display-only and not meaningful on a node).
#
# Exit behaviour: always exits 0 — UI caller ignores exit codes.
# ============================================================================ #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_JSON_LOADED LIB_SSID_FILTER_LOADED LIB_MERVQT_LOADED LIB_MAC_SHIELD_SNAPSHOT_LOADED LIB_SSH_LOADED LIB_ACTION_LOCK_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ]            || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ]            || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_JSON_LOADED:-}" ]                || . "$MERV_BASE/settings/lib_json.sh"
[ -n "${LIB_MERVQT_LOADED:-}" ]              || . "$MERV_BASE/settings/lib_mervqt.sh"
[ -n "${LIB_MAC_SHIELD_SNAPSHOT_LOADED:-}" ] || . "$MERV_BASE/settings/mac_shield_snapshot.sh"
[ -n "${LIB_SSH_LOADED:-}" ]                 || . "$MERV_BASE/settings/lib_ssh.sh" 2>/dev/null || true
[ -n "${LIB_ACTION_LOCK_LOADED:-}" ]        || . "$MERV_BASE/settings/lib_action_lock.sh" || exit 1
[ -n "${LIB_UPDATE_STATE_LOADED:-}" ]       || . "$MERV_BASE/settings/lib_update_state.sh" 2>/dev/null || exit 75
[ -n "${LIB_ACTION_PROGRESS_LOADED:-}" ]    || . "$MERV_BASE/settings/lib_action_progress.sh" 2>/dev/null || :
if ! type merv_action_progress_init >/dev/null 2>&1; then
  merv_action_progress_init() { :; }
  merv_action_progress_phase() { :; }
  merv_action_progress_complete() { :; }
  merv_action_progress_fail() { :; }
fi

DRY_RUN="no"
merv_action_progress_init "${MERV_PROGRESS_TOKEN:-}" "macclientmeta_vlanmgr" "Save Client Metadata" \
  "Preparing client metadata..."
if merv_update_mutation_blocked; then
  merv_action_progress_fail "Client metadata save refused while Update maintenance is active"
  exit 75
fi
META_SIGNAL_HANDLING=0
meta_handle_signal() {
  _meta_signal_status="$1"
  [ "${META_SIGNAL_HANDLING:-0}" -eq 0 ] || exit "$_meta_signal_status"
  META_SIGNAL_HANDLING=1
  trap - INT TERM
  if type merv_action_progress_fail >/dev/null 2>&1; then
    merv_action_progress_fail "Client metadata save interrupted; no success result was published"
  fi
  error -c cli,vlan "Client Metadata: interrupted (rc=$_meta_signal_status); stopping before normal completion"
  exit "$_meta_signal_status"
}
trap 'meta_handle_signal 130' INT
trap 'meta_handle_signal 143' TERM

META_ACTION_LOCK_PATH="${MERV_ACTION_LOCK_PATH:-$LOCKDIR/mervlan_action.lock}"
if ! merv_action_lock_enter "$META_ACTION_LOCK_PATH"; then
  merv_action_progress_fail "Another mutating action is already running"
  exit 75
fi
META_ACTION_LOCK_MODE="${MERV_ACTION_LOCK_MODE:-none}"
META_ACTION_LOCK_NONCE="$MERV_ACTION_LOCK_NONCE"
META_ACTION_LOCK_START="$MERV_ACTION_LOCK_START"
merv_action_lock_export_child_context || exit 75
META_ACTION_LOCK_RELEASED=0
meta_release_action_lock() {
  _meta_action_exit_rc=$?
  if [ "${META_ACTION_LOCK_RELEASED:-0}" -eq 0 ]; then
    if merv_action_lock_leave "$META_ACTION_LOCK_PATH" "$META_ACTION_LOCK_NONCE" "$META_ACTION_LOCK_START" "$META_ACTION_LOCK_MODE" >/dev/null 2>&1; then
      META_ACTION_LOCK_RELEASED=1
    else
      error -c cli,vlan "Client Metadata cleanup could not release the global action lock"
      [ "$_meta_action_exit_rc" -eq 0 ] && _meta_action_exit_rc=75
    fi
  fi
  return "$_meta_action_exit_rc"
}
trap 'meta_release_action_lock' EXIT

# ---------------------------------------------------------------- Main guard --
# Override DB is materialized + pushed from the main router; the name DB is a
# main-only display aid. A node run has nothing useful to do here.
if ! merv_mac_is_main; then
  info -c cli,vlan "Client Metadata: skipped on node context"
  merv_action_progress_complete "Client metadata skipped on node context"
  exit 0
fi

# ----------------------------------------------------------- Concurrency lock --
# Serialize against concurrent saves so two writers never race the same DB
# rebuild. Non-blocking: a second save skips rather than corrupting state.
META_LOCK="$LOCKDIR/mac_client_meta.lock"
META_LOCK_ACQUIRED=0
if type merv_lock_acquire >/dev/null 2>&1; then
  mkdir -p "$LOCKDIR" 2>/dev/null || { error -c cli,vlan "Client Metadata: lock directory unavailable"; exit 1; }
  if merv_lock_acquire "$META_LOCK" "${MERV_CLIENT_META_LOCK_STALE_SEC:-60}" 0 "mac_client_meta"; then
    META_LOCK_ACQUIRED=1
    META_LOCK_NONCE="${MERV_LOCK_NONCE:-}"
    meta_release_lock() {
      _meta_exit_rc=$?
      if [ "${META_LOCK_ACQUIRED:-0}" -eq 1 ]; then
        if merv_lock_release "$META_LOCK" "$META_LOCK_NONCE" 2>/dev/null; then
          META_LOCK_ACQUIRED=0
        else
          error -c cli,vlan "Client Metadata cleanup could not release its owner lock"
          _meta_exit_rc=1
        fi
      fi
      META_ACTION_LOCK_RELEASED=0
      meta_release_action_lock
      _meta_action_rc=$?
      [ "$_meta_action_rc" -eq 0 ] || _meta_exit_rc=75
      return "$_meta_exit_rc"
    }
    trap 'meta_release_lock' EXIT
  else
    merv_action_progress_fail "Another client metadata save is already running"
    info -c cli,vlan "Client Metadata: another save is in progress — skipping"
    exit 0
  fi
fi

# ------------------------------------------------------------- Read settings --
RAW_OVERRIDES=$(json_get_section_value "ClientMeta" "MAC_SHIELD_OVERRIDES" "$SETTINGS_FILE" 2>/dev/null)
RAW_NAMES=$(json_get_section_value "ClientMeta" "CLIENT_NAME_OVERRIDES" "$SETTINGS_FILE" 2>/dev/null)
merv_action_progress_phase "Writing MAC override and display-name databases..."

# ----------------------------------------------- Materialize MAC override DB --
# Split comma-separated MACs, lowercase + validate, dedupe. An empty result is
# meaningful: it writes an empty file so a previously-overridden MAC re-locks.
mkdir -p "${MERV_MAC_OVERRIDE_DB%/*}" 2>/dev/null || :
OVR_TMP="${MERV_MAC_OVERRIDE_DB}.tmp.$$"
: > "$OVR_TMP"
_ovr_count=0
if [ -n "$RAW_OVERRIDES" ]; then
  printf '%s\n' "$RAW_OVERRIDES" | tr ',' '\n' | while IFS= read -r _m; do
    _m=$(printf '%s' "$_m" | tr -d ' \t\r')
    [ -n "$_m" ] || continue
    _m=$(mervqt_mac_lower "$_m")
    mervqt_valid_mac "$_m" || continue
    printf '%s\n' "$_m"
  done | sort -u > "$OVR_TMP"
fi
_ovr_count=$(awk 'NF' "$OVR_TMP" 2>/dev/null | wc -l | tr -d ' ')
_meta_partial=0
if mv "$OVR_TMP" "$MERV_MAC_OVERRIDE_DB" 2>/dev/null; then
  chmod 600 "$MERV_MAC_OVERRIDE_DB" 2>/dev/null || :
  info -c cli,vlan "Client Metadata: MAC override DB written (${_ovr_count} entry/entries)"
  # Echo the materialized override MACs so a failed/empty override set is
  # diagnosable from the log without reading the DB file directly.
  _ovr_macs=$(tr '\n' ' ' < "$MERV_MAC_OVERRIDE_DB" 2>/dev/null | sed 's/ *$//')
  info -c cli,vlan "Client Metadata: override MACs: ${_ovr_macs:-(none)}"
else
  merv_action_progress_fail "Client metadata override DB could not be written"
  rm -f "$OVR_TMP" 2>/dev/null || :
  # The override DB drives which MACs lose their DROP rule. If the write fails
  # the on-disk DB is stale, so reloading/pushing now would enforce an outdated
  # override set (e.g. a just-removed override would stay unlocked). Abort
  # before any shield reload or node push so we never act on stale state.
  error -c cli,vlan "Client Metadata: failed to write MAC override DB — aborting before shield reload to avoid enforcing stale overrides"
  exit 1
fi

# --------------------------------------------- Materialize client name DB ----
# Split ';'-separated "mac=name" pairs into "mac<TAB>name". Names are sanitized
# of tab/newline (they would corrupt the line format) and trimmed; empty names
# drop the entry. Display-only — never pushed to nodes.
mkdir -p "${MERV_CLIENT_NAME_DB%/*}" 2>/dev/null || :
NAME_TMP="${MERV_CLIENT_NAME_DB}.tmp.$$"
: > "$NAME_TMP"
if [ -n "$RAW_NAMES" ]; then
  printf '%s\n' "$RAW_NAMES" | tr ';' '\n' | while IFS= read -r _pair; do
    [ -n "$_pair" ] || continue
    _pm=${_pair%%=*}
    _pn=${_pair#*=}
    [ "$_pm" != "$_pair" ] || continue
    _pm=$(printf '%s' "$_pm" | tr -d ' \t\r')
    _pm=$(mervqt_mac_lower "$_pm")
    mervqt_valid_mac "$_pm" || continue
    _pn=$(printf '%s' "$_pn" | tr -d '\t\r' | sed 's/^ *//; s/ *$//')
    [ -n "$_pn" ] || continue
    printf '%s\t%s\n' "$_pm" "$_pn"
  done | sort -t "$(printf '\t')" -k1,1 -u > "$NAME_TMP"
fi
_name_count=$(awk 'NF' "$NAME_TMP" 2>/dev/null | wc -l | tr -d ' ')
if mv "$NAME_TMP" "$MERV_CLIENT_NAME_DB" 2>/dev/null; then
  chmod 600 "$MERV_CLIENT_NAME_DB" 2>/dev/null || :
  info -c cli,vlan "Client Metadata: client name DB written (${_name_count} entry/entries)"
else
  rm -f "$NAME_TMP" 2>/dev/null || :
  _meta_partial=1
  warn -c cli,vlan "Client Metadata: failed to write client name DB"
fi

# -------------------------------------------------- Re-enforce local shield --
# Reload the local MERV_MAC shield from the best available db so the new
# override set takes effect immediately (overridden MACs lose their DROP rule).
_shield_reload=skip
merv_action_progress_phase "Reloading MAC shield and synchronizing overrides..."
if type ebt_mac_shield_init_and_apply >/dev/null 2>&1; then
  _best=$(merv_mac_best_db 2>/dev/null)
  if [ -n "$_best" ]; then
    ebt_mac_shield_init_and_apply "$_best"
    _shield_reload=ok
    info -c cli,vlan "Client Metadata: local MAC shield reloaded"
  fi
fi

# ----------------------------------------------- Push override DB to nodes ----
# Cluster-wide: push the override DB (and reload each node's shield) so the
# override set is consistent across the mesh. merv_mac_push_db_to_nodes streams
# both the main MAC db and the override db, then reloads the node shield.
_nodes_pushed=0
if [ "${MERV_MAC_NODE_SYNC:-1}" = "1" ]; then
  _nodes=$(merv_mac_node_list 2>/dev/null)
  if [ -n "$_nodes" ]; then
    MERV_MAC_LAST_PUSH_TOTAL=0
    MERV_MAC_LAST_PUSH_OK=0
    MERV_MAC_LAST_PUSH_FAILED=0
    merv_mac_push_db_to_nodes "$_nodes"
    _nodes_pushed=${MERV_MAC_LAST_PUSH_OK:-0}
    [ "${MERV_MAC_LAST_PUSH_FAILED:-0}" -eq 0 ] || _meta_partial=1
    info -c cli,vlan "Client Metadata: override pushed to nodes ${MERV_MAC_LAST_PUSH_OK:-0}/${MERV_MAC_LAST_PUSH_TOTAL:-0}"
  fi
fi

# ------------------------------------------------ Refresh client inventory ----
# Release the metadata writer lock before entering the observation coordinator:
# global ordering is observation lock before operation-specific locks.
if [ "$META_LOCK_ACQUIRED" -eq 1 ]; then
  if merv_lock_release "$META_LOCK" "$META_LOCK_NONCE" 2>/dev/null; then
    META_LOCK_ACQUIRED=0
  else
    error -c cli,vlan "Client Metadata: could not release its owner lock; observation refresh was not started"
    exit 1
  fi
fi

# Rebuild through the one generation coordinator. Foreground execution ensures
# the freshly-published JSON satisfies the UI freshness poll.
_collect=skip
merv_action_progress_phase "Refreshing client inventory..."
if [ -x "$MERV_BASE/functions/post_apply_worker.sh" ]; then
  if MERV_OBS_NO_AUTOSTART=1 sh "$MERV_BASE/functions/post_apply_worker.sh" \
       request collect >/dev/null 2>&1 &&
     sh "$MERV_BASE/functions/post_apply_worker.sh" run >/dev/null 2>&1; then
    _collect=ok
  else
    _collect=failed
    warn -c cli,vlan "Client Metadata: coordinated refresh failed; generation remains pending"
  fi
fi

# Consolidated one-line summary for quick log scanning.
info -c cli,vlan "Client Metadata summary: overrides_written=${_ovr_count:-0} names_written=${_name_count:-0} shield_reload=${_shield_reload:-skip} nodes_pushed=${_nodes_pushed:-0} collect_triggered=${_collect:-skip}"
if [ "$_collect" = "failed" ]; then
  merv_action_progress_fail "Client metadata saved, but client inventory refresh failed"
  exit 2
fi
if [ "${_meta_partial:-0}" -ne 0 ]; then
  merv_action_progress_fail "Client metadata applied with warnings; see the VLAN log for details"
  exit 2
fi
info -c cli,vlan "Client Metadata: save complete"
merv_action_progress_complete "Client metadata saved"
exit 0
