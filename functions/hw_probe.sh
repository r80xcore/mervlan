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
#                   - File: hw_probe.sh || version="0.46"                      #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Probe system hardware and record hardware keys in the central
#                settings store (settings.json). Writes non-destructively via
#                json_set_flag so values remain compatible with legacy top-level
#                keys and the newer Hardware block in settings.json.
# ──────────────────────────────────────────────────────────────────────────── #
#                                                                              #
# ================================================== MerVLAN environment setup #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED
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

# Iterate through radio indices 0, 1, 2 (potential radio slots on Merlin)
for radio in 0 1 2; do
    # Retrieve interface name from nvram (e.g., wl0_ifname, wl1_ifname, wl2_ifname)
    ifname=$(nvram get "wl${radio}_ifname" 2>/dev/null)
    # Verify interface exists in kernel
    if [ -n "$ifname" ] && [ -d "/sys/class/net/$ifname" ]; then
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
#                        MODEL-SPECIFIC PORT DETECTION                         #
# Map product ID to specific router model and assign ethernet port layout      #
# (interface names and labels). Models with native VLAN GUI skip port override.#
# ============================================================================ #
case "$PRODUCTID" in
# === ZenWiFi (Mesh systems) ===
# ZenWiFi XT8 and ET8: 2.5G WAN + 3x 1G LAN
RT-AX95Q) MODEL="XT8"; ETH_PORTS="eth1 eth2 eth3"; LAN_PORT_LABELS="LAN1 LAN2 LAN3"; MAX_ETH_PORTS=3; WAN_IF="eth0" ;;
RT-ET8)   MODEL="ET8"; ETH_PORTS="eth1 eth2 eth3"; LAN_PORT_LABELS="LAN1 LAN2 LAN3"; MAX_ETH_PORTS=3; WAN_IF="eth0" ;;

# === AX86 / AX68 Series (Premium AX models) ===
# AX86U/AX86S: Gig WAN + 4x LAN + 2.5G multi-gig port (configurable WAN/LAN)
RT-AX86U|RT-AX86S) MODEL="AX86"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
# AX68U: Standard AX with 4 LAN + Gig WAN
RT-AX68U)          MODEL="AX68"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;

# === AX58 / AX3000 (Mid-range AX models) ===
# AX58U and AX3000v1 share same port layout: 4x LAN + Gig WAN
RT-AX58U|RT-AX3000) MODEL="AX58/3000v1"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;

# === AX82 / TUF Series ===
# AX82U: Standard AX with 4 LAN + Gig WAN
RT-AX82U)   MODEL="AX82"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
# TUF-AX5400 & TUF-AX3000: Gaming-oriented models with standard 4 LAN + Gig WAN
TUF-AX5400) MODEL="TUF-AX5400"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
TUF-AX3000) MODEL="TUF-AX3000"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;

# === AX92U (Premium AX enterprise) ===
RT-AX92U) MODEL="AX92U"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;

# === DSL Series ===
# NOTE: DSL models use primary WAN as DSL (RJ11); EWAN uses ethernet. Interface
# naming may vary by firmware. This defaults to eth0 as WAN for VLAN purposes.
DSL-AC68U) MODEL="DSL-AC68U"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
DSL-AX82U|DSL-AX5400) MODEL="DSL-AX82/5400"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;

# === AC Series (Legacy, pre-AX WiFi) ===
# AC86U: Standard AC with 4 LAN + Gig WAN
RT-AC86U)  MODEL="AC86U"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
# AC88U: High-port count model with 8 LAN ports (enterprise/prosumer)
RT-AC88U)  MODEL="AC88U"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5 LAN6 LAN7 LAN8"; MAX_ETH_PORTS=8; WAN_IF="eth0" ;;
# AC5300: Triple-band with 4 LAN + Gig WAN
RT-AC5300) MODEL="AC5300"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
# AC3100: Dual-band with 4 LAN + Gig WAN
RT-AC3100) MODEL="AC3100"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;

