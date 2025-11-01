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
#               - File: mervlan_manager.sh || version="0.45"                   #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    JSON-driven VLAN manager for Asuswrt-Merlin firmware.          #
#               Applies VLAN settings to SSIDs and Ethernet ports based on     #
#               settings defined in JSON files.                                #
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

# --------------------------
# JSON helpers (BusyBox-safe, improved for escaped quotes)
# --------------------------
read_json() {
  key="$1"; file="$2"
  # Enhanced regex to handle escaped quotes in values
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p; s/.*\"$key\"[[:space:]]*:[[:space:]]*\([^,}\"]*\).*/\1/p" "$file" | head -1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

read_json_number() { 
  read_json "$1" "$2" | grep -o '^[0-9]\+' 
}

read_json_array() {
  key="$1"; file="$2"
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p" "$file" \
    | sed 's/[[:space:]]//g; s/"//g; s/,/ /g'
}

# --------------------------
# Load hardware + settings
# --------------------------
[ -f "$HW_SETTINGS_FILE" ] || error -c cli,vlan "Missing $HW_SETTINGS_FILE"
[ -f "$SETTINGS_FILE" ] || error -c cli,vlan "Missing $SETTINGS_FILE"

MODEL=$(read_json MODEL "$HW_SETTINGS_FILE")
PRODUCTID=$(read_json PRODUCTID "$HW_SETTINGS_FILE")
MAX_SSIDS=$(read_json_number MAX_SSIDS "$HW_SETTINGS_FILE")
ETH_PORTS=$(read_json_array ETH_PORTS "$HW_SETTINGS_FILE")
WAN_IF=$(read_json WAN_IF "$HW_SETTINGS_FILE")

TOPOLOGY="switch"
PERSISTENT=$(read_json PERSISTENT "$SETTINGS_FILE")
DRY_RUN=$(read_json DRY_RUN "$SETTINGS_FILE")

[ -z "$MAX_SSIDS" ] && MAX_SSIDS=12
[ "$MAX_SSIDS" -gt 12 ] && MAX_SSIDS=12
[ -z "$PERSISTENT" ] && PERSISTENT="no"
[ -z "$DRY_RUN" ] && DRY_RUN="yes"
[ -z "$WAN_IF" ] && WAN_IF="eth0"

UPLINK_PORT="$WAN_IF"
DEFAULT_BRIDGE="br0"

# --------------------------
# State tracking for audit trail
# --------------------------
CHANGE_LOG="$CHANGES/vlan_changes.$$"
cleanup_on_exit() {
    [ -f "$CHANGE_LOG" ] && rm -f "$CHANGE_LOG"
}
trap cleanup_on_exit EXIT INT TERM
track_change() {
  echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$CHANGE_LOG"
}

# --------------------------
# Configuration validation (pre-flight check)
# --------------------------
validate_configuration() {
  [ -f "$SETTINGS_FILE" ] || error -c cli,vlan "Settings file missing"
  [ -f "$HW_SETTINGS_FILE" ] || error -c cli,vlan "Hardware settings file missing"
  [ -n "$MODEL" ] || warn -c cli,vlan "MODEL not defined in hardware settings; using defaults"
  [ -n "$PRODUCTID" ] || warn -c cli,vlan "PRODUCTID not defined in hardware settings; using defaults"
  [ -n "$MAX_SSIDS" ] || warn -c cli,vlan "MAX_SSIDS not defined; defaulting to 12"
  [ -n "$ETH_PORTS" ] || warn -c cli,vlan "ETH_PORTS not defined; no Ethernet ports will be configured"
}

# --------------------------
# Wait for interface with exponential backoff
# --------------------------
wait_for_interface() {
  local iface="$1" max_attempts=10 attempt=0
  while [ $attempt -lt $max_attempts ]; do
    iface_exists "$iface" && return 0
    sleep $((2 ** attempt))  # Exponential backoff: 1s, 2s, 4s, 8s, etc.
    attempt=$((attempt + 1))
  done
  return 1
}

# --------------------------
# Core VLAN functions
# --------------------------

iface_exists() { [ -d "/sys/class/net/$1" ]; }
is_number()    { expr "$1" + 0 >/dev/null 2>&1; }

is_internal_vap() {
  case "$1" in wl[0-2].[4-9]) return 0;; esac
  return 1
}

