#!/bin/sh
#
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
#             - File: sync_nodes.sh || version="0.72.7"                     #
# ============================================================================ #
# - Purpose:    Synchronize MerVLAN addon files to nodes using SSH keys        #
# ============================================================================ #
#                                                                              #
# ================================================== MerVLAN environment setup #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
    unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_SSH_LOADED LIB_JSON_LOADED LIB_DEBUG_LOADED LIB_OWNER_LOCK_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_SSH_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssh.sh"
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh"
[ -n "${LIB_SETTINGS_RECONCILE_LOADED:-}" ] || . "$MERV_BASE/settings/lib_settings_reconcile.sh" 2>/dev/null || {
    error -c cli,vlan "Unable to load the settings reconciliation library; refusing node synchronization"
    exit 75
}
[ -n "${LIB_OWNER_LOCK_LOADED:-}" ] || . "$MERV_BASE/settings/lib_owner_lock.sh" 2>/dev/null || {
    error -c cli,vlan "Unable to load the owner-lock library; refusing node synchronization"
    exit 1
}
[ -n "${LIB_UPDATE_STATE_LOADED:-}" ] || . "$MERV_BASE/settings/lib_update_state.sh" 2>/dev/null || {
    error -c cli,vlan "Unable to load the Update lifecycle state library; refusing node synchronization"
    exit 75
}
if [ "${MERV_MAINTENANCE_SYNC:-0}" = "1" ]; then
    if ! merv_update_maintenance_sync_context_valid; then
        error -c cli,vlan "Sync refused: maintenance synchronization lacks an authenticated Update owner"
        exit 75
    fi
elif merv_update_mutation_blocked; then
    error -c cli,vlan "Sync refused: Update maintenance is active"
    exit 75
fi
[ -n "${LIB_MERVQT_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mervqt.sh" 2>/dev/null || {
    error -c cli,vlan "Unable to load the DHCP/L2 safety library; refusing node synchronization"
    exit 1
}
[ -n "${LIB_NODE_JOBS_LOADED:-}" ] || . "$MERV_BASE/settings/lib_node_jobs.sh"
[ -n "${LIB_ACTION_ACK_LOADED:-}" ] || . "$MERV_BASE/settings/lib_action_ack.sh" 2>/dev/null || {
    error -c cli,vlan "Unable to load the action acknowledgement library; refusing node synchronization"
    exit 1
}
# Progress publication is optional. Load it before lock acquisition so a
# correlated request that is rejected by the action lock still reaches a
# visible terminal failure state.
merv_action_progress_init() { :; }
merv_action_progress_phase() { :; }
merv_action_progress_update() { :; }
merv_action_progress_complete() { :; }
merv_action_progress_fail() { :; }
if [ -f "$MERV_BASE/settings/lib_action_progress.sh" ]; then
    if ! . "$MERV_BASE/settings/lib_action_progress.sh" 2>/dev/null; then
        warn -c cli,vlan "Action progress publication is unavailable for node synchronization"
    fi
fi
_sync_lock_ack_action=sync_vlanmgr
for _sync_lock_arg in "$@"; do
    [ "$_sync_lock_arg" = settings-only ] || [ "$_sync_lock_arg" = --settings-only ] && {
        _sync_lock_ack_action=syncsettings_vlanmgr
        break
    }
done
SYNC_ACTION_LOCK_ACQUIRED=0
if [ -f "$MERV_BASE/settings/lib_action_lock.sh" ]; then
    . "$MERV_BASE/settings/lib_action_lock.sh" 2>/dev/null || exit 75
    _sync_action_lock_path="${MERV_ACTION_LOCK_PATH:-$LOCKDIR/mervlan_action.lock}"
    merv_action_lock_enter "$_sync_action_lock_path"
    _sync_action_lock_rc=$?
    if [ "$_sync_action_lock_rc" -ne 0 ]; then
        _sync_lock_message="The node synchronization could not start because its action lock could not be acquired."
        if [ "$_sync_action_lock_rc" -eq 3 ]; then
            _sync_lock_message="Another configuration action is already running; node synchronization was not started."
        fi
        merv_action_progress_init "${MERV_PROGRESS_TOKEN:-}" "$_sync_lock_ack_action" \
            "${_sync_lock_ack_action}" "Preparing synchronization..."
        merv_action_progress_fail "$_sync_lock_message"
        if [ -n "${MERV_PROGRESS_TOKEN:-}" ] && type action_ack_lock_failure >/dev/null 2>&1; then
            action_ack_lock_failure "$MERV_PROGRESS_TOKEN" "$_sync_lock_ack_action" \
                "$_sync_action_lock_rc" global >/dev/null 2>&1 || :
        fi
        exit 75
    fi
    _sync_action_lock_mode="${MERV_ACTION_LOCK_MODE:-none}"
    [ "$_sync_action_lock_mode" = self ] && SYNC_ACTION_LOCK_ACQUIRED=1
    _sync_action_lock_nonce="$MERV_ACTION_LOCK_NONCE"; _sync_action_lock_start="$MERV_ACTION_LOCK_START"
    if ! merv_action_lock_export_child_context; then
        merv_action_progress_init "${MERV_PROGRESS_TOKEN:-}" "$_sync_lock_ack_action" \
            "${_sync_lock_ack_action}" "Preparing synchronization..."
        merv_action_progress_fail "The node synchronization owner context was invalid; no work was started."
        action_ack_lock_failure "$MERV_PROGRESS_TOKEN" "$_sync_lock_ack_action" 4 global >/dev/null 2>&1 || :
        merv_action_lock_leave "$_sync_action_lock_path" "$_sync_action_lock_nonce" \
            "$_sync_action_lock_start" "$_sync_action_lock_mode" >/dev/null 2>&1 || :
        exit 75
    fi
fi
# =========================================== End of MerVLAN environment setup #

# Default no-op debug helpers; overridden if lib_debug.sh is loaded
dbg_log() { :; }
dbg_var() { :; }

DRY_RUN_FORCED=0
DEBUG_FORCED=0

SETTINGS_ONLY=0
# A settings-only convergence copies and verifies settings.json but never runs
# the VLAN manager or hardware probe. It is a control-plane action, not a
# network mutation.
SETTINGS_CONTROL_PLANE=0
ORIGINAL_ARGS="$*"

# ───── CLI arg parsing: dryrun + debug + settings-only ─────
while [ "$#" -gt 0 ]; do
    case "$1" in
        dryrun|--dry-run|-n)
            DRY_RUN="yes"
            DRY_RUN_FORCED=1
            shift
            ;;
        debug|--debug|-d)
            DEBUG=1
            DEBUG_FORCED=1
            shift
            ;;
        settings-only|--settings-only)
            SETTINGS_ONLY=1
            shift
            ;;
        *)
            break
            ;;
    esac
done

# A regular settings-only or full Sync can satisfy a pending backend-owned
# Save obligation.  Capture its generation only after argument parsing, then
# acknowledge it only while this action still owns the normal serialization.
SYNC_RECONCILE_ACTIVE=0
SYNC_RECONCILE_VERIFIED=0
SYNC_DEFERRED=0
SYNC_DEFERRED_REASON=""
sync_settings_reconcile_capture() {
    [ "$DRY_RUN" != "yes" ] || return 0
    # This action already owns the normal global action serialization. Repair
    # stale topology metadata or quarantine/rebuild malformed metadata here,
    # never from the periodic observer without that ownership.
    merv_settings_reconcile_normalize_current existing
    _ssrc_normalize_rc=$?
    case "$_ssrc_normalize_rc" in
        0|2) ;;
        *) warn -c vlan "Sync: settings convergence metadata could not be normalized"; return 0 ;;
    esac
    [ -z "${MERV_SETTINGS_RECONCILE_QUARANTINED:-}" ] || \
        warn -c vlan "Sync: malformed settings convergence metadata was quarantined and rebuilt from current settings"
    merv_settings_reconcile_read || return 0
    _ssrc_settings=$(merv_settings_node_sync_digest "$SETTINGS_FILE" 2>/dev/null || printf '')
    _ssrc_nodes=$(merv_node_list_digest 2>/dev/null || printf '')
    [ -n "$_ssrc_settings" ] && [ -n "$_ssrc_nodes" ] || return 0
    [ "$_ssrc_settings" = "$MERV_SETTINGS_RECONCILE_SETTINGS_DIGEST" ] || return 0
    SYNC_RECONCILE_GENERATION="$MERV_SETTINGS_RECONCILE_GENERATION"
    SYNC_RECONCILE_SETTINGS_DIGEST="$MERV_SETTINGS_RECONCILE_SETTINGS_DIGEST"
    SYNC_RECONCILE_NODE_LIST_DIGEST="$MERV_SETTINGS_RECONCILE_NODE_LIST_DIGEST"
    # The persisted list digest records the Save-time topology.  Synchronizing
    # must instead exact-verify the currently configured set: a removed node
    # cannot keep an otherwise-current generation pending forever.
    SYNC_RECONCILE_CURRENT_NODE_LIST_DIGEST="$_ssrc_nodes"
    SYNC_RECONCILE_ATTEMPT="$MERV_SETTINGS_RECONCILE_ATTEMPT"
    # This action now owns normal configuration serialization. Reflect that
    # fact in the durable authority before remote work starts, so a modal can
    # distinguish an outstanding generation from one actively synchronizing.
    # A conditional update refuses any generation superseded by a newer Save.
    if ! merv_settings_reconcile_update "$SYNC_RECONCILE_GENERATION" \
        "$SYNC_RECONCILE_SETTINGS_DIGEST" "$SYNC_RECONCILE_NODE_LIST_DIGEST" \
        running "$SYNC_RECONCILE_ATTEMPT" 0; then
        warn -c vlan "Sync: settings convergence generation was superseded before it could be marked running"
        return 0
    fi
    SYNC_RECONCILE_ACTIVE=1
    return 0
}

sync_settings_reconcile_finish() {
    [ "${SYNC_RECONCILE_ACTIVE:-0}" -eq 1 ] || return 0
    merv_settings_reconcile_read || return 0
    [ "$MERV_SETTINGS_RECONCILE_GENERATION" = "$SYNC_RECONCILE_GENERATION" ] || return 0
    _ssrf_settings=$(merv_settings_node_sync_digest "$SETTINGS_FILE" 2>/dev/null || printf '')
    _ssrf_nodes=$(merv_node_list_digest 2>/dev/null || printf '')
    [ "$_ssrf_settings" = "$SYNC_RECONCILE_SETTINGS_DIGEST" ] || return 0
    [ "$_ssrf_nodes" = "$SYNC_RECONCILE_CURRENT_NODE_LIST_DIGEST" ] || return 0
    if [ "${SYNC_RECONCILE_VERIFIED:-0}" -eq 1 ]; then
        merv_settings_reconcile_clear "$SYNC_RECONCILE_GENERATION" || \
            warn -c vlan "Sync: verified settings convergence could not clear its matching marker"
        return 0
    fi
    _ssrf_attempt=$((SYNC_RECONCILE_ATTEMPT + 1))
    [ "$_ssrf_attempt" -le 100000 ] 2>/dev/null || _ssrf_attempt=100000
    _ssrf_delay=$((_ssrf_attempt * 30))
    [ "$_ssrf_delay" -le 300 ] 2>/dev/null || _ssrf_delay=300
    _ssrf_now=$(date +%s 2>/dev/null || printf '0')
    case "$_ssrf_now" in ''|*[!0-9]*) _ssrf_now=0 ;; esac
    _ssrf_status=retry
    _ssrf_next=$((_ssrf_now + _ssrf_delay))
    _ssrf_ssh_reason="${MERV_SSH_TRUST_LAST_REASON:-${MERV_SSH_LAST_REASON:-}}"
    case "$_ssrf_ssh_reason" in
        ssh-trust-required|trust-*|key-or-endpoint-changed|endpoint-changed|host-key-*|identity-*)
            _ssrf_status=blocked; _ssrf_next=0
            ;;
    esac
    merv_settings_reconcile_update "$SYNC_RECONCILE_GENERATION" \
        "$SYNC_RECONCILE_SETTINGS_DIGEST" "$SYNC_RECONCILE_NODE_LIST_DIGEST" \
        "$_ssrf_status" "$_ssrf_attempt" "$_ssrf_next" || \
        warn -c vlan "Sync: settings convergence marker was retained without a retry update"
}

if [ -z "${DRY_RUN:-}" ]; then
    DRY_RUN="$(json_get_flag "DRY_RUN" "yes" "$SETTINGS_FILE" 2>/dev/null)"
fi
[ -z "$DRY_RUN" ] && DRY_RUN="yes"
# Keep an explicit CLI --dry-run as a simulation. The ordinary settings-only
# path must still converge a newly saved DRY_RUN=yes value; otherwise a node
# that was previously live would never receive its safety setting.
if [ "$SETTINGS_ONLY" -eq 1 ] && [ "$DRY_RUN_FORCED" -eq 0 ] && [ "$DRY_RUN" = "yes" ]; then
    SETTINGS_CONTROL_PLANE=1
    DRY_RUN=no
fi
sync_settings_reconcile_capture

DEBUG_JSON_FLAG="$(json_get_flag "SYNC_DEBUG" "0" "$SETTINGS_FILE" 2>/dev/null)"
case "${DEBUG_JSON_FLAG}" in
    1|yes|on|true) DEBUG_JSON=1 ;;
    *)             DEBUG_JSON=0 ;;
esac

if [ "$DEBUG_FORCED" -eq 1 ] || [ "${DEBUG_JSON:-0}" -eq 1 ]; then
    DEBUG=1
else
    DEBUG=0
fi

if [ "$DEBUG" -eq 1 ]; then
    [ -n "${LIB_DEBUG_LOADED:-}" ] || . "$MERV_BASE/settings/lib_debug.sh"
fi

DBG_CHANNEL="vlan,cli"
: "${DBG_PREFIX:=[DEBUG]}"

dbg_log "sync_nodes.sh invoked with args: ${ORIGINAL_ARGS}"
dbg_var DRY_RUN DRY_RUN_FORCED SETTINGS_CONTROL_PLANE DEBUG DEBUG_FORCED DEBUG_JSON

SSH_NODE_USER=$(get_node_ssh_user)
SSH_NODE_PORT=$(get_node_ssh_port)
REMOTE_MERV_BASE="$MERV_BASE"
# The active addon remains the source of node-owned data while a full sync
# uses a separate backup staging directory.
REMOTE_ACTIVE_MERV_BASE="/jffs/addons/mervlan"
dbg_var SSH_NODE_USER SSH_NODE_PORT

SYNC_PROGRESS_TOTAL=0
SYNC_PROGRESS_TERMINAL=0
SYNC_PROGRESS_HEARTBEAT_LAST=0
SYNC_PROGRESS_HEARTBEAT_SEC="${MERV_PROGRESS_HEARTBEAT_SEC:-5}"
case "$SYNC_PROGRESS_HEARTBEAT_SEC" in
    ''|*[!0-9]*|0) SYNC_PROGRESS_HEARTBEAT_SEC=5 ;;
esac
SYNC_PROGRESS_STARTED_EPOCH="$(date +%s 2>/dev/null || printf 0)"
case "$SYNC_PROGRESS_STARTED_EPOCH" in
    ''|*[!0-9]*) SYNC_PROGRESS_STARTED_EPOCH=0 ;;
esac
if [ "$SETTINGS_ONLY" -eq 1 ]; then
    SYNC_PROGRESS_ACTION="syncsettings_vlanmgr"
    SYNC_PROGRESS_LABEL="Syncing settings to node(s)..."
    SYNC_PROGRESS_PREP="Preparing settings synchronization..."
else
    SYNC_PROGRESS_ACTION="sync_vlanmgr"
    SYNC_PROGRESS_LABEL="Sync Nodes"
    SYNC_PROGRESS_PREP="Preparing synchronization..."
fi
if [ "${SETTINGS_CONTROL_PLANE:-0}" -eq 1 ]; then
    info -c cli,vlan "Settings-only control-plane mode: synchronizing settings despite configured Dry Run (no VLAN apply or hardware probe)"
fi
merv_action_progress_init "${MERV_PROGRESS_TOKEN:-}" "$SYNC_PROGRESS_ACTION" \
    "$SYNC_PROGRESS_LABEL" "$SYNC_PROGRESS_PREP"

sync_pool_state_unresolved() {
    if type mnj_pool_state_unresolved >/dev/null 2>&1; then
        mnj_pool_state_unresolved
        return $?
    fi
    # Without the canonical helper, the caller cannot prove that all pool
    # metadata is clean. Retain ownership for a later recovery pass.
    return 0
}

sync_reconcile_signal_children() {
    # lib_node_jobs owns pending-wrapper and published-slot identities.  Use
    # its single abort path so an interruption cannot strand either side of a
    # launch or duplicate the five-slot reconciliation logic here.
    if sync_pool_state_unresolved && type mnj_pool_abort_active >/dev/null 2>&1; then
        mnj_pool_abort_active failed parent-signal
    fi
}

SYNC_SIGNAL_HANDLING=0
sync_handle_signal() {
    _sync_signal_status="$1"
    [ "${SYNC_SIGNAL_HANDLING:-0}" -eq 0 ] || exit "$_sync_signal_status"
    SYNC_SIGNAL_HANDLING=1
    trap - INT TERM
    error -c cli,vlan "Sync interrupted (rc=$_sync_signal_status); reconciling tracked node workers"
    sync_reconcile_signal_children
    if type merv_action_progress_fail >/dev/null 2>&1; then
        merv_action_progress_fail "Synchronization interrupted; tracked workers were stopped"
    fi
    exit "$_sync_signal_status"
}

