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
#                - File: collect_clients.sh || version="0.52"                  #
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
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_SSH_LOADED LIB_MERVQT_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_SSH_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssh.sh"
# lib_json provides merv_node_list (node discovery). Source explicitly rather
# than relying on lib_ssh.sh sourcing it transitively.
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh"
# lib_mervqt provides merv_lock_acquire/release (collection self-lock) and the
# MAC validators reused by the client-metadata annotation pass. Best-effort:
# if absent we degrade to unguarded collection rather than fail.
[ -n "${LIB_MERVQT_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mervqt.sh" 2>/dev/null || true

export PATH="/sbin:/bin:/usr/sbin:/usr/bin"
umask 022

if [ -f "$MERV_BASE/settings/lib_action_ack.sh" ] && [ -z "$LIB_ACTION_ACK_LOADED" ]; then
  . "$MERV_BASE/settings/lib_action_ack.sh" 2>/dev/null || true
fi

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
# Maximum time (seconds) to wait for all collection jobs to complete
WAIT_TIMEOUT="${COLLECT_WAIT_TIMEOUT:-90}"

# Cleanup handler for temp files on exit/interrupt
# Only the process that OWNS the collection lock may remove COLLECTDIR — a
# second (skipped) collector must never delete the working dir out from under
# the running owner. The lock itself is released here too.
cleanup_collect() {
  _collect_cleanup_rc=$?
  _collect_cleanup_failed=0
  # Kill any remaining background collection jobs
  for pid in $BG_PIDS; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || _collect_cleanup_failed=1
    fi
  done
  # Remove temporary collection directory only if we own the lock
  if [ "${COLLECT_LOCK_ACQUIRED:-0}" -eq 1 ]; then
    if [ -d "$COLLECTDIR" ] && ! rm -rf "$COLLECTDIR" 2>/dev/null; then
      _collect_cleanup_failed=1
      error -c cli,vlan "Client collection cleanup could not remove its private workspace"
    fi
    if ! type merv_lock_release >/dev/null 2>&1 || ! merv_lock_release "$COLLECT_LOCK" "${COLLECT_LOCK_NONCE:-}" 2>/dev/null; then
      _collect_cleanup_failed=1
      error -c cli,vlan "Client collection cleanup could not release its owner lock"
    else
      COLLECT_LOCK_ACQUIRED=0
    fi
  fi
  [ "$_collect_cleanup_failed" -eq 0 ] || _collect_cleanup_rc=1
  return "$_collect_cleanup_rc"
}
trap 'cleanup_collect' EXIT INT TERM

# Track background job PIDs for cleanup
BG_PIDS=""

# ----------------------------------------------------------- Collection lock --
# COLLECTDIR is a single shared path, so two concurrent collections would race
# the same working dir. Take a NON-BLOCKING self-lock: a second collection
# skips rather than corrupting state. A crashed collection is reclaimed after
# the stale window. Best-effort — if the lib is absent we proceed unguarded.
COLLECT_LOCK="$LOCKDIR/client_collect.lock"
COLLECT_LOCK_ACQUIRED=0

# execute_nodes retains its orchestration lock while publishing the final
# observation. Permit that one parent-owned collection only after all node
# workers have published terminal verified results, and authenticate the
# exception against the live owner record rather than an unscoped flag.
collect_execute_nodes_observation_grant_valid() {
  [ "${MERV_OBS_EXECUTE_NODES_OWNER_GRANT:-0}" = 1 ] || return 1
  case "${MERV_OBS_EXECUTE_NODES_OWNER_PID:-}:${MERV_OBS_EXECUTE_NODES_OWNER_START:-}:${MERV_OBS_EXECUTE_NODES_OWNER_NONCE:-}" in
    ''|*[!0-9A-Za-z._:-]*|*::*|*::*) return 1 ;;
  esac
  _ceog_lock="$LOCKDIR/execute_nodes.lock"
  [ -d "$_ceog_lock" ] || return 1
  _ceog_pid=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' "$_ceog_lock/owner" 2>/dev/null | head -n 1)
  _ceog_start=$(sed -n 's/^proc_start_time=\([0-9][0-9]*\)$/\1/p' "$_ceog_lock/owner" 2>/dev/null | head -n 1)
  _ceog_nonce=$(sed -n 's/^owner_nonce=\([A-Za-z0-9._:-][A-Za-z0-9._:-]*\)$/\1/p' "$_ceog_lock/owner" 2>/dev/null | head -n 1)
  [ "$_ceog_pid" = "$MERV_OBS_EXECUTE_NODES_OWNER_PID" ] || return 1
  [ "$_ceog_start" = "$MERV_OBS_EXECUTE_NODES_OWNER_START" ] || return 1
  [ "$_ceog_nonce" = "$MERV_OBS_EXECUTE_NODES_OWNER_NONCE" ] || return 1
  merv_process_identity_matches "$_ceog_pid" "$_ceog_start" 2>/dev/null
}

