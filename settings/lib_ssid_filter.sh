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
#               - File: lib_ssid_filter.sh || version="0.52"                   #
# ============================================================================ #
# - Purpose:    Node-scoped SSID/VLAN slot filtering for multi-node setups.    #
#               Determines which SSID slots are "visible" on the current node. #
# ============================================================================ #
[ -n "${LIB_SSID_FILTER_LOADED:-}" ] && return 0 2>/dev/null

# ============================================================================ #
# FILTER INITIALIZATION                                                        #
# Determines this node's assignment token (MAIN, NODE1..NODE10) based on        #
# NODE_ID from settings.json or environment. Must be called after NODE_ID      #
# is resolved.                                                                 #
# ============================================================================ #

# Cache for assignment token (MAIN, NODE1..NODE10)
_SSID_FILTER_TOKEN=""

# One-shot warning flag to avoid log spam when MAX_SSIDS=0
_SSID_FILTER_MAXSSIDS_WARNED=0

# Fatal condition flag — set to 1 if hardware profile not ready (MAX_SSIDS<1)
# Callers can check this after first accessor call to bail early with clear message
SSID_FILTER_FATAL=0
export SSID_FILTER_FATAL

# ssid_filter_init — Initialize the filter with current node identity
# Args: $1=node_id (optional, uses MERV_NODE_ID or NODE_ID if not provided)
# Returns: 0 always; sets _SSID_FILTER_TOKEN
ssid_filter_init() {
  _sf_nodeid="${1:-${MERV_NODE_ID:-${NODE_ID:-none}}}"
  
  case "$_sf_nodeid" in
    none|0|"")
      _SSID_FILTER_TOKEN="MAIN"
      ;;
    ''|*[!0-9]*)
      # Non-numeric NODE_ID; default to MAIN for safety
      _SSID_FILTER_TOKEN="MAIN"
      ;;
    *)
      if [ "$_sf_nodeid" -ge 1 ] 2>/dev/null && [ "$_sf_nodeid" -le "${MERV_MAX_NODES:-10}" ] 2>/dev/null; then
        _SSID_FILTER_TOKEN="NODE${_sf_nodeid}"
      else
        # Out-of-range NODE_ID; default to MAIN for safety
        _SSID_FILTER_TOKEN="MAIN"
      fi
      ;;
  esac
}

# ============================================================================ #
# CORE FILTER FUNCTION                                                         #
# Checks whether a given SSID slot is assigned to this node.                   #
# ============================================================================ #

