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
#                   - File: hw_probe.sh || version="0.60"                      #
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
[ -n "${LIB_RADIO_LOADED:-}" ] || . "$MERV_BASE/settings/lib_radio.sh"
[ -n "${LIB_ACTION_ACK_LOADED:-}" ] || . "$MERV_BASE/settings/lib_action_ack.sh" 2>/dev/null || :
[ -n "${LIB_MERVQT_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mervqt.sh" 2>/dev/null || :
if [ -f "$MERV_BASE/settings/lib_update_state.sh" ]; then
    . "$MERV_BASE/settings/lib_update_state.sh" 2>/dev/null || exit 75
fi
[ -n "${LIB_SETTINGS_RECONCILE_LOADED:-}" ] || \
    . "$MERV_BASE/settings/lib_settings_reconcile.sh" 2>/dev/null || :
# =========================================== End of MerVLAN environment setup #

# APMO may pass a verified request token as the first argument. The normal
# tokenless probe remains compatible with boot and legacy callers.
ACTION_REQUEST_TOKEN="${1:-}"
HW_PROBE_ACTION="hwprobe_vlanmgr"

hw_probe_ack_exit() {
    _hp_rc=$?
    trap - EXIT
    if [ -n "$ACTION_REQUEST_TOKEN" ] && type action_ack_ok >/dev/null 2>&1; then
        if [ "$_hp_rc" -eq 0 ]; then
            action_ack_ok "$ACTION_REQUEST_TOKEN" "$HW_PROBE_ACTION" '{}' \
                "Hardware profile refresh complete" '[]' || :
        else
            action_ack_error "$ACTION_REQUEST_TOKEN" "$HW_PROBE_ACTION" '{}' \
                "Hardware profile refresh failed" '[]' "HW_PROBE_FAILED" || :
        fi
    fi
    exit "$_hp_rc"
}
trap 'hw_probe_ack_exit' EXIT

if type merv_update_mutation_blocked >/dev/null 2>&1 &&
   merv_update_mutation_blocked; then
    error "Hardware profile refresh refused while Update maintenance is active"
    exit 75
fi

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
RADIO_INDEXES=""
GUEST_SLOTS=0
MAX_SSIDS=0

# AiMesh nodes remap wl interfaces to ethX; bypass /sys/class/net check for them
is_node=$(nvram get re_mode 2>/dev/null)

# Determine guest slot limit from Limits section (default 3)
GUEST_SLOTS_LIMIT=$(merv_guest_slots_per_radio "$SETTINGS_FILE")

# Iterate through radio indices 0..15 to support tri-band and quad-band hardware
radio=0
while [ "$radio" -le 15 ]; do
    # Retrieve interface name from nvram (e.g., wl0_ifname, wl1_ifname, ...)
    ifname=$(nvram get "wl${radio}_ifname" 2>/dev/null)
    # Verify interface exists in kernel (or bypass check for AiMesh nodes)
    if [ -n "$ifname" ] && { [ "$is_node" = "1" ] || [ -d "/sys/class/net/$ifname" ]; }; then
        # Map radio index to band name
        case $radio in
            0) band="2.4" ;;      # 2.4 GHz band
            1) band="5g-1" ;;     # 5 GHz primary
            2) band="5g-2" ;;     # 5 GHz secondary (tri-band)
            3) band="5g-3" ;;     # 5 GHz tertiary / quad-band
            *) band="radio${radio}" ;; # generic label for higher indices
        esac
        RADIOS="$RADIOS $band"
        RADIO_INDEXES="$RADIO_INDEXES $radio"

        # Capacity is 1 primary + GUEST_SLOTS_LIMIT per radio regardless of
        # whether guest SSID names are currently populated.  Counting only
        # non-empty nvram values would under-report capacity on routers where
        # guest SSIDs are configured but left with default empty names.
        MAX_SSIDS=$((MAX_SSIDS + 1 + GUEST_SLOTS_LIMIT))

        # Separately count populated guest slots for the GUEST_SLOTS diagnostic
        # value (informational; used to describe the current NVRAM state).
        radio_guests=0
        _slot=1
        while [ "$_slot" -le "$GUEST_SLOTS_LIMIT" ]; do
            ssid=$(nvram get "wl${radio}.${_slot}_ssid" 2>/dev/null)
            [ -n "$ssid" ] && radio_guests=$((radio_guests + 1))
            _slot=$((_slot + 1))
        done
        # Track maximum populated guest slots across all radios
        [ $radio_guests -gt $GUEST_SLOTS ] && GUEST_SLOTS=$radio_guests
    fi
    radio=$((radio + 1))