# An apply already requests its own post-apply collection. Do not let a page
# load or manual refresh start a second collection while configuration is
# mutating. post_apply_worker.sh retries pending generations after the manager
# releases these locks, so this is safe for apply-owned collection too.
if type merv_lock_state >/dev/null 2>&1; then
  case "$(merv_lock_state "$LOCKDIR/mervlan_manager.lock")" in
    active|unknown)
      info -c cli,vlan "Client collection skipped while VLAN apply is active"
      exit 75
      ;;
  esac
  case "$(merv_lock_state "$LOCKDIR/execute_nodes.lock")" in
    active|unknown)
      if collect_execute_nodes_observation_grant_valid; then
        info -c cli,vlan "Client collection authorized by the terminal node-apply owner"
      else
        info -c cli,vlan "Client collection skipped while node apply is active"
        exit 75
      fi
      ;;
  esac
fi

if type merv_lock_acquire >/dev/null 2>&1; then
  mkdir -p "$LOCKDIR" 2>/dev/null || { error -c cli,vlan "Client collection: lock directory unavailable"; exit 1; }
  if merv_lock_acquire "$COLLECT_LOCK" "${COLLECT_STALE_SEC:-300}" 0 "client_collect"; then
    COLLECT_LOCK_ACQUIRED=1
    COLLECT_LOCK_NONCE="${MERV_LOCK_NONCE:-}"
  else
    info -c cli,vlan "Client collection already running — skipping"
    exit 75
  fi
fi

info -c cli,vlan "Refreshing client list started"

# Create temporary collection directory and results directory
mkdir -p "$COLLECTDIR" "$RESULTDIR"

# Do NOT remove the old OUT_FINAL here. It stays visible to the frontend until
# the new fully-annotated file is atomically published at the end of this script.
# Writing to a work file and renaming at the end prevents the browser from
# seeing a missing, partial, or unannotated file during collection.
OUT_WORK="${OUT_FINAL}.new.$$"

# ============================================================================ #
#                             HELPER FUNCTIONS                                 #
# Utility functions for node discovery, SSH validation, and remote collection  #
# of VLAN client data from both main router and satellite nodes.               #
# ============================================================================ #

