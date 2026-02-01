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
#                - File: collect_local_clients.sh || version="0.46"            #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Collect VLAN→client info via bridge FDB (MAC-only) on local    #
#               node so it can be collected by collect_clients.sh.             #
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

export PATH="/sbin:/bin:/usr/sbin:/usr/bin"
umask 022
# Log available commands for debugging purposes (help diagnose missing tools)
logger -t "VLANMgr" "collect_local_clients: PATH=$PATH"
# Check that all required commands are available in the environment
for cmd in ip brctl awk grep sed; do
  command -v "$cmd" >/dev/null 2>&1 || logger -t "VLANMgr" "collect_local_clients: missing cmd $cmd"
done
# =========================================== End of MerVLAN environment setup #

# ============================================================================ #
#                            CONFIGURATION & SETUP                             #
# Parse command-line arguments for output path and node name. Initialize       #
# FDB (Forwarding Database) collection parameters with safe defaults.          #
# ============================================================================ #

# Output file path; defaults to $COLLECTDIR/clients_local.json if not provided
OUT="${1:-$COLLECTDIR/clients_local.json}"
# Node/router name for identification in JSON; defaults to system hostname
NODE_NAME="${2:-$(hostname)}"
# Whether to attempt reverse-DNS lookup for MAC addresses (disabled by default)
RESOLVE_HOSTNAMES="${RESOLVE_HOSTNAMES:-0}"

# Number of retries when reading bridge FDB (retry if incomplete read)
FDB_RETRIES="${FDB_RETRIES:-3}"
# Sleep duration (seconds) between FDB read retry attempts
FDB_RETRY_SLEEP="${FDB_RETRY_SLEEP:-1}"

# Cleanup handler for temp files on exit/interrupt
cleanup_local_collect() {
  # Remove per-bridge temp files
  rm -f "$COLLECTDIR"/mac_br*.lst "$COLLECTDIR"/mac_exclude.lst 2>/dev/null
  rm -f "$COLLECTDIR"/mac_br*.lst.tmp "$COLLECTDIR"/mac_counts.tmp 2>/dev/null
}
trap 'cleanup_local_collect' EXIT INT TERM

info -c vlan "Collecting VLAN clients (MAC-only) on $NODE_NAME"
info -c cli  "Collecting VLAN clients (MAC-only) on $NODE_NAME"
info -c cli  "collect_local_clients: COLLECTDIR='$COLLECTDIR' OUT='$OUT'"

# ============================================================================ #
#                             HELPER FUNCTIONS                                 #
# Utility functions for JSON escaping, bridge enumeration, and MAC address     #
# collection from bridge forwarding databases (FDB).                           #
# ============================================================================ #

# ============================================================================ #
# json_escape                                                                  #
# Escape backslashes and double-quotes in a string to produce valid JSON       #
# string literals. Prevents JSON injection and format corruption.              #
# ============================================================================ #
json_escape() { 
  # Escape backslashes first (\ becomes \\), then quotes (" becomes \")
  echo "$1" | sed -e 's/\\/\\\\/g' -e 's/\"/\\\"/g'; 
}

# ============================================================================ #
# get_bridges                                                                  #
# List all VLAN bridge interfaces (br1, br2, etc.) excluding br0.              #
# Uses numeric sort to ensure natural ordering (br2 before br10).              #
# ============================================================================ #
get_bridges() {
  # List all network interfaces in /sys/class/net matching br[0-9]+ pattern
  ls /sys/class/net/ 2>/dev/null \
    | grep -E '^br[0-9]+$' \
    | grep -v '^br0$' \
    | sed 's/^br//' \
    | sort -n \
    | sed 's/^/br/'
}

# ============================================================================ #
# get_bridge_members                                                           #
# List all interfaces attached to a bridge by reading /sys/class/net/brX/brif  #
# ============================================================================ #
get_bridge_members() {
  local bridge="$1"
  ls "/sys/class/net/$bridge/brif/" 2>/dev/null
}

