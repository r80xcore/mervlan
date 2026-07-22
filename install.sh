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
#                    - File: install.sh || version="0.59"                      #
# ============================================================================ #
# - Purpose:    Enable the MerVLAN addon and set up necessary files            #
#                                                                              #
# ============================================================================ #

source /usr/sbin/helper.sh

# ---- merv: portable `command -v` replacement ----
if ! type merv_has >/dev/null 2>&1; then
  merv_has() { type "$1" >/dev/null 2>&1; }
  merv_cmd() {
    _merv_c="$1"
    case "$_merv_c" in
      */*) [ -x "$_merv_c" ] && { printf '%s\n' "$_merv_c"; return 0; } ;;
    esac
    _merv_oldIFS="$IFS"; IFS=:
    for _merv_d in $PATH; do
      [ -z "$_merv_d" ] && _merv_d="."
      [ -x "$_merv_d/$_merv_c" ] && { IFS="$_merv_oldIFS"; printf '%s\n' "$_merv_d/$_merv_c"; return 0; }
    done
    IFS="$_merv_oldIFS"
    return 1
  }
fi
# ---- end shim ----

# ========================================================================== #
# CONFIGURATION PATHS & CONSTANTS — Source locations and workspace defaults  #
# ========================================================================== #

# GITHUB_URL — Tarball endpoint for fetching latest MerVLAN release snapshot
# ADDON_DIR/ADDON/MERV_BASE — Install root beneath /jffs/addons
# PUBLIC_DIR — Files exposed to web UI for SPA assets and JSON data
# TMP_DIR/TMP — Workspace for transient downloads and log files
# SETTINGS_FILE — JSON configs used during install
# BOOT_SCRIPT — Helper used for setupenable/nodeenable orchestration

# Capture the caller-owned staging directory before selecting the runtime
# profile. download/tarball mode intentionally retain this historical contract.
INSTALL_STAGING_DIR="${TMP_DIR:-}"

MODE=""
BRANCH="main"
LEGACY_DEV_ARG=0
TEST_RUN=0
TEST_WEBUI=0
INTERACTIVE_INSTALL=0
INSTALL_POLICY="fresh"
INSTALL_STATE="absent"
INSTALL_CANCELLED=0

parse_install_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            full|download|tarball|credentials|reinstall)
                if [ -n "$MODE" ] && [ "$MODE" != "$arg" ]; then
                    echo "[install] ERROR: Conflicting modes: $MODE and $arg" >&2
                    return 2
                fi
                MODE="$arg"
                ;;
            dev)
                # Deprecated but retained: install.sh full dev
                BRANCH="dev"
                LEGACY_DEV_ARG=1
                ;;
            --test-run|--dry-run|-dryrun)
                TEST_RUN=1
                ;;
            "") : ;;
            *)
                # Preserve the old no-mode behavior for a lone unknown first
                # argument, but reject extra flags in the interactive installer.
                if [ -z "$MODE" ] && [ "$TEST_RUN" = "0" ]; then
                    MODE="$arg"
                else
                    echo "[install] ERROR: Unknown argument: $arg" >&2
                    return 2
                fi
                ;;
        esac
    done

    [ -n "$MODE" ] || MODE=""
    if [ "$TEST_RUN" = "1" ] && [ "$MODE" != "full" ]; then
        echo "[install] ERROR: --test-run is valid only with 'full'" >&2
        return 2
    fi
    [ "$MODE" = "full" ] && INTERACTIVE_INSTALL=1
    return 0
}

parse_install_args "$@" || exit $?

ADDON_DIR="/jffs/addons"
ACTIVE_ADDON="mervlan"
ACTIVE_MERV_BASE="$ADDON_DIR/$ACTIVE_ADDON"

if [ "$TEST_RUN" = "1" ]; then
    ADDON="mervlan-test-run"
    MERV_BASE="$ADDON_DIR/$ADDON"
    TMP_DIR="/tmp/mervlan_tmp/test-run"
    PUBLIC_DIR="/www/user/mervlan-test-run"
else
    ADDON="$ACTIVE_ADDON"
    MERV_BASE="$ACTIVE_MERV_BASE"
    TMP_DIR="${MERVLAN_RUNTIME_TMP_OVERRIDE:-/tmp/mervlan_tmp}"
    PUBLIC_DIR="/www/user/mervlan"
fi

SOURCE_REF="refs/heads/${BRANCH}"
SOURCE_DESCRIPTION="$BRANCH branch"
GITHUB_URL="https://codeload.github.com/r80xcore/mervlan/tar.gz/${SOURCE_REF}"
TMP="$TMP_DIR"
SETTINGS_FILE="$MERV_BASE/settings/settings.json"
BOOT_SCRIPT="$MERV_BASE/functions/mervlan_boot.sh"
SSH_KEY="$MERV_BASE/.ssh/vlan_manager"
SSH_PUBKEY="$MERV_BASE/.ssh/vlan_manager.pub"

INSTALL_PRESERVE_DIR=""
INSTALL_ROLLBACK_DIR=""
INSTALL_ROLLBACK_NEEDED=0
INSTALL_FINISHED=0
TEST_MENU_TREE_CREATED=0
TEST_MENU_ENTRY_ADDED=0
TEST_WEBUI_PAGE=""
TEST_VALIDATION_FAILED=0
ACTIVE_SETTINGS_DIGEST=""
ACTIVE_MENU_SNAPSHOT=""
ACTIVE_METADATA_SNAPSHOT=""

RESULT_SOURCE="SKIPPED"
RESULT_DOWNLOAD="SKIPPED"
RESULT_ARCHIVE="SKIPPED"
RESULT_EXISTING="SKIPPED"
RESULT_SETTINGS="SKIPPED"
RESULT_FILES="SKIPPED"
RESULT_HARDWARE="SKIPPED"
RESULT_HOOKS="SKIPPED"
RESULT_NODES="SKIPPED"
RESULT_WEBUI="SKIPPED"
RESULT_MENU="SKIPPED"
RESULT_ACTIVE="SKIPPED"
RESULT_CLEANUP="SKIPPED"
RESULT_VERIFY="SKIPPED"
RESULT_DETAIL=""
INSTALL_DIAGNOSTIC_LOG="/tmp/mervlan-installer-last.log"
INSTALL_CURRENT_PHASE="not started"
INSTALL_PHASE_STARTED="0"
INSTALL_HAS_WARNINGS=0

installer_timestamp() {
    date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "unknown-time"
}

installer_record() {
    local level="$1"
    shift
    [ "$MODE" = "full" ] || return 0
    [ -n "$INSTALL_DIAGNOSTIC_LOG" ] || return 0
    printf '%s [%s] %s\n' "$(installer_timestamp)" "$level" "$*" >> "$INSTALL_DIAGNOSTIC_LOG" 2>/dev/null || :
}

installer_log_init() {
    if ! : > "$INSTALL_DIAGNOSTIC_LOG" 2>/dev/null; then
        echo "[install] WARNING: Could not create the installer diagnostic log." >&2
        INSTALL_DIAGNOSTIC_LOG=""
        return 0
    fi
    chmod 600 "$INSTALL_DIAGNOSTIC_LOG" 2>/dev/null || :
    installer_record INFO "Installer started (mode=$MODE test_run=$TEST_RUN)"
}

installer_phase_begin() {
    INSTALL_CURRENT_PHASE="$*"
    INSTALL_PHASE_STARTED="$(date '+%s' 2>/dev/null || printf '0')"
    echo "[install] Phase: $INSTALL_CURRENT_PHASE"
    installer_record INFO "Phase started: $INSTALL_CURRENT_PHASE"
}

installer_phase_end() {
    local ended elapsed
    ended="$(date '+%s' 2>/dev/null || printf '0')"
    elapsed=""
    case "$INSTALL_PHASE_STARTED:$ended" in
        *[!0-9:]*|0:*|*:0) : ;;
        *) elapsed=" in $((ended - INSTALL_PHASE_STARTED))s" ;;
    esac
    echo "[install] Phase complete: $INSTALL_CURRENT_PHASE$elapsed"
    installer_record INFO "Phase completed: $INSTALL_CURRENT_PHASE$elapsed"
    INSTALL_PHASE_STARTED=0
}

installer_warning() {
    INSTALL_HAS_WARNINGS=1
    echo "[install] WARNING: $*" >&2
    installer_record WARNING "$*"
}

print_install_report() {
    local overall="SUCCESS"
    [ "$1" = "0" ] || overall="FAILED"
    [ "$1" = "0" ] && [ "$INSTALL_HAS_WARNINGS" = "1" ] && overall="SUCCESS WITH WARNINGS"
    echo ""
    if [ "$TEST_RUN" = "1" ]; then
        echo "MerVLAN full installer test completed"
    else
        echo "MerVLAN installation completed"
    fi
    echo ""
    printf '  %-24s %s\n' "Source resolution:" "$RESULT_SOURCE"
    printf '  %-24s %s\n' "Archive download:" "$RESULT_DOWNLOAD"
    printf '  %-24s %s\n' "Archive validation:" "$RESULT_ARCHIVE"
    printf '  %-24s %s\n' "Existing installation:" "$RESULT_EXISTING"
    printf '  %-24s %s\n' "Settings migration:" "$RESULT_SETTINGS"
    printf '  %-24s %s\n' "File installation:" "$RESULT_FILES"
    printf '  %-24s %s\n' "Hardware detection:" "$RESULT_HARDWARE"
    printf '  %-24s %s\n' "Service hooks:" "$RESULT_HOOKS"
    printf '  %-24s %s\n' "Node propagation:" "$RESULT_NODES"
    printf '  %-24s %s\n' "Web UI publication:" "$RESULT_WEBUI"
    printf '  %-24s %s\n' "LAN menu registration:" "$RESULT_MENU"
    [ "$TEST_RUN" = "1" ] && printf '  %-24s %s\n' "Active installation:" "$RESULT_ACTIVE"
    [ "$TEST_RUN" = "1" ] && printf '  %-24s %s\n' "Test cleanup:" "$RESULT_CLEANUP"
    printf '  %-24s %s\n' "Final verification:" "$RESULT_VERIFY"
    [ -n "$RESULT_DETAIL" ] && printf '\n  Details: %s\n' "$RESULT_DETAIL"
    [ "$MODE" = "full" ] && [ -n "$INSTALL_DIAGNOSTIC_LOG" ] && \
        printf '  %-24s %s\n' "Diagnostic log:" "$INSTALL_DIAGNOSTIC_LOG"
    echo ""
    echo "Overall result: $overall"
    installer_record INFO "Overall result: $overall"
}

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

	if merv_has json_set_flag; then
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

    if merv_has json_get_flag; then
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
    if [ "$flag_present" = "0" ] && [ -n "${SETTINGS_FILE:-}" ] && merv_has json_set_flag; then
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

# has_configured_nodes — Report if any NODE1..NODE10 entries contain IPs
# Returns: 0 when at least one valid IPv4 is present, 1 otherwise
# Explanation: Allows installer to decide whether to call nodeenable later
has_configured_nodes() {
    [ -f "$SETTINGS_FILE" ] || return 1
    local _MERV_MAX_NODES_LOCAL=10
    grep -o '"NODE[0-9][0-9]*"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" 2>/dev/null | \
        sed -n 's/.*"NODE\([0-9][0-9]*\)"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1 \2/p' | \
        awk -v max="$_MERV_MAX_NODES_LOCAL" \
          '$2!="none" && $2~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $1>=1 && $1<=max {found=1} END{exit !found}'
}

count_configured_nodes() {
    local _MERV_MAX_NODES_LOCAL=10
    grep -o '"NODE[0-9][0-9]*"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" 2>/dev/null | \
        sed -n 's/.*"NODE\([0-9][0-9]*\)"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1 \2/p' | \
        awk -v max="$_MERV_MAX_NODES_LOCAL" \
          '$2!="none" && $2~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $1>=1 && $1<=max {c++} END{print c+0}'
}

# ========================================================================== #
# INTERACTIVE FULL-INSTALL CONTROLLER                                        #
# ========================================================================== #

prompt_yes_no() {
    local prompt="$1" default_answer="${2:-n}" answer
    while :; do
        [ "$default_answer" = "y" ] && printf '%s [Y/n]: ' "$prompt" || printf '%s [y/N]: ' "$prompt"
        IFS= read -r answer || answer=""
        case "$answer" in
            Y|y|YES|yes|Yes) return 0 ;;
            N|n|NO|no|No) return 1 ;;
            "") [ "$default_answer" = "y" ] && return 0 || return 1 ;;
            *) echo "[install] Please answer Y or N." ;;
        esac
    done
}

settings_file_looks_valid() {
    local file="$1" opens closes
    [ -s "$file" ] || return 1
    grep -q '"General"[[:space:]]*:' "$file" 2>/dev/null || return 1
    grep -q '"SSH"[[:space:]]*:' "$file" 2>/dev/null || return 1
    grep -q '"Nodes"[[:space:]]*:' "$file" 2>/dev/null || return 1
    grep -q '"SSH_USER"[[:space:]]*:' "$file" 2>/dev/null || return 1
    grep -q '"SSH_PORT"[[:space:]]*:' "$file" 2>/dev/null || return 1
    opens=$(tr -cd '{' < "$file" 2>/dev/null | wc -c | tr -d ' ')
    closes=$(tr -cd '}' < "$file" 2>/dev/null | wc -c | tr -d ' ')
    [ -n "$opens" ] && [ "$opens" = "$closes" ]
}

detect_existing_installation() {
    local required marker
    INSTALL_STATE="absent"
    if settings_file_looks_valid "$ACTIVE_MERV_BASE/settings/settings.json"; then
        for required in install.sh uninstall.sh mervlan.asp www/index.html settings/lib_json.sh; do
            [ -f "$ACTIVE_MERV_BASE/$required" ] || { INSTALL_STATE="partial"; return 0; }
        done
        INSTALL_STATE="valid"
        return 0
    fi
    # A directory containing only the freshly downloaded install.sh is a
    # bootstrap, not a damaged installation.
    for marker in uninstall.sh mervlan.asp changelog.txt settings/settings.json functions www tmp .ssh; do
        [ -e "$ACTIVE_MERV_BASE/$marker" ] && { INSTALL_STATE="partial"; return 0; }
    done
}

digest_active_user_files() {
    local rel file digest=""
    for rel in settings/settings.json tmp/mac_shield.db tmp/mac_shield_override.db \
        tmp/client_name_override.db .ssh/vlan_manager .ssh/vlan_manager.pub
    do
        file="$ACTIVE_MERV_BASE/$rel"
        if [ -f "$file" ]; then
            if merv_has md5sum; then
                digest="$digest$rel:$(md5sum "$file" 2>/dev/null | awk '{print $1}');"
            else
                digest="$digest$rel:$(cksum "$file" 2>/dev/null | awk '{print $1 ":" $2}');"
            fi
        else
            digest="$digest$rel:absent;"
        fi
    done
    for file in /jffs/scripts/service-event /jffs/scripts/services-start; do
        if [ -f "$file" ]; then
            if merv_has md5sum; then
                digest="$digest$file:$(md5sum "$file" 2>/dev/null | awk '{print $1}');"
            else
                digest="$digest$file:$(cksum "$file" 2>/dev/null | awk '{print $1 ":" $2}');"
            fi
        else
            digest="$digest$file:absent;"
        fi
    done
    printf '%s\n' "$digest"
}

digest_menu_tree() {
    local file="/www/require/modules/menuTree.js"
    if [ ! -f "$file" ]; then
        printf '%s\n' "absent"
    elif merv_has md5sum; then
        md5sum "$file" 2>/dev/null | awk '{print $1}'
    else
        cksum "$file" 2>/dev/null | awk '{print $1 ":" $2}'
    fi
}

select_install_source() {
    local choice default_choice=1
    [ "$BRANCH" = "dev" ] && default_choice=2
    echo ""
    echo "Select the MerVLAN source:"
    echo "  1) Latest stable release (recommended)"
    echo "  2) Development branch"
    while :; do
        printf 'Enter choice [1-2, default %s]: ' "$default_choice"
        IFS= read -r choice || choice=""
        [ -n "$choice" ] || choice="$default_choice"
        case "$choice" in
            1) BRANCH="main"; SOURCE_DESCRIPTION="latest stable release"; return 0 ;;
            2) BRANCH="dev"; SOURCE_DESCRIPTION="development branch"; return 0 ;;
            *) echo "[install] Invalid choice. Please enter 1 or 2." ;;
        esac
    done
}

select_existing_policy() {
    local choice
    if [ "$TEST_RUN" = "1" ]; then
        case "$INSTALL_STATE" in
            valid)
                INSTALL_POLICY="preserve"
                echo "[install] Active installation detected. Its user data will be copied"
                echo "[install] into the isolated test tree to exercise settings migration."
                ;;
            partial)
                INSTALL_POLICY="preserve"
                echo "[install] A partial active installation was detected. Recoverable user"
                echo "[install] data will be tested without changing the active files."
                ;;
            *) INSTALL_POLICY="fresh" ;;
        esac
        return 0
    fi
    case "$INSTALL_STATE" in
        valid)
            echo ""
            echo "An existing MerVLAN installation was detected."
            echo "  1) Preserve configuration and reinstall (recommended)"
            echo "  2) Perform a clean installation"
            echo "  3) Cancel"
            ;;
        partial)
            echo ""
            echo "An incomplete or damaged MerVLAN installation was detected."
            echo "  1) Preserve recoverable data and reinstall (recommended)"
            echo "  2) Remove it and perform a clean installation"
            echo "  3) Cancel"
            ;;
        *) INSTALL_POLICY="fresh"; return 0 ;;
    esac
    while :; do
        printf 'Enter choice [1-3]: '
        IFS= read -r choice || choice=""
        case "$choice" in
            1) INSTALL_POLICY="preserve"; return 0 ;;
            2)
                echo "WARNING: A clean installation discards existing settings, SSH keys,"
                echo "and stored client databases after the new package validates."
                if prompt_yes_no "Continue with a clean installation?" n; then INSTALL_POLICY="clean"; return 0; fi
                ;;
            3) INSTALL_CANCELLED=1; return 1 ;;
            *) echo "[install] Invalid choice. Please enter 1, 2, or 3." ;;
        esac
    done
}

collect_interactive_settings() {
    local source_settings="$ACTIVE_MERV_BASE/settings/settings.json" answer
    INSTALL_SSH_USER="admin"
    INSTALL_SSH_PORT="22"
    if [ "$INSTALL_POLICY" = "preserve" ] && settings_file_looks_valid "$source_settings"; then
        INSTALL_SSH_USER=$(json_get_flag "NODE_SSH_USER" "admin" "$source_settings" 2>/dev/null)
        INSTALL_SSH_PORT=$(json_get_flag "NODE_SSH_PORT" "22" "$source_settings" 2>/dev/null)
    fi
    [ -n "$INSTALL_SSH_USER" ] || INSTALL_SSH_USER="admin"
    case "$INSTALL_SSH_PORT" in ""|*[!0-9]*) INSTALL_SSH_PORT="22" ;; esac
    echo ""
    echo "Connection settings"
    while :; do
        printf '  SSH username [%s]: ' "$INSTALL_SSH_USER"
        IFS= read -r answer || answer=""
        [ -n "$answer" ] || answer="$INSTALL_SSH_USER"
        case "$answer" in *[\"\ ]*|"") echo "[install] Use a non-empty username without spaces or quotes." ;; *) INSTALL_SSH_USER="$answer"; break ;; esac
    done
    while :; do
        printf '  SSH port [%s]: ' "$INSTALL_SSH_PORT"
        IFS= read -r answer || answer=""
        [ -n "$answer" ] || answer="$INSTALL_SSH_PORT"
        case "$answer" in ""|*[!0-9]*) echo "[install] Enter a numeric port from 1 to 65535."; continue ;; esac
        if [ "$answer" -ge 1 ] 2>/dev/null && [ "$answer" -le 65535 ] 2>/dev/null; then INSTALL_SSH_PORT="$answer"; break; fi
        echo "[install] Enter a numeric port from 1 to 65535."
    done
    if [ "$TEST_RUN" = "1" ] && prompt_yes_no "Temporarily test Web UI and LAN menu integration?" n; then TEST_WEBUI=1; fi
}

confirm_install_summary() {
    echo ""
    echo "Installation summary"
    [ "$TEST_RUN" = "1" ] && echo "  Mode:          TEST RUN (active installation remains unchanged)" || echo "  Mode:          Full installation"
    echo "  Source:        $SOURCE_DESCRIPTION"
    echo "  Existing data: $INSTALL_POLICY"
    echo "  SSH user:      $INSTALL_SSH_USER"
    echo "  SSH port:      $INSTALL_SSH_PORT"
    echo "  Addon path:    $MERV_BASE"
    echo "  Runtime path:  $TMP_DIR"
    if [ "$TEST_RUN" = "1" ]; then
        [ "$TEST_WEBUI" = "1" ] && echo "  Web UI test:   enabled" || echo "  Web UI test:   disabled"
        echo "  Hooks/nodes:   safety-skipped"
        echo "  Cleanup:       automatic"
    else
        echo "  Web UI:        enabled"
    fi
    echo ""
    prompt_yes_no "Begin installation?" y
}

run_full_install_wizard() {
    echo ""
    echo "============================================================"
    echo "              Welcome to the MerVLAN installer"
    echo "============================================================"
    [ "$TEST_RUN" = "1" ] && echo "TEST RUN: the active addon, settings, hooks, and nodes will not be changed."
    detect_existing_installation
    select_install_source || return 1
    select_existing_policy || return 1
    collect_interactive_settings || return 1
    confirm_install_summary
}

latest_stable_tag_from_file() {
    # Read one candidate tag per line and return the highest stable vX.Y.Z tag.
    # Numeric comparison avoids relying on GNU sort -V, which BusyBox may lack.
    awk '
        $0 ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ {
            tag=$0
            split(substr(tag, 2), part, ".")
            if (!found || part[1]+0 > major ||
                (part[1]+0 == major && part[2]+0 > minor) ||
                (part[1]+0 == major && part[2]+0 == minor && part[3]+0 > patch)) {
                found=1
                major=part[1]+0
                minor=part[2]+0
                patch=part[3]+0
                best=tag
            }
        }
        END { if (found) print best }
    ' "$1" 2>/dev/null
}

stable_tag_is_valid() {
    printf '%s\n' "$1" | awk '$0 ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ { ok=1 } END { exit(ok ? 0 : 1) }'
}

resolve_download_source() {
    local curl_bin release_file tags_file candidates_file tag release_tag
    if [ "$BRANCH" = "dev" ]; then
        SOURCE_REF="refs/heads/dev"
        SOURCE_DESCRIPTION="development branch"
        GITHUB_URL="https://codeload.github.com/r80xcore/mervlan/tar.gz/$SOURCE_REF"
        RESULT_SOURCE="PASS - dev branch"
        return 0
    fi
    curl_bin="$(merv_cmd /usr/sbin/curl 2>/dev/null || merv_cmd curl 2>/dev/null)"
    release_file="$TMP_DIR/latest-release.$$"
    tags_file="$TMP_DIR/latest-tags.$$"
    candidates_file="$TMP_DIR/stable-tags.$$"
    mkdir -p "$TMP_DIR" 2>/dev/null || return 1
    : > "$candidates_file" || return 1
    tag=""

    echo "[install] Resolving the latest published GitHub release"
    if [ -n "$curl_bin" ] && "$curl_bin" -fsL --retry 2 --connect-timeout 15 --max-time 60 \
        "https://api.github.com/repos/r80xcore/mervlan/releases/latest" -o "$release_file" 2>/dev/null; then
        release_tag=$(tr '{},' '\n\n\n' < "$release_file" 2>/dev/null | \
            sed -n 's/^[[:space:]]*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        if stable_tag_is_valid "$release_tag"; then
            tag="$release_tag"
            SOURCE_DESCRIPTION="stable release $tag"
            RESULT_SOURCE="PASS - latest GitHub release $tag"
        fi
    fi

    if [ -z "$tag" ]; then
        echo "[install] No published release found; checking stable version tags"
        if [ -n "$curl_bin" ] && "$curl_bin" -fsL --retry 2 --connect-timeout 15 --max-time 60 \
            "https://api.github.com/repos/r80xcore/mervlan/tags?per_page=100" -o "$tags_file" 2>/dev/null; then
            tr '{},' '\n\n\n' < "$tags_file" 2>/dev/null | \
                sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' > "$candidates_file"
        elif [ -n "$curl_bin" ] && "$curl_bin" -fsL --retry 2 --connect-timeout 15 --max-time 60 \
            "https://github.com/r80xcore/mervlan/tags.atom" -o "$tags_file" 2>/dev/null; then
            sed -n 's@.*<title>\(v[0-9][^<]*\)</title>.*@\1@p' "$tags_file" > "$candidates_file"
        fi
        tag=$(latest_stable_tag_from_file "$candidates_file")
        if [ -n "$tag" ]; then
            SOURCE_DESCRIPTION="stable tag $tag"
            RESULT_SOURCE="PASS - latest stable tag $tag"
        fi
    fi

    rm -f "$release_file" "$tags_file" "$candidates_file" 2>/dev/null || :
    if [ -n "$tag" ]; then
        SOURCE_REF="refs/tags/$tag"
        GITHUB_URL="https://codeload.github.com/r80xcore/mervlan/tar.gz/$SOURCE_REF"
    else
        SOURCE_REF="refs/heads/main"
        SOURCE_DESCRIPTION="main branch fallback"
        GITHUB_URL="https://codeload.github.com/r80xcore/mervlan/tar.gz/$SOURCE_REF"
        RESULT_SOURCE="WARN - main fallback (release and tag lookup unavailable)"
        installer_warning "No GitHub release or stable version tag could be resolved; using main branch fallback."
    fi
}

prepare_preserved_files() {
    local rel src dest
    [ "$INSTALL_POLICY" = "preserve" ] || { RESULT_EXISTING="PASS - clean/fresh policy"; return 0; }
    INSTALL_PRESERVE_DIR="$TMP_DIR/install-preserve.$$"
    mkdir -p "$INSTALL_PRESERVE_DIR" 2>/dev/null || return 1
    for rel in settings/settings.json tmp/mac_shield.db tmp/mac_shield_override.db \
        tmp/client_name_override.db .ssh/vlan_manager .ssh/vlan_manager.pub
    do
        src="$ACTIVE_MERV_BASE/$rel"
        dest="$INSTALL_PRESERVE_DIR/$rel"
        if [ -f "$src" ]; then
            mkdir -p "$(dirname "$dest")" 2>/dev/null || return 1
            cp -p "$src" "$dest" 2>/dev/null || return 1
        fi
    done
    if [ "$INSTALL_STATE" = "valid" ] && [ ! -f "$INSTALL_PRESERVE_DIR/settings/settings.json" ]; then return 1; fi
    RESULT_EXISTING="PASS - user data preserved"
}

cleanup_preserved_files() {
    [ -n "$INSTALL_PRESERVE_DIR" ] || return 0
    case "$INSTALL_PRESERVE_DIR" in
        "$TMP_DIR"/install-preserve.[0-9]*) rm -rf "$INSTALL_PRESERVE_DIR" 2>/dev/null || return 1 ;;
        *) return 1 ;;
    esac
    INSTALL_PRESERVE_DIR=""
}

prepare_install_target() {
    if [ "$TEST_RUN" = "1" ]; then
        case "$MERV_BASE" in
            /jffs/addons/mervlan-test-run) rm -rf "$MERV_BASE" 2>/dev/null || return 1 ;;
            *) echo "[install] ERROR: Refusing unsafe test target: $MERV_BASE" >&2; return 1 ;;
        esac
        return 0
    fi
    if [ -d "$MERV_BASE" ]; then
        INSTALL_ROLLBACK_DIR="$ADDON_DIR/.mervlan-install-rollback.$$"
        [ ! -e "$INSTALL_ROLLBACK_DIR" ] || return 1
        mv "$MERV_BASE" "$INSTALL_ROLLBACK_DIR" 2>/dev/null || return 1
        INSTALL_ROLLBACK_NEEDED=1
    fi
}

merge_preserved_settings() {
    local old_file="$1" new_file="$2" kv_file merged_file count_file extracted merged
    [ -f "$old_file" ] || return 0
    [ -f "$new_file" ] || return 1
    kv_file="$TMP_DIR/settings-merge.$$"
    merged_file="$TMP_DIR/settings-merged.$$"
    count_file="$TMP_DIR/settings-merged-count.$$"
    : > "$kv_file" || return 1
    awk -v out="$kv_file" '
        function braces(s,t,o,c){t=s;o=gsub(/\{/,"",t);c=gsub(/\}/,"",t);return o-c}
        function pname(s,t){t=s;sub(/^[[:space:]]*"/,"",t);sub(/".*$/,"",t);return t}
        BEGIN{depth=-1;sec="";subsec="";secdepth=0;subdepth=0;inhw=0;hwdepth=0}
        {
            line=$0
            if(depth==0 && line ~ /^[[:space:]]*"[^"]+"[[:space:]]*:[[:space:]]*\{/){sec=pname(line);secdepth=depth+braces(line);inhw=(sec=="Hardware");hwdepth=secdepth;subsec=""}
            if(!inhw && sec!="" && depth==1 && line ~ /^[[:space:]]*"[^"]+"[[:space:]]*:[[:space:]]*\{/){subsec=pname(line);subdepth=depth+braces(line)}
            if(!inhw && sec!="" && line ~ /^[[:space:]]*"[^"]+"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,?[[:space:]]*$/){
                k=pname(line);v=line;sub(/^[^:]*:[[:space:]]*"/,"",v);sub(/"[[:space:]]*,?[[:space:]]*$/,"",v)
                if(k !~ /^_/ && k !~ /^BACKUP_[123]$/){if(depth==1)printf "%s|%s|%s|%s\n",sec,"",k,v >> out;else if(subsec!="")printf "%s|%s|%s|%s\n",sec,subsec,k,v >> out}
            }
            depth+=braces(line)
            if(inhw && depth<hwdepth){inhw=0;sec="";subsec=""}
            if(subsec!="" && depth<subdepth)subsec=""
            if(sec!="" && depth<secdepth){sec="";subsec=""}
        }
    ' "$old_file" || { rm -f "$kv_file"; return 1; }

    extracted=$(wc -l < "$kv_file" 2>/dev/null | tr -d '[:space:]')
    [ -n "$extracted" ] || extracted=0
    echo "[install] Settings migration: merging $extracted preserved values in one pass"
    installer_record INFO "Settings migration extracted $extracted preserved scalar values"
    if [ "$extracted" = "0" ]; then
        rm -f "$kv_file" "$merged_file" "$count_file" 2>/dev/null || :
        installer_warning "No compatible scalar settings were found in the preserved settings file."
        return 0
    fi

    if ! awk -F '|' -v count_out="$count_file" '
        function braces(s,t,o,c){t=s;o=gsub(/\{/,"",t);c=gsub(/\}/,"",t);return o-c}
        function pname(s,t){t=s;sub(/^[[:space:]]*"/,"",t);sub(/".*$/,"",t);return t}
        NR==FNR {
            if (NF >= 4) {
                path=$1 SUBSEP $2 SUBSEP $3
                value=substr($0, length($1)+length($2)+length($3)+4)
                saved[path]=value
            }
            next
        }
        FNR==1 {depth=-1;sec="";subsec="";secdepth=0;subdepth=0;inhw=0;hwdepth=0;merged=0}
        {
            line=$0
            if(depth==0 && line ~ /^[[:space:]]*"[^"]+"[[:space:]]*:[[:space:]]*\{/){sec=pname(line);secdepth=depth+braces(line);inhw=(sec=="Hardware");hwdepth=secdepth;subsec=""}
            if(!inhw && sec!="" && depth==1 && line ~ /^[[:space:]]*"[^"]+"[[:space:]]*:[[:space:]]*\{/){subsec=pname(line);subdepth=depth+braces(line)}
            if(!inhw && sec!="" && line ~ /^[[:space:]]*"[^"]+"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,?[[:space:]]*$/){
                k=pname(line);path=""
                if(k !~ /^_/ && k !~ /^BACKUP_[123]$/){if(depth==1)path=sec SUBSEP "" SUBSEP k;else if(subsec!="")path=sec SUBSEP subsec SUBSEP k}
                if(path!="" && path in saved){
                    match(line,/^[[:space:]]*"[^"]+"[[:space:]]*:[[:space:]]*"/)
                    comma=(line ~ /,[[:space:]]*$/ ? "," : "")
                    line=substr(line,1,RLENGTH) saved[path] "\"" comma
                    merged++
                }
            }
            print line
            depth+=braces($0)
            if(inhw && depth<hwdepth){inhw=0;sec="";subsec=""}
            if(subsec!="" && depth<subdepth)subsec=""
            if(sec!="" && depth<secdepth){sec="";subsec=""}
        }
        END { print merged+0 > count_out }
    ' "$kv_file" "$new_file" > "$merged_file"; then
        rm -f "$kv_file" "$merged_file" "$count_file" 2>/dev/null || :
        return 1
    fi

    merged=$(tr -d '[:space:]' < "$count_file" 2>/dev/null)
    [ -n "$merged" ] || merged=0
    if [ "$extracted" != "0" ] && [ "$merged" = "0" ]; then
        rm -f "$kv_file" "$merged_file" "$count_file" 2>/dev/null || :
        return 1
    fi
    mv "$merged_file" "$new_file" 2>/dev/null || {
        rm -f "$kv_file" "$merged_file" "$count_file" 2>/dev/null || :
        return 1
    }
    chmod 644 "$new_file" 2>/dev/null || :
    rm -f "$kv_file" "$count_file" 2>/dev/null || :
    echo "[install] Settings migration: merged $merged preserved values"
    installer_record INFO "Settings migration merged $merged preserved scalar values"
}

restore_preserved_files() {
    local rel src dest
    if [ "$INSTALL_POLICY" = "preserve" ]; then
        if ! merge_preserved_settings "$INSTALL_PRESERVE_DIR/settings/settings.json" "$SETTINGS_FILE"; then
            RESULT_SETTINGS="FAIL - settings merge"
            return 1
        fi
        for rel in tmp/mac_shield.db tmp/mac_shield_override.db tmp/client_name_override.db .ssh/vlan_manager .ssh/vlan_manager.pub; do
            src="$INSTALL_PRESERVE_DIR/$rel"
            dest="$MERV_BASE/$rel"
            [ -f "$src" ] || continue
            mkdir -p "$(dirname "$dest")" 2>/dev/null || return 1
            cp -p "$src" "$dest" 2>/dev/null || return 1
        done
        [ -f "$MERV_BASE/.ssh/vlan_manager" ] && chmod 600 "$MERV_BASE/.ssh/vlan_manager" 2>/dev/null || :
        [ -f "$MERV_BASE/.ssh/vlan_manager.pub" ] && chmod 644 "$MERV_BASE/.ssh/vlan_manager.pub" 2>/dev/null || :
        RESULT_SETTINGS="PASS - preserved values merged"
    else
        RESULT_SETTINGS="PASS - package defaults"
    fi
    json_set_flag "NODE_SSH_USER" "$INSTALL_SSH_USER" "$SETTINGS_FILE" >/dev/null 2>&1 || return 1
    json_set_flag "SSH_USER" "$INSTALL_SSH_USER" "$SETTINGS_FILE" >/dev/null 2>&1 || return 1
    json_set_flag "NODE_SSH_PORT" "$INSTALL_SSH_PORT" "$SETTINGS_FILE" >/dev/null 2>&1 || return 1
    json_set_flag "SSH_PORT" "$INSTALL_SSH_PORT" "$SETTINGS_FILE" >/dev/null 2>&1 || return 1
    settings_file_looks_valid "$SETTINGS_FILE"
}

rollback_active_installation() {
    [ "$INSTALL_ROLLBACK_NEEDED" = "1" ] || return 0
    case "$INSTALL_ROLLBACK_DIR" in "$ADDON_DIR"/.mervlan-install-rollback.[0-9]*) ;; *) return 1 ;; esac
    [ "$MERV_BASE" = "/jffs/addons/mervlan" ] || return 1
    rm -rf "$MERV_BASE" 2>/dev/null || :
    mv "$INSTALL_ROLLBACK_DIR" "$MERV_BASE" 2>/dev/null || return 1
    INSTALL_ROLLBACK_NEEDED=0
}

remove_test_menu_entry() {
    local menu_tmp menu_target="/www/require/modules/menuTree.js" menu_rewritten=0
    if [ "$TEST_MENU_ENTRY_ADDED" = "1" ]; then
        [ -f /tmp/menuTree.js ] || return 1
        menu_tmp="/tmp/menuTree.mervlan-test.$$"
        sed '/tabName: "MerVLAN Test"/d' /tmp/menuTree.js > "$menu_tmp" 2>/dev/null || { rm -f "$menu_tmp"; return 1; }
        mv "$menu_tmp" /tmp/menuTree.js 2>/dev/null || { rm -f "$menu_tmp"; return 1; }
        chmod 644 /tmp/menuTree.js 2>/dev/null || :
        TEST_MENU_ENTRY_ADDED=0
        menu_rewritten=1
    fi
    if [ "$TEST_MENU_TREE_CREATED" = "1" ]; then
        # The test created the only menu-tree bind mount. Removing that mount
        # restores the firmware file; an already-unmounted target is harmless.
        umount "$menu_target" 2>/dev/null || :
        rm -f /tmp/menuTree.js 2>/dev/null || return 1
        TEST_MENU_TREE_CREATED=0
    elif [ "$menu_rewritten" = "1" ] && [ -f /tmp/menuTree.js ]; then
        # sed/mv replaces the file inode. Refresh the bind mount so Merlin no
        # longer serves the inode containing the temporary tab.
        # Do not rely on /proc/mounts: some Merlin builds do not expose this
        # file bind in a form that can be matched reliably.
        umount "$menu_target" 2>/dev/null || :
        if ! mount -o bind /tmp/menuTree.js "$menu_target" 2>/dev/null; then
            RESULT_DETAIL="could not remount the cleaned Merlin menu tree"
            installer_record ERROR "$RESULT_DETAIL"
            return 1
        fi
    fi
    if grep -q 'tabName: "MerVLAN Test"' "$menu_target" 2>/dev/null; then
        RESULT_DETAIL="temporary LAN menu entry remains in the served menu tree"
        installer_record ERROR "$RESULT_DETAIL"
        return 1
    fi
    if [ -f /tmp/menuTree.js ] && grep -q 'tabName: "MerVLAN Test"' /tmp/menuTree.js 2>/dev/null; then
        RESULT_DETAIL="temporary LAN menu entry remains in /tmp/menuTree.js"
        installer_record ERROR "$RESULT_DETAIL"
        return 1
    fi
    return 0
}

cleanup_test_resources() {
    local failed=0 stale_page
    [ "$TEST_RUN" = "1" ] || return 0
    if grep -q 'tabName: "MerVLAN Test"' /tmp/menuTree.js 2>/dev/null || \
       grep -q 'tabName: "MerVLAN Test"' /www/require/modules/menuTree.js 2>/dev/null; then
        if [ ! -f /tmp/menuTree.js ]; then
            cp /www/require/modules/menuTree.js /tmp/menuTree.js 2>/dev/null || {
                RESULT_DETAIL="could not recover the stale Merlin menu tree"
                failed=1
            }
        fi
        TEST_MENU_ENTRY_ADDED=1
    fi
    remove_test_menu_entry || failed=1
    if [ -n "$TEST_WEBUI_PAGE" ]; then
        case "$TEST_WEBUI_PAGE" in user[0-9]*.asp) rm -f "/www/user/$TEST_WEBUI_PAGE" 2>/dev/null || failed=1 ;; *) failed=1 ;; esac
    fi
    for stale_page in /www/user/user*.asp; do
        [ -f "$stale_page" ] || continue
        if grep -q 'MerVLAN Installer Test' "$stale_page" 2>/dev/null; then rm -f "$stale_page" 2>/dev/null || failed=1; fi
    done
    if [ "$PUBLIC_DIR" = "/www/user/mervlan-test-run" ]; then rm -rf "$PUBLIC_DIR" 2>/dev/null || failed=1; else failed=1; fi
    if [ "$MERV_BASE" = "/jffs/addons/mervlan-test-run" ]; then rm -rf "$MERV_BASE" 2>/dev/null || failed=1; else failed=1; fi
    if [ "$TMP_DIR" = "/tmp/mervlan_tmp/test-run" ]; then rm -rf "$TMP_DIR" 2>/dev/null || failed=1; else failed=1; fi
    [ "$failed" = "0" ]
}

run_full_preflight() {
    local command_name
    for command_name in curl tar gzip sed awk grep cp mv rm; do
        merv_has "$command_name" || { RESULT_DETAIL="required command missing: $command_name"; return 1; }
    done
    [ -d "$ADDON_DIR" ] || mkdir -p "$ADDON_DIR" 2>/dev/null || { RESULT_DETAIL="cannot create $ADDON_DIR"; return 1; }
    [ -w "$ADDON_DIR" ] || { RESULT_DETAIL="$ADDON_DIR is not writable"; return 1; }
    nvram get rc_support 2>/dev/null | grep -q am_addons || { RESULT_DETAIL="firmware does not advertise am_addons support"; return 1; }
    type am_get_webui_page >/dev/null 2>&1 || { RESULT_DETAIL="Merlin helper am_get_webui_page is unavailable"; return 1; }
    type am_settings_get >/dev/null 2>&1 || { RESULT_DETAIL="Merlin helper am_settings_get is unavailable"; return 1; }
    type am_settings_set >/dev/null 2>&1 || { RESULT_DETAIL="Merlin helper am_settings_set is unavailable"; return 1; }
    return 0
}

create_test_webui_page() {
    local page="$MERV_BASE/mervlan-test.asp" diagnostic="$MERV_BASE/www/installer-test.html"
    [ -f "$MERV_BASE/mervlan.asp" ] || return 1

    # Use the exact shell that the downloaded addon will publish. Replacing
    # only the visible title and iframe source ensures the test exercises the
    # same firmware scripts, menu initialization, and layout as the real page.
    sed \
        -e 's@<title>Merlin VLAN Manager</title>@<title>MerVLAN Installer Test</title>@' \
        -e 's@<div class="formfonttitle">Merlin VLAN Manager</div>@<div class="formfonttitle">MerVLAN Installer Test</div>@' \
        -e 's@src="/user/mervlan/index.html"@src="/user/mervlan-test-run/installer-test.html"@' \
        -e 's@height:1750px;@height:440px;@' \
        "$MERV_BASE/mervlan.asp" > "$page" || return 1

    grep -q 'MerVLAN Installer Test' "$page" 2>/dev/null || return 1
    grep -q 'function initial' "$page" 2>/dev/null || return 1
    grep -q 'show_menu' "$page" 2>/dev/null || return 1
    grep -q 'src="/user/mervlan-test-run/installer-test.html"' "$page" 2>/dev/null || return 1

    {
        printf '%s\n' \
            '<!DOCTYPE html>' \
            '<html><head><meta charset="utf-8" /><meta name="viewport" content="width=device-width,initial-scale=1" />' \
            '<title>MerVLAN Installer Test</title>' \
            '<style>html,body{margin:0;background:transparent;color:#e7edf2;font:14px Arial,sans-serif}main{box-sizing:border-box;max-width:700px;margin:24px auto;padding:28px;border:1px solid #4f6774;border-radius:8px;background:#263640}.badge{display:inline-block;margin-bottom:14px;padding:5px 9px;border-radius:999px;background:#173f34;color:#70e0ad;font-weight:bold}h1{margin:0 0 14px;color:#fff;font-size:24px}.ok{font-size:17px;color:#70e0ad}.detail{line-height:1.55;color:#c9d5dc}</style>' \
            '</head><body><main>' \
            '<div class="badge">WEB UI TEST PASSED</div>' \
            '<h1>MerVLAN is working</h1>' \
            '<p class="ok">The temporary diagnostic page loaded inside the Asuswrt-Merlin interface.</p>' \
            '<p class="detail">This confirms that the isolated web directory, ASP wrapper, iframe, and LAN menu entry are available. The active MerVLAN page has not been replaced.</p>' \
            '</main></body></html>'
    } > "$diagnostic" || return 1
    chmod 644 "$page" 2>/dev/null || :
    chmod 644 "$diagnostic" 2>/dev/null || :
}

installer_exit_handler() {
    local status=$?
    trap - EXIT INT TERM
    if [ "$status" != "0" ]; then
        installer_record ERROR "Installer stopped during phase: $INSTALL_CURRENT_PHASE (exit=$status)"
        if [ -n "$RESULT_DETAIL" ]; then
            RESULT_DETAIL="$RESULT_DETAIL; phase: $INSTALL_CURRENT_PHASE"
        else
            RESULT_DETAIL="installer stopped during phase: $INSTALL_CURRENT_PHASE"
        fi
        echo "[install] ERROR: Installer stopped during: $INSTALL_CURRENT_PHASE" >&2
        [ -n "$INSTALL_DIAGNOSTIC_LOG" ] && echo "[install] Diagnostic log: $INSTALL_DIAGNOSTIC_LOG" >&2
        cleanup_install_download_work >/dev/null 2>&1 || :
        cleanup_preserved_files >/dev/null 2>&1 || :
        if [ "$INSTALL_ROLLBACK_NEEDED" = "1" ]; then
            if rollback_active_installation >/dev/null 2>&1; then
                RESULT_FILES="ROLLBACK - previous tree restored"
            else
                RESULT_FILES="FAIL - rollback failed"
            fi
        fi
        if [ "$TEST_RUN" = "1" ]; then
            if cleanup_test_resources >/dev/null 2>&1; then
                case "$RESULT_CLEANUP" in FAIL*) : ;; *) RESULT_CLEANUP="PASS - cleaned after failure" ;; esac
            else
                RESULT_CLEANUP="FAIL - cleanup after failure"
            fi
        fi
        [ "$RESULT_VERIFY" = "SKIPPED" ] && RESULT_VERIFY="FAIL - installer exited early"
        print_install_report "$status"
    fi
    exit "$status"
}

run_install_hardware_probe() {
    local detected_product
    if [ ! -x "$MERV_BASE/functions/hw_probe.sh" ]; then
        RESULT_HARDWARE="FAIL - hw_probe.sh missing"
        return 1
    fi
    if (
       # Source the probe in an isolated shell with every path supplied by the
       # install profile. This prevents its normal defaults from escaping the
       # test tree while still executing the real downloaded probe.
       VAR_SETTINGS_LOADED=1
       LOG_SETTINGS_LOADED=1
       TMPDIR="$TMP_DIR"; LOGDIR="$TMP_DIR/logs"; LOGROOT="$TMP_DIR/logs"
       FUNCDIR="$MERV_BASE/functions"; SETTINGSDIR="$MERV_BASE/settings"; FLAGDIR="$MERV_BASE/flags"
       PUBLIC_MERV_BASE="$PUBLIC_DIR"; PUBLIC_SETTINGS_DIR="$PUBLIC_DIR/settings"
       PUBLIC_SETTINGS_FILE="$PUBLIC_DIR/settings/settings.json"
       LOCKDIR="$TMP_DIR/locks"; RESULTDIR="$TMP_DIR/results"
       CHANGES="$TMP_DIR/results/vlan_changes"; COLLECTDIR="$TMP_DIR/client_collection"
       HW_SETTINGS_FILE="$SETTINGS_FILE"
       info() { printf '[hw_probe] %s\n' "$*"; }
       warn() { printf '[hw_probe] WARNING: %s\n' "$*" >&2; }
       error() { printf '[hw_probe] ERROR: %s\n' "$*" >&2; }
       log() { printf '[hw_probe] %s\n' "$*"; }
       . "$MERV_BASE/functions/hw_probe.sh"
    ); then
        detected_product=$(json_get_flag "PRODUCTID" "" "$SETTINGS_FILE" 2>/dev/null)
        if [ -n "$detected_product" ]; then
            RESULT_HARDWARE="PASS - $detected_product"
            return 0
        fi
        RESULT_HARDWARE="FAIL - PRODUCTID was not detected"
        return 1
    fi
    RESULT_HARDWARE="FAIL"
    return 1
}

# ========================================================================== #
# DOWNLOAD & BOOTSTRAP UTILITIES — Fetch repo and prepare fresh install      #
# ========================================================================== #

# select_and_validate_tarball — Interactive menu for tarball selection
# Args: $1 = staging directory path
# Returns: 0 on success (sets SELECTED_TARBALL), 1 on error/cancel
# Explanation: Lists available tarballs, allows selection and deletion
select_and_validate_tarball() {
  local staging_dir="$1"
  local tarballs idx sel chosen action
  
  while :; do
    # Find all mervlan-*.tar.gz files
    tarballs=$(ls "$staging_dir"/mervlan-*.tar.gz 2>/dev/null | sort -r)
    
    if [ -z "$tarballs" ]; then
      echo "[install] No mervlan tarballs found in $staging_dir"
      echo "[install] Run './install.sh download' first"
      return 1
    fi
    
    # Display menu
    echo ""
    echo "Available MerVLAN tarballs:"
    idx=0
    for tarball in $tarballs; do
      idx=$((idx + 1))
      base="$(basename "$tarball")"
      size="$(wc -c < "$tarball" 2>/dev/null)"
      # Extract branch and version from filename: mervlan-main-v0.48.tar.gz
      branch=$(echo "$base" | sed 's/mervlan-\([^-]*\)-.*/\1/')
      version=$(echo "$base" | sed 's/.*-\(v[^.]*\.[^.]*\)\.tar\.gz/\1/')
      printf '  %d) %s  [%s | %s | %d bytes]\n' "$idx" "$base" "$branch" "$version" "$size"
      eval "TARBALL_$idx=\"$tarball\""
    done
    
    echo ""
    echo "  d) Delete a tarball"
    echo "  q) Quit without installing"
    echo ""
    printf "Select tarball to install [1-%d, d, q]: " "$idx"
    read sel
    
    case "$sel" in
      [0-9]|[0-9][0-9])
        if [ "$sel" -ge 1 ] && [ "$sel" -le "$idx" ]; then
          eval "chosen=\$TARBALL_$sel"
          if [ -n "$chosen" ] && [ -f "$chosen" ]; then
            echo ""
            echo "Selected: $(basename "$chosen")"
            printf "Install this tarball? [y/N]: "
            read action
            case "$action" in
              y|Y|yes|YES)
                SELECTED_TARBALL="$chosen"
                return 0
                ;;
              *)
                echo "[install] Selection cancelled"
                continue
                ;;
            esac
          fi
        else
          echo "[install] Invalid selection"
          sleep 1
        fi
        ;;
      d|D)
        echo ""
        printf "Enter number of tarball to delete [1-%d]: " "$idx"
        read sel
        if [ "$sel" -ge 1 ] 2>/dev/null && [ "$sel" -le "$idx" ] 2>/dev/null; then
          eval "chosen=\$TARBALL_$sel"
          if [ -n "$chosen" ] && [ -f "$chosen" ]; then
            echo ""
            echo "WARNING: This will permanently delete:"
            echo "  $(basename "$chosen")"
            printf "Continue? [y/N]: "
            read action
            case "$action" in
              y|Y|yes|YES)
                rm -f "$chosen"
                echo "[install] Deleted $(basename "$chosen")"
                sleep 1
                ;;
              *)
                echo "[install] Deletion cancelled"
                sleep 1
                ;;
            esac
          fi
        else
          echo "[install] Invalid selection"
          sleep 1
        fi
        ;;
      q|Q)
        echo "[install] Installation cancelled by user"
        return 1
        ;;
      *)
        echo "[install] Invalid selection"
        sleep 1
        ;;
    esac
  done
}