# ============================================================================ #
# get_node_ips                                                                 #
# Extract NODE1-NODE10 IP addresses from settings.json. Parse JSON format       #
# and filter out "none" entries and invalid IP addresses.                      #
# Returns: "node_id ip" pairs, one per line (e.g., "1 192.168.1.100")          #
# ============================================================================ #
get_node_ips() {
  merv_node_list
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
  # This background worker must establish its own initial reachability proof.
  # It may then avoid exactly one duplicate ICMP probe in merv_ssh_exec.
  unset MERV_SSH_SKIP_PING

  info -c vlan "→ Collecting from node $node_ip (NODE${node_id})"

  # Use wrapper precheck (validates IP, keys, and ping)
  if ! merv_ssh_precheck "$node_id" "$node_ip"; then
    merv_ssh_skip_log "$node_id" "$node_ip" "collect"
    printf '{"router":"%s","error":"%s","vlans":[]}' "$node_ip" "$MERV_SSH_LAST_REASON" > "$output_file"
    return 1
  fi
  MERV_SSH_SKIP_PING=1
  export MERV_SSH_SKIP_PING

  # Run remote collector and fetch JSON via SSH wrapper
  # Publish a node-local collection generation and wait for that exact target.
  # This prevents the main cluster merge from bypassing/overlapping the node's
  # own snapshot or health-cron collection worker.
  # Keep the remote artifact's router identity equal to the configured IP.
  # The environment is exported once for both request and run-wait because the
  # coordinator executes the local collector only during the latter command.
  remote_cmd="export MERV_OBS_CLIENT_ROUTER='$node_ip'; MERV_OBS_NO_AUTOSTART=1 sh '$MERV_BASE/functions/post_apply_worker.sh' request collect >/dev/null 2>&1 && sh '$MERV_BASE/functions/post_apply_worker.sh' run-wait 120 >/dev/null 2>&1 && cat $COLLECTDIR/clients_local.json"
  
  _result_tmp="$COLLECTDIR/node_${node_ip}.out.$$"
  result=""
  if merv_ssh_exec "$node_id" "$node_ip" "$remote_cmd" >"$_result_tmp" 2>/dev/null; then
    rc=0
    result="$(cat "$_result_tmp" 2>/dev/null)"
  else
    rc=$?
  fi
  rm -f "$_result_tmp" 2>/dev/null || :

  if [ $rc -eq 0 ] && [ -n "$result" ]; then
    printf '%s' "$result" > "$output_file"
    info -c vlan "✓ Successfully collected from $node_ip"
    return 0
  else
    _reason="${MERV_SSH_LAST_REASON:-fetch-failed}"
    [ "$rc" -eq 0 ] && [ -z "$result" ] && _reason="empty-output"
    warn -c cli,vlan "Failed to fetch results from $node_ip (rc=$rc, reason=$_reason)"
    printf '{"router":"%s","error":"%s","vlans":[]}' "$node_ip" "$_reason" > "$output_file"
    return 1
  fi
}

# ============================================================================ #
#                         MAIN ROUTER COLLECTION                               #
# Invoke collect_local_clients.sh locally to gather VLAN bridges and client    #
# MAC addresses from the main router. Output written to temporary JSON file.   #
# ============================================================================ #

info -c vlan "Collecting VLAN clients"
MAIN_JSON="$COLLECTDIR/main.json"
MAIN_IP=$(nvram get lan_ipaddr 2>/dev/null | tr -d '\r\n')

collect_from_main() {
  if sh "$FUNCDIR/collect_local_clients.sh" "$MAIN_JSON" "Main Router" "$MAIN_IP" >>"$LOG_chan_cli" 2>&1; then
    info -c vlan "✓ Main router collection completed"
  else
    rc=$?
    error -c cli,vlan "✗ Main router collection failed (rc=$rc)"
    if [ ! -s "$MAIN_JSON" ]; then
      printf '{"router":"%s","error":"collector-failed","vlans":[]}' "Main Router" > "$MAIN_JSON"
    fi
  fi
}

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
  info -c vlan "No nodes configured in settings.json"
  NODES_ENABLED=false
else
  # Nodes are configured; check prerequisites before attempting collection
  NODES_ENABLED=true
  info -c vlan "Found configured nodes: $(echo "$NODE_IPS" | awk '{print $2}' | tr '\n' ' ')"

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

# A progress-backed collection must discover every untrusted node before
# starting even the local inventory job.  This lets the common SSH trust modal
# interrupt collection safely and keeps the original generation resumable.
if [ "$NODES_ENABLED" = "true" ] && [ "$DRY_RUN" != yes ]; then
  if type merv_ssh_preflight_grant_fresh >/dev/null 2>&1 && merv_ssh_preflight_grant_fresh; then
    info -c vlan "Reusing the verified SSH host-key preflight for this client refresh"
  else
  _collect_trust_file="$TMPDIR/collect_trust.$$"
  while IFS=' ' read -r _collect_slot _collect_ip _collect_extra || [ -n "$_collect_slot" ]; do
    [ -z "$_collect_extra" ] || { rm -f "$_collect_trust_file"; exit 2; }
    _collect_mac=$(json_get_flag "AUTO_NODE""$_collect_slot""_MAC" "" "$SETTINGS_FILE" 2>/dev/null)
    printf '%s %s %s\n' "$_collect_slot" "$_collect_ip" "$_collect_mac" >> "$_collect_trust_file" || {
      rm -f "$_collect_trust_file"
      exit 1
    }
  done <<EOF
