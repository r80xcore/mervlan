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

# ========================================================================== #
# Helpers
# ========================================================================== #

ensure_json_store() {
    # ensure_json_store [file] [defaults]
    # Create the containing directory and seed the JSON file if missing/empty.
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
    # json_escape_string <value>
    # Emit the input with JSON string-appropriate escaping for quotes and backslashes.
    # Caller captures stdout; no trailing newline is emitted.
    local value="$1"
    printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n'
}

json_set_flag() {
    # json_set_flag <key> <value> [file] [defaults]
    # Only change the value of "key": "value".
    # If key exists: in-place sed replacement of the value.
    # If key does not exist: append a new row before the closing '}'.
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



json_get_int() {
    # json_get_int <key> <default> [file]
    # Returns: sanitized integer or <default> if missing/invalid.
    local key="$1"
    local default_value="$2"
    local file="${3:-$SETTINGS_FILE}"
    local raw num

    # Reuse json_get_flag to extract the raw string
    raw="$(json_get_flag "$key" "$default_value" "$file")"

    # Strip whitespace and quotes (handles "1", " 1 ", etc.)
    num="$(printf '%s' "$raw" | tr -d '[:space:]"')"

    case "$num" in
        ''|*[!0-9]*)
            printf '%s\n' "$default_value"
            return 1
            ;;
        *)
            printf '%s\n' "$num"
            return 0
            ;;
    esac
}


json_ensure_flag() {
    # json_ensure_flag <key> <default> [file]
    local key="$1"
    local default_value="$2"
    local file="${3:-$SETTINGS_FILE}"

    if [ "$(json_get_flag "$key" "__MISSING__" "$file")" != "__MISSING__" ]; then
        return 0
    fi

    json_set_flag "$key" "$default_value" "$file"
}

json_apply_kv_file() {
    # json_apply_kv_file <kv_file> [json_file] [defaults]
    # Merge key\tvalue lines into the target JSON file without disturbing other keys.
    local kv_file="$1"
    local file="${2:-$SETTINGS_FILE}"
    local defaults="${3:-}"

    [ -n "$kv_file" ] || return 0
    [ -f "$kv_file" ] || return 0

    ensure_json_store "$file" "$defaults" || return 1

    # shellcheck disable=SC2162
    while IFS="$(printf '\t')" read -r key value || [ -n "$key" ]; do
        [ -n "$key" ] || continue
        json_set_flag "$key" "${value:-}" "$file" "$defaults" || return 1
    done < "$kv_file"

    return 0
}