# download_mervlan — Retrieve tarball, extract, copy into $MERV_BASE
# Args: none (uses global paths/URLs)
# Returns: 0 on success, non-zero on download/extract failures
# Explanation: Handles BusyBox quirks (tar -z support), ensures permissions,
#   injects service-event hooks, and runs hardware probe on new installs
#   Supports 'download' mode (fetch only) and 'tarball' mode (install from existing)
INSTALL_DOWNLOAD_WORK=""

cleanup_install_download_work() {
  [ -n "$INSTALL_DOWNLOAD_WORK" ] || return 0
  case "$INSTALL_DOWNLOAD_WORK" in
    "$TMP_DIR"/install.[0-9]*)
      [ -d "$INSTALL_DOWNLOAD_WORK" ] && rm -rf "$INSTALL_DOWNLOAD_WORK" 2>/dev/null || :
      ;;
  esac
  INSTALL_DOWNLOAD_WORK=""
}

download_mervlan() {
  local download_only=0 tarball_only=0 branch_choice="" download_valid=0

  echo "[download_mervlan] start"

  # Detect special modes
  case "$MODE" in
    download) 
      download_only=1
      # Ask user which branch to download
      echo ""
      echo "Select branch to download:"
      echo "  1) stable - Latest Release or stable version tag"
      echo "  2) dev    - Development version"
      while :; do
        printf "Enter choice [1-2]: "
        read branch_choice
        case "$branch_choice" in
          1) BRANCH="main"; break ;;
          2) BRANCH="dev"; break ;;
          *) echo "Invalid choice. Please enter 1 or 2." ;;
        esac
      done
      ;;
    tarball)  
      tarball_only=1 
      ;;
  esac

  local archive_dir="" work_dir="" owned_work=0
  SELECTED_TARBALL=""

  # Download/tarball are explicitly caller-owned two-phase storage. Full
  # installs use a private child of the runtime root and always remove it.
  if [ "$download_only" -eq 1 ] || [ "$tarball_only" -eq 1 ]; then
    if [ -z "$INSTALL_STAGING_DIR" ]; then
      echo "[download_mervlan] ERROR: 'download' and 'tarball' modes require explicit TMP_DIR environment variable" >&2
      echo "[download_mervlan] Usage examples:" >&2
      echo "[download_mervlan]   TMP_DIR=/tmp/mervlan_staging ./install.sh download" >&2
      echo "[download_mervlan]   TMP_DIR=/tmp/mervlan_staging ./install.sh tarball" >&2
      return 1
    fi
    archive_dir="$INSTALL_STAGING_DIR"
    mkdir -p "$archive_dir" 2>/dev/null || return 1
  fi

  if [ "$download_only" -eq 1 ]; then
    work_dir="$archive_dir"
  else
    work_dir="$TMP_DIR/install.$$"
    INSTALL_DOWNLOAD_WORK="$work_dir"
    owned_work=1
    mkdir -p "$work_dir" 2>/dev/null || { INSTALL_DOWNLOAD_WORK=""; return 1; }
    [ -n "$archive_dir" ] || archive_dir="$work_dir"
  fi
  echo "[download_mervlan] archive directory: $archive_dir"
  echo "[download_mervlan] extraction workspace: $work_dir (owned=$owned_work)"

  # Tarball mode selects a retained archive but extracts it only inside the
  # installer-owned workspace.
  if [ "$tarball_only" -eq 1 ]; then
    select_and_validate_tarball "$archive_dir" || return 1
  else
    # Full or download mode: fetch the tarball
    resolve_download_source || { RESULT_SOURCE="FAIL - source resolution"; return 1; }
    echo "[download_mervlan] GITHUB_URL=$GITHUB_URL"
    echo "[download_mervlan] downloading archive -> $archive_dir/mervlan_temp.tar.gz"
    /usr/sbin/curl -fsL --retry 3 "$GITHUB_URL" -o "$archive_dir/mervlan_temp.tar.gz" 2>/dev/null || :
    if [ -s "$archive_dir/mervlan_temp.tar.gz" ]; then
      tar -tzf "$archive_dir/mervlan_temp.tar.gz" >/dev/null 2>&1 && download_valid=1
      if [ "$download_valid" = "0" ]; then gzip -dc "$archive_dir/mervlan_temp.tar.gz" 2>/dev/null | tar -t >/dev/null 2>&1 && download_valid=1; fi
    fi
    if [ "$download_valid" = "0" ] && [ "$BRANCH" = "main" ] && [ "$SOURCE_REF" != "refs/heads/main" ]; then
      installer_warning "The selected stable archive could not be downloaded; retrying the main branch fallback."
      rm -f "$archive_dir/mervlan_temp.tar.gz" 2>/dev/null || :
      SOURCE_REF="refs/heads/main"
      SOURCE_DESCRIPTION="main branch fallback"
      GITHUB_URL="https://codeload.github.com/r80xcore/mervlan/tar.gz/$SOURCE_REF"
      RESULT_SOURCE="WARN - main fallback (stable archive unavailable)"
      /usr/sbin/curl -fsL --retry 3 "$GITHUB_URL" -o "$archive_dir/mervlan_temp.tar.gz" 2>/dev/null || :
      if [ -s "$archive_dir/mervlan_temp.tar.gz" ]; then
        tar -tzf "$archive_dir/mervlan_temp.tar.gz" >/dev/null 2>&1 && download_valid=1
        if [ "$download_valid" = "0" ]; then gzip -dc "$archive_dir/mervlan_temp.tar.gz" 2>/dev/null | tar -t >/dev/null 2>&1 && download_valid=1; fi
      fi
    fi
    if [ "$download_valid" = "1" ]; then
      echo "[download_mervlan] download ok, size=$(wc -c < "$archive_dir/mervlan_temp.tar.gz" 2>/dev/null) bytes"
      RESULT_DOWNLOAD="PASS"
    else
      echo "[download_mervlan] ERROR: download failed or archive is unreadable" >&2
      RESULT_DOWNLOAD="FAIL"
      return 1
    fi

    # Extract version from changelog.txt inside the tarball
    local version=""
    if tar -tzf "$archive_dir/mervlan_temp.tar.gz" >/dev/null 2>&1; then
      version=$(tar -xzf "$archive_dir/mervlan_temp.tar.gz" -O "*/changelog.txt" 2>/dev/null | head -1 | sed 's/^mervlan[[:space:]]*//')
    else
      version=$(gzip -dc "$archive_dir/mervlan_temp.tar.gz" | tar -x -O "*/changelog.txt" 2>/dev/null | head -1 | sed 's/^mervlan[[:space:]]*//')
    fi
    version=$(printf '%s' "$version" | tr -d '\r\n')
    
    if [ -z "$version" ]; then
      version="unknown"
    fi
    
    # Rename tarball to include branch and version
    local final_name="mervlan-${BRANCH}-${version}.tar.gz"
    mv "$archive_dir/mervlan_temp.tar.gz" "$archive_dir/$final_name"
    echo "[download_mervlan] Renamed to $final_name"
    
    # Set SELECTED_TARBALL for later use
    SELECTED_TARBALL="$archive_dir/$final_name"

    # Download only mode: stop here
    if [ "$download_only" -eq 1 ]; then
      echo "[download_mervlan] Download complete. Tarball saved to $archive_dir/$final_name"
      echo "[download_mervlan] Branch: $BRANCH | Version: $version"
      echo "[download_mervlan] To install, run: TMP_DIR=$archive_dir ./install.sh tarball"
      return 0
    fi
  fi

  # Continue with extraction and installation
  # Verify SELECTED_TARBALL is set (should be set by either download or tarball mode)
  if [ -z "$SELECTED_TARBALL" ] || [ ! -f "$SELECTED_TARBALL" ]; then
    echo "[download_mervlan] ERROR: No tarball selected or file not found" >&2
    return 1
  fi

  if ! tar -tzf "$SELECTED_TARBALL" >/dev/null 2>&1; then
    if ! gzip -dc "$SELECTED_TARBALL" 2>/dev/null | tar -t >/dev/null 2>&1; then
      RESULT_ARCHIVE="FAIL - unreadable archive"
      return 1
    fi
  fi
  if { tar -tzf "$SELECTED_TARBALL" 2>/dev/null || gzip -dc "$SELECTED_TARBALL" 2>/dev/null | tar -t 2>/dev/null; } | \
      grep -q '^/\|^\.\./\|/\.\./' 2>/dev/null; then
    echo "[download_mervlan] ERROR: Unsafe archive path detected" >&2
    RESULT_ARCHIVE="FAIL - unsafe paths"
    return 1
  fi
  
  echo "[download_mervlan] MERV_BASE=$MERV_BASE"
  mkdir -p "$MERV_BASE"
  echo "[download_mervlan] ensured MERV_BASE exists"

  # Extract: prefer tar -xzf; fallback to gzip -dc | tar -x for BusyBox without -z
  echo "[download_mervlan] Extracting $(basename "$SELECTED_TARBALL")"
  if tar -tzf "$SELECTED_TARBALL" >/dev/null 2>&1; then
    echo "[download_mervlan] extracting with tar -xzf"
    tar -xzf "$SELECTED_TARBALL" -C "$work_dir" || return 1
  else
    echo "[download_mervlan] extracting with gzip -dc | tar -x (fallback)"
    gzip -dc "$SELECTED_TARBALL" | tar -x -C "$work_dir" || return 1
  fi
  echo "[download_mervlan] extraction complete; top-level entries:"
  ls -1 "$work_dir" 2>/dev/null | sed 's/^/[download_mervlan]   /'

    # Determine top-level extracted directory from archive listing, with fallbacks
    local topdir="" topname=""
    if tar -tzf "$SELECTED_TARBALL" >/dev/null 2>&1; then
        topname="$(tar -tzf "$SELECTED_TARBALL" 2>/dev/null | head -1 | cut -d/ -f1)"
        echo "[download_mervlan] tar lists topname: ${topname:-<none>}"
    else
        topname="$(gzip -dc "$SELECTED_TARBALL" 2>/dev/null | tar -t 2>/dev/null | head -1 | cut -d/ -f1)"
        echo "[download_mervlan] gzip|tar lists topname: ${topname:-<none>}"
    fi
    if [ -n "$topname" ] && [ -d "$work_dir/$topname" ]; then
        topdir="$work_dir/$topname"
    else
        # Prefer directories matching mervlan-* if present
        for d in "$work_dir"/mervlan-*; do
            [ -d "$d" ] && { topdir="$d"; break; }
        done
        # Else pick first directory that isn't a known temp subdir like 'logs'
        if [ -z "$topdir" ]; then
            for d in "$work_dir"/*; do
                [ -d "$d" ] || continue
                [ "$(basename "$d")" = "logs" ] && continue
                topdir="$d"; break
            done
        fi
    fi
    echo "[download_mervlan] detected topdir (final): ${topdir:-<none>}"

  if [ -n "$topdir" ]; then
        for required in install.sh uninstall.sh changelog.txt mervlan.asp \
            functions/mervlan_boot.sh functions/hw_probe.sh settings/settings.json \
            settings/lib_json.sh www/index.html; do
            if [ ! -f "$topdir/$required" ]; then
                echo "[download_mervlan] ERROR: Package missing required file: $required" >&2
                RESULT_ARCHIVE="FAIL - missing $required"
                return 1
            fi
        done
        RESULT_ARCHIVE="PASS"
        echo "[download_mervlan] copying contents from $topdir -> $MERV_BASE"
        if ! cp -a "$topdir"/. "$MERV_BASE"/ 2>/dev/null; then
            echo "[download_mervlan] cp -a failed; using tar pipe fallback"
      ( cd "$topdir" && tar -cf - . ) | ( cd "$MERV_BASE" && tar -xpf - ) || return 1
    fi
        echo "[download_mervlan] copy step complete"
  else
    echo "ERROR: Unexpected archive layout (no top directory)" >&2
    return 1
  fi

        # Permissions: BusyBox-safe glob (no find). Default 755 for all .sh; case statement
    # overrides library/config files (settings/lib_*.sh, mac_shield_snapshot.sh,
    # mervlan_templates.sh, log_settings.sh, var_settings.sh) to 644.
        echo "[download_mervlan] adjusting file permissions (.sh)"
    for depth in "" "*/" "*/*/"; do
        for f in $MERV_BASE/${depth}*.sh; do
            [ -f "$f" ] 2>/dev/null || continue
            base="$(basename "$f")"
            case "$base" in
                log_settings.sh|var_settings.sh|\
                lib_debug.sh|lib_json.sh|lib_ssh.sh|lib_action_ack.sh|\
                lib_ssid_filter.sh|lib_stp.sh|lib_mervqt.sh|\
                lib_radio.sh|\
                mervlan_templates.sh|mac_shield_snapshot.sh|\
                lib_br0_guard.sh)
                    chmod 644 "$f" 2>/dev/null || :
                    ;;
                *)
                    chmod 755 "$f" 2>/dev/null || :
                    ;;
            esac
        done
    done
        echo "[download_mervlan] permission step complete"
    RESULT_FILES="PASS"

  if [ "$owned_work" -eq 1 ]; then
    echo "[download_mervlan] cleaning installer-owned workspace: $work_dir"
    cleanup_install_download_work
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
        "$TMP_DIR"/results/client_collection
    do
        mkdir -p "$d" 2>/dev/null || {
            printf 'ERROR: Failed to create directory: %s\n' "$d" >&2
            return 1
        }
    done

    if [ "$TEST_RUN" = "1" ] && [ "$TEST_WEBUI" != "1" ]; then
        return 0
    fi
    for d in \
        "$PUBLIC_DIR" \
        "$PUBLIC_DIR/settings" \
        "$PUBLIC_DIR/docs" \
        "$PUBLIC_DIR/diagrams" \
        "$PUBLIC_DIR/vendor" \
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
# create_logs [reset|preserve] — Initialize log files with safe permissions.
# Normal installs retain their historical reset behavior.  Internal reinstall
# runs create-if-missing so update/restore output survives public reprovisioning.
create_logs() {
    local policy="${1:-reset}" log_file
    case "$policy" in reset|preserve) ;; *) return 1 ;; esac

    for log_file in \
        "$TMP_DIR/logs/cli_output.log" \
        "$TMP_DIR/logs/vlan_manager.log"
    do
        if [ "$policy" = "reset" ] || [ ! -f "$log_file" ]; then
            : > "$log_file" || { printf 'ERROR: Failed to init %s\n' "${log_file##*/}" >&2; return 1; }
        fi
    done

    # boot_wrap may be the process currently invoking install.sh. Always make
    # its log available, but never truncate an active boot/startup sequence.
    log_file="$TMP_DIR/logs/boot_wrap.log"
    if [ ! -f "$log_file" ]; then
        : > "$log_file" || { printf 'ERROR: Failed to init %s\n' "${log_file##*/}" >&2; return 1; }
    fi

    chmod 755 "$TMP_DIR" "$TMP_DIR/logs"
    chmod 644 \
        "$TMP_DIR/logs/cli_output.log" \
        "$TMP_DIR/logs/vlan_manager.log" \
        "$TMP_DIR/logs/boot_wrap.log"
}