$NODE_IPS
EOF
  merv_ssh_preflight_node_set "$_collect_trust_file"
  _collect_trust_rc=$?
  if [ "$_collect_trust_rc" -ne 0 ]; then
    _collect_trust_worker_rc=1
    _collect_trust_reason="$MERV_SSH_TRUST_LAST_REASON"
    [ -n "$_collect_trust_reason" ] || _collect_trust_reason=unknown
    warn -c cli,vlan "Collection refused before mutation: SSH host-key trust/capability preflight failed ($_collect_trust_reason)"
    if [ -n "$MERV_PROGRESS_TOKEN" ] && [ -f "$MERV_BASE/functions/ssh_trust_action.sh" ]; then
      MERV_SSH_TRUST_ORIGINAL_ACTION=collectclients_vlanmgr \
      MERV_SSH_TRUST_ACK_ACTION=collectclients_vlanmgr \
      sh "$MERV_BASE/functions/ssh_trust_action.sh" probe "$MERV_PROGRESS_TOKEN" >/dev/null 2>&1
      _collect_trust_worker_rc=$?
    fi
    if [ "$_collect_trust_worker_rc" -ne 0 ] && [ -n "$MERV_PROGRESS_TOKEN" ] &&
       type action_ack_ssh_trust_required >/dev/null 2>&1; then
      action_ack_ssh_trust_required "$MERV_PROGRESS_TOKEN" collectclients_vlanmgr \
        '{"reason":"ssh-trust-required"}' \
        "SSH host-key verification is required before client collection." '[]' >/dev/null 2>&1 || :
    fi
    rm -f "$_collect_trust_file" 2>/dev/null || :
    exit "$_collect_trust_rc"
  fi
  rm -f "$_collect_trust_file" 2>/dev/null || exit 75
  fi
fi

# Start main collection only after the complete node trust preflight passes.
( trap - EXIT INT TERM; collect_from_main ) &
MAIN_PID="$!"
BG_PIDS="$BG_PIDS $MAIN_PID"

if [ "$NODES_ENABLED" = "true" ]; then
  # Spawn collection background jobs for each node with PID tracking
  info -c vlan "Spawning node collection jobs (timeout: ${WAIT_TIMEOUT}s)..."
  
  # Write node IPs to temp file to avoid subshell issues with pipes
  _node_tmp="$COLLECTDIR/node_ips.tmp"
  printf '%s\n' "$NODE_IPS" > "$_node_tmp"
  
  # Read from file (not pipe) so background PIDs stay in this shell
  while read -r node_id node_ip; do
    [ -n "$node_id" ] || continue
    ( trap - EXIT INT TERM; collect_from_node "$node_id" "$node_ip" "$COLLECTDIR/node_${node_ip}.json" ) &
    # Track PID for cleanup handler
    BG_PIDS="$BG_PIDS $!"
  done < "$_node_tmp"
  rm -f "$_node_tmp"
fi

# Wait for all background jobs (main + nodes) with timeout
if [ -n "$BG_PIDS" ]; then
  waited=0
  while [ "$waited" -lt "$WAIT_TIMEOUT" ]; do
    _still_running=0
    for _pid in $BG_PIDS; do
      if [ -d "/proc/$_pid" ]; then
        _still_running=1
        break
      fi
    done

    [ "$_still_running" -eq 0 ] && break

    sleep 1
    waited=$((waited + 1))
  done

  if [ "$waited" -ge "$WAIT_TIMEOUT" ]; then
    warn -c cli,vlan "Client collection timeout after ${WAIT_TIMEOUT}s; some results may be incomplete"
    for _pid in $BG_PIDS; do
      [ -d "/proc/$_pid" ] && kill "$_pid" 2>/dev/null
    done
  else
    info -c vlan "All collection jobs finished in ${waited}s"
  fi

  for _pid in $BG_PIDS; do
    wait "$_pid" 2>/dev/null
  done
  BG_PIDS=""
