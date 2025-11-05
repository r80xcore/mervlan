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

# ========================================================================== #
# JSON HELPERS — BusyBox-safe parsing for settings and hardware JSON files    #
# ========================================================================== #

# read_json — Extract scalar value from JSON file by key name
# Args: $1=key_name, $2=file_path
# Returns: stdout value (quoted string or bare number), or empty if not found
# Explanation: Uses sed with enhanced regex to handle escaped quotes. Prefers
#   quoted strings; falls back to bare values for numbers. Trims whitespace.
read_json() {
  key="$1"; file="$2"
  # Enhanced regex to handle escaped quotes in values
  # Try quoted string first, then bare value (for numbers), extract first match
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p; s/.*\"$key\"[[:space:]]*:[[:space:]]*\([^,}\"]*\).*/\1/p" "$file" | head -1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# read_json_number — Extract numeric value from JSON key (grep only digits)
# Args: $1=key_name, $2=file_path
# Returns: stdout numeric value, or empty if not found or non-numeric
read_json_number() { 
  # Pipe read_json output through grep to extract leading digits only
  read_json "$1" "$2" | grep -o '^[0-9]\+' 
}

# read_json_array — Extract JSON array and flatten to space-separated values
# Args: $1=key_name, $2=file_path
# Returns: stdout space-separated values (quotes and commas removed)
# Explanation: Extracts [a,b,c] bracket content, removes whitespace/quotes/commas
read_json_array() {
  key="$1"; file="$2"
  # Extract content between [ and ], then normalize spacing and separators
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p" "$file" \
    | sed 's/[[:space:]]//g; s/"//g; s/,/ /g'
}

# ========================================================================== #
# INITIALIZATION & HARDWARE DETECTION — Load configs and validate setup       #
# ========================================================================== #

# Verify required settings files exist; exit if missing
[ -f "$HW_SETTINGS_FILE" ] || error -c cli,vlan "Missing $HW_SETTINGS_FILE"
[ -f "$SETTINGS_FILE" ] || error -c cli,vlan "Missing $SETTINGS_FILE"

# Extract hardware profile from hw_settings.json
MODEL=$(read_json MODEL "$HW_SETTINGS_FILE")
PRODUCTID=$(read_json PRODUCTID "$HW_SETTINGS_FILE")
MAX_SSIDS=$(read_json_number MAX_SSIDS "$HW_SETTINGS_FILE")
ETH_PORTS=$(read_json_array ETH_PORTS "$HW_SETTINGS_FILE")
WAN_IF=$(read_json WAN_IF "$HW_SETTINGS_FILE")

# Extract user configuration from settings.json
TOPOLOGY="switch"
PERSISTENT=$(read_json PERSISTENT "$SETTINGS_FILE")
DRY_RUN=$(read_json DRY_RUN "$SETTINGS_FILE")

# Apply defaults for unconfigured values
[ -z "$MAX_SSIDS" ] && MAX_SSIDS=12
[ "$MAX_SSIDS" -gt 12 ] && MAX_SSIDS=12
[ -z "$PERSISTENT" ] && PERSISTENT="no"
[ -z "$DRY_RUN" ] && DRY_RUN="yes"
[ -z "$WAN_IF" ] && WAN_IF="eth0"

# Resolve bridge and WAN interface
UPLINK_PORT="$WAN_IF"
DEFAULT_BRIDGE="br0"

# ========================================================================== #
# STATE TRACKING & AUDIT — Change log, cleanup on exit, change tracking      #
# ========================================================================== #

# Per-execution change log (cleaned up on exit via trap)
CHANGE_LOG="$CHANGES/vlan_changes.$$"
cleanup_on_exit() {
    # Remove per-execution change log file
    [ -f "$CHANGE_LOG" ] && rm -f "$CHANGE_LOG"
}
trap cleanup_on_exit EXIT INT TERM

# track_change — Log configuration changes with timestamp for audit trail
# Args: $1=change_description (string)
# Returns: none (appends to $CHANGE_LOG)
track_change() {
  # Append change with ISO timestamp and shell PID for tracking
  echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$CHANGE_LOG"
}

# ========================================================================== #
# CONFIGURATION VALIDATION — Pre-flight checks and sanity validation         #
# ========================================================================== #

# validate_configuration — Verify settings and hardware files exist and warn on defaults
# Args: none (uses global paths $SETTINGS_FILE, $HW_SETTINGS_FILE)
# Returns: none (exits if critical files missing, warns on missing values)
validate_configuration() {
  # Check for required configuration files
  [ -f "$SETTINGS_FILE" ] || error -c cli,vlan "Settings file missing"
  [ -f "$HW_SETTINGS_FILE" ] || error -c cli,vlan "Hardware settings file missing"
  # Warn on missing hardware identification (non-critical, uses defaults)
  [ -n "$MODEL" ] || warn -c cli,vlan "MODEL not defined in hardware settings; using defaults"
  [ -n "$PRODUCTID" ] || warn -c cli,vlan "PRODUCTID not defined in hardware settings; using defaults"
  # Warn on missing capacity hints (non-critical, uses defaults)
  [ -n "$MAX_SSIDS" ] || warn -c cli,vlan "MAX_SSIDS not defined; defaulting to 12"
  [ -n "$ETH_PORTS" ] || warn -c cli,vlan "ETH_PORTS not defined; no Ethernet ports will be configured"
}

# wait_for_interface — Poll interface with exponential backoff until ready or timeout
# Args: $1=interface_name
# Returns: 0 if interface exists, 1 if timeout after ~1+2+4+8+16=31 seconds
# Explanation: Exponential backoff prevents busy-waiting. Useful for VAPs that appear after wireless restart.
wait_for_interface() {
  local iface="$1" max_attempts=10 attempt=0
  # Poll up to 10 times with exponential sleep: 1s, 2s, 4s, 8s, 16s, 32s, 64s, 128s, 256s, 512s
  while [ $attempt -lt $max_attempts ]; do
    # Check if interface exists in /sys/class/net
    iface_exists "$iface" && return 0
    # Exponential backoff: 2^attempt seconds
    sleep $((2 ** attempt))
    attempt=$((attempt + 1))
  done
  # Timeout: interface never appeared
  return 1
}

}