# === Pro / Multi-Gig Models ===
# AX88U: 8× LAN + 1× WAN
RT-AX88U) MODEL="AX88U"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5 LAN6 LAN7 LAN8"; MAX_ETH_PORTS=8; WAN_IF="eth0" ;;
# GT-AX11000: 4× GbE LAN + 1× 2.5G WAN/LAN (max 5 LAN when 1G is WAN)
GT-AX11000) MODEL="GT-AX11000"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
# GT-AXE11000: 4× GbE LAN + 1× 2.5G WAN/LAN (max 5 LAN when 1G is WAN)
GT-AXE11000) MODEL="GT-AXE11000"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
# GT-AX6000: dual 2.5G WAN/LAN + 4× GbE LAN (max 5 LAN with one 2.5G as WAN)
GT-AX6000) MODEL="GT-AX6000"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
# XT12 (ZenWiFi Pro XT12): 1× 2.5G WAN + 1× 2.5G LAN + 2× GbE LAN (3 LAN usable)
XT12) MODEL="XT12"; ETH_PORTS="eth1 eth2 eth3"; LAN_PORT_LABELS="LAN1 LAN2 LAN3"; MAX_ETH_PORTS=3; WAN_IF="eth0" ;;
# GT-AX11000_PRO: 10G WAN/LAN + 4× GbE LAN + 2.5G WAN (max 5 LAN)
GT-AX11000_PRO) MODEL="GT-AX11000_PRO"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
# GT-AXE16000: two 10G WAN/LAN + 4× GbE LAN + 2.5G WAN (max 6 LAN)
GT-AXE16000) MODEL="GT-AXE16000"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5 eth6"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5 LAN6"; MAX_ETH_PORTS=6; WAN_IF="eth0" ;;
# RT-AX86U_PRO: 4× GbE LAN + 1× 2.5G WAN/LAN + 1× GbE WAN (max 5 LAN using 1G as WAN)
RT-AX86U_PRO) MODEL="RT-AX86U_PRO"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
# RT-AX88U_PRO: 4× GbE LAN + two 2.5G WAN/LAN (one used as WAN → 5 LAN)
RT-AX88U_PRO) MODEL="RT-AX88U_PRO"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
# RT-BE96U: 10G WAN/LAN + 1G WAN/LAN + 3× 1G LAN + 10G LAN (one WAN/LAN used → 5 LAN)
RT-BE96U) MODEL="RT-BE96U"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
# GT-BE98_PRO: 10G WAN/LAN + 2.5G WAN/LAN + 10G LAN + 3× 2.5G LAN + 1× 1G LAN (one WAN/LAN used → 6 LAN)
GT-BE98_PRO) MODEL="GT-BE98_PRO"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5 eth6"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5 LAN6"; MAX_ETH_PORTS=6; WAN_IF="eth0" ;;
# RT-BE86U: 10G WAN/LAN + 3× 2.5G LAN (+ optional 2.5G WAN/LAN depending on region) — max 4 LAN
RT-BE86U) MODEL="RT-BE86U"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
# RT-BE88U: 10G RJ45 WAN/LAN + 10G SFP+ + 2.5G WAN/LAN + 3× 2.5G LAN + 4× 1G LAN (use SFP+ as WAN → max 9 LAN)
RT-BE88U) MODEL="RT-BE88U"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8 eth9"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5 LAN6 LAN7 LAN8 LAN9"; MAX_ETH_PORTS=9; WAN_IF="eth0" ;;
# RT-BE7200: alias of RT-BE88U (same ports; max 9 LAN when SFP+ is WAN)
RT-BE7200) MODEL="RT-BE7200"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8 eth9"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5 LAN6 LAN7 LAN8 LAN9"; MAX_ETH_PORTS=9; WAN_IF="eth0" ;;
# RT-BE92U: 10G WAN/LAN + 2.5G WAN/LAN + 3× 2.5G LAN (one WAN/LAN used → 4 LAN)
RT-BE92U) MODEL="RT-BE92U"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
# GT-BE98: 10G WAN/LAN + 2.5G WAN/LAN + 10G LAN + 3× 2.5G LAN + 1× 1G LAN (one WAN/LAN used → 6 LAN)
GT-BE98) MODEL="GT-BE98"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5 eth6"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5 LAN6"; MAX_ETH_PORTS=6; WAN_IF="eth0" ;;

# === Fallback for Unknown Models ===
# Attempt to auto-detect ethernet ports by scanning /sys/class/net. If fewer
# than 4 ports found, default to 4 ports (common minimum). Cap SSID count.
    *)
        MODEL="$PRODUCTID"
        ETH_PORTS="eth1 eth2 eth3 eth4"
        LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"
        MAX_ETH_PORTS=4
        # Default SSID cap for unknown models
        MAX_SSIDS=6
        WAN_IF="eth0"
        ;;
esac

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