# Reinstall is used transactionally by update/restore, so its caller needs a
# reliable non-zero result when the complete public/runtime projection was not
# rebuilt.  Normal installs retain their historical best-effort behavior.
verify_reinstall_projection() {
    local failed=0 required
    local verify_www_user_root="${MERV_REINSTALL_WWW_USER_ROOT:-/www/user}"
    local verify_menu_tree="${MERV_REINSTALL_MENU_TREE:-/tmp/menuTree.js}"
    for required in \
        "$PUBLIC_DIR/index.html" \
        "$PUBLIC_DIR/vlan_index_style.css" \
        "$PUBLIC_DIR/vlan_form_style.css" \
        "$PUBLIC_DIR/help.html" \
        "$PUBLIC_DIR/view_logs.html" \
        "$PUBLIC_DIR/docs/HELP.json" \
        "$PUBLIC_DIR/vendor/marked.umd.js" \
        "$PUBLIC_DIR/vendor/github-markdown-dark.css" \
        "$PUBLIC_DIR/vendor/THIRD_PARTY_LICENSES.json" \
        "$PUBLIC_DIR/diagrams/topology-1_local.svg" \
        "$PUBLIC_DIR/diagrams/topology-2_aimesh.svg" \
        "$PUBLIC_DIR/diagrams/topology-3_standalone-ap.svg" \
        "$PUBLIC_DIR/diagrams/topology-4_node-to-main.svg" \
        "$TMP_DIR/logs/cli_output.log" \
        "$TMP_DIR/logs/vlan_manager.log" \
        "$TMP_DIR/logs/boot_wrap.log"
    do
        if [ ! -f "$required" ]; then
            printf '[install] ERROR: Reinstall projection missing %s\n' "$required" >&2
            failed=1
        fi
    done

    for required in \
        "$PUBLIC_DIR/settings/settings.json" \
        "$PUBLIC_DIR/tmp/logs/cli_output.json" \
        "$PUBLIC_DIR/tmp/logs/vlan_manager.json" \
        "$PUBLIC_DIR/tmp/logs/boot_wrap.json" \
        "$PUBLIC_DIR/tmp/results/vlan_clients.json"
    do
        if [ ! -L "$required" ]; then
            printf '[install] ERROR: Reinstall projection missing symlink %s\n' "$required" >&2
            failed=1
        fi
    done

    if [ -z "${am_webui_page:-}" ] || [ ! -f "$verify_www_user_root/$am_webui_page" ]; then
        printf '[install] ERROR: Reinstall projection missing registered ASP page\n' >&2
        failed=1
    fi
    if [ ! -f "$verify_menu_tree" ] || ! grep -q 'tabName: "MerVLAN"' "$verify_menu_tree" 2>/dev/null; then
        printf '[install] ERROR: Reinstall projection missing MerVLAN menu registration\n' >&2
        failed=1
    fi
    if [ -f "$MERV_BASE/.ssh/vlan_manager.pub" ] && [ ! -f "$PUBLIC_DIR/.ssh/vlan_manager.json" ]; then
        printf '[install] ERROR: Reinstall projection missing SSH public-key publication\n' >&2
        failed=1
    fi
    [ "$failed" = "0" ]
}

