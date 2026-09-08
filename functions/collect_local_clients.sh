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
#                - File: collect_local_clients.sh || version="0.50"            #
# ============================================================================ #
# - Purpose:    Collect VLAN→client info via bridge FDB (MAC-only) on local    #
#               node so it can be collected by collect_clients.sh.             #
# ============================================================================ #
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
[ -n "${LIB_IDENTITY_LOADED:-}" ] || . "$MERV_BASE/settings/lib_identity.sh" 2>/dev/null || true
[ -n "${LIB_UPDATE_STATE_LOADED:-}" ] || . "$MERV_BASE/settings/lib_update_state.sh" 2>/dev/null || exit 75

export PATH="/sbin:/bin:/usr/sbin:/usr/bin"
umask 022
if merv_update_mutation_blocked; then
  error -c cli,vlan "Local client collection refused: Update maintenance is active"
  exit 75
fi
# Log available commands for debugging purposes (help diagnose missing tools)
logger -t "VLANMgr" "collect_local_clients: PATH=$PATH"
# Check that all required commands are available in the environment
for cmd in ip brctl awk grep sed; do
  merv_has "$cmd" || logger -t "VLANMgr" "collect_local_clients: missing cmd $cmd"
done
# =========================================== End of MerVLAN environment setup #

# ============================================================================ #
#                            CONFIGURATION & SETUP                             #
# Parse command-line arguments for output path, node name, and IP. Initialize   #
# FDB (Forwarding Database) collection parameters with safe defaults.          #
# ============================================================================ #

# Output file path; defaults to $COLLECTDIR/clients_local.json if not provided
OUT_TARGET="${1:-$COLLECTDIR/clients_local.json}"
OUT="${OUT_TARGET}.new.$$"
# Node/router name for identification in JSON; defaults to system hostname
NODE_NAME="${2:-$(hostname)}"
# Optional stable IP identity. The main router supplies this for node requests;
# it lets the UI map the result to NODE<n>, alias, and ProductID consistently.
NODE_IP="${3:-}"
# Whether to attempt reverse-DNS lookup for MAC addresses (disabled by default)
RESOLVE_HOSTNAMES="${RESOLVE_HOSTNAMES:-0}"

# Number of retries when reading bridge FDB (retry if incomplete read)
FDB_RETRIES="${FDB_RETRIES:-2}"
# Sleep duration (seconds) between FDB read retry attempts
FDB_RETRY_SLEEP="${FDB_RETRY_SLEEP:-1}"

# Cleanup handler for temp files on exit/interrupt
cleanup_local_collect() {
  _local_collect_exit_rc=$?
  _local_collect_cleanup_failed=0
  # Remove per-bridge temp files
  rm -f "$COLLECTDIR"/mac_br*.lst "$COLLECTDIR"/mac_exclude.lst 2>/dev/null || _local_collect_cleanup_failed=1
  rm -f "$COLLECTDIR"/mac_br*.lst.tmp "$COLLECTDIR"/mac_counts.tmp 2>/dev/null || _local_collect_cleanup_failed=1
  rm -f "$COLLECTDIR"/portmap_br*.lst 2>/dev/null || _local_collect_cleanup_failed=1
  rm -f "$COLLECTDIR"/mac_own_ifaces.lst "$COLLECTDIR"/mac_own_ifaces.lst.tmp 2>/dev/null || _local_collect_cleanup_failed=1
  [ -z "${OUT:-}" ] || rm -f "$OUT" 2>/dev/null || _local_collect_cleanup_failed=1
  if [ "$_local_collect_cleanup_failed" -ne 0 ]; then
    error -c cli,vlan "Local client collection cleanup failed; temporary state may require recovery"
    [ "$_local_collect_exit_rc" -eq 0 ] && _local_collect_exit_rc=1
  fi
  return "$_local_collect_exit_rc"
}
LOCAL_COLLECT_SIGNAL_HANDLING=0
local_collect_handle_signal() {
  _local_collect_signal_status="$1"
  [ "${LOCAL_COLLECT_SIGNAL_HANDLING:-0}" -eq 0 ] || exit "$_local_collect_signal_status"
  LOCAL_COLLECT_SIGNAL_HANDLING=1
  trap - INT TERM
  error -c cli,vlan "Local client collection interrupted (rc=$_local_collect_signal_status); stopping before publication"
  exit "$_local_collect_signal_status"
}
trap 'cleanup_local_collect' EXIT
trap 'local_collect_handle_signal 130' INT
trap 'local_collect_handle_signal 143' TERM

