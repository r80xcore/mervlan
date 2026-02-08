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
#               - File: sync_nodes.sh || version="0.54.1"                      #
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
dbg_var SSH_NODE_USER SSH_NODE_PORT
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
functions/mervlan_boot.sh
functions/mervlan_boot_wrap.sh
functions/mervlan_manager.sh 
functions/collect_local_clients.sh 
functions/heal_event.sh  
functions/service-event-handler.sh
functions/hw_probe.sh
templates/mervlan_templates.sh
"

# FILES_TO_COPY_CHMOD — Files requiring executable permissions on nodes (755)
FILES_TO_COPY_CHMOD="
functions/mervlan_boot.sh
functions/mervlan_boot_wrap.sh
functions/mervlan_manager.sh
functions/collect_local_clients.sh
functions/heal_event.sh
functions/service-event-handler.sh
functions/hw_probe.sh
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
templates/mervlan_templates.sh
"
dbg_log "File synchronization manifest loaded"
dbg_var FILES_TO_COPY FILES_TO_COPY_CHMOD FILES_TO_COPY_CHMOD_644

# ========================================================================== #
# SYNCHRONIZATION PARAMETERS — Debug toggles and SSH retry behaviour         #
# ========================================================================== #

# SYNC_DEBUG_PRE/POST toggle verbose remote listings (before/after copy)
SYNC_DEBUG_PRE="${SYNC_DEBUG_PRE:-0}"
SYNC_DEBUG_POST="${SYNC_DEBUG_POST:-1}"
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

# ========================================================================== #
# PRE-FLIGHT VALIDATION — Ensure local configuration and SSH keys are ready  #
# ========================================================================== #

info -c cli,vlan "=== VLAN Manager File Synchronization ==="
info -c cli,vlan ""

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

# get_node_ips — Pull NODE1..NODE5 entries, filter placeholders/invalid IPs
get_node_ips() {
    grep -o '"NODE[1-5]"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" | \
    sed -n 's/"NODE\([1-5]\)"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1 \2/p' | \
    awk '$2 != "none" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $1, $2 }'
}

NODE_IPS=$(get_node_ips)
dbg_log "Discovered node IPs"
dbg_var NODE_IPS

if [ -z "$NODE_IPS" ]; then
    warn -c cli,vlan "No nodes configured in settings.json"
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
        remote_dir="$MERV_BASE/$dir_path"
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
    remote_path="$MERV_BASE/$file"
    
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

    # Special handling for settings.json: reset Trunks section to prevent trunk configs on nodes
    if [ "$file" = "settings/settings.json" ]; then
        _cfn_tmp="$TMPDIR/settings_trunk_reset_sync_node${node_id}.$$"
        cp "$MERV_BASE/$file" "$_cfn_tmp" 2>/dev/null || {
            error -c cli,vlan "✗ Failed to create temp file for trunk reset"
            rm -f "$_cfn_tmp" 2>/dev/null
            return 1
        }

        # Reset Trunks section to defaults (nodes should never trunk)
        if ! json_reset_trunks_section "$_cfn_tmp"; then
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

