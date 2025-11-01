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
# hw_probe.sh - Probe system hardware and generate hw_settings.json (BusyBox compatible)

# Ensure nvram works
if ! nvram get productid >/dev/null 2>&1; then
    error "nvram command not found or not working - not on Asuswrt-Merlin?"
fi

PRODUCTID=$(nvram get productid)
[ -z "$PRODUCTID" ] && error "Could not get productid"

# Detect radios
RADIOS=""
GUEST_SLOTS=0
MAX_SSIDS=0

for radio in 0 1 2; do
    ifname=$(nvram get "wl${radio}_ifname" 2>/dev/null)
    if [ -n "$ifname" ] && [ -d "/sys/class/net/$ifname" ]; then
        case $radio in
            0) band="2.4" ;;
            1) band="5g-1" ;;
            2) band="5g-2" ;;
        esac
        RADIOS="$RADIOS $band"

        radio_guests=0
        for slot in 1 2 3; do
            ssid=$(nvram get "wl${radio}.${slot}_ssid" 2>/dev/null)
            [ -n "$ssid" ] && radio_guests=$((radio_guests + 1))
        done
        [ $radio_guests -gt $GUEST_SLOTS ] && GUEST_SLOTS=$radio_guests

        MAX_SSIDS=$((MAX_SSIDS + 1 + radio_guests))
    fi
done

RADIOS=$(echo $RADIOS | sed 's/^ //')
[ -z "$RADIOS" ] && RADIOS="2.4 5g-1 5g-2"
[ $GUEST_SLOTS -eq 0 ] && GUEST_SLOTS=3
[ $MAX_SSIDS -eq 0 ] && MAX_SSIDS=12
[ $MAX_SSIDS -gt 12 ] && MAX_SSIDS=12

# -------------------------
# Model-specific detection
# -------------------------
case "$PRODUCTID" in
# === ZenWiFi ===
RT-AX95Q) MODEL="XT8"; ETH_PORTS="eth1 eth2 eth3"; LAN_PORT_LABELS="LAN1 LAN2 LAN3"; MAX_ETH_PORTS=3; WAN_IF="eth0" ;;   # 2.5G WAN + 3x LAN
RT-ET8)   MODEL="ET8"; ETH_PORTS="eth1 eth2 eth3"; LAN_PORT_LABELS="LAN1 LAN2 LAN3"; MAX_ETH_PORTS=3; WAN_IF="eth0" ;;   # 2.5G WAN + 3x LAN

# === AX86 / AX68 Series ===
RT-AX86U|RT-AX86S) MODEL="AX86"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;  # + 2.5G multi-gig (WAN/LAN selectable)
RT-AX68U)          MODEL="AX68"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;

# === AX58 / AX3000 V1 ===
RT-AX58U|RT-AX3000) MODEL="AX58/3000v1"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;

# (Optional add) AX58 / AX3000 V2 — keep separate if you want distinct handling for V2
# RT-AX58U_V2|RT-AX3000_V2) MODEL="AX58/3000v2"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;

# === AX82 / TUF ===
RT-AX82U)   MODEL="AX82"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
TUF-AX5400) MODEL="TUF-AX5400"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
TUF-AX3000) MODEL="TUF-AX3000"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;

# (Optional add) RT-AX5400 (non-TUF) — identical port layout if you want it explicit
# RT-AX5400) MODEL="AX5400"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;

# === AX92 ===
RT-AX92U) MODEL="AX92U"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;

# === DSL series ===
# NOTE: On DSL models, the primary WAN is DSL (RJ11). EWAN uses an Ethernet port; interface naming may differ by firmware.
DSL-AC68U) MODEL="DSL-AC68U"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
DSL-AX82U|DSL-AX5400) MODEL="DSL-AX82/5400"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;

