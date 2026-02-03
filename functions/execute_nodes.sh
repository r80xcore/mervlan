#!/bin/sh
#
# ──────────────────────────────────────────────────────────────────────────── #
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
# ──────────────────────────────────────────────────────────────────────────── #
#                - File: execute_nodes.sh || version="0.49"                    #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Execute the MerVLAN Manager on configured nodes via SSH using  #
#               the settings defined in settings.json.                         #
# ──────────────────────────────────────────────────────────────────────────── #
#                                                                              #
# ================================================== MerVLAN environment setup #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_JSON_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_SSH_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssh.sh"
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh"
# =========================================== End of MerVLAN environment setup #
SSH_NODE_USER=$(get_node_ssh_user)
SSH_NODE_PORT=$(get_node_ssh_port)
# ============================================================================ #
#                          INITIALIZATION & LOGGING                            #
# Display welcome message and prepare for node execution. Log script           #
# invocation for diagnostic purposes.                                          #
# ============================================================================ #

info -c cli,vlan "=== VLAN Manager Node Execution ==="
info -c cli,vlan ""

# Optional mode selector (accept "nodesonly" to skip local execution)
MODE="full"
if [ $# -gt 0 ]; then
    case "$1" in
        nodesonly)
            MODE="nodesonly"
            shift
            info -c cli,vlan "Nodes-only mode: local VLAN manager execution will be skipped"
            ;;
        *)
            warn -c cli,vlan "Unknown argument '$1'; ignoring and proceeding normally"
            ;;
    esac
fi

# ============================================================================ #
#                         PRE-EXECUTION VALIDATION                             #
# Verify that all required files and configurations are present and valid      #
# before attempting to connect to or execute on any nodes. Abort if checks     #
# fail to prevent partial or corrupted state.                                  #
# ============================================================================ #

# Verify settings.json exists at expected location
if [ ! -f "$SETTINGS_FILE" ]; then
    error -c cli,vlan "ERROR: Settings file not found at $SETTINGS_FILE"
    exit 1
fi

# Verify SSH keys are effectively installed via shared helper
if ! ssh_keys_effectively_installed; then
    error -c cli,vlan "ERROR: SSH keys are not fully configured"
    warn -c cli,vlan "Either SSH_KEYS_INSTALLED is 0/missing and no key files exist, or the SSH keys have not been generated/installed yet."
    warn -c cli,vlan "Use 'SSH Key Install' in the UI to set them up."
    exit 1
fi

# Verify SSH key pair files actually exist on filesystem
if [ -z "${SSH_KEY:-}" ] || [ ! -f "$SSH_KEY" ] || \
   [ -z "${SSH_PUBKEY:-}" ] || [ ! -f "$SSH_PUBKEY" ]; then
    error -c cli,vlan "ERROR: SSH key files not found"
    warn -c cli,vlan "Please run the SSH key generator first"
    exit 1
fi

# Verify public key is installed in authorized_keys on this router
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

# ============================================================================ #
#                             HELPER FUNCTIONS                                 #
# Utility functions for node discovery, SSH validation, JFFS verification,     #
# settings synchronization, and remote VLAN manager execution.                 #
# ============================================================================ #

# ============================================================================ #
# get_node_ips                                                                 #
# Extract NODE1-NODE5 IP addresses from settings.json. Parse JSON format       #
# and filter out "none" entries and invalid IP addresses.                      #
# ============================================================================ #
get_node_ips() {
    # Extract NODE entries matching JSON "NODE[1-5]": "IP" format
    grep -o '"NODE[1-5]"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" | \
    sed -n 's/"NODE\([1-5]\)"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1 \2/p' | \
    awk '$2 != "none" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $1, $2 }'
}

NODE_IPS=$(get_node_ips)

# Check if any nodes are configured
if [ -z "$NODE_IPS" ]; then
    warn -c cli,vlan "No nodes configured in settings.json"
    exit 0
fi

info -c cli,vlan "Found nodes: $(echo "$NODE_IPS" | awk '{print $2}' | tr '\n' ' ')"
echo ""