# Remove any per-node sync metadata breadcrumbs left by copy_file_to_node.
# Fires on every exit path (normal, error, signal) so no stale files survive
# across runs even if verification was skipped or the script was interrupted.
_cleanup_sync_tmp() {
    _sync_cleanup_rc=$?
    _sync_cleanup_failed=0
    _sync_pool_abort_failed=0
    # Abort any in-flight node pool before releasing the sync/action locks.
    # The library retains identity metadata when reconciliation is unsafe, so
    # preserving ownership here prevents a successor from racing live work.
    if sync_pool_state_unresolved && type mnj_pool_abort_active >/dev/null 2>&1; then
        if ! mnj_pool_abort_active failed parent-exit; then
            _sync_pool_abort_failed=1
        fi
    fi
    # The canonical pool state is authoritative. Do not turn retained pending
    # or slot metadata into a clean owner/action unlock through a caller-local
    # active flag.
    if sync_pool_state_unresolved; then
        _sync_pool_abort_failed=1
        _sync_cleanup_failed=1
        error -c cli,vlan "Sync cleanup retained ownership because node workers could not be reconciled"
    fi
    if [ -n "${_sync_endpoint_map:-}" ] && [ -e "$_sync_endpoint_map" ]; then
        if ! rm -f "$_sync_endpoint_map" 2>/dev/null; then
            _sync_cleanup_failed=1
            warn -c cli,vlan "Sync cleanup could not remove its verified endpoint map"
        fi
    fi
    unset MERV_SSH_PREFLIGHT_ENDPOINT_MAP MERV_SSH_SYNC_ENDPOINT_MAP
    for _sync_expected_file in "$TMPDIR"/merv_sync_expected_*; do
        [ -e "$_sync_expected_file" ] || continue
        if ! rm -f "$_sync_expected_file" 2>/dev/null; then
            _sync_cleanup_failed=1
            warn -c cli,vlan "Sync cleanup could not remove its expected-settings breadcrumbs"
        fi
    done
    # The action lock is still held here.  Do not release it before the
    # generation-conditional terminal update/clear has completed.
    sync_settings_reconcile_finish || :
    if [ "$_sync_pool_abort_failed" -eq 0 ] && [ "${SYNC_LOCK_ACQUIRED:-0}" -eq 1 ]; then
        if ! merv_owner_lock_release "$SYNC_LOCK" "${SYNC_LOCK_NONCE:-}" 2>/dev/null; then
            _sync_cleanup_failed=1
            error -c cli,vlan "Sync cleanup could not release its owner lock"
        else
            SYNC_LOCK_ACQUIRED=0
        fi
    fi
    if [ "$_sync_pool_abort_failed" -eq 0 ] && [ "${SYNC_ACTION_LOCK_ACQUIRED:-0}" -eq 1 ]; then
        if merv_action_lock_leave "${_sync_action_lock_path:-${MERV_ACTION_LOCK_PATH:-$LOCKDIR/mervlan_action.lock}}" "$_sync_action_lock_nonce" "$_sync_action_lock_start" "${_sync_action_lock_mode:-self}" >/dev/null 2>&1; then
            SYNC_ACTION_LOCK_ACQUIRED=0
        else
            _sync_cleanup_failed=1
            error -c cli,vlan "Sync cleanup could not release the global action lock"
        fi
    fi
    [ "$_sync_cleanup_failed" -eq 0 ] || _sync_cleanup_rc=1
    if [ "${MERV_ACTION_PROGRESS_ENABLED:-0}" -eq 1 ] &&
       [ "${MERV_ACTION_PROGRESS_FINAL:-0}" -eq 0 ]; then
        if [ "${SYNC_DEFERRED:-0}" -eq 1 ]; then
            merv_action_progress_complete "Synchronization deferred; current settings remain pending"
        elif [ "$_sync_cleanup_rc" -eq 0 ]; then
            merv_action_progress_complete "Synchronization complete"
        else
            merv_action_progress_fail "Synchronization stopped before completion"
        fi
    fi
    return "$_sync_cleanup_rc"
}
trap '_cleanup_sync_tmp' EXIT
trap 'sync_handle_signal 130' INT
trap 'sync_handle_signal 143' TERM

# ========================================================================== #
# CONCURRENCY GUARD — One sync at a time; never overlap a manager apply       #
# ========================================================================== #
# A sync pushes settings.json (and every runtime script) to nodes. If the
# manager is mid-apply locally, its in-flight settings could be captured
# half-written, and two concurrent syncs could race the same remote files.
# Guard with the shared lock primitive:
#   1. Observe the manager lock (stale-safe) and skip if an apply is in flight.
#   2. Take a dedicated, NON-BLOCKING sync lock so a second sync skips rather
#      than queueing. Skip-on-contention can only make a redundant sync bail —
#      it can never deadlock, and a crashed sync is reclaimed after the stale
#      window. DRY_RUN takes no lock (read-only, safe to overlap).
SYNC_LOCK="$LOCKDIR/sync_nodes.lock"
SYNC_LOCK_ACQUIRED=0
SYNC_LOCK_NONCE=""
if [ "$DRY_RUN" != "yes" ] && type merv_owner_lock_acquire >/dev/null 2>&1; then
    mkdir -p "$LOCKDIR" 2>/dev/null || {
        error -c cli,vlan "Sync: lock directory could not be created; refusing synchronization"
        exit 1
    }
    if ! merv_update_maintenance_sync_context_valid && type merv_owner_lock_state >/dev/null 2>&1; then
        case "$(merv_owner_lock_state "$LOCKDIR/mervlan_maintenance.lock")" in
            live|unknown)
                warn -c cli,vlan "Sync: update, backup, or restore maintenance is active — skipping this run"
                exit 1
                ;;
        esac
    fi
    if type merv_owner_lock_state >/dev/null 2>&1; then
        case "$(merv_owner_lock_state "$LOCKDIR/mervlan_manager.lock")" in
            live|unknown)
                warn -c cli,vlan "Sync: mervlan_manager is applying config — skipping this run"
                SYNC_DEFERRED=1
                SYNC_DEFERRED_REASON=manager-active
                exit 0
                ;;
        esac
    fi
    if merv_owner_lock_acquire "$SYNC_LOCK" "${MERV_SYNC_LOCK_STALE_SEC:-600}" 0 "sync_nodes"; then
        SYNC_LOCK_ACQUIRED=1
        SYNC_LOCK_NONCE="$MERV_LOCK_NONCE"
    else
        warn -c cli,vlan "Sync: another sync_nodes run is in progress — skipping"
        SYNC_RECONCILE_VERIFIED=0
        SYNC_DEFERRED=1
        SYNC_DEFERRED_REASON=sync-active
        exit 0
    fi
fi

# ========================================================================== #
# FILE SYNC SETUP — Source/destination lists and synchronization parameters  #
# ========================================================================== #

# FILES_TO_COPY — Files to replicate to each node (preserves folder structure)
# Includes settings, shell helpers, and service templates required for MerVLAN
FILES_TO_COPY="
settings/settings.json 
settings/var_settings.sh 
settings/log_settings.sh 
settings/lib_json.sh
settings/lib_identity.sh
settings/lib_owner_lock.sh
settings/lib_ssh_trust.sh
settings/lib_action_lock.sh
settings/lib_debug.sh
settings/lib_ssh.sh
settings/lib_ssid_filter.sh
settings/lib_stp.sh
settings/lib_mervqt.sh
settings/lib_node_jobs.sh
settings/lib_action_ack.sh
settings/lib_radio.sh
settings/lib_update_state.sh
settings/lib_maintenance_recovery.sh
settings/lib_node_reconcile.sh
settings/lib_settings_reconcile.sh
settings/lib_progress.sh
settings/lib_action_progress.sh
settings/mac_shield_snapshot.sh
settings/lib_br0_guard.sh
functions/mervlan_boot.sh
functions/mervlan_boot_wrap.sh
functions/mervlan_manager.sh 
functions/mervlan_node_runner.sh
functions/post_apply_worker.sh
functions/collect_local_clients.sh 
functions/heal_event.sh  
functions/service-event-handler.sh
functions/hw_probe.sh
functions/mervlan_trunk.sh
functions/mervlan_wan.sh
functions/mac_refresh.sh
functions/ssh_hostkey_probe.sh
functions/settings_reconcile.sh
templates/mervlan_templates.sh
"

# Developer tools are present on development/test branches only. Keep this
# manifest separate from the production runtime manifest, but feed it through
# the same copy, staging, verification, and permission pipeline when present.
# This makes Sync Nodes provision the router-capable tools everywhere on a
# development tree while keeping main-branch-style trees fully compatible.
DEV_TOOLS_FILES_TO_COPY=""
DEV_TOOLS_FILES_TO_COPY_CHMOD=""
if [ -f "$MERV_BASE/dev-tools/tests/router/mervlan_selftest.sh" ]; then
    DEV_TOOLS_FILES_TO_COPY="$DEV_TOOLS_FILES_TO_COPY dev-tools/tests/router/mervlan_selftest.sh"
    DEV_TOOLS_FILES_TO_COPY_CHMOD="$DEV_TOOLS_FILES_TO_COPY_CHMOD dev-tools/tests/router/mervlan_selftest.sh"
fi
if [ -f "$MERV_BASE/dev-tools/safety/mervlan_live_test_guard.sh" ]; then
    DEV_TOOLS_FILES_TO_COPY="$DEV_TOOLS_FILES_TO_COPY dev-tools/safety/mervlan_live_test_guard.sh"
    DEV_TOOLS_FILES_TO_COPY_CHMOD="$DEV_TOOLS_FILES_TO_COPY_CHMOD dev-tools/safety/mervlan_live_test_guard.sh"
fi
FILES_TO_COPY="$FILES_TO_COPY $DEV_TOOLS_FILES_TO_COPY"

# FILES_TO_COPY_CHMOD — Files requiring executable permissions on nodes (755)
FILES_TO_COPY_CHMOD="
functions/mervlan_boot.sh
functions/mervlan_boot_wrap.sh
functions/mervlan_manager.sh
functions/mervlan_node_runner.sh
functions/post_apply_worker.sh
functions/collect_local_clients.sh
functions/heal_event.sh
functions/service-event-handler.sh
functions/hw_probe.sh
functions/mervlan_trunk.sh
functions/mervlan_wan.sh
functions/mac_refresh.sh
functions/ssh_hostkey_probe.sh
functions/settings_reconcile.sh
"
FILES_TO_COPY_CHMOD="$FILES_TO_COPY_CHMOD $DEV_TOOLS_FILES_TO_COPY_CHMOD"
# FILES_TO_COPY_CHMOD_644 — Config scripts that should remain non-executable
FILES_TO_COPY_CHMOD_644="
settings/var_settings.sh 
settings/log_settings.sh 
settings/lib_json.sh  
settings/lib_identity.sh
settings/lib_owner_lock.sh
settings/lib_ssh_trust.sh
settings/lib_action_lock.sh
settings/lib_debug.sh 
settings/lib_ssh.sh
settings/lib_ssid_filter.sh 
settings/lib_stp.sh
settings/lib_mervqt.sh
settings/lib_node_jobs.sh
settings/lib_action_ack.sh
settings/lib_radio.sh
settings/lib_update_state.sh
settings/lib_maintenance_recovery.sh
settings/lib_node_reconcile.sh
settings/lib_settings_reconcile.sh
settings/lib_progress.sh
settings/lib_action_progress.sh
settings/mac_shield_snapshot.sh
settings/lib_br0_guard.sh
templates/mervlan_templates.sh
"

if [ "$SETTINGS_ONLY" -eq 1 ]; then
    FILES_TO_COPY="settings/settings.json"
    FILES_TO_COPY_CHMOD=""
    FILES_TO_COPY_CHMOD_644="settings/settings.json"
    info -c cli,vlan "Settings-only mode: synchronizing only settings.json to node(s)"
fi

dbg_log "File synchronization manifest loaded"
dbg_var DEV_TOOLS_FILES_TO_COPY DEV_TOOLS_FILES_TO_COPY_CHMOD
dbg_var FILES_TO_COPY FILES_TO_COPY_CHMOD FILES_TO_COPY_CHMOD_644

# ========================================================================== #
# SYNCHRONIZATION PARAMETERS — Debug toggles and SSH retry behaviour         #
# ========================================================================== #

# SYNC_DEBUG_PRE/POST toggle verbose remote listings (before/after copy).
# Both default off: the post-copy `ls -laR` was an extra SSH round-trip per node
# that nobody reads outside active debugging. Set to 1 to re-enable.
SYNC_DEBUG_PRE="${SYNC_DEBUG_PRE:-0}"
SYNC_DEBUG_POST="${SYNC_DEBUG_POST:-0}"
# Ping/SSH retry windows allow nodes time to boot and expose services
PING_MAX_ATTEMPTS="${PING_MAX_ATTEMPTS:-60}"
PING_RETRY_INTERVAL="${PING_RETRY_INTERVAL:-5}"
SSH_MAX_ATTEMPTS="${SSH_MAX_ATTEMPTS:-60}"
SSH_RETRY_INTERVAL="${SSH_RETRY_INTERVAL:-5}"
# Extra settle period after ping success so daemons can come online
PING_STABILIZE_DELAY="${PING_STABILIZE_DELAY:-10}"
dbg_var SYNC_DEBUG_PRE SYNC_DEBUG_POST PING_MAX_ATTEMPTS PING_RETRY_INTERVAL SSH_MAX_ATTEMPTS SSH_RETRY_INTERVAL PING_STABILIZE_DELAY

run_cmd() {
    if [ "$DRY_RUN" = "yes" ]; then
        info -c vlan,cli "[DRY-RUN] $*"
        return 0
    fi
    "$@" 2>/dev/null
}