validate_vlan_id() {
  case "$1" in
   ""|none|trunk) return 0 ;;
  esac

  if is_number "$1"; then
    if [ "$1" -eq 1 ]; then
      error -c cli,vlan "VLAN 1 is reserved (native LAN). Use VLAN_ID=none instead."
      return 1
    fi
    if [ "$1" -ge 2 ] && [ "$1" -le 4094 ]; then
      return 0
    fi
  fi

  error -c cli,vlan "Invalid VLAN: $1"
  return 1
}

remove_from_all_bridges() {
  iface="$1"
  for br in $(brctl show 2>/dev/null | awk 'NR>1 {print $1}'); do
    brctl delif "$br" "$iface" 2>/dev/null
  done
}

# Creates and configures VLAN bridge if not existing
ensure_vlan_bridge() {
  VID="$1"
  [ "$VID" = "none" ] || [ "$VID" = "trunk" ] && return 0

  if ! iface_exists "${UPLINK_PORT}.${VID}"; then
    if [ "$DRY_RUN" = "yes" ]; then
      echo "[DRY-RUN] ip link add link $UPLINK_PORT name ${UPLINK_PORT}.${VID} type vlan id $VID"
      echo "[DRY-RUN] ip link set ${UPLINK_PORT}.${VID} up"
    else
      ip link add link "$UPLINK_PORT" name "${UPLINK_PORT}.${VID}" type vlan id "$VID" 2>/dev/null || {
        error -c cli,vlan "Failed to create VLAN interface ${UPLINK_PORT}.${VID}"
        return 1
      }
      ip link set "${UPLINK_PORT}.${VID}" up 2>/dev/null
      info -c cli,vlan "Created VLAN interface ${UPLINK_PORT}.${VID}"
      track_change "Created VLAN interface ${UPLINK_PORT}.${VID}"
    fi
  fi

  if ! brctl show 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "br${VID}"; then
    if [ "$DRY_RUN" = "yes" ]; then
      echo "[DRY-RUN] brctl addbr br${VID}"
      echo "[DRY-RUN] brctl addif br${VID} ${UPLINK_PORT}.${VID}"
      echo "[DRY-RUN] ip link set br${VID} up"
    else
      brctl addbr "br${VID}" 2>/dev/null || {
        error -c cli,vlan "Failed to create bridge br${VID}"
        return 1
      }
      brctl addif "br${VID}" "${UPLINK_PORT}.${VID}" 2>/dev/null
      ip link set "br${VID}" up 2>/dev/null
      info -c cli,vlan "Created bridge br${VID}"
      track_change "Created bridge br${VID}"
    fi
  fi
}

# Attaches interface to appropriate bridge based on VLAN configuration
attach_to_bridge() {
  IF="$1"
  VID="$2"
  LABEL="$3"

  validate_vlan_id "$VID" || { warn -c cli,vlan "Invalid VLAN $VID for $LABEL, skipping"; return; }

  is_internal_vap "$IF" && { warn -c cli,vlan "$LABEL ($IF) looks internal; skipping"; return; }
  iface_exists "$IF" || { warn -c cli,vlan "$LABEL ($IF) - not present, skipping"; return; }

  [ "$DRY_RUN" = "yes" ] || remove_from_all_bridges "$IF"

  case "$VID" in
    none)
      if [ "$DRY_RUN" = "yes" ]; then
        echo "[DRY-RUN] brctl addif $DEFAULT_BRIDGE $IF"
      else
        brctl addif "$DEFAULT_BRIDGE" "$IF" 2>/dev/null || {
          error -c cli,vlan "Failed to attach $IF to $DEFAULT_BRIDGE"
          return 1
        }
        info -c cli,vlan "$LABEL -> $DEFAULT_BRIDGE (untagged)"
        track_change "Attached $IF to $DEFAULT_BRIDGE (untagged)"
      fi
      ;;
    trunk)
      info -c cli,vlan "$LABEL set as trunk (no bridge)"
      ;;
    *)
      ensure_vlan_bridge "$VID" || return 1
      if [ "$DRY_RUN" = "yes" ]; then
        echo "[DRY-RUN] brctl addif br${VID} $IF"
      else
        brctl addif "br${VID}" "$IF" 2>/dev/null || {
          error -c cli,vlan "Failed to attach $IF to br${VID}"
          return 1
        }
        info -c cli,vlan "$LABEL -> br${VID} (VLAN $VID)"
        track_change "Attached $IF to br${VID} (VLAN $VID)"
      fi
      ;;
  esac
}