fi

# ============================================================================ #
#                          MERGE RESULTS TO JSON                               #
# Combine main router and all node JSON files into a single result JSON.       #
# Add timestamp and array wrapper. Clean up intermediate files.                #
# ============================================================================ #

info -c vlan "Merging JSON results..."
# Capture current timestamp in ISO 8601 format
DATE_NOW=$(date +'%Y-%m-%dT%H:%M:%S')
# Unique run identifier: epoch seconds + PID. The frontend watches for this
# value to change so it does not have to compare browser time to router time.
RUN_ID="$(date +%s)-$$"

# Build final JSON structure with timestamp and array of node results.
# Write to a work file; atomic mv to OUT_FINAL happens after annotation.
{
  echo "{"
  echo "  \"generated\": \"$DATE_NOW\","
  echo "  \"run_id\": \"$RUN_ID\","
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
} > "$OUT_WORK"

# ============================================================================ #
#                  CLIENT METADATA ANNOTATION + LOCATION RESOLVER             #
# Two jobs in one AWK pass over the merged OUT_FINAL:                          #
#                                                                              #
# 1. LOCATION RESOLUTION. Each client object now carries source evidence        #
#    (source_iface/source_type/source_port/fdb_age/location_confidence) from    #
#    collect_local_clients.sh. A MAC can be observed on several VLAN bridges     #
#    and several routers (directly, or learned through a trunk/backhaul). We     #
#    group every observation by MAC and pick the active location by confidence:  #
#      direct  (ssid/access)  beats  unknown (legacy)  beats  relayed (trunk).   #
#    Within the winning tier the freshest FDB age wins. If two different routers #
#    both have a close direct observation (or a MAC is directly attached on two  #
#    VLANs at once) the location is flagged ambiguous. A MAC seen ONLY through a #
#    trunk/backhaul on every router has no direct owner: it is marked            #
#    location_status=relay_only + diagnostic=true and never counts as active.    #
#    Non-winning observations are kept (not deleted) and marked honestly with    #
#    active=false, duplicate=true, location_status and owner_router.             #
#                                                                              #
# 2. SHIELD/NAME ANNOTATION. Adds name + locked/override/unshielded/stale and    #
#    injects a stale_clients array for known MACs not seen in this collection.   #
#                                                                              #
# Fields added per client:                                                      #
#   active            : true on the resolved active location, false elsewhere    #
#   locked            : MAC in MERV_MAC shield db AND not overridden             #
#   override          : MAC in the cluster-wide shield override db               #
#   unshielded        : MAC in neither shield nor override db                    #
#   name              : display name from the main-only client name db           #
#   stale             : known MAC not seen in this collection                    #
#   location_status   : direct | relayed | relay_only | ambiguous | unknown      #
#   diagnostic        : true when a MAC is seen ONLY via trunk/backhaul anywhere #
#                       (relay-only, no direct owner) — never an active client    #
#   duplicate         : true for non-active duplicate observations               #
#   location_conflict : true when direct observations conflict (cross-router or   #
#                       cross-VLAN) and the active location is unresolved          #
#   owner_router      : router that holds the active location (on duplicates)     #
#                                                                              #
# Best-effort: any failure leaves the un-annotated OUT_FINAL in place.          #
# ============================================================================ #
SHIELD_DB=""
if type merv_mac_best_db >/dev/null 2>&1; then
  SHIELD_DB=$(merv_mac_best_db 2>/dev/null)
fi
[ -n "$SHIELD_DB" ] || SHIELD_DB="$MERV_MAC_DB_ACTIVE"