sync_job_tmp_path() {
    _sjt_name="$1"
    case "${MERV_NODE_JOB_DIR:-}" in
        "$TMPDIR/node_jobs"/*) printf '%s/%s\n' "$MERV_NODE_JOB_DIR" "$_sjt_name" ;;
        *) printf '%s/%s\n' "$TMPDIR" "$_sjt_name" ;;
    esac
}

sync_expected_path() {
    sync_job_tmp_path "merv_sync_expected_$1"
}

# ========================================================================== #
# PRE-FLIGHT VALIDATION — Ensure local configuration and SSH keys are ready  #
# ========================================================================== #

info -c cli,vlan "=== VLAN Manager File Synchronization ==="
info -c cli,vlan ""

merv_action_progress_phase validate "Validating settings and SSH prerequisites..."

if [ "$DRY_RUN" = "yes" ]; then
    info -c cli,vlan "[DRY-RUN] Simulation mode active; no remote changes will be applied"
fi
if [ "${DEBUG:-0}" -eq 1 ]; then
    info -c cli,vlan "[DEBUG] Additional debug logging enabled"
fi

# Check if settings file exists (required for node discovery and file paths)
if [ ! -f "$SETTINGS_FILE" ]; then
    error -c cli,vlan "ERROR: Settings file not found at $SETTINGS_FILE"
    exit 1
fi

# Validate that SSH keys are effectively installed via flag or file presence
if ! ssh_keys_effectively_installed; then
    error -c cli,vlan "ERROR: SSH keys are not fully configured"
    warn -c cli,vlan "Either SSH_KEYS_INSTALLED is 0/missing and no key files exist,"
    warn -c cli,vlan "or the SSH keys have not been generated/installed yet."
    warn -c cli,vlan "Use 'SSH Key Install' in the UI to set them up."
    exit 1
fi

if [ -z "${SSH_KEY:-}" ] || [ ! -f "$SSH_KEY" ] || \
   [ -z "${SSH_PUBKEY:-}" ] || [ ! -f "$SSH_PUBKEY" ]; then
    error -c cli,vlan "ERROR: SSH key files not found (SSH_KEY/SSH_PUBKEY missing on disk)"
    warn -c cli,vlan "Run the SSH key generator / installer again."
    exit 1
fi

# Confirm server-side authorized_keys includes generated public key
# Without this, Dropbear rejects key-based logins during sync
PUBKEY_CONTENT=$(cat "$SSH_PUBKEY" 2>/dev/null || printf '')
if [ -z "$PUBKEY_CONTENT" ]; then
    error -c cli,vlan "ERROR: SSH public key file is empty at $SSH_PUBKEY"
    exit 1
fi
if [ ! -f /root/.ssh/authorized_keys ] || ! grep -qF "$PUBKEY_CONTENT" /root/.ssh/authorized_keys; then
    error -c cli,vlan "ERROR: SSH public key not found in /root/.ssh/authorized_keys"
    warn -c cli,vlan "Please install the SSH keys using the 'SSH Key Install' feature"
    info -c cli,vlan "If already done, try rebooting both the main router and nodes"
    exit 1
fi

info -c cli,vlan "✓ SSH key verification passed"

# ========================================================================== #
# NODE DISCOVERY — Extract and validate node IP addresses from settings      #
# ========================================================================== #

# get_node_ips - Pull NODE1..NODE10 entries, filter placeholders/invalid IPs
get_node_ips() {
    merv_node_list
}

merv_action_progress_phase discover "Discovering configured nodes..."
NODE_IPS=$(get_node_ips)
dbg_log "Discovered node IPs"
dbg_var NODE_IPS

if [ -z "$NODE_IPS" ]; then
    warn -c cli,vlan "No nodes configured in settings.json"
    # Exact verification of the currently empty required set is vacuous but
    # intentional.  The terminal handler still rechecks digest/generation.
    SYNC_RECONCILE_VERIFIED=1
    merv_action_progress_complete "No configured nodes; nothing to synchronize"
    exit 0
fi

# Probe and validate the complete configured set before the first directory,
# stream, or remote settings mutation.  A single untrusted/unknown node aborts
# the whole synchronization; no partial node update is allowed.
_sync_trust_file="$TMPDIR/sync_trust.$$"
_sync_endpoint_map="$TMPDIR/sync_endpoint_map.$$"
rm -f "$_sync_endpoint_map" 2>/dev/null || exit 75
while IFS=' ' read -r _sync_slot _sync_ip _sync_extra || [ -n "$_sync_slot" ]; do
    [ -z "$_sync_extra" ] || { rm -f "$_sync_trust_file"; exit 1; }
    _sync_mac=$(json_get_flag "AUTO_NODE${_sync_slot}_MAC" "" "$SETTINGS_FILE" 2>/dev/null)
    printf '%s %s %s\n' "$_sync_slot" "$_sync_ip" "$_sync_mac" >> "$_sync_trust_file" || { rm -f "$_sync_trust_file"; exit 1; }
done <<EOF
$NODE_IPS
EOF
if [ "$DRY_RUN" != yes ]; then
    # Preflight writes the map through a separate variable so the normal
    # endpoint resolver cannot consume a partially populated map mid-loop.
    MERV_SSH_PREFLIGHT_ENDPOINT_MAP="$_sync_endpoint_map"
    unset MERV_SSH_SYNC_ENDPOINT_MAP
    export MERV_SSH_PREFLIGHT_ENDPOINT_MAP
    merv_ssh_preflight_node_set "$_sync_trust_file" "$SETTINGS_FILE"
    _sync_trust_rc=$?
    if [ "$_sync_trust_rc" -ne 0 ]; then
        warn -c cli,vlan "Sync refused before mutation: SSH host-key trust/capability preflight failed (${MERV_SSH_TRUST_LAST_REASON:-unknown})"
        _sync_trust_worker_rc=1
        if [ -f "$MERV_BASE/functions/ssh_trust_action.sh" ] && [ -n "${MERV_PROGRESS_TOKEN:-}" ]; then
            MERV_SSH_TRUST_ORIGINAL_ACTION="$SYNC_PROGRESS_ACTION" \
            MERV_SSH_TRUST_ACK_ACTION="$SYNC_PROGRESS_ACTION" \
            MERV_ACTION_LOCK_PARENT_HELD=1 \
            sh "$MERV_BASE/functions/ssh_trust_action.sh" probe "$MERV_PROGRESS_TOKEN" >/dev/null 2>&1
            _sync_trust_worker_rc=$?
        fi
        if [ "$_sync_trust_worker_rc" -ne 0 ] && type action_ack_ssh_trust_required >/dev/null 2>&1 && [ -n "${MERV_PROGRESS_TOKEN:-}" ]; then
            if ! action_ack_ssh_trust_required "$MERV_PROGRESS_TOKEN" "$SYNC_PROGRESS_ACTION" '{"reason":"ssh-trust-required"}' "SSH host-key verification is required before synchronization." '[]' >/dev/null 2>&1; then
                error -c cli,vlan "Sync: SSH trust-required acknowledgement failed"
                _sync_trust_worker_rc=75
            fi
        fi
        rm -f "$_sync_trust_file" 2>/dev/null || {
            error -c cli,vlan "Sync: trust preflight temporary cleanup failed"
            exit 75
        }
        exit "$_sync_trust_rc"
    fi
    [ -s "$_sync_endpoint_map" ] || {
        error -c cli,vlan "Sync: SSH preflight did not publish a verified endpoint map"
        exit 75
    }
    # Promote only the completed preflight map. Every resolver call made by
    # Sync now pins one verified endpoint for the node's canonical identity.
    unset MERV_SSH_PREFLIGHT_ENDPOINT_MAP
    MERV_SSH_SYNC_ENDPOINT_MAP="$_sync_endpoint_map"
    export MERV_SSH_SYNC_ENDPOINT_MAP
    while IFS=' ' read -r _sync_slot _sync_ip _sync_extra || [ -n "$_sync_slot" ]; do
        [ -z "$_sync_extra" ] || exit 75
        _sync_selected=$(merv_node_endpoint_candidates "$_sync_slot" "$SETTINGS_FILE" 2>/dev/null | sed -n '1p') || {
            error -c cli,vlan "Sync: verified endpoint map failed current candidate validation for NODE${_sync_slot}"
            exit 75
        }
        [ -n "$_sync_selected" ] || exit 75
    done <<EOF
$NODE_IPS
EOF
    _sync_map_rows=$(wc -l < "$_sync_endpoint_map" 2>/dev/null | tr -d ' ')
    _sync_node_rows=$(printf '%s\n' "$NODE_IPS" | wc -l 2>/dev/null | tr -d ' ')
    [ "$_sync_map_rows" = "$_sync_node_rows" ] || {
        error -c cli,vlan "Sync: verified endpoint map does not cover exactly the configured node set"
        exit 75
    }
else
    unset MERV_SSH_PREFLIGHT_ENDPOINT_MAP MERV_SSH_SYNC_ENDPOINT_MAP
fi
rm -f "$_sync_trust_file" 2>/dev/null || {
    error -c cli,vlan "Sync: trust preflight temporary cleanup failed"
    exit 75
}

info -c cli,vlan "Found nodes: $(echo "$NODE_IPS" | awk '{print $2}' | tr '\n' ' ')"
echo ""

# ========================================================================== #
# SSH & JFFS HELPERS — Connectivity tests and persistent storage checks     #
# ========================================================================== #

# test_ssh_connection — Probe Dropbear SSH connectivity using key auth only
test_ssh_connection() {
    node_ip="$1"
    node_id="${2:-?}"
    merv_ssh_test "$node_id" "$node_ip"
}

# check_remote_jffs_status — Inspect nvram flags controlling persistent storage
check_remote_jffs_status() {
    node_ip="$1"
    node_id="${2:-?}"

    output=$(merv_ssh_exec "$node_id" "$node_ip" "nvram get jffs2_on 2>/dev/null; nvram get jffs2_scripts 2>/dev/null")
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo ""
        return 2
    fi

    jffs_on=$(echo "$output" | sed -n '1p' | tr -d '\r')
    jffs_scripts=$(echo "$output" | sed -n '2p' | tr -d '\r')

    [ -z "$jffs_on" ] && jffs_on="0"
    [ -z "$jffs_scripts" ] && jffs_scripts="0"

    printf '%s %s\n' "$jffs_on" "$jffs_scripts"

    if [ "$jffs_on" = "1" ] && [ "$jffs_scripts" = "1" ]; then
        return 0
    else
        return 1
    fi
}

# ========================================================================== #
# JFFS REMEDIATION — Enable persistent storage and wait for reboot cycle     #
# ========================================================================== #

# enable_jffs_and_reboot — Toggle nvram flags, commit, and trigger reboot
enable_jffs_and_reboot() {
    node_ip="$1"
    node_id="${2:-?}"
    remote_cmd="nvram set jffs2_on=1; nvram set jffs2_scripts=1; nvram commit; (sleep 2; reboot) &"

    info -c cli,vlan "Enabling JFFS and scripts on NODE${node_id} ($node_ip) and triggering reboot"
    dbg_log "enable_jffs_and_reboot issuing remote command"
    dbg_var node_ip remote_cmd

    if [ "$DRY_RUN" = "yes" ]; then
        info -c cli,vlan "[DRY-RUN] Would enable JFFS on $node_ip"
        return 0
    fi

    # Use wrapper with short timeout since reboot will kill connection
    MERV_SSH_TIMEOUT=5 merv_ssh_exec "$node_id" "$node_ip" "$remote_cmd" >/dev/null 2>&1
    rc=$?
    # rc=5 (ssh-failed) is expected since connection drops during reboot
    if [ $rc -eq 0 ] || [ $rc -eq 5 ]; then
        info -c cli,vlan "✓ JFFS enable commands sent to NODE${node_id} ($node_ip)"
        return 0
    else
        merv_ssh_skip_log "$node_id" "$node_ip" "JFFS enable"
        return 1
    fi
}

# wait_for_node_ping — Poll reachability until ICMP responds or we give up
wait_for_node_ping() {
    local node_ip="$1"
    local attempt=0

    info -c cli,vlan "Waiting for $node_ip to respond to ping ($PING_MAX_ATTEMPTS attempts, ${PING_RETRY_INTERVAL}s interval)"

    while [ $attempt -lt "$PING_MAX_ATTEMPTS" ]; do
        if ping -c 1 -W 2 "$node_ip" >/dev/null 2>&1; then
            info -c cli,vlan "✓ Ping succeeded for $node_ip"
            if [ "$PING_STABILIZE_DELAY" -gt 0 ] 2>/dev/null; then
                info -c cli,vlan "Waiting an additional ${PING_STABILIZE_DELAY}s for services to settle on $node_ip"
                sleep "$PING_STABILIZE_DELAY"
            fi
            return 0
        fi
        attempt=$((attempt + 1))
        sleep "$PING_RETRY_INTERVAL"
    done

    error -c cli,vlan "✗ Ping did not succeed for $node_ip after $PING_MAX_ATTEMPTS attempts"
    return 1
}

# wait_for_node_ssh_jffs — Ensure SSH responds and /jffs mount is ready
wait_for_node_ssh_jffs() {
    node_ip="$1"
    node_id="${2:-?}"
    attempt=0

    info -c cli,vlan "Waiting for SSH and /jffs on NODE${node_id} ($node_ip) ($SSH_MAX_ATTEMPTS attempts, ${SSH_RETRY_INTERVAL}s interval)"

    while [ $attempt -lt "$SSH_MAX_ATTEMPTS" ]; do
        result=$(merv_ssh_exec "$node_id" "$node_ip" "test -d /jffs && ls /jffs >/dev/null 2>&1 && echo ready" 2>/dev/null)
        if echo "$result" | grep -q "ready"; then
            info -c cli,vlan "✓ SSH and /jffs ready on NODE${node_id} ($node_ip)"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep "$SSH_RETRY_INTERVAL"
    done

    error -c cli,vlan "✗ SSH or /jffs not ready on NODE${node_id} ($node_ip) after $SSH_MAX_ATTEMPTS attempts"
    return 1
}

# ensure_jffs_ready — Verify or remediate JFFS status before file sync
ensure_jffs_ready() {
    node_ip="$1"
    node_id="${2:-?}"

    dbg_log "Checking JFFS readiness"
    dbg_var node_ip node_id

    if jffs_status=$(check_remote_jffs_status "$node_ip" "$node_id"); then
        info -c cli,vlan "✓ JFFS already enabled on NODE${node_id} ($node_ip)"
        return 0
    else
        status=$?
        jffs_on=$(echo "$jffs_status" | awk '{print $1}')
        jffs_scripts=$(echo "$jffs_status" | awk '{print $2}')
        [ -z "$jffs_on" ] && jffs_on="0"
        [ -z "$jffs_scripts" ] && jffs_scripts="0"

        if [ $status -eq 1 ]; then
            warn -c cli,vlan "JFFS not fully enabled on NODE${node_id} ($node_ip) (jffs2_on=$jffs_on, jffs2_scripts=$jffs_scripts). Remediating..."

            if [ "$DRY_RUN" = "yes" ]; then
                info -c cli,vlan "[DRY-RUN] Would enable JFFS and reboot $node_ip"
                return 0
            fi

            if ! enable_jffs_and_reboot "$node_ip" "$node_id"; then
                return 1
            fi

            if ! wait_for_node_ping "$node_ip"; then
                return 1
            fi

            if ! wait_for_node_ssh_jffs "$node_ip" "$node_id"; then
                return 1
            fi

            if ! test_ssh_connection "$node_ip" "$node_id"; then
                error -c cli,vlan "✗ SSH connection failed to NODE${node_id} ($node_ip) after reboot"
                return 1
            fi

            if jffs_status=$(check_remote_jffs_status "$node_ip" "$node_id"); then
                info -c cli,vlan "✓ JFFS successfully enabled on NODE${node_id} ($node_ip)"
                return 0
            else
                error -c cli,vlan "✗ Unable to verify JFFS status on NODE${node_id} ($node_ip) after remediation"
                return 1
            fi
        else
            error -c cli,vlan "✗ Failed to determine JFFS status on NODE${node_id} ($node_ip)"
            return 1
        fi
    fi
}

# Normal syncs used one SSH round trip to test connectivity, another to read
# JFFS, and a third to create the stage.  Combine the non-mutating readiness
# read with exact-stage preparation; the remediation path still delegates to
# ensure_jffs_ready before it is allowed to create the stage.
prepare_remote_sync_stage() {
    _prss_ip="$1"
    _prss_id="$2"
    _prss_stage_cmd="$3"
    [ -n "$_prss_stage_cmd" ] || return 1
    # Do not let a failed stage mkdir be masked by the readiness marker.
    # _prss_stage_cmd is assembled exclusively from validated run/node paths.
    _prss_checked_stage_cmd="if ! ( $_prss_stage_cmd ); then exit 70; fi"
    _prss_cmd="
        jffs_on=\$(nvram get jffs2_on 2>/dev/null);
        jffs_scripts=\$(nvram get jffs2_scripts 2>/dev/null);
        if [ \"\$jffs_on\" = 1 ] && [ \"\$jffs_scripts\" = 1 ]; then
            $_prss_checked_stage_cmd
            printf 'SYNC_STAGE_READY\\n';
        else
            printf 'SYNC_STAGE_JFFS_NOT_READY|%s|%s\\n' \"\$jffs_on\" \"\$jffs_scripts\";
        fi
    "
    _prss_output=$(merv_ssh_exec "$_prss_id" "$_prss_ip" "$_prss_cmd" 2>/dev/null) || {
        merv_ssh_skip_log "$_prss_id" "$_prss_ip" "check JFFS and prepare staged sync directory"
        return 1
    }
    if printf '%s\n' "$_prss_output" | grep -qx 'SYNC_STAGE_READY'; then
        info -c cli,vlan "✓ JFFS already enabled on NODE$_prss_id ($_prss_ip)"
        info -c cli,vlan "✓ Ensured remote directories on NODE$_prss_id ($_prss_ip)"
        return 0
    fi
    if ! printf '%s\n' "$_prss_output" | grep -q '^SYNC_STAGE_JFFS_NOT_READY|'; then
        error -c cli,vlan "Could not confirm JFFS readiness on NODE$_prss_id ($_prss_ip)"
        return 1
    fi
    if ! ensure_jffs_ready "$_prss_ip" "$_prss_id"; then
        return 1
    fi
    if ! merv_ssh_exec "$_prss_id" "$_prss_ip" "$_prss_checked_stage_cmd" >/dev/null 2>&1; then
        merv_ssh_skip_log "$_prss_id" "$_prss_ip" "prepare staged sync directory after JFFS remediation"
        return 1
    fi
    info -c cli,vlan "✓ Ensured remote directories on NODE$_prss_id ($_prss_ip)"
    return 0
}

# ========================================================================== #
# FILE OPERATIONS — Directory creation, copy, verification, permissions      #
# ========================================================================== #

# create_remote_dirs_for_file — Ensure remote path exists before copy
create_remote_dirs_for_file() {
    node_ip="$1"
    file="$2"
    node_id="${3:-?}"
    
    # Extract directory path from file (if any)
    dir_path=$(dirname "$file")
    
    # If file is in a subdirectory, create that directory on remote
    if [ "$dir_path" != "." ]; then
        remote_dir="$REMOTE_MERV_BASE/$dir_path"
        dbg_log "Ensuring remote directory exists"
        dbg_var node_ip remote_dir
        if [ "$DRY_RUN" = "yes" ]; then
            info -c cli,vlan "[DRY-RUN] Would create directory $remote_dir on NODE${node_id} ($node_ip)"
            return 0
        fi
        if merv_ssh_exec "$node_id" "$node_ip" "mkdir -p '$remote_dir'" >/dev/null 2>&1; then
            info -c cli,vlan "✓ Created directory $remote_dir on NODE${node_id} ($node_ip)"
            return 0
        else
            merv_ssh_skip_log "$node_id" "$node_ip" "create directory $remote_dir"
            return 1
        fi
    fi
    return 0
}

# copy_file_to_node — Stream file via SSH, using atomic temp file replacement
copy_file_to_node() {
    node_ip="$1"
    file="$2"
    node_id="${3:-?}"
    remote_path="$REMOTE_MERV_BASE/$file"
    
    # sync_node_worker already creates the complete stage tree in one verified
    # command. Keep the historical directory fallback for other callers.
    if [ "$SYNC_STAGE_DIRS_PREPARED" != 1 ]; then
        if ! create_remote_dirs_for_file "$node_ip" "$file" "$node_id"; then
            return 1
        fi
    fi
    
    dbg_log "Preparing to copy file to node"
    dbg_var node_ip file remote_path

    if [ "$DRY_RUN" = "yes" ]; then
        info -c cli,vlan "[DRY-RUN] Would copy $file to NODE${node_id} ($node_ip):$remote_path"
        return 0
    fi

    # Special handling for settings.json: prepare node-specific settings payload
    if [ "$file" = "settings/settings.json" ]; then
        _cfn_tmp=$(sync_job_tmp_path "settings_prepared_node${node_id}")
        _cfn_node_hw_src=""

        # Read node-owned Hardware from the active installation. The staging
        # tree is new for this run and therefore cannot be the preservation
        # source.
        _cfn_remote_settings="$REMOTE_ACTIVE_MERV_BASE/settings/settings.json"
        _cfn_remote_lib="$REMOTE_ACTIVE_MERV_BASE/settings/lib_json.sh"
        _cfn_remote_hw=$(merv_ssh_exec "$node_id" "$node_ip" "
            if [ -f '$_cfn_remote_settings' ] && [ -f '$_cfn_remote_lib' ]; then
                . '$_cfn_remote_lib' 2>/dev/null
                json_extract_hardware_section '$_cfn_remote_settings' 2>/dev/null
            fi
        " 2>/dev/null || printf '')
        if [ -n "$_cfn_remote_hw" ] && echo "$_cfn_remote_hw" | grep -q '"Hardware"'; then
            _cfn_node_hw_src=$(sync_job_tmp_path "remote_hw_node${node_id}")
            printf '%s\n' "$_cfn_remote_hw" > "$_cfn_node_hw_src" 2>/dev/null
        fi

        if ! mnj_prepare_node_settings "$MERV_BASE/$file" "$node_id" "$_cfn_tmp" "$_cfn_node_hw_src"; then
            error -c cli,vlan "✗ Failed to prepare node settings for NODE${node_id}"
            rm -f "$_cfn_tmp" "$_cfn_node_hw_src" 2>/dev/null
            return 1
        fi
        rm -f "$_cfn_node_hw_src" 2>/dev/null

        # Stream prepared file via SSH
        if merv_ssh_stream_file "$node_id" "$node_ip" "$_cfn_tmp" "$remote_path"; then
            _cfn_exp_size=$(wc -c < "$_cfn_tmp" 2>/dev/null | tr -cd '0-9')
            _cfn_exp_algo=""; _cfn_exp_digest=""
            if merv_has sha256sum; then
                _cfn_exp_algo=sha256; _cfn_exp_digest=$(sha256sum "$_cfn_tmp" 2>/dev/null | awk '{print $1}')
            elif merv_has md5sum; then
                _cfn_exp_algo=md5; _cfn_exp_digest=$(md5sum "$_cfn_tmp" 2>/dev/null | awk '{print $1}')
            else
                error -c cli,vlan "✗ No local digest utility is available for settings verification"
                rm -f "$_cfn_tmp" 2>/dev/null
                return 1
            fi
            printf '%s\n%s\n%s\n' "$_cfn_exp_algo" "$_cfn_exp_size" "$_cfn_exp_digest" \
                > "$(sync_expected_path "$node_id")" 2>/dev/null || return 1
            chmod 600 "$(sync_expected_path "$node_id")" 2>/dev/null || return 1
            info -c cli,vlan "✓ Copied $file (prepared) to NODE${node_id} ($node_ip):$remote_path"
            rm -f "$_cfn_tmp" 2>/dev/null
            return 0
        else
            error -c cli,vlan "✗ Failed to copy $file to NODE${node_id} ($node_ip):$remote_path"
            rm -f "$_cfn_tmp" 2>/dev/null
            return 1
        fi
    fi

    # For all other files, copy as-is
    # Note: The Hardware section in settings.json will be repopulated by hw_probe.sh 
    # which runs after nodeenable. This ensures new model definitions from updates are always applied.

    # Use cat piped with timeout wrapper for atomic file transfer
    if merv_ssh_stream_file "$node_id" "$node_ip" "$MERV_BASE/$file" "$remote_path"; then
        info -c cli,vlan "✓ Copied $file to NODE${node_id} ($node_ip):$remote_path"
        return 0
    else
        error -c cli,vlan "✗ Failed to copy $file to NODE${node_id} ($node_ip):$remote_path"
        return 1
    fi
}

# copy_batch_to_node — Transfer many files in ONE tar stream over a single SSH
# connection instead of one connection per file. The bottleneck in node sync is
# the Dropbear handshake (~150-300ms each), not data volume, so collapsing ~21
# per-file copies into one tar pipe removes ~20 connections of overhead.
# Args: $1=node_ip, $2=node_id, $3=space-separated file list (relative to MERV_BASE)
# Returns: 0 on success, 1 on failure (tar exit code covers truncation / remote
#          write errors; settings.json is handled separately and never here).
copy_batch_to_node() {
    node_ip="$1"
    node_id="$2"
    batch_files="$3"

    if [ -z "$batch_files" ]; then
        warn -c cli,vlan "Batch copy: empty file list for NODE${node_id} ($node_ip)"
        return 1
    fi

    if [ "$DRY_RUN" = "yes" ]; then
        info -c cli,vlan "[DRY-RUN] Would batch-copy $(echo "$batch_files" | wc -w | tr -d ' ') files to NODE${node_id} ($node_ip) via tar"
        return 0
    fi

    info -c cli,vlan "Batch-copying files to NODE${node_id} ($node_ip)..."
    # Local tar streams the listed paths (relative to MERV_BASE); remote tar
    # extracts under the same base. Subdirectories are pre-created in the main
    # loop's mkdir so extraction never fails on a missing path.
    if (cd "$MERV_BASE" && tar -cf - $batch_files 2>/dev/null) | \
        merv_ssh_stream_stdin "$node_id" "$node_ip" "cd '$REMOTE_MERV_BASE' && tar -xf - 2>/dev/null" 2>/dev/null; then
        info -c cli,vlan "✓ Batch copy successful to NODE${node_id} ($node_ip)"
        return 0
    else
        error -c cli,vlan "✗ Batch copy failed to NODE${node_id} ($node_ip)"
        return 1
    fi
}

# verify_batch_on_node — Confirm all batched files landed intact using ONE SSH.
# Primary check: combined md5 fingerprint (md5sum of each file, sorted by name
# so tar's extraction order is irrelevant, then hashed into a single value).
# Fallback (no md5sum on either side): total byte count across all files.
# This replaces the previous per-file verify loop (~2 SSH calls per file) while
# providing a stronger guarantee than the old per-file size+md5 check.
# Args: $1=node_ip, $2=node_id, $3=space-separated file list (relative to MERV_BASE)
# Returns: 0 on success, 1 on mismatch.
verify_batch_on_node() {
    node_ip="$1"
    node_id="$2"
    batch_files="$3"
    _vbn_local_fp=""
    _vbn_remote_fp=""
    _vbn_local_total=""
    _vbn_remote_total=""

    [ -n "$batch_files" ] || return 1

    if [ "$DRY_RUN" = "yes" ]; then
        info -c cli,vlan "[DRY-RUN] Would verify batch on NODE${node_id} ($node_ip)"
        return 0
    fi

    # Primary: combined md5 fingerprint (order-independent via sort -k2).
    if merv_has md5sum; then
        _vbn_local_fp=$(cd "$MERV_BASE" && md5sum $batch_files 2>/dev/null | sort -k2 | md5sum 2>/dev/null | awk '{print $1}')
    elif merv_has md5; then
        _vbn_local_fp=$(cd "$MERV_BASE" && md5 -r $batch_files 2>/dev/null | sort -k2 | md5sum 2>/dev/null | awk '{print $1}')
    fi

    if [ -n "$_vbn_local_fp" ]; then
        _vbn_remote_fp=$(merv_ssh_exec "$node_id" "$node_ip" "cd '$REMOTE_MERV_BASE' && if type md5sum >/dev/null 2>&1; then md5sum $batch_files 2>/dev/null; elif type md5 >/dev/null 2>&1; then md5 -r $batch_files 2>/dev/null; fi | sort -k2 | md5sum 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tr -cd 'a-fA-F0-9')
        if [ -n "$_vbn_remote_fp" ] && [ "$_vbn_local_fp" = "$_vbn_remote_fp" ]; then
            info -c cli,vlan "✓ Batch verified on NODE${node_id} ($node_ip) (md5 fingerprint ok)"
            return 0
        else
            error -c cli,vlan "✗ Batch md5 mismatch on NODE${node_id} ($node_ip) (local: $_vbn_local_fp, remote: $_vbn_remote_fp)"
            return 1
        fi
    fi

    error -c cli,vlan "No digest utility is available for batch verification on NODE${node_id}"
    return 1

    # Legacy size-only fallback is unreachable by design.
    _vbn_local_total=$(cd "$MERV_BASE" && wc -c $batch_files 2>/dev/null | tail -1 | tr -cd '0-9')
    _vbn_remote_total=$(merv_ssh_exec "$node_id" "$node_ip" "cd '$REMOTE_MERV_BASE' && wc -c $batch_files 2>/dev/null | tail -1 | awk '{print \$1}'" 2>/dev/null | tr -cd '0-9')
    if [ -n "$_vbn_local_total" ] && [ "$_vbn_local_total" = "$_vbn_remote_total" ] && [ "$_vbn_local_total" -gt 0 ] 2>/dev/null; then
        info -c cli,vlan "✓ Batch verified on NODE${node_id} ($node_ip) (total size ok: ${_vbn_local_total} bytes)"
        return 0
    else
        error -c cli,vlan "✗ Batch size mismatch on NODE${node_id} ($node_ip) (local: $_vbn_local_total, remote: $_vbn_remote_total)"
        return 1
    fi
}

verify_file_on_node() {
    _vfn_ip="$1"; _vfn_file="$2"; _vfn_id="${3:-?}"; _vfn_remote="$REMOTE_MERV_BASE/$_vfn_file"
    [ "$DRY_RUN" = "yes" ] && return 0
    [ -f "$MERV_BASE/$_vfn_file" ] || return 1
    _vfn_algo=""; _vfn_size=""; _vfn_digest=""; _vfn_breadcrumb=""
    if [ "$_vfn_file" = "settings/settings.json" ]; then
        _vfn_breadcrumb=$(sync_expected_path "$_vfn_id")
    fi
    if [ -s "$_vfn_breadcrumb" ]; then
        _vfn_algo=$(sed -n '1p' "$_vfn_breadcrumb" 2>/dev/null)
        _vfn_size=$(sed -n '2p' "$_vfn_breadcrumb" 2>/dev/null | tr -cd '0-9')
        _vfn_digest=$(sed -n '3p' "$_vfn_breadcrumb" 2>/dev/null | tr -cd 'a-fA-F0-9')
    else
        _vfn_size=$(wc -c < "$MERV_BASE/$_vfn_file" 2>/dev/null | tr -cd '0-9')
        if merv_has sha256sum; then _vfn_algo=sha256; _vfn_digest=$(sha256sum "$MERV_BASE/$_vfn_file" | awk '{print $1}');
        elif merv_has md5sum; then _vfn_algo=md5; _vfn_digest=$(md5sum "$MERV_BASE/$_vfn_file" | awk '{print $1}'); fi
    fi
    case "$_vfn_algo:$_vfn_size:$_vfn_digest" in sha256:[0-9]*:[0-9A-Fa-f]*|md5:[0-9]*:[0-9A-Fa-f]*) ;; *) return 1 ;; esac
    _vfn_remote_result=$(merv_ssh_exec "$_vfn_id" "$_vfn_ip" "
        f='$_vfn_remote'; a='$_vfn_algo'; test -s \"\$f\" || { echo MISSING; exit 1; };
        s=\$(wc -c < \"\$f\" 2>/dev/null | tr -cd '0-9');
        if [ \"\$a\" = sha256 ] && type sha256sum >/dev/null 2>&1; then d=\$(sha256sum \"\$f\" | awk '{print \$1}');
        elif [ \"\$a\" = md5 ] && type md5sum >/dev/null 2>&1; then d=\$(md5sum \"\$f\" | awk '{print \$1}');
        else echo NO_DIGEST; exit 1; fi;
        printf 'OK|%s|%s|%s\\n' \"\$a\" \"\$s\" \"\$d\"
    " 2>/dev/null | tail -n 1 | tr -d '\r\n')
    if [ "$_vfn_remote_result" = "OK|$_vfn_algo|$_vfn_size|$_vfn_digest" ]; then
        [ -z "$_vfn_breadcrumb" ] || rm -f "$_vfn_breadcrumb" 2>/dev/null || return 1
        return 0
    fi
    error -c cli,vlan "Exact digest verification failed for $_vfn_file on NODE${_vfn_id}"
    return 1
}

# batch_set_remote_permissions — Apply all 755 and 644 permissions in ONE SSH
# call instead of one connection per file. Reads the existing manifest lists
# (FILES_TO_COPY_CHMOD / FILES_TO_COPY_CHMOD_644) so the permission policy is
# unchanged — only the transport is batched. Non-fatal, matching old behaviour.
# Args: $1=node_ip, $2=node_id
# Returns: 0 always (permission failures are warnings, never block sync).
batch_set_remote_permissions() {
    node_ip="$1"
    node_id="$2"
    _bsp_c755=""
    _bsp_c644=""
    _bsp_f=""

    if [ "$DRY_RUN" = "yes" ]; then
        info -c cli,vlan "[DRY-RUN] Would set 755/644 permissions on NODE${node_id} ($node_ip)"
        return 0
    fi

    for _bsp_f in $FILES_TO_COPY_CHMOD; do
        _bsp_c755="$_bsp_c755 '$REMOTE_MERV_BASE/$_bsp_f'"
    done
    for _bsp_f in $FILES_TO_COPY_CHMOD_644; do
        _bsp_c644="$_bsp_c644 '$REMOTE_MERV_BASE/$_bsp_f'"
    done

    if merv_ssh_exec "$node_id" "$node_ip" "chmod 755 $_bsp_c755 2>/dev/null; chmod 644 $_bsp_c644 2>/dev/null; echo 'chmod_done'" 2>/dev/null | grep -q "chmod_done"; then
        info -c cli,vlan "✓ Permissions set (755/644) on NODE${node_id} ($node_ip)"
    else
        warn -c cli,vlan "⚠️  chmod may not have completed on NODE${node_id} ($node_ip)"
    fi
    return 0
}

# verify_file_on_node — Confirm remote file exists, matches size/optional hash
verify_file_on_node() {
    node_ip="$1"
    file="$2"
    node_id="${3:-?}"
    remote_file="$REMOTE_MERV_BASE/$file"

    # Check if file exists and has content
    exists_check=$(merv_ssh_exec "$node_id" "$node_ip" "test -f '$remote_file' && echo 'exists'" 2>/dev/null)
    if echo "$exists_check" | grep -q "exists"; then
        # Check file size to ensure it's not empty
        # BusyBox stat variants do not share GNU's -c format flag.  wc -c is
        # available on the router and is sufficient for this bounded check.
        remote_size=$(merv_ssh_exec "$node_id" "$node_ip" "wc -c < '$remote_file' 2>/dev/null || echo 0" 2>/dev/null)
        local_size=$(wc -c < "$MERV_BASE/$file" 2>/dev/null || echo 0)

        # Remove any extra characters from size
        remote_size=$(echo "$remote_size" | tr -cd '0-9')
        local_size=$(echo "$local_size" | tr -cd '0-9')

        # If copy_file_to_node left a breadcrumb for this node+file, use its
        # size and md5 as the reference values. The sent file was content-modified
        # (e.g. settings.json had trunk config rewritten for the node), so
        # comparing against the unmodified local original would always mismatch.
        _vfn_exp_md5=""
        if [ "$file" = "settings/settings.json" ]; then
            _vfn_breadcrumb=$(sync_expected_path "$node_id")
            if [ -f "$_vfn_breadcrumb" ]; then
                _vfn_exp_size=$(sed -n '1p' "$_vfn_breadcrumb" | tr -cd '0-9')
                _vfn_exp_md5=$(sed -n '2p' "$_vfn_breadcrumb" | tr -cd 'a-fA-F0-9')
                if ! rm -f "$_vfn_breadcrumb" 2>/dev/null; then
                    warn -c vlan "Sync: expected-settings breadcrumb cleanup failed for NODE${node_id}"
                    return 1
                fi
                [ -n "$_vfn_exp_size" ] && [ "$_vfn_exp_size" -gt 0 ] && \
                    local_size="$_vfn_exp_size"
            fi
        fi

        if [ "$remote_size" -eq "$local_size" ] && [ "$remote_size" -gt 0 ]; then
            local local_md5=""
            local remote_md5=""

            if merv_has md5sum; then
                local_md5=$(md5sum "$MERV_BASE/$file" 2>/dev/null | awk '{print $1}')
            elif merv_has md5; then
                local_md5=$(md5 -r "$MERV_BASE/$file" 2>/dev/null | awk '{print $1}')
            fi
            # Use breadcrumb md5 when available (content-modified file)
            [ -n "$_vfn_exp_md5" ] && local_md5="$_vfn_exp_md5"

            if [ -n "$local_md5" ]; then
                remote_md5=$(merv_ssh_exec "$node_id" "$node_ip" "if type md5sum >/dev/null 2>&1; then md5sum '$remote_file' 2>/dev/null | awk '{print \$1}'; elif type md5 >/dev/null 2>&1; then md5 -r '$remote_file' 2>/dev/null | awk '{print \$1}'; else echo NA; fi" 2>/dev/null)
                remote_md5=$(echo "$remote_md5" | head -n 1 | tr -cd 'a-fA-F0-9')

                if [ -n "$remote_md5" ] && [ "$remote_md5" != "NA" ]; then
                    if [ "$local_md5" != "$remote_md5" ]; then
                        error -c cli,vlan "✗ MD5 mismatch for $file on NODE${node_id} ($node_ip) (local: $local_md5, remote: $remote_md5)"
                        return 1
                    fi
                    info -c cli,vlan "✓ Verified $file on NODE${node_id} ($node_ip) (size: $remote_size bytes, md5 ok)"
                    return 0
                fi
            fi

            info -c cli,vlan "✓ Verified $file on NODE${node_id} ($node_ip) (size: $remote_size bytes)"
            return 0
        else
            error -c cli,vlan "⚠️  Size mismatch for $file on NODE${node_id} ($node_ip) (local: $local_size, remote: $remote_size)"
            # Don't fail verification for size mismatch, just warn
            return 0
        fi
    else
        error -c cli,vlan "✗ File $file not found on NODE${node_id} ($node_ip) at $remote_file"
        return 1
    fi
}

merv_verify_file_on_node_exact() {
    _ve_ip="$1"; _ve_file="$2"; _ve_id="${3:-?}"; _ve_remote="$REMOTE_MERV_BASE/$_ve_file"
    case "$_ve_file" in ''|*..*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
    [ "$DRY_RUN" = "yes" ] && return 0
    [ -f "$MERV_BASE/$_ve_file" ] || return 1
    _ve_breadcrumb=""; [ "$_ve_file" = "settings/settings.json" ] && _ve_breadcrumb=$(sync_expected_path "$_ve_id")
    if [ -s "$_ve_breadcrumb" ]; then
        _ve_algo=$(sed -n '1p' "$_ve_breadcrumb"); _ve_size=$(sed -n '2p' "$_ve_breadcrumb" | tr -cd '0-9'); _ve_digest=$(sed -n '3p' "$_ve_breadcrumb" | tr -cd 'a-fA-F0-9')
    else
        _ve_size=$(wc -c < "$MERV_BASE/$_ve_file" | tr -cd '0-9')
        if merv_has sha256sum; then _ve_algo=sha256; _ve_digest=$(sha256sum "$MERV_BASE/$_ve_file" | awk '{print $1}');
        elif merv_has md5sum; then _ve_algo=md5; _ve_digest=$(md5sum "$MERV_BASE/$_ve_file" | awk '{print $1}'); else return 1; fi
    fi
    case "$_ve_algo:$_ve_size:$_ve_digest" in sha256:[0-9]*:[0-9A-Fa-f]*|md5:[0-9]*:[0-9A-Fa-f]*) ;; *) return 1 ;; esac
    _ve_result=$(merv_ssh_exec "$_ve_id" "$_ve_ip" "f='$_ve_remote'; a='$_ve_algo'; test -s \"\$f\" || exit 1; s=\$(wc -c < \"\$f\"); if [ \"\$a\" = sha256 ] && type sha256sum >/dev/null 2>&1; then d=\$(sha256sum \"\$f\" | awk '{print \$1}'); elif [ \"\$a\" = md5 ] && type md5sum >/dev/null 2>&1; then d=\$(md5sum \"\$f\" | awk '{print \$1}'); else exit 1; fi; printf 'OK|%s|%s|%s\\n' \"\$a\" \"\$s\" \"\$d\"" 2>/dev/null | tail -n 1 | tr -d '\r\n')
    [ "$_ve_result" = "OK|$_ve_algo|$_ve_size|$_ve_digest" ] || { error -c cli,vlan "Exact digest verification failed for $_ve_file on NODE${_ve_id}"; return 1; }
    [ -z "$_ve_breadcrumb" ] || rm -f "$_ve_breadcrumb" 2>/dev/null || return 1
    return 0
}

verify_file_on_node() { merv_verify_file_on_node_exact "$@"; }

# Build the exact local contract for one staged file.  settings.json may be
# rewritten for node trunk settings, so its breadcrumb remains authoritative
# until the single remote batch verifier has confirmed the sent content.
sync_exact_file_contract() {
    _sefc_file="$1"; _sefc_id="$2"
    case "$_sefc_file" in ''|*..*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
    [ -f "$MERV_BASE/$_sefc_file" ] || return 1
    SYNC_VERIFY_FILE="$_sefc_file"
    SYNC_VERIFY_ALGO=""
    SYNC_VERIFY_SIZE=""
    SYNC_VERIFY_DIGEST=""
    SYNC_VERIFY_BREADCRUMB=""
    if [ "$_sefc_file" = "settings/settings.json" ]; then
        SYNC_VERIFY_BREADCRUMB=$(sync_expected_path "$_sefc_id")
    fi
    if [ -s "$SYNC_VERIFY_BREADCRUMB" ]; then
        SYNC_VERIFY_ALGO=$(sed -n '1p' "$SYNC_VERIFY_BREADCRUMB" 2>/dev/null)
        SYNC_VERIFY_SIZE=$(sed -n '2p' "$SYNC_VERIFY_BREADCRUMB" 2>/dev/null | tr -cd '0-9')
        SYNC_VERIFY_DIGEST=$(sed -n '3p' "$SYNC_VERIFY_BREADCRUMB" 2>/dev/null | tr -cd 'a-fA-F0-9')
    else
        SYNC_VERIFY_SIZE=$(wc -c < "$MERV_BASE/$_sefc_file" 2>/dev/null | tr -cd '0-9')
        if merv_has sha256sum; then
            SYNC_VERIFY_ALGO=sha256
            SYNC_VERIFY_DIGEST=$(sha256sum "$MERV_BASE/$_sefc_file" 2>/dev/null | awk '{print $1}')
        elif merv_has md5sum; then
            SYNC_VERIFY_ALGO=md5
            SYNC_VERIFY_DIGEST=$(md5sum "$MERV_BASE/$_sefc_file" 2>/dev/null | awk '{print $1}')
        fi
    fi
    case "$SYNC_VERIFY_ALGO:$SYNC_VERIFY_SIZE:$SYNC_VERIFY_DIGEST" in
        sha256:[0-9]*:[0-9A-Fa-f]*|md5:[0-9]*:[0-9A-Fa-f]*) return 0 ;;
    esac
    return 1
}

# Verify every staged file independently, but serialize all exact size/digest
# checks into one verified SSH command.  The previous last-definition override
# called verify_file_on_node once per file, causing a normal one-node sync to
# spend minutes on repeated Dropbear setup instead of one bounded verification.
sync_verify_batch_exact() {
    _vbn_ip="$1"; _vbn_id="$2"; _vbn_files="$3"
    [ -n "$_vbn_files" ] || return 1
    [ "$DRY_RUN" = yes ] && return 0
    _vbn_cmd="cd '$REMOTE_MERV_BASE' || exit 2;"
    _vbn_breadcrumbs=""
    _vbn_count=0
    for _vbn_file in $_vbn_files; do
        sync_exact_file_contract "$_vbn_file" "$_vbn_id" || {
            error -c cli,vlan "Could not create an exact local digest contract for $_vbn_file"
            return 1
        }
        _vbn_count=$((_vbn_count + 1))
        _vbn_cmd="$_vbn_cmd f='$SYNC_VERIFY_FILE'; a='$SYNC_VERIFY_ALGO'; s='$SYNC_VERIFY_SIZE'; d='$SYNC_VERIFY_DIGEST'; test -s \"\$f\" || exit 3; actual_size=\$(wc -c < \"\$f\" 2>/dev/null | tr -cd '0-9'); [ \"\$actual_size\" = \"\$s\" ] || exit 4; case \"\$a\" in sha256) type sha256sum >/dev/null 2>&1 || exit 5; actual_digest=\$(sha256sum \"\$f\" | awk '{print \$1}');; md5) type md5sum >/dev/null 2>&1 || exit 5; actual_digest=\$(md5sum \"\$f\" | awk '{print \$1}');; *) exit 5;; esac; [ \"\$actual_digest\" = \"\$d\" ] || exit 6;"
        [ -z "$SYNC_VERIFY_BREADCRUMB" ] || _vbn_breadcrumbs="$_vbn_breadcrumbs $SYNC_VERIFY_BREADCRUMB"
    done
    [ "$_vbn_count" -gt 0 ] 2>/dev/null || return 1
    _vbn_cmd="$_vbn_cmd printf 'SYNC_BATCH_EXACT_OK\\n'"
    _vbn_result=$(merv_ssh_exec "$_vbn_id" "$_vbn_ip" "$_vbn_cmd" 2>/dev/null) || {
        error -c cli,vlan "Exact staged-file verification SSH command failed for NODE$_vbn_id"
        return 1
    }
    printf '%s\n' "$_vbn_result" | tail -n 1 | grep -qx 'SYNC_BATCH_EXACT_OK' || {
        error -c cli,vlan "Exact staged-file verification failed for NODE$_vbn_id"
        return 1
    }
    for _vbn_breadcrumb in $_vbn_breadcrumbs; do
        rm -f "$_vbn_breadcrumb" 2>/dev/null || return 1
    done
    return 0
}

# The compact stream implementation below is the active verifier.  Keeping
# contracts in stdin prevents a multi-file check from exceeding the command
# line accepted by older Dropbear/BusyBox combinations.
sync_verify_batch_manifest() {
    _vbm_ip="$1"; _vbm_id="$2"; _vbm_files="$3"
    [ -n "$_vbm_files" ] || return 1
    [ "$DRY_RUN" = yes ] && return 0
    type merv_ssh_stream_stdin >/dev/null 2>&1 || return 1

    _vbm_tmp_root="${MERV_NODE_JOB_DIR:-${TMPDIR:-/tmp/mervlan_tmp}}"
    case "$_vbm_tmp_root" in /*) ;; *) return 1 ;; esac
    case "$_vbm_tmp_root" in *..*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
    mkdir -p "$_vbm_tmp_root" 2>/dev/null || return 1
    _vbm_tag="${SYNC_RUN_ID:-$$}.${_vbm_id}.$$"
    case "$_vbm_tag" in *[!A-Za-z0-9._-]*) _vbm_tag="${_vbm_id}.$$" ;; esac
    _vbm_manifest="$_vbm_tmp_root/.sync-verify.${_vbm_tag}.manifest"
    _vbm_result_file="$_vbm_tmp_root/.sync-verify.${_vbm_tag}.result"
    ( umask 077; : > "$_vbm_manifest" ) || return 1

    _vbm_breadcrumbs=""
    _vbm_count=0
    for _vbm_file in $_vbm_files; do
        sync_exact_file_contract "$_vbm_file" "$_vbm_id" || {
            error -c cli,vlan "Could not create an exact local digest contract for $_vbm_file"
            rm -f "$_vbm_manifest" "$_vbm_result_file" 2>/dev/null || :
            return 1
        }
        printf '%s|%s|%s|%s\n' "$SYNC_VERIFY_FILE" "$SYNC_VERIFY_ALGO" \
            "$SYNC_VERIFY_SIZE" "$SYNC_VERIFY_DIGEST" >> "$_vbm_manifest" || {
            rm -f "$_vbm_manifest" "$_vbm_result_file" 2>/dev/null || :
            return 1
        }
        _vbm_count=$((_vbm_count + 1))
        [ -z "$SYNC_VERIFY_BREADCRUMB" ] || _vbm_breadcrumbs="$_vbm_breadcrumbs $SYNC_VERIFY_BREADCRUMB"
    done
    if ! [ "$_vbm_count" -gt 0 ] 2>/dev/null; then
        rm -f "$_vbm_manifest" "$_vbm_result_file" 2>/dev/null || :
        return 1
    fi

    _vbm_remote_body=$(cat <<'EOF'
sync_verify_fail() {
    printf 'SYNC_BATCH_EXACT_FAIL|%s|%s\n' "$1" "$2"
    exit 0
}
_svm_count=0
while IFS='|' read -r _svm_file _svm_algo _svm_size _svm_digest _svm_extra || [ -n "$_svm_file" ]; do
    [ -n "$_svm_file" ] && [ -n "$_svm_algo" ] && [ -n "$_svm_size" ] && [ -n "$_svm_digest" ] && [ -z "$_svm_extra" ] || sync_verify_fail manifest invalid-contract
    case "$_svm_file" in ''|*..*|*[!A-Za-z0-9_./-]*) sync_verify_fail "$_svm_file" invalid-path ;; esac
    case "$_svm_algo:$_svm_size:$_svm_digest" in
        sha256:[0-9]*:[0-9A-Fa-f]*|md5:[0-9]*:[0-9A-Fa-f]*) ;;
        *) sync_verify_fail "$_svm_file" invalid-contract ;;
    esac
    [ -s "$_svm_file" ] || sync_verify_fail "$_svm_file" missing
    _svm_actual_size=$(wc -c < "$_svm_file" 2>/dev/null | tr -cd '0-9')
    [ "$_svm_actual_size" = "$_svm_size" ] || sync_verify_fail "$_svm_file" size
    case "$_svm_algo" in
        sha256)
            if type sha256sum >/dev/null 2>&1; then
                _svm_actual_digest=$(sha256sum "$_svm_file" 2>/dev/null | awk '{print $1}')
            elif type openssl >/dev/null 2>&1; then
                _svm_actual_digest=$(openssl dgst -sha256 "$_svm_file" 2>/dev/null | awk '{print $NF}')
            else
                sync_verify_fail "$_svm_file" digest-tool
            fi
            ;;
        md5)
            if type md5sum >/dev/null 2>&1; then
                _svm_actual_digest=$(md5sum "$_svm_file" 2>/dev/null | awk '{print $1}')
            elif type openssl >/dev/null 2>&1; then
                _svm_actual_digest=$(openssl dgst -md5 "$_svm_file" 2>/dev/null | awk '{print $NF}')
            else
                sync_verify_fail "$_svm_file" digest-tool
            fi
            ;;
        *) sync_verify_fail "$_svm_file" invalid-algorithm ;;
    esac
    [ "$_svm_actual_digest" = "$_svm_digest" ] || sync_verify_fail "$_svm_file" digest
    _svm_count=$((_svm_count + 1))
done
[ "$_svm_count" -gt 0 ] 2>/dev/null || sync_verify_fail manifest empty
printf 'SYNC_BATCH_EXACT_OK|%s\n' "$_svm_count"
EOF
)
    _vbm_cmd="cd '$REMOTE_MERV_BASE' || { printf 'SYNC_BATCH_EXACT_FAIL|stage|stage-root\\n'; exit 0; }
$_vbm_remote_body"
    merv_ssh_stream_stdin "$_vbm_id" "$_vbm_ip" "$_vbm_cmd" < "$_vbm_manifest" > "$_vbm_result_file" 2>/dev/null
    _vbm_stream_rc=$?
    _vbm_result=$(tail -n 1 "$_vbm_result_file" 2>/dev/null | tr -d '\r\n')
    rm -f "$_vbm_manifest" "$_vbm_result_file" 2>/dev/null || :

    if [ "$_vbm_stream_rc" -ne 0 ]; then
        _vbm_reason=$(printf '%s' "${MERV_SSH_LAST_REASON:-ssh-stream-failed}" | tr -cd 'A-Za-z0-9._-')
        [ -n "$_vbm_reason" ] || _vbm_reason=ssh-stream-failed
        error -c cli,vlan "Exact staged-file verification transport failed for NODE$_vbm_id ($_vbm_reason)"
        return 1
    fi
    case "$_vbm_result" in
        "SYNC_BATCH_EXACT_OK|$_vbm_count") ;;
        SYNC_BATCH_EXACT_FAIL\|*)
            IFS='|' read -r _vbm_status _vbm_failure_file _vbm_failure_reason _vbm_extra <<EOF
$_vbm_result
EOF
            _vbm_failure_file=$(printf '%s' "$_vbm_failure_file" | tr -cd 'A-Za-z0-9_./-')
            _vbm_failure_reason=$(printf '%s' "$_vbm_failure_reason" | tr -cd 'A-Za-z0-9._-')
            [ -n "$_vbm_failure_file" ] || _vbm_failure_file=unknown-file
            [ -n "$_vbm_failure_reason" ] || _vbm_failure_reason=unknown-reason
            error -c cli,vlan "Exact staged-file verification failed for NODE$_vbm_id: $_vbm_failure_file ($_vbm_failure_reason)"
            return 1
            ;;
        *)
            error -c cli,vlan "Exact staged-file verification returned no valid result for NODE$_vbm_id"
            return 1
            ;;
    esac
    for _vbm_breadcrumb in $_vbm_breadcrumbs; do
        rm -f "$_vbm_breadcrumb" 2>/dev/null || return 1
    done
    return 0
}

verify_batch_on_node() { sync_verify_batch_manifest "$@"; }

batch_set_remote_permissions() {
    _bsp_ip="$1"; _bsp_id="$2"
    [ "$DRY_RUN" = yes ] && return 0
    _bsp_cmd="set -e;"
    for _bsp_file in $FILES_TO_COPY_CHMOD; do
        case "$_bsp_file" in *..*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
        _bsp_cmd="$_bsp_cmd chmod 755 '$REMOTE_MERV_BASE/$_bsp_file';"
    done
    for _bsp_file in $FILES_TO_COPY_CHMOD_644; do
        case "$_bsp_file" in *..*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
        _bsp_cmd="$_bsp_cmd chmod 644 '$REMOTE_MERV_BASE/$_bsp_file';"
    done
    _bsp_cmd="$_bsp_cmd printf 'PERMISSIONS_OK\\n'"
    _bsp_result=$(merv_ssh_exec "$_bsp_id" "$_bsp_ip" "$_bsp_cmd" 2>/dev/null) || return 1
    printf '%s\n' "$_bsp_result" | tail -n 1 | grep -qx 'PERMISSIONS_OK'
}

set_remote_permissions() {
    _srp_ip="$1"; _srp_file="$2"; _srp_id="${3:-?}"
    case "$_srp_file" in ''|*..*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
    [ "$DRY_RUN" = yes ] && return 0
    merv_ssh_exec "$_srp_id" "$_srp_ip" "chmod 755 '$REMOTE_MERV_BASE/$_srp_file'" >/dev/null 2>&1
}

set_remote_permissions_644() {
    _srp_ip="$1"; _srp_file="$2"; _srp_id="${3:-?}"
    case "$_srp_file" in ''|*..*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
    [ "$DRY_RUN" = yes ] && return 0
    merv_ssh_exec "$_srp_id" "$_srp_ip" "chmod 644 '$REMOTE_MERV_BASE/$_srp_file'" >/dev/null 2>&1
}

# set_remote_permissions — Apply 755 to scripts that must be executable
set_remote_permissions() {
    node_ip="$1"
    file="$2"
    node_id="${3:-?}"
    remote_file="$REMOTE_MERV_BASE/$file"

    dbg_log "Applying chmod 755 on node"
    dbg_var node_ip remote_file

    if [ "$DRY_RUN" = "yes" ]; then
        info -c cli,vlan "[DRY-RUN] Would set executable permissions for $file on NODE${node_id} ($node_ip)"
        return 0
    fi

    result=$(merv_ssh_exec "$node_id" "$node_ip" "chmod 755 '$remote_file' 2>/dev/null; echo 'permissions_set'" 2>/dev/null)
    if echo "$result" | grep -q "permissions_set"; then
        info -c cli,vlan "✓ Set executable permissions for $file on NODE${node_id} ($node_ip)"
        return 0
    else
        error -c cli,vlan "⚠️  Could not set permissions for $file on $node_ip"
        return 1
    fi
}

# set_remote_permissions_644 — Ensure sourced configs stay non-executable
set_remote_permissions_644() {
    node_ip="$1"
    file="$2"
    node_id="${3:-?}"
    remote_file="$REMOTE_MERV_BASE/$file"

    dbg_log "Applying chmod 644 on node"
    dbg_var node_ip remote_file

    if [ "$DRY_RUN" = "yes" ]; then
        info -c cli,vlan "[DRY-RUN] Would set 644 permissions for $file on NODE${node_id} ($node_ip)"
        return 0
    fi

    result=$(merv_ssh_exec "$node_id" "$node_ip" "chmod 644 '$remote_file' 2>/dev/null; echo 'permissions_644_set'" 2>/dev/null)
    if echo "$result" | grep -q "permissions_644_set"; then
        info -c cli,vlan "✓ Set 644 permissions for $file on NODE${node_id} ($node_ip)"
        return 0
    else
        warn -c cli,vlan "⚠️  Could not set 644 permissions for $file on NODE${node_id} ($node_ip)"
        return 1
    fi
}

# Last definitions win over the legacy marker-echo implementations above.
# A successful chmod is represented by the SSH command's exit status itself;
# an unconditional echo must never turn a failed chmod into success.
set_remote_permissions() {
    _srp_ip="$1"; _srp_file="$2"; _srp_id="${3:-?}"
    case "$_srp_file" in ''|*..*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
    [ "$DRY_RUN" = yes ] && return 0
    merv_ssh_exec "$_srp_id" "$_srp_ip" "chmod 755 '$REMOTE_MERV_BASE/$_srp_file'" >/dev/null 2>&1
}

set_remote_permissions_644() {
    _srp_ip="$1"; _srp_file="$2"; _srp_id="${3:-?}"
    case "$_srp_file" in ''|*..*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
    [ "$DRY_RUN" = yes ] && return 0
    merv_ssh_exec "$_srp_id" "$_srp_ip" "chmod 644 '$REMOTE_MERV_BASE/$_srp_file'" >/dev/null 2>&1
}

# set_node_flag_remote — Mark remote device as MerVLAN node via settings.json
set_node_flag_remote() {
    node_ip="$1"
    node_id="$2"
    _snfr_c755=""
    _snfr_c644=""
    for _snfr_file in $FILES_TO_COPY_CHMOD; do
        case "$_snfr_file" in ''|*..*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
        _snfr_c755="$_snfr_c755 '$REMOTE_MERV_BASE/$_snfr_file'"
    done
    for _snfr_file in $FILES_TO_COPY_CHMOD_644; do
        case "$_snfr_file" in ''|*..*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
        _snfr_c644="$_snfr_c644 '$REMOTE_MERV_BASE/$_snfr_file'"
    done
    remote_cmd="set -e;"
    [ -z "$_snfr_c755" ] || remote_cmd="$remote_cmd chmod 755 $_snfr_c755;"
    [ -z "$_snfr_c644" ] || remote_cmd="$remote_cmd chmod 644 $_snfr_c644;"
    remote_cmd="$remote_cmd
        SETTINGS_FILE='$REMOTE_MERV_BASE/settings/settings.json';
        if [ ! -f \"\$SETTINGS_FILE\" ]; then
            echo 'settings-missing' >&2
            exit 1
        fi
        if [ ! -f '$REMOTE_MERV_BASE/settings/lib_json.sh' ]; then
            echo 'lib-json-missing' >&2
            exit 1
        fi
        . '$REMOTE_MERV_BASE/settings/lib_json.sh' 2>/dev/null || {
            echo 'lib-json-load-failed' >&2
            exit 1
        }
        json_set_flag IS_NODE 1 \"\$SETTINGS_FILE\" || exit 1
        json_set_flag NODE_ID \"$node_id\" \"\$SETTINGS_FILE\" || exit 1
        json_get_flag IS_NODE 0 \"\$SETTINGS_FILE\"
        json_get_flag NODE_ID \"none\" \"\$SETTINGS_FILE\"
    "

    dbg_log "Setting IS_NODE flag remotely"
    dbg_var node_ip remote_cmd

    if [ "$DRY_RUN" = "yes" ]; then
        info -c cli,vlan "[DRY-RUN] Would set IS_NODE=1 and NODE_ID=$node_id in settings.json on NODE${node_id} ($node_ip)"
        return 0
    fi

    node_flags=$(merv_ssh_exec "$node_id" "$node_ip" "$remote_cmd" 2>/dev/null)
    node_flag_value=$(echo "$node_flags" | tail -n 2 | head -n 1 | tr -d '\r\n')
    node_id_value=$(echo "$node_flags" | tail -n 1 | tr -d '\r\n')

    if [ "$node_flag_value" = "1" ] && [ "$node_id_value" = "$node_id" ]; then
        info -c cli,vlan "✓ Set staged permissions, IS_NODE=1, and NODE_ID=$node_id on NODE${node_id} ($node_ip)"
        return 0
    fi

    error -c cli,vlan "✗ Failed to set IS_NODE/NODE_ID on NODE${node_id} ($node_ip) (IS_NODE='$node_flag_value', NODE_ID='$node_id_value')"
    return 1
}

# ========================================================================== #
# DEBUG UTILITIES — Optional verbose listing during troubleshooting          #
# ========================================================================== #

# debug_remote_files — Recursively list remote MerVLAN directory contents
debug_remote_files() {
    node_ip="$1"
    stage="$2"  # optional: before | after
    node_id="${3:-?}"
    info -c cli "Debugging files on NODE${node_id} ($node_ip)${stage:+ ($stage)}..."
    listing=$(merv_ssh_exec "$node_id" "$node_ip" "if [ -d \"$REMOTE_MERV_BASE\" ]; then ls -laR \"$REMOTE_MERV_BASE\" 2>/dev/null || echo 'No files yet (ls failed)'; else echo 'Directory not found: $REMOTE_MERV_BASE'; fi" 2>/dev/null)
    if [ -n "$listing" ]; then
        echo "$listing" | while IFS= read -r line; do
            [ -n "$line" ] && info -c vlan "$line"
        done
    else
        info -c vlan "(no output from remote ls)"
    fi
    info -c cli "Debugging completed on NODE${node_id} ($node_ip)${stage:+ ($stage)}"
}

# ========================================================================== #
# NODE HARDWARE PROBE — Detect hardware on node and pull values to main      #
# ========================================================================== #

# pull_node_hardware — Run hw_probe on node and copy PRODUCTID/MAX_ETH_PORTS
#                      to main settings.json as PRODUCTID_NODE{n}/MAX_ETH_PORTS_NODE{n}
# Arguments: node_ip, node_id
# Returns: 0 on success, 1 on failure
pull_node_hardware() {
    _pnh_ip="$1"
    _pnh_id="$2"
    _pnh_output=""
    _pnh_productid=""
    _pnh_maxeth=""
    _pnh_label_overrides=""
    _pnh_has_label_overrides=0

    if [ "$DRY_RUN" = "yes" ]; then
        info -c cli,vlan "[DRY-RUN] Would run hw_probe and pull hardware values from NODE${_pnh_id} ($_pnh_ip)"
        return 0
    fi

    # Run hw_probe.sh on the node, then read both Hardware values back — all in
    # ONE SSH session instead of three. hw_probe writes the node's settings.json;
    # we source lib_json once and print the two values with stable key prefixes
    # so the caller can parse them without ambiguity.
    # Activation can provide this output from its verified activation command.
    # Keep the standalone fallback for callers outside Sync Nodes.
    if [ "$#" -ge 3 ]; then
        _pnh_output="$3"
    else
      info -c cli,vlan "Running hw_probe on NODE${_pnh_id} ($_pnh_ip)..."
      _pnh_output=$(merv_ssh_exec "$_pnh_id" "$_pnh_ip" "
        cd '$MERV_BASE/functions' && ./hw_probe.sh >/dev/null 2>&1 || echo 'HWPROBE_FAILED'
        . '$MERV_BASE/settings/lib_json.sh' 2>/dev/null
        printf 'PRODUCTID=%s\n' \"\$(json_get_section_value Hardware PRODUCTID '$MERV_BASE/settings/settings.json' 2>/dev/null)\"
        printf 'MAX_ETH_PORTS=%s\n' \"\$(json_get_section_value Hardware MAX_ETH_PORTS '$MERV_BASE/settings/settings.json' 2>/dev/null)\"
        printf 'LAN_PORT_LABEL_OVERRIDES=%s\n' \"\$(json_get_section_value Hardware LAN_PORT_LABEL_OVERRIDES '$MERV_BASE/settings/settings.json' 2>/dev/null)\"
      " 2>/dev/null)
    fi

    if printf '%s' "$_pnh_output" | grep -q 'HWPROBE_FAILED'; then
        warn -c cli,vlan "⚠️ hw_probe failed on NODE${_pnh_id} ($_pnh_ip)"
        return 1
    fi

    _pnh_productid=$(printf '%s' "$_pnh_output" | sed -n 's/^PRODUCTID=//p' | tr -d '\r\n')
    _pnh_maxeth=$(printf '%s' "$_pnh_output" | sed -n 's/^MAX_ETH_PORTS=//p' | tr -d '\r\n')
    if printf '%s\n' "$_pnh_output" | grep -q '^LAN_PORT_LABEL_OVERRIDES='; then
        _pnh_has_label_overrides=1
        _pnh_label_overrides=$(printf '%s\n' "$_pnh_output" | sed -n 's/^LAN_PORT_LABEL_OVERRIDES=//p' | tr -d '\r\n')
    fi

    # Validate we got something
    if [ -z "$_pnh_productid" ] && [ -z "$_pnh_maxeth" ]; then
        warn -c cli,vlan "⚠️ Could not retrieve hardware values from NODE${_pnh_id} ($_pnh_ip)"
        return 1
    fi

    # Write to main router's settings.json as PRODUCTID_NODE{n} and MAX_ETH_PORTS_NODE{n}
    if [ -n "$_pnh_productid" ]; then
        if json_set_section_value "Hardware" "PRODUCTID_NODE${_pnh_id}" "$_pnh_productid" "$SETTINGS_FILE"; then
            info -c cli,vlan "✓ PRODUCTID_NODE${_pnh_id}=$_pnh_productid"
        else
            warn -c cli,vlan "⚠️ Failed to write PRODUCTID_NODE${_pnh_id}"
        fi
    fi

    if [ -n "$_pnh_maxeth" ]; then
        if json_set_section_value "Hardware" "MAX_ETH_PORTS_NODE${_pnh_id}" "$_pnh_maxeth" "$SETTINGS_FILE"; then
            info -c cli,vlan "✓ MAX_ETH_PORTS_NODE${_pnh_id}=$_pnh_maxeth"
        else
            warn -c cli,vlan "⚠️ Failed to write MAX_ETH_PORTS_NODE${_pnh_id}"
        fi
    fi

    # Empty is meaningful: clear stale labels when a node changes profile or
    # uses a manual hardware map.
    if [ "$_pnh_has_label_overrides" = "1" ]; then
        if json_set_section_value "Hardware" "LAN_PORT_LABEL_OVERRIDES_NODE${_pnh_id}" "$_pnh_label_overrides" "$SETTINGS_FILE"; then
            info -c cli,vlan "LAN_PORT_LABEL_OVERRIDES_NODE${_pnh_id}=${_pnh_label_overrides:-<empty>}"
        else
            warn -c cli,vlan "Failed to write LAN_PORT_LABEL_OVERRIDES_NODE${_pnh_id}"
        fi
    else
        warn -c cli,vlan "NODE${_pnh_id} did not return LAN label metadata"
    fi

    return 0
}

cleanup_remote_stage() {
    _crs_ip="$1"
    _crs_id="$2"
    _crs_stage="$3"
    _crs_old="$4"
    case "$_crs_stage" in /jffs/addons/mervlan_backups/.mervlan.new.*) ;; *) return 1 ;; esac
    case "$_crs_old" in /jffs/addons/mervlan_backups/.mervlan.old.*) ;; *) return 1 ;; esac
    # Remove only the unactivated new tree. A surviving old tree means rollback
    # did not finish and must remain available for manual recovery.
    merv_ssh_exec "$_crs_id" "$_crs_ip" "rm -rf '$_crs_stage'" >/dev/null 2>&1
}

activate_staged_node() {
    _asn_ip="$1"
    _asn_id="$2"
    _asn_stage="$3"
    _asn_old="$4"
    SYNC_NODE_ACTIVATION_OUTPUT=""
    export SYNC_NODE_ACTIVATION_OUTPUT
    case "$_asn_stage" in /jffs/addons/mervlan_backups/.mervlan.new.*) ;; *) return 1 ;; esac
    case "$_asn_old" in /jffs/addons/mervlan_backups/.mervlan.old.*) ;; *) return 1 ;; esac

    _asn_cmd="
        active='$MERV_BASE'; stage='$_asn_stage'; old='$_asn_old';
        test -f \"\$stage/settings/settings.json\" || exit 21;
        test -x \"\$stage/functions/mervlan_boot.sh\" || exit 22;
        rm -rf \"\$old\" 2>/dev/null || exit 23;
        had_old=0;
        if [ -d \"\$active\" ]; then mv \"\$active\" \"\$old\" || exit 24; had_old=1; fi;
        if [ \"\$had_old\" = 1 ] && [ -d \"\$old/tmp\" ]; then
            if ! mkdir -p \"\$stage/tmp\" 2>/dev/null; then exit 23; fi;
            for db in \"\$old\"/tmp/*.db; do
                [ -f \"\$db\" ] || continue;
                if ! cp -p \"\$db\" \"\$stage/tmp/\" 2>/dev/null; then exit 23; fi;
            done;
        fi;
        if ! mv \"\$stage\" \"\$active\"; then
            if [ \"\$had_old\" = 1 ] && ! mv \"\$old\" \"\$active\" 2>/dev/null; then exit 27; fi;
            exit 25;
        fi;
        nodeenable_rc=0; nodeenable_out=\"\";
        if cd \"\$active/functions\"; then
            nodeenable_out=\$(MERV_NODE_CONTEXT=1 sh ./mervlan_boot.sh nodeenable --local 2>&1);
            nodeenable_rc=\$?;
        else
            nodeenable_rc=24;
        fi;
        report=\"\"; report_rc=1;
        if [ \"\$nodeenable_rc\" -eq 0 ]; then
            report=\$(MERV_NODE_CONTEXT=1 sh ./mervlan_boot.sh report 2>/dev/null | tail -1);
            report_rc=\$?;
        fi;
        if [ \"\$nodeenable_rc\" -eq 0 ] && [ \"\$report_rc\" -eq 0 ] && echo \"\$report\" | grep -q 'addon=node-on' && echo \"\$report\" | grep -q 'event=active'; then
            if ! rm -rf \"\$old\" 2>/dev/null; then echo STAGED_NODE_CLEANUP_FAILED; exit 28; fi;
            printf 'NODE_REPORT=%s\\n' \"\$report\";
            echo STAGED_NODE_OK;
            hwprobe_rc=1;
            if cd \"\$active/functions\"; then
                MERV_NODE_CONTEXT=1 sh ./hw_probe.sh >/dev/null 2>&1;
                hwprobe_rc=\$?;
            fi;
            if [ \"\$hwprobe_rc\" -eq 0 ] && . \"\$active/settings/lib_json.sh\" 2>/dev/null; then
                printf 'PRODUCTID=%s\\n' \"\$(json_get_section_value Hardware PRODUCTID \"\$active/settings/settings.json\" 2>/dev/null)\";
                printf 'MAX_ETH_PORTS=%s\\n' \"\$(json_get_section_value Hardware MAX_ETH_PORTS \"\$active/settings/settings.json\" 2>/dev/null)\";
                printf 'LAN_PORT_LABEL_OVERRIDES=%s\\n' \"\$(json_get_section_value Hardware LAN_PORT_LABEL_OVERRIDES \"\$active/settings/settings.json\" 2>/dev/null)\";
            else
                echo HWPROBE_FAILED;
            fi;
            exit 0;
        fi;
        node_msg=\$(printf '%s\\n' \"\$nodeenable_out\" | tail -n 1 | tr -cd 'A-Za-z0-9_.,:=-' | cut -c 1-120);
        printf 'STAGED_NODE_FAIL nodeenable_rc=%s report_rc=%s report=%s detail=%s\\n' \"\$nodeenable_rc\" \"\$report_rc\" \"\$report\" \"\$node_msg\";
        if ! rm -rf \"\$stage\" 2>/dev/null; then exit 26; fi;
        mv \"\$active\" \"\$stage\" 2>/dev/null || exit 26;
        if [ \"\$had_old\" = 1 ]; then
            if mv \"\$old\" \"\$active\" 2>/dev/null; then
                if ! cd \"\$active/functions\" 2>/dev/null || ! MERV_NODE_CONTEXT=1 sh ./mervlan_boot.sh nodeenable --local >/dev/null 2>&1; then exit 28; fi;
                if ! rm -rf \"\$stage\" 2>/dev/null; then exit 29; fi;
                printf 'STAGED_NODE_ROLLBACK_OK\\n'; exit 0;
            fi;
            exit 27;
        fi;
        if ! mv \"\$stage\" \"\$active\" 2>/dev/null; then exit 26; fi;
        printf 'STAGED_NODE_ROLLBACK_OK\\n'; exit 0
    "
    _asn_result=$(merv_ssh_exec "$_asn_id" "$_asn_ip" "$_asn_cmd" 2>/dev/null)
    _asn_rc=$?
    if echo "$_asn_result" | grep -q STAGED_NODE_OK; then
        SYNC_NODE_ACTIVATION_OUTPUT="$_asn_result"
        export SYNC_NODE_ACTIVATION_OUTPUT
        return 0
    fi
    if echo "$_asn_result" | grep -q STAGED_NODE_FAIL; then
        _asn_diag=$(echo "$_asn_result" | grep STAGED_NODE_FAIL | tail -1 | tr -cd 'A-Za-z0-9_=.,:-' | cut -c 1-220)
        MERV_SSH_LAST_REASON="node-activation-failed"
        MERV_SSH_LAST_DETAIL="NODE$_asn_id staged activation failed (ssh_rc=$_asn_rc) $_asn_diag"
    fi
    return 1
}

activate_staged_node_settings_only() {
    _asns_ip="$1"
    _asns_id="$2"
    _asns_stage="$3"

    _asns_cmd="
        base=\"\${MERV_BASE:-/jffs/addons/mervlan}\";
        target=\"\$base/settings/settings.json\";
        pub_dir=\"/www/user/mervlan/settings\";
        pub_target=\"\$pub_dir/settings.json\";
        staged=\"$_asns_stage/settings/settings.json\";
        temp=\"\$target.sync.${_asns_id}.\$\$\";
        test -f \"\$staged\" || exit 21;
        mkdir -p \"\$base/settings\" 2>/dev/null || exit 23;
        rm -f \"\$temp\" 2>/dev/null || :;
        cp \"\$staged\" \"\$temp\" || exit 25;
        chmod 600 \"\$temp\" 2>/dev/null || :;
        test -s \"\$temp\" || { rm -f \"\$temp\" 2>/dev/null || :; exit 26; };
        cmp -s \"\$staged\" \"\$temp\" || { rm -f \"\$temp\" 2>/dev/null || :; exit 27; };
        mv \"\$temp\" \"\$target\" || { rm -f \"\$temp\" 2>/dev/null || :; exit 28; };
        cmp -s \"\$staged\" \"\$target\" || exit 29;
        if [ -d \"\$pub_dir\" ]; then
            cp \"\$target\" \"\$pub_target\" 2>/dev/null;
            chmod 644 \"\$pub_target\" 2>/dev/null || :;
        fi;
        rm -rf \"$_asns_stage\" 2>/dev/null || :;
        echo STAGED_SETTINGS_OK;
        exit 0;
    "
    _asns_result=$(merv_ssh_exec "$_asns_id" "$_asns_ip" "$_asns_cmd" 2>/dev/null)
    _asns_rc=$?
    if echo "$_asns_result" | grep -q STAGED_SETTINGS_OK; then
        return 0
    fi
    MERV_SSH_LAST_REASON="settings-activation-failed"
    MERV_SSH_LAST_DETAIL="NODE$_asns_id settings activation failed (ssh_rc=$_asns_rc)"
    return 1
}

# ========================================================================== #
# MAIN SYNCHRONIZATION LOOP — Iterate nodes and orchestrate copy workflow    #
# ========================================================================== #

sync_node_worker() {
    node_id="$1"
    node_canonical_ip="$2"
    node_ip="$node_canonical_ip"
    if [ -n "${MERV_SSH_SYNC_ENDPOINT_MAP:-}" ]; then
        node_ip=$(merv_node_endpoint_candidates "$node_id" "${SETTINGS_FILE:-}" 2>/dev/null | sed -n '1p') || {
            error -c cli,vlan "Sync NODE${node_id}: verified endpoint map could not be consumed"
            return 1
        }
        [ -n "$node_ip" ] || {
            error -c cli,vlan "Sync NODE${node_id}: verified endpoint map selected no endpoint"
            return 1
        }
    fi
    MERV_NODE_ENDPOINT_SELECTED="$node_ip"
    MERV_NODE_ENDPOINT_EXPECTED="$node_ip"
    MERV_NODE_ENDPOINT_FALLBACK=0
    export MERV_NODE_ENDPOINT_SELECTED MERV_NODE_ENDPOINT_EXPECTED MERV_NODE_ENDPOINT_FALLBACK
    # A pool normally forks one process per node, but reset these worker-local
    # shortcuts so an alternate caller cannot inherit an earlier node's state.
    unset MERV_SSH_SKIP_PING
    SYNC_STAGE_DIRS_PREPARED=0
    SYNC_NODE_ACTIVATION_OUTPUT=""
    export SYNC_STAGE_DIRS_PREPARED SYNC_NODE_ACTIVATION_OUTPUT
    info -c cli,vlan "Processing node: NODE${node_id} (canonical=$node_canonical_ip endpoint=$node_ip)"
    dbg_log "Beginning node synchronization"
    dbg_var node_ip DRY_RUN
    
    # Test the first verified SSH connection. merv_ssh_test performs the
    # bounded reachability, pinned-host, key, and authentication checks.
    if ! test_ssh_connection "$node_ip" "$node_id"; then
        merv_ssh_skip_log "$node_id" "$node_ip" "SSH connection test"
        return 1
    fi
    
    info -c cli,vlan "✓ SSH connection successful to NODE${node_id} ($node_ip)"
    # All following calls remain pinned and time-bounded. They skip only the
    # duplicate ICMP probe because the authenticated connection above proved
    # reachability for this isolated node worker.
    MERV_SSH_SKIP_PING=1
    export MERV_SSH_SKIP_PING

    REMOTE_MERV_BASE="/jffs/addons/mervlan_backups/.mervlan.new.${SYNC_RUN_ID}.${node_id}"
    REMOTE_MERV_OLD="/jffs/addons/mervlan_backups/.mervlan.old.${SYNC_RUN_ID}.${node_id}"
    
    # Create base remote directories (addon path + runtime folders + the addon
    # subdirs that tar will extract into — pre-creating them means batch extract
    # never fails on a missing path, and we drop the per-file dir-creation SSH).
    REMOTE_DEV_TOOLS_DIRS=""
    if [ -n "$DEV_TOOLS_FILES_TO_COPY" ]; then
        REMOTE_DEV_TOOLS_DIRS="'$REMOTE_MERV_BASE/dev-tools/tests/router' '$REMOTE_MERV_BASE/dev-tools/safety'"
    fi
    remote_mkdir_cmd="mkdir -p '/jffs/addons/mervlan_backups'; rm -rf '$REMOTE_MERV_BASE' '$REMOTE_MERV_OLD' 2>/dev/null || exit 70; mkdir -p '$REMOTE_MERV_BASE/settings' '$REMOTE_MERV_BASE/functions' '$REMOTE_MERV_BASE/templates' $REMOTE_DEV_TOOLS_DIRS '$TMPDIR' '$LOGDIR' '$LOCKDIR' '$RESULTDIR' '$CHANGES' '$COLLECTDIR'"
    dbg_log "Ensuring base directories on node"
    dbg_var node_ip remote_mkdir_cmd
    if [ "$DRY_RUN" = "yes" ]; then
        info -c cli,vlan "[DRY-RUN] Would ensure remote directories on NODE${node_id} ($node_ip)"
    else
        if ! prepare_remote_sync_stage "$node_ip" "$node_id" "$remote_mkdir_cmd"; then
            return 1
        fi
        SYNC_STAGE_DIRS_PREPARED=1
        export SYNC_STAGE_DIRS_PREPARED
    fi
    
    # Debug: show remote directory before copying (optional)
    if [ "$SYNC_DEBUG_PRE" = "1" ]; then
        debug_remote_files "$node_ip" "before" "$node_id"
    fi
    
    # Copy files. Everything except settings/settings.json goes in ONE tar
    # stream (single SSH); settings.json keeps its own atomic path because it
    # gets a trunk-rewrite + md5 breadcrumb before transfer. Pre-flight every
    # batch entry so a missing local file is reported up front and BusyBox tar
    # (which can exit 0 on absent inputs) never silently skips it.
    file_success=true
    _batch_files=""
    for file in $FILES_TO_COPY; do
        [ "$file" = "settings/settings.json" ] && continue
        if [ ! -f "$MERV_BASE/$file" ]; then
            error -c cli,vlan "✗ Local file not found: $MERV_BASE/$file"
            file_success=false
            continue
        fi
        _batch_files="$_batch_files $file"
    done

    if [ "$file_success" = "true" ] && [ -n "$_batch_files" ]; then
        if ! copy_batch_to_node "$node_ip" "$node_id" "$_batch_files"; then
            file_success=false
        fi
    fi

    # settings/settings.json: keep the dedicated atomic copy path (trunk rewrite
    # + breadcrumb md5) — only copy if it is part of the manifest.
    if echo "$FILES_TO_COPY" | grep -q "settings/settings.json"; then
        if [ -f "$MERV_BASE/settings/settings.json" ]; then
            if ! copy_file_to_node "$node_ip" "settings/settings.json" "$node_id"; then
                file_success=false
            fi
        else
            error -c cli,vlan "✗ Local file not found: $MERV_BASE/settings/settings.json"
            file_success=false
        fi
    fi
    
    # Debug: show remote directory after copying (default on)
    if [ "$SYNC_DEBUG_POST" = "1" ]; then
        debug_remote_files "$node_ip" "after" "$node_id"
    fi
    
    if [ "$DRY_RUN" = "yes" ]; then
        info -c cli,vlan "[DRY-RUN] Skipping verification, permission updates, and nodeenable for NODE${node_id} ($node_ip)"
        info -c cli,vlan "[DRY-RUN] Simulated synchronization complete for NODE${node_id} ($node_ip)"
        info -c cli,vlan "--- Completed node: NODE${node_id} ($node_ip) ---"
        echo ""
        return 0
    fi

    # Verify files were copied
    if [ "$file_success" = "true" ]; then
        verification_success=true
        # Every staged file is verified independently inside one SSH command.
        # settings/settings.json contributes its trunk-safe breadcrumb to this
        # same exact pass rather than opening another Dropbear connection.
        _verify_files="$_batch_files"
        if echo "$FILES_TO_COPY" | grep -q "settings/settings.json"; then
            _verify_files="$_verify_files settings/settings.json"
        fi
        if [ -n "$_verify_files" ]; then
            if ! verify_batch_on_node "$node_ip" "$node_id" "$_verify_files"; then
                verification_success=false
            fi
        fi

        if [ "$verification_success" = "true" ]; then
            info -c cli,vlan "✓ All files verified on NODE${node_id} ($node_ip)"

            if [ "$SETTINGS_ONLY" -eq 1 ]; then
                # The shared local builder already writes IS_NODE/NODE_ID.
                # Settings-only stages contain no runtime libraries, so the
                # full-sync remote node-flag helper must not be invoked here.
                if activate_staged_node_settings_only "$node_ip" "$node_id" "$REMOTE_MERV_BASE"; then
                    info -c cli,vlan "✓ Node settings synchronized on NODE${node_id} ($node_ip)"
                else
                    merv_ssh_skip_log "$node_id" "$node_ip" "settings activation"
                    if ! cleanup_remote_stage "$node_ip" "$node_id" "$REMOTE_MERV_BASE" "$REMOTE_MERV_OLD"; then
                        error -c cli,vlan "Could not clean the failed NODE${node_id} staging tree"
                    fi
                    return 1
                fi
            else
                # Full sync marks the staged settings after all curated
                # runtime files have been verified, then activates the tree.
                if ! set_node_flag_remote "$node_ip" "$node_id"; then
                    if ! cleanup_remote_stage "$node_ip" "$node_id" "$REMOTE_MERV_BASE" "$REMOTE_MERV_OLD"; then
                        error -c cli,vlan "Could not clean the failed NODE${node_id} staging tree"
                    fi
                    return 1
                fi
                if activate_staged_node "$node_ip" "$node_id" "$REMOTE_MERV_BASE" "$REMOTE_MERV_OLD"; then
                    info -c cli,vlan "✓ Staged activation verified on NODE${node_id} ($node_ip)"
                    report_line=$(printf '%s\n' "$SYNC_NODE_ACTIVATION_OUTPUT" | sed -n 's/^NODE_REPORT=//p' | tail -n 1 | tr -d '\r\n')
                    [ -n "$report_line" ] && info -c cli,vlan "NODE${node_id} ($node_ip) report: $report_line"
                    if ! pull_node_hardware "$node_ip" "$node_id" "$SYNC_NODE_ACTIVATION_OUTPUT"; then
                        warn -c cli,vlan "NODE${node_id} hardware metadata could not be refreshed after synchronization"
                    fi
                else
                    merv_ssh_skip_log "$node_id" "$node_ip" "staged activation"
                    if ! cleanup_remote_stage "$node_ip" "$node_id" "$REMOTE_MERV_BASE" "$REMOTE_MERV_OLD"; then
                        error -c cli,vlan "Could not clean the failed NODE${node_id} staging tree"
                    fi
                    return 1
                fi
            fi
        else
            error -c cli,vlan "✗ File verification failed for NODE${node_id} ($node_ip)"
            if ! cleanup_remote_stage "$node_ip" "$node_id" "$REMOTE_MERV_BASE" "$REMOTE_MERV_OLD"; then
                error -c cli,vlan "Could not clean the failed NODE${node_id} staging tree"
            fi
            return 1
        fi
    else
        if ! cleanup_remote_stage "$node_ip" "$node_id" "$REMOTE_MERV_BASE" "$REMOTE_MERV_OLD"; then
            error -c cli,vlan "Could not clean the failed NODE${node_id} staging tree"
        fi
        return 1
    fi
    
    info -c cli,vlan "--- Completed node: $node_ip (NODE${node_id}) ---"
    echo ""
    return 0
}

# Publish only copies of selected worker logs for the WebUI.  The public tree
# never exposes worker metadata, SSH temp files, status results, or process
# identity files.  This function is called by the parent progress hook only.
sync_copy_worker_log_for_view() {
    _scwv_source="$1"
    _scwv_dest="$2"
    [ -f "$_scwv_source" ] || return 0
    _scwv_tmp="$_scwv_dest.new.$$"
    cp "$_scwv_source" "$_scwv_tmp" 2>/dev/null || { rm -f "$_scwv_tmp"; return 1; }
    chmod 644 "$_scwv_tmp" 2>/dev/null || { rm -f "$_scwv_tmp"; return 1; }
    mv "$_scwv_tmp" "$_scwv_dest" 2>/dev/null || { rm -f "$_scwv_tmp"; return 1; }
}

sync_publish_worker_log_view() {
    _spwv_root="$1"
    _spwv_phase="$2"
    [ "$_spwv_phase" = sync ] || return 0
    _spwv_job="${_spwv_root##*/}"
    mnj_safe_token "$_spwv_job" || return 1
    _spwv_view_root="$TMPDIR/logs/node_workers"
    _spwv_job_view="$_spwv_view_root/$_spwv_job"
    mkdir -p "$_spwv_job_view" 2>/dev/null || return 1
    chmod 755 "$_spwv_view_root" "$_spwv_job_view" 2>/dev/null || return 1
    _spwv_json="$_spwv_view_root/.index.$$.new"
    umask 077
    printf '%s' '{"format_version":1,"jobs":[' > "$_spwv_json" || return 1
    _spwv_first=1
    while IFS=' ' read -r _spwv_node _spwv_ip _spwv_extra || [ -n "$_spwv_node" ]; do
        [ -z "$_spwv_extra" ] || continue
        merv_is_valid_node_id "$_spwv_node" || { rm -f "$_spwv_json"; return 1; }
        _spwv_node_dir="$_spwv_root/node_$_spwv_node"
        _spwv_view_node="$_spwv_job_view/node_$_spwv_node"
        mkdir -p "$_spwv_view_node" 2>/dev/null || { rm -f "$_spwv_json"; return 1; }
        chmod 755 "$_spwv_view_node" 2>/dev/null || { rm -f "$_spwv_json"; return 1; }
        sync_copy_worker_log_for_view "$_spwv_node_dir/cli.log" "$_spwv_view_node/cli.json" || { rm -f "$_spwv_json"; return 1; }
        sync_copy_worker_log_for_view "$_spwv_node_dir/vlan.log" "$_spwv_view_node/vlan.json" || { rm -f "$_spwv_json"; return 1; }
        sync_copy_worker_log_for_view "$_spwv_node_dir/stdout.log" "$_spwv_view_node/stdout.json" || { rm -f "$_spwv_json"; return 1; }
        _spwv_state=running
        if mnj_result_validate "$_spwv_node_dir/result" "$_spwv_node" sync; then
            _spwv_state="$MNJ_RESULT_STATE"
        fi
        [ "$_spwv_first" -eq 1 ] || printf '%s' ',' >> "$_spwv_json"
        printf '%s' "{\"job\":\"$_spwv_job\",\"phase\":\"sync\",\"node_id\":\"$_spwv_node\",\"state\":\"$_spwv_state\",\"cli\":\"$_spwv_job/node_$_spwv_node/cli.json\",\"vlan\":\"$_spwv_job/node_$_spwv_node/vlan.json\",\"stdout\":\"$_spwv_job/node_$_spwv_node/stdout.json\"}" >> "$_spwv_json" || { rm -f "$_spwv_json"; return 1; }
        _spwv_first=0
    done < "$_sync_nodes_file"
    printf '%s\n' ']}' >> "$_spwv_json" || { rm -f "$_spwv_json"; return 1; }
    chmod 644 "$_spwv_json" 2>/dev/null || { rm -f "$_spwv_json"; return 1; }
    mv "$_spwv_json" "$_spwv_view_root/index.json" 2>/dev/null || { rm -f "$_spwv_json"; return 1; }
}

