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
#             - File: sync_nodes.sh || version="0.72.1"                     #
# ============================================================================ #
# - Purpose:    Synchronize MerVLAN addon files to nodes using SSH keys        #
# ============================================================================ #
#                                                                              #
# ================================================== MerVLAN environment setup #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
    unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_SSH_LOADED LIB_JSON_LOADED LIB_DEBUG_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_SSH_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssh.sh"
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh"
[ -n "${LIB_MERVQT_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mervqt.sh" 2>/dev/null || true
[ -n "${LIB_NODE_JOBS_LOADED:-}" ] || . "$MERV_BASE/settings/lib_node_jobs.sh"
# Progress publication is optional. A missing or unusable status path must
# never change the synchronization result. Keep no-op fallbacks so an older
# installation missing the new helper can still run synchronization normally.
merv_action_progress_init() { :; }
merv_action_progress_phase() { :; }
merv_action_progress_update() { :; }
merv_action_progress_complete() { :; }
merv_action_progress_fail() { :; }
if [ -f "$MERV_BASE/settings/lib_action_progress.sh" ]; then
    . "$MERV_BASE/settings/lib_action_progress.sh" 2>/dev/null || :
fi
# =========================================== End of MerVLAN environment setup #

# Default no-op debug helpers; overridden if lib_debug.sh is loaded
dbg_log() { :; }
dbg_var() { :; }

DRY_RUN_FORCED=0
DEBUG_FORCED=0

ORIGINAL_ARGS="$*"

# ───── CLI arg parsing: dryrun + debug ─────
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
        *)
            break
            ;;
    esac
done

if [ -z "${DRY_RUN:-}" ]; then
    DRY_RUN="$(json_get_flag "DRY_RUN" "yes" "$SETTINGS_FILE" 2>/dev/null)"
fi
[ -z "$DRY_RUN" ] && DRY_RUN="yes"

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
dbg_var DRY_RUN DRY_RUN_FORCED DEBUG DEBUG_FORCED DEBUG_JSON

SSH_NODE_USER=$(get_node_ssh_user)
SSH_NODE_PORT=$(get_node_ssh_port)
REMOTE_MERV_BASE="$MERV_BASE"
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
merv_action_progress_init "${MERV_PROGRESS_TOKEN:-}" "sync_vlanmgr" "Sync Nodes" \
    "Preparing synchronization..."

# Remove any per-node sync metadata breadcrumbs left by copy_file_to_node.
# Fires on every exit path (normal, error, signal) so no stale files survive
# across runs even if verification was skipped or the script was interrupted.
_cleanup_sync_tmp() {
    if [ "${MERV_ACTION_PROGRESS_ENABLED:-0}" -eq 1 ] &&
       [ "${MERV_ACTION_PROGRESS_FINAL:-0}" -eq 0 ]; then
        merv_action_progress_fail "Synchronization stopped before completion"
    fi
    rm -f "$TMPDIR"/merv_sync_expected_* 2>/dev/null || :
    [ "${SYNC_LOCK_ACQUIRED:-0}" -eq 1 ] && merv_lock_release "$SYNC_LOCK" 2>/dev/null
}
trap '_cleanup_sync_tmp' EXIT INT TERM

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
if [ "$DRY_RUN" != "yes" ] && type merv_lock_acquire >/dev/null 2>&1; then
    mkdir -p "$LOCKDIR" 2>/dev/null || :
    if [ "${MERV_MAINTENANCE_SYNC:-0}" != "1" ] && type merv_lock_state >/dev/null 2>&1; then
        case "$(merv_lock_state "$LOCKDIR/mervlan_maintenance.lock" 1800)" in
            active|unknown_recent)
                warn -c cli,vlan "Sync: update, backup, or restore maintenance is active — skipping this run"
                exit 1
                ;;
        esac
    fi
    if type merv_lock_state >/dev/null 2>&1; then
        case "$(merv_lock_state "$LOCKDIR/mervlan_manager.lock")" in
            active|unknown_recent)
                warn -c cli,vlan "Sync: mervlan_manager is applying config — skipping this run"
                exit 0
                ;;
        esac
    fi
    if merv_lock_acquire "$SYNC_LOCK" "${MERV_SYNC_LOCK_STALE_SEC:-600}" 0 "sync_nodes"; then
        SYNC_LOCK_ACQUIRED=1
    else
        warn -c cli,vlan "Sync: another sync_nodes run is in progress — skipping"
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
settings/lib_debug.sh
settings/lib_ssh.sh
settings/lib_ssid_filter.sh
settings/lib_stp.sh
settings/lib_mervqt.sh
settings/lib_node_jobs.sh
settings/lib_action_ack.sh
settings/lib_radio.sh
settings/lib_progress.sh
settings/lib_action_progress.sh
settings/mac_shield_snapshot.sh
settings/lib_br0_guard.sh
functions/mervlan_boot.sh
functions/mervlan_boot_wrap.sh
functions/mervlan_manager.sh 
functions/mervlan_node_runner.sh
functions/mervlan_selftest.sh
functions/mervlan_live_test_guard.sh
functions/post_apply_worker.sh
functions/collect_local_clients.sh 
functions/heal_event.sh  
functions/service-event-handler.sh
functions/hw_probe.sh
functions/mervlan_trunk.sh
functions/mac_refresh.sh
templates/mervlan_templates.sh
"

