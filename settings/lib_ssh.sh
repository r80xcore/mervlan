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
#                - File: lib_ssh.sh || version="0.47"                          #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Define shared SSH related functions                            #
# ──────────────────────────────────────────────────────────────────────────── #
[ -n "${LIB_SSH_LOADED:-}" ] && return 0 2>/dev/null
# Only set if not already set (allows override for testing)
: "${MERV_BASE:?MERV_BASE must be set before sourcing folder_settings.sh}"
[ -n "${LIB_JSON_LOADED:-}" ] || {
	if [ -f "$MERV_BASE/settings/lib_json.sh" ]; then
		. "$MERV_BASE/settings/lib_json.sh"
	fi
}

prompt_ssh_port_override() {
    # Configure SSH port for node connections, stored in general.json.
    local current_port reply port

    echo ""
    echo "[install] Configure SSH port for node connections."

    # Read current port from general.json; default to 22 if missing/empty
    current_port=$(json_get_flag "NODE_SSH_PORT" "__MISSING__" "$GENERAL_SETTINGS_FILE" 2>/dev/null)
    if [ "$current_port" = "__MISSING__" ] || [ -z "$current_port" ]; then
        current_port=$(json_get_flag "SSH_PORT" "22" "$GENERAL_SETTINGS_FILE" 2>/dev/null)
    fi
    [ -n "$current_port" ] || current_port="22"

    while :; do
        printf '[install] Use SSH port %s? [Y/n]: ' "$current_port"
        IFS= read -r reply || reply=""
        case "$reply" in
            ""|Y|y|YES|yes|Yes)
                echo "[install] Keeping SSH port $current_port."
                # Persist the selection in both new and legacy keys for compatibility
                json_set_flag "NODE_SSH_PORT" "$current_port" "$GENERAL_SETTINGS_FILE" >/dev/null 2>&1
                json_set_flag "SSH_PORT" "$current_port" "$GENERAL_SETTINGS_FILE" >/dev/null 2>&1
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
                        # Write to general.json using central JSON helper
                        if json_set_flag "NODE_SSH_PORT" "$port" "$GENERAL_SETTINGS_FILE" >/dev/null 2>&1; then
                            json_set_flag "SSH_PORT" "$port" "$GENERAL_SETTINGS_FILE" >/dev/null 2>&1
                            echo "[install] SSH port updated to $port in general.json."
                        else
                            echo "[install] Failed to update SSH port in general.json."
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
    # Configure default SSH admin username for node connections, stored in general.json.
    local current_user reply new_user

    echo ""
    echo "[install] Configure default SSH admin username for node connections."

    # Read current username from general.json; default to 'admin' if missing/empty
    current_user=$(json_get_flag "NODE_SSH_USER" "__MISSING__" "$GENERAL_SETTINGS_FILE" 2>/dev/null)
    if [ "$current_user" = "__MISSING__" ] || [ -z "$current_user" ]; then
        current_user=$(json_get_flag "SSH_USER" "admin" "$GENERAL_SETTINGS_FILE" 2>/dev/null)
    fi
    [ -n "$current_user" ] || current_user="admin"

    while :; do
        printf '[install] Use SSH username "%s"? [Y/n]: ' "$current_user"
        IFS= read -r reply || reply=""
        case "$reply" in
            ""|Y|y|YES|yes|Yes)
                echo "[install] Keeping SSH username \"$current_user\"."
                # Persist under both new and legacy keys so callers stay in sync
                json_set_flag "NODE_SSH_USER" "$current_user" "$GENERAL_SETTINGS_FILE" >/dev/null 2>&1
                json_set_flag "SSH_USER" "$current_user" "$GENERAL_SETTINGS_FILE" >/dev/null 2>&1
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

                    if json_set_flag "NODE_SSH_USER" "$new_user" "$GENERAL_SETTINGS_FILE" >/dev/null 2>&1; then
                        json_set_flag "SSH_USER" "$new_user" "$GENERAL_SETTINGS_FILE" >/dev/null 2>&1
                        echo "[install] SSH username updated to \"$new_user\" in general.json."
                    else
                        echo "[install] Failed to update SSH username in general.json."
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
    user=$(json_get_flag "NODE_SSH_USER" "__MISSING__" "$GENERAL_SETTINGS_FILE" 2>/dev/null)
    if [ "$user" = "__MISSING__" ] || [ -z "$user" ]; then
        # Fall back to SSH_USER
        user=$(json_get_flag "SSH_USER" "__MISSING__" "$GENERAL_SETTINGS_FILE" 2>/dev/null)
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

    # If no valid env override, read from general.json (new key preferred)
    if [ -z "$port" ]; then
        port=$(json_get_flag "NODE_SSH_PORT" "__MISSING__" "$GENERAL_SETTINGS_FILE" 2>/dev/null)
        if [ "$port" = "__MISSING__" ] || [ -z "$port" ]; then
            port=$(json_get_flag "SSH_PORT" "22" "$GENERAL_SETTINGS_FILE" 2>/dev/null)
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
        flag=$(json_get_flag "SSH_KEYS_INSTALLED" "0" "$GENERAL_SETTINGS_FILE" 2>/dev/null)

        # Detect presence by using a special sentinel
        if [ "$(json_get_flag "SSH_KEYS_INSTALLED" "__MISSING__" "$GENERAL_SETTINGS_FILE" 2>/dev/null)" != "__MISSING__" ]; then
            flag_present="1"
        fi
    elif [ -f "${GENERAL_SETTINGS_FILE:-}" ]; then
        # Legacy grep-only fallback
        if grep -q '"SSH_KEYS_INSTALLED"[[:space:]]*:[[:space:]]*"1"' "$GENERAL_SETTINGS_FILE" 2>/dev/null; then
            flag="1"
        fi
        if grep -q '"SSH_KEYS_INSTALLED"' "$GENERAL_SETTINGS_FILE" 2>/dev/null; then
            flag_present="1"
        fi
    fi

    # If flag key is missing entirely, sync it to whatever we think it currently is
    if [ "$flag_present" = "0" ] && [ -n "${GENERAL_SETTINGS_FILE:-}" ] && command -v json_set_flag >/dev/null 2>&1; then
        _sync_ssh_flag "$flag"
        flag=$(json_get_flag "SSH_KEYS_INSTALLED" "0" "$GENERAL_SETTINGS_FILE" 2>/dev/null)
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

# Flag: settings loaded
LIB_SSH_LOADED=1