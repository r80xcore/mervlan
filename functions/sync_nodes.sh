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
#               - File: sync_nodes.sh || version="0.46"                        #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Synchronize MerVLAN addon files to nodes using SSH keys        #
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

# ========================================================================== #
# FILE SYNC SETUP — Source/destination lists and synchronization parameters  #
# ========================================================================== #

# FILES_TO_COPY — Files to replicate to each node (preserves folder structure)
# Includes settings, shell helpers, and service templates required for MerVLAN
FILES_TO_COPY="
settings/settings.json 
settings/hw_settings.json 
settings/var_settings.sh 
settings/log_settings.sh 
functions/mervlan_boot.sh
functions/mervlan_manager.sh 
functions/collect_local_clients.sh 
functions/heal_event.sh  
settings/services-start.tpl 
settings/service-event.tpl
settings/service-event-nodes.tpl
settings/services-start-addon.tpl
"

# FILES_TO_COPY_CHMOD — Files requiring executable permissions on nodes (755)
FILES_TO_COPY_CHMOD="
functions/mervlan_boot.sh
functions/mervlan_manager.sh
functions/collect_local_clients.sh
functions/heal_event.sh
"
# FILES_TO_COPY_CHMOD_644 — Config scripts that should remain non-executable
FILES_TO_COPY_CHMOD_644="settings/var_settings.sh settings/log_settings.sh"

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

# ========================================================================== #
# PRE-FLIGHT VALIDATION — Ensure local configuration and SSH keys are ready  #
# ========================================================================== #

info -c cli,vlan "=== VLAN Manager File Synchronization ==="
info -c cli,vlan ""

# Check if settings file exists (required for node discovery and file paths)
if [ ! -f "$SETTINGS_FILE" ]; then
    error -c cli,vlan "ERROR: Settings file not found at $SETTINGS_FILE"
    exit 1
fi

# Validate UI flag indicating SSH keys were installed by the user
if ! grep -q '"SSH_KEYS_INSTALLED"[[:space:]]*:[[:space:]]*"1"' "$GENERAL_SETTINGS_FILE"; then
    error -c cli,vlan "ERROR: SSH keys are not installed according to general.json"
    warn -c cli,vlan "Please click on 'SSH Key Install' and follow the instructions"
    exit 1
fi

# Verify private/public key files exist on router before contacting nodes
if [ ! -f "$SSH_KEY" ] || [ ! -f "$SSH_PUBKEY" ]; then
    error -c cli,vlan "ERROR: SSH key files not found"
    warn -c cli,vlan "Please run the SSH key generator first"
    exit 1
fi

# Confirm server-side authorized_keys includes generated public key
# Without this, Dropbear rejects key-based logins during sync
PUBKEY_CONTENT=$(cat "$SSH_PUBKEY")
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

# ========================================================================== #
# SSH & JFFS HELPERS — Connectivity tests and persistent storage checks     #
# ========================================================================== #

# test_ssh_connection — Probe Dropbear SSH connectivity using key auth only
test_ssh_connection() {
    local node_ip="$1"
    if dbclient -y -i "$SSH_KEY" -o ConnectTimeout=5 -o PasswordAuthentication=no "admin@$node_ip" "echo connected" 2>/dev/null | grep -q "connected"; then
        return 0
    else
        return 1
    fi
}

# check_remote_jffs_status — Inspect nvram flags controlling persistent storage
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

# ========================================================================== #
# JFFS REMEDIATION — Enable persistent storage and wait for reboot cycle     #
# ========================================================================== #

