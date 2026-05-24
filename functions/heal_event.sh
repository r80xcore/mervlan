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
#                  - File: heal_event.sh || version="0.60"                     #
# ============================================================================ #
# - Purpose:    Automated healing of VLAN configurations called by with        #
#               cooldown to avoid rapid retriggers. Called if invoked by       #
#               the service-event wrapper.                                     #
# ============================================================================ #
#                                                                              #
# ================================================== MerVLAN environment setup #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_JSON_LOADED LIB_SSID_FILTER_LOADED LIB_MERVQT_LOADED LIB_MAC_SHIELD_SNAPSHOT_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_JSON_LOADED:-}" ]   || . "$MERV_BASE/settings/lib_json.sh"
[ -n "${LIB_SSID_FILTER_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssid_filter.sh"
# Graceful-degradation: load MERV_MAC enforcement libs if present.
# heal_event.sh degrades safely if the files are missing (partial install).
[ -n "${LIB_MERVQT_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mervqt.sh" 2>/dev/null || true
[ -n "${LIB_MAC_SHIELD_SNAPSHOT_LOADED:-}" ] || . "$MERV_BASE/settings/mac_shield_snapshot.sh" 2>/dev/null || true
# =========================================== End of MerVLAN environment setup #
. /usr/sbin/helper.sh

# Bootstrap hardware layout (MAX_SSIDS, ETH_PORTS) similar to mervlan_manager.sh
: "${HW_SETTINGS_FILE:=$SETTINGS_FILE}"

if [ -z "${MAX_SSIDS:-}" ]; then
  MAX_SSIDS=$(json_get_int MAX_SSIDS 12 "$HW_SETTINGS_FILE")
fi

if [ -z "${ETH_PORTS:-}" ]; then
  ETH_PORTS=$(json_get_section_array "Hardware" "ETH_PORTS" "$HW_SETTINGS_FILE")
  [ -z "$ETH_PORTS" ] && ETH_PORTS=$(json_get_array ETH_PORTS "$HW_SETTINGS_FILE")
fi

# Initialize SSID filter based on node identity (affects which VLAN slots we consider)
MERV_NODE_ID="$(json_get_flag NODE_ID "" "$SETTINGS_FILE")"
ssid_filter_init "$MERV_NODE_ID"
# ====================================================== Bootstrap Tick Probe
# Determine sub-second or fallback tick command dynamically.
# 100,000 microseconds = 100ms (0.1s). Fallback is 1 second.
if usleep 1 2>/dev/null; then
  export TICK_CMD="usleep 100000"
  export TICKS_PER_SEC=10
  TICK_LABEL="usleep (100ms)"
else
  export TICK_CMD="sleep 1"
  export TICKS_PER_SEC=1
  TICK_LABEL="sleep (1s)"
fi
# ================================================= End of Bootstrap Tick Probe

# ============================================================================ #
#                          INITIALIZATION & SETUP                              #
# Establish locks to prevent concurrent execution, implement cooldown and      #
# debounce mechanisms to avoid rapid re-triggers, and verify VLAN              #
# configurations exist before proceeding.                                      #
# ============================================================================ #

# ============================================================================ #
#                             HELPER FUNCTIONS                                 #
# Utility functions for VLAN validation, service monitoring, and config        #
# consistency checks.                                                          #
# ============================================================================ #

trim_spaces() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

to_lower() {
  printf '%s' "$1" | tr 'A-Z' 'a-z'
}

is_number() {
  local v
  v=$(trim_spaces "$1")
  case "$v" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

sanitize_epoch() {
  local v
  v=$(trim_spaces "$1")
  is_number "$v" || v=0
  printf '%s' "${v:-0}"
}

# ============================================================================ #
# any_vlan_configured                                                          #
# Scan settings.json for any numeric VLAN assignments (2–4094) on Ethernet     #
# ports or SSIDs. Returns 0 if at least one valid VLAN is found, 1 if none.    #
# Used as early guard to skip processing if no VLANs are configured.           #
# ============================================================================ #
any_vlan_configured() {
  # Ensure MAX_SSIDS is numeric; fallback to 12 if unset
  local max_ssids
  max_ssids=$(sanitize_epoch "$MAX_SSIDS")
  [ "$max_ssids" -ge 1 ] 2>/dev/null || max_ssids=12

  # Check Ethernet port VLANs (VLAN.Ethernet_ports.ETHx_VLAN)
  local idx=1 vlan token
  for eth in $ETH_PORTS; do
    # Use nested structure first, fallback to flat
    vlan=$(json_get_section2_value "VLAN" "Ethernet_ports" "ETH${idx}_VLAN" "$SETTINGS_FILE" 2>/dev/null)
    if [ -z "$vlan" ] || [ "$vlan" = "none" ]; then
      vlan=$(json_get_flag "ETH${idx}_VLAN" "" "$SETTINGS_FILE")
    fi
    vlan=$(trim_spaces "$vlan")
    token=$(to_lower "$vlan")
    # Ignore unconfigured, trunk, or non-numeric entries
    case "$token" in
      ''|none) ;;                      # not configured
      trunk) ;;                        # not a specific VLAN ID
      # Valid VLAN ID range is 2–4094 (excluding default VLAN 1)
      *) if is_number "$vlan" && [ "$vlan" -ge 2 ] && [ "$vlan" -le 4094 ]; then return 0; fi ;;
    esac
    idx=$((idx+1))
  done

  # Check SSID VLANs from VLAN pool (VLAN_01..VLAN_NN, filtered by node assignment)
  # We only care if any VLAN_NN is a valid VLAN ID assigned to this node.
  local i=1 vlan tmp
  while [ $i -le "$max_ssids" ]; do
    # Use filtered accessor to respect node assignment
    vlan=$(get_vlan_slot_value "$i" "$SETTINGS_FILE")
    # Check for fatal filter condition after first accessor call
    if [ "$i" -eq 1 ] && [ "${SSID_FILTER_FATAL:-0}" = "1" ]; then
      error -c vlan "Heal: aborting due to SSID filter fatal condition (MAX_SSIDS not set)"
      return 1
    fi
    vlan=$(trim_spaces "$vlan")
    if is_number "$vlan" && [ "$vlan" -ge 2 ] && [ "$vlan" -le 4094 ]; then
      return 0
    fi
    i=$((i+1))
  done

  return 1
}

# ============================================================================ #
#                         PRE-EXECUTION VALIDATION                             #
# Fast-path exit if no VLANs configured, establish lock to prevent concurrent  #
# execution, and initialize cooldown/debounce mechanisms.                      #
# ============================================================================ #

# Fast path: if settings define no numeric VLANs, do nothing
if ! any_vlan_configured; then
  info -c cli,vlan "Heal: no VLANs configured in settings; exiting"
  exit 0
fi

# Skip if vlan manager already busy (avoid holding our lock needlessly)
MANAGER_LOCK="$LOCKDIR/mervlan_manager.lock"
if [ -d "$MANAGER_LOCK" ]; then
  info -c vlan "Heal: skipping [${1:-initial}] because mervlan_manager is active"
  exit 0
