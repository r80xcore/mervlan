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
#                   - File: hw_probe.sh || version="0.51"                      #
# ============================================================================ #
# - Purpose:  Probe system hardware and record hardware keys in the central    #
#             settings store (settings.json). Writes non-destructively via     #
#             json_set_flag so values remain compatible with legacy top-level  #
#             keys and the newer Hardware block in settings.json.              #
# ============================================================================ #
#                                                                              #
# ================================================== MerVLAN environment setup #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_JSON_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh"
# =========================================== End of MerVLAN environment setup #

# ============================================================================ #
#                      HARDWARE DETECTION & PROBING                            #
# Detect system hardware (router model, wireless radios, ethernet ports) and   #
# probe nvram for radio capabilities. Build comprehensive hardware profile.    #
# ============================================================================ #

# ============================================================================ #
#                         PRE-DETECTION VALIDATION                             #
# Verify nvram is available (indicates Asuswrt-Merlin environment) and         #
# retrieve product ID to identify router model.                                #
# ============================================================================ #

# Ensure nvram command works (Asuswrt-Merlin requirement)
if ! nvram get productid >/dev/null 2>&1; then
    error "nvram command not found or not working - not on Asuswrt-Merlin?"
fi

# Retrieve product ID from nvram (used for model-specific detection)
PRODUCTID=$(nvram get productid)
[ -z "$PRODUCTID" ] && error "Could not get productid"

# ============================================================================ #
#                     WIRELESS RADIO DETECTION & ENUMERATION                   #
# Detect all wireless radios (2.4GHz, 5GHz-1, 5GHz-2) by checking nvram for    #
# interface names and validating presence in /sys/class/net. Count guest       #
# SSID slots per radio to determine maximum SSID capacity.                     #
# ============================================================================ #

# Initialize radio tracking variables
RADIOS=""
GUEST_SLOTS=0
MAX_SSIDS=0

# AiMesh nodes remap wl interfaces to ethX; bypass /sys/class/net check for them
is_node=$(nvram get re_mode 2>/dev/null)

# Iterate through radio indices 0, 1, 2 (potential radio slots on Merlin)
for radio in 0 1 2; do
    # Retrieve interface name from nvram (e.g., wl0_ifname, wl1_ifname, wl2_ifname)
    ifname=$(nvram get "wl${radio}_ifname" 2>/dev/null)
    # Verify interface exists in kernel (or bypass check for AiMesh nodes)
    if [ -n "$ifname" ] && { [ "$is_node" = "1" ] || [ -d "/sys/class/net/$ifname" ]; }; then
        # Map radio index to band name
        case $radio in
            0) band="2.4" ;;      # 2.4 GHz band
            1) band="5g-1" ;;     # 5 GHz primary
            2) band="5g-2" ;;     # 5 GHz secondary (tri-band)
        esac
        RADIOS="$RADIOS $band"

        # Count guest SSID slots on this radio (slots 1–3 are guests; slot 0 is primary)
        radio_guests=0
        for slot in 1 2 3; do
            ssid=$(nvram get "wl${radio}.${slot}_ssid" 2>/dev/null)
            [ -n "$ssid" ] && radio_guests=$((radio_guests + 1))
        done
        # Track maximum guest slots across all radios
        [ $radio_guests -gt $GUEST_SLOTS ] && GUEST_SLOTS=$radio_guests

        # Total SSIDs = 1 primary + all guest slots per radio
        MAX_SSIDS=$((MAX_SSIDS + 1 + radio_guests))
    fi
done

# Clean leading space from RADIOS list
RADIOS=$(echo $RADIOS | sed 's/^ //')
# Default to typical tri-band if no radios detected
[ -z "$RADIOS" ] && RADIOS="2.4 5g-1 5g-2"
# Default to 3 guest slots if none detected
[ $GUEST_SLOTS -eq 0 ] && GUEST_SLOTS=3
# Default to 12 SSIDs if none calculated
[ $MAX_SSIDS -eq 0 ] && MAX_SSIDS=12
# Cap at 12 SSIDs maximum (firmware limit)
[ $MAX_SSIDS -gt 12 ] && MAX_SSIDS=12

# ============================================================================ #
#                     HARDWARE OVERRIDE – IDENTITY & VALIDATION                #
# Read device identity (IS_NODE / NODE_ID) and manual port mapping override    #
# from Hardware_Override section in settings.json. If a valid override is      #
# enabled for this device, it replaces the normal model-based port detection.  #
# ============================================================================ #

