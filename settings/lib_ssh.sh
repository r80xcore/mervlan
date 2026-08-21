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
#              - File: lib_ssh.sh || version="0.72.4"                       #
# ============================================================================ #
# - Purpose:    Define shared SSH related functions                            #
# ============================================================================ #

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

# Only set if not already set (allows override for testing)
: "${MERV_BASE:?MERV_BASE must be set before sourcing folder_settings.sh}"
[ -n "${LIB_JSON_LOADED:-}" ] || {
	if [ -f "$MERV_BASE/settings/lib_json.sh" ]; then
		. "$MERV_BASE/settings/lib_json.sh"
	fi
}
if [ -z "${LIB_SSH_TRUST_LOADED:-}" ] && [ -f "$MERV_BASE/settings/lib_ssh_trust.sh" ]; then
  . "$MERV_BASE/settings/lib_ssh_trust.sh"
fi
[ -n "${LIB_SSH_LOADED:-}" ] && return 0 2>/dev/null
[ -n "${SETTINGS_FILE:-}" ] || SETTINGS_FILE="$MERV_BASE/settings/settings.json"
# ========================================================================== #
# AUTO-DETECT NODES/AP - Auto-detect nodes and access points interactively   #
# ========================================================================== #
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
        if ! rm -f "$tmp_candidates" "$tmp_selected" 2>/dev/null; then
            echo "[install] WARNING: Could not remove temporary node-selection files" >&2
            return 1
        fi
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

    if ! rm -f "$tmp_candidates" "$tmp_selected" 2>/dev/null; then
        echo "[install] WARNING: Could not remove temporary node-selection files" >&2
        return 1
    fi
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
# SAFE SSH WRAPPERS — hard timeout + 3 retries + clear skip reasons          #
# ========================================================================== #

# Public knobs (can be overridden per script via env)
: "${MERV_SSH_RETRIES:=3}"          # MUST be 3 per requirement
: "${MERV_SSH_TIMEOUT:=10}"         # seconds per attempt (dbclient hard timeout)
: "${MERV_SSH_PING_TIMEOUT:=2}"     # seconds for ping -W
: "${MERV_SSH_RETRY_DELAY:=2}"      # seconds between attempts
# Command execution is once-only by default.  A caller may opt in only for a
# command it has independently established as read-only/idempotent; even that
# opt-in never replays a command/session timeout or an ambiguous remote exit.
: "${MERV_SSH_EXEC_RETRY_SAFE:=0}"

# Last failure reason/details (for callers to log consistently)
MERV_SSH_LAST_REASON=""
MERV_SSH_LAST_DETAIL=""
MERV_SSH_TMP_SEQ=0

_merv_log_info() { merv_has info && info -c cli,vlan "$*" || echo "[INFO] $*"; }
_merv_log_warn() { merv_has warn && warn -c cli,vlan "$*" || echo "[WARN] $*"; }
_merv_log_err()  { merv_has error && error -c cli,vlan "$*" || echo "[ERROR] $*"; }

_merv_is_ipv4() {
  # returns 0 if $1 looks like IPv4
  echo "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

# Node identity is the configured ASUS/recovery endpoint plus its pinned MAC,
# never an address selected for an in-flight connection.  WAN Native can move a
# node's management address temporarily, so keep selection in this one library
# instead of teaching every SSH caller a special case.
merv_node_valid_ipv4() {
  printf '%s\n' "${1:-}" | awk -F. 'NF==4 { for (i=1;i<=4;i++) if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1; exit 0 } { exit 1 }'
}

merv_node_asus_endpoint() {
  _mnae_slot="$1"; _mnae_file="${2:-${SETTINGS_FILE:-}}"
  case "$_mnae_slot" in ''|*[!0-9]*) return 1 ;; esac
  _mnae_ip=$(json_get_section_value "Nodes" "NODE${_mnae_slot}" "$_mnae_file" 2>/dev/null)
  [ -n "$_mnae_ip" ] || _mnae_ip=$(json_get_flag "NODE${_mnae_slot}" "" "$_mnae_file" 2>/dev/null)
  [ -n "$_mnae_ip" ] || _mnae_ip=$(json_get_flag "NODE${_mnae_slot}_IP" "" "$_mnae_file" 2>/dev/null)
  merv_node_valid_ipv4 "$_mnae_ip" || return 1
  printf '%s\n' "$_mnae_ip"
}

merv_node_wan_native_value() {
  _mnwn_slot="$1"; _mnwn_file="${2:-${SETTINGS_FILE:-}}"
  # The shared resolver preserves a role-less legacy node as Standalone and
  # makes AiMesh inherit MAIN without overwriting its dormant node value.
  type merv_effective_wan_native_value >/dev/null 2>&1 || return 1
  merv_effective_wan_native_value "$_mnwn_slot" "$_mnwn_file"
}

merv_node_wan_native_endpoint() {
  _mnwe_slot="$1"; _mnwe_file="${2:-${SETTINGS_FILE:-}}"
  _mnwe_ip=$(json_get_section_value "Nodes" "NODE${_mnwe_slot}_WAN_NATIVE_IP" "$_mnwe_file" 2>/dev/null)
  [ -n "$_mnwe_ip" ] || _mnwe_ip=$(json_get_flag "NODE${_mnwe_slot}_WAN_NATIVE_IP" "" "$_mnwe_file" 2>/dev/null)
  case "$_mnwe_ip" in ''|none|NONE) return 1 ;; esac
  merv_node_valid_ipv4 "$_mnwe_ip" || return 1
  printf '%s\n' "$_mnwe_ip"
}