# ========================================================================== #
# CORE VLAN FUNCTIONS — Bridge management, VLAN creation, interface attachment  #
# ========================================================================== #

# iface_exists — Check if network interface exists in kernel
# Args: $1=interface_name
# Returns: 0 if present, 1 if not found
iface_exists() { [ -d "/sys/class/net/$1" ]; }

# is_number — Check if string is a valid integer
# Args: $1=value
# Returns: 0 if integer, 1 otherwise
is_number()    { expr "$1" + 0 >/dev/null 2>&1; }

# is_internal_vap — Detect if interface is internal VAP (non-user-facing)
# Args: $1=interface_name (e.g., wl0, wl0.4, wl0.5)
# Returns: 0 if internal, 1 if user-facing
# Explanation: Internal VAPs are slots 4-9 on each band (slots 0-3 are user-facing)
is_internal_vap() {
  # Match pattern wl[0-2].[4-9] (internal slots on any band)
  case "$1" in wl[0-2].[4-9]) return 0;; esac
  return 1
}

# validate_vlan_id — Check if VLAN ID is valid (1-4094 reserved range)
# Args: $1=vlan_id (number, "none", "trunk", or empty)
# Returns: 0 if valid, 1 if invalid
# Explanation: VLAN 1 is reserved LAN (native). Valid user VLANs: 2-4094. Special: "none"=untagged, "trunk"=passthrough
validate_vlan_id() {
  case "$1" in
   ""|none|trunk) return 0 ;;
  esac

  # Check numeric range: only 2-4094 allowed (1 is reserved LAN)
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

