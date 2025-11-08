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
#                - File: execute_nodes.sh || version="0.46"                    #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Execute the MerVLAN Manager on configured nodes via SSH using  #
#               the settings defined in settings.json.                         #
# ──────────────────────────────────────────────────────────────────────────── #
#                                                                              #
# ================================================== MerVLAN environment setup #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
# =========================================== End of MerVLAN environment setup #

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

# Verify SSH keys are marked as installed in general.json
if ! grep -q '"SSH_KEYS_INSTALLED"[[:space:]]*:[[:space:]]*"1"' "$GENERAL_SETTINGS_FILE"; then
    error -c cli,vlan "ERROR: SSH keys are not installed according to general.json"
    warn -c cli,vlan "Please click on 'SSH Key Install' and follow the instructions"
    exit 1
fi

# Verify SSH key pair files actually exist on filesystem
if [ ! -f "$SSH_KEY" ] || [ ! -f "$SSH_PUBKEY" ]; then
    error -c cli,vlan "ERROR: SSH key files not found"
    warn -c cli,vlan "Please run the SSH key generator first"
    exit 1
fi

# Verify public key is installed in authorized_keys on this router
PUBKEY_CONTENT=$(cat "$SSH_PUBKEY")
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
    sed -n 's/.*:[[:space:]]*"\([^"]*\)".*/\1/p' | \
    grep -v "none" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

NODE_IPS=$(get_node_ips)

# Check if any nodes are configured
if [ -z "$NODE_IPS" ]; then
    warn -c cli,vlan "No nodes configured in settings.json"
    exit 0
fi

info -c cli,vlan "Found nodes: $(echo "$NODE_IPS" | tr '\n' ' ')"
echo ""