done

# Clean leading spaces from lists
RADIOS=$(echo $RADIOS | sed 's/^ //')
RADIO_INDEXES=$(echo $RADIO_INDEXES | sed 's/^ //')
# Default to typical tri-band if no radios detected
[ -z "$RADIOS" ] && RADIOS="2.4 5g-1 5g-2"
[ -z "$RADIO_INDEXES" ] && RADIO_INDEXES="0 1 2"
# Default to 3 guest slots if none detected
[ $GUEST_SLOTS -eq 0 ] && GUEST_SLOTS=3
# Default to 12 SSIDs if none calculated
[ $MAX_SSIDS -eq 0 ] && MAX_SSIDS=12
# Cap at Limits.MAX_SSID_CAP (default 16) — replaces the old hardcoded 12 ceiling
MAX_SSIDS=$(merv_cap_ssids "$MAX_SSIDS" "$SETTINGS_FILE")

# ============================================================================ #
#                     HARDWARE OVERRIDE – IDENTITY & VALIDATION                #
# Read device identity (IS_NODE / NODE_ID) and manual port mapping override    #
# from Hardware_Override section in settings.json. If a valid override is      #
# enabled for this device, it replaces the normal model-based port detection.  #
# ============================================================================ #

USE_MAP_OVERRIDE=0
LAN_PORT_LABEL_OVERRIDES=""

# Read device identity from General section
_OVR_IS_NODE=$(json_get_section_value "General" "IS_NODE" "$SETTINGS_FILE" 2>/dev/null)
_OVR_NODE_ID=$(json_get_section_value "General" "NODE_ID" "$SETTINGS_FILE" 2>/dev/null)

# Determine override target key
if [ "$_OVR_IS_NODE" = "1" ]; then
  if merv_is_valid_node_id "$_OVR_NODE_ID" 2>/dev/null; then
    _OVR_TARGET="NODE${_OVR_NODE_ID}"
  else
    _OVR_TARGET="MAIN"
  fi
else
  _OVR_TARGET="MAIN"
fi

# The CLI is an operator-facing action summary.  Keep the detailed probe
# record in the VLAN log, where it remains available for troubleshooting.
info -c cli "Refreshing hardware profile for $_OVR_TARGET..."
info -c vlan "Hardware probe target: $_OVR_TARGET"

# Only a verified APMO request is part of the serialized MAIN Save/probe
# transaction. Boot and legacy tokenless probes retain their historical local
# behavior and never create a MAIN-to-node synchronization obligation here.
_hp_reconcile_capture=no
_hp_reconcile_before=""
if [ "$_OVR_IS_NODE" != "1" ] && [ -n "$ACTION_REQUEST_TOKEN" ] && \
   type merv_settings_node_sync_digest >/dev/null 2>&1; then
  _hp_reconcile_before=$(merv_settings_node_sync_digest "$SETTINGS_FILE" 2>/dev/null || printf '')
  [ -n "$_hp_reconcile_before" ] && _hp_reconcile_capture=yes
fi

# Read override values for resolved target via two-level nested JSON helper
_ovr_get() { json_get_section2_value "Hardware_Override" "$_OVR_TARGET" "$1" "$SETTINGS_FILE" 2>/dev/null; }

OVERRIDE_MAP=$(_ovr_get "MAP_OVERRIDE")
if [ -z "$OVERRIDE_MAP" ]; then
  warn "Hardware override MAP_OVERRIDE is missing or unreadable for $_OVR_TARGET; using normal detection"
  OVERRIDE_MAP="0"