# enable_jffs_and_reboot — Toggle nvram flags, commit, and trigger reboot
enable_jffs_and_reboot() {
    local node_ip="$1"

    info -c cli,vlan "Enabling JFFS and scripts on $node_ip and triggering reboot"

    if dbclient -y -i "$SSH_KEY" -o PasswordAuthentication=no "admin@$node_ip" "nvram set jffs2_on=1; nvram set jffs2_scripts=1; nvram commit; (sleep 2; reboot) &" 2>/dev/null; then
        info -c cli,vlan "✓ JFFS enable commands sent to $node_ip"
        return 0
    else
        local exit_code=$?
        if [ "$exit_code" = "255" ]; then
            info -c cli,vlan "✓ JFFS enable commands sent to $node_ip (connection closed during reboot)"
            return 0
        fi
        error -c cli,vlan "✗ Failed to send JFFS enable commands to $node_ip"
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
    local node_ip="$1"
    local attempt=0

    info -c cli,vlan "Waiting for SSH and /jffs on $node_ip ($SSH_MAX_ATTEMPTS attempts, ${SSH_RETRY_INTERVAL}s interval)"

    while [ $attempt -lt "$SSH_MAX_ATTEMPTS" ]; do
        if dbclient -y -i "$SSH_KEY" -o ConnectTimeout=5 -o PasswordAuthentication=no "admin@$node_ip" "test -d /jffs && ls /jffs >/dev/null 2>&1 && echo ready" 2>/dev/null | grep -q "ready"; then
            info -c cli,vlan "✓ SSH and /jffs ready on $node_ip"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep "$SSH_RETRY_INTERVAL"
    done

    error -c cli,vlan "✗ SSH or /jffs not ready on $node_ip after $SSH_MAX_ATTEMPTS attempts"
    return 1
}

# ensure_jffs_ready — Verify or remediate JFFS status before file sync
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
            warn -c cli,vlan "JFFS not fully enabled on $node_ip (jffs2_on=$jffs_on, jffs2_scripts=$jffs_scripts). Remediating..."

            if ! enable_jffs_and_reboot "$node_ip"; then
                return 1
            fi

            if ! wait_for_node_ping "$node_ip"; then
                return 1
            fi

            if ! wait_for_node_ssh_jffs "$node_ip"; then
                return 1
            fi

            if ! test_ssh_connection "$node_ip"; then
                error -c cli,vlan "✗ SSH connection failed to $node_ip after reboot"
                return 1
            fi

            if jffs_status=$(check_remote_jffs_status "$node_ip"); then
                info -c cli,vlan "✓ JFFS successfully enabled on $node_ip"
                return 0
            else
                error -c cli,vlan "✗ Unable to verify JFFS status on $node_ip after remediation"
                return 1
            fi
        else
            error -c cli,vlan "✗ Failed to determine JFFS status on $node_ip"
            return 1
        fi
    fi
}

# ========================================================================== #
# FILE OPERATIONS — Directory creation, copy, verification, permissions      #
# ========================================================================== #

# create_remote_dirs_for_file — Ensure remote path exists before copy
create_remote_dirs_for_file() {
    local node_ip="$1"
    local file="$2"
    
    # Extract directory path from file (if any)
    local dir_path=$(dirname "$file")
    
    # If file is in a subdirectory, create that directory on remote
    if [ "$dir_path" != "." ]; then
        local remote_dir="$MERV_BASE/$dir_path"
        if dbclient -y -i "$SSH_KEY" "admin@$node_ip" "mkdir -p '$remote_dir'" 2>/dev/null; then
            info -c cli,vlan "✓ Created directory $remote_dir on $node_ip"
            return 0
        else
            error -c cli,vlan "✗ Failed to create directory $remote_dir on $node_ip"
            return 1
        fi
    fi
    return 0
}

# copy_file_to_node — Stream file via SSH, using atomic temp file replacement
copy_file_to_node() {
    local node_ip="$1"
    local file="$2"
    local remote_path="$MERV_BASE/$file"
    
    # First create the necessary directory structure
    if ! create_remote_dirs_for_file "$node_ip" "$file"; then
        return 1
    fi
    
    # Use cat to copy the file content (always overwrite)
    if cat "$MERV_BASE/$file" | dbclient -y -i "$SSH_KEY" "admin@$node_ip" "cat > '${remote_path}.tmp' && mv '${remote_path}.tmp' '${remote_path}'" 2>/dev/null; then
        info -c cli,vlan "✓ Copied $file to $node_ip:$remote_path"
        return 0
    else
        error -c cli,vlan "✗ Failed to copy $file to $node_ip:$remote_path"
        return 1
    fi
}