# remove_from_all_bridges — Detach interface from all bridges (cleanup before reassignment)
# Args: $1=interface_name
# Returns: none (best-effort, ignores errors)
remove_from_all_bridges() {
  iface="$1"
  # List all bridges and remove this interface from each (ignores "interface not in bridge" errors)
  for br in $(brctl show 2>/dev/null | awk 'NR>1 {print $1}'); do
    brctl delif "$br" "$iface" 2>/dev/null
  done
}

# ensure_vlan_bridge — Create VLAN interface and bridge if not present
# Args: $1=vlan_id
# Returns: 0 on success, 1 on failure
# Explanation: Creates eth0.VID (VLAN interface) and brVID (bridge) for tagged traffic
ensure_vlan_bridge() {
  VID="$1"
  # Skip special cases: "none" and "trunk" don't need infrastructure
  [ "$VID" = "none" ] || [ "$VID" = "trunk" ] && return 0

  # Check if VLAN interface already exists (eth0.VID, for example)
  if ! iface_exists "${UPLINK_PORT}.${VID}"; then
    if [ "$DRY_RUN" = "yes" ]; then
      # Dry-run: show what would be executed
      echo "[DRY-RUN] ip link add link $UPLINK_PORT name ${UPLINK_PORT}.${VID} type vlan id $VID"
      echo "[DRY-RUN] ip link set ${UPLINK_PORT}.${VID} up"
    else
      # Create VLAN sub-interface (e.g., eth0.100)
      ip link add link "$UPLINK_PORT" name "${UPLINK_PORT}.${VID}" type vlan id "$VID" 2>/dev/null || {
        error -c cli,vlan "Failed to create VLAN interface ${UPLINK_PORT}.${VID}"
        return 1
      }
      # Bring interface up (enter active state)
      ip link set "${UPLINK_PORT}.${VID}" up 2>/dev/null
      info -c cli,vlan "Created VLAN interface ${UPLINK_PORT}.${VID}"
      track_change "Created VLAN interface ${UPLINK_PORT}.${VID}"
    fi
  fi

  # Check if bridge brVID exists (e.g., br100)
  if ! brctl show 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "br${VID}"; then
    if [ "$DRY_RUN" = "yes" ]; then
      echo "[DRY-RUN] brctl addbr br${VID}"
      echo "[DRY-RUN] brctl addif br${VID} ${UPLINK_PORT}.${VID}"
      echo "[DRY-RUN] ip link set br${VID} up"
    else
      # Create bridge interface
      brctl addbr "br${VID}" 2>/dev/null || {
        error -c cli,vlan "Failed to create bridge br${VID}"
        return 1
      }
      # Add VLAN interface to bridge
      brctl addif "br${VID}" "${UPLINK_PORT}.${VID}" 2>/dev/null
      # Bring bridge up (enter active state)
      ip link set "br${VID}" up 2>/dev/null
      info -c cli,vlan "Created bridge br${VID}"
      track_change "Created bridge br${VID}"
    fi
  fi
}

# attach_to_bridge — Attach interface to appropriate bridge based on VLAN config
# Args: $1=interface, $2=vlan_id, $3=label (for logging)
# Returns: none (logs errors, continues on non-critical failures)
# Explanation: Validates VLAN, filters internal VAPs, ensures bridge exists, adds interface
attach_to_bridge() {
  IF="$1"
  VID="$2"
  LABEL="$3"

  # Validate VLAN ID before attempting attachment
  validate_vlan_id "$VID" || { warn -c cli,vlan "Invalid VLAN $VID for $LABEL, skipping"; return; }

  # Skip internal VAPs (e.g., wl0.4-9 are internal; wl0, wl0.1-3 are user-facing)
  is_internal_vap "$IF" && { warn -c cli,vlan "$LABEL ($IF) looks internal; skipping"; return; }
  # Verify interface exists in kernel before attachment
  iface_exists "$IF" || { warn -c cli,vlan "$LABEL ($IF) - not present, skipping"; return; }

  # Detach from all bridges before reattachment (unless dry-run mode)
  [ "$DRY_RUN" = "yes" ] || remove_from_all_bridges "$IF"

  # Attach interface to appropriate bridge based on VLAN ID
  case "$VID" in
    none)
      # Attach to default bridge br0 (untagged LAN)
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
      # Trunk mode: leave unconfigured (passthrough, no bridge)
      info -c cli,vlan "$LABEL set as trunk (no bridge)"
      ;;
    *)
      # Attach to VLAN bridge (e.g., br100 for VLAN 100)
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