fi

case "$OVERRIDE_MAP" in
  0|1) ;;
  *)
    warn "Hardware override MAP_OVERRIDE '$OVERRIDE_MAP' is invalid for $_OVR_TARGET; using normal detection"
    OVERRIDE_MAP="0"
    ;;
esac

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
  LAN_PORT_LABEL_OVERRIDES=""
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
GT-BE98) MODEL="GT-BE98"; ETH_PORTS="eth1 eth2 eth3"; LAN_PORT_LABELS="LAN1 LAN5 LAN6"; LAN_PORT_LABEL_OVERRIDES="1=2.5G_LAN1-4_(shared)"; MAX_ETH_PORTS=3; WAN_IF="eth0" ;;
RT-AX95Q) MODEL="RT-AX95Q"; ETH_PORTS="eth1 eth2 eth3"; LAN_PORT_LABELS="LAN1 LAN2 LAN3"; MAX_ETH_PORTS=3; WAN_IF="eth0" ;;
RT-AXE95Q) MODEL="RT-AXE95Q"; ETH_PORTS="eth1 eth2 eth3"; LAN_PORT_LABELS="LAN1 LAN2 LAN3"; MAX_ETH_PORTS=3; WAN_IF="eth0" ;;
RT-ET8)   MODEL="RT-ET8"; ETH_PORTS="eth1 eth2 eth3"; LAN_PORT_LABELS="LAN1 LAN2 LAN3"; MAX_ETH_PORTS=3; WAN_IF="eth0" ;;
RT-AX58U) MODEL="RT-AX58U"; ETH_PORTS="eth3 eth2 eth1 eth0"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth4" ;;
RT-AX56U) MODEL="RT-AX56U"; ETH_PORTS="eth4 eth3 eth2 eth1"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
RT-AX68U) MODEL="RT-AX68U"; ETH_PORTS="eth4 eth3 eth2 eth1"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
RT-AX82U) MODEL="RT-AX82U"; ETH_PORTS="eth3 eth2 eth1 eth0"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth4" ;;
DSL-AX82U) MODEL="DSL-AX82U"; ETH_PORTS="eth2 eth1 eth0"; LAN_PORT_LABELS="LAN1 LAN2 LAN3"; MAX_ETH_PORTS=3; WAN_IF="eth3" ;;
RT-AX5400) MODEL="RT-AX5400"; ETH_PORTS="eth3 eth2 eth1 eth0"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth4" ;;
RT-AX92U) MODEL="RT-AX92U"; ETH_PORTS="eth4 eth3 eth2 eth1"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
RT-AC86U) MODEL="RT-AC86U"; ETH_PORTS="eth4 eth3 eth2 eth1"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
TUF-AX3000_V2) MODEL="TUF-AX3000_V2"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
RT-AX86U|RT-AX86S)
    _ax86_odmpid=$(nvram get odmpid 2>/dev/null)
    case "$PRODUCTID:$_ax86_odmpid" in
        RT-AX86S:*|RT-AX86U:RT-AX86S*) MODEL="RT-AX86S"; ETH_PORTS="eth4 eth3 eth2 eth1"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
        *)                              MODEL="RT-AX86U"; ETH_PORTS="eth4 eth3 eth2 eth1 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
    esac ;;