# ============================================================================ #
# check_remote_jffs_status                                                     #
# Query remote node's JFFS and JFFS scripts settings via SSH. Returns          #
# status string "jffs2_on jffs2_scripts" or error code 2 on SSH failure.       #
# ============================================================================ #
check_remote_jffs_status() {
    node_id="$1"
    node_ip="$2"
    output=""

    # Execute remote nvram queries and capture output
    output=$(merv_ssh_exec "$node_id" "$node_ip" "nvram get jffs2_on 2>/dev/null; nvram get jffs2_scripts 2>/dev/null")
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo ""
        return 2
    fi

    # Extract first line (jffs2_on) and second line (jffs2_scripts); strip carriage returns
    jffs_on=""
    jffs_scripts=""
    jffs_on=$(echo "$output" | sed -n '1p' | tr -d '\r')
    jffs_scripts=$(echo "$output" | sed -n '2p' | tr -d '\r')

    # Default to "0" (disabled) if empty
    [ -z "$jffs_on" ] && jffs_on="0"
    [ -z "$jffs_scripts" ] && jffs_scripts="0"

    printf '%s %s\n' "$jffs_on" "$jffs_scripts"

    # Return success only if both are enabled ("1")
    if [ "$jffs_on" = "1" ] && [ "$jffs_scripts" = "1" ]; then
        return 0
    else
        return 1
    fi
}

# ============================================================================ #
# test_ssh_connection                                                          #
# Verify SSH connectivity to a node using dropbear client. Attempts echo       #
# command with timeout. Returns 0 if successful, 1 if connection fails.        #
# ============================================================================ #
test_ssh_connection() {
    node_id="$1"
    node_ip="$2"
    # Use wrapper-based SSH test with precheck and timeout
    if merv_ssh_test "$node_id" "$node_ip"; then
        return 0
    else
        return 1
    fi
}

# ============================================================================ #
# ensure_jffs_ready                                                            #
# Verify JFFS is enabled on the remote node. Abort with error if JFFS is not   #
# fully enabled (indicates "Sync Nodes" must be run first).                    #
# ============================================================================ #
ensure_jffs_ready() {
    node_id="$1"
    node_ip="$2"
    jffs_status=""

    # Query JFFS status; success means both jffs2_on and jffs2_scripts are 1
    if jffs_status=$(check_remote_jffs_status "$node_id" "$node_ip"); then
        info -c cli,vlan "✓ JFFS already enabled on $node_ip"
        return 0
    else
        status=$?
        jffs_on=""
        jffs_scripts=""
        jffs_on=$(echo "$jffs_status" | awk '{print $1}')
        jffs_scripts=$(echo "$jffs_status" | awk '{print $2}')
        [ -z "$jffs_on" ] && jffs_on="0"
        [ -z "$jffs_scripts" ] && jffs_scripts="0"

        # Status 1 means JFFS not fully enabled; status > 1 means SSH error
        if [ $status -eq 1 ]; then
            error -c cli,vlan "✗ JFFS is not fully enabled on $node_ip (jffs2_on=$jffs_on, jffs2_scripts=$jffs_scripts)"
            error -c cli,vlan '   "Sync Nodes" must be executed before multi-configuring nodes.'
            exit 1
        else
            error -c cli,vlan "✗ Failed to determine JFFS status on $node_ip"
            return 1
        fi
    fi
}

# ============================================================================ #
# ensure_settings_conf_exists                                                  #
# Verify that local settings.json exists before attempting to propagate it     #
# to nodes. Abort if missing to prevent blank or corrupted node configs.       #
# ============================================================================ #
ensure_settings_conf_exists() {
    if [ ! -f "$SETTINGS_FILE" ]; then
        error -c cli,vlan "ERROR: settings.json not found at $SETTINGS_FILE"
        return 1
    fi
    return 0
}

# ============================================================================ #
# ensure_remote_settings_dir                                                   #
# Create settings directory on remote node via SSH. Required before copying    #
# settings.json to node. Fails if directory creation fails.                    #
# ============================================================================ #
ensure_remote_settings_dir() {
    node_id="$1"
    node_ip="$2"
    remote_dir="$SETTINGSDIR"

    # Attempt to create settings directory on remote node
    if merv_ssh_exec "$node_id" "$node_ip" "mkdir -p '$remote_dir'" >/dev/null; then
        info -c cli,vlan "✓ Ensured directory $remote_dir on $node_ip"
        return 0
    else
        error -c cli,vlan "✗ Failed to create directory $remote_dir on $node_ip"
        return 1
    fi
}