# ========================================================================== #
# SSID RESOLUTION — Find wireless interfaces by SSID name                    #
# ========================================================================== #

# find_if_by_ssid — Locate interface on specific band by SSID name
# Args: $1=band (0|1|2), $2=ssid_name
# Returns: stdout interface_name (e.g., wl0, wl0.1), or empty if not found
# Explanation: Tries base radio first (main SSID), then guest slots 1-3
find_if_by_ssid() {
  BAND="$1"
  TARGET="$2"

  [ -z "$TARGET" ] && return 1
  # Skip placeholder SSIDs (used to mark unused slots in settings)
  [ "$TARGET" = "unused-placeholder" ] && return 1

  # Try base radio first (primary SSID on band, e.g., wl0, wl1, wl2)
  # Check if SSID matches and interface exists and is ready
  SSID_BASE="$(nvram get wl${BAND}_ssid 2>/dev/null)"
  IF_BASE="$(nvram get wl${BAND}_ifname 2>/dev/null)"
  if [ "$SSID_BASE" = "$TARGET" ] && [ -n "$IF_BASE" ] && iface_exists "$IF_BASE"; then
    echo "$IF_BASE"
    return 0
  fi

  # Try guest AP slots 1, 2, 3 (VAPs on base band, e.g., wl0.1, wl0.2, wl0.3)
  for slot in 1 2 3; do
    # Query NVRAM for guest slot SSID (wl0.1_ssid format)
    SSID="$(nvram get wl${BAND}.${slot}_ssid 2>/dev/null)"
    [ "$SSID" = "$TARGET" ] || continue
    # Get interface name for this slot
    IFN="$(nvram get wl${BAND}.${slot}_ifname 2>/dev/null)"
    if [ -n "$IFN" ] && iface_exists "$IFN"; then
      echo "$IFN"
      return 0
    fi
  done
  
  return 1
}

# find_if_by_ssid_any — Robust SSID lookup across all bands/slots (fallback)
# Args: $1=ssid_name
# Returns: stdout interface_name, or empty if not found
# Explanation: Scans all NVRAM *_ssid entries, finds first matching interface
# Use case: Fallback when band/slot unknown, or user moves SSID between bands
find_if_by_ssid_any() {
  ssid="$1"
  [ -z "$ssid" ] && return 1
  # Extract all NVRAM keys with matching SSID value (e.g., wl0_ssid=MySSID)
  keys=$(nvram show 2>/dev/null | grep '_ssid=' | grep -F "=${ssid}" | awk -F= '{print $1}' | sed 's/_ssid$//')
  for key in $keys; do
    # Get interface name for this NVRAM key root (e.g., wl0 -> wl0_ifname)
    iface=$(nvram get ${key}_ifname 2>/dev/null)
    # Verify interface is valid wireless VAP (starts with wl) and exists in kernel
    if [ -n "$iface" ] && echo "$iface" | grep -q '^wl' && iface_exists "$iface"; then
      echo "$iface"
      return 0
    fi
  done
  return 1
}

# ========================================================================== #
# AP ISOLATION & SSID BINDING — Wireless policy and bridge attachment        #
# ========================================================================== #