RT-AX86U_PRO) MODEL="RT-AX86U_PRO"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
RT-AX88U) MODEL="RT-AX88U"; ETH_PORTS="eth4 eth3 eth2 eth1 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
RT-AX88U_PRO) MODEL="RT-AX88U_PRO"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
RT-BE88U) MODEL="RT-BE88U"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5 LAN6 LAN7 LAN8"; MAX_ETH_PORTS=8; WAN_IF="eth0" ;;
RT-BE86U) MODEL="RT-BE86U"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; LAN_PORT_LABEL_OVERRIDES="1=LAN1_2.5G"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
RT-BE92U) MODEL="RT-BE92U"; ETH_PORTS="eth1"; LAN_PORT_LABELS="LAN1"; LAN_PORT_LABEL_OVERRIDES="1=LAN_1-4_(shared)"; MAX_ETH_PORTS=1; WAN_IF="eth0" ;;
GT-AX11000) MODEL="GT-AX11000"; ETH_PORTS="eth4 eth3 eth2 eth1 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
GT-AX11000_PRO) MODEL="GT-AX11000_PRO"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
GT-AXE16000) MODEL="GT-AXE16000"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5 eth6"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5 LAN6"; MAX_ETH_PORTS=6; WAN_IF="eth0" ;;
XT12) MODEL="XT12"; ETH_PORTS="eth1 eth2 eth3"; LAN_PORT_LABELS="LAN1 LAN2 LAN3"; MAX_ETH_PORTS=3; WAN_IF="eth0" ;;

# === Models that needs port layout testing/verification ===
#RT-AX3000) MODEL="RT-AX3000"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
#TUF-AX5400) MODEL="TUF-AX5400"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
#TUF-AX3000) MODEL="TUF-AX3000"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
#DSL-AC68U) MODEL="DSL-AC68U"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
#DSL-AX5400) MODEL="DSL-AX5400"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
#RT-AC88U)  MODEL="RT-AC88U"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5 LAN6 LAN7 LAN8"; MAX_ETH_PORTS=8; WAN_IF="eth0" ;;
#RT-AC5300) MODEL="RT-AC5300"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
#RT-AC3100) MODEL="RT-AC3100"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
#TUF-AX5400) MODEL="TUF-AX5400"; ETH_PORTS="eth0 eth1 eth2 eth3"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth4" ;;
#GT-AXE11000) MODEL="GT-AXE11000"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
#RT-BE96U) MODEL="RT-BE96U"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
#GT-BE98_PRO) MODEL="GT-BE98_PRO"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5 eth6"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5 LAN6"; MAX_ETH_PORTS=6; WAN_IF="eth0" ;;
#RT-BE7200) MODEL="RT-BE7200"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8 eth9"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5 LAN6 LAN7 LAN8 LAN9"; MAX_ETH_PORTS=9; WAN_IF="eth0" ;;

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
        # Do NOT overwrite MAX_SSIDS here — the wireless detection above already
        # computed the correct value from live nvram.  Clobbering it with 3
        # would discard the actual hardware capacity for unrecognized models.
        WAN_IF="eth0"
        ;;
esac
fi

