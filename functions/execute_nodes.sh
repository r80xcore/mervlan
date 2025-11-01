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
#                - File: execute_nodes.sh || version: 0.45                     #
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

info -c cli,vlan "=== VLAN Manager Node Execution ==="
info -c cli,vlan ""


# Check if settings file exists
if [ ! -f "$SETTINGS_FILE" ]; then
    error -c cli,vlan "ERROR: Settings file not found at $SETTINGS_FILE"
    exit 1
fi

# Check if SSH keys are installed according to settings
if ! grep -q '"SSH_KEYS_INSTALLED"[[:space:]]*:[[:space:]]*"1"' "$GENERAL_SETTINGS_FILE"; then
    error -c cli,vlan "ERROR: SSH keys are not installed according to general.json"
    warn -c cli,vlan "Please click on 'SSH Key Install' and follow the instructions"
    exit 1
fi

# Check if SSH key files exist
if [ ! -f "$SSH_KEY" ] || [ ! -f "$SSH_PUBKEY" ]; then
    error -c cli,vlan "ERROR: SSH key files not found"
    warn -c cli,vlan "Please run the SSH key generator first"
    exit 1
fi

# Check if public key is installed in /root/.ssh/authorized_keys
PUBKEY_CONTENT=$(cat "$SSH_PUBKEY")
if [ ! -f /root/.ssh/authorized_keys ] || ! grep -qF "$PUBKEY_CONTENT" /root/.ssh/authorized_keys; then
    error -c cli,vlan "ERROR: SSH public key not found in /root/.ssh/authorized_keys"
    warn -c cli,vlan "Please install the SSH keys using the 'SSH Key Install' feature"
    info -c cli,vlan "If already done, try rebooting both the main router and nodes"
    exit 1
fi

info -c cli,vlan "✓ SSH key verification passed"

# Get node IPs from settings.json
get_node_ips() {
    grep -o '"NODE[1-5]"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" | \
    sed -n 's/.*:[[:space:]]*"\([^"]*\)".*/\1/p' | \
    grep -v "none" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

NODE_IPS=$(get_node_ips)

if [ -z "$NODE_IPS" ]; then
    warn -c cli,vlan "No nodes configured in settings.json"
    exit 0
fi

info -c cli,vlan "Found nodes: $(echo "$NODE_IPS" | tr '\n' ' ')"
echo ""