_ann_tmp="${OUT_FINAL}.ann.$$"
_ann_stats="${OUT_FINAL}.stats.$$"
if awk \
    -v shieldf="$SHIELD_DB" \
    -v overf="${MERV_MAC_OVERRIDE_DB:-}" \
    -v namef="${MERV_CLIENT_NAME_DB:-}" \
    -v statsf="$_ann_stats" '
  function jesc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); return s }
  # Extract a quoted-string JSON field value from a single line ("" if absent).
  function field(line, key,   re, s) {
    re="\"" key "\"[ \t]*:[ \t]*\"[^\"]*\""
    if (match(line, re)) {
      s=substr(line, RSTART, RLENGTH)
      sub(/^[^:]*:[ \t]*"/, "", s); sub(/"$/, "", s)
      return s
    }
    return ""
  }
  # Extract a numeric JSON field value from a single line (-1 if absent).
  function numfield(line, key,   re, s) {
    re="\"" key "\"[ \t]*:[ \t]*-?[0-9]+"
    if (match(line, re)) {
      s=substr(line, RSTART, RLENGTH)
      sub(/^.*:[ \t]*/, "", s)
      return s+0
    }
    return -1
  }
  BEGIN {
    BIG=1000000000; AMBIG=30
    shieldN=0; overN=0; nameN=0
    if (shieldf != "") {
      while ((getline ln < shieldf) > 0) {
        n=split(ln,a," "); if (n>=2) { shield[tolower(a[2])]=1; shieldN++ }
      }
      close(shieldf)
    }
    if (overf != "") {
      while ((getline ln < overf) > 0) {
        gsub(/[ \t\r]/,"",ln)
        if (ln != "" && ln !~ /^#/) { over[tolower(ln)]=1; overN++ }
      }
      close(overf)
    }
    if (namef != "") {
      while ((getline ln < namef) > 0) {
        ti=index(ln,"\t")
        if (ti>0) {
          m=substr(ln,1,ti-1); gsub(/[ \t\r]/,"",m); m=tolower(m)
          nm=substr(ln,ti+1); sub(/\r$/,"",nm)
          if (m != "") { name[m]=nm; namekeys[m]=1; nameN++ }
        }
      }
      close(namef)
    }
    curRouter=""
    curVlan=""
    obsN=0
  }
  {
    lines[NR]=$0
    # Track which router section we are inside (each node object has a router).
    if ($0 ~ /"router"[ \t]*:/) { curRouter=field($0,"router") }
    # Track which VLAN object we are inside ("id" only appears on vlan objects).
    if ($0 ~ /^[ \t]*"id"[ \t]*:/) { curVlan=field($0,"id") }
    # A client object occupies its own line beginning with {"mac": ...
    if ($0 ~ /^[ \t]*\{[ \t]*"mac"[ \t]*:/) {
      mac=field($0,"mac"); lm=tolower(mac)
      conf=field($0,"location_confidence"); if (conf=="") conf="unknown"
      age=numfield($0,"fdb_age")
      obsN++
      oMac[obsN]=lm; oRouter[obsN]=curRouter; oConf[obsN]=conf; oAge[obsN]=age
      oVlan[obsN]=curVlan
      lineObs[NR]=obsN
      macObs[lm]=macObs[lm] " " obsN
      macSeen[lm]=1; seen[lm]=1
    }
  }
  END {
    total=NR
    activeCount=0; ambiguousCount=0; relayedMacCount=0; legacyN=0; relayOnlyMacCount=0

    # ---- Resolve the active location for every observed MAC ----
    for (mac in macSeen) {
      split(macObs[mac], idx, " ")
      bestDirect=0; bestDirectAge=BIG; directRouters=""; directRouterN=0
      bestUnknown=0; bestUnknownAge=BIG; unknownRouters=""; unknownRouterN=0
      directVlans=""; directVlanN=0
      nObs=0
      for (j in idx) {
        o=idx[j]; if (o=="") continue; o=o+0; nObs++
        c=oConf[o]; a=oAge[o]; if (a<0) a=BIG
        if (c=="direct") {
          if (a<bestDirectAge){ bestDirectAge=a; bestDirect=o }
          rk="|" oRouter[o] "|"
          if (index(directRouters,rk)==0){ directRouters=directRouters rk; directRouterN++ }
          # Distinct VLANs carrying a *direct* attachment for this MAC. More than
          # one means the same device looks directly attached on two VLANs at
          # once, which is a genuine cross-VLAN conflict (not just a backhaul echo).
          vk="|" oVlan[o] "|"
          if (oVlan[o]!="" && index(directVlans,vk)==0){ directVlans=directVlans vk; directVlanN++ }
        } else if (c=="relayed") {
          ; # relayed never wins; handled implicitly
        } else {
          if (a<bestUnknownAge){ bestUnknownAge=a; bestUnknown=o }
          rk="|" oRouter[o] "|"
          if (index(unknownRouters,rk)==0){ unknownRouters=unknownRouters rk; unknownRouterN++ }
        }
      }

      winner=0; tier="relayed"; winAge=BIG; winRouterN=0
      if (bestDirect>0){ winner=bestDirect; tier="direct"; winAge=bestDirectAge; winRouterN=directRouterN }
      else if (bestUnknown>0){ winner=bestUnknown; tier="unknown"; winAge=bestUnknownAge; winRouterN=unknownRouterN; legacyN++ }

      # A MAC seen only via trunk/backhaul on every router (no direct/unknown
      # owner) is a relay-only diagnostic entry — never an active client.
      relayOnly=(winner==0)?1:0

      # Ambiguity: a competing observation in the winning tier on a different
      # router that is almost as fresh means we cannot confidently pick a side.
      ambiguous=0
      if (winner>0 && winRouterN>1) {
        otherBest=BIG
        for (j in idx) {
          o=idx[j]; if (o=="") continue; o=o+0
          c=oConf[o]
          if (tier=="direct" && c!="direct") continue
          if (tier=="unknown" && (c=="direct" || c=="relayed")) continue
          if (oRouter[o]==oRouter[winner]) continue
          a=oAge[o]; if (a<0) a=BIG
          if (a<otherBest) otherBest=a
        }
        if (otherBest!=BIG && (otherBest-winAge) < AMBIG) ambiguous=1
      }
      # Direct attachment on more than one VLAN is also an unresolved conflict.
      crossVlan=(tier=="direct" && directVlanN>1)?1:0
      if (crossVlan) ambiguous=1

      # Tally + assign per-observation result.
      if (winner>0) activeCount++
      if (ambiguous) ambiguousCount++
      if (relayOnly) relayOnlyMacCount++
      else if (tier=="relayed") relayedMacCount++
      for (j in idx) {
        o=idx[j]; if (o=="") continue; o=o+0
        c=oConf[o]
        if (o==winner) {
          rActive[o]=1
          rStatus[o]=(ambiguous?"ambiguous":tier)
          rConflict[o]=(ambiguous?1:0)
          rDup[o]=0
          rOwner[o]=""
          rDiag[o]=0
        } else if (relayOnly) {
          # No owner anywhere: every observation is a relay-only diagnostic.
          rActive[o]=0
          rStatus[o]="relay_only"
          rDiag[o]=1
          rDup[o]=(nObs>1?1:0)
          rOwner[o]=""
          rConflict[o]=0
        } else {
          rActive[o]=0
          rDup[o]=(nObs>1?1:0)
          rOwner[o]=(winner>0?oRouter[winner]:"")
          rDiag[o]=0
          if (c=="direct") rStatus[o]=(ambiguous?"ambiguous":"direct")
          else if (c=="relayed") rStatus[o]="relayed"
          else rStatus[o]="unknown"
          rConflict[o]=((ambiguous && c=="direct")?1:0)
        }
      }
    }

    # ---- Rewrite each client line with resolution + shield annotation ----
    for (i=1;i<=total;i++) {
      if (i in lineObs) {
        o=lineObs[i]; lm=oMac[o]
        ln=lines[i]; indent=ln; sub(/[^ \t].*$/,"",indent)
        si=field(ln,"source_iface"); st=field(ln,"source_type"); sp=field(ln,"source_port")
        fa=numfield(ln,"fdb_age"); lc=field(ln,"location_confidence")
        isover=(lm in over)?1:0
        islock=((lm in shield) && !isover)?1:0
        unshield=((!(lm in shield)) && (!(lm in over)))?1:0
        obj=indent "{\"mac\": \"" lm "\""
        if (si!="") obj=obj ", \"source_iface\": \"" jesc(si) "\""
        if (st!="") obj=obj ", \"source_type\": \"" jesc(st) "\""
        if (sp!="") obj=obj ", \"source_port\": \"" jesc(sp) "\""
        obj=obj ", \"fdb_age\": " fa
        if (lc!="") obj=obj ", \"location_confidence\": \"" jesc(lc) "\""
        if (lm in name) obj=obj ", \"name\": \"" jesc(name[lm]) "\""
        obj=obj ", \"active\": " (rActive[o]?"true":"false")
        obj=obj ", \"locked\": " (islock?"true":"false")
        obj=obj ", \"override\": " (isover?"true":"false")
        obj=obj ", \"unshielded\": " (unshield?"true":"false")
        obj=obj ", \"stale\": false"
        obj=obj ", \"location_status\": \"" rStatus[o] "\""
        if (rDiag[o]) obj=obj ", \"diagnostic\": true"
        if (rDup[o]) obj=obj ", \"duplicate\": true"
        if (rConflict[o]) obj=obj ", \"location_conflict\": true"
        if (rOwner[o]!="") obj=obj ", \"owner_router\": \"" jesc(rOwner[o]) "\""
        obj=obj "}"
        lines[i]=obj
      }
    }

    # ---- Stale clients: known MACs not present anywhere in this collection ----
    scount=0
    for (m in shield)   { if (!(m in seen)) stalem[m]=1 }
    for (m in over)     { if (!(m in seen)) stalem[m]=1 }
    for (m in namekeys) { if (!(m in seen)) stalem[m]=1 }
    for (m in stalem)   { scount++ }

    for (i=1;i<=total;i++) {
      if (i==total-1 && scount>0 && total>=2) {
        print lines[i] ","
        print "  \"stale_clients\": ["
        first=1
        for (m in stalem) {
          isover=(m in over)?1:0
          islock=((m in shield) && !isover)?1:0
          unshield=((!(m in shield)) && (!(m in over)))?1:0
          obj="    {\"mac\": \"" m "\""
          if (m in name) { obj=obj ", \"name\": \"" jesc(name[m]) "\"" }
          obj=obj ", \"active\": false"
          obj=obj ", \"locked\": " (islock?"true":"false")
          obj=obj ", \"override\": " (isover?"true":"false")
          obj=obj ", \"unshielded\": " (unshield?"true":"false")
          obj=obj ", \"stale\": true}"
          if (first) { first=0 } else { printf ",\n" }
          printf "%s", obj
        }
        printf "\n"
        print "  ]"
      } else {
        print lines[i]
      }
    }

    if (statsf != "") {
      printf "shield=%d override=%d names=%d active=%d stale=%d ambiguous=%d relayed=%d relayonly=%d legacy=%d\n", \
        shieldN, overN, nameN, activeCount, scount, ambiguousCount, relayedMacCount, relayOnlyMacCount, legacyN > statsf
      close(statsf)
    }
  }
' "$OUT_WORK" > "$_ann_tmp" 2>/dev/null && [ -s "$_ann_tmp" ]; then
  mv "$_ann_tmp" "$OUT_WORK" 2>/dev/null || rm -f "$_ann_tmp" 2>/dev/null
  if [ -f "$_ann_stats" ]; then
    info -c vlan "Client annotation: $(cat "$_ann_stats" 2>/dev/null)"
    rm -f "$_ann_stats" 2>/dev/null
  fi
  info -c vlan "Client metadata annotation applied"
else
  rm -f "$_ann_tmp" "$_ann_stats" 2>/dev/null
  warn -c cli,vlan "Client metadata annotation skipped (kept raw collection)"
fi

# Atomically publish the finished file. The old OUT_FINAL stays readable until
# this rename completes, so the frontend never sees a missing file.
mv "$OUT_WORK" "$OUT_FINAL" 2>/dev/null || {
  warn -c cli,vlan "Failed to publish $OUT_FINAL; leaving work file at $OUT_WORK"
  exit 1
}

# ============================================================================ #
#                            CLEANUP & COMPLETION                              #
# Remove temporary collection directory and all intermediate JSON files.       #
# Log final result location and exit successfully.                             #
# ============================================================================ #

# Remove temporary directory and all intermediate collection files
rm -rf "$COLLECTDIR"

info -c vlan "✓ Client collection completed - JSON saved to $OUT_FINAL"
info -c cli,vlan "Refreshing client list complete"
exit 0
