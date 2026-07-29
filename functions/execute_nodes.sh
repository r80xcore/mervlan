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
#              - File: execute_nodes.sh || version="0.72.2"                  #
# ============================================================================ #
# - Purpose:    Execute the MerVLAN Manager on configured nodes via SSH using  #
#               the settings defined in settings.json.                         #
# ============================================================================ #
#                                                                              #
# ================================================== MerVLAN environment setup #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_JSON_LOADED LIB_SSH_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_SSH_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssh.sh"
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh"
[ -n "${LIB_MERVQT_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mervqt.sh" 2>/dev/null || true
[ -n "${LIB_NODE_JOBS_LOADED:-}" ] || . "$MERV_BASE/settings/lib_node_jobs.sh"
# Optional web progress publication. The parent orchestration script owns the
# progress token; worker processes must never publish to the shared status file.
merv_action_progress_init() { :; }
merv_action_progress_update() { :; }
merv_action_progress_complete() { :; }
merv_action_progress_fail() { :; }
if [ -f "$MERV_BASE/settings/lib_action_progress.sh" ]; then
  . "$MERV_BASE/settings/lib_action_progress.sh" 2>/dev/null || :
fi
# Runtime marker used by the HTML to block redundant client refreshes during
# node applies, including applies started by boot/event handlers.
if [ -f "$MERV_BASE/settings/lib_action_runtime.sh" ]; then
  . "$MERV_BASE/settings/lib_action_runtime.sh" 2>/dev/null || :
fi
# =========================================== End of MerVLAN environment setup #
SSH_NODE_USER=$(get_node_ssh_user)
SSH_NODE_PORT=$(get_node_ssh_port)

execute_nodes_progress_cleanup() {
  _enpc_rc=$?
  if [ "${MERV_ACTION_PROGRESS_ENABLED:-0}" -eq 1 ] &&
     [ "${MERV_ACTION_PROGRESS_FINAL:-0}" -eq 0 ]; then
    if [ "$_enpc_rc" -eq 0 ]; then
      if [ "${MODE:-full}" = "nodesonly" ]; then
        merv_action_progress_complete "Node apply complete"
      else
        merv_action_progress_complete "Apply complete"
      fi
    else
      if [ "${MODE:-full}" = "nodesonly" ]; then
        merv_action_progress_fail "Node apply failed; see the VLAN log for details"
      else
        merv_action_progress_fail "Apply with nodes failed; see the VLAN log for details"
      fi
    fi
  fi
  [ "${EXEC_RUNTIME_OWNED:-0}" -eq 1 ] &&
    merv_action_runtime_finish 2>/dev/null || :
  [ "${EXEC_NODES_LOCK_ACQUIRED:-0}" -eq 1 ] && merv_lock_release "$EXEC_NODES_LOCK" 2>/dev/null || :
}

# ----------------------------------------------------------- Concurrency lock --
# execute_nodes orchestrates a local manager apply plus remote node runs. The
# local manager self-locks, but two overlapping execute_nodes invocations (e.g.
# UI double-submit) would still fire redundant remote work. Take a NON-BLOCKING
# self-lock so the second invocation skips cleanly. Lower urgency than sync/
# mac_refresh (no local config files are overwritten here), hence best-effort.
EXEC_NODES_LOCK="$LOCKDIR/execute_nodes.lock"
EXEC_NODES_LOCK_ACQUIRED=0
if type merv_lock_acquire >/dev/null 2>&1; then
  mkdir -p "$LOCKDIR" 2>/dev/null || :
  if merv_lock_acquire "$EXEC_NODES_LOCK" "${MERV_EXEC_NODES_LOCK_STALE_SEC:-900}" 0 "execute_nodes"; then
    EXEC_NODES_LOCK_ACQUIRED=1
    trap 'execute_nodes_progress_cleanup' EXIT INT TERM
  else
    warn -c cli,vlan "Execute: another execute_nodes run is in progress — skipping"
    exit 0
  fi
fi
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

if [ "$MODE" = "full" ]; then
    EXECUTE_PROGRESS_ACTION="executenodes_vlanmgr"
    EXECUTE_PROGRESS_LABEL="Apply VLAN + Nodes"
    EXECUTE_PROGRESS_START="Preparing router and nodes..."
else
    EXECUTE_PROGRESS_ACTION="executenodesonly_vlanmgr"
    EXECUTE_PROGRESS_LABEL="Apply VLAN to Nodes"
    EXECUTE_PROGRESS_START="Preparing node apply..."
fi
merv_action_progress_init "${MERV_PROGRESS_TOKEN:-}" "$EXECUTE_PROGRESS_ACTION" \
    "$EXECUTE_PROGRESS_LABEL" "$EXECUTE_PROGRESS_START"

EXEC_RUNTIME_OWNED=0
if type merv_action_runtime_start >/dev/null 2>&1 &&
   merv_action_runtime_start "$EXECUTE_PROGRESS_ACTION" "$EXECUTE_PROGRESS_LABEL" \
     "Applying VLAN configuration on router and node(s)..."; then
  EXEC_RUNTIME_OWNED=1
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
# Extract NODE1-NODE10 IP addresses from settings.json. Parse JSON format       #
# and filter out "none" entries and invalid IP addresses.                      #
# ============================================================================ #
get_node_ips() {
    merv_node_list
}

NODE_IPS=$(get_node_ips)
APPLY_RUN_ID="$(date +%s 2>/dev/null || printf 0)-$$"
_exec_seen_ids=" "
_exec_seen_ips=" "
while IFS=' ' read -r _exec_check_id _exec_check_ip _exec_check_extra || [ -n "$_exec_check_id" ]; do
    [ -z "$_exec_check_extra" ] && merv_is_valid_node_id "$_exec_check_id" && _merv_is_ipv4 "$_exec_check_ip" || {
        error -c cli,vlan "Execute: invalid node list entry"
        exit 1
    }
    case "$_exec_seen_ids" in *" $_exec_check_id "*) error -c cli,vlan "Execute: duplicate node ID $_exec_check_id"; exit 1;; esac
    case "$_exec_seen_ips" in *" $_exec_check_ip "*) error -c cli,vlan "Execute: duplicate node IP $_exec_check_ip"; exit 1;; esac
    _exec_seen_ids="$_exec_seen_ids$_exec_check_id "
    _exec_seen_ips="$_exec_seen_ips$_exec_check_ip "