auto_detect_nodes() {
    # Requires: /proc/net/arp, wget, json_set_flag, SETTINGS_FILE
    local do_detect ans
    local tmp_candidates tmp_selected

    echo ""
    echo "[install] Auto-detect Asus / AiMesh AP/nodes?"
    while :; do
        printf "[install] Enable auto-detection? [Y/n]: "
        IFS= read -r ans || ans=""
        case "$ans" in
            ""|Y|y|YES|yes|Yes)
                do_detect=1
                break
                ;;
            N|n|NO|no|No)
                do_detect=0
                break
                ;;
            *)
                echo "[install] Please answer Y or N."
                ;;
        esac
    done

    # User chose not to auto-detect → caller can continue with existing flow
    [ "$do_detect" = "1" ] || return 0

    tmp_candidates="/tmp/mervlan_autonodes.$$"
    tmp_selected="/tmp/mervlan_selected_nodes.$$"
    : > "$tmp_candidates" || return 1
    : > "$tmp_selected" || return 1

    echo ""
    echo "[install] Scanning ARP table for possible Asus / AiMesh devices..."
    echo "[install] This may take a few seconds."

    # ----------------------------------------------------------------------
    # Step 1: Scan ARP and probe http://IP/message.htm for Asus/AiMesh hints
    # ----------------------------------------------------------------------
    awk 'NR>1 && $4!="00:00:00:00:00:00"{print $1, $4}' /proc/net/arp | \
    {
        idx=1
        while read ip mac; do
            page=$(wget -T3 -t1 -qO- "http://$ip/message.htm" 2>/dev/null) || page=""
            [ -z "$page" ] && continue

            match=""
            if printf '%s\n' "$page" | grep -qi 'aimesh'; then
                match="AiMesh"
            elif printf '%s\n' "$page" | grep -qi 'router detect'; then
                match="router detect"
            elif printf '%s\n' "$page" | grep -qi 'asus'; then
                match="ASUS"
            fi

            if [ -n "$match" ]; then
                # Store index, IP, MAC for later lookup
                printf '%s %s %s\n' "$idx" "$ip" "$mac" >>"$tmp_candidates"
                # Show user a nice numbered list
                echo "  $idx) $ip  $mac  [$match]"
                idx=$((idx+1))
            fi
        done

        # Subshell ends here; tmp_candidates persists on disk
    }

    if [ ! -s "$tmp_candidates" ]; then
        echo "[install] No Asus/AiMesh-style devices were detected from ARP + HTTP."
        echo "[install] You can still configure nodes manually in the next step."
    else
        echo ""
        echo "[install] Detected candidates above."
        echo "[install] Enter the numbers of the devices you want to use as nodes."
        echo "[install] Example: 1,3 or 2,4,5"
        echo "[install] (Leave empty to skip auto-select and do everything manually.)"
        echo ""

        local selection
        printf "[install] Your choice: "
        IFS= read -r selection || selection=""

        if [ -n "$selection" ]; then
            # Normalize: "1, 3,4" → "1 3 4"
            selection=$(printf '%s\n' "$selection" | tr ',' ' ')
            for num in $selection; do
                num=$(printf '%s' "$num" | tr -cd '0-9')
                [ -z "$num" ] && continue
                # candidate line: "<idx> <ip> <mac>"
                line=$(awk -v n="$num" '$1==n {print; exit}' "$tmp_candidates")
                [ -z "$line" ] && continue
                ip=$(printf '%s\n' "$line" | awk '{print $2}')
                mac=$(printf '%s\n' "$line" | awk '{print $3}')
                echo "$ip $mac" >>"$tmp_selected"
                echo "[install] Selected: $ip  $mac"
            done
        fi
    fi

    # ----------------------------------------------------------------------
    # Step 2: Ask if everything was found; if not, add manual IP/MAC entries
    # ----------------------------------------------------------------------
    echo ""
    echo "[install] Were ALL intended nodes/APs identified in the list above?"
    while :; do
        printf "[install] Answer Y if yes, N to add missing devices manually [Y/n]: "
        IFS= read -r ans || ans=""
        case "$ans" in
            ""|Y|y|YES|yes|Yes)
                all_done=1
                break
                ;;
            N|n|NO|no|No)
                all_done=0
                break
                ;;
            *)
                echo "[install] Please answer Y or N."
                ;;
        esac
    done

    if [ "$all_done" = "0" ]; then
        echo ""
        echo "[install] You can now add missing nodes by IP or MAC."
        echo "[install] Examples:"
        echo "          - IP : 192.168.1.20"
        echo "          - MAC: aa:bb:cc:dd:ee:ff"
        echo "[install] Press Enter on a blank line when you are done."
        echo ""

        while :; do
            local extra ip mac
            printf "[install] Enter additional node IP or MAC (blank to finish): "
            IFS= read -r extra || extra=""
            [ -z "$extra" ] && break

            case "$extra" in
                *.*.*.*)  # looks like IP
                    ip="$extra"
                    mac=$(awk -v ip="$ip" 'NR>1 && $1==ip {print $4; exit}' /proc/net/arp)
                    ;;
                *:*)      # looks like MAC
                    mac=$(printf '%s\n' "$extra" | tr 'A-F' 'a-f')
                    ip=$(awk -v m="$mac" 'NR>1 && tolower($4)==m {print $1; exit}' /proc/net/arp)
                    ;;
                *)
                    echo "[install] Input does not look like a valid IP or MAC; skipping."
                    continue
                    ;;
            esac

            if [ -z "$ip" ] || [ -z "$mac" ]; then
                echo "[install] Could not resolve both IP and MAC from ARP for '$extra'."
                echo "[install] Make sure the device is online and has talked recently."
                continue
            fi

            echo "$ip $mac" >>"$tmp_selected"
            echo "[install] Added node: $ip  $mac"
        done
    fi

    # ----------------------------------------------------------------------
    # Step 3: Persist into settings.json via json_set_flag
    # ----------------------------------------------------------------------
    if [ ! -s "$tmp_selected" ]; then
        echo ""
        echo "[install] No nodes selected or added. Skipping JSON update."
        rm -f "$tmp_candidates" "$tmp_selected" 2>/dev/null || :
        return 0
    fi

    echo ""
    echo "[install] Persisting selected nodes into settings.json"

    local idx=1 ip mac key_ip key_mac
    while read ip mac; do
        [ -z "$ip" ] && continue

        key_ip="AUTO_NODE${idx}_IP"
        key_mac="AUTO_NODE${idx}_MAC"

        # Use your sed-based json_set_flag helper
        if ! json_set_flag "$key_ip" "$ip" "$SETTINGS_FILE" >/dev/null 2>&1; then
            echo "[install] WARNING: Failed to store $key_ip in $SETTINGS_FILE"
        fi
        if ! json_set_flag "$key_mac" "$mac" "$SETTINGS_FILE" >/dev/null 2>&1; then
            echo "[install] WARNING: Failed to store $key_mac in $SETTINGS_FILE"
        fi

        idx=$((idx+1))
    done < "$tmp_selected"

    echo "[install] Stored $((idx-1)) node entries in $SETTINGS_FILE (AUTO_NODE*_IP/MAC)."

    rm -f "$tmp_candidates" "$tmp_selected" 2>/dev/null || :
    return 0
}