fi

# Ensure locks directory exists for all lock/cooldown files
mkdir -p "$LOCKDIR" 2>/dev/null

# Simple lock using mkdir (atomic operation) to avoid concurrent runs
LOCK="$LOCKDIR/vlan_event.lock"
if mkdir "$LOCK" 2>/dev/null; then
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM
else
  exit 0
fi

# ============================================================================ #
#                         COOLDOWN & DEBOUNCE LOGIC                            #
# Implement rate limiting to prevent rapid re-triggers of vlan_manager.sh      #
# (90-second minimum interval) and event debouncing (2-second minimum).        #
# ============================================================================ #

# Cooldown file tracks last vlan_manager execution time (prevents thrashing)
COOLDOWN_FILE="$LOCKDIR/vlan_heal.last"
COOLDOWN_SEC=90
# Delay between config checks during retry (allows interfaces to settle)
VLAN_SETTLE_DELAY="${VLAN_SETTLE_DELAY:-3}"
VLAN_SETTLE_DELAY=$(sanitize_epoch "$VLAN_SETTLE_DELAY")
[ "$VLAN_SETTLE_DELAY" -ge 1 ] 2>/dev/null || VLAN_SETTLE_DELAY=3

# Health heartbeat and mismatch tracking for cron-based monitoring
HEALTH_OK_FILE="$LOCKDIR/vlan_health_ok.last"
HEALTH_LOG_INTERVAL_SEC=$((12 * 3600)) # 12 hours
LAST_MISMATCH_FILE="$LOCKDIR/vlan_last_mismatch.last"

# ============================================================================ #
# heal_allowed                                                                 #
# Check if sufficient time has elapsed (COOLDOWN_SEC) since last vlan_manager  #
# invocation. Returns 0 if heal allowed.                                       #
# ============================================================================ #
heal_allowed() {
  local now last_raw last
  now=$(date +%s)
  
  # Read timestamp of last heal; default to 0 (epoch) if file doesn't exist
  last_raw=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
  last=$(sanitize_epoch "$last_raw")
  # Return success if elapsed time >= cooldown threshold
  [ $((now - last)) -ge "$COOLDOWN_SEC" ]
}

# ============================================================================ #
# mark_heal                                                                    #
# Record current timestamp in cooldown file to mark when vlan_manager was      #
# invoked. Used to enforce rate-limiting for subsequent heal attempts.         #
# ============================================================================ #
mark_heal() {
  date +%s > "$COOLDOWN_FILE"
}


record_mismatch() {
  date +%s > "$LAST_MISMATCH_FILE"
}

log_health_ok_if_needed() {
  local now last_ok_raw last_ok last_m_raw last_m since_ts hours since_str

  now=$(date +%s)
  last_ok_raw=$(cat "$HEALTH_OK_FILE" 2>/dev/null || echo 0)
  last_ok=$(sanitize_epoch "$last_ok_raw")

  if [ $((now - last_ok)) -lt "$HEALTH_LOG_INTERVAL_SEC" ]; then
    return 0
  fi

  last_m_raw=$(cat "$LAST_MISMATCH_FILE" 2>/dev/null || echo 0)
  last_m=$(sanitize_epoch "$last_m_raw")

  if [ "$last_m" -gt 0 ]; then
    since_ts="$last_m"
  else
    since_ts="$now"
  fi

  hours=$(( (now - since_ts) / 3600 ))
  [ "$hours" -lt 0 ] && hours=0

  since_str=$(date -d "@$since_ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')

  info -c vlan "Heal: no VLAN damage since ${since_str} (≈${hours}h ago)"

  printf '%s\n' "$now" > "$HEALTH_OK_FILE"
}

# ============================================================================ #
#                           VLAN VALIDATION LOGIC                              #
# Functions to query actual VLAN interfaces from kernel and expected VLANs     #
# from settings.json, then compare for mismatches.                             #
# ============================================================================ #

# ============================================================================ #
# actual_vlans_from_kernel                                                     #
# Enumerate bridge interfaces (br1, br2, ...) currently active in the kernel   #
# by scanning /sys/class/net. Excludes br0 (main LAN bridge). Returns sorted   #
# numeric list of VLAN IDs.                                                    #
# ============================================================================ #
bridge_has_members() {
  local br member has_edge members count
  br="$1"

  [ -d "/sys/class/net/$br/brif" ] || return 1

  members=$(ls "/sys/class/net/$br/brif" 2>/dev/null)
  [ -n "$members" ] || return 1

  count=0
  has_edge=0
  for member in $members; do
    count=$((count + 1))
    case "$member" in
      eth0|eth0.*|vlan[0-9]*|bond[0-9]*) ;;  # Uplink/WAN only - don't count as edge
      eth[0-9]*) has_edge=1 ;;  # LAN port or LAN VLAN subinterface (trunk) - count as edge
      wl*|ra*|ath*|psta*|apcli*|lan*|wan*) has_edge=1 ;;  # Wireless/client interfaces
      *) has_edge=1 ;;
    esac
  done

  [ "$count" -gt 0 ] && [ "$has_edge" -eq 1 ]
}

actual_vlans_from_kernel() {
  local br name

  for br in /sys/class/net/br[0-9]*; do
    [ -e "$br" ] || continue
    name="${br##*/}"
    [ "$name" = "br0" ] && continue

    if bridge_has_members "$name"; then
      printf '%s\n' "${name#br}"
    fi
  done | sort -n
}

# ============================================================================ #
# wl_leaked_to_br0                                                             #
# Detect the restart_wireless race condition where firmware dumps wireless     #
# SSID subinterfaces back into br0 while trunk subinterfaces keep VLAN bridges #
# alive, causing bridge_has_members / actual_vlans_from_kernel to report a     #
# false-positive healthy state.                                                #
#                                                                              #
# Logic: only flag a leak when BOTH conditions hold simultaneously:            #
#   1. At least one wl*.* (or ra*.*|ath*.*) subinterface is present in br0    #
#   2. No such subinterface exists in ANY non-br0 VLAN bridge                 #
#                                                                              #
# This dual condition self-filters unmanaged guest networks: if wl0.2 is a    #
# native Asuswrt guest legitimately in br0, but MerVLAN's wl0.1 is correctly  #
# in br5, condition 2 is false and no alert fires. Post-heal, once the managed #
# interfaces are restored to their VLAN bridges, condition 2 flips false again #
# and the check clears — no infinite loop.                                     #
#                                                                              #
# Returns 0 (true) if a leak is detected, 1 (false) otherwise.                #
# ============================================================================ #
wl_leaked_to_br0() {
  local iface_path iface has_wl_in_br0 has_wl_in_vlan br_path

  has_wl_in_br0=0
  has_wl_in_vlan=0

  # Condition 1: any wl*.* subinterface in br0?
  for iface_path in /sys/class/net/br0/brif/*; do
    [ -e "$iface_path" ] || continue
    iface="${iface_path##*/}"
    case "$iface" in
      wl*.*|ra*.*|ath*.*)
        has_wl_in_br0=1
        break
        ;;
    esac
  done

  [ "$has_wl_in_br0" -eq 1 ] || return 1

  # Condition 2: no wl*.* subinterface in any VLAN bridge (br1..br9*)?
  for br_path in /sys/class/net/br[1-9]*/brif; do
    [ -d "$br_path" ] || continue
    for iface_path in "$br_path"/*; do
      [ -e "$iface_path" ] || continue
      iface="${iface_path##*/}"
      case "$iface" in
        wl*.*|ra*.*|ath*.*)
          has_wl_in_vlan=1
          break 2
          ;;
      esac
    done
  done

  [ "$has_wl_in_vlan" -eq 0 ]
}