info -c vlan "Collecting VLAN clients (MAC-only) on $NODE_NAME"
info -c vlan "collect_local_clients: COLLECTDIR='$COLLECTDIR' OUT='$OUT_TARGET'"

: "${MERV_SYS_CLASS_NET_ROOT:=/sys/class/net}"

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
type get_bridges >/dev/null 2>&1 || get_bridges() {
  # List all network interfaces in sysfs matching br[0-9]+ pattern
  ls "$MERV_SYS_CLASS_NET_ROOT/" 2>/dev/null \
    | grep -E '^br[0-9]+$' \
    | grep -v '^br0$' \
    | sed 's/^br//' \
    | sort -n \
    | sed 's/^/br/'
}

# ============================================================================ #
# get_bridge_members                                                           #
# List all interfaces attached to a bridge by reading sysfs brX/brif           #
# ============================================================================ #
type get_bridge_members >/dev/null 2>&1 || get_bridge_members() {
  local bridge="$1"
  ls "$MERV_SYS_CLASS_NET_ROOT/$bridge/brif/" 2>/dev/null
}

# ============================================================================ #
# classify_interface                                                           #
# Determine interface type: ssid, access, trunk-tagged, internal, or unknown   #
# Returns: type|base_port (e.g., "ssid|wl0.1" or "trunk-tagged|eth1")          #
# NOTE: eth0 is the internal switch fabric on Asus routers, not user-facing.   #
#       Only eth1-eth7 are actual LAN ports that users can configure.          #
# ============================================================================ #
type classify_interface >/dev/null 2>&1 || classify_interface() {
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
type get_trunk_ports >/dev/null 2>&1 || get_trunk_ports() {
  # Find all eth[1-9]*.VLAN interfaces (exclude eth0), extract base port
  ls "$MERV_SYS_CLASS_NET_ROOT/" 2>/dev/null \
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
type get_trunk_vlans >/dev/null 2>&1 || get_trunk_vlans() {
  local base_port="$1"
  ls "$MERV_SYS_CLASS_NET_ROOT/" 2>/dev/null \
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
type get_trunk_native_vlan >/dev/null 2>&1 || get_trunk_native_vlan() {
  local base_port="$1"
  # Check each bridge to see if the untagged base port is a member
  for br in $(get_bridges) br0; do
    if [ -d "$MERV_SYS_CLASS_NET_ROOT/$br/brif/$base_port" ]; then
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
type init_trunk_detection >/dev/null 2>&1 || init_trunk_detection() {
  TRUNK_PORTS=$(get_trunk_ports)
}

# ============================================================================ #
# collect_macs_for_bridge                                                      #
# Query bridge FDB and extract non-local (learned) MAC addresses together with #
# the bridge port number and FDB ageing timer they were learned on. Retry      #
# multiple times in case FDB is incomplete on first read. Per MAC the freshest #
# observation (smallest ageing timer) wins. Output lines: "mac port_no age".   #
# ============================================================================ #
collect_macs_for_bridge() {
  local bridge="$1"
  local out="$2"
  local i=0
  local tmp
  # Temporary file for accumulating MACs across retries
  tmp="${out}.tmp"
  info -c vlan "collect_local_clients: collecting bridge='$bridge' out='$out' tmp='$tmp'"
  # Initialize temporary file as empty
  : > "$tmp"
  # Retry loop: collect FDB multiple times to handle transient reads
  while [ $i -lt "$FDB_RETRIES" ]; do
    # brctl showmacs format: port_no mac_addr is_local age_in_secs
    # Keep only non-local (learned) entries; emit "mac port_no age".
    brctl showmacs "$bridge" 2>/dev/null \
      | awk '$3=="no"{printf "%s %s %s\n", tolower($2), $1, $4}' >> "$tmp"
    i=$((i+1))
    # Sleep between retries if more attempts remain
    [ $i -lt "$FDB_RETRIES" ] && sleep "$FDB_RETRY_SLEEP"
  done
  # Deduplicate by MAC keeping the freshest (smallest ageing timer) observation,
  # preserving the port number that observation was learned on.
  awk '{
         a=$3+0
         if (!($1 in age) || a < age[$1]) { age[$1]=a; port[$1]=$2 }
       }
       END { for (m in age) printf "%s %s %s\n", m, port[m], age[m] }' "$tmp" \
    | sort > "$out"
  # Clean up temporary file
  rm -f "$tmp"
}

# ============================================================================ #
# classify_source                                                              #
# Map a bridge member interface to a client source descriptor used to grade    #
# location confidence. Returns: "type|port|confidence".                        #
#   ssid          → direct   (wireless client physically on this device)       #
#   access        → direct   (wired client on a non-trunk LAN port / robo sw)  #
#   trunk-tagged  → relayed  (learned through a tagged trunk/backhaul)          #
#   trunk-native  → relayed  (bare LAN port that is also a trunk base)          #
#   vlan-if       → relayed  (internal VLAN forwarding path)                    #
#   unknown       → unknown  (unmappable / legacy)                             #
# NOTE: eth0 is the Asus robo-switch fabric carrying the local wired LAN ports, #
#       so a bare eth0 hit is treated as direct wired access; only tagged       #
#       eth0.<vid> sub-interfaces are relayed trunk paths.                      #
# ============================================================================ #
classify_source() {
  local iface="$1"
  case "$iface" in
    wl[0-9]*)
      echo "ssid|$iface|direct" ;;
    eth0)
      echo "access|eth0|direct" ;;
    eth0.[0-9]*)
      echo "trunk-tagged|eth0|relayed" ;;
    eth[1-9].[0-9]*|eth[1-9][0-9].[0-9]*)
      base_port="${iface%%.*}"
      echo "trunk-tagged|$base_port|relayed" ;;
    eth[1-9]|eth[1-9][0-9])
      # Bare LAN port: trunk-native if it is also a trunk base, else access.
      if echo " $TRUNK_PORTS " | grep -q " $iface "; then
        echo "trunk-native|$iface|relayed"
      else
        echo "access|$iface|direct"
      fi ;;
    vlan[0-9]*)
      echo "vlan-if|$iface|relayed" ;;
    *)
      echo "unknown|$iface|unknown" ;;
  esac
}