USE_MAP_OVERRIDE=0

# Read device identity from General section
_OVR_IS_NODE=$(json_get_section_value "General" "IS_NODE" "$SETTINGS_FILE" 2>/dev/null)
_OVR_NODE_ID=$(json_get_section_value "General" "NODE_ID" "$SETTINGS_FILE" 2>/dev/null)

# Determine override target key
if [ "$_OVR_IS_NODE" = "1" ]; then
  case "$_OVR_NODE_ID" in
    1|2|3|4|5) _OVR_TARGET="NODE${_OVR_NODE_ID}" ;;
    *) _OVR_TARGET="MAIN" ;;
  esac
else
  _OVR_TARGET="MAIN"
fi

# Read override values for resolved target via two-level nested JSON helper
_ovr_get() { json_get_section2_value "Hardware_Override" "$_OVR_TARGET" "$1" "$SETTINGS_FILE" 2>/dev/null; }

OVERRIDE_MAP=$(_ovr_get "MAP_OVERRIDE")
[ -z "$OVERRIDE_MAP" ] && OVERRIDE_MAP="0"

if [ "$OVERRIDE_MAP" = "1" ]; then
  OVERRIDE_WAN=$(_ovr_get "OVERRIDE_WAN")
  OVERRIDE_MAX_ETH_PORTS=$(_ovr_get "OVERRIDE_MAX_ETH_PORTS")
  [ -z "$OVERRIDE_WAN" ] && OVERRIDE_WAN="eth0"
  [ -z "$OVERRIDE_MAX_ETH_PORTS" ] && OVERRIDE_MAX_ETH_PORTS="0"

  # Read LAN slot values
  _ovr_i=1
  while [ "$_ovr_i" -le 8 ]; do
    eval "OVERRIDE_LAN${_ovr_i}=\"\$(_ovr_get \"OVERRIDE_LAN${_ovr_i}\")\""
    eval "[ -z \"\$OVERRIDE_LAN${_ovr_i}\" ] && OVERRIDE_LAN${_ovr_i}=\"none\""
    _ovr_i=$((_ovr_i + 1))
  done

  # Trim whitespace from all override values
  OVERRIDE_WAN=$(echo "$OVERRIDE_WAN" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  _ovr_i=1
  while [ "$_ovr_i" -le 8 ]; do
    eval "OVERRIDE_LAN${_ovr_i}=\$(echo \"\$OVERRIDE_LAN${_ovr_i}\" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    _ovr_i=$((_ovr_i + 1))
  done

  # Validate override
  _ovr_valid=1
  _ovr_reason=""

  # MAX must be numeric 0-8
  case "$OVERRIDE_MAX_ETH_PORTS" in
    0|1|2|3|4|5|6|7|8) ;;
    *) _ovr_valid=0; _ovr_reason="MAX_ETH_PORTS '$OVERRIDE_MAX_ETH_PORTS' is not 0-8" ;;
  esac

  # WAN must be non-empty after trim
  if [ "$_ovr_valid" = "1" ] && [ -z "$OVERRIDE_WAN" ]; then
    _ovr_valid=0
    _ovr_reason="OVERRIDE_WAN is empty"
  fi

  # When MAX > 0, validate active LAN slots
  if [ "$_ovr_valid" = "1" ] && [ "$OVERRIDE_MAX_ETH_PORTS" -gt 0 ]; then
    _ovr_i=1
    while [ "$_ovr_i" -le "$OVERRIDE_MAX_ETH_PORTS" ] && [ "$_ovr_valid" = "1" ]; do
      eval "_ovr_lanval=\$OVERRIDE_LAN${_ovr_i}"
      if [ -z "$_ovr_lanval" ] || [ "$_ovr_lanval" = "none" ]; then
        _ovr_valid=0
        _ovr_reason="OVERRIDE_LAN${_ovr_i} is empty or none"
      fi
      _ovr_i=$((_ovr_i + 1))
    done
  fi

  # Duplicate check across WAN + active LAN slots (only when MAX > 0)
  if [ "$_ovr_valid" = "1" ] && [ "$OVERRIDE_MAX_ETH_PORTS" -gt 0 ]; then
    _ovr_all_ifaces="$OVERRIDE_WAN"
    _ovr_i=1
    while [ "$_ovr_i" -le "$OVERRIDE_MAX_ETH_PORTS" ]; do
      eval "_ovr_lanval=\$OVERRIDE_LAN${_ovr_i}"
      _ovr_all_ifaces="$_ovr_all_ifaces $_ovr_lanval"
      _ovr_i=$((_ovr_i + 1))
    done
    _ovr_unique_count=$(echo "$_ovr_all_ifaces" | tr ' ' '\n' | sort -u | wc -l)
    _ovr_total_count=$(echo "$_ovr_all_ifaces" | tr ' ' '\n' | wc -l)
    if [ "$_ovr_unique_count" -ne "$_ovr_total_count" ]; then
      _ovr_valid=0
      _ovr_reason="duplicate interfaces detected"
    fi
  fi

  if [ "$_ovr_valid" = "1" ]; then
    USE_MAP_OVERRIDE=1
    info "Hardware override enabled for $_OVR_TARGET"
  else
    warn "Hardware override for $_OVR_TARGET failed validation: $_ovr_reason — using normal detection"
  fi