# ============================================================================ #
# check_wl_iface_placements                                                    #
# Per-interface leak detector using settings-derived expected placements.      #
# Checks each config-expected wl subinterface individually:                    #
#   - If in br0: report a per-interface leak                                   #
#   - If in correct VLAN bridge: report as correct                             #
#   - If in neither: log at debug level (may be restarting; not a hard fail)  #
#                                                                              #
# Returns 0 if ALL expected interfaces are in their correct VLAN bridge.       #
# Returns 1 on any mismatch (at least one interface is in br0).                #
#                                                                              #
# Unlike wl_leaked_to_br0, this fires even when only SOME interfaces leaked    #
# (e.g. native guest SSID keeps condition 2 of wl_leaked_to_br0 false).       #
# ============================================================================ #
check_wl_iface_placements() {
  local pairs iface vid ok

  ok=1
  pairs=$(merv_mac_build_expected_iface_vid 2>/dev/null) || return 0
  [ -n "$pairs" ] || return 0

  while IFS=' ' read -r iface vid; do
    [ -n "$iface" ] && [ -n "$vid" ] || continue

    if [ -e "/sys/class/net/br${vid}/brif/$iface" ]; then
      # Correctly placed in its VLAN bridge
      continue
    elif [ -e "/sys/class/net/br0/brif/$iface" ]; then
      warn -c vlan "Placement: $iface expected br${vid} but is in br0 — restart_wireless race suspected"
      ok=0
    else
      dbg_log "Placement: $iface expected br${vid} but found in neither bridge (may be restarting)"
    fi
  done <<_PAIRS_
$pairs
_PAIRS_

  [ "$ok" -eq 1 ]
}

# ============================================================================ #
# evict_wl_from_br0                                                            #
# Pre-eviction guard: immediately removes wl subinterfaces from br0 before    #
# invoking the VLAN manager, closing the DHCP leak window that exists while   #
# the manager is detecting and repairing bridges. Brings each subinterface    #
# down first so clients cannot grab a br0 lease in the gap between the delif  #
# and the manager's brctl addif into the correct VLAN bridge.                 #
# Scoped to MERVLAN-managed interfaces only — firmware-owned interfaces (e.g. #
# AiMesh management SSIDs like wl0.1 on nodes) that legitimately belong in    #
# br0 are never touched.                                                       #
# ============================================================================ #
evict_wl_from_br0() {
  local iface iface_path evicted managed_ifaces
  evicted=0

  # Resolve MERVLAN-managed wl interfaces from settings + NVRAM.
  # Only these can leak to br0; firmware-owned AiMesh SSIDs must be left alone.
  managed_ifaces=""
  if type merv_mac_build_expected_iface_vid >/dev/null 2>&1; then
    managed_ifaces=$(merv_mac_build_expected_iface_vid 2>/dev/null | awk '{print $1}')
  fi
  # Nothing to evict if no MERVLAN-managed wl interfaces are configured.
  [ -n "$managed_ifaces" ] || return 0

  for iface_path in /sys/class/net/br0/brif/wl*.*; do
    [ -e "$iface_path" ] || continue
    iface="${iface_path##*/}"
    # Skip firmware-owned interfaces (not in MERVLAN-managed set)
    printf '%s\n' "$managed_ifaces" | grep -qxF "$iface" || continue
    wl -i "$iface" down 2>/dev/null
    brctl delif br0 "$iface" 2>/dev/null
    info -c vlan "Heal: pre-evicted $iface from br0 (DHCP gate)"
    evicted=$((evicted + 1))
  done
  [ "$evicted" -gt 0 ] && info -c vlan "Heal: evicted ${evicted} wl subinterface(s) from br0"
  return 0
}

# Script-level state for repair-log deduplication — reset once per process invocation.
_MERV_QT_SHIELD_STATE=""

# ============================================================================ #
# restore_merv_qt_shield                                                       #
# Called every tick inside wait_for_rc_quiet to re-arm the MERV_QT ebtables   #
# chain if Asuswrt's rc daemon flushed it during a rebuild sequence.           #
# Recreates the chain, re-inserts FORWARD/INPUT jumps (idempotent), and       #
# re-adds DROP rules for every guest wireless subinterface present in sysfs.  #
# Accepts an optional pre-fetched ebtables dump ($1) to avoid redundant reads. #
# Returns immediately (no-op) if ebtables is unavailable or chain is intact.  #
# ============================================================================ #
restore_merv_qt_shield() {
  type ebtables >/dev/null 2>&1 || return 0

  # Accept shared dump from wait_for_rc_quiet, or fetch independently
  local full_rules="${1:-}"
  [ -n "$full_rules" ] || full_rules=$(ebtables -t filter -L 2>/dev/null)

  local chain_exists=1
  local jumps_exist=1

  # 1. Did the chain survive?
  printf '%s' "$full_rules" | grep -qF 'Bridge chain: MERV_QT' || chain_exists=0

  # 2. Did both jump rules (FORWARD and INPUT) survive?
  # Must check even when chain exists — Asuswrt rc may flush the FORWARD/INPUT
  # chains (ebtables -F FORWARD) without touching MERV_QT, leaving the chain
  # intact but orphaned: DROP rules present but never reached.
  # MERV_QT's own rules use -j DROP, so any '-j MERV_QT' match originates
  # exclusively from FORWARD/INPUT jump rules. Count >= 2 means both are present.
  # Pattern 'j MERV_QT' (no leading dash): matches '-j MERV_QT' jump rules but NOT
  # 'Bridge chain: MERV_QT' (preceding char is ':' not 'j'). Avoids BusyBox v1.25.1
  # grep misinterpreting a leading '-j' pattern as an option flag.
  if [ "$chain_exists" -eq 1 ]; then
    if [ "$(printf '%s' "$full_rules" | grep -cF 'j MERV_QT')" -lt 2 ]; then
      jumps_exist=0
    fi
  else
    jumps_exist=0
  fi

  # Fast path: shield is completely intact — nothing to do
  if [ "$chain_exists" -eq 1 ] && [ "$jumps_exist" -eq 1 ]; then
    case "$_MERV_QT_SHIELD_STATE" in
      ""|"ok") ;;
      *) info -c vlan "Heal: MERV_QT shield stable — firmware flushing stopped" ;;
    esac
    _MERV_QT_SHIELD_STATE="ok"
    return 0
  fi

  # 3. Re-link jump rules (covers both orphaned-chain and full-wipe cases)
  ebtables -t filter -N MERV_QT 2>/dev/null || true
  ebtables -t filter -L FORWARD 2>/dev/null | grep -qF 'MERV_QT' || \
    ebtables -t filter -I FORWARD -j MERV_QT 2>/dev/null || true
  ebtables -t filter -L INPUT   2>/dev/null | grep -qF 'MERV_QT' || \
    ebtables -t filter -I INPUT   -j MERV_QT 2>/dev/null || true

  # 4. Rebuild per-interface DROP rules only if the chain itself was wiped.
  # If only jumps were flushed the chain and its rules are intact — skip rebuild.
  if [ "$chain_exists" -eq 0 ]; then
    local iface_path iface
    # Install DROP rules only for MERVLAN-managed interfaces. Firmware-owned
    # wl subinterfaces (e.g. AiMesh management SSIDs like wl0.1 on nodes)
    # legitimately reside in br0 and must never receive a DROP rule here.
    # Fall back to the sysfs scan only when the settings resolver is absent
    # (partial install / test environment).
    if type merv_mac_build_expected_iface_vid >/dev/null 2>&1; then
      merv_mac_build_expected_iface_vid 2>/dev/null | while IFS=' ' read -r _qt_iface _qt_vid; do
        [ -n "$_qt_iface" ] || continue
        ebtables -t filter -A MERV_QT -i "$_qt_iface" --logical-in br0 -j DROP 2>/dev/null || true
      done
    else
      for iface_path in /sys/class/net/wl*.* /sys/class/net/ra*.* /sys/class/net/ath*.*; do
        [ -e "$iface_path" ] || continue
        iface="${iface_path##*/}"
        ebtables -t filter -A MERV_QT -i "$iface" --logical-in br0 -j DROP 2>/dev/null || true
      done
    fi
    [ "$_MERV_QT_SHIELD_STATE" = "wiped" ] || \
      info -c vlan "Heal: MERV_QT chain flushed by rc — fully rebuilt shield"
    _MERV_QT_SHIELD_STATE="wiped"
  else
    [ "$_MERV_QT_SHIELD_STATE" = "orphaned" ] || \
      info -c vlan "Heal: MERV_QT orphaned by rc (FORWARD/INPUT jumps flushed) — re-linked shield"
    _MERV_QT_SHIELD_STATE="orphaned"
  fi
}