# set_ap_isolation — Enable/disable AP isolation (privacy between clients on same SSID)
# Args: $1=interface, $2=value (0=off, 1=on)
# Returns: none (logs errors on failure, continues)
# Explanation: Uses wl command for immediate effect; persists via NVRAM if requested
set_ap_isolation() {
  IFN="$1"; VAL="$2"  # 0 or 1
  case "$VAL" in
    0|1)
      if [ "$DRY_RUN" = "yes" ]; then
        echo "[DRY-RUN] wl -i $IFN ap_isolate $VAL"
      else
        # Apply AP isolation immediately on interface
        wl -i "$IFN" ap_isolate "$VAL" 2>/dev/null || {
          error -c cli,vlan "Failed to set AP isolation=$VAL for $IFN"
          return 1
        }
        info -c cli,vlan "Set AP isolation=$VAL for $IFN"
        # Persist in NVRAM for specific bands/slots (wl0, wl0.1, etc.)
        case "$IFN" in wl[0-2]|wl[0-2].[1-3]) nvram set "${IFN}_ap_isolate=$VAL" ;; esac
        [ "$PERSISTENT" = "yes" ] && nvram commit
        track_change "Set AP isolation=$VAL for $IFN"
      fi
      ;;
  esac
}

# bind_configured_ssids — Dynamically bind all configured SSIDs to VLAN bridges
# Args: none (reads SETTINGS_FILE)
# Returns: none (logs all actions)
# Explanation: SSID_01-SSID_MAX_SSIDS, each with corresponding VLAN_01-VLAN_MAX_SSIDS
# Also restores unconfigured SSIDs to br0 (prevents orphaning on VLAN changes)
bind_configured_ssids() {
  USED_SSIDS=""
  i=1
  # Loop through all SSID slots (SSID_01, SSID_02, etc. up to MAX_SSIDS)
  while [ $i -le "$MAX_SSIDS" ]; do
    # Read SSID and VLAN settings from JSON (printf %02d = zero-padded decimal)
    ssid=$(read_json "$(printf "SSID_%02d" $i)" "$SETTINGS_FILE")
    vlan=$(read_json "$(printf "VLAN_%02d" $i)" "$SETTINGS_FILE")
    # Apply defaults: empty SSID = placeholder, empty VLAN = untagged (none)
    [ -z "$ssid" ] && ssid="unused-placeholder"
    [ -z "$vlan" ] && vlan="none"

    if [ "$ssid" != "unused-placeholder" ]; then
      validate_vlan_id "$vlan" || { i=$((i+1)); continue; }
      # Find interface for this SSID (searches all bands/slots)
      # Uses wait_for_interface with exponential backoff for VAP boot-up delay
      IFN="$(find_if_by_ssid_any "$ssid")"
      if [ -n "$IFN" ] && wait_for_interface "$IFN"; then
        # Attach to appropriate bridge (br0, brVID, or trunk)
        attach_to_bridge "$IFN" "$vlan" "SSID_$(printf "%02d" $i)"
        # Track which SSIDs are configured (for restoration logic below)
        USED_SSIDS="$USED_SSIDS $ssid"
      else
        warn -c cli,vlan "SSID_$(printf "%02d" $i) '$ssid' not found on any band"
      fi
    else
      info -c cli,vlan "SSID_$(printf "%02d" $i) skipped"
    fi
    i=$((i+1))
  done

  # Restore unconfigured SSIDs to br0 (prevents orphaning if VLAN config changed)
  # Query all NVRAM SSIDs, restore any not in configured list
  ALL_NVRAM_SSIDS=$(nvram show 2>/dev/null | grep '_ssid=' | awk -F= '{print $2}')
  for s in $ALL_NVRAM_SSIDS; do
    # Skip if this SSID was explicitly configured
    case " $USED_SSIDS " in
      *" $s "*) continue ;;
    esac
    # Find interface for unconfigured SSID
    iface=$(find_if_by_ssid_any "$s")
    [ -z "$iface" ] && continue
    # Skip internal VAPs (e.g., wl0.4-9)
    is_internal_vap "$iface" && continue
    # Attach to default bridge (untagged LAN)
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
  
  # Display current bridge topology from brctl
  info -c cli,vlan "Current bridge status:"
  brctl show 2>/dev/null | while read line; do
    info -c cli,vlan "  $line"
  done

  if [ "$DRY_RUN" = "yes" ]; then
    # Dry-run mode: remind user no changes were made
    info -c cli,vlan "=== DRY-RUN COMPLETE ==="
    info -c cli,vlan "No changes were applied to the system"
    info -c cli,vlan "To apply changes, set DRY_RUN=no in settings.json"
  else
    # Live mode: confirm configuration was applied
    info -c cli,vlan "=== CONFIGURATION APPLIED ==="
  fi
}

