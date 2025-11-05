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
#                   - File: uninstall.sh || version: 0.45                      #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Disable the MerVLAN addon and clean up necessary files.        #
#                                                                              #
# ──────────────────────────────────────────────────────────────────────────── #
# ============================================================================ #
#                  CONFIGURATION & RUNTIME CONTEXT                             #
# Define global paths, addon identifiers, and helper entry points leveraged    #
# during uninstall operations.                                                 #
# ============================================================================ #
MERV_BASE="/jffs/addons/mervlan"
ADDON="Merlin_VLAN_Manager"
LOGTAG="VLAN"
ACTION="${1:-standard}"
source /usr/sbin/helper.sh

SETTINGS_FILE="$MERV_BASE/settings/settings.json"
GENERAL_SETTINGS_FILE="$MERV_BASE/settings/general.json"
BOOT_SCRIPT="$MERV_BASE/functions/mervlan_boot.sh"

# ============================================================================ #
# NODE & SSH STATE HELPERS — Determine remote cleanup prerequisites           #
# ============================================================================ #

# has_configured_nodes — Report configured NODE entries containing IPv4s
# Returns: 0 when at least one valid node IP is present, 1 otherwise
# Explanation: Indicates whether remote hooks must be disabled before files
#   are removed from the router.
has_configured_nodes() {
    [ -f "$SETTINGS_FILE" ] || return 1
    local nodes
    nodes=$(grep -o '"NODE[1-5]"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" 2>/dev/null | \
        sed -n 's/.*:[[:space:]]*"\([^"]*\)".*/\1/p' | \
        grep -v "none" | \
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    [ -n "$nodes" ]
}

# ssh_keys_installed — Check general.json flag for SSH key deployment
# Returns: 0 if SSH_KEYS_INSTALLED is "1", 1 otherwise
# Explanation: Ensures passwordless SSH is available before attempting to run
#   remote disable operations.
ssh_keys_installed() {
    [ -f "$GENERAL_SETTINGS_FILE" ] || return 1
    grep -q '"SSH_KEYS_INSTALLED"[[:space:]]*:[[:space:]]*"1"' "$GENERAL_SETTINGS_FILE" 2>/dev/null
}

# ============================================================================ #
# PRE-UNINSTALL HOOK DISABLE — Stop MerVLAN services before file removal      #
# ============================================================================ #

# Disable router and node hooks first so MerVLAN stops executing during cleanup
if has_configured_nodes && ssh_keys_installed; then
    # Only attempt teardown when the boot helper script is available
    if [ -x "$BOOT_SCRIPT" ]; then
        logger -t "$LOGTAG" "Pre-uninstall: disabling hooks locally and on nodes"
        if ! sh "$BOOT_SCRIPT" disable >/dev/null 2>&1; then
            logger -t "$LOGTAG" "WARNING: mervlan_boot.sh disable failed pre-uninstall"
        fi
        if ! sh "$BOOT_SCRIPT" nodedisable >/dev/null 2>&1; then
            logger -t "$LOGTAG" "WARNING: mervlan_boot.sh nodedisable failed pre-uninstall"
        fi
    else
        # Warn when teardown is impossible because the helper script is missing
        logger -t "$LOGTAG" "WARNING: mervlan_boot.sh missing; cannot pre-disable hooks"
    fi
else
    # No remote cleanup needed when nodes are absent or SSH keys were not set up
    logger -t "$LOGTAG" "Pre-uninstall: no eligible nodes detected or SSH keys not installed"
fi

# ============================================================================ #
# ASUSWRT UI CLEANUP — Remove user pages, menu entries, and static assets     #
# ============================================================================ #

########################################
# 1. Figure out which user page we mounted
########################################
# We saved this during install
am_page="$(am_settings_get merlin_vlan_manager_page)"

# Discover the ASP slot by title when the stored page reference is empty
if [ -z "$am_page" ]; then
    am_page="$(ls /www/user/user*.asp 2>/dev/null | xargs -r grep -l 'VLAN Manager' 2>/dev/null | xargs -r -n1 basename | head -n1)"
fi

logger -t "$LOGTAG" "Uninstalling $ADDON page '$am_page'"

########################################
# 2. Make sure we have a writable copy of menuTree.js
#    (same trick as installer, but in reverse)
########################################
# Bind a writable copy of menuTree.js so navigation edits persist this boot
if [ ! -f /tmp/menuTree.js ]; then
    # If nobody prepared /tmp/menuTree.js yet this boot, create it now
    cp /www/require/modules/menuTree.js /tmp/ 2>/dev/null
    mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js 2>/dev/null
fi

# 3. Remove our VLAN tab entry from Tools
#    We only nuke the specific line that references our page + tabName "VLAN".
# Remove the navigation entry that points to our VLAN Manager UI
if [ -f /tmp/menuTree.js ]; then
    # Prefer precise removal using the page URL when available
    if [ -n "$am_page" ]; then
        sed -i "/url: \"$am_page\".*tabName: \"VLAN\"/d" /tmp/menuTree.js
    else
        # fallback: remove any tab literally called VLAN
        sed -i '/tabName: "VLAN"/d' /tmp/menuTree.js
    fi

    # Rebind to refresh, same quirk as installer
    umount /www/require/modules/menuTree.js 2>/dev/null
    mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js 2>/dev/null
fi

########################################
# 4. Remove published web assets
########################################
# Remove the main ASP page
# Delete the ASP view so the Tools menu no longer loads MerVLAN
if [ -n "$am_page" ]; then
    rm -f "/www/user/$am_page"
fi

# Remove our static asset directory
rm -rf /www/user/merlin_vlan_manager

# Remove service-event and addon hooks via setupdisable
# Run setupdisable to unregister service-event handlers and node sync scripts
if [ -x "$MERV_BASE/functions/mervlan_boot.sh" ]; then
    echo "[uninstall] invoking setupdisable to remove hooks"
    # Log outcome of setupdisable while skipping node sync for performance
    if MERV_SKIP_NODE_SYNC=1 sh "$MERV_BASE/functions/mervlan_boot.sh" setupdisable >/dev/null 2>&1; then
        echo "[uninstall] setupdisable completed successfully"
    else
        echo "[uninstall] WARNING: setupdisable failed" >&2
    fi
else
    echo "[uninstall] WARNING: mervlan_boot.sh not executable or missing; skipping setupdisable" >&2
fi

########################################
# 5. Mark addon disabled / cleanup settings
########################################
am_settings_set merlin_vlan_manager_state "disabled"
am_settings_set merlin_vlan_manager_page ""
am_settings_set merlin_vlan_manager_version ""

logger -t "$LOGTAG" "$ADDON uninstalled"
# When ACTION=full, remove addon directories for a clean slate reinstall later
if [ "$ACTION" = "full" ]; then
    logger -t "$LOGTAG" "Performing full uninstall (removing addon directories)"
    rm -rf /jffs/addons/mervlan 2>/dev/null
    rm -rf /tmp/mervlan_tmp 2>/dev/null
fi
exit 0