# ============================================================================ #
# build_port_map                                                               #
# Write a "port_no iface" map for a bridge to $1 by reading the kernel's        #
# per-member port_no files. Lets us translate brctl showmacs port numbers back #
# to the interface the MAC was learned on. Empty file when no members resolve.  #
# ============================================================================ #
type build_port_map >/dev/null 2>&1 || build_port_map() {
  local bridge="$1"
  local mapfile="$2"
  local d pn iface
  : > "$mapfile"
  for d in "$MERV_SYS_CLASS_NET_ROOT/$bridge/brif/"*; do
    [ -e "$d/port_no" ] || continue
    pn=$(cat "$d/port_no" 2>/dev/null)
    # Normalize (handles decimal or 0x-prefixed values) to a plain integer.
    pn=$((pn))
    iface="${d##*/}"
    printf '%s %s\n' "$pn" "$iface" >> "$mapfile"
  done
}

# ============================================================================ #
# append_own_mac_candidate                                                     #
# Add a MAC and its U/L-bit paired variant to an exclusion file.               #
# The U/L bit is bit 1 of the first octet (0x02). Router VAP interfaces        #
# sometimes appear in the FDB with that bit toggled, creating false clients.   #
# ============================================================================ #
append_own_mac_candidate() {
  local mac out pair
  mac=$(printf '%s' "$1" | tr 'A-F' 'a-f')
  out="$2"

  case "$mac" in
    [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) ;;
    *) return 0 ;;
  esac

  printf '%s\n' "$mac" >> "$out"

  pair=$(printf '%s\n' "$mac" | awk -F: '
    BEGIN { OFS=":"; h="0123456789abcdef" }
    function hv(c){ return index(h,c)-1 }
    function hd(n){ return substr(h,n+1,1) }
    {
      v=hv(substr($1,1,1))*16 + hv(substr($1,2,1))
      if (int(v/2)%2) v-=2; else v+=2
      $1=hd(int(v/16)) hd(v%16)
      print
    }')
  [ -n "$pair" ] && printf '%s\n' "$pair" >> "$out"
}