# ============================================================================ #
# classify_interface                                                           #
# Determine interface type: ssid, access, trunk-tagged, internal, or unknown   #
# Returns: type|base_port (e.g., "ssid|wl0.1" or "trunk-tagged|eth1")          #
# NOTE: eth0 is the internal switch fabric on Asus routers, not user-facing.   #
#       Only eth1-eth7 are actual LAN ports that users can configure.          #
# ============================================================================ #
classify_interface() {
  local iface="$1"
  case "$iface" in
    wl[0-9]*|wl[0-9]*.[0-9]*)
      # Wireless interface (SSID) - always single VLAN, never trunk
      echo "ssid|$iface"
      ;;
    eth0|eth0.[0-9]*)
      # eth0 is internal switch fabric - not user-facing, skip display
      echo "internal|$iface"
      ;;
    eth[1-9].[0-9]*|eth[1-9][0-9].[0-9]*)
      # Tagged VLAN sub-interface on user LAN port (trunk port)
      # Extract base port: eth1.100 -> eth1
      base_port="${iface%%.*}"
      echo "trunk-tagged|$base_port"
      ;;
    eth[1-9]|eth[1-9][0-9])
      # Untagged user LAN port (access or trunk native)
      echo "access|$iface"
      ;;
    vlan[0-9]*)
      # VLAN interface (sometimes used on some firmware)
      echo "vlan-if|$iface"
      ;;
    *)
      echo "unknown|$iface"
      ;;
  esac
}

# ============================================================================ #
# get_trunk_ports                                                              #
# Find user-facing LAN ports (eth1-eth7) that have VLAN sub-interfaces         #
# NOTE: Excludes eth0 which is internal switch fabric, not a user trunk        #
# Returns: list of base ports that are trunks (e.g., "eth1 eth2")              #
# ============================================================================ #
get_trunk_ports() {
  # Find all eth[1-9]*.VLAN interfaces (exclude eth0), extract base port
  ls /sys/class/net/ 2>/dev/null \
    | grep -E '^eth[1-9][0-9]*\.[0-9]+$' \
    | sed 's/\.[0-9]*$//' \
    | sort | uniq -c \
    | awk '$1 >= 1 {print $2}'
}

# ============================================================================ #
# get_trunk_vlans                                                              #
# For a given base port, list all tagged VLANs (from eth*.VLAN interfaces)     #
# Returns: comma-separated VLAN IDs                                            #
# ============================================================================ #
get_trunk_vlans() {
  local base_port="$1"
  ls /sys/class/net/ 2>/dev/null \
    | grep -E "^${base_port}\.[0-9]+$" \
    | sed "s/^${base_port}\.//" \
    | sort -n \
    | tr '\n' ',' \
    | sed 's/,$//'
}

# ============================================================================ #
# get_trunk_native_vlan                                                        #
# Find native/untagged VLAN for a trunk port (if base port is on a bridge)     #
# Returns: VLAN ID or empty if not found                                       #
# ============================================================================ #
get_trunk_native_vlan() {
  local base_port="$1"
  # Check each bridge to see if the untagged base port is a member
  for br in $(get_bridges) br0; do
    if [ -d "/sys/class/net/$br/brif/$base_port" ]; then
      # Extract VLAN ID from bridge name (br0 = native/untagged)
      vlan_id="${br#br}"
      [ "$vlan_id" = "0" ] && vlan_id="native"
      echo "$vlan_id"
      return 0
    fi
  done
  echo ""
}

# ============================================================================ #
# is_trunk_mac                                                                 #
# Check if a MAC appears on interfaces belonging to the same trunk port        #
# This prevents excluding legitimate trunk-connected clients                   #
# ============================================================================ #
TRUNK_PORTS=""
init_trunk_detection() {
  TRUNK_PORTS=$(get_trunk_ports)
}

# ============================================================================ #
# collect_macs_for_bridge                                                      #
# Query bridge FDB and extract non-local (learned) MAC addresses. Retry        #
# multiple times in case FDB is incomplete on first read. Deduplicate output.  #
# ============================================================================ #
collect_macs_for_bridge() {
  local bridge="$1"
  local out="$2"
  local i=0
  local tmp
  # Temporary file for accumulating MACs across retries
  tmp="${out}.tmp"
  info -c cli "collect_local_clients: collecting bridge='$bridge' out='$out' tmp='$tmp'"
  # Initialize temporary file as empty
  : > "$tmp"
  # Retry loop: collect FDB multiple times to handle transient reads
  while [ $i -lt "$FDB_RETRIES" ]; do
    # Extract non-local MACs from brctl output (column 3 == "no" means not local)
    # brctl showmacs format: port_no mac_addr is_local age_in_secs
    brctl showmacs "$bridge" 2>/dev/null | awk '$3=="no"{print tolower($2)}' >> "$tmp"
    i=$((i+1))
    # Sleep between retries if more attempts remain
    [ $i -lt "$FDB_RETRIES" ] && sleep "$FDB_RETRY_SLEEP"
  done
  # Deduplicate and sort MACs; write to final output file
  sort -u "$tmp" > "$out"
  # Clean up temporary file
  rm -f "$tmp"
}

