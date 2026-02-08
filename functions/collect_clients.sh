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
#                - File: collect_clients.sh || version="0.49"                  #
# ============================================================================ #
# - Purpose:    Orchestrate collection of VLAN bridges and client MAC          # 
#               addresses from main and nodes to be stored in JSON format      #
#               so they can be read by the MerVLAN GUI.                        #
# ============================================================================ #
#                                                                              #
# ================================================== MerVLAN environment setup #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_SSH_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_SSH_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssh.sh"

export PATH="/sbin:/bin:/usr/sbin:/usr/bin"
umask 022

SSH_NODE_USER=$(get_node_ssh_user)
SSH_NODE_PORT=$(get_node_ssh_port)
# =========================================== End of MerVLAN environment setup #

# ============================================================================ #
#                            CONFIGURATION & SETUP                             #
# Define collection timeout and initialize logging. Prepare working            #
# directories and clear any stale results from previous runs.                  #
# ============================================================================ #

# Timeout (seconds) for remote SSH commands; prevents hanging on slow nodes
TIMEOUT=10
# Retry controls for transient node boot/SSH delays
RETRY_MAX="${COLLECT_RETRY_MAX:-2}"
RETRY_DELAY="${COLLECT_RETRY_DELAY:-3}"
# Maximum time (seconds) to wait for all node collections to complete
WAIT_TIMEOUT="${COLLECT_WAIT_TIMEOUT:-90}"

# Cleanup handler for temp files on exit/interrupt
cleanup_collect() {
  # Kill any remaining background collection jobs
  for pid in $BG_PIDS; do
    kill "$pid" 2>/dev/null
  done
  # Remove temporary collection directory
  [ -d "$COLLECTDIR" ] && rm -rf "$COLLECTDIR" 2>/dev/null
}
trap 'cleanup_collect' EXIT INT TERM

# Track background job PIDs for cleanup
BG_PIDS=""

info -c cli,vlan "=== VLAN Client Collection Started ==="

# Create temporary collection directory and results directory
mkdir -p "$COLLECTDIR" "$RESULTDIR"

# Remove any stale results file from previous collection attempts
if [ -f "$OUT_FINAL" ]; then
  rm -f "$OUT_FINAL"
  info -c cli,vlan "Cleared previous results at $OUT_FINAL"
fi

# ============================================================================ #
#                             HELPER FUNCTIONS                                 #
# Utility functions for node discovery, SSH validation, and remote collection  #
# of VLAN client data from both main router and satellite nodes.               #
# ============================================================================ #

# ============================================================================ #
# get_node_ips                                                                 #
# Extract NODE1-NODE5 IP addresses from settings.json. Parse JSON format       #
# and filter out "none" entries and invalid IP addresses.                      #
# Returns: "node_id ip" pairs, one per line (e.g., "1 192.168.1.100")          #
# ============================================================================ #
get_node_ips() {
  # Extract NODE entries matching JSON "NODE[1-5]": "IP" format
  grep -o '"NODE[1-5]"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" | \
  sed -n 's/"NODE\([1-5]\)"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1 \2/p' | \
  awk '$2 != "none" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $1, $2 }'
}

# ============================================================================ #
# test_ssh_connection                                                          #
# Verify SSH connectivity to a node using the SSH wrapper. Attempts echo       #
# command with timeout. Returns 0 if successful, 1 if connection fails.        #
# ============================================================================ #
test_ssh_connection() {
  node_id="$1"
  node_ip="$2"
  # Use wrapper-based SSH test with precheck and timeout
  merv_ssh_test "$node_id" "$node_ip"
}