# verify_file_on_node — Confirm remote file exists, matches size/optional hash
verify_file_on_node() {
    local node_ip="$1"
    local file="$2"
    local remote_file="$MERV_BASE/$file"
    
    # Check if file exists and has content
    if dbclient -y -i "$SSH_KEY" "admin@$node_ip" "test -f '$remote_file' && echo 'exists'" 2>/dev/null | grep -q "exists"; then
        # Check file size to ensure it's not empty
        local remote_size=$(dbclient -y -i "$SSH_KEY" "admin@$node_ip" "stat -c%s '$remote_file' 2>/dev/null || wc -c < '$remote_file' 2>/dev/null || echo 0" 2>/dev/null)
        local local_size=$(stat -c%s "$MERV_BASE/$file" 2>/dev/null || wc -c < "$MERV_BASE/$file" 2>/dev/null || echo 0)
        
        # Remove any extra characters from size
        remote_size=$(echo "$remote_size" | tr -cd '0-9')
        local_size=$(echo "$local_size" | tr -cd '0-9')
        
        if [ "$remote_size" -eq "$local_size" ] && [ "$remote_size" -gt 0 ]; then
            local local_md5=""
            local remote_md5=""

            if command -v md5sum >/dev/null 2>&1; then
                local_md5=$(md5sum "$MERV_BASE/$file" 2>/dev/null | awk '{print $1}')
            elif command -v md5 >/dev/null 2>&1; then
                local_md5=$(md5 -r "$MERV_BASE/$file" 2>/dev/null | awk '{print $1}')
            fi

            if [ -n "$local_md5" ]; then
                remote_md5=$(dbclient -y -i "$SSH_KEY" "admin@$node_ip" "if command -v md5sum >/dev/null 2>&1; then md5sum '$remote_file' 2>/dev/null | awk '{print \\$1}'; elif command -v md5 >/dev/null 2>&1; then md5 -r '$remote_file' 2>/dev/null | awk '{print \\$1}'; else echo NA; fi" 2>/dev/null)
                remote_md5=$(echo "$remote_md5" | head -n 1 | tr -cd 'a-fA-F0-9')

                if [ -n "$remote_md5" ] && [ "$remote_md5" != "NA" ]; then
                    if [ "$local_md5" != "$remote_md5" ]; then
                        error -c cli,vlan "✗ MD5 mismatch for $file on $node_ip (local: $local_md5, remote: $remote_md5)"
                        return 1
                    fi
                    info -c cli,vlan "✓ Verified $file on $node_ip (size: $remote_size bytes, md5 ok)"
                    return 0
                fi
            fi

            info -c cli,vlan "✓ Verified $file on $node_ip (size: $remote_size bytes)"
            return 0
        else
            error -c cli,vlan "⚠️  Size mismatch for $file on $node_ip (local: $local_size, remote: $remote_size)"
            # Don't fail verification for size mismatch, just warn
            return 0
        fi
    else
        error -c cli,vlan "✗ File $file not found on $node_ip at $remote_file"
        return 1
    fi
}

# set_remote_permissions — Apply 755 to scripts that must be executable
set_remote_permissions() {
    local node_ip="$1"
    local file="$2"
    local remote_file="$MERV_BASE/$file"
    
    if dbclient -y -i "$SSH_KEY" "admin@$node_ip" "chmod 755 '$remote_file' 2>/dev/null; echo 'permissions_set'" 2>/dev/null | grep -q "permissions_set"; then
        info -c cli,vlan "✓ Set executable permissions for $file on $node_ip"
        return 0
    else
        error -c cli,vlan "⚠️  Could not set permissions for $file on $node_ip"
        return 1
    fi
}

# set_remote_permissions_644 — Ensure sourced configs stay non-executable
set_remote_permissions_644() {
    local node_ip="$1"
    local file="$2"
    local remote_file="$MERV_BASE/$file"

    if dbclient -y -i "$SSH_KEY" "admin@$node_ip" "chmod 644 '$remote_file' 2>/dev/null; echo 'permissions_644_set'" 2>/dev/null | grep -q "permissions_644_set"; then
        info -c cli,vlan "✓ Set 644 permissions for $file on $node_ip"
        return 0
    else
        warn -c cli,vlan "⚠️  Could not set 644 permissions for $file on $node_ip"
        return 1
    fi
}

# ========================================================================== #
# DEBUG UTILITIES — Optional verbose listing during troubleshooting          #
# ========================================================================== #