done <<EOF
$NODE_IPS
EOF

# Check if any nodes are configured
if [ -z "$NODE_IPS" ]; then
    warn -c cli,vlan "No nodes configured in settings.json"
    exit 0
fi

info -c cli,vlan "Found nodes: $(echo "$NODE_IPS" | awk '{print $2}' | tr '\n' ' ')"
echo ""
EXEC_NODE_COUNT=$(printf '%s\n' "$NODE_IPS" | awk 'NF { count++ } END { print count + 0 }')
merv_action_progress_update preflight 1 1 15 \
    "Validated settings, SSH, and $EXEC_NODE_COUNT configured node(s)..."

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
    _vnc_deadline=$(( $(date +%s) + ${MERV_NODE_COMPLETION_MAX_SEC:-600} ))
    while [ "$(date +%s)" -lt "$_vnc_deadline" ]; do
        marker_content=$(MERV_SSH_RETRIES=1 merv_ssh_exec "$node_id" "$node_ip" "sh '$MERV_BASE/functions/mervlan_node_runner.sh' status '$APPLY_RUN_ID' '$node_id'" 2>/dev/null)
        if [ $? -eq 0 ] && execute_status_valid "$marker_content" "$node_id"; then
            case "$EXEC_STATUS_STATE" in
                complete) return 0 ;;
                failed) fetch_node_runner_logs "$node_id" "$node_ip"; return 1 ;;
            esac
        fi
        sleep "${MERV_NODE_MARKER_POLL_SEC:-5}"
    done
    fetch_node_runner_logs "$node_id" "$node_ip"
    return 1
}