# === AC series ===
RT-AC86U)  MODEL="AC86U"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;
RT-AC88U)  MODEL="AC88U"; ETH_PORTS="eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5 LAN6 LAN7 LAN8"; MAX_ETH_PORTS=8; WAN_IF="eth0" ;;
RT-AC5300) MODEL="AC5300"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;  # <-- fixed
RT-AC3100) MODEL="AC3100"; ETH_PORTS="eth1 eth2 eth3 eth4"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth0" ;;

# === Models with native VLAN GUI (skip override) ===
# Confirmed by ASUS docs / ISP KB: GT-AX11000_PRO, GT-AX6000, GT-AXE16000, RT-AX86U_PRO, RT-AX88U_PRO, XT12, ET12
# Treat BE-series as firmware-dependent (3.0.0.6/3006 builds).
RT-AX88U|GT-AX11000|GT-AXE11000|GT-AX6000|XT12|GT-AX11000_PRO|GT-AXE16000|RT-AX86U_PRO|RT-AX88U_PRO|RT-BE96U|GT-BE98_PRO|RT-BE86U|RT-BE88U|RT-BE7200|RT-BE92U|GT-BE98)
    MODEL="$PRODUCTID"
    ETH_PORTS=""
    LAN_PORT_LABELS=""
    MAX_ETH_PORTS=0
    WAN_IF="eth0"
    info "Model $PRODUCTID has native VLAN GUI support - skipping LAN port override"
    ;;


    # === Fallback ===
    *)
        MODEL="$PRODUCTID"
        ETH_PORTS=""
        LAN_PORT_LABELS=""
        MAX_ETH_PORTS=0
        for eth in eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8; do
            if [ -d "/sys/class/net/$eth" ]; then
                ETH_PORTS="$ETH_PORTS $eth"
                LAN_PORT_LABELS="$LAN_PORT_LABELS LAN$((MAX_ETH_PORTS+1))"
                MAX_ETH_PORTS=$((MAX_ETH_PORTS + 1))
            fi
        done

        if [ -z "$ETH_PORTS" ] || [ $MAX_ETH_PORTS -lt 4 ]; then
            ETH_PORTS="eth1 eth2 eth3 eth4"
            LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"
            MAX_ETH_PORTS=4
        fi

        MAX_SSIDS=8
        WAN_IF="eth0"
        ;;
esac

# Ensure WAN_IF exists
[ ! -d "/sys/class/net/$WAN_IF" ] && WAN_IF=$(nvram get wan_ifname 2>/dev/null)


# -------------------------
# Generate hw_settings.json
# -------------------------
{
    echo "{"
    echo "  \"MODEL\": \"$MODEL\","
    echo "  \"PRODUCTID\": \"$PRODUCTID\","
    echo "  \"MAX_SSIDS\": $MAX_SSIDS,"

    echo -n "  \"RADIOS\": ["
    first=1
    for radio in $RADIOS; do
        [ $first -eq 1 ] && echo -n "\"$radio\"" && first=0 || echo -n ", \"$radio\""
    done
    echo "],"

    echo "  \"GUEST_SLOTS\": $GUEST_SLOTS,"

    echo -n "  \"ETH_PORTS\": ["
    first=1
    for port in $ETH_PORTS; do
        [ $first -eq 1 ] && echo -n "\"$port\"" && first=0 || echo -n ", \"$port\""
    done
    echo "],"

    echo -n "  \"LAN_PORT_LABELS\": ["
    first=1
    for label in $LAN_PORT_LABELS; do
        [ $first -eq 1 ] && echo -n "\"$label\"" && first=0 || echo -n ", \"$label\""
    done
    echo "],"

  echo "  \"WAN_IF\": \"$WAN_IF\","
  echo "  \"MAX_ETH_PORTS\": $MAX_ETH_PORTS"
    echo "}"
} > "$HW_SETTINGS_FILE"

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
echo "=== Debug: All detected interfaces ==="
ls /sys/class/net/ | grep -E '^eth[0-9]' | sort