# debug_remote_files — Recursively list remote MerVLAN directory contents
debug_remote_files() {
    local node_ip="$1"
    local stage="$2"  # optional: before | after
    info -c cli "Debugging files on $node_ip${stage:+ ($stage)}..."
    listing=$(dbclient -y -i "$SSH_KEY" "admin@$node_ip" "if [ -d \"$MERV_BASE\" ]; then ls -laR \"$MERV_BASE\" 2>/dev/null || echo 'No files yet (ls failed)'; else echo 'Directory not found: $MERV_BASE'; fi" 2>/dev/null)
    if [ -n "$listing" ]; then
        echo "$listing" | while IFS= read -r line; do
            [ -n "$line" ] && info -c vlan "$line"
        done
    else
        info -c vlan "(no output from remote ls)"
    fi
    info -c cli "Debugging completed on $node_ip${stage:+ ($stage)}"
}

# ========================================================================== #
# MAIN SYNCHRONIZATION LOOP — Iterate nodes and orchestrate copy workflow    #
# ========================================================================== #

info -c cli,vlan "Starting file synchronization..."
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

    # Ensure JFFS and scripts are enabled before proceeding
    if ! ensure_jffs_ready "$node_ip"; then
        overall_success=false
        continue
    fi
    
    # Create base remote directories (addon path + runtime folders)
    remote_mkdir_cmd="mkdir -p '$MERV_BASE' '$TMPDIR' '$LOGDIR' '$LOCKDIR' '$RESULTDIR' '$CHANGES' '$COLLECTDIR'"
    if ! dbclient -y -i "$SSH_KEY" "admin@$node_ip" "$remote_mkdir_cmd" 2>/dev/null; then
        error -c cli,vlan "✗ Failed to create required directories on $node_ip"
        overall_success=false
        continue
    else
        info -c cli,vlan "✓ Ensured remote directories on $node_ip: $MERV_BASE, $TMPDIR, $LOGDIR, $LOCKDIR, $RESULTDIR, $CHANGES, $COLLECTDIR"
    fi
    
    # Debug: show remote directory before copying (optional)
    if [ "$SYNC_DEBUG_PRE" = "1" ]; then
        debug_remote_files "$node_ip" "before"
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
        
        if ! copy_file_to_node "$node_ip" "$file"; then
            file_success=false
        fi
    done
    
    # Debug: show remote directory after copying (default on)
    if [ "$SYNC_DEBUG_POST" = "1" ]; then
        debug_remote_files "$node_ip" "after"
    fi
    
    # Verify files were copied
    if [ "$file_success" = "true" ]; then
        verification_success=true
        for file in $FILES_TO_COPY; do
            if ! verify_file_on_node "$node_ip" "$file"; then
                verification_success=false
            fi
        done
        
        if [ "$verification_success" = "true" ]; then
            info -c cli,vlan "✓ All files verified on $node_ip"
            
            # Set 755 permissions for files that need to be executable
            for file in $FILES_TO_COPY_CHMOD; do
                # Check if this file is in our copy list
                if echo "$FILES_TO_COPY" | grep -q "$file"; then
                    set_remote_permissions "$node_ip" "$file"
                fi
            done

            # Set 644 permissions for files that should not be executable
            for file in $FILES_TO_COPY_CHMOD_644; do
                # Check if this file is in our copy list
                if echo "$FILES_TO_COPY" | grep -q "$file"; then
                    set_remote_permissions_644 "$node_ip" "$file"
                fi
            done
        else
            error -c cli,vlan "✗ File verification failed for $node_ip"
            overall_success=false
        fi
    else
        overall_success=false
    fi
    
    info -c cli,vlan "--- Completed node: $node_ip ---"
    echo ""
done

info -c cli,vlan "Triggering nodeenable on synchronized nodes"
if sh "$MERV_BASE/functions/mervlan_boot.sh" nodeenable --local; then
    info -c cli,vlan "✓ Nodeenable completed for all reachable nodes"
else
    warn -c cli,vlan "⚠️  Nodeenable reported issues; review logs for details"
fi

# ========================================================================== #
# SUMMARY & EXIT — Report overall status and exit with success/failure       #
# ========================================================================== #

info -c cli,vlan "=== Synchronization Complete ==="

if [ "$overall_success" = "true" ]; then
    info -c cli,vlan "✓ SUCCESS: All files synchronized to all nodes"
    info -c cli,vlan "Files copied: $FILES_TO_COPY"
    info -c cli,vlan "Files made executable: $FILES_TO_COPY_CHMOD"
    exit 0
else
    warn -c cli,vlan "⚠️  PARTIAL SUCCESS: Some files may not have been synchronized"
    info -c cli,vlan "Check the log at $CLI_LOG for details"
    exit 1
fi