# Strictly validate the remote runner payload again on the parent.  The remote
# runner already validates its file; this prevents an SSH response from being
# mistaken for a current-run terminal status.
execute_status_valid() {
    _esv_text="$1" _esv_node="$2"
    EXEC_STATUS_STATE=""; _esv_keys=" "
    _esv_run=""; _esv_pid=""; _esv_start=""; _esv_started=""; _esv_done=""; _esv_exit=""; _esv_reason=""
    while IFS= read -r _esv_line || [ -n "$_esv_line" ]; do
        case "$_esv_line" in *=*) _esv_key=${_esv_line%%=*}; _esv_val=${_esv_line#*=} ;; *) return 1;; esac
        case "$_esv_keys" in *" $_esv_key "*) return 1;; esac
        _esv_keys="$_esv_keys$_esv_key "
        case "$_esv_key" in
            format_version) [ "$_esv_val" = 1 ] || return 1;; run_id) _esv_run=$_esv_val;; node_id) [ "$_esv_val" = "$_esv_node" ] || return 1;;
            state) EXEC_STATUS_STATE=$_esv_val;; pid) _esv_pid=$_esv_val;; proc_start_time) _esv_start=$_esv_val;; started_epoch) _esv_started=$_esv_val;;
            completed_epoch) _esv_done=$_esv_val;; exit_code) _esv_exit=$_esv_val;; reason) _esv_reason=$_esv_val;; *) return 1;; esac
    done <<EOF
$_esv_text
EOF
    for _esv_required in format_version run_id node_id state pid proc_start_time started_epoch completed_epoch exit_code reason; do
        case "$_esv_keys" in *" $_esv_required "*) ;; *) return 1;; esac
    done
    [ "$_esv_run" = "$APPLY_RUN_ID" ] || return 1
    case "$_esv_pid:$_esv_start:$_esv_started:$_esv_done" in *[!0-9:]*|:*|*::*) return 1;; esac
    case "$_esv_reason" in ''|*[!A-Za-z0-9._-]*) return 1;; esac
    case "$EXEC_STATUS_STATE" in
      started) [ "$_esv_done" = 0 ] && [ -z "$_esv_exit" ];;
      complete) [ "$_esv_exit" = 0 ] && [ "$_esv_done" -ge "$_esv_started" ] 2>/dev/null;;
      failed) case "$_esv_exit" in ''|*[!0-9]*) false;; *) [ "$_esv_exit" -ne 0 ] 2>/dev/null && [ "$_esv_done" -ge "$_esv_started" ] 2>/dev/null;; esac;;
      *) false;;
    esac
}

fetch_node_runner_logs() {
    _enrl_id="$1" _enrl_ip="$2"
    [ "${DEBUG:-0}" = 1 ] || [ "${MERV_NODE_FETCH_LOGS_ON_FAILURE:-0}" = 1 ] || return 0
    _enrl_out=$(MERV_SSH_RETRIES=1 merv_ssh_exec "$_enrl_id" "$_enrl_ip" "d='$MERV_NODE_STATUS_ROOT/$APPLY_RUN_ID'; for f in \"\$d/cli.log\" \"\$d/vlan.log\" \"\$d/stdout.log\"; do [ -f \"\$f\" ] && tail -n 200 \"\$f\"; done" 2>/dev/null)
    [ -n "$_enrl_out" ] && printf '%s\n' "$_enrl_out" | while IFS= read -r _enrl_line; do info -c vlan "NODE${_enrl_id}: $_enrl_line"; done
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
    output=$(MERV_SSH_RETRIES=1 merv_ssh_exec "$node_id" "$node_ip" "sh '$MERV_BASE/functions/mervlan_node_runner.sh' start '$APPLY_RUN_ID' '$node_id'" 2>&1)
    rc=$?

    if [ $rc -eq 0 ]; then
        info -c cli,vlan "✓ Successfully executed VLAN manager on $node_ip"
        return 0
    else
        error -c cli,vlan "✗ Failed to execute VLAN manager on $node_ip (rc=$rc)"
        return 1
    fi
}

# Bounded-worker handlers.  Parent aggregation remains in this script.
execute_prepare_job() {
    _epj_id="$1" _epj_ip="$2"
    merv_ssh_precheck "$_epj_id" "$_epj_ip" || return 1
    test_ssh_connection "$_epj_id" "$_epj_ip" || return 1
    sync_settings_conf_for_node "$_epj_id" "$_epj_ip" || return 1
    set_node_flags_remote "$_epj_id" "$_epj_ip"
}
execute_launch_job() { execute_vlan_manager_on_node "$1" "$2"; }
execute_status_job() { verify_node_completion "$1" "$2"; }