# is_ssid_slot_allowed — Check if slot is assigned to this node
# Args: $1=slot_index (1-12, NOT zero-padded)
#       $2=settings_file (optional, defaults to SETTINGS_FILE)
# Returns: 0 if slot is allowed on this node, 1 if not
# Explanation: Reads SSIDassign_XX from settings.json. If the assignment
#   string contains this node's token (MAIN, NODE1..NODE<MERV_MAX_NODES>), returns 0.
#   If SSIDassign_XX is missing, defaults to MAIN-only assignment.
#   If SSIDassign_XX is exactly "none", slot is denied to all nodes.
is_ssid_slot_allowed() {
  _sf_slot="${1:-1}"
  _sf_file="${2:-${SETTINGS_FILE:-/jffs/addons/mervlan/settings/settings.json}}"
  
  # Validate slot is numeric (prevents garbage behavior)
  case "$_sf_slot" in
    ''|*[!0-9]*) return 1 ;;  # Non-numeric → deny
  esac
  
  # Validate MAX_SSIDS is sane; refuse to filter if hardware profile not ready
  _sf_max="${MAX_SSIDS:-0}"
  case "$_sf_max" in ''|*[!0-9]*) _sf_max=0 ;; esac
  if [ "$_sf_max" -lt 1 ] 2>/dev/null; then
    # Hardware profile not loaded — this is a fatal misconfiguration
    # Set global flag so callers can bail early with clear message
    SSID_FILTER_FATAL=1
    export SSID_FILTER_FATAL
    # Log loudly ONCE so users/devs know why nothing is applying (avoid spam)
    if [ "${_SSID_FILTER_MAXSSIDS_WARNED:-0}" -eq 0 ]; then
      _SSID_FILTER_MAXSSIDS_WARNED=1
      if type error >/dev/null 2>&1; then
        error -c vlan "SSID filter: MAX_SSIDS=$_sf_max; hardware profile not ready; refusing to filter"
      else
        echo "[ERROR] SSID filter: MAX_SSIDS=$_sf_max; hardware profile not ready; refusing to filter" >&2
      fi
    fi
    return 1
  fi
  
  # Slot out of range → deny
  [ "$_sf_slot" -ge 1 ] 2>/dev/null && [ "$_sf_slot" -le "$_sf_max" ] 2>/dev/null || return 1
  
  # Re-init token on each call to avoid boot race where NODE_ID wasn't set yet
  ssid_filter_init "${MERV_NODE_ID:-${NODE_ID:-none}}"
  
  # Zero-pad slot index
  _sf_key="$(printf 'SSIDassign_%02d' "$_sf_slot")"
  
  # Read assignment string from JSON
  # Try nested WiFi.SSIDassign structure first, fallback to flat key
  _sf_assign=""
  if type json_get_section2_value >/dev/null 2>&1; then
    _sf_assign="$(json_get_section2_value "WiFi" "SSIDassign" "$_sf_key" "$_sf_file" 2>/dev/null)"
  fi
  if [ -z "$_sf_assign" ]; then
    if type json_get_scalar >/dev/null 2>&1; then
      _sf_assign="$(json_get_scalar "$_sf_key" "$_sf_file" 2>/dev/null)"
    elif type json_get_flag >/dev/null 2>&1; then
      _sf_assign="$(json_get_flag "$_sf_key" "" "$_sf_file" 2>/dev/null)"
    fi
  fi
  
  # Handle missing vs explicit "none" assignment
  if [ -z "$_sf_assign" ]; then
    # Empty/missing: default to MAIN-only for backwards compatibility
    case "$_SSID_FILTER_TOKEN" in
      MAIN) return 0 ;;
      *)    return 1 ;;
    esac
  fi
  
  # Explicit "none" (not the comma-separated format) means "assigned nowhere"
  if [ "$_sf_assign" = "none" ]; then
    return 1  # Deny for ALL nodes including MAIN
  fi
  
  # Check if our token appears in the comma-separated list
  # Token can be: MAIN, NODE1..NODE10
  # Non-assignments are "none" in each position
  case ",$_sf_assign," in
    *,"$_SSID_FILTER_TOKEN",*)
      return 0  # Token found → allowed
      ;;
    *)
      return 1  # Token not found → not allowed
      ;;
  esac
}

# ============================================================================ #
# FILTERED VALUE ACCESSORS                                                     #
# Wrappers that return "filtered" values: if slot is not allowed, returns      #
# default placeholder values instead of actual config.                         #
# ============================================================================ #

# get_ssid_slot_value — Get SSID value, filtered by node assignment
# Args: $1=slot_index (1-12), $2=settings_file (optional)
# Returns: SSID string or "unused-placeholder" if not allowed
get_ssid_slot_value() {
  _gsv_slot="${1:-1}"
  _gsv_file="${2:-${SETTINGS_FILE:-/jffs/addons/mervlan/settings/settings.json}}"
  
  if ! is_ssid_slot_allowed "$_gsv_slot" "$_gsv_file"; then
    printf '%s\n' "unused-placeholder"
    return 0
  fi
  
  # Slot is allowed; return actual value
  _gsv_key="$(printf 'SSID_%02d' "$_gsv_slot")"
  _gsv_val=""
  # Try nested WiFi.SSIDs structure first
  if type json_get_section2_value >/dev/null 2>&1; then
    _gsv_val="$(json_get_section2_value "WiFi" "SSIDs" "$_gsv_key" "$_gsv_file" 2>/dev/null)"
  fi
  # Fallback to flat key
  if [ -z "$_gsv_val" ] || [ "$_gsv_val" = "unused-placeholder" ]; then
    if type json_get_scalar >/dev/null 2>&1; then
      _gsv_val="$(json_get_scalar "$_gsv_key" "$_gsv_file" 2>/dev/null)"
    elif type json_get_flag >/dev/null 2>&1; then
      _gsv_val="$(json_get_flag "$_gsv_key" "" "$_gsv_file" 2>/dev/null)"
    fi
  fi
  [ -z "$_gsv_val" ] && _gsv_val="unused-placeholder"
  printf '%s\n' "$_gsv_val"
}