# Read the completed endpoint map emitted by a Sync preflight.  The map is
# deliberately opt-in: ordinary SSH callers continue to resolve the normal
# expected-first candidate list.  Every row is shape-checked, each slot may
# occur only once, and the requested slot/canonical identity must resolve to
# exactly one endpoint that is still a current candidate.
merv_ssh_sync_endpoint_pin() {
  _msep_slot="$1"; _msep_canonical="$2"; _msep_wan="${3:-}"; _msep_file="${4:-${SETTINGS_FILE:-}}"
  _msep_map="${MERV_SSH_SYNC_ENDPOINT_MAP:-}"
  [ -n "$_msep_map" ] || return 1
  case "$_msep_map" in
    /*) ;;
    *) return 2 ;;
  esac
  case "$_msep_map" in
    *..*|*[!A-Za-z0-9_./-]*) return 2 ;;
  esac
  [ -f "$_msep_map" ] || return 2
  _msep_seen_slots=' '; _msep_matches=0; _msep_endpoint=''
  while IFS=' ' read -r _msep_row_slot _msep_row_canonical _msep_row_endpoint _msep_extra || [ -n "$_msep_row_slot" ]; do
    [ -n "$_msep_row_slot" ] || return 2
    [ -z "$_msep_extra" ] || return 2
    case "$_msep_row_slot" in ''|*[!0-9]*) return 2 ;; esac
    [ "$_msep_row_slot" -ge 1 ] 2>/dev/null || return 2
    case "$_msep_seen_slots" in *" $_msep_row_slot "*) return 2 ;; esac
    _msep_seen_slots="$_msep_seen_slots$_msep_row_slot "
    merv_node_valid_ipv4 "$_msep_row_canonical" || return 2
    merv_node_valid_ipv4 "$_msep_row_endpoint" || return 2
    _msep_expected_canonical=$(merv_node_asus_endpoint "$_msep_row_slot" "$_msep_file" 2>/dev/null) || return 2
    [ "$_msep_row_canonical" = "$_msep_expected_canonical" ] || return 2
    if [ "$_msep_row_slot" = "$_msep_slot" ] && [ "$_msep_row_canonical" = "$_msep_canonical" ]; then
      _msep_matches=$((_msep_matches + 1))
      _msep_endpoint="$_msep_row_endpoint"
    fi
  done < "$_msep_map"
  [ "$_msep_matches" -eq 1 ] || return 2
  if [ "$_msep_endpoint" = "$_msep_canonical" ]; then
    :
  elif [ -n "$_msep_wan" ] && [ "$_msep_endpoint" = "$_msep_wan" ]; then
    :
  else
    return 2
  fi
  printf '%s\n' "$_msep_endpoint"
}

merv_node_endpoint_candidates() {
  # merv_node_endpoint_candidates <slot> [settings-file]
  # Emits expected-first endpoints.  The configured ASUS endpoint is retained
  # for identity/recovery; WAN Native only changes connection preference.
  _mnec_slot="$1"; _mnec_file="${2:-${SETTINGS_FILE:-}}"
  _mnec_asus=$(merv_node_asus_endpoint "$_mnec_slot" "$_mnec_file") || return 1
  _mnec_wan_mode=$(merv_node_wan_native_value "$_mnec_slot" "$_mnec_file") || return 2
  _mnec_wan=$(merv_node_wan_native_endpoint "$_mnec_slot" "$_mnec_file" 2>/dev/null || printf '')
  if [ "$_mnec_wan_mode" != none ] && [ -z "$_mnec_wan" ]; then
    MERV_SSH_LAST_REASON=wan-native-endpoint-missing
    MERV_SSH_LAST_DETAIL="NODE${_mnec_slot} WAN Native=$_mnec_wan_mode requires NODE${_mnec_slot}_WAN_NATIVE_IP"
    return 2
  fi
  if [ -n "${MERV_SSH_SYNC_ENDPOINT_MAP:-}" ]; then
    _mnec_pinned=$(merv_ssh_sync_endpoint_pin "$_mnec_slot" "$_mnec_asus" "$_mnec_wan" "$_mnec_file" 2>/dev/null) || {
      MERV_SSH_LAST_REASON=sync-endpoint-map-invalid
      MERV_SSH_LAST_DETAIL="NODE${_mnec_slot} preflight endpoint map is missing, stale, or not a current candidate"
      return 2
    }
    printf '%s\n' "$_mnec_pinned"
    return 0
  fi
  if [ "$_mnec_wan_mode" != none ] && [ -n "$_mnec_wan" ]; then
    printf '%s\n' "$_mnec_wan"
    [ "$_mnec_wan" = "$_mnec_asus" ] || printf '%s\n' "$_mnec_asus"
  else
    printf '%s\n' "$_mnec_asus"
    [ -z "$_mnec_wan" ] || [ "$_mnec_wan" = "$_mnec_asus" ] || printf '%s\n' "$_mnec_wan"
  fi
}

merv_node_endpoint_is_configured() {
  _mneic_slot="$1"; _mneic_ip="$2"; _mneic_file="${3:-${SETTINGS_FILE:-}}"
  merv_node_endpoint_candidates "$_mneic_slot" "$_mneic_file" 2>/dev/null | grep -Fx -- "$_mneic_ip" >/dev/null 2>&1
}

merv_node_validate_wan_native_management() {
  _mnvwn_file="${1:-${SETTINGS_FILE:-}}"; _mnvwn_slot=1
  while [ "$_mnvwn_slot" -le "${MERV_MAX_NODES:-10}" ]; do
    _mnvwn_asus=$(merv_node_asus_endpoint "$_mnvwn_slot" "$_mnvwn_file" 2>/dev/null || printf '')
    if [ -n "$_mnvwn_asus" ]; then
      _mnvwn_role=$(merv_node_role "$_mnvwn_slot" "$_mnvwn_file" 2>/dev/null) || {
        MERV_SSH_LAST_REASON=invalid-node-role
        MERV_SSH_LAST_DETAIL="NODE${_mnvwn_slot} role must be aimesh or standalone"
        return 1
      }
      _mnvwn_mode=$(merv_node_wan_native_value "$_mnvwn_slot" "$_mnvwn_file" 2>/dev/null) || {
        MERV_SSH_LAST_REASON=invalid-wan-native
        MERV_SSH_LAST_DETAIL="NODE${_mnvwn_slot} effective WAN Native value is invalid"
        return 1
      }
      if [ "$_mnvwn_mode" != none ] && ! merv_node_wan_native_endpoint "$_mnvwn_slot" "$_mnvwn_file" >/dev/null 2>&1; then
        MERV_SSH_LAST_REASON=wan-native-endpoint-missing
        MERV_SSH_LAST_DETAIL="NODE${_mnvwn_slot} (${_mnvwn_role}) has effective WAN Native=$_mnvwn_mode but no valid NODE${_mnvwn_slot}_WAN_NATIVE_IP"
        return 1
      fi
    fi
    _mnvwn_slot=$((_mnvwn_slot + 1))
  done
  return 0
}

# Live global preflight uses the same expected-first resolver as every SSH
# caller.  The immutable trust identity remains the ASUS/recovery endpoint;
# only the host-key probe transport address may be the configured WAN Native
# endpoint.  A reachability failure can try the configured recovery address;
# any trust, key, or configuration error fails closed immediately.
merv_ssh_preflight_configured_nodes() {
  _mspcn_file="${1:-${SETTINGS_FILE:-}}"
  [ -n "$_mspcn_file" ] && [ -f "$_mspcn_file" ] || return 2
  type merv_node_list >/dev/null 2>&1 || return 2
  _mspcn_lines=$(merv_node_list "$_mspcn_file" 2>/dev/null) || return 2
  [ -n "$_mspcn_lines" ] || return 0
  _mspcn_port=$(get_node_ssh_port 2>/dev/null || printf '22')
  _mspcn_port=$(merv_ssh_trust_normalize_port "$_mspcn_port") || return 2
  while IFS=' ' read -r _mspcn_slot _mspcn_canonical _mspcn_extra || [ -n "$_mspcn_slot" ]; do
    [ -n "$_mspcn_slot" ] || continue
    [ -z "$_mspcn_extra" ] || return 2
    _mspcn_canonical=$(merv_node_asus_endpoint "$_mspcn_slot" "$_mspcn_file") || return 2
    _mspcn_mac=$(json_get_flag "AUTO_NODE${_mspcn_slot}_MAC" "" "$_mspcn_file" 2>/dev/null)
    _mspcn_mac=$(merv_ssh_trust_mac_or_none "$_mspcn_mac") || return 2
    _mspcn_candidates=$(merv_node_endpoint_candidates "$_mspcn_slot" "$_mspcn_file" 2>/dev/null) || return 2
    _mspcn_ok=0
    while IFS= read -r _mspcn_endpoint || [ -n "$_mspcn_endpoint" ]; do
      [ -n "$_mspcn_endpoint" ] || continue
      merv_ssh_hostkey_probe "$_mspcn_slot" "$_mspcn_endpoint" "$_mspcn_port" "$_mspcn_mac" "$_mspcn_canonical"
      _mspcn_rc=$?
      if [ "$_mspcn_rc" -eq 0 ] && [ "${MERV_SSH_TRUST_LAST_STATUS:-}" = verified ]; then
        _mspcn_ok=1
        break
      fi
      case "$_mspcn_rc:${MERV_SSH_TRUST_LAST_REASON:-}" in
        10:*|11:*|*:unreachable|*:timeout|*:refused|*:no-route) continue ;;
        # Some Dropbear builds terminate before printing a transport error.
        # Treat that otherwise-ambiguous probe result as fallback-eligible only
        # when the same bounded ICMP check also proves this endpoint absent.
        7:probe-failed)
          _merv_ping_ok "$_mspcn_endpoint" || continue
          ;;
      esac
      MERV_SSH_LAST_REASON="${MERV_SSH_TRUST_LAST_REASON:-probe-failed}"
      MERV_SSH_LAST_DETAIL="NODE${_mspcn_slot:-?} host-key preflight failed"
      return "$_mspcn_rc"
    done <<EOF
$_mspcn_candidates
EOF
    if [ "$_mspcn_ok" -ne 1 ]; then
      MERV_SSH_LAST_REASON=unreachable
      MERV_SSH_LAST_DETAIL="NODE${_mspcn_slot:-?} no configured management endpoint reached the verified host-key probe"
      return 4
    fi
  done <<EOF
$_mspcn_lines
EOF
  return 0
}

_merv_ping_ok() {
  # BusyBox ping: -c 1 -W <sec>
  ping -c 1 -W "$MERV_SSH_PING_TIMEOUT" "$1" >/dev/null 2>&1
}

# Resolve an SSH stderr root.  Workers must explicitly provide both their job
# root and a descendant ssh directory; callers outside a worker keep the
# historical /tmp fallback.  Do not accept traversal or a sibling job path.
_merv_ssh_tmp_root() {
  MERV_SSH_TMP_ROOT=""
  if [ -z "${MERV_SSH_TMPDIR:-}" ]; then
    MERV_SSH_TMP_ROOT="/tmp"
    return 0
  fi
  case "${MERV_NODE_JOB_DIR:-}" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$MERV_NODE_JOB_DIR" in
    *..*|*[!A-Za-z0-9_./-]*) return 1 ;;
  esac
  case "$MERV_SSH_TMPDIR" in
    "$MERV_NODE_JOB_DIR"/ssh|"$MERV_NODE_JOB_DIR"/ssh/*) ;;
    *) return 1 ;;
  esac
  case "$MERV_SSH_TMPDIR" in
    *..*|*[!A-Za-z0-9_./-]*) return 1 ;;
  esac
  [ -d "$MERV_NODE_JOB_DIR" ] || return 1
  mkdir -p "$MERV_SSH_TMPDIR" 2>/dev/null || return 1
  MERV_SSH_TMP_ROOT="$MERV_SSH_TMPDIR"
  return 0
}

# Allocate one private stderr directory for this SSH attempt.  mkdir is the
# exclusion point; the sequence supplements $$ because BusyBox subshells can
# share a shell PID.  The caller removes only this exact directory.
_merv_ssh_tmp_acquire() {
  _msta_root="$1"
  case "${MERV_SSH_TMP_SEQ:-}" in ''|*[!0-9]*) MERV_SSH_TMP_SEQ=0 ;; esac
  _msta_try=0
  while [ "$_msta_try" -lt 100 ]; do
    MERV_SSH_TMP_SEQ=$((MERV_SSH_TMP_SEQ + 1))
    MERV_SSH_ERR_DIR="$_msta_root/ssh_err.$$.${MERV_SSH_TMP_SEQ}"
    if mkdir "$MERV_SSH_ERR_DIR" 2>/dev/null; then
      MERV_SSH_ERR_FILE="$MERV_SSH_ERR_DIR/stderr"
      : > "$MERV_SSH_ERR_FILE" 2>/dev/null || {
        if ! rmdir "$MERV_SSH_ERR_DIR" 2>/dev/null; then
          _merv_log_err "Could not remove failed SSH stderr directory $MERV_SSH_ERR_DIR"
        fi
        return 1
      }
      return 0
    fi
    _msta_try=$((_msta_try + 1))
  done
  return 1
}

_merv_ssh_tmp_release() {
  case "${MERV_SSH_ERR_DIR:-}" in
    "${MERV_SSH_TMP_ROOT:-}"/ssh_err.[0-9]*.[0-9]*) ;;
    *) return 1 ;;
  esac
  if ! rm -f "${MERV_SSH_ERR_FILE:-}" 2>/dev/null; then
    _merv_log_err "Could not remove SSH stderr file ${MERV_SSH_ERR_FILE:-}"
    return 1
  fi
  if ! rmdir "$MERV_SSH_ERR_DIR" 2>/dev/null; then
    _merv_log_err "Could not remove SSH stderr directory $MERV_SSH_ERR_DIR"
    return 1
  fi
  MERV_SSH_ERR_FILE=""
  MERV_SSH_ERR_DIR=""
  return 0
}

# BusyBox on the lab router has no timeout/setsid applets.  Collect the
# descendants of a timed command from /proc so the fallback can terminate the
# command tree without killing unrelated processes.
_merv_timeout_collect_tree() {
  _mtct_root="$1"
  case "$_mtct_root" in ''|*[!0-9]*) return 1 ;; esac
  MERV_TIMEOUT_TREE_PIDS=" $_mtct_root "
  _mtct_pass=0
  # One or two passes are sufficient on the router's normal shell->client
  # process shape. More passes make the watchdog itself miss the deadline on
  # low-powered BusyBox systems because /proc scans are comparatively costly.
  while [ "$_mtct_pass" -lt 2 ]; do
    _mtct_added=0
    for _mtct_stat in /proc/[0-9]*/stat; do
      _mtct_pid=${_mtct_stat#/proc/}
      _mtct_pid=${_mtct_pid%/stat}
      case "$_mtct_pid" in ''|*[!0-9]*) continue ;; esac
      case "$MERV_TIMEOUT_TREE_PIDS" in *" $_mtct_pid "*) continue ;; esac
      _mtct_line=$(cat "$_mtct_stat" 2>/dev/null) || continue
      case "$_mtct_line" in *") "*) _mtct_tail=${_mtct_line##*) } ;; *) continue ;; esac
      _mtct_state=${_mtct_tail%% *}
      _mtct_rest=${_mtct_tail#* }
      _mtct_ppid=${_mtct_rest%% *}
      case "$MERV_TIMEOUT_TREE_PIDS" in
        *" $_mtct_ppid "*)
          MERV_TIMEOUT_TREE_PIDS="${MERV_TIMEOUT_TREE_PIDS}${_mtct_pid} "
          _mtct_added=1
          ;;
      esac
    done
    [ "$_mtct_added" -eq 1 ] || break
    _mtct_pass=$((_mtct_pass + 1))
  done
  return 0
}