# FILES_TO_COPY_CHMOD — Files requiring executable permissions on nodes (755)
FILES_TO_COPY_CHMOD="
functions/mervlan_boot.sh
functions/mervlan_boot_wrap.sh
functions/mervlan_manager.sh
functions/mervlan_node_runner.sh
functions/mervlan_selftest.sh
functions/mervlan_live_test_guard.sh
functions/post_apply_worker.sh
functions/collect_local_clients.sh
functions/heal_event.sh
functions/service-event-handler.sh
functions/hw_probe.sh
functions/mervlan_trunk.sh
functions/mac_refresh.sh
"
# FILES_TO_COPY_CHMOD_644 — Config scripts that should remain non-executable
FILES_TO_COPY_CHMOD_644="
settings/var_settings.sh 
settings/log_settings.sh 
settings/lib_json.sh  
settings/lib_debug.sh 
settings/lib_ssh.sh
settings/lib_ssid_filter.sh 
settings/lib_stp.sh
settings/lib_mervqt.sh
settings/lib_node_jobs.sh
settings/lib_action_ack.sh
settings/lib_radio.sh
settings/lib_progress.sh
settings/lib_action_progress.sh
settings/mac_shield_snapshot.sh
settings/lib_br0_guard.sh
templates/mervlan_templates.sh
"
dbg_log "File synchronization manifest loaded"
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
    merv_action_progress_complete "No configured nodes; nothing to synchronize"
    exit 0