# ========================================================================== #
# INSTALL ENTRYPOINT — Support multiple install modes                       #
# ========================================================================== #
# Supported modes and behaviors:
#
#   ./install.sh
#     - Standard upgrade install (uses existing /jffs/addons/mervlan)
#     - Continues to normal install flow (no download)
#     - Does not prompt for SSH credentials
#
#   ./install.sh full
#     - Interactive source/configuration wizard and full install
#
#   ./install.sh full --test-run
#     - Runs the full installer in isolated test paths and cleans afterward
#
#   ./install.sh full dev
#     - Deprecated compatibility alias; starts the wizard with dev selected
#
#   TMP_DIR=/path ./install.sh download
#     - Interactive download session
#     - Prompts for branch selection (main/dev)
#     - Downloads and renames to mervlan-{branch}-{version}.tar.gz
#     - Exits after download (does not install)
#
#   TMP_DIR=/path ./install.sh tarball
#     - Interactive tarball selection menu
#     - Shows all mervlan-*.tar.gz in TMP_DIR
#     - Allows selection, deletion, or abort (q)
#     - Prompts for SSH credentials if installing
#     - Abortable at any confirmation prompt
#
#   ./install.sh credentials
#     - Update SSH credentials only
#     - Exits after updating settings.json
#
#   ./install.sh reinstall
#     - Rebuilds the complete runtime/public installation from existing files
#     - Preserves existing logs and leaves hook/node reconciliation to caller
#
# ========================================================================== #