# ============================================================================ #
# check_remote_jffs_status                                                     #
# Query remote node's JFFS and JFFS scripts settings via SSH. Returns          #
# status string "jffs2_on jffs2_scripts" or error code 2 on SSH failure.       #
# ============================================================================ #
check_remote_jffs_status() {
    local node_ip="$1"
    local output

    # Execute remote nvram queries and capture output
    output=$(dbclient -y -i "$SSH_KEY" -o ConnectTimeout=5 -o PasswordAuthentication=no "admin@$node_ip" "nvram get jffs2_on 2>/dev/null; nvram get jffs2_scripts 2>/dev/null" 2>/dev/null)
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo ""
        return 2
    fi

    # Extract first line (jffs2_on) and second line (jffs2_scripts); strip carriage returns
    local jffs_on
    local jffs_scripts
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
    local node_ip="$1"
    # Attempt to SSH and run echo; grep for success string to verify connection
    if dbclient -y -i "$SSH_KEY" -o ConnectTimeout=5 -o PasswordAuthentication=no "admin@$node_ip" "echo connected" 2>/dev/null | grep -q "connected"; then
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
    local node_ip="$1"
    local jffs_status

    # Query JFFS status; success means both jffs2_on and jffs2_scripts are 1
    if jffs_status=$(check_remote_jffs_status "$node_ip"); then
        info -c cli,vlan "✓ JFFS already enabled on $node_ip"
        return 0
    else
        local status=$?
        local jffs_on
        local jffs_scripts
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
    local node_ip="$1"
    local remote_dir="$SETTINGSDIR"

    # Attempt to create settings directory on remote node
    if dbclient -y -i "$SSH_KEY" "admin@$node_ip" "mkdir -p '$remote_dir'" 2>/dev/null; then
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
# Uses atomic rename to avoid partial file reads. Logs all steps.              #
# ============================================================================ #
copy_settings_conf_to_node() {
    local node_ip="$1"
    local file_rel="settings/settings.json"
    local remote_path="$MERV_BASE/$file_rel"

    info -c cli,vlan "Copying $file_rel to $node_ip"

    # Ensure remote directory exists before copying
    if ! ensure_remote_settings_dir "$node_ip"; then
        return 1
    fi

    # Use cat pipe through SSH with atomic rename (write to .tmp then mv)
    if cat "$SETTINGS_FILE" | dbclient -y -i "$SSH_KEY" "admin@$node_ip" "cat > '${remote_path}.tmp' && mv '${remote_path}.tmp' '${remote_path}'" 2>/dev/null; then
        info -c cli,vlan "✓ Copied $file_rel to $node_ip:$remote_path"
        return 0
    else
        error -c cli,vlan "✗ Failed to copy $file_rel to $node_ip:$remote_path"
        return 1
    fi
}

# ============================================================================ #
# verify_settings_conf_on_node                                                 #
# Verify that settings.json was copied correctly to node. Check file exists,   #
# compare file sizes, and validate MD5 checksums if available.                 #
# ============================================================================ #
verify_settings_conf_on_node() {
    local node_ip="$1"
    local remote_file="$MERV_BASE/settings/settings.json"

    # Verify file exists on remote node
    if ! dbclient -y -i "$SSH_KEY" "admin@$node_ip" "test -f '$remote_file' && echo 'exists'" 2>/dev/null | grep -q "exists"; then
        error -c cli,vlan "✗ settings.json not found on $node_ip at $remote_file"
        return 1
    fi

    # Compare file sizes (local vs remote)
    local remote_size=$(dbclient -y -i "$SSH_KEY" "admin@$node_ip" "stat -c%s '$remote_file' 2>/dev/null || wc -c < '$remote_file' 2>/dev/null || echo 0" 2>/dev/null)
    local local_size=$(stat -c%s "$SETTINGS_FILE" 2>/dev/null || wc -c < "$SETTINGS_FILE" 2>/dev/null || echo 0)

    # Extract numeric values; strip any non-digit characters
    remote_size=$(echo "$remote_size" | tr -cd '0-9')
    local_size=$(echo "$local_size" | tr -cd '0-9')

    # Fail if sizes don't match or file is empty
    if [ "$remote_size" -ne "$local_size" ] || [ "$remote_size" -eq 0 ]; then
        error -c cli,vlan "⚠️  Size mismatch for settings.json on $node_ip (local: $local_size, remote: $remote_size)"
        return 1
    fi

    # Attempt MD5 checksum verification if md5sum/md5 available
    local local_md5=""
    local remote_md5=""

    if command -v md5sum >/dev/null 2>&1; then
        local_md5=$(md5sum "$SETTINGS_FILE" 2>/dev/null | awk '{print $1}')
    elif command -v md5 >/dev/null 2>&1; then
        local_md5=$(md5 -r "$SETTINGS_FILE" 2>/dev/null | awk '{print $1}')
    fi

    # If we have a local MD5, fetch remote MD5 and compare
    if [ -n "$local_md5" ]; then
        remote_md5=$(dbclient -y -i "$SSH_KEY" "admin@$node_ip" "if command -v md5sum >/dev/null 2>&1; then md5sum '$remote_file' 2>/dev/null | awk '{print \\$1}'; elif command -v md5 >/dev/null 2>&1; then md5 -r '$remote_file' 2>/dev/null | awk '{print \\$1}'; else echo NA; fi" 2>/dev/null)
        remote_md5=$(echo "$remote_md5" | head -n 1 | tr -cd 'a-fA-F0-9')

        # Compare MD5s if remote MD5 was successfully computed
        if [ -n "$remote_md5" ] && [ "$remote_md5" != "NA" ]; then
            if [ "$local_md5" != "$remote_md5" ]; then
                error -c cli,vlan "✗ MD5 mismatch for settings.json on $node_ip (local: $local_md5, remote: $remote_md5)"
                return 1
            fi
            info -c cli,vlan "✓ Verified settings.json on $node_ip (size: $remote_size bytes, md5 ok)"
            return 0
        fi
    fi

    # If no MD5 available, consider verification complete based on size
    info -c cli,vlan "✓ Verified settings.json on $node_ip (size: $remote_size bytes)"
    return 0
}

# ============================================================================ #
# sync_settings_conf_for_node                                                  #
# Orchestrate settings synchronization for a single node. Check JFFS status,   #
# copy settings.json, and verify successful transfer.                          #
# ============================================================================ #
sync_settings_conf_for_node() {
    local node_ip="$1"

    # Verify JFFS is enabled on node (abort if not)
    if ! ensure_jffs_ready "$node_ip"; then
        return 1
    fi

    # Copy local settings.json to remote node
    if ! copy_settings_conf_to_node "$node_ip"; then
        return 1
    fi

    # Verify that settings.json transferred correctly
    if ! verify_settings_conf_on_node "$node_ip"; then
        return 1
    fi

    return 0
}

# Verify local settings.json exists before proceeding with any node operations
if ! ensure_settings_conf_exists; then
    exit 1
fi

# ============================================================================ #
# execute_vlan_manager_on_node                                                 #
# Invoke mervlan_manager.sh on a remote node via SSH. Logs all steps and       #
# captures output. Returns 0 on success, 1 on failure.                         #
# ============================================================================ #
execute_vlan_manager_on_node() {
    local node_ip="$1"
    local remote_vlan_manager
    remote_vlan_manager="$(printf '%s' "$MERV_BASE/functions/mervlan_manager.sh" | tr -d '\r')"
    
    info -c cli,vlan "Executing VLAN manager on $node_ip..."

    # Ensure the script exists on the remote node before attempting execution
    if ! dbclient -y -i "$SSH_KEY" "admin@$node_ip" "test -f '$remote_vlan_manager'" 2>/dev/null; then
        error -c cli,vlan "✗ VLAN manager script missing on $node_ip at $remote_vlan_manager"
        warn  -c cli,vlan "   Run 'Sync Nodes' to deploy the addon before executing nodes"
        return 1
    fi

    # Execute the remote script and capture its output for logging/diagnostics
    local output
    output=$(dbclient -y -i "$SSH_KEY" "admin@$node_ip" "cd '$MERV_BASE' && sh '$remote_vlan_manager'" 2>&1)
    local rc=$?

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
# Iterate through all configured nodes. For each node, test connectivity,      #
# verify SSH, synchronize settings, and execute VLAN manager remotely.         #
# ============================================================================ #

info -c cli,vlan "Starting VLAN manager execution on nodes..."
overall_success=true

for node_ip in $NODE_IPS; do
    info -c cli,vlan "Processing node: $node_ip"
    
    # Test ping reachability; skip node if unreachable
    if ! ping -c 1 -W 2 "$node_ip" >/dev/null 2>&1; then
        error -c cli,vlan "✗ Node $node_ip is not reachable via ping"
        overall_success=false
        continue
    fi
    
    # Test SSH connectivity; skip node if SSH fails
    if ! test_ssh_connection "$node_ip"; then
        error -c cli,vlan "✗ SSH connection failed to $node_ip"
        info -c cli,vlan "   Check if SSH key is properly installed on the node"
        overall_success=false
        continue
    fi
    
    info -c cli,vlan "✓ SSH connection successful to $node_ip"

    # Verify JFFS and copy settings.json to node
    if ! sync_settings_conf_for_node "$node_ip"; then
        overall_success=false
        continue
    fi
    
    # Execute VLAN manager on the remote node
    if ! execute_vlan_manager_on_node "$node_ip"; then
        overall_success=false
    fi
    
    info -c cli,vlan "--- Completed node: $node_ip ---"
    echo ""
done

# ============================================================================ #
#                     EXECUTE ON MAIN ROUTER                                   #
# After all nodes have been configured, run VLAN manager on main router        #
# to apply the final consolidated settings.                                    #
# ============================================================================ #

local_success=true

if [ "$MODE" = "nodesonly" ]; then
    info -c cli,vlan "Skipping VLAN manager execution on main router (nodes-only mode)"
else
    info -c cli,vlan "Executing VLAN manager on main router..."
    local local_script
    local_script="$(printf '%s' "$MERV_BASE/functions/mervlan_manager.sh" | tr -d '\r')"

    if [ ! -f "$local_script" ]; then
        error -c cli,vlan "✗ Local VLAN manager script missing at $local_script"
        local_success=false
    else
        if sh "$local_script" >>"$CLI_LOG" 2>&1; then
            info -c cli,vlan "✓ Successfully executed VLAN manager on main router"
            local_success=true
        else
            error -c cli,vlan "✗ Failed to execute VLAN manager on main router"
            local_success=false
        fi
    fi
fi

# ============================================================================ #
#                        EXECUTION SUMMARY                                     #
# Report overall success or failure based on node and main router execution    #
# results. Exit with appropriate code (0=success, 1=failure).                  #
# ============================================================================ #

info -c cli,vlan "=== Execution Summary ==="

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