fi

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
    
    # First create the necessary directory structure
    if ! create_remote_dirs_for_file "$node_ip" "$file" "$node_id"; then
        return 1
    fi
    
    dbg_log "Preparing to copy file to node"
    dbg_var node_ip file remote_path

    if [ "$DRY_RUN" = "yes" ]; then
        info -c cli,vlan "[DRY-RUN] Would copy $file to NODE${node_id} ($node_ip):$remote_path"
        return 0
    fi

    # Special handling for settings.json: inject node-aware trunk config
    # Nodes need TRUNK1 enabled so the backhaul port carries tagged VLAN traffic.
    if [ "$file" = "settings/settings.json" ]; then
        _cfn_tmp=$(sync_job_tmp_path "settings_trunk_reset_sync_node${node_id}")
        cp "$MERV_BASE/$file" "$_cfn_tmp" 2>/dev/null || {
            error -c cli,vlan "✗ Failed to create temp file for trunk config"
            rm -f "$_cfn_tmp" 2>/dev/null
            return 1
        }

        # Check if main has any active trunk ports (user intent gate).
        # If all trunks are "0", the user explicitly wants no trunks — respect
        # that and send the settings as-is. Only auto-inject when the main has
        # at least one trunk enabled, which signals an active managed-switch
        # topology where the node's backhaul port also needs trunk config.
        _cfn_main_has_trunk="no"
        _cfn_ti=1
        while [ "$_cfn_ti" -le 8 ]; do
            if [ "$(json_get_flag "TRUNK${_cfn_ti}" "0" "$MERV_BASE/$file")" = "1" ]; then
                _cfn_main_has_trunk="yes"
                break
            fi
            _cfn_ti=$((_cfn_ti + 1))
        done

        # Zero all trunks first (clean slate), then inject node trunk config
        if [ "$_cfn_main_has_trunk" = "yes" ] && json_reset_trunks_section "$_cfn_tmp"; then
            # Collect all VLAN IDs from the SSID pool.
            # Scan up to Hardware.MAX_SSIDS slots; if zero/absent use Limits.MAX_SSID_CAP; default 16.
            _cfn_vlan_scan_max=$(json_get_section_value "Hardware" "MAX_SSIDS" "$_cfn_tmp" 2>/dev/null)
            case "$_cfn_vlan_scan_max" in
              ''|0|*[!0-9]*)
                _cfn_vlan_scan_max=$(json_get_section_value "Limits" "MAX_SSID_CAP" "$_cfn_tmp" 2>/dev/null)
                case "$_cfn_vlan_scan_max" in ''|0|*[!0-9]*) _cfn_vlan_scan_max=16 ;; esac
                ;;
            esac
            _cfn_vlan_list=""
            _cfn_vi=1
            while [ "$_cfn_vi" -le "$_cfn_vlan_scan_max" ]; do
                _cfn_vid="$(json_get_flag "VLAN_$(printf '%02d' "$_cfn_vi")" "" "$_cfn_tmp")"
                case "$_cfn_vid" in
                    ""|none|*[!0-9]*) ;;
                    *) _cfn_vlan_list="${_cfn_vlan_list}${_cfn_vlan_list:+,}${_cfn_vid}" ;;
                esac
                _cfn_vi=$((_cfn_vi + 1))
            done
            # Enable TRUNK1 for node backhaul with collected VLANs
            if [ -n "$_cfn_vlan_list" ]; then
                json_set_flag "TRUNK1" "1" "$_cfn_tmp"
                json_set_flag "TAGGED_TRUNK1" "$_cfn_vlan_list" "$_cfn_tmp"
                info -c cli,vlan "Node trunk config: TRUNK1=1, TAGGED=$_cfn_vlan_list"
            fi
        elif [ "$_cfn_main_has_trunk" = "no" ]; then
            info -c cli,vlan "Node trunk config: all trunks disabled on main — sending as-is (no auto-inject)"
        else
            warn -c cli,vlan "⚠️ Failed to reset trunks section, copying original file"
            rm -f "$_cfn_tmp" 2>/dev/null
            # Fallback to original file
            if cat "$MERV_BASE/$file" | _merv_timeout_run "$MERV_SSH_TIMEOUT" dbclient -p "$(get_node_ssh_port)" -y -i "$SSH_KEY" "$(get_node_ssh_user)@$node_ip" "cat > '${remote_path}.tmp' && mv '${remote_path}.tmp' '${remote_path}'" 2>/dev/null; then
                info -c cli,vlan "✓ Copied $file to NODE${node_id} ($node_ip):$remote_path"
                return 0
            else
                error -c cli,vlan "✗ Failed to copy $file to NODE${node_id} ($node_ip):$remote_path"
                return 1
            fi
        fi

        # Use cat piped with timeout wrapper for atomic file transfer
        if cat "$_cfn_tmp" | _merv_timeout_run "$MERV_SSH_TIMEOUT" dbclient -p "$(get_node_ssh_port)" -y -i "$SSH_KEY" "$(get_node_ssh_user)@$node_ip" "cat > '${remote_path}.tmp' && mv '${remote_path}.tmp' '${remote_path}'" 2>/dev/null; then
            # Persist expected size+md5 of the sent (content-modified) file
            # before discarding the temp copy. verify_file_on_node reads this
            # breadcrumb so it validates against what actually landed on the
            # node rather than the unmodified local original.
            _cfn_exp_size=$(wc -c < "$_cfn_tmp" 2>/dev/null | tr -cd '0-9')
            _cfn_exp_md5=""
            if merv_has md5sum; then
                _cfn_exp_md5=$(md5sum "$_cfn_tmp" 2>/dev/null | awk '{print $1}')
            elif merv_has md5; then
                _cfn_exp_md5=$(md5 -r "$_cfn_tmp" 2>/dev/null | awk '{print $1}')
            fi
            printf '%s\n%s\n' "$_cfn_exp_size" "$_cfn_exp_md5" \
                > "$(sync_expected_path "$node_id")" 2>/dev/null || true
            info -c cli,vlan "✓ Copied $file (trunk-safe) to NODE${node_id} ($node_ip):$remote_path"
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
    if cat "$MERV_BASE/$file" | _merv_timeout_run "$MERV_SSH_TIMEOUT" dbclient -p "$(get_node_ssh_port)" -y -i "$SSH_KEY" "$(get_node_ssh_user)@$node_ip" "cat > '${remote_path}.tmp' && mv '${remote_path}.tmp' '${remote_path}'" 2>/dev/null; then
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
        _merv_timeout_run "$MERV_SSH_TIMEOUT" dbclient -p "$(get_node_ssh_port)" -y -i "$SSH_KEY" "$(get_node_ssh_user)@$node_ip" "cd '$REMOTE_MERV_BASE' && tar -xf - 2>/dev/null" 2>/dev/null; then
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

    # Fallback: total byte count (wc -c prints a 'total' line for multiple files).
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
        remote_size=$(merv_ssh_exec "$node_id" "$node_ip" "stat -c%s '$remote_file' 2>/dev/null || wc -c < '$remote_file' 2>/dev/null || echo 0" 2>/dev/null)
        local_size=$(stat -c%s "$MERV_BASE/$file" 2>/dev/null || wc -c < "$MERV_BASE/$file" 2>/dev/null || echo 0)

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
                rm -f "$_vfn_breadcrumb" 2>/dev/null || :
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