# Keep the WebUI worker-log projection bounded without touching live or
# unvalidated worker state.  A run becomes eligible for rotation only after
# the parent has validated every node result and atomically written .run_state.
sync_worker_log_archive() {
    _swla_state="$1"
    _swla_current="$2"
    _swla_root="$TMPDIR/logs/node_workers"
    [ -d "$_swla_root" ] || return 0
    case "$_swla_state" in ok|failed|timeout) ;; *) return 1 ;; esac
    mnj_safe_token "$_swla_current" || return 1
    _swla_now=$(date +%s 2>/dev/null || printf 0)
    case "$_swla_now" in ''|*[!0-9]*) return 1 ;; esac
    _swla_marker="$_swla_root/$_swla_current/.run_state"
    [ -d "$_swla_root/$_swla_current" ] || return 1
    _swla_marker_tmp="$_swla_marker.new.$$"
    printf 'state=%s\ncompleted_epoch=%s\n' "$_swla_state" "$_swla_now" > "$_swla_marker_tmp" || return 1
    chmod 600 "$_swla_marker_tmp" 2>/dev/null || {
        if ! rm -f "$_swla_marker_tmp"; then warn -c cli,vlan "Could not remove failed worker-log marker $_swla_marker_tmp"; fi
        return 1
    }
    mv "$_swla_marker_tmp" "$_swla_marker" || { rm -f "$_swla_marker_tmp"; return 1; }

    # Migrate pre-rotation projections only when their matching private job
    # still contains a validated terminal result for every published node.
    # Missing private state, malformed results, and partial runs remain
    # untouched as required for safe diagnosis.
    for _swla_legacy_dir in "$_swla_root"/sync.*; do
        [ -d "$_swla_legacy_dir" ] || continue
        _swla_legacy_job=${_swla_legacy_dir##*/}
        case "$_swla_legacy_job" in sync.[0-9]*-[0-9]*) ;; *) continue ;; esac
        [ ! -f "$_swla_legacy_dir/.run_state" ] || continue
        _swla_private="$TMPDIR/node_jobs/$_swla_legacy_job"
        [ -d "$_swla_private" ] || continue
        _swla_legacy_nodes=0; _swla_legacy_valid=1; _swla_legacy_failed=0
        for _swla_legacy_node_dir in "$_swla_legacy_dir"/node_*; do
            [ -d "$_swla_legacy_node_dir" ] || continue
            _swla_legacy_node=${_swla_legacy_node_dir##*/node_}
            merv_is_valid_node_id "$_swla_legacy_node" || { _swla_legacy_valid=0; continue; }
            _swla_legacy_nodes=$((_swla_legacy_nodes + 1))
            if ! mnj_result_validate "$_swla_private/node_$_swla_legacy_node/result" "$_swla_legacy_node" sync; then
                _swla_legacy_valid=0
            elif [ "$MNJ_RESULT_STATE" != ok ]; then
                _swla_legacy_failed=1
            fi
        done
        [ "$_swla_legacy_nodes" -gt 0 ] && [ "$_swla_legacy_valid" -eq 1 ] || continue
        _swla_legacy_state=ok
        [ "$_swla_legacy_failed" -eq 1 ] && _swla_legacy_state=failed
        _swla_legacy_marker="$_swla_legacy_dir/.run_state"
        _swla_legacy_tmp="$_swla_legacy_marker.new.$$"
        printf 'state=%s\ncompleted_epoch=%s\n' "$_swla_legacy_state" "$_swla_now" > "$_swla_legacy_tmp" || continue
        if ! chmod 600 "$_swla_legacy_tmp" 2>/dev/null; then
            if ! rm -f "$_swla_legacy_tmp"; then warn -c cli,vlan "Could not remove failed legacy worker-log marker $_swla_legacy_tmp"; fi
            continue
        fi
        mv "$_swla_legacy_tmp" "$_swla_legacy_marker" || { rm -f "$_swla_legacy_tmp"; continue; }
        if ! rm -rf "$_swla_private" 2>/dev/null; then
            warn -c cli,vlan "Could not remove migrated private worker job $_swla_private"
            return 1
        fi
    done

    _swla_list="$_swla_root/.runs.$$"
    _swla_json="$_swla_root/.index.$$.new"
    : > "$_swla_list" || return 1
    for _swla_dir in "$_swla_root"/sync.*; do
        [ -d "$_swla_dir" ] || continue
        _swla_job=${_swla_dir##*/}
        case "$_swla_job" in sync.[0-9]*-[0-9]*) ;; *) continue ;; esac
        case "$_swla_job" in *..*|*[!A-Za-z0-9._-]*) continue ;; esac
        printf '%s\n' "$_swla_job" >> "$_swla_list"
    done
    sort -r "$_swla_list" > "$_swla_list.sorted" 2>/dev/null || {
        rm -f "$_swla_list"; return 1
    }
    printf '%s' '{"format_version":1,"jobs":[' > "$_swla_json" || return 1
    _swla_first=1; _swla_kept=0; _swla_seen_terminal=0; _swla_archive_failed=0
    while IFS= read -r _swla_job || [ -n "$_swla_job" ]; do
        _swla_job_dir="$_swla_root/$_swla_job"
        _swla_state_file="$_swla_job_dir/.run_state"
        _swla_run_state=""
        _swla_terminal=0
        if [ -f "$_swla_state_file" ]; then
            _swla_run_state=$(sed -n 's/^state=//p' "$_swla_state_file" | sed -n '1p')
        fi
        case "$_swla_run_state" in ok|failed|timeout)
            _swla_terminal=1
            ;;
          *)
            # Only the current run may be shown as live. Unknown/old live
            # state is retained on disk but excluded from the public index.
            [ "$_swla_job" = "$_swla_current" ] || continue
            _swla_run_state=running; _swla_terminal=0
            ;;
        esac
        if [ "$_swla_terminal" -eq 1 ]; then
            _swla_seen_terminal=$((_swla_seen_terminal + 1))
            [ "$_swla_seen_terminal" -le 3 ] || {
                # This directory is a validated terminal projection and is
                # safe to remove after its newer three peers are indexed.
                if ! rm -rf "$_swla_job_dir" 2>/dev/null; then
                    warn -c cli,vlan "Could not remove archived worker-log job $_swla_job_dir"
                    _swla_archive_failed=1
                fi
                continue
            }
        fi
        for _swla_node_dir in "$_swla_job_dir"/node_*; do
            [ -d "$_swla_node_dir" ] || continue
            _swla_node=${_swla_node_dir##*/node_}
            merv_is_valid_node_id "$_swla_node" || continue
            _swla_cli="$_swla_job/node_$_swla_node/cli.json"
            _swla_vlan="$_swla_job/node_$_swla_node/vlan.json"
            _swla_stdout="$_swla_job/node_$_swla_node/stdout.json"
            [ -f "$_swla_node_dir/cli.json" ] || continue
            [ -f "$_swla_node_dir/vlan.json" ] || continue
            [ -f "$_swla_node_dir/stdout.json" ] || continue
            [ "$_swla_first" -eq 1 ] || printf '%s' ',' >> "$_swla_json"
            printf '%s' "{\"job\":\"$_swla_job\",\"phase\":\"sync\",\"node_id\":\"$_swla_node\",\"state\":\"$_swla_run_state\",\"cli\":\"$_swla_cli\",\"vlan\":\"$_swla_vlan\",\"stdout\":\"$_swla_stdout\"}" >> "$_swla_json" || return 1
            _swla_first=0
        done
        _swla_kept=$((_swla_kept + 1))
    done < "$_swla_list.sorted"
    printf '%s\n' ']}' >> "$_swla_json" || return 1
    if ! chmod 644 "$_swla_json" 2>/dev/null; then
        if ! rm -f "$_swla_json"; then warn -c cli,vlan "Could not remove failed worker-log index $_swla_json"; fi
        return 1
    fi
    mv "$_swla_json" "$_swla_root/index.json" || return 1
    if ! rm -f "$_swla_list" "$_swla_list.sorted"; then
        warn -c cli,vlan "Could not remove worker-log archive index scratch files"
        return 1
    fi
    [ "$_swla_archive_failed" -eq 0 ]
}