# Sanitize optional presentation-only LAN label overrides. Entries use the
# form SLOT=DISPLAY_TEXT, separated by semicolons. Invalid entries are dropped
# without affecting hardware detection; the first valid value for a slot wins.
sanitize_lan_port_label_overrides() {
  _lplo_raw="$1"
  _lplo_max="$2"
  _lplo_result=""
  _lplo_seen=";"
  _lplo_remaining="$_lplo_raw"

  [ -n "$_lplo_raw" ] || { printf '%s\n' ""; return 0; }

  while :; do
    _lplo_last=0
    case "$_lplo_remaining" in
      *';'*) _lplo_entry=${_lplo_remaining%%;*}; _lplo_remaining=${_lplo_remaining#*;} ;;
      *)     _lplo_entry=$_lplo_remaining; _lplo_remaining=""; _lplo_last=1 ;;
    esac

    _lplo_entry=$(printf '%s' "$_lplo_entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -n "$_lplo_entry" ]; then
      case "$_lplo_entry" in
        *=*=*)
          warn "Ignoring LAN label override '$_lplo_entry': expected exactly one '='"
          ;;
        *=*)
          _lplo_slot=${_lplo_entry%%=*}
          _lplo_label=${_lplo_entry#*=}
          _lplo_slot=$(printf '%s' "$_lplo_slot" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
          _lplo_label=$(printf '%s' "$_lplo_label" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

          case "$_lplo_slot" in
            ''|*[!0-9]*)
              warn "Ignoring LAN label override '$_lplo_entry': slot must be numeric"
              ;;
            *)
              _lplo_slot_norm=$(printf '%s' "$_lplo_slot" | sed 's/^0*//')
              [ -n "$_lplo_slot_norm" ] || _lplo_slot_norm=0
              if [ "$_lplo_slot_norm" -lt 1 ] || [ "$_lplo_slot_norm" -gt "$_lplo_max" ]; then
                warn "Ignoring LAN label override '$_lplo_entry': slot must be between 1 and $_lplo_max"
              elif [ -z "$_lplo_label" ]; then
                warn "Ignoring LAN label override '$_lplo_entry': label is empty"
              elif ! printf '%s' "$_lplo_label" | LC_ALL=C grep -q '^[-A-Za-z0-9_()./+ ][-A-Za-z0-9_()./+ ]*$'; then
                warn "Ignoring LAN label override '$_lplo_entry': label contains unsupported characters"
              else
                case "$_lplo_seen" in
                  *";$_lplo_slot_norm;"*)
                    warn "Ignoring duplicate LAN label override for slot $_lplo_slot_norm"
                    ;;
                  *)
                    _lplo_seen="${_lplo_seen}${_lplo_slot_norm};"
                    _lplo_clean="${_lplo_slot_norm}=${_lplo_label}"
                    if [ -n "$_lplo_result" ]; then
                      _lplo_result="${_lplo_result};${_lplo_clean}"
                    else
                      _lplo_result="$_lplo_clean"
                    fi
                    ;;
                esac
              fi
              ;;
          esac
          ;;
        *)
          warn "Ignoring LAN label override '$_lplo_entry': missing '='"
          ;;
      esac
    fi

    [ "$_lplo_last" = "1" ] && break
  done

  printf '%s\n' "$_lplo_result"
}

LAN_PORT_LABEL_OVERRIDES=$(sanitize_lan_port_label_overrides "$LAN_PORT_LABEL_OVERRIDES" "$MAX_ETH_PORTS")

# ============================================================================ #
#                        WAN INTERFACE VALIDATION                              #
# Verify WAN interface exists; fallback to nvram if default not found.         #
# ============================================================================ #

# Manual WAN mappings are authoritative. Do not silently replace an explicit
# override with nvram's default just because the interface is temporarily
# absent from sysfs; retain the configured value so the resulting profile and
# Apply diagnostics identify the actual problem. Automatic detection keeps the
# legacy nvram fallback when no manual mapping is active.
if [ "$USE_MAP_OVERRIDE" = "1" ]; then
    if [ ! -d "/sys/class/net/$WAN_IF" ]; then
        warn "Manual WAN override '$WAN_IF' for $_OVR_TARGET is not currently present; retaining the explicit mapping"
    fi
else
    [ ! -d "/sys/class/net/$WAN_IF" ] && WAN_IF=$(nvram get wan_ifname 2>/dev/null)
fi

# ============================================================================ #
#                     RECORD hardware into settings.json (Hardware block)      #
# Use json_set_flag to update the consolidated `settings.json` file non-       #
# destructively. Hardware keys are stored under the "Hardware" section in    #
# `settings.json`.                                                            #
# ============================================================================ #

# determine target JSON file (HW_SETTINGS_FILE is an alias to settings.json)
HW_TARGET="${HW_SETTINGS_FILE:-${SETTINGS_FILE}}"

info -c vlan "Writing hardware profile to settings.json (Hardware section)"

# Ensure the store exists before attempting changes
ensure_json_store "$HW_TARGET" || {
    error "Unable to create or access $HW_TARGET"
    exit 1
}

# --- helper: write array values safely into JSON ---
# JSON array writing delegated to lib_json.sh via json_set_array

