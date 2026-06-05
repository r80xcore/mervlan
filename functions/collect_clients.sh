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
#                - File: collect_clients.sh || version="0.50"                  #
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
# Only the process that OWNS the collection lock may remove COLLECTDIR — a
# second (skipped) collector must never delete the working dir out from under
# the running owner. The lock itself is released here too.
cleanup_collect() {
  # Kill any remaining background collection jobs
  for pid in $BG_PIDS; do
    kill "$pid" 2>/dev/null
  done
  # Remove temporary collection directory only if we own the lock
  if [ "${COLLECT_LOCK_ACQUIRED:-0}" -eq 1 ]; then
    [ -d "$COLLECTDIR" ] && rm -rf "$COLLECTDIR" 2>/dev/null
    if type merv_lock_release >/dev/null 2>&1; then
      merv_lock_release "$COLLECT_LOCK" 2>/dev/null
    fi
  fi
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
if type merv_lock_acquire >/dev/null 2>&1; then
  mkdir -p "$LOCKDIR" 2>/dev/null || :
  if merv_lock_acquire "$COLLECT_LOCK" "${COLLECT_STALE_SEC:-300}" 0 "client_collect"; then
    COLLECT_LOCK_ACQUIRED=1
  else
    info -c cli,vlan "Client collection already running — skipping"
    exit 0
  fi
fi

info -c cli,vlan "=== VLAN Client Collection Started ==="

# Create temporary collection directory and results directory
mkdir -p "$COLLECTDIR" "$RESULTDIR"

# Remove any stale results file from previous collection attempts
if [ -f "$OUT_FINAL" ]; then
  rm -f "$OUT_FINAL"
  info -c vlan "Cleared previous results at $OUT_FINAL"
fi

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

info -c cli,vlan "Collecting VLAN clients"
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
  info -c vlan "Spawning node collection jobs (timeout: ${WAIT_TIMEOUT}s)..."
  
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
    info -c vlan "All node collections finished in ${waited}s"
  fi
fi

# ============================================================================ #
#                          MERGE RESULTS TO JSON                               #
# Combine main router and all node JSON files into a single result JSON.       #
# Add timestamp and array wrapper. Clean up intermediate files.                #
# ============================================================================ #

info -c vlan "Merging JSON results..."
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
' "$OUT_FINAL" > "$_ann_tmp" 2>/dev/null && [ -s "$_ann_tmp" ]; then
  mv "$_ann_tmp" "$OUT_FINAL" 2>/dev/null || rm -f "$_ann_tmp" 2>/dev/null
  if [ -f "$_ann_stats" ]; then
    info -c vlan "Client annotation: $(cat "$_ann_stats" 2>/dev/null)"
    rm -f "$_ann_stats" 2>/dev/null
  fi
  info -c vlan "Client metadata annotation applied"
else
  rm -f "$_ann_tmp" "$_ann_stats" 2>/dev/null
  warn -c cli,vlan "Client metadata annotation skipped (kept raw collection)"
fi

# ============================================================================ #
#                            CLEANUP & COMPLETION                              #
# Remove temporary collection directory and all intermediate JSON files.       #
# Log final result location and exit successfully.                             #
# ============================================================================ #

# Remove temporary directory and all intermediate collection files
rm -rf "$COLLECTDIR"

info -c vlan "✓ Client collection completed - JSON saved to $OUT_FINAL"
info -c cli,vlan "=== VLAN Client Collection Finished ==="
exit 0