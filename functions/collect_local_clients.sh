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
#                - File: collect_local_clients.sh || version="0.45"            #
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
# PASS 2: Identify and exclude upstream MACs                                   #
# Find MACs that appear on 2+ bridges (likely upstream/parent interfaces).     #
# These should not be reported as individual clients.                          #
# ============================================================================ #

# File to store MACs seen on multiple bridges (to be excluded)
EXC_FILE="$COLLECTDIR/mac_exclude.lst"
# Combine all per-bridge MAC lists, count occurrences, and extract those with count >= 2
cat "$COLLECTDIR"/mac_br*.lst 2>/dev/null | awk 'NF' | sort | uniq -c | awk '$1>=2 {print $2}' > "$EXC_FILE"

# ============================================================================ #
# PASS 3: Generate JSON output per VLAN                                        #
# For each VLAN bridge, emit JSON object with id and client list, excluding    #
# upstream MACs. Count total clients for logging.                              #
# ============================================================================ #
for BR in $BR_LIST; do
  # Extract numeric VLAN ID from bridge name (e.g., "2" from "br2")
  VLAN_ID="${BR#br}"
  # Per-bridge MAC list file from pass 1
  MACS_FILE="$COLLECTDIR/mac_${BR}.lst"
  # Add comma separator between VLAN entries (not before first)
  if [ "$FIRST_VLAN" = true ]; then FIRST_VLAN=false; else echo ',' >> "$OUT"; fi
  # Write VLAN object header with id and start of clients array
  {
    echo '    {'
    printf '      "id": "%s",\n' "$VLAN_ID"
    echo '      "clients": ['
  } >> "$OUT"

  # Track whether this is first client in VLAN (no leading comma)
  FIRST_CLIENT=true
  # Counter for clients in this specific VLAN
  VLAN_CLIENTS=0
  # Iterate through deduplicated MACs collected for this bridge
  while read -r MAC; do
    # Skip excluded MACs (those on multiple bridges - upstream traffic)
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