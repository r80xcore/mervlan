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

# Function to update the JSON flag
update_json_flag() {
    local value="$1"
    local reason="$2"
    
  if [ ! -f "$GENERAL_SETTINGS_FILE" ]; then
    warn -c cli,vlan "Warning: HW settings file not found at $GENERAL_SETTINGS_FILE"
        return 1
    fi
    
    # Check if the file is empty
    if [ ! -s "$GENERAL_SETTINGS_FILE" ]; then
        # Initialize empty file with the flag
        echo "{\"SSH_KEYS_INSTALLED\": \"$value\"}" > "$GENERAL_SETTINGS_FILE"
        info -c cli "✓ Initialized HW settings with SSH_KEYS_INSTALLED: $value ($reason)"
        return 0
    fi
    
    # Check if the flag already exists in the JSON
  if grep -q '"SSH_KEYS_INSTALLED"' "$GENERAL_SETTINGS_FILE"; then
        # Update existing flag
    if sed -i "s/\"SSH_KEYS_INSTALLED\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"SSH_KEYS_INSTALLED\": \"$value\"/" "$GENERAL_SETTINGS_FILE"; then
            info -c cli "✓ Updated SSH_KEYS_INSTALLED to $value ($reason)"
        else
            warn -c cli,vlan "Warning: Failed to update SSH_KEYS_INSTALLED flag"
        fi
    else
        # Add new flag (insert before the closing brace)
    if sed -i 's/}/,"SSH_KEYS_INSTALLED": "'"$value"'"}/' "$GENERAL_SETTINGS_FILE"; then
            info -c cli "✓ Added SSH_KEYS_INSTALLED: $value ($reason)"
        else
            warn -c cli,vlan "Warning: Failed to add SSH_KEYS_INSTALLED flag"
        fi
    fi
}

# Symlink function
create_link() {
    # create_link <target> <dest>
    local target="$1" dest="$2"
    
    if [ -L "$dest" ]; then
        rm -f "$dest"
    fi
    ln -sf "$target" "$dest" || {
        printf 'ERROR: Failed to create symlink %s -> %s\n' "$target" "$dest" >&2
        return 1
    }
}

info -c cli "=== VLAN Manager SSH Key Generator ==="
info -c cli ""

# Create directory if it doesn't exist
mkdir -p "$(dirname "$SSH_KEY")"

# Check if SSH key pair already exists
if [ -f "$SSH_KEY" ] && [ -f "$SSH_PUBKEY" ]; then
    info -c cli "✓ SSH key pair already exists:"
    info -c cli "  Private key: $SSH_KEY"
    info -c cli "  Public key:  $SSH_PUBKEY"
    info -c cli ""
    info -c cli "Public key content:"
    cat "$SSH_PUBKEY"
    
    # Update JSON flag to indicate keys are available
    update_json_flag "1" "Keys already exist"
    exit 0
fi

# Generate new key pair
info -c cli "Generating new ED25519 SSH key pair..."
if "$DROPBEARKEY" -t ed25519 -f "$SSH_KEY" 2>/dev/null; then
    # Extract public key
    "$DROPBEARKEY" -y -f "$SSH_KEY" 2>/dev/null | grep "^ssh-ed25519 " > "$SSH_PUBKEY"
    
    # Set permissions
    chmod 600 "$SSH_KEY"
    chmod 644 "$SSH_PUBKEY"
    
    info -c cli "✓ SSH key pair generated successfully:"
    info -c cli "  Private key: $SSH_KEY"
    info -c cli "  Public key:  $SSH_PUBKEY"
    info -c cli ""
    info -c cli "Public key content:"
    cat "$SSH_PUBKEY"
    
    # Update JSON flag to indicate keys are available
    update_json_flag "1"
    info -c cli,vlan "Keys generated successfully"
    # Create and log symlinks
    create_link "$SSH_PUBKEY" "$PUBLIC_DIR/.ssh/vlan_manager.pub"
    info -c cli,vlan "✓ Created symlink for public key at $PUBLIC_DIR/.ssh/vlan_manager.json"
    exit 0
else
    error -c cli,vlan "ERROR: Failed to generate SSH key pair"
    # Update JSON flag to indicate keys are NOT available
    update_json_flag "0" "Key generation failed"
    exit 1
fi