# Scalars -> stored as strings for compatibility
json_set_flag "MODEL" "$MODEL" "$HW_TARGET" || warn "Failed to write MODEL"
# Overwrite the raw nvram PRODUCTID with the resolved MODEL name so the UI
# badge always shows the correct device identity. On hardware where the nvram
# productid differs from the true model (e.g. RT-AX86S reporting as RT-AX86U),
# the badge would otherwise display the wrong name.
PRODUCTID="$MODEL"
json_set_flag "PRODUCTID" "$PRODUCTID" "$HW_TARGET" || warn "Failed to write PRODUCTID"
json_set_flag "MAX_SSIDS" "${MAX_SSIDS}" "$HW_TARGET" || warn "Failed to write MAX_SSIDS"
json_set_flag "GUEST_SLOTS" "${GUEST_SLOTS}" "$HW_TARGET" || warn "Failed to write GUEST_SLOTS"
json_set_flag "WAN_IF" "$WAN_IF" "$HW_TARGET" || warn "Failed to write WAN_IF"
json_set_flag "MAX_ETH_PORTS" "${MAX_ETH_PORTS}" "$HW_TARGET" || warn "Failed to write MAX_ETH_PORTS"
json_set_section_value "Hardware" "LAN_PORT_LABEL_OVERRIDES" "$LAN_PORT_LABEL_OVERRIDES" "$HW_TARGET" \
  || warn "Failed to write LAN_PORT_LABEL_OVERRIDES"

# Lists: store as space-separated strings for later parsing
json_set_array "RADIO_INDEXES" "$RADIO_INDEXES" "$HW_TARGET" || warn "Failed to write RADIO_INDEXES"
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
  while [ "$_node_i" -le "${MERV_MAX_NODES:-10}" ]; do
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

# The probe can change authoritative Hardware and MAIN MAX_ETH_PORTS_NODEn
# values after an override Save. Publish only its final observed generation;
# this makes the browser follow-up an accelerator, not a durability owner.
if [ "$_hp_reconcile_capture" = yes ]; then
  _hp_reconcile_after=$(merv_settings_node_sync_digest "$SETTINGS_FILE" 2>/dev/null || printf '')
  if [ -n "$_hp_reconcile_after" ] && [ "$_hp_reconcile_before" != "$_hp_reconcile_after" ]; then
    if type merv_settings_reconcile_normalize_current >/dev/null 2>&1; then
      merv_settings_reconcile_normalize_current publish || \
        warn "Hardware probe changed settings but could not publish node convergence intent"
    else
      warn "Hardware probe changed settings but reconciliation support is unavailable"
    fi
  fi
fi

# ============================================================================ #
#                           REPORT & DEBUG OUTPUT                              #
# Display detected hardware configuration and list all available ethernet      #
# interfaces for troubleshooting.                                              #
# ============================================================================ #