# Parent-only progress hook for bounded node worker pools. Each worker writes
# only to its own result file; this hook aggregates validated success markers
# into a small user-facing node count without exposing the full CLI log.
execute_nodes_progress_hook() {
    [ "${MERV_ACTION_PROGRESS_ENABLED:-0}" -eq 1 ] || return 0
    _enph_root="$1"
    _enph_phase="$2"
    _enph_nodes_file=""
    _enph_base=0
    _enph_span=0
    _enph_label="Working on nodes..."
    case "$_enph_phase" in
        prepare)
            _enph_nodes_file="${_exec_nodes_file:-}"
            _enph_base=25
            _enph_span=15
            _enph_label="Preparing nodes"
            ;;
        launch)
            _enph_nodes_file="${_exec_jobs_root:-}/ready"
            _enph_base=45
            if [ "${MODE:-full}" = "nodesonly" ]; then
                _enph_span=30
                _enph_label="Applying VLAN configuration to nodes"
            else
                _enph_span=25
                _enph_label="Applying VLAN configuration on router and nodes"
            fi
            ;;
        status)
            _enph_nodes_file="${_exec_jobs_root:-}/launched"
            if [ "${MODE:-full}" = "nodesonly" ]; then
                _enph_base=90
                _enph_span=7
            else
                _enph_base=85
                _enph_span=10
            fi
            _enph_label="Verifying node completion"
            ;;
        *) return 0 ;;
    esac
    [ -f "$_enph_nodes_file" ] || return 0
    _enph_total=$(awk 'NF { count++ } END { print count + 0 }' "$_enph_nodes_file" 2>/dev/null)
    case "$_enph_total" in ''|*[!0-9]*) _enph_total=0 ;; esac
    [ "$_enph_total" -gt 0 ] 2>/dev/null || return 0
    _enph_done=0
    while IFS=' ' read -r _enph_node _enph_ip _enph_extra || [ -n "$_enph_node" ]; do
        [ -z "$_enph_extra" ] || continue
        [ -f "$_enph_root/node_${_enph_node}/result" ] || continue
        grep -q '^state=ok$' "$_enph_root/node_${_enph_node}/result" 2>/dev/null &&
            _enph_done=$((_enph_done + 1))
    done < "$_enph_nodes_file"
    _enph_percent=$((_enph_base + (_enph_span * _enph_done / _enph_total)))
    merv_action_progress_update "$_enph_phase" "$_enph_done" "$_enph_total" \
        "$_enph_percent" "$_enph_label: $_enph_done of $_enph_total complete..."
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
LAUNCHED_NODES=""

# ============================================================================ #
# PHASE 1: Prepare all nodes in bounded parallel workers                       #
# ============================================================================ #
info -c cli,vlan "--- Phase 1: Preparing nodes ---"

_exec_nodes_file="$TMPDIR/execute_nodes.$APPLY_RUN_ID"
printf '%s\n' "$NODE_IPS" > "$_exec_nodes_file"
_exec_jobs_root="$TMPDIR/node_jobs/$APPLY_RUN_ID"
merv_action_progress_update node_prepare 0 "$EXEC_NODE_COUNT" 25 \
    "Preparing nodes: 0 of $EXEC_NODE_COUNT complete..."
MNJ_POOL_PROGRESS_HOOK=execute_nodes_progress_hook
if ! mnj_pool_run "$_exec_jobs_root/prepare" prepare "${MERV_NODE_PARALLELISM:-2}" "${MERV_NODE_PREPARE_MAX_SEC:-180}" "$_exec_nodes_file" execute_prepare_job; then
    overall_success=false
fi
execute_nodes_progress_hook "$_exec_jobs_root/prepare" prepare
while IFS=' ' read -r node_id node_ip _exec_extra || [ -n "$node_id" ]; do
    [ -z "$_exec_extra" ] || continue
    if mnj_result_validate "$_exec_jobs_root/prepare/node_$node_id/result" "$node_id" prepare && [ "$MNJ_RESULT_STATE" = ok ]; then
        READY_NODES="${READY_NODES}${READY_NODES:+
}$node_id $node_ip"
    else
        overall_success=false
    fi