sync_prune_private_worker_jobs() {
    _sppw_current="$1"
    _sppw_root="$TMPDIR/node_jobs"
    [ -d "$_sppw_root" ] || return 0
    _sppw_list="$_sppw_root/.sync_runs.$$"
    for _sppw_dir in "$_sppw_root"/sync.*; do
        [ -d "$_sppw_dir" ] || continue
        _sppw_job=${_sppw_dir##*/}
        case "$_sppw_job" in sync.[0-9]*-[0-9]*) ;; *) continue ;; esac
        case "$_sppw_job" in *..*|*[!A-Za-z0-9._-]*) continue ;; esac
        [ "$_sppw_job" = "$_sppw_current" ] && continue
        printf '%s\n' "$_sppw_job" >> "$_sppw_list"
    done
    [ -f "$_sppw_list" ] || return 0
    sort -r "$_sppw_list" > "$_sppw_list.sorted" 2>/dev/null || {
        rm -f "$_sppw_list"; return 1
    }
    _sppw_kept=0
    _sppw_archive_failed=0
    while IFS= read -r _sppw_job || [ -n "$_sppw_job" ]; do
        _sppw_dir="$_sppw_root/$_sppw_job"
        _sppw_valid=1; _sppw_nodes=0
        for _sppw_node_dir in "$_sppw_dir"/node_*; do
            [ -d "$_sppw_node_dir" ] || continue
            _sppw_node=${_sppw_node_dir##*/node_}
            merv_is_valid_node_id "$_sppw_node" || { _sppw_valid=0; continue; }
            _sppw_nodes=$((_sppw_nodes + 1))
            mnj_result_validate "$_sppw_node_dir/result" "$_sppw_node" sync || _sppw_valid=0
        done
        [ "$_sppw_nodes" -gt 0 ] && [ "$_sppw_valid" -eq 1 ] || continue
        _sppw_kept=$((_sppw_kept + 1))
        if [ "$_sppw_kept" -gt 3 ] && ! rm -rf "$_sppw_dir" 2>/dev/null; then
            warn -c cli,vlan "Could not remove archived private worker job $_sppw_dir"
            _sppw_archive_failed=1
        fi
    done < "$_sppw_list.sorted"
    if ! rm -f "$_sppw_list" "$_sppw_list.sorted"; then
        warn -c cli,vlan "Could not remove private worker-job index scratch files"
        _sppw_archive_failed=1
    fi
    [ "$_sppw_archive_failed" -eq 0 ]
}