# --------------------------
# SSID resolution
# --------------------------
find_if_by_ssid() {
  BAND="$1"
  TARGET="$2"

  [ -z "$TARGET" ] && return 1
  [ "$TARGET" = "unused-placeholder" ] && return 1

  # Try base radio first (main SSID)
  SSID_BASE="$(nvram get wl${BAND}_ssid 2>/dev/null)"
  IF_BASE="$(nvram get wl${BAND}_ifname 2>/dev/null)"
  if [ "$SSID_BASE" = "$TARGET" ] && [ -n "$IF_BASE" ] && iface_exists "$IF_BASE"; then
    echo "$IF_BASE"
    return 0
  fi

  # Try guest slots (1, 2, 3)
  for slot in 1 2 3; do
    SSID="$(nvram get wl${BAND}.${slot}_ssid 2>/dev/null)"
    [ "$SSID" = "$TARGET" ] || continue
    IFN="$(nvram get wl${BAND}.${slot}_ifname 2>/dev/null)"
    if [ -n "$IFN" ] && iface_exists "$IFN"; then
      echo "$IFN"
      return 0
    fi
  done
  
  return 1
}

# Find interface for an SSID across any band/slot using NVRAM scan (robust)
find_if_by_ssid_any() {
  ssid="$1"
  [ -z "$ssid" ] && return 1
  keys=$(nvram show 2>/dev/null | grep '_ssid=' | grep -F "=${ssid}" | awk -F= '{print $1}' | sed 's/_ssid$//')
  for key in $keys; do
    iface=$(nvram get ${key}_ifname 2>/dev/null)
    if [ -n "$iface" ] && echo "$iface" | grep -q '^wl' && iface_exists "$iface"; then
      echo "$iface"
      return 0
    fi
  done
  return 1
}

# Apply AP isolation to an interface and optionally persist via nvram
set_ap_isolation() {
  IFN="$1"; VAL="$2"  # 0 or 1
  case "$VAL" in
    0|1)
      if [ "$DRY_RUN" = "yes" ]; then
        echo "[DRY-RUN] wl -i $IFN ap_isolate $VAL"
      else
        wl -i "$IFN" ap_isolate "$VAL" 2>/dev/null || {
          error -c cli,vlan "Failed to set AP isolation=$VAL for $IFN"
          return 1
        }
        info -c cli,vlan "Set AP isolation=$VAL for $IFN"
        case "$IFN" in wl[0-2]|wl[0-2].[1-3]) nvram set "${IFN}_ap_isolate=$VAL" ;; esac
        [ "$PERSISTENT" = "yes" ] && nvram commit
        track_change "Set AP isolation=$VAL for $IFN"
      fi
      ;;
  esac
}

