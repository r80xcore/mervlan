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
#                - File: dropbear_sshkey_gen.sh || version="0.45"              #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Generate SSH key pairs for MerVLAN and set the SSH key         #
#               flag if not already set.                                       #
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
#                             HELPER FUNCTIONS                                 #
# Utility functions for JSON flag management and filesystem symlink creation   #
# to support SSH key installation validation and public key distribution.      #
# ============================================================================ #

# ============================================================================ #
# update_json_flag                                                             #
# Update or create SSH_KEYS_INSTALLED flag in general.json settings. Sets      #
# flag to "1" (installed/ready) or "0" (failed/unavailable). Initializes       #
# file if empty. Logs all changes with reason context.                         #
# ============================================================================ #
update_json_flag() {
    local value="$1"
    local reason="$2"
    
  # Verify that the general settings file path exists
  if [ ! -f "$GENERAL_SETTINGS_FILE" ]; then
    warn -c cli,vlan "Warning: HW settings file not found at $GENERAL_SETTINGS_FILE"
        return 1
    fi
    
    # If file is empty, initialize it with flag
    if [ ! -s "$GENERAL_SETTINGS_FILE" ]; then
        # Create minimal JSON with SSH_KEYS_INSTALLED flag
        echo "{\"SSH_KEYS_INSTALLED\": \"$value\"}" > "$GENERAL_SETTINGS_FILE"
        info -c cli "✓ Initialized HW settings with SSH_KEYS_INSTALLED: $value ($reason)"
        return 0
    fi
    
    # Check if SSH_KEYS_INSTALLED flag already exists in the JSON
  if grep -q '"SSH_KEYS_INSTALLED"' "$GENERAL_SETTINGS_FILE"; then
        # Flag exists: update the value using sed replacement
    if sed -i "s/\"SSH_KEYS_INSTALLED\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"SSH_KEYS_INSTALLED\": \"$value\"/" "$GENERAL_SETTINGS_FILE"; then
            info -c cli "✓ Updated SSH_KEYS_INSTALLED to $value ($reason)"
        else
            warn -c cli,vlan "Warning: Failed to update SSH_KEYS_INSTALLED flag"
        fi
    else
        # Flag does not exist: add new flag before closing brace
    if sed -i 's/}/,"SSH_KEYS_INSTALLED": "'"$value"'"}/' "$GENERAL_SETTINGS_FILE"; then
            info -c cli "✓ Added SSH_KEYS_INSTALLED: $value ($reason)"
        else
            warn -c cli,vlan "Warning: Failed to add SSH_KEYS_INSTALLED flag"
        fi
    fi
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

# ============================================================================ #
#                      CHECK FOR EXISTING KEY PAIR                             #
# If both private and public keys already exist, display them, update flag,    #
# and exit early (idempotent behavior).                                        #
# ============================================================================ #

if [ -f "$SSH_KEY" ] && [ -f "$SSH_PUBKEY" ]; then
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
    exit 0
fi

# ============================================================================ #
#                         GENERATE NEW KEY PAIR                                #
# Use dropbearkey to create ED25519 key pair. Extract public key from          #
# private key. Set appropriate file permissions. Display and report results.   #
# ============================================================================ #

info -c cli "Generating new ED25519 SSH key pair..."
# Invoke dropbearkey to generate ED25519 key; store in SSH_KEY file
if "$DROPBEARKEY" -t ed25519 -f "$SSH_KEY" 2>/dev/null; then
    # Extract public key from generated private key (dropbearkey -y outputs it)
    "$DROPBEARKEY" -y -f "$SSH_KEY" 2>/dev/null | grep "^ssh-ed25519 " > "$SSH_PUBKEY"
    
    # Set restrictive permissions on private key (owner read/write only)
    chmod 600 "$SSH_KEY"
    # Set readable permissions on public key (can be shared)
    chmod 644 "$SSH_PUBKEY"
    
    # Report successful generation with file locations
    info -c cli "✓ SSH key pair generated successfully:"
    info -c cli "  Private key: $SSH_KEY"
    info -c cli "  Public key:  $SSH_PUBKEY"
    info -c cli ""
    info -c cli "Public key content:"
    # Display public key for user to install on nodes
    cat "$SSH_PUBKEY"
    
    # Mark keys as installed in settings file
    update_json_flag "1"
    info -c cli,vlan "Keys generated successfully"
    # Create symlink to expose public key to web UI
    create_link "$SSH_PUBKEY" "$PUBLIC_DIR/.ssh/vlan_manager.pub"
    info -c cli,vlan "✓ Created symlink for public key at $PUBLIC_DIR/.ssh/vlan_manager.json"
    exit 0
else
    # Key generation failed; report error and mark keys as unavailable
    error -c cli,vlan "ERROR: Failed to generate SSH key pair"
    # Mark keys as NOT installed in settings file
    update_json_flag "0" "Key generation failed"
    exit 1
fi