fi

# ============================================================================ #
#                        MODEL-SPECIFIC PORT DETECTION                         #
# Map product ID to specific router model and assign ethernet port layout      #
# (interface names and labels). Models with native VLAN GUI skip port override.#
# ============================================================================ #
if [ "$USE_MAP_OVERRIDE" = "1" ]; then
  # Override mode: use manual port mapping instead of model detection
  MODEL="CUSTOM"
  WAN_IF="$OVERRIDE_WAN"
  MAX_ETH_PORTS="$OVERRIDE_MAX_ETH_PORTS"
  ETH_PORTS=""
  LAN_PORT_LABELS=""
  if [ "$MAX_ETH_PORTS" -gt 0 ]; then
    _ovr_i=1
    while [ "$_ovr_i" -le "$MAX_ETH_PORTS" ]; do
      eval "_ovr_lanval=\$OVERRIDE_LAN${_ovr_i}"
      ETH_PORTS="$ETH_PORTS $_ovr_lanval"
      LAN_PORT_LABELS="$LAN_PORT_LABELS LAN${_ovr_i}"
      _ovr_i=$((_ovr_i + 1))
    done
    ETH_PORTS=$(echo $ETH_PORTS | sed 's/^ //')
    LAN_PORT_LABELS=$(echo $LAN_PORT_LABELS | sed 's/^ //')
  fi
else
case "$PRODUCTID" in
# === Supported Models ===

GT-AX6000) MODEL="GT-AX6000"; ETH_PORTS="eth4 eth3 eth2 eth1 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
RT-AX95Q) MODEL="RT-AX95Q"; ETH_PORTS="eth1 eth2 eth3"; LAN_PORT_LABELS="LAN1 LAN2 LAN3"; MAX_ETH_PORTS=3; WAN_IF="eth0" ;;
RT-AXE95Q) MODEL="RT-AXE95Q"; ETH_PORTS="eth1 eth2 eth3"; LAN_PORT_LABELS="LAN1 LAN2 LAN3"; MAX_ETH_PORTS=3; WAN_IF="eth0" ;;
RT-ET8)   MODEL="RT-ET8"; ETH_PORTS="eth1 eth2 eth3"; LAN_PORT_LABELS="LAN1 LAN2 LAN3"; MAX_ETH_PORTS=3; WAN_IF="eth0" ;;
RT-AX58U) MODEL="RT-AX58U"; ETH_PORTS="eth3 eth2 eth1 eth0"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth4" ;;
RT-AX82U) MODEL="RT-AX82U"; ETH_PORTS="eth3 eth2 eth1 eth0"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth4" ;;
RT-AX5400) MODEL="RT-AX5400"; ETH_PORTS="eth3 eth2 eth1 eth0"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth4" ;;
RT-AX86S) MODEL="RT-AX86S"; ETH_PORTS="eth4 eth3 eth2 eth1"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
RT-AX92U) MODEL="RT-AX92U"; ETH_PORTS="eth4 eth3 eth2 eth1"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
RT-AC86U) MODEL="RT-AC86U"; ETH_PORTS="eth4 eth3 eth2 eth1"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
TUF-AX3000_V2) MODEL="TUF-AX3000_V2"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
RT-AX86U) MODEL="RT-AX86U"; ETH_PORTS="eth4 eth3 eth2 eth1 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
RT-AX86U_PRO) MODEL="RT-AX86U_PRO"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
RT-AX88U) MODEL="RT-AX88U"; ETH_PORTS="eth4 eth3 eth2 eth1 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
RT-BE92U) MODEL="RT-BE92U"; ETH_PORTS="eth1"; LAN_PORT_LABELS="LAN1"; MAX_ETH_PORTS=1; WAN_IF="eth0" ;;


