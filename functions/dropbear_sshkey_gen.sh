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
#                - File: dropbear_sshkey_gen.sh || version="0.48"              #
# ============================================================================ #
# - Purpose:    Generate SSH key pairs for MerVLAN and set the SSH key         #
#               flag if not already set.                                       #
# ============================================================================ #
#                                                                              #
# ================================================== MerVLAN environment setup #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
   unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_JSON_LOADED LIB_SSH_LOADED LIB_ACTION_LOCK_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh"
[ -n "${LIB_SSH_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssh.sh"
[ -n "${LIB_ACTION_LOCK_LOADED:-}" ] || . "$MERV_BASE/settings/lib_action_lock.sh" || exit 1
[ -n "${LIB_UPDATE_STATE_LOADED:-}" ] || . "$MERV_BASE/settings/lib_update_state.sh" 2>/dev/null || exit 75
[ -n "${LIB_ACTION_PROGRESS_LOADED:-}" ] || . "$MERV_BASE/settings/lib_action_progress.sh" 2>/dev/null || :
# =========================================== End of MerVLAN environment setup #

merv_action_progress_init "${MERV_PROGRESS_TOKEN:-}" "genkey_vlanmgr" "Generate SSH Keys" "Preparing SSH key generation..."

if merv_update_mutation_blocked; then
    merv_action_progress_fail "SSH key generation refused while Update maintenance is active"
    exit 75
fi

KEY_ACTION_LOCK_PATH="${MERV_ACTION_LOCK_PATH:-$LOCKDIR/mervlan_action.lock}"
if ! merv_action_lock_enter "$KEY_ACTION_LOCK_PATH"; then
    merv_action_progress_fail "Another mutating action is already running"
    exit 75
fi
KEY_ACTION_LOCK_MODE="${MERV_ACTION_LOCK_MODE:-none}"
KEY_ACTION_LOCK_NONCE="$MERV_ACTION_LOCK_NONCE"
KEY_ACTION_LOCK_START="$MERV_ACTION_LOCK_START"
merv_action_lock_export_child_context || exit 75

ssh_key_progress_exit() {
    _progress_rc=$?
    # This hook runs for every terminal path, including an explicit `exit`
    # and a signal-derived shell status. Disable the hook before finalizing
    # so the status-preserving exit below cannot recurse through EXIT.
    trap - EXIT
    _cleanup_rc=0
    if ! merv_action_lock_leave "$KEY_ACTION_LOCK_PATH" "$KEY_ACTION_LOCK_NONCE" "$KEY_ACTION_LOCK_START" "$KEY_ACTION_LOCK_MODE" >/dev/null 2>&1; then
        _cleanup_rc=75
        [ "$_progress_rc" -eq 0 ] && _progress_rc=$_cleanup_rc
        printf '%s\n' "[ERROR] SSH key action-lock cleanup failed; lock retained for recovery" >&2
    fi
    if [ "$_progress_rc" -eq 0 ]; then
        merv_action_progress_complete "SSH keys ready"
    else
        merv_action_progress_fail "SSH key generation failed"
    fi
    # `return 0` here masks cleanup failures (and signal/generation failures)
    # from callers waiting on this worker. Exit explicitly with the original
    # failure, or the cleanup failure when the action itself had succeeded.
    exit "$_progress_rc"
}
trap ssh_key_progress_exit EXIT

# ============================================================================ #
#                             HELPER FUNCTIONS                                 #
# Utility functions for JSON flag management and filesystem symlink creation   #
# to support SSH key installation validation and public key distribution.      #
# ============================================================================ #

# ============================================================================ #
# update_json_flag                                                             #
# Update or create SSH_KEYS_INSTALLED flag in settings.json. Sets              #
# flag to "1" (installed/ready) or "0" (failed/unavailable). Initializes       #
# file if empty. Logs all changes with reason context.                         #
# ============================================================================ #
update_json_flag() {
    local value="$1" reason="$2"

    # Prefer the sync helper if available – this preserves BOOT_ENABLED.
    if merv_has _sync_ssh_flag; then
        _sync_ssh_flag "$value"
        info -c cli "✓ SSH_KEYS_INSTALLED set to $value via _sync_ssh_flag${reason:+ ($reason)}"
        return 0
    fi

    # Fallback: direct write if lib_ssh isn't available for some reason.
    if json_set_flag "SSH_KEYS_INSTALLED" "$value" "$SETTINGS_FILE" >/dev/null 2>&1; then
        info -c cli "✓ SSH_KEYS_INSTALLED set to $value${reason:+ ($reason)}"
        return 0
    fi

    warn -c cli,vlan "Warning: Failed to update SSH_KEYS_INSTALLED flag"
    return 1
}

# ============================================================================ #
# create_link                                                                  #
# Create a symlink from target to destination. Removes existing symlink at     #
# destination first (idempotent). Used to expose public key to web UI.         #
# ============================================================================ #
create_link() {
    local target="$1" dest="$2"
    
    # Remove existing symlink if present (safe to do on regular files too)
    if [ -L "$dest" ]; then
        rm -f "$dest"
    fi
    # Create new symlink; abort with error if creation fails
    ln -sf "$target" "$dest" || {
        printf 'ERROR: Failed to create symlink %s -> %s\n' "$target" "$dest" >&2
        return 1
    }
}

# ============================================================================ #
#                          INITIALIZATION & LOGGING                            #
# Display welcome message and prepare SSH key storage directory. Log script    #
# invocation for diagnostic purposes.                                          #
# ============================================================================ #

info -c cli "=== VLAN Manager SSH Key Generator ==="
info -c cli ""

# Create SSH key directory if it doesn't exist (may not exist on first run)
mkdir -p "$(dirname "$SSH_KEY")"
# Ensure public-facing SSH directory exists for symlink publication
mkdir -p "$PUBLIC_MERV_BASE/.ssh"
merv_action_progress_update "prepare" 10 100 10 "Preparing SSH key storage..."

# ============================================================================ #
#                      CHECK FOR EXISTING KEY PAIR                             #
# If both private and public keys already exist, display them, update flag,    #
# and exit early (idempotent behavior).                                        #
# ============================================================================ #

if [ -f "$SSH_KEY" ] && [ -f "$SSH_PUBKEY" ]; then
    merv_action_progress_update "prepare" 60 100 60 "Existing key pair found; preserving current keys..."
    # Keys already exist; report status and show public key
    info -c cli "✓ SSH key pair already exists:"
    info -c cli "  Private key: $SSH_KEY"
    info -c cli "  Public key:  $SSH_PUBKEY"
    info -c cli ""
    info -c cli "Public key content:"
    # Display public key for user to install on nodes
    cat "$SSH_PUBKEY"
    
    # Mark keys as installed in settings (even though they already existed)
    update_json_flag "1" "Keys already exist"

    if create_link "$SSH_PUBKEY" "$PUBLIC_MERV_BASE/.ssh/vlan_manager.json"; then
        info -c cli,vlan "✓ Updated symlink for public key at $PUBLIC_MERV_BASE/.ssh/vlan_manager.json"
    else
        warn -c cli,vlan "Unable to update public key symlink at $PUBLIC_MERV_BASE/.ssh"
    fi
    exit 0
fi

# ============================================================================ #
#                         GENERATE NEW KEY PAIR                                #
# Use dropbearkey to create ED25519 key pair. Extract public key from          #
# private key. Set appropriate file permissions. Display and report results.   #
# ============================================================================ #

info -c cli "Generating new ED25519 SSH key pair..."
merv_action_progress_update "generate" 35 100 35 "Generating ED25519 key pair..."
# Invoke dropbearkey to generate ED25519 key; store in SSH_KEY file
if "$DROPBEARKEY" -t ed25519 -f "$SSH_KEY" 2>/dev/null; then
    # Extract public key from generated private key (dropbearkey -y outputs it)
    "$DROPBEARKEY" -y -f "$SSH_KEY" 2>/dev/null | grep "^ssh-ed25519 " > "$SSH_PUBKEY"
    
    # Set restrictive permissions on private key (owner read/write only)
    chmod 600 "$SSH_KEY"
    # Set readable permissions on public key (can be shared)
    chmod 644 "$SSH_PUBKEY"
    merv_action_progress_update "publish" 70 100 70 "Publishing public key..."
    
    # Report successful generation with file locations
    info -c cli "✓ SSH key pair generated successfully:"
    info -c cli "  Private key: $SSH_KEY"
    info -c cli "  Public key:  $SSH_PUBKEY"
    info -c cli ""
    info -c cli "Public key content:"
    # Display public key for user to install on nodes
    cat "$SSH_PUBKEY"
    
    # Mark keys as installed in settings file
    merv_action_progress_update "publish" 85 100 85 "Updating SSH key status..."
    update_json_flag "1"
    info -c cli,vlan "Keys generated successfully"
    # Create symlink to expose public key to web UI
    if create_link "$SSH_PUBKEY" "$PUBLIC_MERV_BASE/.ssh/vlan_manager.json"; then
        info -c cli,vlan "✓ Created symlink for public key at $PUBLIC_MERV_BASE/.ssh/vlan_manager.json"
    else
        warn -c cli,vlan "Unable to publish public key symlink at $PUBLIC_MERV_BASE/.ssh"
    fi
    exit 0
else
    # Key generation failed; report error and mark keys as unavailable
    error -c cli,vlan "ERROR: Failed to generate SSH key pair"
    # Mark keys as NOT installed in settings file
    update_json_flag "0" "Key generation failed"
    exit 1
fi
