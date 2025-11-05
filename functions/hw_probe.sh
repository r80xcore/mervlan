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
#                   - File: hw_probe.sh || version="0.45"                      #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Probe system hardware and generate hw_settings.json            #
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

# === Models with Native VLAN GUI (skip override) ===
# These models have built-in VLAN support in firmware; do not override.
# Confirmed models: GT-AX11000_PRO, GT-AX6000, GT-AXE16000, RT-AX86U_PRO,
# RT-AX88U_PRO, XT12, ET12, and BE-series (firmware dependent).
RT-AX88U|GT-AX11000|GT-AXE11000|GT-AX6000|XT12|GT-AX11000_PRO|GT-AXE16000|RT-AX86U_PRO|RT-AX88U_PRO|RT-BE96U|GT-BE98_PRO|RT-BE86U|RT-BE88U|RT-BE7200|RT-BE92U|GT-BE98)
    MODEL="$PRODUCTID"
    ETH_PORTS=""
    LAN_PORT_LABELS=""
    MAX_ETH_PORTS=0
    WAN_IF="eth0"
    info "Model $PRODUCTID has native VLAN GUI support - skipping LAN port override"
    ;;

# === Fallback for Unknown Models ===
# Attempt to auto-detect ethernet ports by scanning /sys/class/net. If fewer
# than 4 ports found, default to 4 ports (common minimum). Cap SSID count.
    *)
        MODEL="$PRODUCTID"
        ETH_PORTS=""
        LAN_PORT_LABELS=""
        MAX_ETH_PORTS=0
        # Scan for eth1..eth8 interfaces
        for eth in eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8; do
            if [ -d "/sys/class/net/$eth" ]; then
                ETH_PORTS="$ETH_PORTS $eth"
                LAN_PORT_LABELS="$LAN_PORT_LABELS LAN$((MAX_ETH_PORTS+1))"
                MAX_ETH_PORTS=$((MAX_ETH_PORTS + 1))
            fi
        done

        # If fewer than 4 ports detected, default to standard configuration
        if [ -z "$ETH_PORTS" ] || [ $MAX_ETH_PORTS -lt 4 ]; then
            ETH_PORTS="eth1 eth2 eth3 eth4"
            LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"
            MAX_ETH_PORTS=4
        fi

        # Default SSID cap for unknown models
        MAX_SSIDS=8
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
#                     GENERATE & WRITE hw_settings.json                        #
# Format all detected hardware parameters as JSON and write to output file.    #
# JSON includes model, radios, SSID counts, ethernet ports, labels, and WAN.   #
# ============================================================================ #
{
    # JSON header and model/product info
    echo "{"
    echo "  \"MODEL\": \"$MODEL\","
    echo "  \"PRODUCTID\": \"$PRODUCTID\","
    echo "  \"MAX_SSIDS\": $MAX_SSIDS,"

    # RADIOS array: convert space-separated list to JSON array
    echo -n "  \"RADIOS\": ["
    first=1
    for radio in $RADIOS; do
        [ $first -eq 1 ] && echo -n "\"$radio\"" && first=0 || echo -n ", \"$radio\""
    done
    echo "],"

    # Guest slots per radio
    echo "  \"GUEST_SLOTS\": $GUEST_SLOTS,"

    # ETH_PORTS array: convert space-separated list to JSON array
    echo -n "  \"ETH_PORTS\": ["
    first=1
    for port in $ETH_PORTS; do
        [ $first -eq 1 ] && echo -n "\"$port\"" && first=0 || echo -n ", \"$port\""
    done
    echo "],"

    # LAN_PORT_LABELS array: convert space-separated list to JSON array
    echo -n "  \"LAN_PORT_LABELS\": ["
    first=1
    for label in $LAN_PORT_LABELS; do
        [ $first -eq 1 ] && echo -n "\"$label\"" && first=0 || echo -n ", \"$label\""
    done
    echo "],"

  # WAN interface and max port count
  echo "  \"WAN_IF\": \"$WAN_IF\","
  echo "  \"MAX_ETH_PORTS\": $MAX_ETH_PORTS"
    echo "}"
} > "$HW_SETTINGS_FILE"

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
echo "  Output: $HW_SETTINGS_FILE"

echo ""
# Debug output: list all detected ethernet interfaces for verification
echo "=== Debug: All detected interfaces ==="
ls /sys/class/net/ | grep -E '^eth[0-9]' | sort