# === Models that needs port layout testing/verification ===
#RT-AX68U) MODEL="RT-AX68U"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
#RT-AX3000) MODEL="RT-AX3000"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
#RT-AX82U)   MODEL="RT-AX82U"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
#TUF-AX5400) MODEL="TUF-AX5400"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
#TUF-AX3000) MODEL="TUF-AX3000"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
#RT-AX92U) MODEL="RT-AX92U"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
#DSL-AC68U) MODEL="DSL-AC68U"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
#DSL-AX82U|DSL-AX5400) MODEL="DSL-AX82/5400"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
#RT-AC88U)  MODEL="RT-AC88U"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5 LAN6 LAN7 LAN8"; MAX_ETH_PORTS=8; WAN_IF="eth0" ;;
#RT-AC5300) MODEL="RT-AC5300"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
#RT-AC3100) MODEL="RT-AC3100"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
#TUF-AX5400) MODEL="TUF-AX5400"; ETH_PORTS="eth0 eth1 eth2 eth3"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth4" ;;
#GT-AX11000) MODEL="GT-AX11000"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
#GT-AXE11000) MODEL="GT-AXE11000"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
#XT12) MODEL="XT12"; ETH_PORTS="eth1 eth2 eth3"; LAN_PORT_LABELS="LAN1 LAN2 LAN3"; MAX_ETH_PORTS=3; WAN_IF="eth0" ;;
#GT-AX11000_PRO) MODEL="GT-AX11000_PRO"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
#GT-AXE16000) MODEL="GT-AXE16000"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5 eth6"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5 LAN6"; MAX_ETH_PORTS=6; WAN_IF="eth0" ;;
#RT-AX86U_PRO) MODEL="RT-AX86U_PRO"; ETH_PORTS="eth5 eth4 eth3 eth2 eth1"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
#RT-AX88U_PRO) MODEL="RT-AX88U_PRO"; ETH_PORTS="eth5 eth4 eth3 eth2 eth1"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
#RT-BE96U) MODEL="RT-BE96U"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
#GT-BE98_PRO) MODEL="GT-BE98_PRO"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5 eth6"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5 LAN6"; MAX_ETH_PORTS=6; WAN_IF="eth0" ;;
#RT-BE86U) MODEL="RT-BE86U"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
#RT-BE88U) MODEL="RT-BE88U"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8 eth9"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5 LAN6 LAN7 LAN8 LAN9"; MAX_ETH_PORTS=9; WAN_IF="eth0" ;;
#RT-BE7200) MODEL="RT-BE7200"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8 eth9"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5 LAN6 LAN7 LAN8 LAN9"; MAX_ETH_PORTS=9; WAN_IF="eth0" ;;
#RT-BE92U) MODEL="RT-BE92U"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
#GT-BE98) MODEL="GT-BE98"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5 eth6"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5 LAN6"; MAX_ETH_PORTS=6; WAN_IF="eth0" ;;

# === Custom Support Mapper ===
# DEVICE_SUPPORT_MAPPER_PLACEHOLDER

# === Fallback for Unknown Models ===
# Attempt to auto-detect ethernet ports by scanning /sys/class/net. If fewer
# than 4 ports found, default to 4 ports (common minimum). Cap SSID count.
    *)
        MODEL="UNSUPPORTED"
        ETH_PORTS="eth1 eth2 eth3"
        LAN_PORT_LABELS="LAN1 LAN2 LAN3"
        MAX_ETH_PORTS=3
        # Default SSID cap for unknown models
        MAX_SSIDS=3
        WAN_IF="eth0"
        ;;
esac
fi

# ============================================================================ #
#                        WAN INTERFACE VALIDATION                              #
# Verify WAN interface exists; fallback to nvram if default not found.         #
# ============================================================================ #

# Ensure WAN_IF exists in kernel; fallback to nvram wan_ifname if not
[ ! -d "/sys/class/net/$WAN_IF" ] && WAN_IF=$(nvram get wan_ifname 2>/dev/null)

# ============================================================================ #
#                     RECORD hardware into settings.json (Hardware block)      #
# Use json_set_flag to update the consolidated `settings.json` file non-       #
# destructively. Hardware keys are stored under the "Hardware" section in    #
# `settings.json`.                                                            #
# ============================================================================ #