get_node_ip_from_mac() {
    # get_node_ip_from_mac <mac> → IP or empty
    # normalise to lowercase
    local mac="$(printf '%s\n' "$1" | tr 'A-F' 'a-f')"
    awk -v m="$mac" 'NR>1 && tolower($4)==m {print $1; exit}' /proc/net/arp
}
# ========================================================================== #
prompt_ssh_port_override() {
    # Configure SSH port for node connections, stored in settings.json.
    local current_port reply port

    echo ""
    echo "[install] Configure SSH port for node connections."

    # Read current port from settings.json; default to 22 if missing/empty
    current_port=$(json_get_flag "NODE_SSH_PORT" "__MISSING__" "$SETTINGS_FILE" 2>/dev/null)
    if [ "$current_port" = "__MISSING__" ] || [ -z "$current_port" ]; then
        current_port=$(json_get_flag "SSH_PORT" "22" "$SETTINGS_FILE" 2>/dev/null)
    fi
    [ -n "$current_port" ] || current_port="22"

    while :; do
        printf '[install] Use SSH port %s? [Y/n]: ' "$current_port"
        IFS= read -r reply || reply=""
        case "$reply" in
            ""|Y|y|YES|yes|Yes)
                echo "[install] Keeping SSH port $current_port."
                # Persist the selection in both new and legacy keys for compatibility
                json_set_flag "NODE_SSH_PORT" "$current_port" "$SETTINGS_FILE" >/dev/null 2>&1
                json_set_flag "SSH_PORT" "$current_port" "$SETTINGS_FILE" >/dev/null 2>&1
                return 0
                ;;
            N|n|NO|no|No)
                while :; do
                    printf '[install] Enter SSH port (1-65535): '
                    IFS= read -r port || port=""
                    case "$port" in
                        ''|*[^0-9]*)
                            echo "[install] Invalid entry; please enter digits only."
                            continue
                            ;;
                    esac
                    if [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                        # Write to settings.json using central JSON helper
                        if json_set_flag "NODE_SSH_PORT" "$port" "$SETTINGS_FILE" >/dev/null 2>&1; then
                            json_set_flag "SSH_PORT" "$port" "$SETTINGS_FILE" >/dev/null 2>&1
                            echo "[install] SSH port updated to $port in settings.json."
                        else
                            echo "[install] Failed to update SSH port in settings.json."
                        fi
                        return 0
                    else
                        echo "[install] Port out of range (1-65535)."
                    fi
                done
                ;;
            *)
                echo "[install] Please answer Y or N."
                ;;
        esac
    done
}

prompt_ssh_user_override() {
    # Configure default SSH admin username for node connections, stored in settings.json.
    local current_user reply new_user

    echo ""
    echo "[install] Configure default SSH admin username for node connections."

    # Read current username from settings.json; default to 'admin' if missing/empty
    current_user=$(json_get_flag "NODE_SSH_USER" "__MISSING__" "$SETTINGS_FILE" 2>/dev/null)
    if [ "$current_user" = "__MISSING__" ] || [ -z "$current_user" ]; then
        current_user=$(json_get_flag "SSH_USER" "admin" "$SETTINGS_FILE" 2>/dev/null)
    fi
    [ -n "$current_user" ] || current_user="admin"

    while :; do
        printf '[install] Use SSH username "%s"? [Y/n]: ' "$current_user"
        IFS= read -r reply || reply=""
        case "$reply" in
            ""|Y|y|YES|yes|Yes)
                echo "[install] Keeping SSH username \"$current_user\"."
                # Persist under both new and legacy keys so callers stay in sync
                json_set_flag "NODE_SSH_USER" "$current_user" "$SETTINGS_FILE" >/dev/null 2>&1
                json_set_flag "SSH_USER" "$current_user" "$SETTINGS_FILE" >/dev/null 2>&1
                return 0
                ;;
            N|n|NO|no|No)
                while :; do
                    printf '[install] Enter SSH username (no spaces, no quotes): '
                    IFS= read -r new_user || new_user=""
                    # Basic validation: non-empty, no spaces, no double quotes
                    case "$new_user" in
                        "" )
                            echo "[install] Username cannot be empty."
                            continue
                            ;;
                        *[\"\ ]* )
                            echo "[install] Invalid username; avoid spaces and double quotes."
                            continue
                            ;;
                    esac

                    # You can tighten this if you want (e.g. restrict to [-a-zA-Z0-9_])
                    # case "$new_user" in
                    #     *[!a-zA-Z0-9_-]* )
                    #         echo "[install] Use only letters, digits, '_' or '-'."
                    #         continue
                    #         ;;
                    # esac

                    if json_set_flag "NODE_SSH_USER" "$new_user" "$SETTINGS_FILE" >/dev/null 2>&1; then
                        json_set_flag "SSH_USER" "$new_user" "$SETTINGS_FILE" >/dev/null 2>&1
                        echo "[install] SSH username updated to \"$new_user\" in settings.json."
                    else
                        echo "[install] Failed to update SSH username in settings.json."
                    fi
                    return 0
                done
                ;;
            *)
                echo "[install] Please answer Y or N."
                ;;
        esac
    done
}