# ============================================================================ #
# copy_settings_conf_to_node                                                   #
# Transfer local settings.json to remote node's settings directory via SSH.    #
# Uses atomic rename to avoid partial file reads. Preserves node's Hardware    #
# section to avoid overwriting device-specific hardware detection values.      #
# IS_NODE and NODE_ID are set separately by set_node_flags_remote().           #
# ============================================================================ #
copy_settings_conf_to_node() {
    node_id="$1"
    node_ip="$2"
    file_rel="settings/settings.json"
    remote_path="$MERV_BASE/$file_rel"

    info -c cli,vlan "Copying $file_rel to $node_ip"

    # Ensure remote directory exists before copying
    if ! ensure_remote_settings_dir "$node_id" "$node_ip"; then
        return 1
    fi

    # Fetch node's current Hardware section (if exists) to preserve it
    # NOTE: We do NOT preserve IS_NODE/NODE_ID here - they are set by set_node_flags_remote()
    _cstn_tmp="$TMPDIR/settings_merged_node${node_id}.$$"
    _cstn_node_hw=""

    _cstn_node_hw=$(merv_ssh_exec "$node_id" "$node_ip" "
        if [ -f '$remote_path' ]; then
            . '$MERV_BASE/settings/lib_json.sh' 2>/dev/null
            json_extract_hardware_section '$remote_path' 2>/dev/null
        fi
    " 2>/dev/null)

    if [ -n "$_cstn_node_hw" ] && echo "$_cstn_node_hw" | grep -q '"Hardware"'; then
        # Node has Hardware section - create merged file
        cp "$SETTINGS_FILE" "$_cstn_tmp" 2>/dev/null || {
            error -c cli,vlan "✗ Failed to create temp file for settings merge"
            rm -f "$_cstn_tmp" 2>/dev/null
            return 1
        }

        # Reset Trunks section to defaults (nodes should never trunk)
        if ! json_reset_trunks_section "$_cstn_tmp"; then
            warn -c cli,vlan "⚠️ Failed to reset trunks section, continuing anyway"
        fi

        # Write node's Hardware to temp file, then replace in the copy
        _cstn_hw_file="$TMPDIR/node_hw_${node_id}.$$"
        printf '%s\n' "$_cstn_node_hw" > "$_cstn_hw_file"

        if json_replace_hardware_section "$_cstn_hw_file" "$_cstn_tmp"; then
            info -c cli,vlan "✓ Merged settings.json preserving NODE${node_id} Hardware section"
            # Copy the merged file
            if cat "$_cstn_tmp" | _merv_timeout_run $MERV_SSH_TIMEOUT dbclient -p "$SSH_NODE_PORT" -y -i "$SSH_KEY" "$SSH_NODE_USER@$node_ip" "cat > '${remote_path}.tmp' && mv '${remote_path}.tmp' '${remote_path}'" 2>/dev/null; then
                info -c cli,vlan "✓ Copied $file_rel (merged) to $node_ip:$remote_path"
                rm -f "$_cstn_tmp" "$_cstn_hw_file" 2>/dev/null
                return 0
            else
                error -c cli,vlan "✗ Failed to copy merged $file_rel to $node_ip:$remote_path"
                rm -f "$_cstn_tmp" "$_cstn_hw_file" 2>/dev/null
                return 1
            fi
        else
            warn -c cli,vlan "⚠️ Hardware merge failed, copying settings.json as-is"
            rm -f "$_cstn_tmp" "$_cstn_hw_file" 2>/dev/null
        fi
        rm -f "$_cstn_tmp" "$_cstn_hw_file" 2>/dev/null
    fi

    # No existing Hardware section on node, or merge wasn't needed - copy with trunk reset
    # Create temp file with reset trunks
    _cstn_tmp="$TMPDIR/settings_trunk_reset_node${node_id}.$$"
    cp "$SETTINGS_FILE" "$_cstn_tmp" 2>/dev/null || {
        error -c cli,vlan "✗ Failed to create temp file for trunk reset"
        rm -f "$_cstn_tmp" 2>/dev/null
        return 1
    }

    # Reset Trunks section to defaults (nodes should never trunk)
    if ! json_reset_trunks_section "$_cstn_tmp"; then
        warn -c cli,vlan "⚠️ Failed to reset trunks section, copying original file"
        rm -f "$_cstn_tmp" 2>/dev/null
        # Fallback to original file
        if cat "$SETTINGS_FILE" | _merv_timeout_run $MERV_SSH_TIMEOUT dbclient -p "$SSH_NODE_PORT" -y -i "$SSH_KEY" "$SSH_NODE_USER@$node_ip" "cat > '${remote_path}.tmp' && mv '${remote_path}.tmp' '${remote_path}'" 2>/dev/null; then
            info -c cli,vlan "✓ Copied $file_rel to $node_ip:$remote_path"
            return 0
        else
            error -c cli,vlan "✗ Failed to copy $file_rel to $node_ip:$remote_path"
            return 1
        fi
    fi

    # Use cat pipe through SSH with atomic rename (write to .tmp then mv)
    if cat "$_cstn_tmp" | _merv_timeout_run $MERV_SSH_TIMEOUT dbclient -p "$SSH_NODE_PORT" -y -i "$SSH_KEY" "$SSH_NODE_USER@$node_ip" "cat > '${remote_path}.tmp' && mv '${remote_path}.tmp' '${remote_path}'" 2>/dev/null; then
        info -c cli,vlan "✓ Copied $file_rel (trunk-safe) to $node_ip:$remote_path"
        rm -f "$_cstn_tmp" 2>/dev/null
        return 0
    else
        error -c cli,vlan "✗ Failed to copy $file_rel to $node_ip:$remote_path"
        rm -f "$_cstn_tmp" 2>/dev/null
        return 1
    fi
}

# ============================================================================ #
# verify_settings_conf_on_node                                                 #
# Verify that settings.json was copied correctly to node. Check file exists,   #
# is non-empty, and contains valid JSON structure. Since we preserve node-     #
# specific values (Hardware, IS_NODE, NODE_ID) during copy, byte-level         #
# comparison is not appropriate - just verify basic integrity.                 #
# ============================================================================ #
verify_settings_conf_on_node() {
    node_id="$1"
    node_ip="$2"
    remote_file="$MERV_BASE/settings/settings.json"

    # Verify file exists on remote node
    if ! merv_ssh_exec "$node_id" "$node_ip" "test -f '$remote_file' && echo 'exists'" | grep -q "exists"; then
        error -c cli,vlan "✗ settings.json not found on $node_ip at $remote_file"
        return 1
    fi

    # Check file is non-empty and contains basic JSON structure
    _vscon_check=$(merv_ssh_exec "$node_id" "$node_ip" "
        if [ ! -s '$remote_file' ]; then
            echo 'EMPTY'
            exit 1
        fi
        
        # Basic JSON validity: must have opening/closing braces and at least one key
        if ! grep -q '^{' '$remote_file' 2>/dev/null; then
            echo 'NO_OPENING_BRACE'
            exit 1
        fi
        if ! grep -q '^}' '$remote_file' 2>/dev/null; then
            echo 'NO_CLOSING_BRACE'
            exit 1
        fi
        
        # Count keys (should have multiple sections: General, SSH, Nodes, WiFi, VLAN, Hardware)
        key_count=\$(grep -c '\"[^\"]*\"[[:space:]]*:' '$remote_file' 2>/dev/null || echo 0)
        if [ \"\$key_count\" -lt 10 ]; then
            echo \"TOO_FEW_KEYS \$key_count\"
            exit 1
        fi
        
        # Verify critical sections exist
        if ! grep -q '\"General\"' '$remote_file' 2>/dev/null; then
            echo 'MISSING_GENERAL'
            exit 1
        fi
        if ! grep -q '\"VLAN\"' '$remote_file' 2>/dev/null; then
            echo 'MISSING_VLAN'
            exit 1
        fi
        
        echo 'OK'
    " 2>&1)

    _vscon_result=$(echo "$_vscon_check" | tail -n 1 | tr -d '\r\n')
    
    if [ "$_vscon_result" = "OK" ]; then
        info -c cli,vlan "✓ Verified settings.json on $node_ip (structure valid)"
        return 0
    elif echo "$_vscon_result" | grep -q "EMPTY"; then
        error -c cli,vlan "✗ settings.json is empty on $node_ip"
        return 1
    elif echo "$_vscon_result" | grep -q "TOO_FEW_KEYS"; then
        key_count=$(echo "$_vscon_result" | awk '{print $2}')
        error -c cli,vlan "✗ settings.json appears incomplete on $node_ip (only $key_count keys found)"
        return 1
    elif echo "$_vscon_result" | grep -q "MISSING"; then
        error -c cli,vlan "✗ settings.json missing critical sections on $node_ip: $_vscon_result"
        return 1
    else
        warn -c cli,vlan "⚠️ Unable to verify settings.json on $node_ip (check: $_vscon_result)"
        # Don't fail - file exists and was copied, verification just couldn't complete
        return 0
    fi
}

# ============================================================================ #
# sync_settings_conf_for_node                                                  #
# Orchestrate settings synchronization for a single node. Check JFFS status,   #
# copy settings.json, and verify successful transfer.                          #
# ============================================================================ #
sync_settings_conf_for_node() {
    node_id="$1"
    node_ip="$2"

    # Verify JFFS is enabled on node (abort if not)
    if ! ensure_jffs_ready "$node_id" "$node_ip"; then
        return 1
    fi

    # Copy local settings.json to remote node
    if ! copy_settings_conf_to_node "$node_id" "$node_ip"; then
        return 1
    fi

    # Verify that settings.json transferred correctly
    if ! verify_settings_conf_on_node "$node_id" "$node_ip"; then
        return 1
    fi

    return 0
}

# set_node_flags_remote — Ensure IS_NODE=1 and NODE_ID are set on remote settings.json
# Only writes if values are missing or incorrect (to avoid unnecessary file modifications)
set_node_flags_remote() {
    node_id="$1"
    node_ip="$2"
    node_flags=""
    node_flag_value=""
    node_id_value=""
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
        
        # Read current values
        current_is_node=\$(json_get_flag IS_NODE '' \"\$SETTINGS_FILE\" 2>/dev/null)
        current_node_id=\$(json_get_flag NODE_ID '' \"\$SETTINGS_FILE\" 2>/dev/null)
        
        # Only write if values are missing or incorrect
        if [ \"\$current_is_node\" != \"1\" ]; then
            json_set_flag IS_NODE 1 \"\$SETTINGS_FILE\" || exit 1
        fi
        if [ \"\$current_node_id\" != \"$node_id\" ]; then
            json_set_flag NODE_ID \"$node_id\" \"\$SETTINGS_FILE\" || exit 1
        fi
        
        # Return final values for verification
        json_get_flag IS_NODE 0 \"\$SETTINGS_FILE\"
        json_get_flag NODE_ID \"none\" \"\$SETTINGS_FILE\"
    "

    node_flags=$(merv_ssh_exec "$node_id" "$node_ip" "$remote_cmd")
    node_flag_value=$(echo "$node_flags" | tail -n 2 | head -n 1 | tr -d '\r\n')
    node_id_value=$(echo "$node_flags" | tail -n 1 | tr -d '\r\n')

    if [ "$node_flag_value" = "1" ] && [ "$node_id_value" = "$node_id" ]; then
        info -c cli,vlan "✓ Verified IS_NODE=1 and NODE_ID=$node_id on $node_ip"
        return 0
    fi

    error -c cli,vlan "✗ Failed to verify IS_NODE/NODE_ID on $node_ip (IS_NODE='$node_flag_value', NODE_ID='$node_id_value')"
    return 1
}

# Verify local settings.json exists before proceeding with any node operations
if ! ensure_settings_conf_exists; then
    exit 1
fi

# ============================================================================ #
# verify_node_completion                                                       #
# Check if a node has completed mervlan_manager execution by reading its       #
# completion marker file. Returns 0 if complete, 1 if not.                     #
# ============================================================================ #
verify_node_completion() {
    node_id="$1"
    node_ip="$2"
    marker_file="/tmp/mervlan_tmp/results/node_complete/node_${node_id}.marker"
    
    # Read the completion marker from the node
    marker_content=$(merv_ssh_exec "$node_id" "$node_ip" "cat '$marker_file' 2>/dev/null")
    
    if [ -n "$marker_content" ]; then
        info -c cli,vlan "✓ Node $node_ip (NODE${node_id}) completed: $marker_content"
        return 0
    else
        warn -c cli,vlan "✗ Node $node_ip (NODE${node_id}) completion marker not found"
        return 1
    fi
}

# ============================================================================ #
# clear_node_completion_marker                                                 #
# Remove the completion marker on a node before execution starts.              #
# ============================================================================ #
clear_node_completion_marker() {
    node_id="$1"
    node_ip="$2"
    marker_dir="/tmp/mervlan_tmp/results/node_complete"
    marker_file="$marker_dir/node_${node_id}.marker"
    
    # Ensure directory exists and clear any old marker
    merv_ssh_exec "$node_id" "$node_ip" "mkdir -p '$marker_dir' && rm -f '$marker_file'" >/dev/null 2>&1
}

# ============================================================================ #
# execute_vlan_manager_on_node                                                 #
# Invoke mervlan_manager.sh on a remote node via SSH. Logs all steps and       #
# captures output. Returns 0 on success, 1 on failure.                         #
# ============================================================================ #
execute_vlan_manager_on_node() {
    node_id="$1"
    node_ip="$2"
    remote_vlan_manager=""
    remote_vlan_manager="$(printf '%s' "$MERV_BASE/functions/mervlan_manager.sh" | tr -d '\r')"
    
    info -c cli,vlan "Executing VLAN manager on $node_ip..."

    # Ensure the script exists on the remote node before attempting execution
    if ! merv_ssh_exec "$node_id" "$node_ip" "test -f '$remote_vlan_manager'" >/dev/null 2>&1; then
        error -c cli,vlan "✗ VLAN manager script missing on $node_ip at $remote_vlan_manager"
        warn  -c cli,vlan "   Run 'Sync Nodes' to deploy the addon before executing nodes"
        return 1
    fi

    # Execute the remote script and capture its output for logging/diagnostics
    output=""
    output=$(merv_ssh_exec "$node_id" "$node_ip" "cd '$MERV_BASE' && sh '$remote_vlan_manager'" 2>&1)
    rc=$?

    if [ $rc -eq 0 ]; then
        info -c cli,vlan "✓ Successfully executed VLAN manager on $node_ip"
        if [ -n "$output" ]; then
            printf '%s\n' "$output" >>"$CLI_LOG"
        fi
        return 0
    else
        error -c cli,vlan "✗ Failed to execute VLAN manager on $node_ip (rc=$rc)"
        if [ -n "$output" ]; then
            printf '%s\n' "$output" >>"$CLI_LOG"
        fi
        return 1
    fi
}

# ============================================================================ #
#                      MAIN NODE EXECUTION LOOP                                #
# Phase 1: Prepare nodes (connectivity, sync settings, set flags)              #
# Phase 2: Execute VLAN manager on all nodes in parallel                       #
# Phase 3: Verify completion of all nodes before proceeding                    #
# ============================================================================ #

info -c cli,vlan "Starting VLAN manager execution on nodes..."
overall_success=true
local_success=true

# Track which nodes are ready for execution
READY_NODES=""

# ============================================================================ #
# PHASE 1: Prepare all nodes (sequential - required before parallel exec)     #
# ============================================================================ #
info -c cli,vlan "--- Phase 1: Preparing nodes ---"

while read -r node_id node_ip; do
    [ -n "$node_id" ] || continue
    info -c cli,vlan "Preparing node: $node_ip (NODE${node_id})"
    
    # Use wrapper precheck (validates IP, keys, and ping in one call)
    if ! merv_ssh_precheck "$node_id" "$node_ip"; then
        merv_ssh_skip_log "$node_id" "$node_ip" "execute"
        overall_success=false
        continue
    fi
    
    # Test SSH connectivity; skip node if SSH fails
    if ! test_ssh_connection "$node_id" "$node_ip"; then
        merv_ssh_skip_log "$node_id" "$node_ip" "execute"
        overall_success=false
        continue
    fi
    
    info -c cli,vlan "✓ SSH connection successful to $node_ip"

    # Verify JFFS and copy settings.json to node
    if ! sync_settings_conf_for_node "$node_id" "$node_ip"; then
        overall_success=false
        continue
    fi

    # Set IS_NODE and NODE_ID on the remote node before execution
    if ! set_node_flags_remote "$node_id" "$node_ip"; then
        overall_success=false
        continue
    fi
    
    # Clear any old completion marker before execution
    clear_node_completion_marker "$node_id" "$node_ip"
    
    # Add to ready list
    READY_NODES="$READY_NODES
$node_id $node_ip"
done <<EOF
$NODE_IPS
EOF

# Trim leading newline
READY_NODES=$(echo "$READY_NODES" | sed '/^$/d')

if [ -z "$READY_NODES" ]; then
    warn -c cli,vlan "No nodes ready for execution"
    
    # Still run main router if not in nodesonly mode
    if [ "$MODE" != "nodesonly" ]; then
        info -c cli,vlan "Executing VLAN manager on main router (no nodes)..."
        local_script="$(printf '%s' "$MERV_BASE/functions/mervlan_manager.sh" | tr -d '\r')"
        if [ -f "$local_script" ]; then
            # No nodes, so run with collect_clients included
            sh "$local_script" >>"$CLI_LOG" 2>&1
            local_success=$?
        fi
    fi
else
    # ============================================================================ #
    # PHASE 2: Execute VLAN manager on ALL in parallel (nodes + main router)     #
    # ============================================================================ #
    info -c cli,vlan "--- Phase 2: Executing on all routers in parallel ---"
    
    # Launch node executions in background
    while read -r node_id node_ip; do
        [ -n "$node_id" ] || continue
        info -c cli,vlan "Launching execution on $node_ip (NODE${node_id})..."
        execute_vlan_manager_on_node "$node_id" "$node_ip" &
    done <<EOF2
$READY_NODES
EOF2
    
    # Launch main router execution in background (with --no-collect flag)
    if [ "$MODE" != "nodesonly" ]; then
        info -c cli,vlan "Launching execution on main router..."
        local_script="$(printf '%s' "$MERV_BASE/functions/mervlan_manager.sh" | tr -d '\r')"
        if [ -f "$local_script" ]; then
            sh "$local_script" --no-collect >>"$CLI_LOG" 2>&1 &
            main_pid=$!
        fi
    fi
    
    # Wait for all background executions to complete
    info -c cli,vlan "Waiting for all executions to complete..."
    wait
    info -c cli,vlan "All executions finished"
    
    # Check if main router succeeded (if we ran it)
    if [ "$MODE" != "nodesonly" ]; then
        # wait already completed, check if script ran
        if [ -f "$local_script" ]; then
            info -c cli,vlan "✓ Main router execution completed"
            local_success=true
        else
            error -c cli,vlan "✗ Local VLAN manager script missing"
            local_success=false
        fi
    fi
    
    # ============================================================================ #
    # PHASE 3: Verify completion markers on all nodes                            #
    # ============================================================================ #
    info -c cli,vlan "--- Phase 3: Verifying node completions ---"
    
    while read -r node_id node_ip; do
        [ -n "$node_id" ] || continue
        if ! verify_node_completion "$node_id" "$node_ip"; then
            overall_success=false
        fi
    done <<EOF3
$READY_NODES
EOF3
    
    # ============================================================================ #
    # PHASE 4: Run collect_clients.sh after all nodes verified                   #
    # ============================================================================ #
    if [ "$MODE" != "nodesonly" ] && [ -x "$FUNCDIR/collect_clients.sh" ]; then
        info -c cli,vlan "--- Phase 4: Collecting clients ---"
        info -c cli,vlan "Waiting 5 seconds before refreshing VLAN client list..."
        sleep 5
        info -c cli,vlan "Refreshing VLAN client list via collect_clients.sh"
        if "$FUNCDIR/collect_clients.sh"; then
            info -c cli,vlan "✓ VLAN client list refresh completed"
        else
            rc=$?
            warn -c cli,vlan "✗ collect_clients.sh failed (rc=$rc)"
        fi
    fi
fi

echo ""

# ============================================================================ #
#                        EXECUTION SUMMARY                                     #
# Report overall success or failure based on node and main router execution    #
# results. Exit with appropriate code (0=success, 1=failure).                  #
# ============================================================================ #

info -c cli,vlan "=== Execution Summary ==="

# Final cleanup: clear all node completion markers to prevent false positives
if [ -n "$READY_NODES" ]; then
    info -c cli,vlan "Cleaning up node completion markers..."
    while read -r node_id node_ip; do
        [ -n "$node_id" ] || continue
        clear_node_completion_marker "$node_id" "$node_ip"
    done <<EOFCLEAN
$READY_NODES
EOFCLEAN
fi

if [ "$overall_success" = "true" ] && [ "$local_success" = "true" ]; then
    if [ "$MODE" = "nodesonly" ]; then
        info -c cli,vlan "✓ SUCCESS: VLAN manager executed on all nodes (main router skipped)"
    else
        info -c cli,vlan "✓ SUCCESS: VLAN manager executed on all nodes and main router"
    fi
    exit 0
else
    warn -c cli,vlan "⚠️  PARTIAL SUCCESS: See details above (nodes or main may have failed)"
    info -c cli,vlan "Check the log at $CLI_LOG for details"
    exit 1
fi