# ============================================================================ #
#                         INITIALIZE JSON OUTPUT                               #
# Create output JSON file with header structure, timestamps, and router name.  #
# Begin the vlans array which will be populated in main loop.                  #
# ============================================================================ #

# Capture current timestamp in ISO 8601 format for "generated" field
DATE_NOW=$(date +'%Y-%m-%dT%H:%M:%S')

# Write JSON header with metadata (not yet closing vlans array)
{
  echo "{"
  printf '  "generated": "%s",\n' "$DATE_NOW"
  printf '  "router": "%s",\n' "$(json_escape "$NODE_NAME")"
  echo '  "vlans": ['
} > "$OUT"

# ============================================================================ #
#                       BRIDGE ENUMERATION & MACs COLLECTION                   #
# Iterate through all VLAN bridges and collect learned MAC addresses from      #
# each bridge FDB. Clean up previous temp files to avoid stale data merges.    #
# ============================================================================ #

# Track whether this is the first VLAN (no leading comma) or subsequent
FIRST_VLAN=true
# Counter for total unique clients found across all VLANs
TOTAL_COUNT=0
# Ensure collection directory exists
mkdir -p "$COLLECTDIR" 2>/dev/null

# Clean previous per-bridge temp lists to avoid stale merges on re-run
rm -f "$COLLECTDIR"/mac_br*.lst "$COLLECTDIR"/mac_exclude.lst 2>/dev/null

# Get list of all VLAN bridges on this system
BR_LIST="$(get_bridges)"

# ============================================================================ #
# PASS 1: Gather MACs per bridge                                               #
# For each VLAN bridge, collect non-local MACs and store in per-bridge file.   #
# ============================================================================ #
for BR in $BR_LIST; do
  # Per-bridge MAC list file (will be deduplicated within collect_macs_for_bridge)
  MACS_FILE="$COLLECTDIR/mac_${BR}.lst"
  info -c cli "collect_local_clients: bridge=$BR macs_file='$MACS_FILE'"
  # Collect MACs from this bridge's FDB with retries
  collect_macs_for_bridge "$BR" "$MACS_FILE"
done

# ============================================================================ #
# PASS 2: Identify trunk ports and upstream MACs                               #
# Find MACs that appear on 2+ bridges. For trunk ports, don't exclude MACs     #
# that appear on multiple VLANs of the same physical trunk.                    #
# ============================================================================ #

# Initialize trunk port detection
init_trunk_detection
info -c cli "Detected trunk ports: ${TRUNK_PORTS:-none}"

# Build a mapping of which VLANs each trunk port carries
# Format: trunk_eth1_vlans="10,20,30"
for trunk in $TRUNK_PORTS; do
  vlans=$(get_trunk_vlans "$trunk")
  native=$(get_trunk_native_vlan "$trunk")
  eval "trunk_${trunk}_tagged=\"$vlans\""
  eval "trunk_${trunk}_native=\"$native\""
  info -c cli "Trunk $trunk: tagged=[$vlans] native=[$native]"
done

# File to store MACs seen on multiple bridges (potential upstream)
EXC_FILE="$COLLECTDIR/mac_exclude.lst"
# Combine all per-bridge MAC lists, count occurrences
cat "$COLLECTDIR"/mac_br*.lst 2>/dev/null | awk 'NF' | sort | uniq -c > "$COLLECTDIR/mac_counts.tmp"

# Only exclude MACs on 2+ bridges that are NOT explained by trunk ports
# A MAC on multiple bridges is OK if those bridges all connect via same trunk
: > "$EXC_FILE"
while read -r count mac; do
  [ "$count" -lt 2 ] && continue
  
  # Check if this MAC can be explained by a trunk port
  is_trunk_client=0
  for trunk in $TRUNK_PORTS; do
    tagged_vlans=$(eval echo "\$trunk_${trunk}_tagged")
    # Check if this MAC appears only on VLANs this trunk carries
    # (Complex check - for now, be conservative and don't exclude trunk MACs)
    # Future: verify MAC only appears on bridges matching trunk's VLANs
    if [ -n "$tagged_vlans" ]; then
      is_trunk_client=1
      break
    fi
  done
  
  # Only exclude if not a potential trunk client
  if [ "$is_trunk_client" -eq 0 ]; then
    echo "$mac" >> "$EXC_FILE"
  fi