done < "$_exec_nodes_file"
_execute_ready_count=$(printf '%s\n' "$READY_NODES" | awk 'NF { count++ } END { print count + 0 }')
merv_action_progress_update node_prepare "$_execute_ready_count" "$EXEC_NODE_COUNT" 40 \
    "Nodes prepared: $_execute_ready_count of $EXEC_NODE_COUNT ready..."

if [ -z "$READY_NODES" ]; then
    warn -c cli,vlan "No nodes ready for execution"
    
    # Still run main router if not in nodesonly mode
    if [ "$MODE" != "nodesonly" ]; then
        info -c cli,vlan "Executing VLAN manager on main router (no nodes)..."
        local_script="$(printf '%s' "$MERV_BASE/functions/mervlan_manager.sh" | tr -d '\r')"
        if [ -f "$local_script" ]; then
            # Keep collection in the shared final phase below so a no-node
            # combined run cannot publish the client inventory twice.
            MERV_PROGRESS_TOKEN="" MERV_ACTION_RUNTIME_OWNER=1 sh "$local_script" --no-collect >>"$CLI_LOG" 2>&1 && local_success=true || local_success=false
        fi
    fi
else
    # ============================================================================ #
    # PHASE 2: Execute VLAN manager on ALL in parallel (nodes + main router)     #
    # ============================================================================ #
    info -c cli,vlan "--- Phase 2: Executing on all routers in parallel ---"
    
    printf '%s\n' "$READY_NODES" > "$_exec_jobs_root/ready"
    _execute_ready_count=$(printf '%s\n' "$READY_NODES" | awk 'NF { count++ } END { print count + 0 }')
    if [ "$MODE" = "nodesonly" ]; then
        merv_action_progress_update apply 0 "$EXEC_NODE_COUNT" 45 \
            "Starting VLAN configuration on $_execute_ready_count node(s)..."
    else
        merv_action_progress_update apply 0 "$EXEC_NODE_COUNT" 45 \
            "Starting VLAN configuration on router and $_execute_ready_count node(s)..."
    fi
    if ! mnj_pool_run "$_exec_jobs_root/launch" launch "${MERV_NODE_PARALLELISM:-2}" "${MERV_NODE_PREPARE_MAX_SEC:-180}" "$_exec_jobs_root/ready" execute_launch_job; then
        overall_success=false
    fi
    execute_nodes_progress_hook "$_exec_jobs_root/launch" launch
    while IFS=' ' read -r node_id node_ip _exec_extra || [ -n "$node_id" ]; do
        [ -z "$_exec_extra" ] || continue
        if mnj_result_validate "$_exec_jobs_root/launch/node_$node_id/result" "$node_id" launch && [ "$MNJ_RESULT_STATE" = ok ]; then
            LAUNCHED_NODES="${LAUNCHED_NODES}${LAUNCHED_NODES:+
}$node_id $node_ip"
        else
            overall_success=false
        fi
    done < "$_exec_jobs_root/ready"
    
    # Launch main router execution in background (with --no-collect flag)
    if [ "$MODE" != "nodesonly" ]; then
        info -c cli,vlan "Launching execution on main router..."
        local_script="$(printf '%s' "$MERV_BASE/functions/mervlan_manager.sh" | tr -d '\r')"
        if [ -f "$local_script" ]; then
            _main_rc_file="$TMPDIR/main_exec_rc.$$"
            ( MERV_PROGRESS_TOKEN="" MERV_ACTION_RUNTIME_OWNER=1 sh "$local_script" --no-collect >>"$CLI_LOG" 2>&1; echo $? > "$_main_rc_file" ) &
            main_pid=$!
        fi
    fi
    
    # Wait for all background executions to complete
    if [ "$MODE" = "nodesonly" ]; then
        merv_action_progress_update wait 0 1 75 \
            "Waiting for $_execute_ready_count node(s) to finish..."
    else
        merv_action_progress_update wait 0 1 70 \
            "Waiting for router and $_execute_ready_count node(s) to finish..."
    fi
    info -c cli,vlan "Waiting for all executions to complete..."
    if [ -n "${main_pid:-}" ]; then
        wait "$main_pid"
    fi
    if [ "$MODE" = "nodesonly" ]; then
        merv_action_progress_update wait 1 1 90 \
            "Node operations finished; verifying node completion..."
    else
        merv_action_progress_update wait 1 2 78 \
            "Router execution finished; waiting for node operations..."
    fi
    info -c cli,vlan "All executions finished"
    
    # Check if main router succeeded (if we ran it)
    if [ "$MODE" != "nodesonly" ]; then
        if [ -n "${_main_rc_file:-}" ] && [ -f "$_main_rc_file" ]; then
            _main_rc=$(cat "$_main_rc_file" 2>/dev/null)
            rm -f "$_main_rc_file" 2>/dev/null
            if [ "${_main_rc:-1}" = "0" ]; then
                info -c cli,vlan "✓ Main router execution completed"
                local_success=true
            else
                error -c cli,vlan "✗ Main router execution failed (rc=${_main_rc:-?})"
                local_success=false
            fi
        elif [ -n "${local_script:-}" ] && [ ! -f "$local_script" ]; then
            error -c cli,vlan "✗ Local VLAN manager script missing"
            local_success=false
        else
            # rc file missing (script may not have been launched)
            warn -c cli,vlan "⚠ Main router exit status unavailable"
            local_success=false
        fi
    fi
    
    # ============================================================================ #
    # PHASE 3: Verify completion markers on all nodes                            #
    # ============================================================================ #
    info -c cli,vlan "--- Phase 3: Verifying node completions ---"

    if [ -n "$LAUNCHED_NODES" ]; then
        printf '%s\n' "$LAUNCHED_NODES" > "$_exec_jobs_root/launched"
        if [ "$MODE" = "nodesonly" ]; then
            merv_action_progress_update verify 0 "$EXEC_NODE_COUNT" 90 \
                "Verifying node completion: 0 of $EXEC_NODE_COUNT complete..."
        else
            merv_action_progress_update verify 0 "$EXEC_NODE_COUNT" 85 \
                "Verifying node completion: 0 of $EXEC_NODE_COUNT complete..."
        fi
        MNJ_POOL_PROGRESS_HOOK=execute_nodes_progress_hook
        if ! mnj_pool_run "$_exec_jobs_root/status" status "${MERV_NODE_PARALLELISM:-2}" "${MERV_NODE_COMPLETION_MAX_SEC:-600}" "$_exec_jobs_root/launched" execute_status_job; then
            overall_success=false
        fi
        execute_nodes_progress_hook "$_exec_jobs_root/status" status
    else
        warn -c cli,vlan "No node launches acknowledged; skipping completion polling"
    fi
    
    # ============================================================================ #
    # PHASE 4: Publish one cluster observation after all work is verified       #
    # ============================================================================ #
    if [ -x "$FUNCDIR/post_apply_worker.sh" ]; then
        merv_action_progress_update complete 1 1 98 "Refreshing client inventory..."
        info -c cli,vlan "--- Phase 4: Refreshing client inventory ---"
        if [ "${EXEC_NODES_LOCK_ACQUIRED:-0}" -eq 1 ]; then
            merv_lock_release "$EXEC_NODES_LOCK" 2>/dev/null || :
            EXEC_NODES_LOCK_ACQUIRED=0
        fi
        if MERV_OBS_NO_AUTOSTART=1 "$FUNCDIR/post_apply_worker.sh" \
             request snapshot collect >/dev/null 2>&1 &&
           "$FUNCDIR/post_apply_worker.sh" run-wait "${MERV_OBS_AUTOSTART_WAIT_SEC:-120}"; then
            info -c cli,vlan "✓ VLAN client list refresh completed"
        else
            _exec_observation_rc=$?
            overall_success=false
            warn -c cli,vlan "✗ Post-apply observation failed (rc=$_exec_observation_rc); generation remains pending"
        fi
    else
        overall_success=false
        warn -c cli,vlan "✗ Post-apply observation unavailable; client inventory was not refreshed"
    fi
fi

echo ""

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