# ============================================================================ #
# collect_from_node                                                            #
# Orchestrate client collection from a remote node. Uses SSH wrapper for       #
# connectivity checks and remote execution. Always writes a JSON output file   #
# (even on error) for unified result merging.                                  #
# ============================================================================ #
collect_from_node() {
  node_id="$1"
  node_ip="$2"
  output_file="$3"

  info -c cli,vlan "→ Collecting from node $node_ip (NODE${node_id})"

  # Use wrapper precheck (validates IP, keys, and ping)
  if ! merv_ssh_precheck "$node_id" "$node_ip"; then
    merv_ssh_skip_log "$node_id" "$node_ip" "collect"
    printf '{"router":"%s","error":"%s","vlans":[]}' "$node_ip" "$MERV_SSH_LAST_REASON" > "$output_file"
    return 1
  fi

  # Test SSH connectivity using wrapper
  if ! test_ssh_connection "$node_id" "$node_ip"; then
    merv_ssh_skip_log "$node_id" "$node_ip" "collect"
    printf '{"router":"%s","error":"ssh-failed","vlans":[]}' "$node_ip" > "$output_file"
    return 1
  fi

  # Run remote collector and fetch JSON via SSH wrapper
  # collect_local_clients.sh writes to /tmp/node_clients.json, we cat and capture output
  remote_cmd="$MERV_BASE/functions/collect_local_clients.sh /tmp/node_clients.json \"$node_ip\" >/dev/null 2>&1 && cat /tmp/node_clients.json"
  
  result=$(merv_ssh_exec "$node_id" "$node_ip" "$remote_cmd" 2>/dev/null)
  rc=$?
  
  if [ $rc -eq 0 ] && [ -n "$result" ]; then
    printf '%s' "$result" > "$output_file"
    info -c cli,vlan "✓ Successfully collected from $node_ip"
    return 0
  else
    warn -c cli,vlan "Failed to fetch results from $node_ip (rc=$rc)"
    printf '{"router":"%s","error":"fetch-failed","vlans":[]}' "$node_ip" > "$output_file"
    return 1
  fi
}

# ============================================================================ #
#                         MAIN ROUTER COLLECTION                               #
# Invoke collect_local_clients.sh locally to gather VLAN bridges and client    #
# MAC addresses from the main router. Output written to temporary JSON file.   #
# ============================================================================ #

info -c cli,vlan "Collecting clients from main router (JSON)..."
MAIN_JSON="$COLLECTDIR/main.json"

# Call local collector; redirect output to CLI log channel
if "$FUNCDIR/collect_local_clients.sh" "$MAIN_JSON" "Main Router" >>"$LOG_chan_cli" 2>&1; then
  info -c cli,vlan "✓ Main router collection completed"
else
  # Collector returned error; log failure code and write error JSON if file is empty
  rc=$?
  error -c cli,vlan "✗ Main router collection failed (rc=$rc)"
  if [ ! -s "$MAIN_JSON" ]; then
    # Write error JSON so result merging doesn't fail on missing file
    printf '{"router":"%s","error":"collector-failed","vlans":[]}' "Main Router" > "$MAIN_JSON"
  fi
fi

# ============================================================================ #
#                          NODE DISCOVERY & VALIDATION                         #
# Check if nodes are configured in settings.json. Verify SSH keys are          #
# installed and marked as enabled in configuration before attempting remote    #
# collection from any nodes.                                                   #
# ============================================================================ #

# Extract configured node IPs from settings.json (returns "node_id ip" pairs)
NODE_IPS=$(get_node_ips)

if [ -z "$NODE_IPS" ]; then
  # No nodes configured; collection will only include main router
  info -c cli,vlan "No nodes configured in settings.json"
  NODES_ENABLED=false
else
  # Nodes are configured; check prerequisites before attempting collection
  NODES_ENABLED=true
  info -c cli,vlan "Found configured nodes: $(echo "$NODE_IPS" | awk '{print $2}' | tr '\n' ' ')"

  if ! ssh_keys_effectively_installed; then
    warn -c cli,vlan "SSH keys are not fully configured; only collecting from main router"
    warn -c cli,vlan "Either SSH_KEYS_INSTALLED is 0/missing in settings.json or key files are absent."
    NODES_ENABLED=false
  elif [ -z "${SSH_KEY:-}" ] || [ ! -f "$SSH_KEY" ] || \
       [ -z "${SSH_PUBKEY:-}" ] || [ ! -f "$SSH_PUBKEY" ]; then
    warn -c cli,vlan "SSH key files not found on disk; only collecting from main router"
    NODES_ENABLED=false
  fi