# set_node_flag_remote — Mark remote device as MerVLAN node via settings.json
set_node_flag_remote() {
    node_ip="$1"
    node_id="$2"
    remote_cmd="
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
        info -c cli,vlan "✓ Set IS_NODE=1 and NODE_ID=$node_id in settings.json on NODE${node_id} ($node_ip)"
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
    info -c cli,vlan "Running hw_probe on NODE${_pnh_id} ($_pnh_ip)..."
    _pnh_output=$(merv_ssh_exec "$_pnh_id" "$_pnh_ip" "
        cd '$MERV_BASE/functions' && ./hw_probe.sh >/dev/null 2>&1 || echo 'HWPROBE_FAILED'
        . '$MERV_BASE/settings/lib_json.sh' 2>/dev/null
        printf 'PRODUCTID=%s\n' \"\$(json_get_section_value Hardware PRODUCTID '$MERV_BASE/settings/settings.json' 2>/dev/null)\"
        printf 'MAX_ETH_PORTS=%s\n' \"\$(json_get_section_value Hardware MAX_ETH_PORTS '$MERV_BASE/settings/settings.json' 2>/dev/null)\"
        printf 'LAN_PORT_LABEL_OVERRIDES=%s\n' \"\$(json_get_section_value Hardware LAN_PORT_LABEL_OVERRIDES '$MERV_BASE/settings/settings.json' 2>/dev/null)\"
    " 2>/dev/null)

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
            mkdir -p \"\$stage/tmp\" 2>/dev/null || :;
            cp -p \"\$old\"/tmp/*.db \"\$stage/tmp/\" 2>/dev/null || :;
        fi;
        if ! mv \"\$stage\" \"\$active\"; then
            [ \"\$had_old\" = 1 ] && mv \"\$old\" \"\$active\" 2>/dev/null || :;
            exit 25;
        fi;
        if cd \"\$active/functions\" && MERV_NODE_CONTEXT=1 ./mervlan_boot.sh nodeenable --local >/dev/null 2>&1; then
            report=\$(MERV_NODE_CONTEXT=1 ./mervlan_boot.sh report 2>/dev/null | tail -1);
            if echo \"\$report\" | grep -q 'addon=node-on' && echo \"\$report\" | grep -q 'event=active'; then
                rm -rf \"\$old\" 2>/dev/null || :; echo STAGED_NODE_OK; exit 0;
            fi;
        fi;
        rm -rf \"\$stage\" 2>/dev/null || :;
        mv \"\$active\" \"\$stage\" 2>/dev/null || exit 26;
        if [ \"\$had_old\" = 1 ]; then
            if mv \"\$old\" \"\$active\" 2>/dev/null; then
                cd \"\$active/functions\" 2>/dev/null && MERV_NODE_CONTEXT=1 ./mervlan_boot.sh nodeenable --local >/dev/null 2>&1 || :;
                rm -rf \"\$stage\" 2>/dev/null || :;
                exit 26;
            fi;
            exit 27;
        fi;
        mv \"\$stage\" \"\$active\" 2>/dev/null || :;
        exit 26
    "
    _asn_result=$(merv_ssh_exec "$_asn_id" "$_asn_ip" "$_asn_cmd" 2>/dev/null)
    echo "$_asn_result" | grep -q STAGED_NODE_OK
}

# ========================================================================== #
# MAIN SYNCHRONIZATION LOOP — Iterate nodes and orchestrate copy workflow    #
# ========================================================================== #

sync_node_worker() {
    node_id="$1"
    node_ip="$2"
    info -c cli,vlan "Processing node: NODE${node_id} ($node_ip)"
    dbg_log "Beginning node synchronization"
    dbg_var node_ip DRY_RUN
    
    # Test connectivity
    if ! ping -c 1 -W 2 "$node_ip" >/dev/null 2>&1; then
        error -c cli,vlan "✗ NODE${node_id} ($node_ip) is not reachable via ping"
        return 1
    fi
    
    # Test SSH connection
    if ! test_ssh_connection "$node_ip" "$node_id"; then
        merv_ssh_skip_log "$node_id" "$node_ip" "SSH connection test"
        return 1
    fi
    
    info -c cli,vlan "✓ SSH connection successful to NODE${node_id} ($node_ip)"

    # Ensure JFFS and scripts are enabled before proceeding
    if ! ensure_jffs_ready "$node_ip" "$node_id"; then
        return 1
    fi

    REMOTE_MERV_BASE="/jffs/addons/mervlan_backups/.mervlan.new.${SYNC_RUN_ID}.${node_id}"
    REMOTE_MERV_OLD="/jffs/addons/mervlan_backups/.mervlan.old.${SYNC_RUN_ID}.${node_id}"
    
    # Create base remote directories (addon path + runtime folders + the addon
    # subdirs that tar will extract into — pre-creating them means batch extract
    # never fails on a missing path, and we drop the per-file dir-creation SSH).
    remote_mkdir_cmd="mkdir -p '/jffs/addons/mervlan_backups'; rm -rf '$REMOTE_MERV_BASE' '$REMOTE_MERV_OLD' 2>/dev/null || exit 70; mkdir -p '$REMOTE_MERV_BASE/settings' '$REMOTE_MERV_BASE/functions' '$REMOTE_MERV_BASE/templates' '$TMPDIR' '$LOGDIR' '$LOCKDIR' '$RESULTDIR' '$CHANGES' '$COLLECTDIR'"
    dbg_log "Ensuring base directories on node"
    dbg_var node_ip remote_mkdir_cmd
    if [ "$DRY_RUN" = "yes" ]; then
        info -c cli,vlan "[DRY-RUN] Would ensure remote directories on NODE${node_id} ($node_ip)"
    else
        if ! merv_ssh_exec "$node_id" "$node_ip" "$remote_mkdir_cmd" >/dev/null 2>&1; then
            merv_ssh_skip_log "$node_id" "$node_ip" "create required directories"
            return 1
        fi
        info -c cli,vlan "✓ Ensured remote directories on NODE${node_id} ($node_ip)"
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
        # Batched files: one combined md5 fingerprint check (single SSH).
        if [ -n "$_batch_files" ]; then
            if ! verify_batch_on_node "$node_ip" "$node_id" "$_batch_files"; then
                verification_success=false
            fi
        fi
        # settings/settings.json: dedicated per-file verify (uses breadcrumb md5).
        if echo "$FILES_TO_COPY" | grep -q "settings/settings.json"; then
            if ! verify_file_on_node "$node_ip" "settings/settings.json" "$node_id"; then
                verification_success=false
            fi
        fi

        if [ "$verification_success" = "true" ]; then
            info -c cli,vlan "✓ All files verified on NODE${node_id} ($node_ip)"

            # Apply all 755 + 644 permissions in a single SSH call.
            batch_set_remote_permissions "$node_ip" "$node_id"

            # Mark remote device as MerVLAN node via IS_NODE flag
            if ! set_node_flag_remote "$node_ip" "$node_id"; then
                cleanup_remote_stage "$node_ip" "$node_id" "$REMOTE_MERV_BASE" "$REMOTE_MERV_OLD" || :
                return 1
            fi

            if activate_staged_node "$node_ip" "$node_id" "$REMOTE_MERV_BASE" "$REMOTE_MERV_OLD"; then
                info -c cli,vlan "✓ Staged activation verified on NODE${node_id} ($node_ip)"
                report_line=$(merv_ssh_exec "$node_id" "$node_ip" "cd '$MERV_BASE/functions' && MERV_NODE_CONTEXT=1 ./mervlan_boot.sh report" 2>/dev/null | tail -1)
                [ -n "$report_line" ] && info -c cli,vlan "NODE${node_id} ($node_ip) report: $report_line"
                pull_node_hardware "$node_ip" "$node_id"
            else
                merv_ssh_skip_log "$node_id" "$node_ip" "staged activation"
                cleanup_remote_stage "$node_ip" "$node_id" "$REMOTE_MERV_BASE" "$REMOTE_MERV_OLD" || :
                return 1
            fi
        else
            error -c cli,vlan "✗ File verification failed for NODE${node_id} ($node_ip)"
            cleanup_remote_stage "$node_ip" "$node_id" "$REMOTE_MERV_BASE" "$REMOTE_MERV_OLD" || :
            return 1
        fi
    else
        cleanup_remote_stage "$node_ip" "$node_id" "$REMOTE_MERV_BASE" "$REMOTE_MERV_OLD" || :
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
    chmod 600 "$_swla_marker_tmp" 2>/dev/null || :
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
        chmod 600 "$_swla_legacy_tmp" 2>/dev/null || :
        mv "$_swla_legacy_tmp" "$_swla_legacy_marker" || { rm -f "$_swla_legacy_tmp"; continue; }
        rm -rf "$_swla_private" 2>/dev/null || :
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
    _swla_first=1; _swla_kept=0; _swla_seen_terminal=0
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
                rm -rf "$_swla_job_dir" 2>/dev/null || :
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
    chmod 644 "$_swla_json" 2>/dev/null || :
    mv "$_swla_json" "$_swla_root/index.json" || return 1
    rm -f "$_swla_list" "$_swla_list.sorted"
    return 0
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
        [ "$_sppw_kept" -le 3 ] || rm -rf "$_sppw_dir" 2>/dev/null || :
    done < "$_sppw_list.sorted"
    rm -f "$_sppw_list" "$_sppw_list.sorted"
    return 0
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
if ! mnj_pool_run "$_sync_jobs_root" sync "${MERV_NODE_PARALLELISM:-2}" "${MERV_NODE_SYNC_MAX_SEC:-720}" "$_sync_nodes_file" sync_node_worker; then
    overall_success=false
fi
MNJ_POOL_PROGRESS_HOOK=""
sync_pool_progress "$_sync_jobs_root" sync || :
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
sync_publish_worker_log_view "$_sync_jobs_root" sync || :
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
        rm -rf "$_sync_jobs_root" 2>/dev/null || :
    else
        warn -c vlan "Sync: worker-log archive rotation failed; private logs retained"
    fi
fi
sync_prune_private_worker_jobs "sync.$SYNC_RUN_ID" ||
    warn -c vlan "Sync: private worker-log retention cleanup failed"
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