# Dynamically binds configured SSIDs to VLAN bridges based on settings.json
bind_configured_ssids() {
  USED_SSIDS=""
  i=1
  while [ $i -le "$MAX_SSIDS" ]; do
    ssid=$(read_json "$(printf "SSID_%02d" $i)" "$SETTINGS_FILE")
    vlan=$(read_json "$(printf "VLAN_%02d" $i)" "$SETTINGS_FILE")
    [ -z "$ssid" ] && ssid="unused-placeholder"
    [ -z "$vlan" ] && vlan="none"

    if [ "$ssid" != "unused-placeholder" ]; then
      validate_vlan_id "$vlan" || { i=$((i+1)); continue; }
      # Use wait_for_interface with backoff instead of fixed retries
      IFN="$(find_if_by_ssid_any "$ssid")"
      if [ -n "$IFN" ] && wait_for_interface "$IFN"; then
        attach_to_bridge "$IFN" "$vlan" "SSID_$(printf "%02d" $i)"
        USED_SSIDS="$USED_SSIDS $ssid"
      else
        warn -c cli,vlan "SSID_$(printf "%02d" $i) '$ssid' not found on any band"
      fi
    else
      info -c cli,vlan "SSID_$(printf "%02d" $i) skipped"
    fi
    i=$((i+1))
  done

  # Restore any unconfigured SSIDs to br0 (untagged), excluding internal VAPs
  ALL_NVRAM_SSIDS=$(nvram show 2>/dev/null | grep '_ssid=' | awk -F= '{print $2}')
  for s in $ALL_NVRAM_SSIDS; do
    case " $USED_SSIDS " in
      *" $s "*) continue ;;
    esac
    iface=$(find_if_by_ssid_any "$s")
    [ -z "$iface" ] && continue
    is_internal_vap "$iface" && continue
    attach_to_bridge "$iface" "none" "Unconfigured SSID $s"
  done
}

# --------------------------
# Band resolution
# --------------------------
resolve_and_attach() {
  BAND="$1"
  SSID="$2"
  VLAN="$3"
  LABEL="$4"

  validate_vlan_id "$VLAN"

  if [ -z "$SSID" ] || [ "$SSID" = "unused-placeholder" ]; then
    info -c cli,vlan "$LABEL skipped"
    return
  fi

  IFN=""
  # Try up to 5 times to allow interfaces to appear
  for _ in 1 2 3 4 5; do
    if [ "$BAND" = "auto" ] || [ "$BAND" = "any" ] || [ -z "$BAND" ]; then
      for b in 0 1 2; do
        IFN="$(find_if_by_ssid "$b" "$SSID")"
        [ -n "$IFN" ] && break
      done
    else
      IFN="$(find_if_by_ssid "$BAND" "$SSID")"
    fi
    [ -n "$IFN" ] && break
    sleep 1
  done

  if [ -z "$IFN" ]; then
    if [ "$BAND" = "auto" ] || [ "$BAND" = "any" ] || [ -z "$BAND" ]; then
      warn -c cli,vlan "$LABEL SSID '$SSID' not found on any band"
    else
      warn -c cli,vlan "$LABEL SSID '$SSID' not found on band $BAND"
    fi
    return
  fi

  attach_to_bridge "$IFN" "$VLAN" "$LABEL ($SSID)"
}

# --------------------------
# Configuration Summary
# --------------------------
show_configuration_summary() {
  info -c cli,vlan "=== CONFIGURATION SUMMARY ==="
  
  # Show current bridge status
  info -c cli,vlan "Current bridge status:"
  brctl show 2>/dev/null | while read line; do
    info -c cli,vlan "  $line"
  done

  if [ "$DRY_RUN" = "yes" ]; then
    info -c cli,vlan "=== DRY-RUN COMPLETE ==="
    info -c cli,vlan "No changes were applied to the system"
    info -c cli,vlan "To apply changes, set DRY_RUN=no in settings.json"
  else
    info -c cli,vlan "=== CONFIGURATION APPLIED ==="
  fi
}