get_node_ssh_user() {
    local user="__MISSING__"

    # Prefer NODE_SSH_USER if set
    user=$(json_get_flag "NODE_SSH_USER" "__MISSING__" "$SETTINGS_FILE" 2>/dev/null)
    if [ "$user" = "__MISSING__" ] || [ -z "$user" ]; then
        # Fall back to SSH_USER
        user=$(json_get_flag "SSH_USER" "__MISSING__" "$SETTINGS_FILE" 2>/dev/null)
    fi

    # Final fallback: admin
    if [ "$user" = "__MISSING__" ] || [ -z "$user" ]; then
        user="admin"
    fi

    printf '%s\n' "$user"
}

get_node_ssh_port() {
    local port

    # Prefer environment override if it’s a clean integer
    case "${SSH_PORT:-}" in
        ""|*[!0-9]*) port="" ;;
        *) port="$SSH_PORT" ;;
    esac

    # If no valid env override, read from settings.json (new key preferred)
    if [ -z "$port" ]; then
        port=$(json_get_flag "NODE_SSH_PORT" "__MISSING__" "$SETTINGS_FILE" 2>/dev/null)
        if [ "$port" = "__MISSING__" ] || [ -z "$port" ]; then
            port=$(json_get_flag "SSH_PORT" "22" "$SETTINGS_FILE" 2>/dev/null)
        fi
    fi

    # Final sanity: enforce numeric + range
    case "$port" in
        ""|*[!0-9]*) port="22" ;;
    esac
    if [ "$port" -lt 1 ] 2>/dev/null || [ "$port" -gt 65535 ] 2>/dev/null; then
        port="22"
    fi

    printf '%s\n' "$port"
}


_sync_ssh_flag() {
	# _sync_ssh_flag <value>
	# Ensure the SSH key installed flag reflects detected state when helpers exist.
	local desired="$1"
	[ -n "$desired" ] || return 0

	if command -v json_set_flag >/dev/null 2>&1; then
		json_set_flag "SSH_KEYS_INSTALLED" "$desired" >/dev/null 2>&1
	fi
	return 0
}

ssh_keys_effectively_installed() {
    local flag="0" have_keys="0" flag_present="0"

    # Check actual key files
    if [ -n "${SSH_KEY:-}" ] && [ -f "$SSH_KEY" ] && \
       [ -n "${SSH_PUBKEY:-}" ] && [ -f "$SSH_PUBKEY" ]; then
        have_keys="1"
    fi

    if command -v json_get_flag >/dev/null 2>&1; then
        # Read flag via JSON helper
        flag=$(json_get_flag "SSH_KEYS_INSTALLED" "0" "$SETTINGS_FILE" 2>/dev/null)

        # Detect presence by using a special sentinel
        if [ "$(json_get_flag "SSH_KEYS_INSTALLED" "__MISSING__" "$SETTINGS_FILE" 2>/dev/null)" != "__MISSING__" ]; then
            flag_present="1"
        fi
    elif [ -f "${SETTINGS_FILE:-}" ]; then
        # Legacy grep-only fallback
        if grep -q '"SSH_KEYS_INSTALLED"[[:space:]]*:[[:space:]]*"1"' "$SETTINGS_FILE" 2>/dev/null; then
            flag="1"
        fi
        if grep -q '"SSH_KEYS_INSTALLED"' "$SETTINGS_FILE" 2>/dev/null; then
            flag_present="1"
        fi
    fi

    # If flag key is missing entirely, sync it to whatever we think it currently is
    if [ "$flag_present" = "0" ] && [ -n "${SETTINGS_FILE:-}" ] && command -v json_set_flag >/dev/null 2>&1; then
        _sync_ssh_flag "$flag"
        flag=$(json_get_flag "SSH_KEYS_INSTALLED" "0" "$SETTINGS_FILE" 2>/dev/null)
    fi

    # If physical keys and flag disagree, make them consistent
    if [ "$have_keys" = "1" ] && [ "$flag" != "1" ]; then
        _sync_ssh_flag "1"
        flag="1"
    elif [ "$have_keys" = "0" ] && [ "$flag" = "1" ]; then
        _sync_ssh_flag "0"
        flag="0"
    fi

    # Final decision: success if either real keys or flag say "installed"
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