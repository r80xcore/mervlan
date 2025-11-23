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
BOOT_SCRIPT="$MERV_BASE/functions/mervlan_boot.sh"
SSH_KEY="$MERV_BASE/.ssh/vlan_manager"
SSH_PUBKEY="$MERV_BASE/.ssh/vlan_manager.pub"

# ============================================================================ #
# EMBEDDED JSON HELPERS — Minimal subset required during uninstall            #
# ============================================================================ #

ensure_json_store() {
    local file="${1:-$SETTINGS_FILE}" defaults="${2:-}" dir

    dir=$(dirname "$file")
    mkdir -p "$dir" 2>/dev/null || return 1

    if [ ! -s "$file" ]; then
        if [ -n "$defaults" ]; then
            printf '%s\n' "$defaults" > "$file" || return 1
        else
            printf '{\n}\n' > "$file" || return 1
        fi
    fi

    return 0
}

json_escape_string() {
    local value="$1"
    printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n'
}

json_set_flag() {
    local key="$1"
    local value="$2"
    local file="${3:-$SETTINGS_FILE}"
    local defaults="${4:-}"
    local json_value sed_value script tmp

    [ -n "$key" ] || return 1

    ensure_json_store "$file" "$defaults" || return 1

    json_value=$(json_escape_string "$value")
    sed_value=$(printf '%s' "$json_value" | sed 's/\\/\\\\/g; s/&/\\&/g')

    if grep -q "\"$key\""[[:space:]]*: "$file" 2>/dev/null; then
        script="${file}.sed.$$"
        printf 's/"%s"[[:space:]]*:[[:space:]]*"[^"]*"/"%s": "%s"/\n' "$key" "$key" "$sed_value" > "$script" || {
            rm -f "$script"
            return 1
        }
        if ! sed -i -f "$script" "$file" 2>/dev/null; then
            rm -f "$script"
            return 1
        fi
        rm -f "$script"
        return 0
    fi

    if grep -q '"[^"]\+"' "$file" 2>/dev/null; then
        tmp="${file}.tmp.$$"
        JSON_SET_FLAG_VALUE="$json_value" \
        awk -v key="$key" '
            BEGIN {
                value = ENVIRON["JSON_SET_FLAG_VALUE"]
                last_prop = -1
            }
            {
                lines[NR] = $0
                if ($0 ~ /"[^"]+"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*(,)?[[:space:]]*$/) {
                    last_prop = NR
                }
            }
            END {
                if (last_prop == -1) {
                    printf "{\n  \"%s\": \"%s\"\n}\n", key, value
                    exit
                }

                for (i = 1; i < last_prop; i++) {
                    print lines[i]
                }

                line = lines[last_prop]
                sub(/[[:space:]]*$/, "", line)
                if (line !~ /,$/) {
                    line = line ","
                }
                print line

                printf "  \"%s\": \"%s\"\n", key, value

                for (i = last_prop + 1; i <= NR; i++) {
                    print lines[i]
                }
            }
        ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }

        mv "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
        return 0
    fi

    printf '{\n  "%s": "%s"\n}\n' "$key" "$json_value" > "$file" || return 1
    return 0
}

json_get_flag() {
    # json_get_flag <key> [default] [file]
    local key="$1"
    local default_value="${2:-}"
    local file="${3:-$SETTINGS_FILE}"

    [ -n "$key" ] || { printf '%s\n' "$default_value"; return 1; }

    if [ ! -s "$file" ]; then
        printf '%s\n' "$default_value"
        return 0
    fi

    # Extract "VALUE" from a line like:  "KEY": "VALUE",
    # - ignores leading spaces
    # - allows spaces around colon
    # - ignores trailing comma and spaces
    local value
    value="$(sed -n "s/^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\"[[:space:]]*,\{0,1\}[[:space:]]*$/\\1/p" "$file")"

    if [ -n "$value" ]; then
        printf '%s\n' "$value"
    else
        printf '%s\n' "$default_value"
    fi
}

# ============================================================================ #
# EMBEDDED SSH HELPERS — Node credentials & key state detection               #
# ============================================================================ #