INSTALL_LOG_POLICY="reset"
[ "$MODE" = "reinstall" ] && INSTALL_LOG_POLICY="preserve"

if [ "$MODE" = "full" ]; then
    if ! run_full_install_wizard; then
        echo "[install] Installation cancelled. No changes were made."
        exit 0
    fi
    trap 'installer_exit_handler' EXIT
    trap 'RESULT_DETAIL="interrupted by user"; exit 130' INT
    trap 'RESULT_DETAIL="terminated"; exit 143' TERM
    installer_log_init
    installer_phase_begin "Preflight checks"
    run_full_preflight || exit 1
    installer_phase_end

    if [ "$TEST_RUN" = "1" ]; then
        installer_phase_begin "Preparing isolated test environment"
        # Clear only the fixed isolated paths from an earlier interrupted run.
        cleanup_test_resources || { RESULT_CLEANUP="FAIL - stale test cleanup"; exit 1; }
        RESULT_CLEANUP="PENDING"
        ACTIVE_SETTINGS_DIGEST="$(digest_active_user_files)"
        ACTIVE_MENU_SNAPSHOT="$(digest_menu_tree)"
        ACTIVE_METADATA_SNAPSHOT="$(am_settings_get mervlan_page 2>/dev/null)|$(am_settings_get mervlan_state 2>/dev/null)|$(am_settings_get mervlan_version 2>/dev/null)"
        RESULT_ACTIVE="PENDING"
        installer_phase_end
    fi
    installer_phase_begin "Preserving existing installation data"
    mkdir -p "$TMP_DIR" 2>/dev/null || { RESULT_DETAIL="cannot create runtime staging"; exit 1; }
    prepare_preserved_files || { RESULT_EXISTING="FAIL - could not preserve user data"; exit 1; }
    prepare_install_target || { RESULT_FILES="FAIL - could not prepare target"; exit 1; }
    installer_phase_end
