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
#              - File: lib_ssh.sh || version="0.72.0"                       #
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
# SAFE SSH WRAPPERS — hard timeout + 3 retries + clear skip reasons          #
# ========================================================================== #

# Public knobs (can be overridden per script via env)
: "${MERV_SSH_RETRIES:=3}"          # MUST be 3 per requirement
: "${MERV_SSH_TIMEOUT:=10}"         # seconds per attempt (dbclient hard timeout)
: "${MERV_SSH_PING_TIMEOUT:=2}"     # seconds for ping -W
: "${MERV_SSH_RETRY_DELAY:=2}"      # seconds between attempts

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
        rmdir "$MERV_SSH_ERR_DIR" 2>/dev/null || :
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
  rm -f "${MERV_SSH_ERR_FILE:-}" 2>/dev/null || :
  rmdir "$MERV_SSH_ERR_DIR" 2>/dev/null || return 1
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
  for _mtst_pid in $MERV_TIMEOUT_TREE_PIDS; do
    case "$_mtst_pid" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$_mtst_root" ]; then
      _mtst_root="$_mtst_pid"
      continue
    fi
    kill "$_mtst_signal" "$_mtst_pid" 2>/dev/null || :
  done
  [ -n "$_mtst_root" ] && kill "$_mtst_signal" "$_mtst_root" 2>/dev/null || :
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
  : > "$_mtr_out" 2>/dev/null || { rmdir "$_mtr_dir" 2>/dev/null || :; return 125; }
  : > "$_mtr_err" 2>/dev/null || { rm -f "$_mtr_out"; rmdir "$_mtr_dir" 2>/dev/null || :; return 125; }
  "$@" <&9 >"$_mtr_out" 2>"$_mtr_err" &
  _mtr_pid=$!
  exec 9<&-
  (
    sleep "$seconds"
    _merv_timeout_collect_tree "$_mtr_pid" || :
    _merv_timeout_signal_tree -TERM
    # The command has already exceeded its deadline; do not add another
    # full BusyBox sleep interval before force-cleaning its descendants.
    _merv_timeout_signal_tree -KILL
  ) >/dev/null 2>&1 &
  _mtr_watchdog=$!
  wait "$_mtr_pid"
  _mtr_rc=$?
  kill "$_mtr_watchdog" 2>/dev/null || :
  wait "$_mtr_watchdog" 2>/dev/null || :
  cat "$_mtr_out" 2>/dev/null || :
  cat "$_mtr_err" >&2 || :
  rm -f "$_mtr_out" 2>/dev/null || :
  rm -f "$_mtr_err" 2>/dev/null || :
  rmdir "$_mtr_dir" 2>/dev/null || :
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
  HOME="$_mssh_home"
  export HOME
  MERV_SSH_HOME="$_mssh_home"
  export MERV_SSH_HOME
  return 0
}

merv_ssh_prepare_client_home || :

merv_ssh_precheck() {
  # merv_ssh_precheck <node_num> <node_ip>
  # returns:
  #   0 = ok
  #   2 = ssh keys missing
  #   3 = invalid ip
  #   4 = unreachable (ping)
  node_num="$1"
  node_ip="$2"

  MERV_SSH_LAST_REASON=""
  MERV_SSH_LAST_DETAIL=""

  if [ -z "$node_ip" ] || ! _merv_is_ipv4 "$node_ip"; then
    MERV_SSH_LAST_REASON="invalid-ip"
    MERV_SSH_LAST_DETAIL="NODE${node_num:-?} ip='$node_ip'"
    return 3
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

  # Fast reachability check
  if ! _merv_ping_ok "$node_ip"; then
    MERV_SSH_LAST_REASON="unreachable"
    MERV_SSH_LAST_DETAIL="NODE${node_num:-?} ip='$node_ip' not reachable via ping"
    return 4
  fi

  return 0
}

merv_ssh_exec() {
  # merv_ssh_exec <node_num> <node_ip> <remote_cmd>
  #
  # Behavior:
  # - Precheck (ip + keys + ping)
  # - 3 attempts total
  # - hard timeout per attempt
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
    return 0
  fi

  # Precheck once before retry loop; if unreachable, still retry (3 total) because LAN can be flaky
  _attempt=1
  while [ "$_attempt" -le "$MERV_SSH_RETRIES" ]; do
    merv_ssh_precheck "$_node_num" "$_node_ip"
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
      # If invalid ip or keys missing → do not retry (it won't improve)
      if [ "$_rc" -eq 2 ] || [ "$_rc" -eq 3 ]; then
        return "$_rc"
      fi
      # unreachable → retry up to 3 times
      if [ "$_attempt" -lt "$MERV_SSH_RETRIES" ]; then
        sleep "$MERV_SSH_RETRY_DELAY"
        _attempt=$((_attempt + 1))
        continue
      fi
      return 4
    fi

    # Build args (read fresh each time in case settings changed)
    _port="$(get_node_ssh_port)"
    _user="$(get_node_ssh_user)"
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
    _out=$(
      _merv_timeout_run "$MERV_SSH_TIMEOUT" \
        dbclient -p "$_port" -y -i "$SSH_KEY" \
        "$_user@$_node_ip" "$_remote_cmd" \
        </dev/null \
        2>"$_tmp"
    )
    _rc=$?
    _err=""
    _err=$(cat "$_tmp" 2>/dev/null)
    _merv_ssh_tmp_release || {
      MERV_SSH_LAST_REASON="ssh-tmp-cleanup-failed"
      MERV_SSH_LAST_DETAIL="NODE${_node_num:-?} isolated SSH stderr cleanup failed"
      return 5
    }

    if [ "$_rc" -eq 0 ]; then
      MERV_SSH_LAST_REASON=""
      MERV_SSH_LAST_DETAIL=""
      # Print stdout so callers can capture it if needed
      printf '%s' "$_out"
      return 0
    fi

    # Timeout(124) if BusyBox timeout was used
    if [ "$_rc" -eq 124 ]; then
      MERV_SSH_LAST_REASON="timeout"
      MERV_SSH_LAST_DETAIL="NODE${_node_num:-?} ip='$_node_ip' timed out after ${MERV_SSH_TIMEOUT}s (attempt $_attempt/$MERV_SSH_RETRIES)"
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
      elif [ "$_rc" -eq 126 ] || [ "$_rc" -eq 127 ]; then
        MERV_SSH_LAST_REASON="remote-cmd-failed"
        MERV_SSH_LAST_DETAIL="NODE${_node_num:-?} ip='$_node_ip' remote command exited rc=$_rc"
        # Missing remote files/binaries will not improve by retrying.
        return 5
      else
        MERV_SSH_LAST_REASON="ssh-failed"
        MERV_SSH_LAST_DETAIL="NODE${_node_num:-?} ip='$_node_ip' dbclient failed rc=$_rc (attempt $_attempt/$MERV_SSH_RETRIES)"
      fi
    fi

    if [ "$_attempt" -lt "$MERV_SSH_RETRIES" ]; then
      sleep "$MERV_SSH_RETRY_DELAY"
      _attempt=$((_attempt + 1))
      continue
    fi

    return 5
  done

  return 5
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