# determine target JSON file (HW_SETTINGS_FILE is an alias to settings.json)
HW_TARGET="${HW_SETTINGS_FILE:-${SETTINGS_FILE}}"

info "Writing hardware profile into: $HW_TARGET (Hardware section)"

# Ensure the store exists before attempting changes
ensure_json_store "$HW_TARGET" || {
    error "Unable to create or access $HW_TARGET"
    exit 1
}

# --- helper: write array values safely into JSON ---
# JSON array writing delegated to lib_json.sh via json_set_array

# Scalars -> stored as strings for compatibility
json_set_flag "MODEL" "$MODEL" "$HW_TARGET" || warn "Failed to write MODEL"
json_set_flag "PRODUCTID" "$PRODUCTID" "$HW_TARGET" || warn "Failed to write PRODUCTID"
json_set_flag "MAX_SSIDS" "${MAX_SSIDS}" "$HW_TARGET" || warn "Failed to write MAX_SSIDS"
json_set_flag "GUEST_SLOTS" "${GUEST_SLOTS}" "$HW_TARGET" || warn "Failed to write GUEST_SLOTS"
json_set_flag "WAN_IF" "$WAN_IF" "$HW_TARGET" || warn "Failed to write WAN_IF"
json_set_flag "MAX_ETH_PORTS" "${MAX_ETH_PORTS}" "$HW_TARGET" || warn "Failed to write MAX_ETH_PORTS"

# Lists: store as space-separated strings for later parsing
json_set_array "RADIOS" "$RADIOS" "$HW_TARGET" || warn "Failed to write RADIOS"
json_set_array "ETH_PORTS" "$ETH_PORTS" "$HW_TARGET" || warn "Failed to write ETH_PORTS"
json_set_array "LAN_PORT_LABELS" "$LAN_PORT_LABELS" "$HW_TARGET" || warn "Failed to write LAN_PORT_LABELS"

# ============================================================================ #
#            NODE OVERRIDE PROPAGATION (main router only)                      #
# When running on the main router, check each node's override and update       #
# MAX_ETH_PORTS_NODEn in the Hardware section so the UI reflects overrides     #
# without needing a full sync_nodes run.                                       #
# ============================================================================ #
if [ "$_OVR_IS_NODE" != "1" ]; then
  _node_i=1
  while [ "$_node_i" -le 5 ]; do
    _nod_map=$(json_get_section2_value "Hardware_Override" "NODE${_node_i}" "MAP_OVERRIDE" "$HW_TARGET" 2>/dev/null)
    if [ "$_nod_map" = "1" ]; then
      _nod_max=$(json_get_section2_value "Hardware_Override" "NODE${_node_i}" "OVERRIDE_MAX_ETH_PORTS" "$HW_TARGET" 2>/dev/null)
      [ -z "$_nod_max" ] && _nod_max="0"
      case "$_nod_max" in
        0|1|2|3|4|5|6|7|8)
          if json_set_section_value "Hardware" "MAX_ETH_PORTS_NODE${_node_i}" "$_nod_max" "$HW_TARGET"; then
            info "Override: MAX_ETH_PORTS_NODE${_node_i}=$_nod_max"
          else
            warn "Failed to write override MAX_ETH_PORTS_NODE${_node_i}"
          fi
          ;;
        *) warn "Override NODE${_node_i} MAX_ETH_PORTS '$_nod_max' invalid (not 0-8), skipping" ;;
      esac
    fi
    _node_i=$((_node_i + 1))
  done
fi

# ============================================================================ #
#                           REPORT & DEBUG OUTPUT                              #
# Display detected hardware configuration and list all available ethernet      #
# interfaces for troubleshooting.                                              #
# ============================================================================ #

# Log detected hardware configuration
info "Hardware detection complete:"
echo "  Model: $MODEL ($PRODUCTID)"
echo "  Radios: $RADIOS"
echo "  Guest slots per radio: $GUEST_SLOTS"
echo "  Max SSIDs: $MAX_SSIDS"
echo "  Ethernet ports: $ETH_PORTS"
echo "  Labels: $LAN_PORT_LABELS"
echo "  WAN interface: $WAN_IF"
echo "  Output: $HW_TARGET (Hardware section in settings.json)"

echo ""
# Debug output: list all detected ethernet interfaces for verification
echo "=== Debug: All detected interfaces ==="
ls /sys/class/net/ | grep -E '^eth[0-9]' | sort