fi

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
    download)
        # Download tarball to TMP_DIR for later installation
        logger -t "$ADDON" "Download mode: fetching package to TMP_DIR for later installation"
        download_mervlan || { logger -t "$ADDON" "ERROR: download_mervlan failed"; exit 1; }
        logger -t "$ADDON" "Download complete. Use 'install tarball' to install."
        exit 0
        ;;
    tarball)
        # Install from previously downloaded tarball
        logger -t "$ADDON" "Tarball mode: installing from previously downloaded package"
        create_dirs_first_install || { logger -t "$ADDON" "ERROR: create_dirs_first_install failed"; exit 1; }
        download_mervlan || { logger -t "$ADDON" "ERROR: download_mervlan failed"; exit 1; }
        ;;
    full)
        # Full install: create dirs + download + setup
        installer_phase_begin "Downloading and validating the source package"
        logger -t "$ADDON" "Full install mode: creating base dirs and downloading package"
        create_dirs_first_install || { logger -t "$ADDON" "ERROR: create_dirs_first_install failed"; exit 1; }
        download_mervlan || { logger -t "$ADDON" "ERROR: download_mervlan failed"; exit 1; }
        installer_phase_end
        installer_phase_begin "Restoring settings and user data"
        restore_preserved_files || { RESULT_SETTINGS="FAIL - restore/configuration"; exit 1; }
        installer_phase_end
        installer_phase_begin "Detecting router hardware"
        run_install_hardware_probe || exit 1
        installer_phase_end
        ;;
    *)
        # Standard / upgrade install: verify addon files are already present
        for _req in \
            mervlan.asp \
            www/index.html \
            www/vlan_index_style.css \
            www/vlan_form_style.css \
            settings/lib_action_ack.sh \
            settings/settings.json
        do
            [ -f "$MERV_BASE/$_req" ] || {
                echo "[install] ERROR: Missing required file: $MERV_BASE/$_req" >&2
                echo "[install] The addon files are not installed yet." >&2
                echo "[install] For a first install, run: sh install.sh full" >&2
                exit 1
            }
        done

        for _optional in \
            www/help.html \
            www/view_logs.html \
            www/vendor/marked.umd.js \
            www/vendor/github-markdown-dark.css \
            www/vendor/THIRD_PARTY_LICENSES.md \
            docs/HELP.md \
            docs/diagrams/topology-1_local.svg \
            docs/diagrams/topology-2_aimesh.svg \
            docs/diagrams/topology-3_standalone-ap.svg \
            docs/diagrams/topology-4_node-to-main.svg
        do
            [ -f "$MERV_BASE/$_optional" ] || \
                echo "[install] WARNING: Optional file missing: $MERV_BASE/$_optional" >&2
        done
        ;;
