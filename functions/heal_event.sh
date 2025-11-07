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
#                  - File: heal_event.sh || version="0.46"                     #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Automated healing of VLAN configurations called by with        #
#               cooldown to avoid rapid retriggers. Called if invoked by       #
#               the service-event wrapper.                                     #
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

read_json() {
  key="$1"; file="$2"
  [ -n "$key" ] && [ -f "$file" ] || return 1
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p; s/.*\"$key\"[[:space:]]*:[[:space:]]*\([^,}\"]*\).*/\1/p" "$file" \
    | head -1 \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
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

  # Check Ethernet port VLANs
  local idx=1 vlan token
  for eth in $ETH_PORTS; do
    vlan=$(read_json "ETH${idx}_VLAN" "$SETTINGS_FILE")
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

  # Check SSID VLANs (only count if SSID is actually set)
  local i=1 ssid ssid_token
  while [ $i -le "$max_ssids" ]; do
    ssid=$(read_json "$(printf "SSID_%02d" $i)" "$SETTINGS_FILE")
    vlan=$(read_json "$(printf "VLAN_%02d" $i)" "$SETTINGS_FILE")
    ssid=$(trim_spaces "$ssid")
    vlan=$(trim_spaces "$vlan")
    ssid_token=$(to_lower "$ssid")
    # Only consider SSID if it has a valid name (not unused placeholder)
    if [ -n "$ssid_token" ] && [ "$ssid_token" != "unused-placeholder" ]; then
      # Check if VLAN is numeric and within valid range
      if is_number "$vlan" && [ "$vlan" -ge 2 ] && [ "$vlan" -le 4094 ]; then
        return 0
      fi
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

# Ensure locks directory exists for all lock/cooldown files
mkdir -p "$LOCKDIR" 2>/dev/null

# Simple lock using mkdir (atomic operation) to avoid concurrent runs
LOCK="$LOCKDIR/vlan_event.lock"
if mkdir "$LOCK" 2>/dev/null; then
  # Clean up lock on script exit
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM
else
  # Another instance is running; exit silently
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

# ============================================================================ #
# heal_allowed                                                                 #
# Check if sufficient time has elapsed (COOLDOWN_SEC) since last vlan_manager  #
# invocation. Returns 0 if heal is allowed, 1 if within cooldown window.       #
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

# Event debounce: suppress same event if triggered again within 2 seconds
EVENT_DEBOUNCE="$LOCKDIR/vlan_event.last"
event_now=$(date +%s)
last_event_raw=$(cat "$EVENT_DEBOUNCE" 2>/dev/null || echo 0)
last_event=$(sanitize_epoch "$last_event_raw")
if [ "$last_event" -gt 0 ] && [ $((event_now - last_event)) -lt 2 ]; then
  info -c vlan "Event suppressed by debounce: [$*]"
  exit 0
fi
# Record current event timestamp for next debounce check
printf '%s\n' "$event_now" > "$EVENT_DEBOUNCE"

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
actual_vlans_from_kernel() {
  # List all network interfaces; filter bridge devices excluding br0
  ls /sys/class/net 2>/dev/null \
    | grep -E '^br[0-9]+$' \
    | grep -v '^br0$' \
    | sed 's/^br//' \
    | sort -n
}

# ============================================================================ #
# expected_vlans_from_settings                                                 #
# Parse settings.json for VLAN_01..VLAN_16 and ETH*_VLAN keys, extracting      #
# numeric VLAN IDs (2–4094 range). Returns deduplicated sorted list.           #
# ============================================================================ #
expected_vlans_from_settings() {
  {
    # Extract all VLAN_NN entries from settings.json
    grep -Eo '"VLAN_[0-9][0-9]"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" 2>/dev/null
    # Extract all ETH*_VLAN entries from settings.json
    grep -Eo '"ETH[0-9]+_VLAN"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" 2>/dev/null
  } | sed -n 's/.*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -E '^[0-9]+$' \
    | awk '{n=$1+0; if (n>=2 && n<=4094) print n}' \
    | sort -n \
    | uniq
}

# ============================================================================ #
# check_vlan_config                                                            #
# Compare expected VLANs (from settings.json) with actual VLANs (from kernel). #
# On mismatch, logs details and returns 1. On match, returns 0. Attempts up    #
# to 2 checks with VLAN_SETTLE_DELAY between attempts to allow interfaces to   #
# stabilize.                                                                   #
# ============================================================================ #
check_vlan_config() {
  local exp cur exp_str cur_str missing extra attempt max_attempts

  # Query expected VLANs from settings file
  exp=$(expected_vlans_from_settings)
  if [ -z "$exp" ]; then
    info -c vlan "VLAN check OK: no VLANs configured in settings"
    return 0
  fi
  # Convert list to space-separated string for logging
  exp_str=$(printf '%s\n' "$exp" | xargs 2>/dev/null)

  # Retry loop: check once, wait for settle, check again
  max_attempts=2
  attempt=1
  while [ $attempt -le $max_attempts ]; do
    # Query actual VLANs from kernel
    cur=$(actual_vlans_from_kernel)
    cur_str=$(printf '%s\n' "$cur" | xargs 2>/dev/null)
    # Compare expected vs actual (line-by-line for accuracy)
    if [ "$(printf '%s\n' "$exp")" = "$(printf '%s\n' "$cur")" ]; then
      # Log success message; include settle message on retry
      if [ $attempt -gt 1 ]; then
        info -c vlan "VLANs restored after settle (${VLAN_SETTLE_DELAY}s): ${cur_str:-none}"
      else
        info -c vlan "VLAN check OK: expected=${exp_str:-none} actual=${cur_str:-none}"
      fi
      return 0
    fi
    # Break loop if this was the last attempt
    [ $attempt -lt $max_attempts ] || break
    # Wait for network interfaces to settle before retry
    sleep "$VLAN_SETTLE_DELAY"
    attempt=$((attempt + 1))
  done

  # Compute missing VLANs (in expected but not in actual)
  missing=""
  for vid in $exp; do
    printf '%s\n' "$cur" | grep -Fx "$vid" >/dev/null 2>&1 || missing="$missing $vid"
  done
  # Strip leading space from missing list
  missing=${missing# }

  # Compute extra VLANs (in actual but not in expected)
  extra=""
  for vid in $cur; do
    printf '%s\n' "$exp" | grep -Fx "$vid" >/dev/null 2>&1 || extra="$extra $vid"
  done
  # Strip leading space from extra list
  extra=${extra# }

  # Log full mismatch details for troubleshooting
  warn -c vlan "VLAN mismatch after settle: expected{${exp_str:-none}} actual{${cur_str:-none}} missing{${missing:-none}} extra{${extra:-none}}"
  return 1
}

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

# ============================================================================ #
#                          MAIN EVENT HANDLER                                  #
# Dispatch on event type. For system events (restart, wireless, wan, httpd),   #
# check VLAN config and heal if needed and cooldown allows.                    #
# ============================================================================ #

# Test mode: if called with --test, perform manual VLAN check
if [ "$1" = "--test" ] || [ "$1" = "test" ]; then
  info -c vlan "Manual VLAN check triggered via --test"
  if ! check_vlan_config; then
    # VLAN mismatch detected; check if heal is allowed by cooldown
    if heal_allowed; then
      info -c cli,vlan "Manual check detected mismatch — invoking vlan_manager (cooldown ${COOLDOWN_SEC}s)"
      # Mark heal time first to prevent rapid re-triggers
      mark_heal
      # Invoke VLAN manager in background
      "$VLAN_MANAGER" >/dev/null 2>&1 &
    else
      # Cooldown still active from previous heal
      info -c cli,vlan "Manual check mismatch but heal suppressed (within ${COOLDOWN_SEC}s cooldown)"
    fi
  fi
  exit 0
fi

EVENT="$*"

if [ -z "$EVENT" ]; then
  info -c cli,vlan "Heal: invoked without event payload; nothing to do"
  exit 0
fi

# ============================================================================ #
# Event-based VLAN healing dispatch                                            #
# Respond to specific system events by checking VLAN config and triggering     #
# heal if config mismatch is detected and cooldown allows.                     #
# ============================================================================ #

case "$EVENT" in
  # Trigger on restart, wireless, httpd, and WAN events (common VLAN disruptors)
  *restart*|*wireless*|*httpd*|*wan-start*|*wan-restart*)
    if ! check_vlan_config; then
      # VLAN config mismatch detected after event
      if heal_allowed; then
        info -c cli,vlan "VLAN config missing after [$EVENT] — healing (cooldown ${COOLDOWN_SEC}s)"
        # Mark heal time first (prevents rapid re-triggers)
        mark_heal
        # Invoke VLAN manager in background to restore config
        "$VLAN_MANAGER" >/dev/null 2>&1 &
      else
        # Cooldown is still active from previous heal attempt
        info -c cli,vlan "Heal suppressed (within ${COOLDOWN_SEC}s cooldown)"
      fi
    fi
    # Service monitoring currently disabled (uncommitted check_services call)
    #check_services
    ;;
esac

exit 0