# Relay newly appended worker CLI lines to the detailed VLAN log.  The CLI
# remains concise, while this preserves live sync visibility without allowing
# worker processes to write either shared log directly.
sync_relay_worker_progress() {
    _srwp_root="$1"
    _srwp_phase="$2"
    [ "$_srwp_phase" = sync ] || return 0
    while IFS=' ' read -r _srwp_node _srwp_ip _srwp_extra || [ -n "$_srwp_node" ]; do
        [ -z "$_srwp_extra" ] || continue
        _srwp_log="$_srwp_root/node_$_srwp_node/cli.log"
        _srwp_cursor="$_srwp_root/.vlan_cursor.node_$_srwp_node"
        [ -f "$_srwp_log" ] || continue
        _srwp_seen=$(cat "$_srwp_cursor" 2>/dev/null || printf 0)
        case "$_srwp_seen" in ''|*[!0-9]*) _srwp_seen=0 ;; esac
        _srwp_total=$(wc -l < "$_srwp_log" 2>/dev/null | tr -d ' ')
        case "$_srwp_total" in ''|*[!0-9]*) continue ;; esac
        [ "$_srwp_total" -gt "$_srwp_seen" ] 2>/dev/null || continue
        _srwp_start=$((_srwp_seen + 1))
        sed -n "${_srwp_start},${_srwp_total}p" "$_srwp_log" | while IFS= read -r _srwp_line || [ -n "$_srwp_line" ]; do
            [ -n "$_srwp_line" ] && info -c vlan "Sync NODE$_srwp_node: $_srwp_line"
        done
        _srwp_tmp="$_srwp_cursor.new.$$"
        printf '%s\n' "$_srwp_total" > "$_srwp_tmp" && mv "$_srwp_tmp" "$_srwp_cursor" || rm -f "$_srwp_tmp"
    done < "$_sync_nodes_file"
}