# ============================================================================ #
# build_own_mac_exclude                                                        #
# Build a sorted unique list of all router/VAP interface MACs (plus their      #
# U/L-bit pairs) into $1. Called once before PASS 3 so every client row can   #
# be checked in O(1) by mac_is_own_interface.                                  #
# ============================================================================ #
type build_own_mac_exclude >/dev/null 2>&1 || build_own_mac_exclude() {
  local out="$1"
  local tmp="${out}.tmp"
  local p iface mac br

  : > "$tmp" || return 0

  # All kernel network interfaces
  for p in "$MERV_SYS_CLASS_NET_ROOT"/*/address; do
    [ -f "$p" ] || continue
    mac=$(cat "$p" 2>/dev/null)
    append_own_mac_candidate "$mac" "$tmp"
  done

  # Bridge-local (is_local=yes) FDB entries
  for br in $(get_bridges) br0; do
    brctl showmacs "$br" 2>/dev/null | awk '$3=="yes"{print $2}' | while read -r mac; do
      append_own_mac_candidate "$mac" "$tmp"
    done
  done

  # Wireless VAP addresses (cur_etheraddr / perm_etheraddr / bssid may differ)
  for iface in $(ls "$MERV_SYS_CLASS_NET_ROOT" 2>/dev/null | grep -E '^wl[0-9]+(\.[0-9]+)?$'); do
    cat "$MERV_SYS_CLASS_NET_ROOT/$iface/address" 2>/dev/null
    wl -i "$iface" cur_etheraddr 2>/dev/null
    wl -i "$iface" perm_etheraddr 2>/dev/null
    wl -i "$iface" bssid 2>/dev/null
  done | awk '{
    for (i=1;i<=NF;i++) {
      m=tolower($i)
      if (m ~ /^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]$/) print m
    }
  }' | while read -r mac; do
    append_own_mac_candidate "$mac" "$tmp"
  done

  sort -u "$tmp" > "$out" 2>/dev/null || cp "$tmp" "$out" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
}

# ============================================================================ #
# mac_is_own_interface                                                         #
# Return 0 (true) if MAC is in the own-interface exclusion file, 1 otherwise.  #
# ============================================================================ #
mac_is_own_interface() {
  local mac="$1"
  local file="$2"
  [ -f "$file" ] || return 1
  mac=$(printf '%s' "$mac" | tr 'A-F' 'a-f')
  awk -v m="$mac" 'tolower($0)==m{found=1; exit} END{exit found?0:1}' "$file"
}

# ============================================================================ #
#                         INITIALIZE JSON OUTPUT                               #
# Create output JSON file with header structure, timestamps, and router name.  #
# Begin the vlans array which will be populated in main loop.                  #
# ============================================================================ #

# Derive parent directory of output target
_out_dir="${OUT_TARGET%/*}"
[ -n "$_out_dir" ] && [ "$_out_dir" != "$OUT_TARGET" ] || _out_dir="."

# Ensure collection directory exists before writing any output or scratch files
if ! mkdir -p "$COLLECTDIR" 2>/dev/null || [ ! -d "$COLLECTDIR" ]; then
  error -c cli,vlan "Local client collection could not create collection directory: '$COLLECTDIR'"
  exit 1
fi

# Ensure output target directory exists before writing initial JSON header
if ! mkdir -p "$_out_dir" 2>/dev/null || [ ! -d "$_out_dir" ]; then
  error -c cli,vlan "Local client collection could not create output directory: '$_out_dir'"
  exit 1
fi

# Capture current timestamp in ISO 8601 format for "generated" field
DATE_NOW=$(date +'%Y-%m-%dT%H:%M:%S')

# Write JSON header with metadata (not yet closing vlans array)
if ! {
  echo "{"
  printf '  "generated": "%s",\n' "$DATE_NOW"
  printf '  "router": "%s",\n' "$(json_escape "$NODE_NAME")"
  if [ -n "$NODE_IP" ]; then
    printf '  "ip": "%s",\n' "$(json_escape "$NODE_IP")"
  fi
  echo '  "vlans": ['
} > "$OUT" || [ ! -s "$OUT" ]; then
  rm -f "$OUT" 2>/dev/null || :
  error -c cli,vlan "Local client collection could not initialize output candidate: '$OUT'"
  exit 1
fi

# ============================================================================ #
#                       BRIDGE ENUMERATION & MACs COLLECTION                   #
# Iterate through all VLAN bridges and collect learned MAC addresses from      #
# each bridge FDB. Clean up previous temp files to avoid stale data merges.    #
# ============================================================================ #

# Track whether this is the first VLAN (no leading comma) or subsequent
FIRST_VLAN=true
# Counter for total unique clients found across all VLANs
TOTAL_COUNT=0

# Clean previous per-bridge temp lists to avoid stale merges on re-run
rm -f "$COLLECTDIR"/mac_br*.lst "$COLLECTDIR"/mac_exclude.lst 2>/dev/null

# Get list of all VLAN bridges on this system
BR_LIST="$(get_bridges)"

# Build own-interface MAC exclusion list once (includes U/L-bit paired variants)
OWN_MACS_FILE="$COLLECTDIR/mac_own_ifaces.lst"
OWN_FILTERED=0
build_own_mac_exclude "$OWN_MACS_FILE"

# ============================================================================ #
# PASS 1: Gather MACs per bridge                                               #
# For each VLAN bridge, collect non-local MACs and store in per-bridge file.   #
# ============================================================================ #
for BR in $BR_LIST; do
  # Per-bridge MAC list file (will be deduplicated within collect_macs_for_bridge)
  MACS_FILE="$COLLECTDIR/mac_${BR}.lst"
  info -c vlan "collect_local_clients: bridge=$BR macs_file='$MACS_FILE'"
  # Collect MACs from this bridge's FDB with retries
  collect_macs_for_bridge "$BR" "$MACS_FILE"
done

# ============================================================================ #
# PASS 2: Trunk port detection (metadata only)                                 #
# Detect trunk ports and the VLANs they carry. This drives interface           #
# classification and the per-client location-confidence grading in PASS 3.     #
#                                                                              #
# NOTE: We intentionally no longer build a blanket "exclude" list for MACs      #
# that appear on multiple bridges. The old heuristic dropped legitimate        #
# clients whenever any tagged trunk existed. Instead, every observation is now  #
# emitted with source evidence (iface/type/port/age/confidence) and the        #
# cluster-wide merge resolver in collect_clients.sh decides the active          #
# location. A multi-bridge MAC is graded per observation: direct (ssid/access) #
# vs relayed (trunk-tagged/native), so it is never silently kept active        #
# everywhere.                                                                   #
# ============================================================================ #

# Initialize trunk port detection
init_trunk_detection
info -c vlan "Detected trunk ports: ${TRUNK_PORTS:-none}"

# Build a mapping of which VLANs each trunk port carries
# Format: trunk_eth1_vlans="10,20,30"
for trunk in $TRUNK_PORTS; do
  vlans=$(get_trunk_vlans "$trunk")
  native=$(get_trunk_native_vlan "$trunk")
  eval "trunk_${trunk}_tagged=\"$vlans\""
  eval "trunk_${trunk}_native=\"$native\""
  info -c vlan "Trunk $trunk: tagged=[$vlans] native=[$native]"
done

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

  # Build a port_no -> iface map for this bridge so we can attribute each MAC
  # to the interface it was learned on and grade its location confidence.
  PORTMAP="$COLLECTDIR/portmap_${BR}.lst"
  build_port_map "$BR" "$PORTMAP"

  # Track whether this is first client in VLAN (no leading comma)
  FIRST_CLIENT=true
  # Counter for clients in this specific VLAN
  VLAN_CLIENTS=0
  # Iterate observations collected for this bridge: "mac port_no age"
  while read -r MAC PORTNO AGE; do
    [ -n "$MAC" ] || continue
    # Skip router/VAP interface MACs (and their U/L-bit variants) to prevent
    # false-positive clients from being reported.
    if mac_is_own_interface "$MAC" "$OWN_MACS_FILE"; then
      OWN_FILTERED=$((OWN_FILTERED + 1))
      continue
    fi
    # Resolve the learning interface from the port number, then classify it.
    SRC_IFACE=$(awk -v p="$PORTNO" '$1==p{print $2; exit}' "$PORTMAP" 2>/dev/null)
    if [ -n "$SRC_IFACE" ]; then
      CS=$(classify_source "$SRC_IFACE")
      SRC_TYPE="${CS%%|*}"
      CS_REST="${CS#*|}"
      SRC_PORT="${CS_REST%%|*}"
      SRC_CONF="${CS_REST#*|}"
    else
      SRC_IFACE=""
      SRC_TYPE="unknown"
      SRC_PORT=""
      SRC_CONF="unknown"
    fi
    # Normalize the ageing timer to an integer number of seconds (-1 = unknown).
    AGE_INT=$(printf '%s' "$AGE" | sed 's/\..*$//')
    case "$AGE_INT" in ''|*[!0-9]*) AGE_INT=-1 ;; esac
    # Add comma separator between clients (not before first)
    if [ "$FIRST_CLIENT" = true ]; then FIRST_CLIENT=false; else echo ',' >> "$OUT"; fi
    # Write client object with source evidence on a single line.
    printf '        {"mac": "%s", "source_iface": "%s", "source_type": "%s", "source_port": "%s", "fdb_age": %s, "location_confidence": "%s"}' \
      "$MAC" "$SRC_IFACE" "$SRC_TYPE" "$SRC_PORT" "$AGE_INT" "$SRC_CONF" >> "$OUT"
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
  info -c vlan "VLAN $VLAN_ID: $VLAN_CLIENTS clients"
done

[ "${OWN_FILTERED:-0}" -gt 0 ] && \
  info -c vlan "Filtered ${OWN_FILTERED} local interface/VAP MAC observation(s) on $NODE_NAME"

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

preserve_collection_fault() {
  local _fault_candidate="$1"
  local _fault_root="${RESULTDIR:-/tmp/mervlan_tmp/results}/client_collection_faults"
  local _f_pid="$$"
  local _f_start _f_nonce _f_dir _f_meta _f_meta_tmp _f_sz _f_ts
  local _esc_node _esc_ip _saved_umask
  local _candidate_saved=0 _scratch_saved=1 _metadata_complete=0 _perms_secure=1
  local _metadata_escaped=1 _f_status="partial" _meta_comp=0
  local _pattern _src _bname _old_fault _f
  local _rest _cand_pid _cand_start _cand_nonce _valid_count
  local _n_rest _n_epoch _n_pid _n_start _n_seq

  _saved_umask=$(umask)
  umask 077

  _f_start=$(merv_identity_current_start 2>/dev/null) || {
    warn -c cli,vlan "Could not acquire process start identity; skipping client fault preservation"
    umask "$_saved_umask"
    return 1
  }
  merv_identity_nonce_next || {
    warn -c cli,vlan "Could not acquire identity nonce; skipping client fault preservation"
    umask "$_saved_umask"
    return 1
  }
  _f_nonce="$MERV_IDENTITY_NONCE"
  [ -n "$_f_nonce" ] || {
    warn -c cli,vlan "Empty identity nonce; skipping client fault preservation"
    umask "$_saved_umask"
    return 1
  }

  if [ ! -d "$_fault_root" ]; then
    mkdir -p "$_fault_root" 2>/dev/null || {
      warn -c cli,vlan "Could not create fault root directory '$_fault_root'"
      umask "$_saved_umask"
      return 1
    }
  fi
  chmod 700 "$_fault_root" 2>/dev/null || {
    warn -c cli,vlan "Could not set secure permissions (0700) on fault root '$_fault_root'"
    umask "$_saved_umask"
    return 1
  }

  _f_dir="${_fault_root}/fault.${_f_pid}.${_f_start}.${_f_nonce}"
  mkdir -p "$_f_dir" 2>/dev/null || {
    warn -c cli,vlan "Could not create fault preservation directory '$_f_dir'"
    umask "$_saved_umask"
    return 1
  }
  chmod 700 "$_f_dir" 2>/dev/null || {
    warn -c cli,vlan "Could not set secure permissions (0700) on fault directory '$_f_dir'"
    umask "$_saved_umask"
    return 1
  }

  # Copy rejected candidate
  if [ -f "$_fault_candidate" ]; then
    if cp "$_fault_candidate" "$_f_dir/candidate.json" 2>/dev/null && [ -s "$_f_dir/candidate.json" ]; then
      _candidate_saved=1
    else
      warn -c cli,vlan "Failed to copy candidate file '$_fault_candidate' to '$_f_dir/candidate.json'"
    fi
  else
    warn -c cli,vlan "Candidate file '$_fault_candidate' missing or empty at preservation time"
  fi

  # Copy scratch evidence files that existed at validation failure
  if [ -d "$COLLECTDIR" ]; then
    for _pattern in 'mac_br*.lst' 'portmap_br*.lst' 'mac_own_ifaces.lst' 'mac_exclude.lst'; do
      for _src in "$COLLECTDIR"/$_pattern; do
        [ -e "$_src" ] || continue
        _bname="${_src##*/}"
        if cp "$_src" "$_f_dir/$_bname" 2>/dev/null && [ -e "$_f_dir/$_bname" ]; then
          :
        else
          _scratch_saved=0
          warn -c cli,vlan "Failed to copy scratch evidence '$_src' to fault directory"
        fi
      done
    done
  fi

  # Format dynamic fields for metadata; no lossy fallback
  _esc_node=""
  _esc_ip=""
  if type json_escape_string >/dev/null 2>&1; then
    _esc_node=$(json_escape_string "$NODE_NAME" 2>/dev/null) || _metadata_escaped=0
    _esc_ip=$(json_escape_string "$NODE_IP" 2>/dev/null) || _metadata_escaped=0
  else
    _metadata_escaped=0
  fi

  if [ "$_metadata_escaped" -ne 1 ]; then
    warn -c cli,vlan "Failed to safely JSON-escape metadata fields; recording fallback constants"
    _esc_node="unavailable"
    _esc_ip="unavailable"
  fi

  _f_sz=$(wc -c < "$_fault_candidate" 2>/dev/null || printf '0')
  _f_sz=$(printf '%s' "$_f_sz" | tr -d '[:space:]')
  _f_ts=$(date +%s 2>/dev/null || printf '0')

  # Enforce 0600 on all preserved evidence files
  for _f in "$_f_dir"/*; do
    [ -e "$_f" ] || continue
    chmod 600 "$_f" 2>/dev/null || {
      warn -c cli,vlan "Could not set secure permissions (0600) on preserved evidence '$_f'"
      _perms_secure=0
    }
  done

  # Stage, verify, and atomically publish metadata
  _f_meta="$_f_dir/metadata.json"
  _f_meta_tmp="$_f_dir/metadata.json.tmp.$$"

  _publish_meta() {
    _pm_status="$1"
    _pm_complete="$2"
    rm -f "$_f_meta_tmp" 2>/dev/null || :

    {
      printf '{\n'
      printf '  "timestamp": %s,\n' "${_f_ts:-0}"
      printf '  "pid": %s,\n' "$_f_pid"
      printf '  "start": %s,\n' "$_f_start"
      printf '  "nonce": "%s",\n' "$_f_nonce"
      printf '  "validator": "json_validate_file",\n'
      printf '  "validator_result": "rejected",\n'
      printf '  "candidate_size_bytes": %s,\n' "${_f_sz:-0}"
      [ "$_candidate_saved" -eq 1 ] && printf '  "candidate_preserved": true,\n' || printf '  "candidate_preserved": false,\n'
      [ "$_scratch_saved" -eq 1 ] && printf '  "scratch_preserved": true,\n' || printf '  "scratch_preserved": false,\n'
      [ "$_pm_complete" -eq 1 ] && printf '  "metadata_complete": true,\n' || printf '  "metadata_complete": false,\n'
      printf '  "preservation_status": "%s",\n' "$_pm_status"
      printf '  "node_name": "%s",\n' "$_esc_node"
      printf '  "node_ip": "%s"\n' "$_esc_ip"
      printf '}\n'
    } > "$_f_meta_tmp" 2>/dev/null || {
      rm -f "$_f_meta_tmp" 2>/dev/null || :
      return 1
    }

    [ -s "$_f_meta_tmp" ] || {
      rm -f "$_f_meta_tmp" 2>/dev/null || :
      return 1
    }

    chmod 600 "$_f_meta_tmp" 2>/dev/null || {
      rm -f "$_f_meta_tmp" 2>/dev/null || :
      return 1
    }

    if type json_validate_file >/dev/null 2>&1; then
      json_validate_file "$_f_meta_tmp" 2>/dev/null || {
        rm -f "$_f_meta_tmp" 2>/dev/null || :
        return 1
      }
    fi

    mv -f "$_f_meta_tmp" "$_f_meta" 2>/dev/null || {
      rm -f "$_f_meta_tmp" "$_f_meta" 2>/dev/null || :
      return 1
    }

    return 0
  }

  _f_status="partial"
  if [ "$_candidate_saved" -eq 1 ] && [ "$_scratch_saved" -eq 1 ] && \
     [ "$_metadata_escaped" -eq 1 ] && [ "$_perms_secure" -eq 1 ]; then
    if _publish_meta "complete" 1; then
      _f_status="complete"
    else
      warn -c cli,vlan "Could not securely publish complete metadata in '$_f_dir'"
      _f_status="partial"
    fi
  else
    _meta_comp=0
    [ "$_metadata_escaped" -eq 1 ] && _meta_comp=1
    _publish_meta "partial" "$_meta_comp" || warn -c cli,vlan "Could not publish partial metadata in '$_f_dir'"
  fi

  # Restore umask immediately
  umask "$_saved_umask"

  if [ "$_f_status" = "complete" ]; then
    info -c cli,vlan "Preserved invalid client collection candidate in '$_f_dir' (status=complete)"
  else
    warn -c cli,vlan "Partial client collection fault preservation in '$_f_dir' (status=partial)"
  fi

  case "$_fault_root" in
    /*)
      if [ -d "$_fault_root" ]; then
        _valid_count=0
        ls -dt "$_fault_root"/* 2>/dev/null | while IFS= read -r _old_fault; do
          [ -d "$_old_fault" ] || continue
          [ ! -L "$_old_fault" ] || continue

          _bname="${_old_fault##*/}"
          case "$_bname" in
            fault.*) ;;
            *) continue ;;
          esac

          _rest="${_bname#fault.}"
          _cand_pid="${_rest%%.*}"
          case "$_rest" in
            *.*) _rest="${_rest#*.}" ;;
            *) continue ;;
          esac

          _cand_start="${_rest%%.*}"
          case "$_rest" in
            *.*) _cand_nonce="${_rest#*.}" ;;
            *) continue ;;
          esac

          # 1. Outer PID & start must be positive integers
          if type merv_identity_positive_uint >/dev/null 2>&1; then
            merv_identity_positive_uint "$_cand_pid" || continue
            merv_identity_positive_uint "$_cand_start" || continue
          else
            case "$_cand_pid" in ''|*[!0-9]*|0) continue ;; esac
            case "$_cand_start" in ''|*[!0-9]*|0) continue ;; esac
          fi

          # 2. Nonce must satisfy canonical nonce character & length grammar
          if type merv_identity_nonce_valid >/dev/null 2>&1; then
            merv_identity_nonce_valid "$_cand_nonce" || continue
          else
            case "$_cand_nonce" in ''|*[!A-Za-z0-9._:-]*) continue ;; esac
            [ "${#_cand_nonce}" -le 160 ] || continue
          fi

          # 3. Nonce must structurally contain exactly 4 dot-separated fields:
          #    <epoch>.<nonce_pid>.<nonce_start>.<sequence>
          _n_rest="$_cand_nonce"
          _n_epoch="${_n_rest%%.*}"
          case "$_n_rest" in
            *.*) _n_rest="${_n_rest#*.}" ;;
            *) continue ;;
          esac

          _n_pid="${_n_rest%%.*}"
          case "$_n_rest" in
            *.*) _n_rest="${_n_rest#*.}" ;;
            *) continue ;;
          esac

          _n_start="${_n_rest%%.*}"
          case "$_n_rest" in
            *.*) _n_seq="${_n_rest#*.}" ;;
            *) continue ;;
          esac

          # Reject if extra components exist in sequence
          case "$_n_seq" in
            *.*) continue ;;
          esac

          # 4. Nonce components must satisfy numeric identity expectations
          case "$_n_epoch" in ''|*[!0-9]*) continue ;; esac
          if type merv_identity_positive_uint >/dev/null 2>&1; then
            merv_identity_positive_uint "$_n_pid" || continue
            merv_identity_positive_uint "$_n_start" || continue
            merv_identity_positive_uint "$_n_seq" || continue
          else
            case "$_n_pid" in ''|*[!0-9]*|0) continue ;; esac
            case "$_n_start" in ''|*[!0-9]*|0) continue ;; esac
            case "$_n_seq" in ''|*[!0-9]*|0) continue ;; esac
          fi

          # 5. Nonce PID & start must match outer PID & start
          [ "$_n_pid" = "$_cand_pid" ] || continue
          [ "$_n_start" = "$_cand_start" ] || continue

          _valid_count=$((_valid_count + 1))
          if [ "$_valid_count" -gt 5 ]; then
            rm -rf "$_old_fault" 2>/dev/null || :
          fi
        done
      fi
      ;;
  esac

  [ "$_f_status" = "complete" ] && return 0
  return 1
}

if ! json_validate_file "$OUT"; then
  preserve_collection_fault "$OUT" || :
  error -c cli,vlan "Local client collection produced invalid JSON; preserving the previous artifact"
  exit 1
fi
if ! mv -f "$OUT" "$OUT_TARGET" 2>/dev/null; then
  error -c cli,vlan "Local client collection could not publish its JSON artifact"
  exit 1
fi

# Log final summary (different messages for empty vs populated results)
if [ "$TOTAL_COUNT" -eq 0 ]; then
  info -c vlan "No active clients found on $NODE_NAME"
else
  info -c vlan "Found $TOTAL_COUNT clients on $NODE_NAME"
fi

# Signal successful completion
exit 0
