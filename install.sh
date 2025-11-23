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
#                    - File: install.sh || version="0.45"                      #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Enable the MerVLAN addon and set up necessary files            #
#                                                                              #
# ──────────────────────────────────────────────────────────────────────────── #

source /usr/sbin/helper.sh

# ========================================================================== #
# CONFIGURATION PATHS & CONSTANTS — Source locations and workspace defaults  #
# ========================================================================== #

# GITHUB_URL — Tarball endpoint for fetching latest MerVLAN release snapshot
# ADDON_DIR/ADDON/MERV_BASE — Install root beneath /jffs/addons
# PUBLIC_DIR — Files exposed to web UI for SPA assets and JSON data
# TMP_DIR/TMP — Workspace for transient downloads and log files
# SETTINGS_FILE — JSON configs used during install
# BOOT_SCRIPT — Helper used for setupenable/nodeenable orchestration

GITHUB_URL="https://codeload.github.com/r80xcore/mervlan/tar.gz/refs/heads/main"
ADDON_DIR="/jffs/addons"
ADDON="mervlan"
MERV_BASE="$ADDON_DIR/$ADDON"
PUBLIC_DIR="/www/user/mervlan"
TMP_DIR="/tmp/mervlan_tmp"
TMP="${TMP_DIR:-$(mktemp -d)}"
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

# ========================================================================== #
# NODE & SSH STATE HELPERS — Detect existing node config and key installs    #
# ========================================================================== #
# (Embedded subset in this script to avoid external dependencies)

# has_configured_nodes — Report if any NODE1..NODE5 entries contain IPs
# Returns: 0 when at least one valid IPv4 is present, 1 otherwise
# Explanation: Allows installer to decide whether to call nodeenable later
has_configured_nodes() {
    [ -f "$SETTINGS_FILE" ] || return 1
    local nodes
    nodes=$(grep -o '"NODE[1-5]"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" 2>/dev/null | \
        sed -n 's/.*:[[:space:]]*"\([^"]*\)".*/\1/p' | \
        grep -v "none" | \
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    [ -n "$nodes" ]
}

# ========================================================================== #
# DOWNLOAD & BOOTSTRAP UTILITIES — Fetch repo and prepare fresh install      #
# ========================================================================== #