# ========================================================================== #
# CLEANUP & SERVICE RESTART — Remove old config, restart affected services   #
# ========================================================================== #

# cleanup_existing_config — Remove VLAN infrastructure from previous runs
# Args: none
# Returns: none (logs all actions)
# Explanation: Removes all VLAN bridges (br1+) and VLAN interfaces (eth0.VID+)
# Preserves br0 (default LAN bridge)
cleanup_existing_config() {
  info -c cli,vlan "Cleaning up existing VLAN config..."
  
  # Remove VLAN bridges (except br0 - the default LAN bridge)
  # Iterate through all bridges, remove those numbered br1+ (custom VLANs)
  for br in $(brctl show 2>/dev/null | awk 'NR>1 {print $1}' | grep -E '^br[1-9][0-9]*$'); do
    if [ "$DRY_RUN" = "yes" ]; then
      echo "[DRY-RUN] ip link set $br down; brctl delbr $br"
    else
      # Bring bridge down before deletion
      ip link set "$br" down 2>/dev/null
      # Remove bridge interface
      brctl delbr "$br" 2>/dev/null
      info -c cli,vlan "Removed bridge $br"
      track_change "Removed bridge $br"
    fi
  done

  # Remove VLAN interfaces (eth0.100, eth0.200, etc.)
  # Parse ip link output for VLAN sub-interfaces (format: "eth0.100@eth0")
  ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E "^${UPLINK_PORT}\\.[0-9]+(@|$)" | cut -d'@' -f1 | while read -r vif; do
    if [ "$DRY_RUN" = "yes" ]; then
      echo "[DRY-RUN] ip link del $vif"
    else
      # Delete VLAN interface
      ip link del "$vif" 2>/dev/null
      info -c cli,vlan "Removed VLAN interface $vif"
      track_change "Removed VLAN interface $vif"
    fi
  done
}

# restart_services — Restart WiFi, bridge, and web server after configuration
# Args: none
# Returns: none (logs all actions)
# Explanation: Restarts wireless to pick up new VAP configuration, then resets
# bridge and HTTP services. Handles optional eapd (EAP daemon) if present.
restart_services() {
  info -c cli,vlan "Restarting WiFi & bridge services..."
  # Skip if dry-run mode
  [ "$DRY_RUN" = "yes" ] && return

  # Restart wireless radio drivers and VAP configuration
  service restart_wireless 2>/dev/null
  sleep 2
  # Restart switch (bridge) driver to apply port configuration
  /sbin/service switch restart 2>/dev/null
  # Restart web server (httpd) for UI refresh
  service restart_httpd 2>/dev/null
  # Restart EAP daemon if present (used for 802.1X auth on some models)
  if type eapd >/dev/null 2>&1 && [ -x /usr/sbin/eapd ]; then
    killall eapd 2>/dev/null
    /usr/sbin/eapd 2>/dev/null
  fi
}

}

# ========================================================================== #
# MAIN EXECUTION — Orchestrate VLAN configuration application flow           #
# ========================================================================== #