esac

if [ "$MODE" = "full" ]; then
    installer_phase_begin "Publishing the Web UI and LAN menu"
fi

# ========================================================================== #
# CORE INSTALL FLOW — Validate firmware support and mount addon web page     #
# ========================================================================== #

# 1. Does the firmware support addons?
nvram get rc_support | grep -q am_addons
if [ $? != 0 ]; then
    logger -t "$ADDON" "This firmware does not support addons!"
    exit 5
fi

WEBUI_ENABLED=1
[ "$TEST_RUN" = "1" ] && [ "$TEST_WEBUI" != "1" ] && WEBUI_ENABLED=0
am_webui_page=""

if [ "$WEBUI_ENABLED" = "1" ]; then
    if [ "$TEST_RUN" = "1" ]; then
        create_test_webui_page || { RESULT_WEBUI="FAIL - diagnostic page creation"; exit 1; }
        WEBUI_SOURCE_PAGE="$MERV_BASE/mervlan-test.asp"
    else
        WEBUI_SOURCE_PAGE="$MERV_BASE/mervlan.asp"
    fi
    am_get_webui_page "$WEBUI_SOURCE_PAGE"
    if [ "$am_webui_page" = "none" ]; then
        logger -t "$ADDON" "Unable to install $ADDON (no free user page)"
        echo "[install] ERROR: No free user page slots available" >&2
        RESULT_WEBUI="FAIL - no free user page"
        exit 5
    fi
    logger -t "$ADDON" "Mounting $ADDON as $am_webui_page"
    echo "[install] Mounting web UI page: $am_webui_page"
    cp "$WEBUI_SOURCE_PAGE" "/www/user/$am_webui_page" || { RESULT_WEBUI="FAIL - ASP publication"; exit 1; }
    [ "$TEST_RUN" = "1" ] && TEST_WEBUI_PAGE="$am_webui_page"
    RESULT_WEBUI="PASS - $am_webui_page"
else
    RESULT_WEBUI="SAFETY-SKIPPED - optional test disabled"
    RESULT_MENU="SAFETY-SKIPPED - optional test disabled"
fi

# ========================================================================== #
# FILE & ASSET PROVISIONING — Prepare runtime directories and static assets  #
# ========================================================================== #

# 3a. Create Project Dirs
# Ensure runtime temp/log directories exist before exposing UI assets
echo "[install] Creating runtime directories and logs"
if create_dirs && create_logs "$INSTALL_LOG_POLICY"; then
    logger -t "$ADDON" "Logs & folder structure complete!"
else
    logger -t "$ADDON" "ERROR: Failed to initialize directories or logs"
    echo "[install] ERROR: Failed to initialize directories or logs" >&2
    exit 1
fi
if [ "$TEST_RUN" = "1" ]; then
    :
elif mkdir -p "${MERV_BASE%/*}/mervlan_backups" 2>/dev/null; then
    logger -t "$ADDON" "Backup directory created successfully"
else
    logger -t "$ADDON" "ERROR: Failed to create backup directory"
    echo "[install] ERROR: Failed to create backup directory" >&2
    exit 1
fi

# Full mode collected and applied these settings before provisioning. Preserve
# the historical tarball-mode prompts.
if [ "$MODE" = "tarball" ]; then
    prompt_ssh_user_override
    prompt_ssh_port_override
    run_install_hardware_probe || exit 1
fi

# 3b. Copy Static assets to Public Dir
if [ "$WEBUI_ENABLED" = "1" ]; then
cp -p "$ADDON_DIR/$ADDON/www/index.html"            "$PUBLIC_DIR/index.html" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/www/vlan_index_style.css"  "$PUBLIC_DIR/vlan_index_style.css" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/www/vlan_form_style.css"   "$PUBLIC_DIR/vlan_form_style.css" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/www/help.html"             "$PUBLIC_DIR/help.html" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/www/view_logs.html"        "$PUBLIC_DIR/view_logs.html" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/www/vendor/marked.umd.js"  "$PUBLIC_DIR/vendor/marked.umd.js" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/www/vendor/github-markdown-dark.css" "$PUBLIC_DIR/vendor/github-markdown-dark.css" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/www/vendor/THIRD_PARTY_LICENSES.md" "$PUBLIC_DIR/vendor/THIRD_PARTY_LICENSES.json" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/docs/HELP.md"              "$PUBLIC_DIR/docs/HELP.json" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/docs/diagrams/topology-1_local.svg" "$PUBLIC_DIR/diagrams/topology-1_local.svg" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/docs/diagrams/topology-2_aimesh.svg" "$PUBLIC_DIR/diagrams/topology-2_aimesh.svg" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/docs/diagrams/topology-3_standalone-ap.svg" "$PUBLIC_DIR/diagrams/topology-3_standalone-ap.svg" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/docs/diagrams/topology-4_node-to-main.svg" "$PUBLIC_DIR/diagrams/topology-4_node-to-main.svg" 2>/dev/null
if [ "$TEST_RUN" = "1" ]; then
    cp -p "$ADDON_DIR/$ADDON/www/installer-test.html" "$PUBLIC_DIR/installer-test.html" 2>/dev/null || {
        RESULT_WEBUI="FAIL - diagnostic asset publication"
        exit 1
    }
fi
# settings.json is a symlink to the persistent JFFS copy — one source of truth,
# no sync needed. Any write via the public path (save_settings.sh step 5, etc.)
# goes directly to the JFFS file. Recreated here on every boot since /www is tmpfs.
create_link "$MERV_BASE/settings/settings.json" "$PUBLIC_DIR/settings/settings.json"
# Note: hw_settings.json has been consolidated into settings/settings.json.
# The SPA now reads the Hardware block from settings/settings.json directly;
# keep the consolidated settings.json published for the UI.

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
create_link "$TMP_DIR/logs/boot_wrap.log"                "$PUBLIC_DIR/tmp/logs/boot_wrap.json"
create_link "$TMP_DIR/results/vlan_clients.json"        "$PUBLIC_DIR/tmp/results/vlan_clients.json"
# settings.json symlink is created above with the static asset copies

logger -t "$ADDON" "Symlinks created successfully"
echo "[install] Runtime symlinks created"
fi


# ========================================================================== #
# ASUSWRT UI INTEGRATION — Modify menu tree and persist addon metadata       #
# ========================================================================== #

if [ "$WEBUI_ENABLED" = "1" ]; then
# 4. Copy menuTree.js (if not already bind-mounted) so we can modify it
if [ ! -f /tmp/menuTree.js ]; then
    cp /www/require/modules/menuTree.js /tmp/
    mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js || { RESULT_MENU="FAIL - bind mount"; exit 1; }
    [ "$TEST_RUN" = "1" ] && TEST_MENU_TREE_CREATED=1
fi

# 5. Insert our tab inside the LAN menu
# Clean only the entry owned by this profile.
if [ "$TEST_RUN" = "1" ]; then
    MENU_LABEL="MerVLAN Test"
    sed -i '/tabName: "MerVLAN Test"/d' /tmp/menuTree.js
else
    MENU_LABEL="MerVLAN"
    sed -i '/tabName: "MerVLAN"/d' /tmp/menuTree.js
fi

# Append our MerVLAN tab just before the LAN menu's __INHERIT__ sentinel
sed -i "/index: \"menu_LAN\"/,/{url: \"NULL\", tabName: \"__INHERIT__\"}/ {/{url: \"NULL\", tabName: \"__INHERIT__\"}/i \\
{url: \"$am_webui_page\", tabName: \"$MENU_LABEL\"},
}" /tmp/menuTree.js

# 6. Remount after sed (bind+sed quirk)
umount /www/require/modules/menuTree.js 2>/dev/null || :
mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js 2>/dev/null || { RESULT_MENU="FAIL - menu remount"; exit 1; }

# 7. Record metadata for real installs only. Test mode must not overwrite the
# active addon's page, state, or version keys.
if [ "$TEST_RUN" = "1" ]; then
    TEST_MENU_ENTRY_ADDED=1