fi

# ============================================================================ #
#                        PARALLEL NODE COLLECTION                              #
# Spawn background collection jobs for each configured node. Run jobs in       #
# parallel to minimize total time. Wait for all jobs to complete before        #
# proceeding to result merging.                                                #
# ============================================================================ #

if [ "$NODES_ENABLED" = "true" ]; then
  # Spawn collection background jobs for each node with PID tracking
  info -c cli,vlan "Spawning node collection jobs (timeout: ${WAIT_TIMEOUT}s)..."
  
  # Write node IPs to temp file to avoid subshell issues with pipes
  _node_tmp="$COLLECTDIR/node_ips.tmp"
  printf '%s\n' "$NODE_IPS" > "$_node_tmp"
  
  # Read from file (not pipe) so background PIDs stay in this shell
  while read -r node_id node_ip; do
    [ -n "$node_id" ] || continue
    collect_from_node "$node_id" "$node_ip" "$COLLECTDIR/node_${node_ip}.json" &
    # Track PID for cleanup handler
    BG_PIDS="$BG_PIDS $!"
  done < "$_node_tmp"
  rm -f "$_node_tmp"
  
  # Wait for all background jobs with timeout using PID-based tracking
  # 'jobs -p' may not work reliably in BusyBox non-interactive sh
  waited=0
  while [ "$waited" -lt "$WAIT_TIMEOUT" ]; do
    # Check if any tracked PIDs are still running via /proc
    _still_running=0
    for _pid in $BG_PIDS; do
      if [ -d "/proc/$_pid" ]; then
        _still_running=1
        break
      fi
    done
    
    if [ "$_still_running" -eq 0 ]; then
      break
    fi
    
    sleep 1
    waited=$((waited + 1))
  done
  
  # Collect exit codes from background jobs (wait for each)
  for _pid in $BG_PIDS; do
    wait "$_pid" 2>/dev/null
  done
  
  # If timeout reached, log warning (jobs will be killed by trap on exit)
  if [ "$waited" -ge "$WAIT_TIMEOUT" ]; then
    warn -c cli,vlan "Node collection timeout after ${WAIT_TIMEOUT}s; some nodes may be incomplete"
  else
    info -c cli,vlan "All node collections finished in ${waited}s"
  fi
fi

# ============================================================================ #
#                          MERGE RESULTS TO JSON                               #
# Combine main router and all node JSON files into a single result JSON.       #
# Add timestamp and array wrapper. Clean up intermediate files.                #
# ============================================================================ #

info -c cli,vlan "Merging JSON results..."
# Capture current timestamp in ISO 8601 format
DATE_NOW=$(date +'%Y-%m-%dT%H:%M:%S')

# Build final JSON structure with timestamp and array of node results
{
  echo "{"
  echo "  \"generated\": \"$DATE_NOW\","
  echo "  \"nodes\": ["

  # Track first entry to avoid trailing comma after last entry
  FIRST=1
  # Iterate through all collected JSON files (main router + nodes)
  for json_file in "$COLLECTDIR/main.json" "$COLLECTDIR"/node_*.json; do
    # Skip if file doesn't exist
    [ -f "$json_file" ] || continue
    # Add comma separator between entries (not before first entry)
    if [ $FIRST -eq 1 ]; then FIRST=0; else echo ","; fi
    # Indent and append JSON content (sed adds 4 spaces to each line)
    sed 's/^/    /' "$json_file"
  done

  echo "  ]"
  echo "}"
} > "$OUT_FINAL"

# ============================================================================ #
#                            CLEANUP & COMPLETION                              #
# Remove temporary collection directory and all intermediate JSON files.       #
# Log final result location and exit successfully.                             #
# ============================================================================ #

# Remove temporary directory and all intermediate collection files
rm -rf "$COLLECTDIR"

info -c cli,vlan "✓ Client collection completed - JSON saved to $OUT_FINAL"
info -c cli,vlan "=== VLAN Client Collection Finished ==="
exit 0