done < "$COLLECTDIR/mac_counts.tmp"
rm -f "$COLLECTDIR/mac_counts.tmp"

# ============================================================================ #
# PASS 3: Generate JSON output per VLAN with interface info                    #
# For each VLAN bridge, emit JSON object with id, interfaces, and client list. #
# Interfaces are categorized as ssid, access, or trunk-tagged.                 #
# ============================================================================ #
for BR in $BR_LIST; do
  # Extract numeric VLAN ID from bridge name (e.g., "2" from "br2")
  VLAN_ID="${BR#br}"
  # Per-bridge MAC list file from pass 1
  MACS_FILE="$COLLECTDIR/mac_${BR}.lst"
  # Add comma separator between VLAN entries (not before first)
  if [ "$FIRST_VLAN" = true ]; then FIRST_VLAN=false; else echo ',' >> "$OUT"; fi
  
  # Collect interface information for this bridge
  IFACE_JSON=""
  FIRST_IFACE=true
  for iface in $(get_bridge_members "$BR"); do
    classified=$(classify_interface "$iface")
    iface_type="${classified%%|*}"
    iface_port="${classified#*|}"
    
    # Skip internal interfaces (eth0 and its VLAN sub-interfaces)
    [ "$iface_type" = "internal" ] && continue
    
    # Build interface JSON entry
    if [ "$FIRST_IFACE" = true ]; then FIRST_IFACE=false; else IFACE_JSON="$IFACE_JSON,"; fi
    
    # For trunk-tagged interfaces, add trunk info
    case "$iface_type" in
      trunk-tagged)
        tagged_vlans=$(eval echo "\$trunk_${iface_port}_tagged" 2>/dev/null)
        native_vlan=$(eval echo "\$trunk_${iface_port}_native" 2>/dev/null)
        IFACE_JSON="$IFACE_JSON{\"name\":\"$iface\",\"type\":\"$iface_type\",\"port\":\"$iface_port\",\"tagged\":\"$tagged_vlans\",\"native\":\"$native_vlan\"}"
        ;;
      *)
        IFACE_JSON="$IFACE_JSON{\"name\":\"$iface\",\"type\":\"$iface_type\"}"
        ;;
    esac
  done
  
  # Write VLAN object header with id, interfaces, and start of clients array
  {
    echo '    {'
    printf '      "id": "%s",\n' "$VLAN_ID"
    printf '      "interfaces": [%s],\n' "$IFACE_JSON"
    echo '      "clients": ['
  } >> "$OUT"

  # Track whether this is first client in VLAN (no leading comma)
  FIRST_CLIENT=true
  # Counter for clients in this specific VLAN
  VLAN_CLIENTS=0
  # Iterate through deduplicated MACs collected for this bridge
  while read -r MAC; do
    # Skip excluded MACs (upstream traffic, but not trunk clients)
    if [ -s "$EXC_FILE" ] && grep -q "^$MAC$" "$EXC_FILE" 2>/dev/null; then
      continue
    fi
    # Add comma separator between clients (not before first)
    if [ "$FIRST_CLIENT" = true ]; then FIRST_CLIENT=false; else echo ',' >> "$OUT"; fi
    # Write client object as JSON line
    printf '        {"mac": "%s"}' "$MAC" >> "$OUT"
    echo "" >> "$OUT"
    # Increment both total and per-VLAN counters
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    VLAN_CLIENTS=$((VLAN_CLIENTS + 1))
  done < "$MACS_FILE"

  # Close clients array and VLAN object
  {
    echo '      ]'
    echo -n '    }'
  } >> "$OUT"

  # Log client count for this VLAN
  info -c cli "VLAN $VLAN_ID: $VLAN_CLIENTS clients"
done

# ============================================================================ #
#                           FINALIZE JSON & CLEANUP                            #
# Close JSON array and root object. Log total client count. Clean temp files.  #
# ============================================================================ #

# Close JSON vlans array and root object
{
  echo
  echo '  ]'
  echo '}'
} >> "$OUT"

# Log final summary (different messages for empty vs populated results)
if [ "$TOTAL_COUNT" -eq 0 ]; then
  info -c vlan "No active clients found on $NODE_NAME"
  info -c cli  "No active clients found on $NODE_NAME"
else
  info -c vlan "Found $TOTAL_COUNT clients on $NODE_NAME"
  info -c cli  "Found $TOTAL_COUNT clients on $NODE_NAME"
fi

# Signal successful completion
exit 0