else
    am_settings_set mervlan_page "$am_webui_page"
    am_settings_set mervlan_state "enabled"
    MERVLAN_VERSION="$(awk 'NF { print $NF; exit }' "$MERV_BASE/changelog.txt" 2>/dev/null)"
    case "$MERVLAN_VERSION" in
        v*) : ;;
        *) MERVLAN_VERSION="unknown" ;;
    esac
    am_settings_set mervlan_version "$MERVLAN_VERSION"
fi

if grep -q "tabName: \"$MENU_LABEL\"" /tmp/menuTree.js 2>/dev/null; then
    RESULT_MENU="PASS - $MENU_LABEL"
else
    RESULT_MENU="FAIL - menu entry missing"
    exit 1
fi
logger -t "$ADDON" "Installed tab '$MENU_LABEL' under LAN -> $am_webui_page"
echo "[install] Web UI tab installed: LAN -> $MENU_LABEL ($am_webui_page)"

if [ "$TEST_RUN" = "1" ]; then
    echo ""
    echo "Web UI confirmation"
    echo "  1. Open the Asuswrt-Merlin Web UI."
    echo "  2. Refresh the browser, then open LAN and select 'MerVLAN Test'."
    echo "  3. Confirm that the diagnostic appears inside the normal Merlin page frame."
    if prompt_yes_no "Was 'MerVLAN Test' visible under LAN?" n; then
        RESULT_MENU="PASS - confirmed by user"
    else
        RESULT_MENU="FAIL - not visible (user confirmation)"
        TEST_VALIDATION_FAILED=1
    fi
    if prompt_yes_no "Did 'MerVLAN is working' load inside the Merlin page?" n; then
        RESULT_WEBUI="PASS - confirmed by user"
    else
        RESULT_WEBUI="FAIL - page did not load (user confirmation)"
        TEST_VALIDATION_FAILED=1
    fi
fi
fi

if [ "$MODE" = "full" ]; then
    installer_phase_end
    installer_phase_begin "Reconciling services and configured nodes"
fi

# ========================================================================== #
# POST-INSTALL HOOKS — Ensure service scripts reachable and sync nodes       #
# ========================================================================== #

# Reinstall is an internal public/runtime reprovisioning mode.  Update/restore
# deliberately remove old-version injections before the swap and reinstall the
# target-version injections afterward, so this phase must not create a second,
# hidden reconciliation cycle.
if [ "$TEST_RUN" = "1" ]; then
    RESULT_HOOKS="SAFETY-SKIPPED - active hooks protected"
    RESULT_NODES="SAFETY-SKIPPED - node operations disabled"
elif [ "$MODE" = "reinstall" ]; then
    if ! verify_reinstall_projection; then
        logger -t "$ADDON" "ERROR: Reinstall public/runtime projection verification failed"
        echo "[install] ERROR: Reinstall provisioning is incomplete" >&2
        exit 1
    fi
    logger -t "$ADDON" "Reinstall mode: public/runtime provisioning complete; hook reconciliation deferred to caller"
    echo "[install] Reinstall provisioning complete; hooks preserved for caller reconciliation"
    RESULT_HOOKS="SKIPPED - deferred to update/restore caller"
    RESULT_NODES="SKIPPED - deferred to update/restore caller"
else
    # Ensure boot/service-event hooks are present even on non-full installs
    echo "[install] Installing service-event hooks"
    if [ -x "$MERV_BASE/functions/mervlan_boot.sh" ]; then
        if MERV_SKIP_NODE_SYNC=1 sh "$MERV_BASE/functions/mervlan_boot.sh" setupenable >/dev/null 2>&1; then
            logger -t "$ADDON" "addon setupenable completed (post-install)"
            echo "[install] Service-event hooks installed"
            RESULT_HOOKS="PASS"
        else
            logger -t "$ADDON" "WARNING: setupenable failed during post-install"
            echo "[install] WARNING: Service-event hook installation failed" >&2
            RESULT_HOOKS="FAIL"
        fi
    else
        logger -t "$ADDON" "WARNING: mervlan_boot.sh not executable; skipping post-install setupenable"
        echo "[install] WARNING: mervlan_boot.sh not executable" >&2
        RESULT_HOOKS="FAIL - mervlan_boot.sh unavailable"
    fi

    # If nodes are configured and SSH keys are ready, propagate nodeenable now
    if has_configured_nodes && ssh_keys_effectively_installed; then
        if [ -x "$BOOT_SCRIPT" ]; then
            echo "[install] Propagating setup to $(count_configured_nodes) configured node(s)"
            logger -t "$ADDON" "Propagating nodeenable to configured nodes"
            if sh "$BOOT_SCRIPT" nodeenable >/dev/null 2>&1; then
                logger -t "$ADDON" "nodeenable completed successfully"
                echo "[install] Node setup completed successfully"
                RESULT_NODES="PASS - $(count_configured_nodes) node(s)"
            else
                logger -t "$ADDON" "WARNING: nodeenable encountered errors"
                echo "[install] WARNING: Some node operations may have failed" >&2
                RESULT_NODES="FAIL - nodeenable"
            fi
        else
            logger -t "$ADDON" "WARNING: mervlan_boot.sh not executable; skipping nodeenable"
            echo "[install] WARNING: Cannot propagate to nodes (mervlan_boot.sh not executable)" >&2
            RESULT_NODES="FAIL - boot helper unavailable"
        fi
    else
        if has_configured_nodes; then
            echo "[install] Nodes configured but SSH keys not ready; run SSH key setup to enable nodes"
        fi
        logger -t "$ADDON" "Nodeenable skipped (no nodes configured or SSH keys not installed)"
        if has_configured_nodes; then
            RESULT_NODES="SKIPPED - SSH keys not ready"
        else
            RESULT_NODES="SKIPPED - no configured nodes"
        fi
    fi
fi

if [ "$MODE" = "full" ]; then
    installer_phase_end
    installer_phase_begin "Final verification and cleanup"
fi

FINAL_STATUS=0

# Verify concrete outcomes before saying the installation succeeded.
for _req in install.sh uninstall.sh changelog.txt mervlan.asp functions/mervlan_boot.sh \
    functions/hw_probe.sh settings/settings.json settings/lib_json.sh www/index.html
do
    [ -f "$MERV_BASE/$_req" ] || { RESULT_DETAIL="final verification missing $MERV_BASE/$_req"; FINAL_STATUS=1; }
done
settings_file_looks_valid "$SETTINGS_FILE" || { RESULT_DETAIL="final settings validation failed"; FINAL_STATUS=1; }
[ -f "$TMP_DIR/logs/cli_output.log" ] || { RESULT_DETAIL="runtime cli log missing"; FINAL_STATUS=1; }
[ -f "$TMP_DIR/logs/vlan_manager.log" ] || { RESULT_DETAIL="runtime manager log missing"; FINAL_STATUS=1; }

if [ "$WEBUI_ENABLED" = "1" ]; then
    [ -n "$am_webui_page" ] && [ -f "/www/user/$am_webui_page" ] || { RESULT_WEBUI="FAIL - published ASP missing"; FINAL_STATUS=1; }
    for _public_req in index.html vlan_index_style.css vlan_form_style.css; do
        [ -f "$PUBLIC_DIR/$_public_req" ] || { RESULT_WEBUI="FAIL - public asset missing: $_public_req"; FINAL_STATUS=1; }
    done
    [ -L "$PUBLIC_DIR/settings/settings.json" ] || { RESULT_WEBUI="FAIL - settings link missing"; FINAL_STATUS=1; }
    if [ "$TEST_RUN" = "1" ]; then
        [ -f "$PUBLIC_DIR/installer-test.html" ] || { RESULT_WEBUI="FAIL - diagnostic asset missing"; FINAL_STATUS=1; }
        grep -q '/user/mervlan-test-run/installer-test.html' "/www/user/$am_webui_page" 2>/dev/null || {
            RESULT_WEBUI="FAIL - diagnostic iframe missing"
            FINAL_STATUS=1
        }
    fi
    grep -q "tabName: \"$MENU_LABEL\"" /tmp/menuTree.js 2>/dev/null || { RESULT_MENU="FAIL - verification"; FINAL_STATUS=1; }
fi

if [ "$RESULT_HOOKS" = "PASS" ]; then
    grep -q '/jffs/addons/mervlan/functions/service-event-handler.sh' /jffs/scripts/service-event 2>/dev/null || { RESULT_HOOKS="FAIL - service-event verification"; FINAL_STATUS=1; }
    grep -q '/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh install' /jffs/scripts/services-start 2>/dev/null || { RESULT_HOOKS="FAIL - services-start verification"; FINAL_STATUS=1; }
fi

case "$RESULT_HOOKS" in FAIL*) FINAL_STATUS=1 ;; esac
case "$RESULT_NODES" in FAIL*) FINAL_STATUS=1 ;; esac
[ "$TEST_VALIDATION_FAILED" = "0" ] || FINAL_STATUS=1

if [ "$TEST_RUN" = "1" ]; then
    if cleanup_test_resources; then
        RESULT_CLEANUP="PASS"
        case "$RESULT_MENU" in
            PASS*) RESULT_MENU="PASS - confirmed; temporary entry removed" ;;
        esac
        if [ "$TEST_WEBUI" = "1" ]; then
            echo "[install] Temporary Web UI page and LAN tab removed."
            echo "[install] Refresh the Merlin browser page to clear its already-loaded menu."
        fi
    else
        RESULT_CLEANUP="FAIL"
        FINAL_STATUS=1
    fi
    CURRENT_MENU_SNAPSHOT="$(digest_menu_tree)"
    CURRENT_METADATA_SNAPSHOT="$(am_settings_get mervlan_page 2>/dev/null)|$(am_settings_get mervlan_state 2>/dev/null)|$(am_settings_get mervlan_version 2>/dev/null)"
    if [ "$(digest_active_user_files)" = "$ACTIVE_SETTINGS_DIGEST" ] && \
       [ "$CURRENT_MENU_SNAPSHOT" = "$ACTIVE_MENU_SNAPSHOT" ] && \
       [ "$CURRENT_METADATA_SNAPSHOT" = "$ACTIVE_METADATA_SNAPSHOT" ] && \
       ! grep -q 'tabName: "MerVLAN Test"' /www/require/modules/menuTree.js 2>/dev/null; then
        RESULT_ACTIVE="UNCHANGED"
    else
        RESULT_ACTIVE="FAIL - active files, menu, or metadata changed"
        FINAL_STATUS=1
    fi
fi

if [ "$FINAL_STATUS" = "0" ]; then
    RESULT_VERIFY="PASS"
else
    RESULT_VERIFY="FAIL"
fi

if [ "$FINAL_STATUS" != "0" ] && [ "$MODE" = "full" ]; then
    exit 1
fi

if [ "$INSTALL_ROLLBACK_NEEDED" = "1" ]; then
    case "$INSTALL_ROLLBACK_DIR" in
        "$ADDON_DIR"/.mervlan-install-rollback.[0-9]*) rm -rf "$INSTALL_ROLLBACK_DIR" 2>/dev/null || : ;;
    esac
    INSTALL_ROLLBACK_NEEDED=0
fi
[ "$TEST_RUN" = "1" ] || cleanup_preserved_files >/dev/null 2>&1 || RESULT_DETAIL="installation succeeded but preservation staging cleanup failed"

[ "$RESULT_FILES" = "SKIPPED" ] && RESULT_FILES="PASS - installed source verified"
[ "$RESULT_SETTINGS" = "SKIPPED" ] && RESULT_SETTINGS="PASS - settings verified"
[ "$RESULT_EXISTING" = "SKIPPED" ] && RESULT_EXISTING="PASS - existing source retained"
if [ "$MODE" = "" ] || [ "$MODE" = "reinstall" ]; then
    RESULT_SOURCE="SKIPPED - using installed source"
    RESULT_DOWNLOAD="SKIPPED - using installed source"
    RESULT_ARCHIVE="SKIPPED - using installed source"
fi

if [ "$MODE" = "full" ]; then
    installer_phase_end
fi
trap - EXIT INT TERM
echo "[install] Installation complete!"
print_install_report "$FINAL_STATUS"
exit "$FINAL_STATUS"