# download_mervlan — Retrieve tarball, extract, copy into $MERV_BASE
# Args: none (uses global paths/URLs)
# Returns: 0 on success, non-zero on download/extract failures
# Explanation: Handles BusyBox quirks (tar -z support), ensures permissions,
#   injects service-event hooks, and runs hardware probe on new installs
download_mervlan() {
  set -e
    echo "[download_mervlan] start"
    echo "[download_mervlan] GITHUB_URL=$GITHUB_URL"
    echo "[download_mervlan] MERV_BASE=$MERV_BASE"
    mkdir -p "$MERV_BASE"
    echo "[download_mervlan] ensured MERV_BASE exists"

  # Use provided TMP_DIR; otherwise create a private temp workspace
  local tmp created=0
    if [ -n "$TMP_DIR" ]; then
    tmp="$TMP_DIR"
    mkdir -p "$tmp"
  else
    tmp="$(mktemp -d)"; created=1
  fi
    echo "[download_mervlan] tmp workspace: $tmp (created=$created)"
    trap 'if [ "$created" -eq 1 ]; then echo "[download_mervlan] cleaning tmp: $tmp"; rm -rf "$tmp"; fi' EXIT

# ========================================================================== #
# SSH PORT CONFIGURATION — Optional override for node SSH connections       #
# ========================================================================== #
# Source: settings/lib_ssh.sh

  # Fetch archive to a file (curl only)
    echo "[download_mervlan] downloading archive -> $tmp/mervlan.tar.gz"
    /usr/sbin/curl -fsL --retry 3 "$GITHUB_URL" -o "$tmp/mervlan.tar.gz"
    if [ -s "$tmp/mervlan.tar.gz" ]; then
        echo "[download_mervlan] download ok, size=$(wc -c < "$tmp/mervlan.tar.gz" 2>/dev/null) bytes"
    else
        echo "[download_mervlan] ERROR: download failed or empty file" >&2
        return 1
    fi

  # Extract: prefer tar -xzf; fallback to gzip -dc | tar -x for BusyBox without -z
    if tar -tzf "$tmp/mervlan.tar.gz" >/dev/null 2>&1; then
        echo "[download_mervlan] extracting with tar -xzf"
        tar -xzf "$tmp/mervlan.tar.gz" -C "$tmp"
  else
        echo "[download_mervlan] extracting with gzip -dc | tar -x (fallback)"
        gzip -dc "$tmp/mervlan.tar.gz" | tar -x -C "$tmp"
  fi
    echo "[download_mervlan] extraction complete; top-level entries:"
    ls -1 "$tmp" 2>/dev/null | sed 's/^/[download_mervlan]   /'

    # Determine top-level extracted directory from archive listing, with fallbacks
    local topdir="" topname=""
    if tar -tzf "$tmp/mervlan.tar.gz" >/dev/null 2>&1; then
        topname="$(tar -tzf "$tmp/mervlan.tar.gz" 2>/dev/null | head -1 | cut -d/ -f1)"
        echo "[download_mervlan] tar lists topname: ${topname:-<none>}"
    else
        topname="$(gzip -dc "$tmp/mervlan.tar.gz" 2>/dev/null | tar -t 2>/dev/null | head -1 | cut -d/ -f1)"
        echo "[download_mervlan] gzip|tar lists topname: ${topname:-<none>}"
    fi
    if [ -n "$topname" ] && [ -d "$tmp/$topname" ]; then
        topdir="$tmp/$topname"
    else
        # Prefer directories matching mervlan-* if present
        for d in "$tmp"/mervlan-*; do
            [ -d "$d" ] && { topdir="$d"; break; }
        done
        # Else pick first directory that isn't a known temp subdir like 'logs'
        if [ -z "$topdir" ]; then
            for d in "$tmp"/*; do
                [ -d "$d" ] || continue
                [ "$(basename "$d")" = "logs" ] && continue
                topdir="$d"; break
            done
        fi
    fi
    echo "[download_mervlan] detected topdir (final): ${topdir:-<none>}"

  if [ -n "$topdir" ]; then
        echo "[download_mervlan] copying contents from $topdir -> $MERV_BASE"
        if ! cp -a "$topdir"/. "$MERV_BASE"/ 2>/dev/null; then
            echo "[download_mervlan] cp -a failed; using tar pipe fallback"
      ( cd "$topdir" && tar -cf - . ) | ( cd "$MERV_BASE" && tar -xpf - )
    fi
        echo "[download_mervlan] copy step complete"
  else
    echo "ERROR: Unexpected archive layout (no top directory)" >&2
    return 1
  fi

        # Permissions: BusyBox-safe (no find). 755 for all .sh except the two settings files -> 644
    # First set 644 for settings/log_settings.sh and settings/var_settings.sh if present
        echo "[download_mervlan] adjusting file permissions (.sh)"
    for depth in "" "*/" "*/*/"; do
        for f in $MERV_BASE/${depth}*.sh; do
            [ -f "$f" ] 2>/dev/null || continue
            base="$(basename "$f")"
            if [ "$base" = "log_settings.sh" ] || [ "$base" = "var_settings.sh" ]; then
                chmod 644 "$f" 2>/dev/null || :
            fi
        done
    done

    # Then apply 755 to all other .sh files
    for depth in "" "*/" "*/*/"; do
        for f in $MERV_BASE/${depth}*.sh; do
            [ -f "$f" ] 2>/dev/null || continue
            base="$(basename "$f")"
            if [ "$base" != "log_settings.sh" ] && [ "$base" != "var_settings.sh" ]; then
                chmod 755 "$f" 2>/dev/null || :
            fi
        done
    done
        echo "[download_mervlan] permission step complete"

    # Inject service-event on fresh download so a new install is functional
    if [ -x "$MERV_BASE/functions/mervlan_boot.sh" ]; then
        echo "[download_mervlan] invoking setupenable to inject service-event"
        if MERV_SKIP_NODE_SYNC=1 sh "$MERV_BASE/functions/mervlan_boot.sh" setupenable >/dev/null 2>&1; then
            echo "[download_mervlan] setupenable completed successfully"
        else
            echo "[download_mervlan] WARNING: setupenable failed" >&2
        fi
    else
        echo "[download_mervlan] WARNING: mervlan_boot.sh not executable or missing; skipping setupenable" >&2
    fi

        # Setup HW probe on fresh install
    if [ -x "$MERV_BASE/functions/hw_probe.sh" ]; then
        echo "[download_mervlan] invoking hw_probe to inject settings"
        if sh "$MERV_BASE/functions/hw_probe.sh"; then
            echo "[download_mervlan] hw_probe completed successfully"
        else
            echo "[download_mervlan] WARNING: hw_probe failed" >&2
        fi
    else
        echo "[download_mervlan] WARNING: hw_probe.sh not executable or missing; skipping setupenable" >&2
    fi

  trap - EXIT
    if [ "$created" -eq 1 ]; then
        echo "[download_mervlan] cleaning tmp (manual): $tmp"
        rm -rf "$tmp"
    fi
    echo "[download_mervlan] done"
}




# ========================================================================== #
# DIRECTORY & LOG SETUP — Ensure runtime paths exist with correct perms      #
# ========================================================================== #

# create_dirs — Prepare temp/log/public directories used by web UI & CLI
# Returns: 0 on success, 1 on failure (logs error message)
# Explanation: Creates shared folders for logs, results, and user-facing UI
create_dirs() {
    local d
    for d in \
        "$TMP_DIR" \
        "$TMP_DIR/logs" \
        "$TMP_DIR/locks" \
        "$TMP_DIR"/results \
        "$TMP_DIR"/results/vlan_changes \
        "$TMP_DIR"/results/client_collection \
        "$PUBLIC_DIR" \
        "$PUBLIC_DIR/settings" \
        "$PUBLIC_DIR/.ssh" \
        "$PUBLIC_DIR/tmp/results" \
        "$PUBLIC_DIR/tmp/logs"
    do
        mkdir -p "$d" 2>/dev/null || {
            printf 'ERROR: Failed to create directory: %s\n' "$d" >&2
            return 1
        }
    done
}

# create_dirs_first_install — Build addon skeleton under $MERV_BASE
# Returns: 0 on success, 1 on failure
# Explanation: Used for "full" mode to lay out initial folder hierarchy
create_dirs_first_install() {
    # Create base addon directories inside MERV_BASE on first install
    local base d
    base="${MERV_BASE:-/jffs/addons/mervlan}"
    for d in \
        "$base" \
        "$base/functions" \
        "$base/settings" \
        "$base/flags" \
        "$base/www" \
        "$base/.ssh"
    do
        mkdir -p "$d" 2>/dev/null || {
            printf 'ERROR: Failed to create directory: %s\n' "$d" >&2
            return 1
        }
    done
}

# create_link — Idempotent symlink helper for exposing logs/results via UI
# Args: target, dest; recreates existing symlink if present
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
# create_logs — Initialize log files with safe permissions
# Explanation: Truncates/creates CLI and VLAN manager logs and sets modes
create_logs() {
    : > "$TMP_DIR/logs/cli_output.log"    || { printf 'ERROR: Failed to init cli_output.log\n' >&2; return 1; }
    : > "$TMP_DIR/logs/vlan_manager.log"       || { printf 'ERROR: Failed to init vlan_manager.log\n' >&2; return 1; }

    chmod 755 "$TMP_DIR" "$TMP_DIR/logs"
    chmod 644 "$TMP_DIR/logs/cli_output.log" "$TMP_DIR/logs/vlan_manager.log"
}

# ========================================================================== #
# INSTALL ENTRYPOINT — Support "full" bootstrap mode with download step     #
# ========================================================================== #

# Handle "full" and "credentials" install mode: first-install dirs + fetch latest, then continue
MODE="${1:-}"

# Handle special modes before normal install flow
case "$MODE" in
    credentials)
        # Only configure SSH credentials and exit
        echo "[install] Credentials-only mode: configuring SSH username and port."
        prompt_ssh_user_override
        prompt_ssh_port_override
        echo "[install] Credentials updated. Exiting."
        exit 0
        ;;
    full)
        logger -t "$ADDON" "Full install requested: creating base dirs and downloading package"
        create_dirs_first_install || { logger -t "$ADDON" "ERROR: create_dirs_first_install failed"; exit 1; }
        download_mervlan || { logger -t "$ADDON" "ERROR: download_mervlan failed"; exit 1; }
        ;;
    *)
        # Standard / upgrade install: no special pre-work
        ;;
esac


# ========================================================================== #
# CORE INSTALL FLOW — Validate firmware support and mount addon web page     #
# ========================================================================== #

# 1. Does the firmware support addons?
nvram get rc_support | grep -q am_addons
if [ $? != 0 ]; then
    logger -t "$ADDON" "This firmware does not support addons!"
    exit 5
fi

# 2. Obtain the first available mount point into $am_webui_page
am_get_webui_page "$ADDON_DIR/$ADDON/mervlan.asp"

# Abort installation if router has no free user page slots available
if [ "$am_webui_page" = "none" ]; then
    logger -t "$ADDON" "Unable to install $ADDON (no free user page)"
    exit 5
fi
logger -t "$ADDON" "Mounting $ADDON as $am_webui_page"

# 3. Publish our page to /www/user/<slot>.asp
cp "$ADDON_DIR/$ADDON/mervlan.asp" "/www/user/$am_webui_page"

# ========================================================================== #
# FILE & ASSET PROVISIONING — Prepare runtime directories and static assets  #
# ========================================================================== #

# 3a. Create Project Dirs
# Ensure runtime temp/log directories exist before exposing UI assets
if create_dirs && create_logs; then
    logger -t "$ADDON" "Logs & folder structure complete!"
else
    logger -t "$ADDON" "ERROR: Failed to initialize directories or logs"
    exit 1
fi

# Only ask for SSH credentials during a full install
if [ "$MODE" = "full" ]; then
    prompt_ssh_user_override
    prompt_ssh_port_override
fi

# 3b. Copy Static assets to Public Dir
cp -p "$ADDON_DIR/$ADDON/www/index.html"            "$PUBLIC_DIR/index.html" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/www/vlan_index_style.css"  "$PUBLIC_DIR/vlan_index_style.css" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/www/vlan_form_style.css"   "$PUBLIC_DIR/vlan_form_style.css" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/www/help.html"             "$PUBLIC_DIR/help.html" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/www/view_logs.html"        "$PUBLIC_DIR/view_logs.html" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/settings/settings.json"    "$PUBLIC_DIR/settings/settings.json" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/settings/hw_settings.json" "$PUBLIC_DIR/settings/hw_settings.json" 2>/dev/null

# 3c. Publish SSH public key for UI if it already exists (rename to .json for compatibility)
if [ -f "$ADDON_DIR/$ADDON/.ssh/vlan_manager.pub" ]; then
    # Copy it to a .json filename so fetch('.ssh/vlan_manager.json') returns raw text
    cp -p "$ADDON_DIR/$ADDON/.ssh/vlan_manager.pub" "$PUBLIC_DIR/.ssh/vlan_manager.json" 2>/dev/null || {
        logger -t "$ADDON" "ERROR: Failed to publish SSH key to $PUBLIC_DIR/.ssh/vlan_manager.json"
    }
    chmod 644 "$PUBLIC_DIR/.ssh/vlan_manager.json" 2>/dev/null
    logger -t "$ADDON" "SSH public key published to web UI"
else
    logger -t "$ADDON" "SSH public key not present yet, skipping publish"
fi

# Create and log symlinks
create_link "$TMP_DIR/logs/cli_output.log"              "$PUBLIC_DIR/tmp/logs/cli_output.json"
create_link "$TMP_DIR/logs/vlan_manager.log"            "$PUBLIC_DIR/tmp/logs/vlan_manager.json"
create_link "$TMP_DIR/results/vlan_clients.json"        "$PUBLIC_DIR/tmp/results/vlan_clients.json"

logger -t "$ADDON" "Symlinks created successfully"
echo "$ADDON" "Symlinks created successfully"


# ========================================================================== #
# ASUSWRT UI INTEGRATION — Modify menu tree and persist addon metadata       #
# ========================================================================== #

# 4. Copy menuTree.js (if not already bind-mounted) so we can modify it
if [ ! -f /tmp/menuTree.js ]; then
    cp /www/require/modules/menuTree.js /tmp/
    mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js
fi

# 5. Insert our tab inside the LAN menu
# Clean any previous MerVLAN line so we're idempotent (leave other VLAN tabs intact)
sed -i '/tabName: "MerVLAN"/d' /tmp/menuTree.js

# Append our MerVLAN tab just before the LAN menu's __INHERIT__ sentinel
sed -i "/index: \"menu_LAN\"/,/{url: \"NULL\", tabName: \"__INHERIT__\"}/ {/{url: \"NULL\", tabName: \"__INHERIT__\"}/i \\
{url: \"$am_webui_page\", tabName: \"MerVLAN\"},
}" /tmp/menuTree.js

# 6. Remount after sed (bind+sed quirk)
umount /www/require/modules/menuTree.js
mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js

# 7. Record metadata (optional but good practice)
am_settings_set mervlan_page "$am_webui_page"
am_settings_set mervlan_state "enabled"
am_settings_set mervlan_version "v0.46"

logger -t "$ADDON" "Installed tab 'MerVLAN' under LAN -> $am_webui_page"
echo "$ADDON" "Installed tab 'MerVLAN' under LAN -> $am_webui_page"

# ========================================================================== #
# POST-INSTALL HOOKS — Ensure service scripts reachable and sync nodes       #
# ========================================================================== #

# Ensure boot/service-event hooks are present even on non-full installs
if [ -x "$MERV_BASE/functions/mervlan_boot.sh" ]; then
    if MERV_SKIP_NODE_SYNC=1 sh "$MERV_BASE/functions/mervlan_boot.sh" setupenable >/dev/null 2>&1; then
        logger -t "$ADDON" "addon setupenable completed (post-install)"
    else
        logger -t "$ADDON" "WARNING: setupenable failed during post-install"
    fi
else
    logger -t "$ADDON" "WARNING: mervlan_boot.sh not executable; skipping post-install setupenable"
fi

# If nodes are configured and SSH keys are ready, propagate nodeenable now
if has_configured_nodes && ssh_keys_effectively_installed; then
    if [ -x "$BOOT_SCRIPT" ]; then
        logger -t "$ADDON" "Propagating nodeenable to configured nodes"
        if sh "$BOOT_SCRIPT" nodeenable >/dev/null 2>&1; then
            logger -t "$ADDON" "nodeenable completed successfully"
        else
            logger -t "$ADDON" "WARNING: nodeenable encountered errors"
        fi
    else
        logger -t "$ADDON" "WARNING: mervlan_boot.sh not executable; skipping nodeenable"
    fi
else
    logger -t "$ADDON" "Nodeenable skipped (no nodes configured or SSH keys not installed)"
fi

exit 0