rc_queue_has() {
  [ -f /tmp/rc_service ] && grep -E "$1" /tmp/rc_service 2>/dev/null | grep -qv '^$'
}

rc_proc_busy() {
  ps w 2>/dev/null | grep -E "[s]ervice" | grep -E "$1" >/dev/null 2>&1
}

wait_for_rc_quiet() {
  local need_sec max_wait_sec quiet_ticks max_ticks quiet current_tick _rules

  need_sec="${1:-6}"
  max_wait_sec="${2:-45}"
  quiet_ticks=$(( need_sec * TICKS_PER_SEC ))
  max_ticks=$(( max_wait_sec * TICKS_PER_SEC ))
  quiet=0
  current_tick=0

  info -c vlan "wait_for_rc_quiet: watching rc (need=${need_sec}s quiet, method=${TICK_LABEL})"

  while :; do
    # Fetch ebtables filter table once per tick; pass to both restore functions
    # to avoid redundant netlink reads at tick rate. Gate on ebtables presence
    # to avoid spawning a missing binary on every tick.
    # evict_wl_from_br0 is intentionally NOT called here: repeated wl -i down
    # calls every tick interfere with firmware's restart_wireless sequence,
    # leaving radios permanently down. The single evict call after this
    # function returns (once rc is confirmed quiet) is the correct sweep.
    _rules=""
    type ebtables >/dev/null 2>&1 && _rules=$(ebtables -t filter -L 2>/dev/null)
    restore_merv_qt_shield "$_rules"
    type restore_merv_mac_shield >/dev/null 2>&1 && restore_merv_mac_shield "$_rules"

    # If either queue or process is busy, reset quiet counter
    if rc_queue_has 'restart_wireless|start_lan|stop_lan|switch|httpd' >/dev/null 2>&1 || \
       rc_proc_busy  'restart_wireless|wlconf|start_lan|switch|httpd' >/dev/null 2>&1; then
      quiet=0
    else
      quiet=$((quiet + 1))
      if [ "$quiet" -ge "$quiet_ticks" ]; then
        info -c vlan "wait_for_rc_quiet: rc quiet threshold satisfied; proceeding"
        return 0
      fi
    fi

    current_tick=$((current_tick + 1))
    if [ "$current_tick" -ge "$max_ticks" ]; then
      warn -c vlan "wait_for_rc_quiet: timeout reached; continuing"
      return 0
    fi

    # Unquoted: intentional POSIX word-split for two-token command
    $TICK_CMD
  done
}


# ============================================================================ #
# expected_vlans_from_settings                                                 #
# Parse settings.json for all configured VLAN IDs, extracting numeric values   #
# (2–4094 range) from Pool, Ethernet_ports, and Trunks sections.               #
# Returns deduplicated sorted list of all expected VLANs.                      #
# ============================================================================ #
expected_vlans_from_settings() {
  # Pull VLAN IDs from:
  #  - VLAN.Pool (VLAN_01..NN) - SSID VLANs
  #  - VLAN.Ethernet_ports (ETHx_VLAN) - Access port VLANs  
  #  - VLAN.Trunks (TAGGED/UNTAGGED_TRUNKx) - Trunk VLANs
  # using section-aware JSON helpers for nested structure.
  local vids tmp i idx vlan

  # SSID VLAN pool from VLAN.Pool section (filtered by node assignment)
  i=1
  while [ $i -le "${MAX_SSIDS:-12}" ]; do
    # Use filtered accessor to respect node assignment
    vlan=$(get_vlan_slot_value "$i" "$SETTINGS_FILE")
    # Check for fatal filter condition after first accessor call
    if [ "$i" -eq 1 ] && [ "${SSID_FILTER_FATAL:-0}" = "1" ]; then
      error -c vlan "expected_vlans_from_settings: aborting due to SSID filter fatal condition"
      printf ''
      return 1
    fi
    vlan=$(trim_spaces "$vlan")
    if is_number "$vlan" && [ "$vlan" -ge 2 ] && [ "$vlan" -le 4094 ]; then
      vids="$vids
$vlan"
    fi
    i=$((i+1))
  done

  # Access-port VLANs from VLAN.Ethernet_ports section
  idx=1
  for eth in $ETH_PORTS; do
    # Use json_get_section2_value for VLAN->Ethernet_ports->ETHx_VLAN nested structure
    vlan=$(json_get_section2_value "VLAN" "Ethernet_ports" "ETH${idx}_VLAN" "$SETTINGS_FILE" 2>/dev/null)
    # Fallback to old flat structure for backwards compatibility
    if [ -z "$vlan" ] || [ "$vlan" = "none" ]; then
      vlan=$(json_get_flag "ETH${idx}_VLAN" "" "$SETTINGS_FILE")
    fi
    vlan=$(trim_spaces "$vlan")
    if is_number "$vlan" && [ "$vlan" -ge 2 ] && [ "$vlan" -le 4094 ]; then
      vids="$vids
$vlan"
    fi
    idx=$((idx+1))
  done

  # Trunk VLANs from VLAN.Trunks section (both tagged and untagged)
  idx=1
  while [ $idx -le 8 ]; do
    # First check if trunk is enabled (TRUNKx must be 1 or positive integer)
    trunk_enabled=$(json_get_section2_value "VLAN" "Trunks" "TRUNK${idx}" "$SETTINGS_FILE" 2>/dev/null)
    if [ -z "$trunk_enabled" ]; then
      trunk_enabled=$(json_get_flag "TRUNK${idx}" "0" "$SETTINGS_FILE" 2>/dev/null)
    fi
    
    # Skip this trunk if disabled (0) or missing
    case "$trunk_enabled" in
      0|none|"") 
        idx=$((idx+1))
        continue
        ;;
    esac
    
    # Trunk is enabled - read TAGGED_TRUNKx (can be comma-separated like "187,188,189")
    tagged=$(json_get_section2_value "VLAN" "Trunks" "TAGGED_TRUNK${idx}" "$SETTINGS_FILE" 2>/dev/null)
    if [ -z "$tagged" ] || [ "$tagged" = "none" ]; then
      tagged=$(json_get_flag "TAGGED_TRUNK${idx}" "" "$SETTINGS_FILE")
    fi
    tagged=$(trim_spaces "$tagged")
    
    # Parse comma-separated VLAN IDs from tagged trunk
    if [ -n "$tagged" ] && [ "$tagged" != "none" ]; then
      # Save IFS and split by comma
      oldifs="$IFS"
      IFS=','
      for vid in $tagged; do
        IFS="$oldifs"
        vid=$(trim_spaces "$vid")
        if is_number "$vid" && [ "$vid" -ge 2 ] && [ "$vid" -le 4094 ]; then
          vids="$vids