_merv_timeout_signal_tree() {
  _mtst_signal="$1"
  _mtst_root=""
  _mtst_failed=0
  for _mtst_pid in $MERV_TIMEOUT_TREE_PIDS; do
    case "$_mtst_pid" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$_mtst_root" ]; then
      _mtst_root="$_mtst_pid"
      continue
    fi
    if [ -d "/proc/$_mtst_pid" ] && ! kill "$_mtst_signal" "$_mtst_pid" 2>/dev/null; then
      _mtst_failed=1
    fi
  done
  if [ -n "$_mtst_root" ] && [ -d "/proc/$_mtst_root" ] && ! kill "$_mtst_signal" "$_mtst_root" 2>/dev/null; then
    _mtst_failed=1
  fi
  [ "$_mtst_failed" -eq 0 ]
}

_merv_timeout_run() {
  # Run command with a hard timeout if possible.
  # Prefer BusyBox 'timeout' when available.
  seconds="$1"; shift
  if merv_has timeout; then
    timeout "$seconds" "$@"
    return $?
  fi
  # ASUS builds without the timeout applet still need a real deadline. Run the
  # command in the background and let a short-lived watchdog terminate it.
  # Return 124 for either watchdog signal, matching common timeout semantics.
  exec 9<&0
  _mtr_root="${MERV_SSH_TMPDIR:-${TMPDIR:-/tmp/mervlan_tmp}}"
  case "$_mtr_root" in
    /*) ;;
    *) _mtr_root="/tmp" ;;
  esac
  case "$_mtr_root" in
    *..*|*[!A-Za-z0-9_./-]*) _mtr_root="/tmp" ;;
  esac
  mkdir -p "$_mtr_root" 2>/dev/null || _mtr_root="/tmp"
  _mtr_try=0
  while :; do
    _mtr_dir="$_mtr_root/timeout_out.$$.${_mtr_try}"
    mkdir "$_mtr_dir" 2>/dev/null && break
    _mtr_try=$((_mtr_try + 1))
    [ "$_mtr_try" -lt 100 ] || return 125
  done
  _mtr_out="$_mtr_dir/stdout"
  _mtr_err="$_mtr_dir/stderr"
  : > "$_mtr_out" 2>/dev/null || {
    if ! rmdir "$_mtr_dir" 2>/dev/null; then _merv_log_err "Could not remove timeout directory $_mtr_dir"; fi
    return 125
  }
  : > "$_mtr_err" 2>/dev/null || {
    if ! rm -f "$_mtr_out"; then _merv_log_err "Could not remove timeout stdout file $_mtr_out"; fi
    if ! rmdir "$_mtr_dir" 2>/dev/null; then _merv_log_err "Could not remove timeout directory $_mtr_dir"; fi
    return 125
  }
  "$@" <&9 >"$_mtr_out" 2>"$_mtr_err" &
  _mtr_pid=$!
  exec 9<&-
  (
    sleep "$seconds"
    if ! _merv_timeout_collect_tree "$_mtr_pid"; then
      _merv_timeout_collect_failed=1
    fi
    _merv_timeout_signal_tree -TERM
    # The command has already exceeded its deadline; do not add another
    # full BusyBox sleep interval before force-cleaning its descendants.
    _merv_timeout_signal_tree -KILL
  ) >/dev/null 2>&1 &
  _mtr_watchdog=$!
  wait "$_mtr_pid"
  _mtr_rc=$?
  _mtr_cleanup_failed=0
  if [ -d "/proc/$_mtr_watchdog" ] && ! kill "$_mtr_watchdog" 2>/dev/null; then _mtr_cleanup_failed=1; fi
  if wait "$_mtr_watchdog" 2>/dev/null; then :; else _mtr_watchdog_rc=$?; fi
  if ! cat "$_mtr_out" 2>/dev/null; then _mtr_cleanup_failed=1; fi
  if ! cat "$_mtr_err" >&2; then _mtr_cleanup_failed=1; fi
  if ! rm -f "$_mtr_out" 2>/dev/null; then _mtr_cleanup_failed=1; fi
  if ! rm -f "$_mtr_err" 2>/dev/null; then _mtr_cleanup_failed=1; fi
  if ! rmdir "$_mtr_dir" 2>/dev/null; then _mtr_cleanup_failed=1; fi
  [ "$_mtr_cleanup_failed" -eq 0 ] || _merv_log_err "Timed SSH command cleanup failed in $_mtr_dir"
  [ "$_mtr_cleanup_failed" -eq 0 ] || return 125
  case "$_mtr_rc" in
    137|143) return 124 ;;
    *) return "$_mtr_rc" ;;
  esac
}

# Dropbear's dbclient tries to create $HOME/.ssh even with -y.  Service and
# CGI launchers may provide HOME=/ (or another read-only location), which
# creates a noisy warning on every direct client invocation.  Use one owned,
# volatile client home for all runtime dbclient calls without changing keys or
# host-key acceptance policy.
merv_ssh_prepare_client_home() {
  _mssh_home="${MERV_SSH_HOME:-${TMPDIR:-/tmp/mervlan_tmp}/dbclient_home}"
  case "$_mssh_home" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$_mssh_home" in
    *[!A-Za-z0-9_./-]*) return 1 ;;
  esac
  mkdir -p "$_mssh_home/.ssh" 2>/dev/null || return 1
  MERV_SSH_BASE_HOME="$_mssh_home"
  export MERV_SSH_BASE_HOME
  HOME="$_mssh_home"
  export HOME
  MERV_SSH_HOME="$_mssh_home"
  export MERV_SSH_HOME
  return 0
}

if ! merv_ssh_prepare_client_home; then
  MERV_SSH_HOME=""
fi

# Each outbound operation gets its own client HOME. A shared known_hosts file
# is unsafe when node workers run in parallel: one worker can replace the
# pinned record while another dbclient is between precheck and connect.
MERV_SSH_KNOWN_HOME=""
MERV_SSH_KNOWN_HOME_SEQ=0

merv_ssh_node_mac() {
  _msnm_node="$1"
  if type json_get_flag >/dev/null 2>&1; then
    _msnm_mac=$(json_get_flag "AUTO_NODE${_msnm_node}_MAC" "" "${SETTINGS_FILE:-}" 2>/dev/null)
  fi
  merv_ssh_trust_mac_or_none "${_msnm_mac:-}" 2>/dev/null
}

# One outbound operation calls merv_ssh_precheck and then immediately builds a
# private known_hosts file.  Keep the checked identity and pinned record only
# for that narrow hand-off.  prepare_known_host rechecks the trust-file digest
# before reuse, so an enroll/revoke between the two calls falls back to a full
# trust lookup rather than using the earlier record.
merv_ssh_precheck_cache_clear() {
  MERV_SSH_PRECHECK_SLOT=""; MERV_SSH_PRECHECK_HOST=""; MERV_SSH_PRECHECK_PORT=""; MERV_SSH_PRECHECK_MAC=""
  MERV_SSH_PRECHECK_USER=""
  MERV_SSH_PRECHECK_NODE=""; MERV_SSH_PRECHECK_TRUST_DIGEST=""
  MERV_SSH_PRECHECK_TRUST_NODE=""; MERV_SSH_PRECHECK_TRUST_SLOT=""; MERV_SSH_PRECHECK_TRUST_MAC=""
  MERV_SSH_PRECHECK_TRUST_HOST=""; MERV_SSH_PRECHECK_TRUST_PORT=""; MERV_SSH_PRECHECK_TRUST_ALGORITHM=""
  MERV_SSH_PRECHECK_TRUST_PUBLIC_KEY=""; MERV_SSH_PRECHECK_TRUST_FINGERPRINT=""
}

merv_ssh_precheck_cache_matches() {
  [ "${MERV_SSH_PRECHECK_SLOT:-}" = "$1" ] && [ "${MERV_SSH_PRECHECK_HOST:-}" = "$2" ]
}

merv_ssh_canonical_endpoint() {
  _msce_slot="$1"; _msce_host="$2"
  _msce_canonical=$(merv_node_asus_endpoint "$_msce_slot" 2>/dev/null || printf '')
  [ -n "$_msce_canonical" ] || _msce_canonical="$_msce_host"
  printf '%s\n' "$_msce_canonical"
}

merv_ssh_precheck_cache_store() {
  _mspcs_slot="$1"; _mspcs_host="$2"; _mspcs_port="$3"; _mspcs_mac="$4"; _mspcs_user="$5"
  _mspcs_canonical=$(merv_ssh_canonical_endpoint "$_mspcs_slot" "$_mspcs_host") || return 1
  _mspcs_node=$(merv_ssh_trust_node_id "$_mspcs_slot" "$_mspcs_mac" "$_mspcs_canonical" "$_mspcs_port") || return 1
  [ "${SSH_TRUST_NODE:-}" = "$_mspcs_node" ] || return 1
  [ "${SSH_TRUST_HOST:-}" = "$_mspcs_canonical" ] && [ "${SSH_TRUST_PORT:-}" = "$_mspcs_port" ] || return 1
  [ -n "$_mspcs_user" ] || return 1
  MERV_SSH_PRECHECK_SLOT="$_mspcs_slot"; MERV_SSH_PRECHECK_HOST="$_mspcs_host"; MERV_SSH_PRECHECK_PORT="$_mspcs_port"; MERV_SSH_PRECHECK_MAC="$_mspcs_mac"; MERV_SSH_PRECHECK_USER="$_mspcs_user"
  MERV_SSH_PRECHECK_NODE="$_mspcs_node"; MERV_SSH_PRECHECK_TRUST_DIGEST="${MERV_SSH_TRUST_VALIDATION_DIGEST:-}"
  MERV_SSH_PRECHECK_TRUST_NODE="$SSH_TRUST_NODE"; MERV_SSH_PRECHECK_TRUST_SLOT="$SSH_TRUST_SLOT"; MERV_SSH_PRECHECK_TRUST_MAC="$SSH_TRUST_MAC"
  MERV_SSH_PRECHECK_TRUST_HOST="$SSH_TRUST_HOST"; MERV_SSH_PRECHECK_TRUST_PORT="$SSH_TRUST_PORT"; MERV_SSH_PRECHECK_TRUST_ALGORITHM="$SSH_TRUST_ALGORITHM"
  MERV_SSH_PRECHECK_TRUST_PUBLIC_KEY="$SSH_TRUST_PUBLIC_KEY"; MERV_SSH_PRECHECK_TRUST_FINGERPRINT="$SSH_TRUST_FINGERPRINT"
  return 0
}

merv_ssh_precheck_trust_current() {
  _msptc_node="$1"; _msptc_host="$2"; _msptc_port="$3"; _msptc_mac="$4"
  _msptc_canonical=$(merv_ssh_canonical_endpoint "${MERV_SSH_PRECHECK_SLOT:-}" "$_msptc_host") || return 1
  [ "${MERV_SSH_PRECHECK_HOST:-}" = "$_msptc_host" ] || return 1
  [ "${MERV_SSH_PRECHECK_PORT:-}" = "$_msptc_port" ] && [ "${MERV_SSH_PRECHECK_MAC:-}" = "$_msptc_mac" ] || return 1
  [ "${MERV_SSH_PRECHECK_NODE:-}" = "$_msptc_node" ] && [ "${MERV_SSH_PRECHECK_TRUST_NODE:-}" = "$_msptc_node" ] || return 1
  [ "${MERV_SSH_PRECHECK_TRUST_HOST:-}" = "$_msptc_canonical" ] && [ "${MERV_SSH_PRECHECK_TRUST_PORT:-}" = "$_msptc_port" ] || return 1
  [ -n "${MERV_SSH_PRECHECK_TRUST_ALGORITHM:-}" ] && [ -n "${MERV_SSH_PRECHECK_TRUST_PUBLIC_KEY:-}" ] || return 1
  [ -n "${MERV_SSH_PRECHECK_TRUST_DIGEST:-}" ] || return 1
  _msptc_digest=$(merv_ssh_trust_file_digest "${MERV_SSH_TRUST_FILE:-}" 2>/dev/null || printf '')
  [ "$_msptc_digest" = "$MERV_SSH_PRECHECK_TRUST_DIGEST" ]
}

merv_ssh_precheck_trust_restore() {
  SSH_TRUST_NODE="$MERV_SSH_PRECHECK_TRUST_NODE"; SSH_TRUST_SLOT="$MERV_SSH_PRECHECK_TRUST_SLOT"; SSH_TRUST_MAC="$MERV_SSH_PRECHECK_TRUST_MAC"
  SSH_TRUST_HOST="$MERV_SSH_PRECHECK_TRUST_HOST"; SSH_TRUST_PORT="$MERV_SSH_PRECHECK_TRUST_PORT"; SSH_TRUST_ALGORITHM="$MERV_SSH_PRECHECK_TRUST_ALGORITHM"
  SSH_TRUST_PUBLIC_KEY="$MERV_SSH_PRECHECK_TRUST_PUBLIC_KEY"; SSH_TRUST_FINGERPRINT="$MERV_SSH_PRECHECK_TRUST_FINGERPRINT"
}

merv_ssh_preflight_grant_fresh() {
  _mspgf_epoch="${MERV_OBS_TRUST_GATE_EPOCH:-}"
  _mspgf_expected="${MERV_OBS_TRUST_GATE_DIGEST:-}"
  case "$_mspgf_epoch" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$_mspgf_expected" | grep -Eq '^cksum:[0-9]+\.[0-9]+$|^md5:[0-9A-Fa-f]{32}$' || return 1
  _mspgf_now=$(date +%s 2>/dev/null || printf '0')
  case "$_mspgf_now" in ''|*[!0-9]*) return 1 ;; esac
  _mspgf_max="${MERV_OBS_TRUST_GATE_MAX_AGE_SEC:-30}"
  case "$_mspgf_max" in ''|*[!0-9]*) _mspgf_max=30 ;; esac
  [ "$_mspgf_max" -ge 1 ] 2>/dev/null && [ "$_mspgf_max" -le 120 ] 2>/dev/null || _mspgf_max=30
  [ "$_mspgf_now" -ge "$_mspgf_epoch" ] 2>/dev/null || return 1
  _mspgf_age=$((_mspgf_now - _mspgf_epoch))
  [ "$_mspgf_age" -le "$_mspgf_max" ] 2>/dev/null || return 1
  type merv_node_list_digest >/dev/null 2>&1 || return 1
  _mspgf_actual=$(merv_node_list_digest 2>/dev/null) || return 1
  [ "$_mspgf_actual" = "$_mspgf_expected" ]
}

merv_ssh_release_known_host() {
  _msrkh_home="${MERV_SSH_KNOWN_HOME:-}"
  [ -n "$_msrkh_home" ] || return 0
  _msrkh_base="${MERV_SSH_BASE_HOME:-}"
  [ -n "$_msrkh_base" ] || return 1
  case "$_msrkh_home" in
    "$_msrkh_base"/ssh_op.*) ;;
    *) return 1 ;;
  esac
  case "$_msrkh_home" in *[!A-Za-z0-9_./-]*) return 1 ;; esac
  rm -rf "$_msrkh_home" 2>/dev/null || return 1
  MERV_SSH_KNOWN_HOME=""
  MERV_SSH_HOME="$_msrkh_base"
  HOME="$_msrkh_base"
  export MERV_SSH_KNOWN_HOME MERV_SSH_HOME HOME
  return 0
}

merv_ssh_prepare_known_host() {
  _mskh_node="$1"; _mskh_host="$2"; _mskh_port="$3"; _mskh_mac="$4"
  _mskh_canonical=$(merv_ssh_canonical_endpoint "$_mskh_node" "$_mskh_host") || return 1
  _mskh_node_id=$(merv_ssh_trust_node_id "$_mskh_node" "$_mskh_mac" "$_mskh_canonical" "$_mskh_port") || return 1
  if merv_ssh_precheck_trust_current "$_mskh_node_id" "$_mskh_host" "$_mskh_port" "$_mskh_mac"; then
    merv_ssh_precheck_trust_restore
  else
    merv_ssh_trust_find "$_mskh_node_id" || return 1
  fi
  [ -z "${MERV_SSH_KNOWN_HOME:-}" ] || merv_ssh_release_known_host || return 1
  [ -n "${MERV_SSH_BASE_HOME:-}" ] || merv_ssh_prepare_client_home || return 1
  _mskh_base="$MERV_SSH_BASE_HOME"
  case "$_mskh_base" in /*) ;; *) return 1 ;; esac
  case "$_mskh_base" in *..*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
  case "${MERV_SSH_KNOWN_HOME_SEQ:-}" in ''|*[!0-9]*) MERV_SSH_KNOWN_HOME_SEQ=0 ;; esac
  _mskh_try=0
  while [ "$_mskh_try" -lt 100 ]; do
    MERV_SSH_KNOWN_HOME_SEQ=$((MERV_SSH_KNOWN_HOME_SEQ + 1))
    _mskh_home="$_mskh_base/ssh_op.$$.${MERV_SSH_KNOWN_HOME_SEQ}"
    if mkdir "$_mskh_home" 2>/dev/null && mkdir "$_mskh_home/.ssh" 2>/dev/null; then
      break
    fi
    rm -rf "$_mskh_home" 2>/dev/null || :
    _mskh_try=$((_mskh_try + 1))
  done
  [ -d "$_mskh_home/.ssh" ] || return 1
  chmod 700 "$_mskh_home" "$_mskh_home/.ssh" 2>/dev/null || { rm -rf "$_mskh_home" 2>/dev/null || :; return 1; }
  _mskh_tmp="$_mskh_home/.ssh/known_hosts.tmp.$$.$MERV_SSH_KNOWN_HOME_SEQ"
  _mskh_host_token="$_mskh_host"
  [ "$_mskh_port" = 22 ] || _mskh_host_token="[$_mskh_host]:$_mskh_port"
  ( umask 077; printf '%s %s %s\n' "$_mskh_host_token" "$SSH_TRUST_ALGORITHM" "$SSH_TRUST_PUBLIC_KEY" > "$_mskh_tmp" ) 2>/dev/null || { rm -rf "$_mskh_home" 2>/dev/null || :; return 1; }
  chmod 600 "$_mskh_tmp" 2>/dev/null || { rm -rf "$_mskh_home" 2>/dev/null || :; return 1; }
  mv -f "$_mskh_tmp" "$_mskh_home/.ssh/known_hosts" 2>/dev/null || { rm -rf "$_mskh_home" 2>/dev/null || :; return 1; }
  MERV_SSH_KNOWN_HOME="$_mskh_home"
  MERV_SSH_HOME="$_mskh_home"
  HOME="$_mskh_home"
  export MERV_SSH_KNOWN_HOME MERV_SSH_HOME HOME
  return 0
}

merv_ssh_precheck() {
  # merv_ssh_precheck <node_num> <node_ip>
  # returns:
  #   0 = ok
  #   2 = ssh keys missing
  #   3 = invalid ip
  #   4 = unreachable (ping)
  node_num="$1"
  node_ip="$2"

  merv_ssh_precheck_cache_clear
  MERV_SSH_LAST_REASON=""
  MERV_SSH_LAST_DETAIL=""

  if [ -z "$node_ip" ] || ! _merv_is_ipv4 "$node_ip"; then
    MERV_SSH_LAST_REASON="invalid-ip"
    MERV_SSH_LAST_DETAIL="NODE${node_num:-?} ip='$node_ip'"
    return 3
  fi

  node_mac=$(merv_ssh_node_mac "$node_num" 2>/dev/null)
  if [ -z "$node_mac" ]; then
    MERV_SSH_LAST_REASON="node-mac-missing"
    MERV_SSH_LAST_DETAIL="NODE${node_num:-?} has no canonical AUTO_NODE${node_num}_MAC identity"
    return 6
  fi
  _node_port_for_trust="$(get_node_ssh_port 2>/dev/null || printf '22')"
  _node_asus_endpoint=$(merv_node_asus_endpoint "$node_num" 2>/dev/null || printf '')
  if [ -n "$_node_asus_endpoint" ] && [ "$node_ip" != "$_node_asus_endpoint" ] && \
     ! merv_node_endpoint_is_configured "$node_num" "$node_ip"; then
    MERV_SSH_LAST_REASON="unconfigured-endpoint"
    MERV_SSH_LAST_DETAIL="NODE${node_num:-?} endpoint '$node_ip' is not configured"
    return 3
  fi
  merv_ssh_require_verified_node "$node_num" "$node_ip" "$_node_port_for_trust" "$node_mac" "$_node_asus_endpoint"
  _trust_rc=$?
  if [ "$_trust_rc" -ne 0 ]; then
    MERV_SSH_LAST_REASON="${MERV_SSH_TRUST_LAST_REASON:-ssh-trust-required}"
    MERV_SSH_LAST_DETAIL="NODE${node_num:-?} host-key trust precondition failed"
    return 6
  fi

  # Keys check (uses existing lib behavior)
  if ! ssh_keys_effectively_installed; then
    MERV_SSH_LAST_REASON="ssh-keys-missing"
    MERV_SSH_LAST_DETAIL="NODE${node_num:-?} ip='$node_ip' (SSH_KEYS_INSTALLED=0 or keyfiles missing)"
    return 2
  fi

  if [ -z "${SSH_KEY:-}" ] || [ ! -f "$SSH_KEY" ]; then
    MERV_SSH_LAST_REASON="ssh-keyfile-missing"
    MERV_SSH_LAST_DETAIL="NODE${node_num:-?} ip='$node_ip' missing SSH_KEY='$SSH_KEY'"
    return 2
  fi

  _node_user_for_ssh="$(get_node_ssh_user 2>/dev/null || printf 'admin')"
  [ -n "$_node_user_for_ssh" ] || _node_user_for_ssh="admin"

  # A caller that has just completed a verified SSH connection may suppress
  # only this redundant ICMP check for its short-lived follow-up sequence.
  # Host-key, node-identity, and key-file checks above still run for every
  # connection, and dbclient retains its bounded timeout/retry behavior.
  case "$MERV_SSH_SKIP_PING" in
    1|yes|on|true)
      merv_ssh_precheck_cache_store "$node_num" "$node_ip" "$_node_port_for_trust" "$node_mac" "$_node_user_for_ssh" || merv_ssh_precheck_cache_clear
      return 0
      ;;
  esac

  # Fast reachability check
  if ! _merv_ping_ok "$node_ip"; then
    MERV_SSH_LAST_REASON="unreachable"
    MERV_SSH_LAST_DETAIL="NODE${node_num:-?} ip='$node_ip' not reachable via ping"
    return 4
  fi

  merv_ssh_precheck_cache_store "$node_num" "$node_ip" "$_node_port_for_trust" "$node_mac" "$_node_user_for_ssh" || merv_ssh_precheck_cache_clear
  return 0
}

merv_ssh_exec_endpoint() {
  # merv_ssh_exec <node_num> <node_ip> <remote_cmd>
  #
  # Behavior:
  # - Precheck (ip + keys + ping) may retry before command execution.
  # - A remote command executes once by default.  Set
  #   MERV_SSH_EXEC_RETRY_SAFE=1 only for an explicitly idempotent command;
  #   that permits retry only after a proven pre-command transport failure.
  # - A hard command/session timeout and every ambiguous command exit are
  #   terminal: the command may already have run and must not be replayed.
  # - sets MERV_SSH_LAST_REASON / DETAIL on failure
  #
  # Return:
  #   0 = success
  #   2 = keys missing
  #   3 = invalid ip
  #   4 = unreachable
  #   5 = ssh failed (timeout/refused/auth/etc)
  _node_num="$1"
  _node_ip="$2"
  _remote_cmd="$3"

  # Refuse to run if node context is set (safety; aligns with mervlan_boot behavior)
  if [ "${MERV_NODE_CONTEXT:-0}" = "1" ]; then
    MERV_SSH_LAST_REASON="node-context"
    MERV_SSH_LAST_DETAIL="Refusing outbound SSH from node context"
    return 5
  fi

  # Retry reachability prechecks before any remote command is started.  Once
  # dbclient has been invoked, retrying is governed by the stricter execution
  # contract below.
  _attempt=1
  while [ "$_attempt" -le "$MERV_SSH_RETRIES" ]; do
    merv_ssh_precheck "$_node_num" "$_node_ip"
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
      # If invalid ip or keys missing → do not retry (it won't improve)
      if [ "$_rc" -eq 2 ] || [ "$_rc" -eq 3 ] || [ "$_rc" -eq 6 ] || [ "$_rc" -eq 7 ] || [ "$_rc" -eq 8 ]; then
        return "$_rc"
      fi
      # unreachable → retry up to 3 times
      if [ "$_attempt" -lt "$MERV_SSH_RETRIES" ]; then
        sleep "$MERV_SSH_RETRY_DELAY"
        _attempt=$((_attempt + 1))
        continue
      fi
      [ "$_rc" -eq 4 ] && return 4
      return "$_rc"
    fi

    # Build args. The precheck just read and verified this node's identity;
    # reuse that exact context for this connection instead of reparsing JSON.
    if merv_ssh_precheck_cache_matches "$_node_num" "$_node_ip"; then
      _port="$MERV_SSH_PRECHECK_PORT"
      _node_mac="$MERV_SSH_PRECHECK_MAC"
      _user="$MERV_SSH_PRECHECK_USER"
    else
      _port="$(get_node_ssh_port)"
      _node_mac=$(merv_ssh_node_mac "$_node_num" 2>/dev/null) || _node_mac=""
      _user="$(get_node_ssh_user)"
    fi
    [ -n "$_port" ] || _port="22"
    [ -n "$_user" ] || _user="admin"

    # Capture stderr in an invocation-private file.  Worker callers supply a
    # validated job-contained root; shared callers retain /tmp compatibility.
    if ! _merv_ssh_tmp_root || ! _merv_ssh_tmp_acquire "$MERV_SSH_TMP_ROOT"; then
      MERV_SSH_LAST_REASON="invalid-ssh-tmpdir"
      MERV_SSH_LAST_DETAIL="NODE${_node_num:-?} cannot allocate isolated SSH stderr path"
      return 5
    fi
    _tmp="$MERV_SSH_ERR_FILE"

    # Hard-timeout dbclient
    merv_ssh_prepare_known_host "$_node_num" "$_node_ip" "$_port" "$_node_mac" || {
      merv_ssh_release_known_host 2>/dev/null || :
      if ! _merv_ssh_tmp_release; then
        MERV_SSH_LAST_REASON="known-host-temp-cleanup-failed"
        MERV_SSH_LAST_DETAIL="NODE${_node_num:-?} private SSH stderr cleanup failed"
        return 5
      fi
      MERV_SSH_LAST_REASON="known-host-publication-failed"
      MERV_SSH_LAST_DETAIL="NODE${_node_num:-?} verified key could not be installed into the private client home"
      return 5
    }
    _out=$(
      _merv_timeout_run "$MERV_SSH_TIMEOUT" \
        "${MERV_SSH_CLIENT:-dbclient}" -p "$_port" -i "$SSH_KEY" \
        "$_user@$_node_ip" "$_remote_cmd" \
        </dev/null \
        2>"$_tmp"
    )
    _rc=$?
    _err=""
    _err=$(cat "$_tmp" 2>/dev/null)
    _merv_ssh_known_release_rc=0
    merv_ssh_release_known_host || _merv_ssh_known_release_rc=$?
    _merv_ssh_tmp_release || {
      MERV_SSH_LAST_REASON="ssh-tmp-cleanup-failed"
      MERV_SSH_LAST_DETAIL="NODE${_node_num:-?} isolated SSH stderr cleanup failed"
      return 5
    }
    if [ "$_merv_ssh_known_release_rc" -ne 0 ]; then
      MERV_SSH_LAST_REASON="known-host-temp-cleanup-failed"
      MERV_SSH_LAST_DETAIL="NODE${_node_num:-?} private SSH client home cleanup failed"
      return 5
    fi

    if [ "$_rc" -eq 0 ]; then
      MERV_SSH_LAST_REASON=""
      MERV_SSH_LAST_DETAIL=""
      # Print stdout so callers can capture it if needed
      printf '%s' "$_out"
      return 0
    fi

    # A local timeout cannot prove dbclient failed before the remote shell
    # started.  It is deliberately distinct from a connection timeout emitted
    # by dbclient before session establishment, and must never fall back or
    # replay the command.
    if [ "$_rc" -eq 124 ]; then
      MERV_SSH_LAST_REASON="session-timeout"
      MERV_SSH_LAST_DETAIL="NODE${_node_num:-?} ip='$_node_ip' command/session timed out after ${MERV_SSH_TIMEOUT}s"
      return 5
    else
      # Best-effort classify common dbclient failures
      if echo "$_err" | grep -qi "Permission denied"; then
        MERV_SSH_LAST_REASON="auth-failed"
        MERV_SSH_LAST_DETAIL="NODE${_node_num:-?} ip='$_node_ip' Permission denied (keys/user mismatch)"
        # auth failures won't improve by retrying → stop
        return 5
      elif echo "$_err" | grep -qi "Connection refused"; then
        MERV_SSH_LAST_REASON="refused"
        MERV_SSH_LAST_DETAIL="NODE${_node_num:-?} ip='$_node_ip' connection refused (SSH service/port wrong)"
      elif echo "$_err" | grep -qi "No route to host"; then
        MERV_SSH_LAST_REASON="no-route"
        MERV_SSH_LAST_DETAIL="NODE${_node_num:-?} ip='$_node_ip' no route to host"
      elif echo "$_err" | grep -Eqi 'Connection timed out|Connect timeout|Operation timed out|Network is unreachable'; then
        MERV_SSH_LAST_REASON="connect-timeout"
        MERV_SSH_LAST_DETAIL="NODE${_node_num:-?} ip='$_node_ip' connection timed out before SSH session establishment"
      elif echo "$_err" | grep -Eqi 'host[[:space:]-]*key|fingerprint'; then
        MERV_SSH_LAST_REASON="host-key-mismatch"
        MERV_SSH_LAST_DETAIL="NODE${_node_num:-?} ip='$_node_ip' rejected the pinned SSH host key"
        return 6
      elif [ "$_rc" -eq 126 ] || [ "$_rc" -eq 127 ]; then
        MERV_SSH_LAST_REASON="remote-cmd-failed"
        MERV_SSH_LAST_DETAIL="NODE${_node_num:-?} ip='$_node_ip' remote command exited rc=$_rc"
        # Missing remote files/binaries will not improve by retrying.
        return 5
      else
        MERV_SSH_LAST_REASON="command-or-session-failed"
        MERV_SSH_LAST_DETAIL="NODE${_node_num:-?} ip='$_node_ip' command/session failed rc=$_rc; not replayed"
        return 5
      fi
    fi

    # A same-endpoint execution retry is an explicit caller contract, and is
    # available only when dbclient positively reported a pre-session transport
    # failure.  The default remains exactly one command invocation.
    case "${MERV_SSH_EXEC_RETRY_SAFE:-0}" in 1|yes|on|true) _retry_safe=1 ;; *) _retry_safe=0 ;; esac
    if [ "$_retry_safe" -eq 1 ] && [ "$_attempt" -lt "$MERV_SSH_RETRIES" ]; then
      sleep "$MERV_SSH_RETRY_DELAY"
      _attempt=$((_attempt + 1))
      continue
    fi

    return 5
  done

  return 5
}

# Endpoint fallback is safe only when the preferred transport is proven not to
# have established a usable SSH session. Any generic SSH failure or remote exit
# is ambiguous and must never replay a potentially mutating command elsewhere.
merv_ssh_fallback_allowed() {
  case "${1:-}" in
    unreachable|timeout|refused|no-route|connect-timeout) return 0 ;;
    *) return 1 ;;
  esac
}

merv_ssh_exec() {
  # merv_ssh_exec <node_num> <configured-asus-ip> <remote_cmd>
  # All existing connection callers retain their configured ASUS value, while
  # this wrapper chooses the expected WAN Native endpoint first when enabled.
  _msee_slot="$1"; _msee_configured="$2"; _msee_cmd="$3"
  _msee_candidates=$(merv_node_endpoint_candidates "$_msee_slot" 2>/dev/null)
  _msee_candidate_rc=$?
  if [ "$_msee_candidate_rc" -ne 0 ]; then
    # Preserve the historical direct-wrapper contract for legacy callers that
    # supply a valid endpoint before a Nodes section exists.  A discovered WAN
    # Native configuration error is never downgraded to that compatibility path.
    if [ "$_msee_candidate_rc" -eq 1 ] && merv_node_valid_ipv4 "$_msee_configured"; then
      _msee_candidates="$_msee_configured"
    else
      [ "$_msee_candidate_rc" -eq 2 ] || {
      MERV_SSH_LAST_REASON=invalid-node-endpoint
      MERV_SSH_LAST_DETAIL="NODE${_msee_slot:-?} configured ASUS endpoint is invalid"
      }
      return 3
    fi
  fi
  [ -n "$_msee_candidates" ] || { MERV_SSH_LAST_REASON=invalid-node-endpoint; return 3; }
  _msee_expected=$(printf '%s\n' "$_msee_candidates" | sed -n '1p')
  _msee_last_rc=4
  while IFS= read -r _msee_endpoint || [ -n "$_msee_endpoint" ]; do
    [ -n "$_msee_endpoint" ] || continue
    if merv_ssh_exec_endpoint "$_msee_slot" "$_msee_endpoint" "$_msee_cmd"; then
      MERV_NODE_ENDPOINT_SELECTED="$_msee_endpoint"
      MERV_NODE_ENDPOINT_EXPECTED="$_msee_expected"
      if [ "$_msee_endpoint" = "$_msee_expected" ]; then MERV_NODE_ENDPOINT_FALLBACK=0; else MERV_NODE_ENDPOINT_FALLBACK=1; fi
      return 0
    else
      _msee_last_rc=$?
    fi
    merv_ssh_fallback_allowed "${MERV_SSH_LAST_REASON:-}" || return "$_msee_last_rc"
  done <<EOF
$_msee_candidates
EOF
  return "$_msee_last_rc"
}

merv_node_resolve_endpoint() {
  # merv_node_resolve_endpoint <slot> <configured-asus-ip>
  _mnre_slot="$1"; _mnre_configured="$2"; _mnre_candidates=$(merv_node_endpoint_candidates "$_mnre_slot" 2>/dev/null)
  _mnre_candidates_rc=$?
  if [ "$_mnre_candidates_rc" -ne 0 ]; then
    [ "$_mnre_candidates_rc" -eq 1 ] && merv_node_valid_ipv4 "$_mnre_configured" || return 3
    _mnre_candidates="$_mnre_configured"
  fi
  _mnre_expected=$(printf '%s\n' "$_mnre_candidates" | sed -n '1p')
  _mnre_last_rc=4
  while IFS= read -r _mnre_endpoint || [ -n "$_mnre_endpoint" ]; do
    [ -n "$_mnre_endpoint" ] || continue
    if merv_ssh_precheck "$_mnre_slot" "$_mnre_endpoint"; then
      MERV_NODE_ENDPOINT_SELECTED="$_mnre_endpoint"; MERV_NODE_ENDPOINT_EXPECTED="$_mnre_expected"
      if [ "$_mnre_endpoint" = "$_mnre_expected" ]; then MERV_NODE_ENDPOINT_FALLBACK=0; else MERV_NODE_ENDPOINT_FALLBACK=1; fi
      printf '%s\n' "$_mnre_endpoint"
      return 0
    else
      _mnre_last_rc=$?
    fi
    merv_ssh_fallback_allowed "${MERV_SSH_LAST_REASON:-}" || return "$_mnre_last_rc"
  done <<EOF
$_mnre_candidates
EOF
  return "$_mnre_last_rc"
}

# merv_ssh_stream_file <node> <ip> <local-file> <remote-path>
# Streams a verified local file to a node through the same host-key contract as
# command execution.  The remote rename is atomic and the temporary path is
# fixed by the caller, never derived from browser input.
merv_ssh_stream_file() {
  _mssf_node="$1"; _mssf_ip="$2"; _mssf_local="$3"; _mssf_remote="$4"
  [ -f "$_mssf_local" ] || [ "$_mssf_local" = "/dev/null" ] || return 1
  case "$_mssf_remote" in
    /*) ;;
    *) MERV_SSH_LAST_REASON="invalid-remote-path"; return 2 ;;
  esac
  case "$_mssf_remote" in *..*|*[!A-Za-z0-9_./-]*) MERV_SSH_LAST_REASON="invalid-remote-path"; return 2 ;; esac
  _mssf_ip=$(merv_node_resolve_endpoint "$_mssf_node" "$_mssf_ip") || return $?
  merv_ssh_precheck "$_mssf_node" "$_mssf_ip" || return $?
  if merv_ssh_precheck_cache_matches "$_mssf_node" "$_mssf_ip"; then
    _mssf_mac="$MERV_SSH_PRECHECK_MAC"; _mssf_port="$MERV_SSH_PRECHECK_PORT"; _mssf_user="$MERV_SSH_PRECHECK_USER"
  else
    _mssf_mac=$(merv_ssh_node_mac "$_mssf_node" 2>/dev/null) || return 6
    _mssf_port=$(get_node_ssh_port)
    _mssf_user=$(get_node_ssh_user)
  fi
  merv_ssh_prepare_known_host "$_mssf_node" "$_mssf_ip" "$_mssf_port" "$_mssf_mac" || { merv_ssh_release_known_host 2>/dev/null || :; return 5; }
  _mssf_rc=0
  if cat "$_mssf_local" | _merv_timeout_run "$MERV_SSH_TIMEOUT" \
      "${MERV_SSH_CLIENT:-dbclient}" -p "$_mssf_port" -i "$SSH_KEY" \
      "$_mssf_user@$_mssf_ip" "cat > '${_mssf_remote}.tmp' && mv '${_mssf_remote}.tmp' '${_mssf_remote}'" 2>/dev/null; then
    :
  else
    _mssf_rc=$?
  fi
  merv_ssh_release_known_host || { MERV_SSH_LAST_REASON="known-host-temp-cleanup-failed"; MERV_SSH_LAST_DETAIL="NODE${_mssf_node:-?} private SSH client home cleanup failed"; return 5; }
  [ "$_mssf_rc" -eq 0 ] && return 0
  MERV_SSH_LAST_REASON="stream-failed"
  MERV_SSH_LAST_DETAIL="NODE${_mssf_node:-?} verified SSH stream failed"
  return 5
}

merv_ssh_stream_stdin() {
  _msss_node="$1"; _msss_ip="$2"; _msss_cmd="$3"
  _msss_ip=$(merv_node_resolve_endpoint "$_msss_node" "$_msss_ip") || return $?
  merv_ssh_precheck "$_msss_node" "$_msss_ip" || return $?
  if merv_ssh_precheck_cache_matches "$_msss_node" "$_msss_ip"; then
    _msss_mac="$MERV_SSH_PRECHECK_MAC"; _msss_port="$MERV_SSH_PRECHECK_PORT"; _msss_user="$MERV_SSH_PRECHECK_USER"
  else
    _msss_mac=$(merv_ssh_node_mac "$_msss_node" 2>/dev/null) || return 6
    _msss_port=$(get_node_ssh_port)
    _msss_user=$(get_node_ssh_user)
  fi
  merv_ssh_prepare_known_host "$_msss_node" "$_msss_ip" "$_msss_port" "$_msss_mac" || { merv_ssh_release_known_host 2>/dev/null || :; return 5; }
  _msss_rc=0
  _merv_timeout_run "$MERV_SSH_TIMEOUT" "${MERV_SSH_CLIENT:-dbclient}" \
    -p "$_msss_port" -i "$SSH_KEY" "$_msss_user@$_msss_ip" "$_msss_cmd"
  _msss_rc=$?
  merv_ssh_release_known_host || { MERV_SSH_LAST_REASON="known-host-temp-cleanup-failed"; MERV_SSH_LAST_DETAIL="NODE${_msss_node:-?} private SSH client home cleanup failed"; return 5; }
  return "$_msss_rc"
}

merv_ssh_test() {
  # merv_ssh_test <node_num> <node_ip>
  # returns 0 if remote echo works
  _merv_test_out="$(merv_ssh_exec "$1" "$2" "echo connected" 2>/dev/null)"
  [ $? -eq 0 ] || return 1
  printf '%s\n' "$_merv_test_out" | grep -q "connected"
}

merv_ssh_skip_log() {
  # merv_ssh_skip_log <node_num> <node_ip> <context>
  _node_num="$1"; _node_ip="$2"; _context="$3"
  [ -n "$_context" ] || _context="ssh"

  if [ -n "$MERV_SSH_LAST_REASON" ]; then
    _merv_log_warn "Skipping $_context for NODE${_node_num:-?} ($_node_ip): $MERV_SSH_LAST_REASON — $MERV_SSH_LAST_DETAIL"
  else
    _merv_log_warn "Skipping $_context for NODE${_node_num:-?} ($_node_ip): unknown reason"
  fi
}

# Flag: settings loaded
LIB_SSH_LOADED=1