# Function to check if JFFS and JFFS scripts are enabled
check_remote_jffs_status() {
    local node_ip="$1"
    local output

    output=$(dbclient -y -i "$SSH_KEY" -o ConnectTimeout=5 -o PasswordAuthentication=no "admin@$node_ip" "nvram get jffs2_on 2>/dev/null; nvram get jffs2_scripts 2>/dev/null" 2>/dev/null)
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo ""
        return 2
    fi

    local jffs_on
    local jffs_scripts
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

# Function to test SSH connection to a node
test_ssh_connection() {
    local node_ip="$1"
    if dbclient -y -i "$SSH_KEY" -o ConnectTimeout=5 -o PasswordAuthentication=no "admin@$node_ip" "echo connected" 2>/dev/null | grep -q "connected"; then
        return 0
    else
        return 1
    fi
}

ensure_jffs_ready() {
    local node_ip="$1"
    local jffs_status

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

ensure_settings_conf_exists() {
    if [ ! -f "$SETTINGS_FILE" ]; then
        error -c cli,vlan "ERROR: settings.json not found at $SETTINGS_FILE"
        return 1
    fi
    return 0
}

ensure_remote_settings_dir() {
    local node_ip="$1"
    local remote_dir="$SETTINGSDIR"

    if dbclient -y -i "$SSH_KEY" "admin@$node_ip" "mkdir -p '$remote_dir'" 2>/dev/null; then
        info -c cli,vlan "✓ Ensured directory $remote_dir on $node_ip"
        return 0
    else
        error -c cli,vlan "✗ Failed to create directory $remote_dir on $node_ip"
        return 1
    fi
}

copy_settings_conf_to_node() {
    local node_ip="$1"
    local file_rel="settings/settings.json"
    local remote_path="$MERV_BASE/$file_rel"

    info -c cli,vlan "Copying $file_rel to $node_ip"

    if ! ensure_remote_settings_dir "$node_ip"; then
        return 1
    fi

    if cat "$SETTINGS_FILE" | dbclient -y -i "$SSH_KEY" "admin@$node_ip" "cat > '${remote_path}.tmp' && mv '${remote_path}.tmp' '${remote_path}'" 2>/dev/null; then
        info -c cli,vlan "✓ Copied $file_rel to $node_ip:$remote_path"
        return 0
    else
        error -c cli,vlan "✗ Failed to copy $file_rel to $node_ip:$remote_path"
        return 1
    fi
}

verify_settings_conf_on_node() {
    local node_ip="$1"
    local remote_file="$MERV_BASE/settings/settings.json"

    if ! dbclient -y -i "$SSH_KEY" "admin@$node_ip" "test -f '$remote_file' && echo 'exists'" 2>/dev/null | grep -q "exists"; then
        error -c cli,vlan "✗ settings.json not found on $node_ip at $remote_file"
        return 1
    fi

    local remote_size=$(dbclient -y -i "$SSH_KEY" "admin@$node_ip" "stat -c%s '$remote_file' 2>/dev/null || wc -c < '$remote_file' 2>/dev/null || echo 0" 2>/dev/null)
    local local_size=$(stat -c%s "$SETTINGS_FILE" 2>/dev/null || wc -c < "$SETTINGS_FILE" 2>/dev/null || echo 0)

    remote_size=$(echo "$remote_size" | tr -cd '0-9')
    local_size=$(echo "$local_size" | tr -cd '0-9')

    if [ "$remote_size" -ne "$local_size" ] || [ "$remote_size" -eq 0 ]; then
        error -c cli,vlan "⚠️  Size mismatch for settings.json on $node_ip (local: $local_size, remote: $remote_size)"
        return 1
    fi

    local local_md5=""
    local remote_md5=""

    if command -v md5sum >/dev/null 2>&1; then
        local_md5=$(md5sum "$SETTINGS_FILE" 2>/dev/null | awk '{print $1}')
    elif command -v md5 >/dev/null 2>&1; then
        local_md5=$(md5 -r "$SETTINGS_FILE" 2>/dev/null | awk '{print $1}')
    fi

    if [ -n "$local_md5" ]; then
        remote_md5=$(dbclient -y -i "$SSH_KEY" "admin@$node_ip" "if command -v md5sum >/dev/null 2>&1; then md5sum '$remote_file' 2>/dev/null | awk '{print \\$1}'; elif command -v md5 >/dev/null 2>&1; then md5 -r '$remote_file' 2>/dev/null | awk '{print \\$1}'; else echo NA; fi" 2>/dev/null)
        remote_md5=$(echo "$remote_md5" | head -n 1 | tr -cd 'a-fA-F0-9')

        if [ -n "$remote_md5" ] && [ "$remote_md5" != "NA" ]; then
            if [ "$local_md5" != "$remote_md5" ]; then
                error -c cli,vlan "✗ MD5 mismatch for settings.json on $node_ip (local: $local_md5, remote: $remote_md5)"
                return 1
            fi
            info -c cli,vlan "✓ Verified settings.json on $node_ip (size: $remote_size bytes, md5 ok)"
            return 0
        fi
    fi

    info -c cli,vlan "✓ Verified settings.json on $node_ip (size: $remote_size bytes)"
    return 0
}

sync_settings_conf_for_node() {
    local node_ip="$1"

    if ! ensure_jffs_ready "$node_ip"; then
        return 1
    fi

    if ! copy_settings_conf_to_node "$node_ip"; then
        return 1
    fi

    if ! verify_settings_conf_on_node "$node_ip"; then
        return 1
    fi

    return 0
}

# Ensure local settings.json exists before proceeding
if ! ensure_settings_conf_exists; then
    exit 1
fi

# Function to execute VLAN manager on a node
execute_vlan_manager_on_node() {
    local node_ip="$1"
    local remote_vlan_manager="$MERV_BASE/functions/mervlan_manager.sh"
    
    info -c cli,vlan "Executing VLAN manager on $node_ip..."
    
    # Execute the VLAN manager script on the remote node
    if dbclient -y -i "$SSH_KEY" "admin@$node_ip" "cd $MERV_BASE && $remote_vlan_manager" 2>/dev/null; then
        info -c cli,vlan "✓ Successfully executed VLAN manager on $node_ip"
        return 0
    else
        error -c cli,vlan "✗ Failed to execute VLAN manager on $node_ip"
        return 1
    fi
}

# Main execution process
info -c cli,vlan "Starting VLAN manager execution on nodes..."
overall_success=true

for node_ip in $NODE_IPS; do
    info -c cli,vlan "Processing node: $node_ip"
    
    # Test connectivity
    if ! ping -c 1 -W 2 "$node_ip" >/dev/null 2>&1; then
        error -c cli,vlan "✗ Node $node_ip is not reachable via ping"
        overall_success=false
        continue
    fi
    
    # Test SSH connection
    if ! test_ssh_connection "$node_ip"; then
        error -c cli,vlan "✗ SSH connection failed to $node_ip"
        info -c cli,vlan "   Check if SSH key is properly installed on the node"
        overall_success=false
        continue
    fi
    
    info -c cli,vlan "✓ SSH connection successful to $node_ip"

    # Ensure JFFS and synchronize settings.json before execution
    if ! sync_settings_conf_for_node "$node_ip"; then
        overall_success=false
        continue
    fi
    
    # Execute VLAN manager on the node
    if ! execute_vlan_manager_on_node "$node_ip"; then
        overall_success=false
    fi
    
    info -c cli,vlan "--- Completed node: $node_ip ---"
    echo ""
done

# Execute on main router after nodes
info -c cli,vlan "Executing VLAN manager on main router..."
local_success=true
if "$ACTDIR/run_vlan.sh" >> "$CLI_LOG" 2>&1; then
  info -c cli,vlan "✓ Successfully executed VLAN manager on main router"
  local_success=true
else
  error -c cli,vlan "✗ Failed to execute VLAN manager on main router"
  local_success=false
fi

# Summary
info -c cli,vlan "=== Execution Summary ==="

if [ "$overall_success" = "true" ] && [ "$local_success" = "true" ]; then
  info -c cli,vlan "✓ SUCCESS: VLAN manager executed on all nodes and main router"
  exit 0
else
  warn -c cli,vlan "⚠️  PARTIAL SUCCESS: See details above (nodes or main may have failed)"
  info -c cli,vlan "Check the log at $CLI_LOG for details"
  exit 1
fi