sync_pool_progress() {
    sync_publish_worker_log_view "$1" "$2" || warn -c vlan "Sync: unable to publish worker-log view"
    sync_relay_worker_progress "$1" "$2" || warn -c vlan "Sync: unable to relay worker progress"
    sync_progress_pool_update "$1"
}

info -c cli,vlan "Starting file synchronization..."
overall_success=true
SYNC_RUN_ID="$(date +%s 2>/dev/null || printf 0)-$$"
_sync_nodes_file="$TMPDIR/sync_nodes.$SYNC_RUN_ID"
printf '%s\n' "$NODE_IPS" > "$_sync_nodes_file"
if ! mnj_nodes_validate "$_sync_nodes_file"; then
    error -c cli,vlan "Sync: invalid or duplicate node ID/IP entry"
    merv_action_progress_fail "Configured node list is invalid or contains duplicates"
    exit 1
fi
SYNC_PROGRESS_TOTAL=$(wc -l < "$_sync_nodes_file" 2>/dev/null | tr -d ' ')
case "$SYNC_PROGRESS_TOTAL" in ''|*[!0-9]*) SYNC_PROGRESS_TOTAL=0 ;; esac
if [ "$SYNC_PROGRESS_TOTAL" -gt 0 ] 2>/dev/null; then
    if [ "$DRY_RUN" = "yes" ]; then
        merv_action_progress_update sync 0 "$SYNC_PROGRESS_TOTAL" 15 \
            "Dry-run: ready to simulate synchronization of $SYNC_PROGRESS_TOTAL node(s)"
    else
        merv_action_progress_update sync 0 "$SYNC_PROGRESS_TOTAL" 15 \
            "Ready to synchronize $SYNC_PROGRESS_TOTAL configured node(s)"
    fi