# --------------------------
# Cleanup
# --------------------------
cleanup_existing_config() {
  info -c cli,vlan "Cleaning up existing VLAN config..."
  
  # Remove VLAN bridges (except br0)
  for br in $(brctl show 2>/dev/null | awk 'NR>1 {print $1}' | grep -E '^br[1-9][0-9]*$'); do
    if [ "$DRY_RUN" = "yes" ]; then
      echo "[DRY-RUN] ip link set $br down; brctl delbr $br"
    else
      ip link set "$br" down 2>/dev/null
      brctl delbr "$br" 2>/dev/null
      info -c cli,vlan "Removed bridge $br"
      track_change "Removed bridge $br"
    fi
  done

  # Remove VLAN interfaces
  ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E "^${UPLINK_PORT}\\.[0-9]+(@|$)" | cut -d'@' -f1 | while read -r vif; do
    if [ "$DRY_RUN" = "yes" ]; then
      echo "[DRY-RUN] ip link del $vif"
    else
      ip link del "$vif" 2>/dev/null
      info -c cli,vlan "Removed VLAN interface $vif"
      track_change "Removed VLAN interface $vif"
    fi
  done
}

# --------------------------
# Service restart
# --------------------------
restart_services() {
  info -c cli,vlan "Restarting WiFi & bridge services..."
  [ "$DRY_RUN" = "yes" ] && return

  service restart_wireless 2>/dev/null
  sleep 2
  /sbin/service switch restart 2>/dev/null
  service restart_httpd 2>/dev/null
  if type eapd >/dev/null 2>&1 && [ -x /usr/sbin/eapd ]; then
    killall eapd 2>/dev/null
    /usr/sbin/eapd 2>/dev/null
  fi
}

# --------------------------
# Main Execution
# --------------------------
main() {
  validate_configuration
  info -c cli,vlan "Starting VLAN manager on $MODEL ($PRODUCTID)"
  info -c cli,vlan "WAN: $WAN_IF, Topology: $TOPOLOGY"
  info -c cli,vlan "Dry Run: $DRY_RUN, Persistent: $PERSISTENT"

  # Validate all settings first
  info -c cli,vlan "Validating VLAN settings..."
  
  # Validate Ethernet VLANs
  idx=1
  for eth in $ETH_PORTS; do
    vlan=$(read_json "ETH${idx}_VLAN" "$SETTINGS_FILE")
    [ -z "$vlan" ] && vlan="none"
    validate_vlan_id "$vlan"
    idx=$((idx+1))
  done

  # Validate SSID VLANs
  i=1
  while [ $i -le "$MAX_SSIDS" ]; do
    ssid=$(read_json "$(printf "SSID_%02d" $i)" "$SETTINGS_FILE")
    vlan=$(read_json "$(printf "VLAN_%02d" $i)" "$SETTINGS_FILE")
    [ -n "$ssid" ] && [ "$ssid" != "unused-placeholder" ] && validate_vlan_id "$vlan"
    i=$((i+1))
  done

  cleanup_existing_config

  # Bind Ethernet ports
  idx=1
  for eth in $ETH_PORTS; do
    vlan=$(read_json "ETH${idx}_VLAN" "$SETTINGS_FILE")
    [ -z "$vlan" ] && vlan="none"
    attach_to_bridge "$eth" "$vlan" "LAN Port $idx"
    idx=$((idx+1))
  done

  # Bind all configured SSIDs dynamically (1..MAX_SSIDS)
  bind_configured_ssids

  # Apply AP isolation policies across all SSIDs
  i=1
  while [ $i -le "$MAX_SSIDS" ]; do
    ssid=$(read_json "$(printf "SSID_%02d" $i)" "$SETTINGS_FILE")
    apiso=$(read_json "$(printf "APISO_%02d" $i)" "$SETTINGS_FILE")
    if [ -n "$ssid" ] && [ "$ssid" != "unused-placeholder" ] && [ -n "$apiso" ]; then
      iface=$(find_if_by_ssid_any "$ssid")
      if [ -n "$iface" ]; then
        set_ap_isolation "$iface" "$apiso"
      fi
    fi
    i=$((i+1))
  done

  [ "$DRY_RUN" = "yes" ] || {
    restart_services

    # Second pass to catch VAPs that spawn after wireless restart
    info -c cli,vlan "Second pass for new VAPs..."
    bind_configured_ssids
  }

  show_configuration_summary
}

main "$@"