# main — Entry point: validate, cleanup, configure, and verify
# Args: none (reads all global configuration)
# Returns: none (exit code via mervlan_manager.sh script)
main() {
  # Pre-flight validation: verify required files and settings exist
  validate_configuration
  
  # Log startup information
  info -c cli,vlan "Starting VLAN manager on $MODEL ($PRODUCTID)"
  info -c cli,vlan "WAN: $WAN_IF, Topology: $TOPOLOGY"
  info -c cli,vlan "Dry Run: $DRY_RUN, Persistent: $PERSISTENT"

  # Validation phase 1: check all VLAN IDs for syntax errors before any changes
  info -c cli,vlan "Validating VLAN settings..."
  
  # Validate Ethernet port VLAN assignments (ETH1_VLAN, ETH2_VLAN, etc.)
  idx=1
  for eth in $ETH_PORTS; do
    vlan=$(read_json "ETH${idx}_VLAN" "$SETTINGS_FILE")
    [ -z "$vlan" ] && vlan="none"
    # Validate VLAN ID syntax (will error and stop if invalid)
    validate_vlan_id "$vlan"
    idx=$((idx+1))
  done

  # Validate SSID VLAN assignments (VLAN_01-VLAN_MAX_SSIDS)
  i=1
  while [ $i -le "$MAX_SSIDS" ]; do
    ssid=$(read_json "$(printf "SSID_%02d" $i)" "$SETTINGS_FILE")
    vlan=$(read_json "$(printf "VLAN_%02d" $i)" "$SETTINGS_FILE")
    # Only validate if SSID is configured (not empty or placeholder)
    [ -n "$ssid" ] && [ "$ssid" != "unused-placeholder" ] && validate_vlan_id "$vlan"
    i=$((i+1))
  done

  # Cleanup phase: remove old VLAN infrastructure from previous runs
  cleanup_existing_config

  # Configuration phase 1: Attach Ethernet LAN ports to appropriate bridges
  idx=1
  for eth in $ETH_PORTS; do
    vlan=$(read_json "ETH${idx}_VLAN" "$SETTINGS_FILE")
    [ -z "$vlan" ] && vlan="none"
    # Attach Ethernet port to br0 (untagged) or brVID (tagged)
    attach_to_bridge "$eth" "$vlan" "LAN Port $idx"
    idx=$((idx+1))
  done

  # Configuration phase 2: Bind all configured SSIDs dynamically (1..MAX_SSIDS)
  # This includes restoring unconfigured SSIDs to br0
  bind_configured_ssids

  # Configuration phase 3: Apply AP isolation policies across all SSIDs
  # Iterate through configured SSIDs and apply APISO_01-APISO_MAX_SSIDS settings
  i=1
  while [ $i -le "$MAX_SSIDS" ]; do
    ssid=$(read_json "$(printf "SSID_%02d" $i)" "$SETTINGS_FILE")
    apiso=$(read_json "$(printf "APISO_%02d" $i)" "$SETTINGS_FILE")
    # Apply AP isolation if SSID is configured and APISO value is set
    if [ -n "$ssid" ] && [ "$ssid" != "unused-placeholder" ] && [ -n "$apiso" ]; then
      iface=$(find_if_by_ssid_any "$ssid")
      if [ -n "$iface" ]; then
        set_ap_isolation "$iface" "$apiso"
      fi
    fi
    i=$((i+1))
  done

  # Service restart phase: only if not in dry-run mode
  [ "$DRY_RUN" = "yes" ] || {
    # Restart WiFi services to pick up new VAP configuration
    restart_services

    # Second pass for new VAPs that appear after wireless restart
    # Some VAPs may not exist until after restart_wireless completes
    info -c cli,vlan "Second pass for new VAPs..."
    bind_configured_ssids
  }

  # Summary: display final configuration status
  show_configuration_summary
}

# Entry point: call main with command-line arguments
main "$@"