fi
_sync_jobs_root="$TMPDIR/node_jobs/sync.$SYNC_RUN_ID"

sync_progress_pool_update() {
    [ "${MERV_ACTION_PROGRESS_ENABLED:-0}" -eq 1 ] || return 0
    [ "$SYNC_PROGRESS_TOTAL" -gt 0 ] 2>/dev/null || return 0
    _sppu_completed=0
    _sppu_failed=0
    _sppu_last_node=""
    _sppu_last_state=""
    _sppu_active_count=0
    _sppu_active_nodes=""
    while IFS=' ' read -r _sppu_node _sppu_ip _sppu_extra || [ -n "$_sppu_node" ]; do
        [ -z "$_sppu_extra" ] || continue
        if mnj_result_validate "$1/node_$_sppu_node/result" "$_sppu_node" sync; then
            case "$MNJ_RESULT_STATE" in
                ok) _sppu_completed=$((_sppu_completed + 1)); _sppu_last_node="$_sppu_node"; _sppu_last_state=ok ;;
                failed|timeout) _sppu_failed=$((_sppu_failed + 1)); _sppu_last_node="$_sppu_node"; _sppu_last_state=failed ;;
            esac
        elif [ -d "$1/node_$_sppu_node" ]; then
            _sppu_active_count=$((_sppu_active_count + 1))
            if [ "$_sppu_active_count" -le 3 ]; then
                if [ -n "$_sppu_active_nodes" ]; then
                    _sppu_active_nodes="$_sppu_active_nodes,"
                fi
                _sppu_active_nodes="$_sppu_active_nodes NODE$_sppu_node"
            fi
        fi
    done < "$_sync_nodes_file"
    _sppu_terminal=$((_sppu_completed + _sppu_failed))
    _sppu_now=$(date +%s 2>/dev/null || printf 0)
    case "$_sppu_now" in
        ''|*[!0-9]*) _sppu_now=0 ;;
    esac
    _sppu_heartbeat_due=0
    if [ "$SYNC_PROGRESS_HEARTBEAT_LAST" -eq 0 ] ||
       [ "$_sppu_now" -ge $((SYNC_PROGRESS_HEARTBEAT_LAST + SYNC_PROGRESS_HEARTBEAT_SEC)) ] 2>/dev/null; then
        _sppu_heartbeat_due=1
    fi
    if [ "$_sppu_terminal" -gt "$SYNC_PROGRESS_TERMINAL" ] 2>/dev/null ||
       [ "$_sppu_heartbeat_due" -eq 1 ]; then
        _sppu_percent=$((15 + (65 * _sppu_terminal / SYNC_PROGRESS_TOTAL)))
        [ "$_sppu_percent" -le 80 ] 2>/dev/null || _sppu_percent=80
        _sppu_elapsed=0
        if [ "$_sppu_now" -ge "$SYNC_PROGRESS_STARTED_EPOCH" ] 2>/dev/null; then
            _sppu_elapsed=$((_sppu_now - SYNC_PROGRESS_STARTED_EPOCH))
        fi
        if [ "$_sppu_terminal" -gt "$SYNC_PROGRESS_TERMINAL" ] 2>/dev/null &&
           [ -n "$_sppu_last_node" ]; then
            if [ "$_sppu_last_state" != ok ]; then
                _sppu_message="NODE$_sppu_last_node reported a failure; $_sppu_terminal of $SYNC_PROGRESS_TOTAL nodes finished"
            else
                _sppu_message="NODE$_sppu_last_node complete; $_sppu_terminal of $SYNC_PROGRESS_TOTAL nodes finished"
            fi
        elif [ "$_sppu_active_count" -gt 0 ] 2>/dev/null; then
            if [ "$_sppu_active_count" -gt 3 ] 2>/dev/null; then
                _sppu_active_nodes="$_sppu_active_nodes and $((_sppu_active_count - 3)) more"
            fi
            _sppu_message="Still working on$_sppu_active_nodes; $_sppu_terminal of $SYNC_PROGRESS_TOTAL nodes finished (${_sppu_elapsed}s)"
        else
            _sppu_message="Synchronizing nodes; $_sppu_terminal of $SYNC_PROGRESS_TOTAL nodes finished (${_sppu_elapsed}s)"
        fi
        [ "$DRY_RUN" = "yes" ] && _sppu_message="Dry-run: $_sppu_message"
        merv_action_progress_update sync "$_sppu_terminal" "$SYNC_PROGRESS_TOTAL" \
            "$_sppu_percent" "$_sppu_message"
        SYNC_PROGRESS_TERMINAL="$_sppu_terminal"
        [ "$_sppu_now" -gt 0 ] 2>/dev/null && SYNC_PROGRESS_HEARTBEAT_LAST="$_sppu_now"
    fi
}

merv_action_progress_update sync 0 "$SYNC_PROGRESS_TOTAL" 15 \
    "Synchronizing configured nodes..."
while IFS=' ' read -r node_id node_ip _sync_extra || [ -n "$node_id" ]; do
    [ -z "$_sync_extra" ] || continue
    info -c cli "Sync NODE${node_id} ($node_ip): queued; detailed progress is in the VLAN log"
done < "$_sync_nodes_file"
MNJ_POOL_PROGRESS_HOOK=sync_pool_progress
if ! mnj_pool_run "$_sync_jobs_root" sync "${MERV_NODE_PARALLELISM:-}" "${MERV_NODE_SYNC_MAX_SEC:-720}" "$_sync_nodes_file" sync_node_worker; then
    overall_success=false
fi
MNJ_POOL_PROGRESS_HOOK=""
sync_pool_progress "$_sync_jobs_root" sync || {
    overall_success=false
    warn -c vlan "Sync: progress publication failed"
}
merv_action_progress_update verify 0 "$SYNC_PROGRESS_TOTAL" 80 \
    "Verifying synchronized node results..."
SYNC_PROGRESS_VERIFIED=0
while IFS=' ' read -r node_id node_ip _sync_extra || [ -n "$node_id" ]; do
    [ -z "$_sync_extra" ] || continue
    if mnj_result_validate "$_sync_jobs_root/node_$node_id/result" "$node_id" sync; then
        SYNC_PROGRESS_VERIFIED=$((SYNC_PROGRESS_VERIFIED + 1))
        _sync_verify_percent=$((80 + (15 * SYNC_PROGRESS_VERIFIED / SYNC_PROGRESS_TOTAL)))
        [ "$_sync_verify_percent" -le 95 ] 2>/dev/null || _sync_verify_percent=95
        if [ "$MNJ_RESULT_STATE" = ok ]; then
            info -c cli,vlan "Sync NODE${node_id} ($node_ip): complete"
            merv_action_progress_update verify "$SYNC_PROGRESS_VERIFIED" "$SYNC_PROGRESS_TOTAL" \
                "$_sync_verify_percent" "Verified NODE${node_id} successfully"
        else
            overall_success=false
            warn -c cli,vlan "Sync NODE${node_id} ($node_ip): failed; detailed worker logs retained in the timestamped worker-log archive"
            merv_action_progress_update verify "$SYNC_PROGRESS_VERIFIED" "$SYNC_PROGRESS_TOTAL" \
                "$_sync_verify_percent" "Verification failed for NODE${node_id}"
        fi
    else
        overall_success=false
        warn -c cli,vlan "Sync NODE${node_id} ($node_ip): failed; detailed worker logs retained in the timestamped worker-log archive"
        merv_action_progress_update verify "$SYNC_PROGRESS_VERIFIED" "$SYNC_PROGRESS_TOTAL" 80 \
            "Verification result missing for NODE${node_id}"
    fi
done < "$_sync_nodes_file"

# Finalize the public archive only after every node has a validated terminal
# result. If a result is missing or malformed, leave the private job intact
# for diagnosis and do not mark it eligible for rotation.
sync_publish_worker_log_view "$_sync_jobs_root" sync || {
    overall_success=false
    warn -c vlan "Sync: worker-log publication failed"
}
if [ "$SYNC_PROGRESS_TOTAL" -gt 0 ] 2>/dev/null &&
   [ "$SYNC_PROGRESS_VERIFIED" -eq "$SYNC_PROGRESS_TOTAL" ] 2>/dev/null; then
    if [ "$overall_success" = "true" ]; then
        _sync_archive_state=ok
    else
        _sync_archive_state=failed
    fi
    if sync_worker_log_archive "$_sync_archive_state" "sync.$SYNC_RUN_ID"; then
        # The public projection is now the retained diagnostic copy. Remove
        # only this validated, terminal private job tree.
        if sync_pool_state_unresolved; then
            overall_success=false
            warn -c vlan "Sync: private worker-job cleanup deferred while node identity reconciliation is pending"
        elif ! rm -rf "$_sync_jobs_root" 2>/dev/null; then
            overall_success=false
            warn -c vlan "Sync: private worker-job cleanup failed; logs retained"
        fi
    else
        warn -c vlan "Sync: worker-log archive rotation failed; private logs retained"
    fi
fi
sync_prune_private_worker_jobs "sync.$SYNC_RUN_ID" || {
    overall_success=false
    warn -c vlan "Sync: private worker-log retention cleanup failed"
}
# Global nodeenable sweep removed; handled per-node in loop above

# ========================================================================== #
# SUMMARY & EXIT — Report overall status and exit with success/failure       #
# ========================================================================== #

info -c cli,vlan "=== Synchronization Complete ==="
merv_action_progress_update cleanup "$SYNC_PROGRESS_TOTAL" "$SYNC_PROGRESS_TOTAL" 95 \
    "Finalizing synchronization..."

if [ "$overall_success" = "true" ]; then
    if [ "$DRY_RUN" = "yes" ]; then
        info -c cli,vlan "[DRY-RUN] SUCCESS: Synchronization simulation completed (no changes applied)"
    else
        info -c cli,vlan "✓ SUCCESS: All files synchronized to all nodes"
        info -c cli,vlan "Files copied: $FILES_TO_COPY"
        info -c cli,vlan "Files made executable: $FILES_TO_COPY_CHMOD"
    fi
    if [ "$DRY_RUN" = "yes" ]; then
        merv_action_progress_complete "Dry-run synchronization simulation complete"
    else
        merv_action_progress_complete "Synchronization complete"
    fi
    SYNC_RECONCILE_VERIFIED=1
    exit 0
else
    if [ "$DRY_RUN" = "yes" ]; then
        warn -c cli,vlan "[DRY-RUN] Simulation encountered issues; review output before running without dry-run"
    else
        warn -c cli,vlan "⚠️  PARTIAL SUCCESS: Some files may not have been synchronized"
        info -c cli,vlan "Check the log at $CLI_LOG for details"
    fi
    merv_action_progress_fail "Synchronization failed; see the VLAN log for details"
    exit 1
fi