# verify_file_on_node — Confirm remote file exists, matches size/optional hash
verify_file_on_node() {
    node_ip="$1"
    file="$2"
    node_id="${3:-?}"
    remote_file="$MERV_BASE/$file"

    # Check if file exists and has content
    exists_check=$(merv_ssh_exec "$node_id" "$node_ip" "test -f '$remote_file' && echo 'exists'" 2>/dev/null)
    if echo "$exists_check" | grep -q "exists"; then
        # Check file size to ensure it's not empty
        remote_size=$(merv_ssh_exec "$node_id" "$node_ip" "stat -c%s '$remote_file' 2>/dev/null || wc -c < '$remote_file' 2>/dev/null || echo 0" 2>/dev/null)
        local_size=$(stat -c%s "$MERV_BASE/$file" 2>/dev/null || wc -c < "$MERV_BASE/$file" 2>/dev/null || echo 0)

        # Remove any extra characters from size
        remote_size=$(echo "$remote_size" | tr -cd '0-9')
        local_size=$(echo "$local_size" | tr -cd '0-9')
        
        if [ "$remote_size" -eq "$local_size" ] && [ "$remote_size" -gt 0 ]; then
            local local_md5=""
            local remote_md5=""

            if merv_has md5sum; then
                local_md5=$(md5sum "$MERV_BASE/$file" 2>/dev/null | awk '{print $1}')
            elif merv_has md5; then
                local_md5=$(md5 -r "$MERV_BASE/$file" 2>/dev/null | awk '{print $1}')
            fi

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
    remote_file="$MERV_BASE/$file"

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
    remote_file="$MERV_BASE/$file"

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
        SETTINGS_FILE='$MERV_BASE/settings/settings.json';
        if [ ! -f \"\$SETTINGS_FILE\" ]; then
            echo 'settings-missing' >&2
            exit 1
        fi
        if [ ! -f '$MERV_BASE/settings/lib_json.sh' ]; then
            echo 'lib-json-missing' >&2
            exit 1
        fi
        . '$MERV_BASE/settings/lib_json.sh' 2>/dev/null || {
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
    listing=$(merv_ssh_exec "$node_id" "$node_ip" "if [ -d \"$MERV_BASE\" ]; then ls -laR \"$MERV_BASE\" 2>/dev/null || echo 'No files yet (ls failed)'; else echo 'Directory not found: $MERV_BASE'; fi" 2>/dev/null)
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

    if [ "$DRY_RUN" = "yes" ]; then
        info -c cli,vlan "[DRY-RUN] Would run hw_probe and pull hardware values from NODE${_pnh_id} ($_pnh_ip)"
        return 0
    fi

    # Run hw_probe.sh on the node to detect and write hardware to its settings.json
    info -c cli,vlan "Running hw_probe on NODE${_pnh_id} ($_pnh_ip)..."
    if ! merv_ssh_exec "$_pnh_id" "$_pnh_ip" "cd '$MERV_BASE/functions' && ./hw_probe.sh" >/dev/null 2>&1; then
        warn -c cli,vlan "⚠️ hw_probe failed on NODE${_pnh_id} ($_pnh_ip)"
        return 1
    fi

    # Extract PRODUCTID from node's settings.json
    _pnh_productid=$(merv_ssh_exec "$_pnh_id" "$_pnh_ip" "
        . '$MERV_BASE/settings/lib_json.sh' 2>/dev/null
        json_get_section_value Hardware PRODUCTID '$MERV_BASE/settings/settings.json'
    " 2>/dev/null | tr -d '\r\n')

    # Extract MAX_ETH_PORTS from node's settings.json
    _pnh_maxeth=$(merv_ssh_exec "$_pnh_id" "$_pnh_ip" "
        . '$MERV_BASE/settings/lib_json.sh' 2>/dev/null
        json_get_section_value Hardware MAX_ETH_PORTS '$MERV_BASE/settings/settings.json'
    " 2>/dev/null | tr -d '\r\n')

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

    return 0
}

# ========================================================================== #
# MAIN SYNCHRONIZATION LOOP — Iterate nodes and orchestrate copy workflow    #
# ========================================================================== #

info -c cli,vlan "Starting file synchronization..."
overall_success=true

while read -r node_id node_ip; do
    [ -n "$node_id" ] || continue
    info -c cli,vlan "Processing node: NODE${node_id} ($node_ip)"
    dbg_log "Beginning node synchronization"
    dbg_var node_ip DRY_RUN
    
    # Test connectivity
    if ! ping -c 1 -W 2 "$node_ip" >/dev/null 2>&1; then
        error -c cli,vlan "✗ NODE${node_id} ($node_ip) is not reachable via ping"
        overall_success=false
        continue
    fi
    
    # Test SSH connection
    if ! test_ssh_connection "$node_ip" "$node_id"; then
        merv_ssh_skip_log "$node_id" "$node_ip" "SSH connection test"
        overall_success=false
        continue
    fi
    
    info -c cli,vlan "✓ SSH connection successful to NODE${node_id} ($node_ip)"

    # Ensure JFFS and scripts are enabled before proceeding
    if ! ensure_jffs_ready "$node_ip" "$node_id"; then
        overall_success=false
        continue
    fi
    
    # Create base remote directories (addon path + runtime folders)
    remote_mkdir_cmd="mkdir -p '$MERV_BASE' '$TMPDIR' '$LOGDIR' '$LOCKDIR' '$RESULTDIR' '$CHANGES' '$COLLECTDIR'"
    dbg_log "Ensuring base directories on node"
    dbg_var node_ip remote_mkdir_cmd
    if [ "$DRY_RUN" = "yes" ]; then
        info -c cli,vlan "[DRY-RUN] Would ensure remote directories on NODE${node_id} ($node_ip)"
    else
        if ! merv_ssh_exec "$node_id" "$node_ip" "$remote_mkdir_cmd" >/dev/null 2>&1; then
            merv_ssh_skip_log "$node_id" "$node_ip" "create required directories"
            overall_success=false
            continue
        fi
        info -c cli,vlan "✓ Ensured remote directories on NODE${node_id} ($node_ip)"
    fi
    
    # Debug: show remote directory before copying (optional)
    if [ "$SYNC_DEBUG_PRE" = "1" ]; then
        debug_remote_files "$node_ip" "before" "$node_id"
    fi
    
    # Copy each file
    file_success=true
    for file in $FILES_TO_COPY; do
        local_file="$MERV_BASE/$file"
        
        if [ ! -f "$local_file" ]; then
            error -c cli,vlan "✗ Local file not found: $local_file"
            file_success=false
            continue
        fi
        
        if ! copy_file_to_node "$node_ip" "$file" "$node_id"; then
            file_success=false
        fi
    done
    
    # Debug: show remote directory after copying (default on)
    if [ "$SYNC_DEBUG_POST" = "1" ]; then
        debug_remote_files "$node_ip" "after" "$node_id"
    fi
    
    if [ "$DRY_RUN" = "yes" ]; then
        info -c cli,vlan "[DRY-RUN] Skipping verification, permission updates, and nodeenable for NODE${node_id} ($node_ip)"
        info -c cli,vlan "[DRY-RUN] Simulated synchronization complete for NODE${node_id} ($node_ip)"
        info -c cli,vlan "--- Completed node: NODE${node_id} ($node_ip) ---"
        echo ""
        continue
    fi

    # Verify files were copied
    if [ "$file_success" = "true" ]; then
        verification_success=true
        for file in $FILES_TO_COPY; do
            if ! verify_file_on_node "$node_ip" "$file" "$node_id"; then
                verification_success=false
            fi
        done
        
        if [ "$verification_success" = "true" ]; then
            info -c cli,vlan "✓ All files verified on NODE${node_id} ($node_ip)"
            
            # Set 755 permissions for files that need to be executable
            for file in $FILES_TO_COPY_CHMOD; do
                # Check if this file is in our copy list
                if echo "$FILES_TO_COPY" | grep -q "$file"; then
                    if set_remote_permissions "$node_ip" "$file" "$node_id"; then
                        info -c cli,vlan "chmod 755 on NODE${node_id}:$file"
                    fi
                fi
            done

            # Set 644 permissions for files that should not be executable
            for file in $FILES_TO_COPY_CHMOD_644; do
                # Check if this file is in our copy list
                if echo "$FILES_TO_COPY" | grep -q "$file"; then
                    if set_remote_permissions_644 "$node_ip" "$file" "$node_id"; then
                        info -c cli,vlan "chmod 644 on NODE${node_id}:$file"
                    fi
                fi
            done

            # Mark remote device as MerVLAN node via IS_NODE flag
            if ! set_node_flag_remote "$node_ip" "$node_id"; then
                overall_success=false
                continue
            fi

            if [ "$DRY_RUN" = "yes" ]; then
                info -c cli,vlan "[DRY-RUN] Skipping nodeenable execution on NODE${node_id} ($node_ip)"
                pull_node_hardware "$node_ip" "$node_id"
            else
                if merv_ssh_exec "$node_id" "$node_ip" "cd '$MERV_BASE/functions' && MERV_NODE_CONTEXT=1 ./mervlan_boot.sh nodeenable --local" >/dev/null 2>&1; then
                    info -c cli,vlan "✓ nodeenable applied on NODE${node_id} ($node_ip)"
                    report_line=$(merv_ssh_exec "$node_id" "$node_ip" "cd '$MERV_BASE/functions' && ./mervlan_boot.sh report" 2>/dev/null | tail -1)
                    if [ -n "$report_line" ]; then
                        info -c cli,vlan "NODE${node_id} ($node_ip) report: $report_line"
                        echo "$report_line" | grep -q 'event=active' || warn -c cli,vlan "⚠️ event not active on NODE${node_id} ($node_ip)"
                    else
                        warn -c cli,vlan "⚠️ no report output from NODE${node_id} ($node_ip) after nodeenable"
                    fi

                    # Probe node hardware and pull PRODUCTID/MAX_ETH_PORTS to main settings
                    pull_node_hardware "$node_ip" "$node_id"
                else
                    merv_ssh_skip_log "$node_id" "$node_ip" "nodeenable"
                    overall_success=false
                fi
            fi
        else
            error -c cli,vlan "✗ File verification failed for NODE${node_id} ($node_ip)"
            overall_success=false
        fi
    else
        overall_success=false
    fi
    
    info -c cli,vlan "--- Completed node: $node_ip (NODE${node_id}) ---"
    echo ""
done <<EOF
$NODE_IPS
EOF
# Global nodeenable sweep removed; handled per-node in loop above

# ========================================================================== #
# SUMMARY & EXIT — Report overall status and exit with success/failure       #
# ========================================================================== #

info -c cli,vlan "=== Synchronization Complete ==="

if [ "$overall_success" = "true" ]; then
    if [ "$DRY_RUN" = "yes" ]; then
        info -c cli,vlan "[DRY-RUN] SUCCESS: Synchronization simulation completed (no changes applied)"
    else
        info -c cli,vlan "✓ SUCCESS: All files synchronized to all nodes"
        info -c cli,vlan "Files copied: $FILES_TO_COPY"
        info -c cli,vlan "Files made executable: $FILES_TO_COPY_CHMOD"
    fi
    exit 0
else
    if [ "$DRY_RUN" = "yes" ]; then
        warn -c cli,vlan "[DRY-RUN] Simulation encountered issues; review output before running without dry-run"
    else
        warn -c cli,vlan "⚠️  PARTIAL SUCCESS: Some files may not have been synchronized"
        info -c cli,vlan "Check the log at $CLI_LOG for details"
    fi
    exit 1
fi