# get_vlan_slot_value — Get VLAN ID value, filtered by node assignment
# Args: $1=slot_index (1-12), $2=settings_file (optional)
# Returns: VLAN ID or "none" if not allowed (treated as 0/untagged)
get_vlan_slot_value() {
  _gvv_slot="${1:-1}"
  _gvv_file="${2:-${SETTINGS_FILE:-/jffs/addons/mervlan/settings/settings.json}}"
  
  if ! is_ssid_slot_allowed "$_gvv_slot" "$_gvv_file"; then
    printf '%s\n' "none"
    return 0
  fi
  
  # Slot is allowed; return actual value
  _gvv_key="$(printf 'VLAN_%02d' "$_gvv_slot")"
  _gvv_val=""
  # Try nested VLAN.Pool structure first
  if type json_get_section2_value >/dev/null 2>&1; then
    _gvv_val="$(json_get_section2_value "VLAN" "Pool" "$_gvv_key" "$_gvv_file" 2>/dev/null)"
  fi
  # Fallback to flat key
  if [ -z "$_gvv_val" ] || [ "$_gvv_val" = "none" ]; then
    if type json_get_scalar >/dev/null 2>&1; then
      _gvv_val="$(json_get_scalar "$_gvv_key" "$_gvv_file" 2>/dev/null)"
    elif type json_get_flag >/dev/null 2>&1; then
      _gvv_val="$(json_get_flag "$_gvv_key" "" "$_gvv_file" 2>/dev/null)"
    fi
  fi
  [ -z "$_gvv_val" ] && _gvv_val="none"
  printf '%s\n' "$_gvv_val"
}

# get_apiso_slot_value — Get AP isolation value, filtered by node assignment
# Args: $1=slot_index (1-12), $2=settings_file (optional)
# Returns: APISO value or "0" if not allowed
get_apiso_slot_value() {
  _gav_slot="${1:-1}"
  _gav_file="${2:-${SETTINGS_FILE:-/jffs/addons/mervlan/settings/settings.json}}"
  
  if ! is_ssid_slot_allowed "$_gav_slot" "$_gav_file"; then
    printf '%s\n' "0"
    return 0
  fi
  
  # Slot is allowed; return actual value
  _gav_key="$(printf 'APISO_%02d' "$_gav_slot")"
  _gav_val=""
  # Try nested WiFi.APISO structure first
  if type json_get_section2_value >/dev/null 2>&1; then
    _gav_val="$(json_get_section2_value "WiFi" "APISO" "$_gav_key" "$_gav_file" 2>/dev/null)"
  fi
  # Fallback to flat key
  if [ -z "$_gav_val" ]; then
    if type json_get_scalar >/dev/null 2>&1; then
      _gav_val="$(json_get_scalar "$_gav_key" "$_gav_file" 2>/dev/null)"
    elif type json_get_flag >/dev/null 2>&1; then
      _gav_val="$(json_get_flag "$_gav_key" "" "$_gav_file" 2>/dev/null)"
    fi
  fi
  [ -z "$_gav_val" ] && _gav_val="0"
  printf '%s\n' "$_gav_val"
}

LIB_SSID_FILTER_LOADED=1
# ========================= end of lib_ssid_filter ============================
