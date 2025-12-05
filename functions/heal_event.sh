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
#                  - File: heal_event.sh || version="0.47"                     #
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
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_JSON_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_JSON_LOADED:-}" ]   || . "$MERV_BASE/settings/lib_json.sh"
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
    vlan=$(json_get_flag "ETH${idx}_VLAN" "" "$SETTINGS_FILE")
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

  # Check SSID VLANs from VLAN pool (VLAN_01..VLAN_NN)
  # We only care if any VLAN_NN is a valid VLAN ID.
  local i=1 vlan
  while [ $i -le "$max_ssids" ]; do
    vlan=$(json_get_flag "$(printf "VLAN_%02d" $i)" "" "$SETTINGS_FILE")
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
  info -c vlan "Heal: skipping [initial] because mervlan_manager is active"
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
      eth[0-9]*|vlan[0-9]*|bond[0-9]*) ;;  # uplink/backhaul style members
      wl*|ra*|ath*|psta*|apcli*|lan*|wan*) has_edge=1 ;;
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

wait_for_rc_quiet() {
  local need max_wait quiet start now

  need="${1:-6}"
  max_wait="${2:-45}"
  quiet=0
  start=$(date +%s)

  info -c vlan "wait_for_rc_quiet: watching rc (need=${need}s quiet, max=${max_wait}s)"

  while :; do
    # If either queue or process is busy, reset quiet counter
    if rc_queue_has 'restart_wireless|start_lan|stop_lan|switch|httpd' >/dev/null 2>&1 || \
       rc_proc_busy  'restart_wireless|wlconf|start_lan|switch|httpd' >/dev/null 2>&1; then
      quiet=0
    else
      quiet=$((quiet + 1))
      if [ "$quiet" -ge "$need" ]; then
        info -c vlan "wait_for_rc_quiet: rc quiet for ${quiet}s; proceeding"
        return 0
      fi
    fi

    now=$(date +%s)
    if [ $((now - start)) -ge "$max_wait" ]; then
      warn -c vlan "wait_for_rc_quiet: timeout after ${max_wait}s; continuing"
      return 0
    fi

    sleep 1
  done
}


# ============================================================================ #
# expected_vlans_from_settings                                                 #
# Parse settings.json for VLAN_01..VLAN_16 and ETH*_VLAN keys, extracting      #
# numeric VLAN IDs (2–4094 range). Returns deduplicated sorted list.           #
# ============================================================================ #
expected_vlans_from_settings() {
  # Pull VLAN IDs from VLAN.Pool (VLAN_01..NN) and VLAN.Ethernet_ports (ETHx_VLAN)
  # using section-aware JSON helpers.
  local vids tmp i idx vlan

  # SSID VLAN pool
  i=1
  while :; do
    tmp=$(printf 'VLAN_%02d' "$i")
    vlan=$(json_get_flag "$tmp" "" "$SETTINGS_FILE")
    [ -z "$vlan" ] && break
    vlan=$(trim_spaces "$vlan")
    if is_number "$vlan" && [ "$vlan" -ge 2 ] && [ "$vlan" -le 4094 ]; then
      vids="$vids
$vlan"
    fi
    i=$((i+1))
  done

  # Access‑port VLANs
  idx=1
  for eth in $ETH_PORTS; do
    vlan=$(json_get_flag "ETH${idx}_VLAN" "" "$SETTINGS_FILE")
    vlan=$(trim_spaces "$vlan")
    if is_number "$vlan" && [ "$vlan" -ge 2 ] && [ "$vlan" -le 4094 ]; then
      vids="$vids
$vlan"
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
# On mismatch, logs details and returns 1. On match, returns 0. Attempts up    #
# to 2 checks with VLAN_SETTLE_DELAY between attempts to allow interfaces to   #
# stabilize.                                                                   #
# ============================================================================ #
check_vlan_config() {
  local exp cur exp_str cur_str missing extra

  exp=$(expected_vlans_from_settings)
  if [ -z "$exp" ]; then
    info -c vlan "VLAN check OK: no VLANs configured in settings"
    return 0
  fi
  exp_str=$(printf '%s\n' "$exp" | xargs 2>/dev/null)

  local delays="1 1 2 2 4"
  local attempt=1
  local total_passes=5

  for delay in $delays; do
    cur=$(actual_vlans_from_kernel)
    cur_str=$(printf '%s\n' "$cur" | xargs 2>/dev/null)

    if [ "$(printf '%s\n' "$exp")" = "$(printf '%s\n' "$cur")" ]; then
      info -c vlan "VLAN check pass ${attempt}/${total_passes} OK: expected=${exp_str:-none} actual=${cur_str:-none}"

      if [ "$attempt" -eq "$total_passes" ]; then
        info -c vlan "VLAN check final OK after ${attempt} passes: ${cur_str:-none}"
        return 0
      fi

      sleep "$delay"
    else
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

      warn -c vlan "VLAN mismatch on pass ${attempt}/${total_passes}: expected{${exp_str:-none}} actual{${cur_str:-none}} missing{${missing:-none}} extra{${extra:-none}}"
      return 1
    fi

    attempt=$((attempt + 1))
  done

  info -c vlan "VLAN check completed fallback path; treating as OK (expected=${exp_str:-none})"
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
      "$VLAN_MANAGER" >/dev/null 2>&1 &
    else
      info -c cli,vlan "Manual check mismatch but heal suppressed (within ${COOLDOWN_SEC}s cooldown)"
    fi
  fi
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
  if ! check_vlan_config_fast; then
    record_mismatch

    if heal_allowed; then
      info -c cli,vlan "Cron: VLAN config mismatch detected — invoking vlan_manager (cooldown ${COOLDOWN_SEC}s)"
      mark_heal
      "$VLAN_MANAGER" >/dev/null 2>&1 &
    else
      info -c cli,vlan "Cron: VLAN mismatch detected but heal suppressed (within ${COOLDOWN_SEC}s cooldown)"
    fi
  else
    log_health_ok_if_needed
  fi

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
    # HTTPD / GUI reboot
    httpd|httpd_*|restart_httpd*|httpd_restart*)
      return 0
      ;;
    # Generic reload orchestrators
    reload|reload_*|restart_all|services_restart|service_restart|restart_services|service_reload)
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
  if ! check_vlan_config; then
    record_mismatch
    # VLAN config mismatch detected after event
    if heal_allowed; then
      info -c cli,vlan "VLAN config missing after [$EVENT_LABEL] — waiting for rc quiet, then healing (cooldown ${COOLDOWN_SEC}s)"
      # Allow rc to finish wireless/LAN/httpd work so interfaces exist
      wait_for_rc_quiet
      # Mark heal time first (prevents rapid re-triggers)
      mark_heal
      # Invoke VLAN manager in background to restore config
      "$VLAN_MANAGER" >/dev/null 2>&1 &
    else
      # Cooldown is still active from previous heal attempt
      info -c cli,vlan "Heal suppressed after [$EVENT_LABEL] (within ${COOLDOWN_SEC}s cooldown)"
    fi
  fi
  # Service monitoring currently disabled (uncommitted check_services call)
  #check_services
fi

exit 0