$vid"
        fi
      done
      IFS="$oldifs"
    fi
    
    # Read UNTAGGED_TRUNKx (single VLAN ID)
    untagged=$(json_get_section2_value "VLAN" "Trunks" "UNTAGGED_TRUNK${idx}" "$SETTINGS_FILE" 2>/dev/null)
    if [ -z "$untagged" ] || [ "$untagged" = "none" ]; then
      untagged=$(json_get_flag "UNTAGGED_TRUNK${idx}" "" "$SETTINGS_FILE")
    fi
    untagged=$(trim_spaces "$untagged")
    
    if is_number "$untagged" && [ "$untagged" -ge 2 ] && [ "$untagged" -le 4094 ]; then
      vids="$vids
$untagged"
    fi
    
    idx=$((idx+1))
  done

  printf '%s
' "$vids" \
    | sed '/^[[:space:]]*$/d' \
    | sort -n \
    | uniq
}

# ============================================================================ #
# check_vlan_config                                                            #
# Compare expected VLANs (from settings.json) with actual VLANs (from kernel). #
# On mismatch, logs details and returns 1. On match, returns 0. Requires       #
# mismatch to persist across 2 checks with delay to avoid false positives      #
# during transient rc states.                                                  #
# ============================================================================ #
check_vlan_config() {
  local exp cur exp_str cur_str missing extra mismatch_count

  exp=$(expected_vlans_from_settings)
  if [ -z "$exp" ]; then
    info -c vlan "VLAN check OK: no VLANs configured in settings"
    return 0
  fi
  exp_str=$(printf '%s\n' "$exp" | xargs 2>/dev/null)

  # Multi-check validation with full monitoring window
  # - Always performs all max_checks to ensure VLANs remain stable
  # - Heals if heal_threshold consecutive mismatches detected
  # - Only returns OK if all checks pass without hitting threshold
  # This ensures we don't miss issues that appear mid-window
  local mismatch_count=0
  local check=1
  local max_checks=10         # Always run this many checks (27s total window)
  local heal_threshold=3      # Trigger heal after this many consecutive mismatches (6s)
  local settle_delay=3        # Seconds between checks
  local pass_count=0          # Track successful checks

  while [ "$check" -le "$max_checks" ]; do
    cur=$(actual_vlans_from_kernel)
    cur_str=$(printf '%s\n' "$cur" | xargs 2>/dev/null)

    if [ "$(printf '%s\n' "$exp")" = "$(printf '%s\n' "$cur")" ]; then
      # VLANs match on this check
      info -c vlan "VLAN check pass ${check}/${max_checks} OK: expected=${exp_str:-none} actual=${cur_str:-none}"
      mismatch_count=0  # Reset consecutive mismatch counter
      pass_count=$((pass_count + 1))
    else
      # Mismatch detected
      mismatch_count=$((mismatch_count + 1))

      missing=""
      for vid in $exp; do
        printf '%s\n' "$cur" | grep -Fx "$vid" >/dev/null 2>&1 || missing="$missing $vid"
      done
      missing=${missing# }

      extra=""
      for vid in $cur; do
        printf '%s\n' "$exp" | grep -Fx "$vid" >/dev/null 2>&1 || extra="$extra $vid"
      done
      extra=${extra# }

      if [ "$mismatch_count" -ge "$heal_threshold" ]; then
        # Hit heal threshold — trigger healing immediately
        warn -c vlan "VLAN mismatch confirmed (${mismatch_count}/${heal_threshold} consecutive): expected{${exp_str:-none}} actual{${cur_str:-none}} missing{${missing:-none}} extra{${extra:-none}}"
        return 1
      fi

      # Mismatch but not yet at threshold
      info -c vlan "VLAN mismatch on pass ${check}/${max_checks} (consecutive: ${mismatch_count}/${heal_threshold}): missing{${missing:-none}} extra{${extra:-none}}"
    fi

    # Continue to next check (unless this was the last one)
    if [ "$check" -lt "$max_checks" ]; then
      # Active settle: restore L2 shields on every tick so rc cannot flush
      # and leak traffic during the inter-check pause. Mirrors the dump+restore
      # pattern in wait_for_rc_quiet to avoid redundant netlink reads per tick.
      local s=0
      local tick_target=$(( settle_delay * TICKS_PER_SEC ))
      while [ "$s" -lt "$tick_target" ]; do
        _rules=""
        type ebtables >/dev/null 2>&1 && _rules=$(ebtables -t filter -L 2>/dev/null)
        restore_merv_qt_shield "$_rules"
        type restore_merv_mac_shield >/dev/null 2>&1 && restore_merv_mac_shield "$_rules"
        $TICK_CMD
        s=$((s + 1))
      done
    fi
    check=$((check + 1))
  done

  # Completed all checks without hitting heal threshold
  info -c vlan "VLAN monitoring complete: ${pass_count}/${max_checks} checks passed, ${mismatch_count} consecutive mismatches (below ${heal_threshold} threshold)"

  # Secondary leak detector: first try per-interface placement check (settings-derived,
  # catches partial leaks where only some managed SSIDs moved to br0 while a native
  # guest SSID keeps wl_leaked_to_br0's condition 2 false). Fall back to wl_leaked_to_br0
  # for environments where the settings-derived resolver is unavailable.
  if type merv_mac_build_expected_iface_vid >/dev/null 2>&1; then
    if ! check_wl_iface_placements; then
      warn -c vlan "VLAN bridges present (trunk alive) but wl subinterfaces misplaced — restart_wireless race suspected"
      return 1
    fi
  else
    if wl_leaked_to_br0; then
      warn -c vlan "VLAN bridges present (trunk alive) but wl subinterfaces detected in br0 — restart_wireless race condition suspected"
      return 1
    fi
  fi

  return 0
}

check_vlan_config_fast() {
  local exp cur exp_str cur_str missing extra

  exp=$(expected_vlans_from_settings)
  if [ -z "$exp" ]; then
    return 0
  fi
  exp_str=$(printf '%s\n' "$exp" | xargs 2>/dev/null)

  cur=$(actual_vlans_from_kernel)
  cur_str=$(printf '%s\n' "$cur" | xargs 2>/dev/null)

  if [ "$(printf '%s\n' "$exp")" = "$(printf '%s\n' "$cur")" ]; then
    return 0
  fi

  missing=""
  for vid in $exp; do
    printf '%s\n' "$cur" | grep -Fx "$vid" >/dev/null 2>&1 || missing="$missing $vid"
  done
  missing=${missing# }

  extra=""
  for vid in $cur; do
    printf '%s\n' "$exp" | grep -Fx "$vid" >/dev/null 2>&1 || extra="$extra $vid"
  done
  extra=${extra# }

  warn -c vlan "Fast VLAN mismatch: expected{${exp_str:-none}} actual{${cur_str:-none}} missing{${missing:-none}} extra{${extra:-none}}"
  return 1
}

# Manual test mode: allow admins to invoke a one-off validation
if [ "$1" = "--test" ] || [ "$1" = "test" ]; then
  info -c vlan "Manual VLAN check triggered via --test"
  if ! check_vlan_config; then
    if heal_allowed; then
      info -c cli,vlan "Manual check detected mismatch — invoking vlan_manager (cooldown ${COOLDOWN_SEC}s)"
      mark_heal
      evict_wl_from_br0
      "$VLAN_MANAGER" >/dev/null 2>&1 &
    else
      info -c cli,vlan "Manual check mismatch but heal suppressed (within ${COOLDOWN_SEC}s cooldown)"
    fi
  fi
  exit 0
fi

# Cron escalation test mode: simulate VLAN mismatch to test full escalation flow
if [ "$1" = "cron-test" ] || [ "$1" = "crontest" ]; then
  info -c cli,vlan "=== CRON ESCALATION TEST MODE ==="
  info -c cli,vlan "This will inject a fake VLAN (9999) to trigger the full escalation cycle"
  
  # Override expected_vlans_from_settings to inject fake VLAN
  expected_vlans_from_settings() {
    # Get real VLANs first
    local real_vlans
    real_vlans=$(expected_vlans_from_settings_real)
    
    # Add fake VLAN 9999 to force mismatch
    printf '%s\n9999\n' "$real_vlans" | sed '/^[[:space:]]*$/d' | sort -n | uniq
  }
  
  # Save original function
  expected_vlans_from_settings_real() {
    local vids tmp i idx vlan

    i=1
    while :; do
      tmp=$(printf 'VLAN_%02d' "$i")
      vlan=$(json_get_section2_value "VLAN" "Pool" "$tmp" "$SETTINGS_FILE" 2>/dev/null)
      if [ -z "$vlan" ] || [ "$vlan" = "none" ]; then
        vlan=$(json_get_flag "$tmp" "" "$SETTINGS_FILE")
      fi
      [ -z "$vlan" ] && break
      vlan=$(trim_spaces "$vlan")
      if is_number "$vlan" && [ "$vlan" -ge 2 ] && [ "$vlan" -le 4094 ]; then
        vids="$vids
$vlan"
      fi
      i=$((i+1))
    done

    idx=1
    for eth in $ETH_PORTS; do
      vlan=$(json_get_section2_value "VLAN" "Ethernet_ports" "ETH${idx}_VLAN" "$SETTINGS_FILE" 2>/dev/null)
      if [ -z "$vlan" ] || [ "$vlan" = "none" ]; then
        vlan=$(json_get_flag "ETH${idx}_VLAN" "" "$SETTINGS_FILE")
      fi
      vlan=$(trim_spaces "$vlan")
      if is_number "$vlan" && [ "$vlan" -ge 2 ] && [ "$vlan" -le 4094 ]; then
        vids="$vids
$vlan"
      fi
      idx=$((idx+1))
    done

    idx=1
    while [ $idx -le 8 ]; do
      # First check if trunk is enabled (TRUNKx must be 1 or positive integer)
      trunk_enabled=$(json_get_section2_value "VLAN" "Trunks" "TRUNK${idx}" "$SETTINGS_FILE" 2>/dev/null)
      if [ -z "$trunk_enabled" ]; then
        trunk_enabled=$(json_get_flag "TRUNK${idx}" "0" "$SETTINGS_FILE" 2>/dev/null)
      fi
      
      # Skip this trunk if disabled (0) or missing
      case "$trunk_enabled" in
        0|none|"") 
          idx=$((idx+1))
          continue
          ;;
      esac
      
      # Trunk is enabled - read TAGGED_TRUNKx
      tagged=$(json_get_section2_value "VLAN" "Trunks" "TAGGED_TRUNK${idx}" "$SETTINGS_FILE" 2>/dev/null)
      if [ -z "$tagged" ] || [ "$tagged" = "none" ]; then
        tagged=$(json_get_flag "TAGGED_TRUNK${idx}" "" "$SETTINGS_FILE")
      fi
      tagged=$(trim_spaces "$tagged")
      
      if [ -n "$tagged" ] && [ "$tagged" != "none" ]; then
        oldifs="$IFS"
        IFS=','
        for vid in $tagged; do
          IFS="$oldifs"
          vid=$(trim_spaces "$vid")
          if is_number "$vid" && [ "$vid" -ge 2 ] && [ "$vid" -le 4094 ]; then
            vids="$vids
$vid"
          fi
        done
        IFS="$oldifs"
      fi
      
      untagged=$(json_get_section2_value "VLAN" "Trunks" "UNTAGGED_TRUNK${idx}" "$SETTINGS_FILE" 2>/dev/null)
      if [ -z "$untagged" ] || [ "$untagged" = "none" ]; then
        untagged=$(json_get_flag "UNTAGGED_TRUNK${idx}" "" "$SETTINGS_FILE")
      fi
      untagged=$(trim_spaces "$untagged")
      
      if is_number "$untagged" && [ "$untagged" -ge 2 ] && [ "$untagged" -le 4094 ]; then
        vids="$vids
$untagged"
      fi
      
      idx=$((idx+1))
    done

    printf '%s
' "$vids" \
      | sed '/^[[:space:]]*$/d' \
      | sort -n \
      | uniq
  }
  
  # Simulate cron event
  info -c cli,vlan "--- Phase 1: Fast check (should detect fake VLAN 9999) ---"
  if ! check_vlan_config_fast; then
    record_mismatch
    info -c vlan "Cron test: Fast check detected mismatch — escalating to full validation..."
    
    info -c cli,vlan "--- Phase 2: Full validation (10 passes over 27s) ---"
    if ! check_vlan_config; then
      if heal_allowed; then
        info -c cli,vlan "Cron test: VLAN damage confirmed — would normally heal here (skipping actual heal in test mode)"
        info -c cli,vlan "In production, this would run: $VLAN_MANAGER"
      else
        info -c cli,vlan "Cron test: Damage confirmed but heal suppressed (within ${COOLDOWN_SEC}s cooldown)"
      fi
    else
      info -c vlan "Cron test: Escalation cleared — VLANs recovered (unexpected in test mode)"
    fi
  else
    info -c cli,vlan "Cron test: Fast check passed (unexpected — fake VLAN should have been detected)"
  fi
  
  info -c cli,vlan "=== CRON ESCALATION TEST COMPLETE ==="
  exit 0
fi

# Normalize incoming event payload into a single lower-case token
RAW_EVENT="$1"
if [ $# -gt 0 ]; then
  shift
  while [ $# -gt 0 ]; do
    RAW_EVENT="${RAW_EVENT}_$1"
    shift
  done
fi

if [ -z "$RAW_EVENT" ]; then
  info -c cli,vlan "Heal: invoked without event payload; nothing to do"
  exit 0
fi

EVENT=$(printf '%s' "$RAW_EVENT" | tr 'A-Z' 'a-z' | tr ' ' '_' | tr '-' '_')
EVENT=$(printf '%s' "$EVENT" | tr -s '_' '_' | sed 's/^_//; s/_$//')
EVENT_LABEL="$EVENT"

# Skip heal attempts while mervlan_manager is already applying changes
if [ -d "$MANAGER_LOCK" ]; then
  info -c vlan "Heal: skipping [$EVENT_LABEL] because mervlan_manager is active"
  exit 0
fi

# Skip heal if within self-restart window (prevents async event loops from mervlan_manager)
# The marker contains an expiry timestamp; if now < expiry, we're still in the window.
SELF_RESTART_MARKER="$LOCKDIR/self_restart.marker"
if [ -f "$SELF_RESTART_MARKER" ]; then
  expiry_ts=$(cat "$SELF_RESTART_MARKER" 2>/dev/null || echo 0)
  case "$expiry_ts" in ''|*[!0-9]*) expiry_ts=0 ;; esac
  now=$(date +%s)
  if [ "$now" -lt "$expiry_ts" ]; then
    info -c vlan "Heal: skipping [$EVENT_LABEL] — within self-restart window"
    exit 0
  fi
fi

# Event debounce: suppress same event if triggered again within 2 seconds
EVENT_DEBOUNCE="$LOCKDIR/vlan_event.last"
event_now=$(date +%s)
last_event_raw=$(cat "$EVENT_DEBOUNCE" 2>/dev/null || echo 0)
last_event=$(sanitize_epoch "$last_event_raw")
if [ "$last_event" -gt 0 ] && [ $((event_now - last_event)) -lt 2 ]; then
  info -c vlan "Event suppressed by debounce: [$EVENT_LABEL]"
  exit 0
fi
# Record current event timestamp for next debounce check
printf '%s\n' "$event_now" > "$EVENT_DEBOUNCE"


# --- Periodic CRU-driven check (EVENT=cron) ---------------------------------
if [ "$EVENT" = "cron" ]; then
  # Fix A: one-shot shield restore at cron entry.
  # Re-links MERV_QT/MERV_MAC FORWARD/INPUT jump rules if firmware's rc flushed
  # them during a restart_wireless that our event handler missed or fired late.
  # Single ebtables read shared by both restore calls — not a loop, not polling.
  if type ebtables >/dev/null 2>&1; then
    _cron_rules=$(ebtables -t filter -L 2>/dev/null)
    restore_merv_qt_shield "$_cron_rules"
    type restore_merv_mac_shield >/dev/null 2>&1 && restore_merv_mac_shield "$_cron_rules"
  fi

  # Phase 1: Fast sensor check
  if ! check_vlan_config_fast; then
    record_mismatch
    info -c vlan "Cron: Fast check detected mismatch — escalating to full validation..."

    # Phase 2: Escalated full validation (10 passes over 27s)
    # If it returns 1, damage is confirmed (3+ consecutive mismatches)
    if ! check_vlan_config; then
      if heal_allowed; then
        info -c cli,vlan "Cron: VLAN damage confirmed after escalation — healing (cooldown ${COOLDOWN_SEC}s)"
        mark_heal
        evict_wl_from_br0
        "$VLAN_MANAGER" >/dev/null 2>&1 &
      else
        info -c cli,vlan "Cron: Damage confirmed but heal suppressed (within ${COOLDOWN_SEC}s cooldown)"
      fi
    else
      info -c vlan "Cron: Escalation cleared — VLANs recovered or mismatch was transient"
    fi
  else
    log_health_ok_if_needed
    # Fix B: fast check passed (bridges alive via trunk) but wl subinterfaces may
    # still be in br0 due to a restart_wireless race. The trunk keeps VLAN bridges
    # alive so check_vlan_config_fast cannot detect this; check placement directly.
    # Single synchronous call — no loop, no polling overhead.
    if type merv_mac_build_expected_iface_vid >/dev/null 2>&1; then
      if ! check_wl_iface_placements; then
        warn -c vlan "Cron: wl placement mismatch despite healthy bridges — restart_wireless race"
        record_mismatch
        if heal_allowed; then
          info -c cli,vlan "Cron: wl subinterface(s) misplaced — healing (cooldown ${COOLDOWN_SEC}s)"
          mark_heal
          evict_wl_from_br0
          "$VLAN_MANAGER" >/dev/null 2>&1 &
        else
          info -c cli,vlan "Cron: wl placement mismatch but heal suppressed (within ${COOLDOWN_SEC}s cooldown)"
        fi
      fi
    fi
  fi

  # Periodic MAC snapshot — preconditions guard against snapshotting mid-heal;
  # on a stable network the db won't change so JFFS and ebtables are untouched.
  type merv_mac_snapshot >/dev/null 2>&1 && merv_mac_snapshot

  exit 0
fi


# ============================================================================ #
#                         SERVICE MONITORING (UNUSED)                          #
# ensure_process provides infrastructure for restarting background services    #
# (watchdog, actions) if they die. Currently commented out but available for   #
# future expansion.                                                            #
# ============================================================================ #

# ============================================================================ #
# ensure_process                                                               #
# Check if a background process (identified by pidfile) is still running.      #
# If not running, restart it. Used for watchdog and background action handlers.#
# ============================================================================ #
ensure_process() {
  # $1 label (for logging), $2 binary path, $3 pidfile location
  _label="$1"; _bin="$2"; _pidfile="$3"
  # Skip if binary doesn't exist or isn't executable
  [ -x "$_bin" ] || return 0

  # Check if pidfile exists and process is still alive
  if [ -f "$_pidfile" ] && pid=$(cat "$_pidfile" 2>/dev/null) && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    # Process is alive; nothing to do
    return 0
  fi

  # Process is dead or pidfile missing; restart it
  "$_bin" >/dev/null 2>&1 &
  newpid=$!
  # Save new PID to pidfile
  echo "$newpid" > "$_pidfile"
  info -c cli,vlan "Restarted $_label (pid $newpid)"
}

# Service monitoring currently disabled; uncomment if watchdog/actions restart needed
#check_services() {
#        ensure_process watchdog "$WATCHDOG" "$WATCHDOG_PIDFILE"
#        ensure_process actions "$ACTIONS" "$ACTIONS_PIDFILE"
#}

should_heal_event() {
  case "$1" in
    # Wi-Fi / LAN / NET
    restart_wireless*|wireless*|restart_wl*|wl_restart|wl_start|wl*_restart|wl*_start|wl*_down|wl*_up|\
    restart_lan*|lan_restart|lan_start|lan|lan_*|\
    restart_net*|net_restart|net_start|net|net_*)
      return 0
      ;;
    # WAN lifecycle
    wan_start*|wan_restart*|restart_wan*|wan_down*|wan_up*|wan_renew*|wan|wan_rebind*|\
    wan_stop*|wan_connect*|wan_disconnect*)
      return 0
      ;;
    # Firewall / NAT reconfigure
    firewall_start*|restart_firewall*|firewall_restart*|firewall|firewall_*|\
    nat_start*|restart_nat*|nat_restart*|nat|nat_*)
      return 0
      ;;
    # NOTE: httpd events intentionally excluded - httpd restarts do not affect
    # VLAN configuration, and healing on them creates an event loop since
    # mervlan_manager.sh calls restart_httpd after applying VLANs.
    # Generic reload orchestrators
    reload|reload_*|restart_all|services_restart|service_restart|restart_services|service_reload)
      return 0
      ;;
    # Deferred safety-net rechecks scheduled by Fix 3 (fires ~90s after a
    # wireless event to catch firmware that settles after the main heal window)
    deferred_*)
      return 0
      ;;
    # dnsmasq refresh
    dnsmasq|dnsmasq_*|restart_dnsmasq*|dnsmasq_restart*|dnsmasq_start*|dnsmasq_stop*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# ============================================================================ #