# This script is normally launched by the service-event handler, whose stdout
# is intentionally not the WebUI CLI stream.  Publish the operational report
# explicitly to both supported user-visible log channels instead of relying on
# background-action stdout.
_hp_detected_eth=$(ls /sys/class/net/ 2>/dev/null | grep -E '^eth[0-9]' | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')
info -c vlan "Hardware detection complete"
info -c vlan "Hardware model: $MODEL"
info -c vlan "Hardware radios: $RADIOS (indexes: $RADIO_INDEXES; guest slots: $GUEST_SLOTS; max SSIDs: $MAX_SSIDS)"
info -c vlan "Hardware Ethernet: ports: $ETH_PORTS; labels: $LAN_PORT_LABELS; WAN: $WAN_IF"
info -c vlan "Hardware label overrides: ${LAN_PORT_LABEL_OVERRIDES:-none}"
info -c vlan "Detected Ethernet interfaces: ${_hp_detected_eth:-none}"
info -c vlan "Hardware profile stored in settings.json (Hardware section)"
info -c cli "Hardware profile refreshed: $MODEL ($MAX_ETH_PORTS LAN ports; WAN $WAN_IF)"

# ============================================================================ #
#                 PUBLIC HARDWARE PROFILE CATALOG GENERATOR                   #
# Generate the browser-readable catalog from the active model definitions     #
# above. The model case list remains the source of truth and normal probe     #
# behavior is unaffected if this best-effort publication fails.               #
# ============================================================================ #
merv_generate_public_hardware_profiles() {
    _hp_public_dir="${PUBLIC_SETTINGS_DIR:-${PUBLIC_MERV_BASE:-/www/user/mervlan}/settings}"
    _hp_target="$_hp_public_dir/hardware_profiles.json"
    _hp_tmp="${_hp_target}.tmp.$$"
    _hp_source="${MERV_BASE:-/jffs/addons/mervlan}/functions/hw_probe.sh"

    [ -r "$_hp_source" ] || return 1
    mkdir -p "$_hp_public_dir" 2>/dev/null || return 1

    awk '
      function jsonq(v, t) {
        t = v
        gsub(/\\/, "\\\\", t)
        gsub(/"/, "\\\"", t)
        return "\"" t "\""
      }
      function jsonarr(v, a, n, i, out) {
        out = "["
        n = split(v, a, /[[:space:]]+/)
        for (i = 1; i <= n; i++) {
          if (a[i] == "") continue
          if (out != "[") out = out ","
          out = out jsonq(a[i])
        }
        return out "]"
      }
      function field(line, name, start, rest, end) {
        start = index(line, name "=\"")
        if (!start) return ""
        rest = substr(line, start + length(name) + 2)
        end = index(rest, "\"")
        return end ? substr(rest, 1, end - 1) : ""
      }
      function number_field(line, name, start, rest) {
        start = index(line, name "=")
        if (!start) return 0
        rest = substr(line, start + length(name) + 1)
        sub(/[^0-9].*$/, "", rest)
        return rest + 0
      }
      BEGIN {
        in_models = 0
        first = 1
        print "{"
        print "  \"version\": 1,"
        print "  \"profiles\": {"
      }
      /case "\$PRODUCTID" in/ { in_models = 1; next }
      in_models && /# === Models that needs port layout testing\/verification ===/ { in_models = 0; next }
      in_models && /^[[:space:]]*#/ { next }
      in_models && index($0, "MODEL=\"") && index($0, "ETH_PORTS=\"") &&
        index($0, "LAN_PORT_LABELS=\"") && index($0, "MAX_ETH_PORTS=") &&
        index($0, "WAN_IF=\"") {
          model = field($0, "MODEL")
          eth = field($0, "ETH_PORTS")
          labels = field($0, "LAN_PORT_LABELS")
          max = number_field($0, "MAX_ETH_PORTS")
          wan = field($0, "WAN_IF")
          override = field($0, "LAN_PORT_LABEL_OVERRIDES")
          if (model == "" || seen[model]++) next
          if (!first) print "    ,"
          printf "    %s: {\"model\":%s,\"wan_if\":%s,\"max_eth_ports\":%s,\"eth_ports\":%s,\"lan_labels\":%s",
            jsonq(model), jsonq(model), jsonq(wan), max + 0, jsonarr(eth), jsonarr(labels)
          if (override != "") printf ",\"lan_port_label_overrides\":%s", jsonq(override)
          printf "}"
          first = 0
        }
      END {
        print ""
        print "  }"
        print "}"
      }
    ' "$_hp_source" > "$_hp_tmp" 2>/dev/null || {
        rm -f "$_hp_tmp" 2>/dev/null || :
        return 1
    }

    if [ -f "$_hp_target" ] && cmp -s "$_hp_tmp" "$_hp_target" 2>/dev/null; then
        rm -f "$_hp_tmp" 2>/dev/null || :
    else
        chmod 644 "$_hp_tmp" 2>/dev/null || :
        mv -f "$_hp_tmp" "$_hp_target" 2>/dev/null || {
            rm -f "$_hp_tmp" 2>/dev/null || :
            return 1
        }
    fi
    return 0
}

# This is deliberately best-effort: hardware detection and settings writes
# must retain their existing success/failure behavior if the public web path
# is unavailable during boot or installation.
merv_generate_public_hardware_profiles || warn "Could not update public hardware_profiles.json"