get_node_ssh_user() {
    local user="__MISSING__"

    user=$(json_get_flag "NODE_SSH_USER" "__MISSING__" "$SETTINGS_FILE" 2>/dev/null)
    if [ "$user" = "__MISSING__" ] || [ -z "$user" ]; then
        user=$(json_get_flag "SSH_USER" "__MISSING__" "$SETTINGS_FILE" 2>/dev/null)
    fi
    if [ "$user" = "__MISSING__" ] || [ -z "$user" ]; then
        user="admin"
    fi

    printf '%s\n' "$user"
}

get_node_ssh_port() {
    local port

    case "${SSH_PORT:-}" in
        ''|*[!0-9]*) port="" ;;
        *) port="$SSH_PORT" ;;
    esac

    if [ -z "$port" ]; then
        port=$(json_get_flag "NODE_SSH_PORT" "__MISSING__" "$SETTINGS_FILE" 2>/dev/null)
        if [ "$port" = "__MISSING__" ] || [ -z "$port" ]; then
            port=$(json_get_flag "SSH_PORT" "22" "$SETTINGS_FILE" 2>/dev/null)
        fi
    fi

    case "$port" in
        ''|*[!0-9]*) port="22" ;;
    esac
    if [ "$port" -lt 1 ] 2>/dev/null || [ "$port" -gt 65535 ] 2>/dev/null; then
        port="22"
    fi

    printf '%s\n' "$port"
}

_sync_ssh_flag() {
    local desired="$1"
    [ -n "$desired" ] || return 0

    if command -v json_set_flag >/dev/null 2>&1; then
        json_set_flag "SSH_KEYS_INSTALLED" "$desired" "$SETTINGS_FILE" >/dev/null 2>&1
    fi
    return 0
}

ssh_keys_effectively_installed() {
    local flag="0" have_keys="0" flag_present="0"

    if [ -n "${SSH_KEY:-}" ] && [ -f "$SSH_KEY" ] && \
       [ -n "${SSH_PUBKEY:-}" ] && [ -f "$SSH_PUBKEY" ]; then
        have_keys="1"
    fi

    if command -v json_get_flag >/dev/null 2>&1; then
        flag=$(json_get_flag "SSH_KEYS_INSTALLED" "0" "$SETTINGS_FILE" 2>/dev/null)
        if [ "$(json_get_flag "SSH_KEYS_INSTALLED" "__MISSING__" "$SETTINGS_FILE" 2>/dev/null)" != "__MISSING__" ]; then
            flag_present="1"
        fi
    elif [ -f "${SETTINGS_FILE:-}" ]; then
        if grep -q '"SSH_KEYS_INSTALLED"[[:space:]]*:[[:space:]]*"1"' "$SETTINGS_FILE" 2>/dev/null; then
            flag="1"
        fi
        if grep -q '"SSH_KEYS_INSTALLED"' "$SETTINGS_FILE" 2>/dev/null; then
            flag_present="1"
        fi
    fi

    if [ "$flag_present" = "0" ] && [ -n "${SETTINGS_FILE:-}" ] && command -v json_set_flag >/dev/null 2>&1; then
        _sync_ssh_flag "$flag"
        flag=$(json_get_flag "SSH_KEYS_INSTALLED" "0" "$SETTINGS_FILE" 2>/dev/null)
    fi

    if [ "$have_keys" = "1" ] && [ "$flag" != "1" ]; then
        _sync_ssh_flag "1"
        flag="1"
    elif [ "$have_keys" = "0" ] && [ "$flag" = "1" ]; then
        _sync_ssh_flag "0"
        flag="0"
    fi

    if [ "$have_keys" = "1" ] || [ "$flag" = "1" ]; then
        return 0
    fi

    return 1
}