#                          MAIN EVENT HANDLER                                  #
# Dispatch on event type. For system events (restart, wireless, wan, httpd),   #
# check VLAN config and heal if needed and cooldown allows.                    #
# ============================================================================ #

# ============================================================================ #
# Event-based VLAN healing dispatch                                            #
# Respond to specific system events by checking VLAN config and triggering     #
# heal if config mismatch is detected and cooldown allows.                     #
# ============================================================================ #

if should_heal_event "$EVENT"; then
  info -c vlan "Heal: event [$EVENT_LABEL] matched watchlist"

  # For wireless restart events, wait for rc to settle BEFORE reading kernel
  # state. Firmware's restart_wireless can take several minutes on some
  # hardware; checking mid-restart produces a false-positive healthy result
  # (trunk subinterfaces keep VLAN bridges alive while wl interfaces are
  # still being torn down and rebuilt by the wireless driver). Use a generous
  # 120s max_wait to cover slow Broadcom DFS restarts.
  # Fix C: for all other matched events (dnsmasq from MAC-binding changes,
  # firewall, lan, wan, deferred, etc.) perform a one-shot shield restore
  # before the VLAN check — these events skip wait_for_rc_quiet so orphaned
  # chains would otherwise stay unrepaired for the full 27s check window.
  # Single ebtables read; no loop, no CPU concern.
  case "$EVENT" in
    restart_wireless*|wireless*|restart_wl*|wl_restart|wl_start|\
    wl*_restart|wl*_start|wl*_down|wl*_up)
      info -c vlan "Heal: wireless event — waiting for rc to settle before VLAN check (max 120s)"
      wait_for_rc_quiet 6 120
      ;;
    *)
      # If restart_wireless is concurrently running (e.g. MAC binding change
      # triggered both dnsmasq and wireless restarts and we caught the dnsmasq
      # event first), use the full restore loop so we keep re-linking chains as
      # firmware flushes them throughout the wireless restart sequence.
      # If rc is already quiet, a single read is sufficient — no polling overhead.
      if rc_queue_has 'restart_wireless' || rc_proc_busy 'restart_wireless|wlconf'; then
        info -c vlan "Heal: non-wireless event but wireless rc active — waiting for rc quiet (max 30s)"
        wait_for_rc_quiet 6 30
      elif type ebtables >/dev/null 2>&1; then
        _evt_rules=$(ebtables -t filter -L 2>/dev/null)
        restore_merv_qt_shield "$_evt_rules"
        type restore_merv_mac_shield >/dev/null 2>&1 && restore_merv_mac_shield "$_evt_rules"
      fi
      ;;
  esac

  if ! check_vlan_config; then
    record_mismatch
    # VLAN config mismatch detected after event
    if heal_allowed; then
      info -c cli,vlan "VLAN config missing after [$EVENT_LABEL] — waiting for rc quiet, then healing (cooldown ${COOLDOWN_SEC}s)"
      # Allow rc to finish wireless/LAN/httpd work so interfaces exist
      wait_for_rc_quiet
      # Mark heal time first (prevents rapid re-triggers)
      mark_heal
      # Close DHCP leak window before manager runs
      evict_wl_from_br0
      # Invoke VLAN manager in background to restore config
      "$VLAN_MANAGER" >/dev/null 2>&1 &
    else
      # Cooldown is active
      info -c cli,vlan "Heal suppressed after [$EVENT_LABEL] (within ${COOLDOWN_SEC}s cooldown)"
    fi
  fi

  # Fix 3 — Deferred safety-net recheck for wireless events.
  # Firmware rc can yield mid-restart, satisfying wait_for_rc_quiet, then
  # resume and dump wl interfaces back into br0 after the monitoring window
  # closes. Schedule a one-shot follow-up check ~90s later so MerVLAN always
  # gets the final word regardless of firmware behaviour.
  # The cooldown in heal_allowed prevents a double-apply if healing already
  # ran during the primary window.
  case "$EVENT" in
    restart_wireless*|wireless*|restart_wl*|wl_restart|wl_start|\
    wl*_restart|wl*_start|wl*_down|wl*_up)
      info -c vlan "Heal: scheduling deferred recheck in 90s for [$EVENT_LABEL]"
      (
        sleep 90
        # Skip if manager is already running (concurrent apply in progress)
        [ -d "$MANAGER_LOCK" ] && exit 0
        "$MERV_BASE/functions/heal_event.sh" "deferred_${EVENT}"
      ) >/dev/null 2>&1 &
      ;;
  esac
  # Service monitoring currently disabled (uncommitted check_services call)
  #check_services
fi

exit 0