list_configured_nodes() {
    [ -f "$SETTINGS_FILE" ] || return 1
    grep -o '"NODE[1-5]"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" 2>/dev/null | \
        sed -n "s/.*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | \
        grep -v "none" | \
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

# ============================================================================ #
# NODE & SSH STATE HELPERS — Determine remote cleanup prerequisites           #
# ============================================================================ #

# has_configured_nodes — Report configured NODE entries containing IPv4s
# Returns: 0 when at least one valid node IP is present, 1 otherwise
# Explanation: Indicates whether remote hooks must be disabled before files
#   are removed from the router.
has_configured_nodes() {
    local nodes
    nodes=$(list_configured_nodes)
    [ -n "$nodes" ]
}

remove_nodes_full_install() {
    local nodes user ssh_bin impl node port
    nodes=$(list_configured_nodes)
    [ -n "$nodes" ] || return 0

    if command -v dbclient >/dev/null 2>&1; then
        ssh_bin=$(command -v dbclient)
        impl="dbclient"
    elif command -v ssh >/dev/null 2>&1; then
        ssh_bin=$(command -v ssh)
        impl="ssh"
    else
        logger -t "$LOGTAG" "WARNING: No SSH client available; cannot clean nodes"
        return 1
    fi

    if [ ! -f "$SSH_KEY" ]; then
        logger -t "$LOGTAG" "WARNING: SSH key missing; skipping node cleanup"
        return 1
    fi

    user=$(get_node_ssh_user)
    port=$(get_node_ssh_port)
    for node in $nodes; do
        if [ "$impl" = "dbclient" ]; then
            if "$ssh_bin" -p "$port" -y -i "$SSH_KEY" \
                "$user@$node" "rm -rf /jffs/addons/mervlan /tmp/mervlan_tmp" >/dev/null 2>&1; then
                logger -t "$LOGTAG" "Node cleanup success: $node"
            else
                logger -t "$LOGTAG" "WARNING: Node cleanup failed for $node"
            fi
        else
            if "$ssh_bin" -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                "$user@$node" "rm -rf /jffs/addons/mervlan /tmp/mervlan_tmp" >/dev/null 2>&1; then
                logger -t "$LOGTAG" "Node cleanup success: $node"
            else
                logger -t "$LOGTAG" "WARNING: Node cleanup failed for $node"
            fi
        fi
    done
}

# Ensure cron job is removed before continuing cleanup
if [ -x "$BOOT_SCRIPT" ]; then
    logger -t "$LOGTAG" "Pre-uninstall: disabling cron job"
    if ! sh "$BOOT_SCRIPT" crondisable >/dev/null 2>&1; then
        logger -t "$LOGTAG" "WARNING: mervlan_boot.sh crondisable failed pre-uninstall"
    fi
else
    logger -t "$LOGTAG" "WARNING: mervlan_boot.sh missing; cannot disable cron job"
fi

# ============================================================================ #
# PRE-UNINSTALL HOOK DISABLE — Stop MerVLAN services before file removal      #
# ============================================================================ #

# Disable router and node hooks first so MerVLAN stops executing during cleanup
if has_configured_nodes && ssh_keys_effectively_installed; then
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
# We saved this during install (new key) — fall back to legacy name if absent
am_page="$(am_settings_get mervlan_page)"
[ -n "$am_page" ] || am_page="$(am_settings_get merlin_vlan_manager_page)"

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

# 3. Remove our MerVLAN tab entry from LAN
#    We only nuke the specific line that references our page + tabName "MerVLAN".
# Remove the navigation entry that points to our MerVLAN UI
if [ -f /tmp/menuTree.js ]; then
    # Prefer precise removal using the page URL when available
    if [ -n "$am_page" ]; then
        sed -i "/url: \"$am_page\".*tabName: \"MerVLAN\"/d" /tmp/menuTree.js
    else
        # fallback: remove any tab literally called MerVLAN
        sed -i '/tabName: "MerVLAN"/d' /tmp/menuTree.js
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

# Remove our static asset directory (new path, keep legacy for safety)
rm -rf /www/user/mervlan 2>/dev/null
rm -rf /www/user/merlin_vlan_manager 2>/dev/null

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
am_settings_set mervlan_state "disabled"
am_settings_set mervlan_page ""
am_settings_set mervlan_version ""
am_settings_set merlin_vlan_manager_state "disabled"
am_settings_set merlin_vlan_manager_page ""
am_settings_set merlin_vlan_manager_version ""

logger -t "$LOGTAG" "$ADDON uninstalled"
# When ACTION=full, remove addon directories for a clean slate reinstall later
if [ "$ACTION" = "full" ]; then
    logger -t "$LOGTAG" "Performing full uninstall (removing addon directories)"
    if has_configured_nodes && ssh_keys_effectively_installed; then
        remove_nodes_full_install
    fi
    rm -rf /jffs/addons/mervlan 2>/dev/null
    rm -rf /tmp/mervlan_tmp 2>/dev/null
    rm -rf /www/user/mervlan 2>/dev/null
fi
exit 0