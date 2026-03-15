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
#               - File: mervlan_manager.sh || version="0.58"                   #
# ============================================================================ #
# - Purpose:    JSON-driven VLAN manager for Asuswrt-Merlin firmware.          #
#               Applies VLAN settings to SSIDs and Ethernet ports based on     #
#               settings defined in JSON files.                                #
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
unset LIB_JSON_LOADED
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh"
[ -n "${LIB_SSID_FILTER_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssid_filter.sh"
[ -n "${LIB_STP_LOADED:-}" ] || . "$MERV_BASE/settings/lib_stp.sh"
# Optional CLI overrides:
#   boot                 → boot mode (enables SSID readiness gate)
#   dryrun|--dry-run|-n  → forces dry-run regardless of settings.json
#   --no-collect         → skip collect_clients.sh (for parallel execution)
MERV_MANAGER_MODE="normal"
CLI_DRY_RUN="no"
SKIP_COLLECT="no"
for arg in "$@"; do
  case "$arg" in
    boot)
      MERV_MANAGER_MODE="boot"
      ;;
    dryrun|--dry-run|-n)
      CLI_DRY_RUN="yes"
      ;;
    --no-collect)
      SKIP_COLLECT="yes"
      ;;
  esac
done

# Boot mode: ensure log directories and files exist before any logging
# This is critical because install.sh may not have run yet on first boot
if [ "$MERV_MANAGER_MODE" = "boot" ]; then
  _boot_logdir="${TMPDIR:-/tmp/mervlan_tmp}/logs"
  mkdir -p "$_boot_logdir" 2>/dev/null || :
  [ -f "$_boot_logdir/cli_output.log" ] || : > "$_boot_logdir/cli_output.log" 2>/dev/null || :
  [ -f "$_boot_logdir/vlan_manager.log" ] || : > "$_boot_logdir/vlan_manager.log" 2>/dev/null || :
  chmod 644 "$_boot_logdir/cli_output.log" "$_boot_logdir/vlan_manager.log" 2>/dev/null || :
  # Trim logs on boot to prevent unbounded growth (see LOG_MAX_LINES in log_settings.sh)
  log_trim_all
fi

# =========================================== End of MerVLAN environment setup #

# ============================================================================ #
# NODE DETECTION — Check if running on a node (satellite) vs main router      #
# ============================================================================ #
# Read IS_NODE and NODE_ID from settings.json (set by execute_nodes.sh)
MERV_IS_NODE="$(json_get_flag IS_NODE 0 "$SETTINGS_FILE")"
MERV_NODE_ID="$(json_get_flag NODE_ID "" "$SETTINGS_FILE")"

# Initialize SSID filter based on node identity (affects which SSIDs we manage)
ssid_filter_init "$MERV_NODE_ID"
info -c vlan "SSID filter: identity=${_SSID_FILTER_TOKEN} node_id=${MERV_NODE_ID:-none}"

# Completion marker directory and file (used by main router to verify node execution)
MERV_COMPLETION_DIR="/tmp/mervlan_tmp/results/node_complete"
MERV_COMPLETION_MARKER="$MERV_COMPLETION_DIR/node_${MERV_NODE_ID}.marker"

# ========================================================================== #
# JSON HELPERS — BusyBox-safe parsing for settings and hardware JSON files    #
# ========================================================================== #

# esc_key — Escape regex-special characters in JSON key names for sed
# Args: $1=key_name
# Returns: escaped key suitable for embedding in sed patterns
esc_key() {
  # Backwards-compatible wrapper: delegate to centralized json_escape_key
  json_escape_key "$@"
}

# read_json_raw — Extract scalar value from JSON file by key name (no NODE_ID remapping)
# Args: $1=key_name, $2=file_path
# Returns: stdout value (quoted string or bare number), or empty if not found
# Explanation: Uses sed with enhanced regex to handle escaped quotes. Prefers
#   quoted strings; falls back to bare values for numbers. Trims whitespace.
read_json_raw() {
  # Backwards-compatible wrapper: delegate to centralized json_get_scalar
  json_get_scalar "$1" "$2"
}

# read_json — Early alias for read_json_raw (pre-NODE_ID wrapper)
# Args: $1=key_name, $2=file_path
# Returns: stdout value from json_get_scalar
read_json() {
  read_json_raw "$@"
}

# read_json_number — Extract numeric value from JSON key (grep only digits)
# Args: $1=key_name, $2=file_path
# Returns: stdout numeric value, or empty if not found or non-numeric
read_json_number() {
  # Backwards-compatible wrapper: reuse json_get_int
  json_get_int "$1" "" "$2"
}

# read_json_section_value — Extract a string value from a nested JSON object
# Args: <section> <key> <file>
# Returns: matching string value or empty
read_json_section_value() {
  # Backwards-compatible wrapper: delegate to centralized json_get_section_value
  json_get_section_value "$1" "$2" "$3"
}

# read_json_section_number — Similar to read_json_section_value but returns numeric digits only
read_json_section_number() {
  # Backwards-compatible wrapper: delegate to centralized json_get_section_int
  json_get_section_int "$1" "$2" "$3"
}

# read_json_section_array — Extract a nested JSON array or fallback to a string
# Returns: space-separated list (quotes removed)
read_json_section_array() {
  # Backwards-compatible wrapper: delegate to centralized json_get_section_array
  json_get_section_array "$1" "$2" "$3"
}

# read_json_array — Extract JSON array and flatten to space-separated values
# Args: $1=key_name, $2=file_path
# Returns: stdout space-separated values (quotes and commas removed)
# Explanation: Extracts [a,b,c] bracket content, removes whitespace/quotes/commas
read_json_array() {
  # Backwards-compatible wrapper: delegate to centralized json_get_array
  json_get_array "$1" "$2"
}

detect_trunks_configured() {
  local idx val
  idx=1
  while [ $idx -le 8 ]; do
    val=$(read_json_number "TRUNK${idx}" "$SETTINGS_FILE")
    [ -z "$val" ] && val=$(read_json_number "trunk${idx}" "$SETTINGS_FILE")
    [ -z "$val" ] && val=$(json_get_section2_int "VLAN" "Trunks" "TRUNK${idx}" "$SETTINGS_FILE" 2>/dev/null)
    [ -z "$val" ] && val=$(json_get_section2_int "VLAN" "Trunks" "trunk${idx}" "$SETTINGS_FILE" 2>/dev/null)
    case "$val" in ''|0) ;; *) return 0 ;; esac
    idx=$((idx + 1))
  done
  return 1
}

run_trunk_if_configured() {
  TRUNK_APPLIED=0

  if ! detect_trunks_configured; then
    info -c cli,vlan "No trunk configuration enabled. Skipping."
    return 0
  fi

  info -c cli,vlan "Trunk config detected. Running trunk script..."

  if [ ! -x "$FUNCDIR/mervlan_trunk.sh" ]; then
    info -c cli,vlan "Node/remote AP: trunk script not present; skipping trunk config"
    return 0
  fi

  if DRY_RUN="$DRY_RUN" UPLINK_PORT="$UPLINK_PORT" DEFAULT_BRIDGE="$DEFAULT_BRIDGE" MAX_TRUNKS=8 \
      "$FUNCDIR/mervlan_trunk.sh"; then
    TRUNK_APPLIED=1
    return 0
  fi

  warn -c cli,vlan "Trunk script execution failed"
  return 1
}

# ========================================================================== #
# STRING NORMALIZATION HELPERS — ensure consistent SSID and interface matching #
# ========================================================================== #

normalize_basic() {
  val="$1"
  val=$(printf '%s' "$val" | tr -d '\r\357\273\277\342\200\213\342\200\214\342\200\215')
  printf '%s' "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

normalize_iface() {
  normalize_basic "$1"
}

normalize_ssid() {
  val=$(normalize_basic "$1")
  printf '%s' "$val" | sed \
    -e 's/—/-/g' -e 's/–/-/g' \
    -e "s/[‘’]/'/g" -e 's/[“”]/"/g'
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

BOUND_IFACES=""
WATCH_IFACES=""
TRUNK_APPLIED=0

# ========================================================================== #
# INITIALIZATION & HARDWARE DETECTION — Load configs and validate setup       #
# ========================================================================== #

# Verify required settings files exist; exit if missing
[ -f "$HW_SETTINGS_FILE" ] || error -c cli,vlan "Missing $HW_SETTINGS_FILE"
[ -f "$SETTINGS_FILE" ] || error -c cli,vlan "Missing $SETTINGS_FILE"

# Extract hardware profile from hardware settings. Supports both a standalone
# hw_settings.json (legacy) as well as the consolidated Hardware block inside
# settings.json. We try top-level reads first for backward compatibility, then
# probe the nested Hardware object when present.
MODEL=$(read_json MODEL "$HW_SETTINGS_FILE")
if [ -z "$MODEL" ]; then
  MODEL=$(read_json_section_value "Hardware" "MODEL" "$HW_SETTINGS_FILE")
fi

PRODUCTID=$(read_json PRODUCTID "$HW_SETTINGS_FILE")
if [ -z "$PRODUCTID" ]; then
  PRODUCTID=$(read_json_section_value "Hardware" "PRODUCTID" "$HW_SETTINGS_FILE")
fi

MAX_SSIDS=$(read_json_number MAX_SSIDS "$HW_SETTINGS_FILE")
if [ -z "$MAX_SSIDS" ]; then
  MAX_SSIDS=$(read_json_section_number "Hardware" "MAX_SSIDS" "$HW_SETTINGS_FILE")
fi

# ETH_PORTS is an array in the legacy format, but may be stored either as a
# JSON array or as a space-separated string inside the Hardware block. Try
# both extraction methods and normalize to space-separated values.
ETH_PORTS=$(read_json_array ETH_PORTS "$HW_SETTINGS_FILE")
if [ -z "$ETH_PORTS" ]; then
  ETH_PORTS=$(read_json_section_array "Hardware" "ETH_PORTS" "$HW_SETTINGS_FILE")
fi

WAN_IF=$(read_json WAN_IF "$HW_SETTINGS_FILE")
if [ -z "$WAN_IF" ]; then
  WAN_IF=$(read_json_section_value "Hardware" "WAN_IF" "$HW_SETTINGS_FILE")
fi

# Extract user configuration from settings.json
TOPOLOGY="switch"
PERSISTENT=$(read_json_raw PERSISTENT "$SETTINGS_FILE")
DRY_RUN=$(read_json_raw DRY_RUN "$SETTINGS_FILE")
ENABLE_STP=$(read_json_raw ENABLE_STP "$SETTINGS_FILE")

# Extract NODE_ID early (before node-aware read_json wrapper is defined)
NODE_ID=$(read_json_raw NODE_ID "$SETTINGS_FILE")
if [ -z "$NODE_ID" ]; then
  NODE_ID=$(read_json_section_value "General" "NODE_ID" "$SETTINGS_FILE")
fi
[ -z "$NODE_ID" ] && NODE_ID="none"

# Normalize invalid NODE_IDs to prevent unexpected behavior
case "$NODE_ID" in
  none|1|2|3|4|5) : ;;
  *) NODE_ID="none" ;;
esac

# Apply defaults for unconfigured values
[ -z "$MAX_SSIDS" ] && MAX_SSIDS=12
[ "$MAX_SSIDS" -gt 12 ] && MAX_SSIDS=12
[ -z "$PERSISTENT" ] && PERSISTENT="no"
[ -z "$DRY_RUN" ] && DRY_RUN="yes"
[ -z "$WAN_IF" ] && WAN_IF="eth0"
[ -z "$ENABLE_STP" ] && ENABLE_STP="0"

# CLI "dryrun" forces DRY_RUN=yes regardless of settings.json
if [ "$CLI_DRY_RUN" = "yes" ]; then
  DRY_RUN="yes"
  info -c cli,vlan "Dry-run forced by CLI argument; ignoring DRY_RUN setting"
fi

case "$ENABLE_STP" in
  1) ENABLE_STP=1 ;;
  *) ENABLE_STP=0 ;;
esac

# Temporarily force non-persistent mode until feature is fixed
if [ "$PERSISTENT" != "no" ]; then
  warn -c cli,vlan "Persistent mode is forced off pending fixes; running non-persistent"
fi
PERSISTENT="no"

# Resolve bridge and WAN interface
UPLINK_PORT="$WAN_IF"
DEFAULT_BRIDGE="br0"

# ========================================================================== #
# NODE-AWARE read_json WRAPPER — Intercept ETH VLAN reads for node overrides #
# ========================================================================== #

# read_json — Smart wrapper that redirects ETH*_VLAN reads based on NODE_ID
# Args: $1=key_name, $2=file_path
# Returns: stdout value from appropriate pool (node override or main)
# Explanation: When NODE_ID is 1-5, intercepts ETH1_VLAN..ETH8_VLAN reads
#   and redirects to NODE{n}_ETH{idx}_VLAN. No fallback to main pool.
#   All other keys pass through to read_json_raw unchanged.
read_json() {
  local key="$1"
  local file="$2"
  local idx okey val

  # Only redirect ETH port VLAN reads, only for settings.json, only on nodes
  case "$NODE_ID" in
    1|2|3|4|5)
      if [ "$file" = "$SETTINGS_FILE" ]; then
        case "$key" in
          ETH[1-8]_VLAN)
            idx="${key#ETH}"      # "1_VLAN"
            idx="${idx%_VLAN}"    # "1"
            okey="NODE${NODE_ID}_ETH${idx}_VLAN"

            val="$(read_json_raw "$okey" "$file")"
            [ -z "$val" ] && val="none"   # strict modular: no fallback to main
            printf '%s' "$val"
            return 0
            ;;
        esac
      fi
      ;;
  esac

  # Main unit (NODE_ID=none) or non-ETH keys: normal read
  read_json_raw "$key" "$file"
}

# ========================================================================== #
# STATE TRACKING & AUDIT — Change log, cleanup on exit, change tracking      #
# ========================================================================== #

# Fail fast if critical directories are unset to avoid writing to /
# In dry-run mode we intentionally avoid creating or touching state/log folders
if [ "$DRY_RUN" != "yes" ]; then
  [ -n "$CHANGES" ] || { error -c cli,vlan "CHANGES not set"; exit 1; }
  [ -n "$LOCKDIR" ] || { error -c cli,vlan "LOCKDIR not set"; exit 1; }

  # Ensure change-tracking and lock directories exist before use
  [ -d "$CHANGES" ] || mkdir -p "$CHANGES" 2>/dev/null || :
  [ -d "$LOCKDIR" ] || mkdir -p "$LOCKDIR" 2>/dev/null || :

  # Per-execution change log (cleaned up on exit via trap)
  CHANGE_LOG="$CHANGES/vlan_changes.$$"
  LOCK_PATH="$LOCKDIR/mervlan_manager.lock"
else
  # Dry-run: keep these unset or empty so helpers are no-op
  CHANGE_LOG=""
  LOCK_PATH=""
fi

LOCK_ACQUIRED=0

acquire_script_lock() {
  # Prevent concurrent runs from stomping on bridges/interfaces (mkdir-based lock)
  # Skip lock acquisition in dry-run mode
  [ "$DRY_RUN" = "yes" ] && return 0
  [ -n "$LOCK_PATH" ] || return 0
  attempts=0
  while ! mkdir "$LOCK_PATH" 2>/dev/null; do
    if [ $attempts -ge 30 ]; then
      error -c cli,vlan "Another mervlan_manager run appears active; aborting"
      exit 1
    fi
    warn -c cli,vlan "Another run in progress (lock $LOCK_PATH); waiting..."
    sleep 2
    attempts=$((attempts + 1))
  done
  LOCK_ACQUIRED=1
}

release_script_lock() {
  # No-op in dry-run
  [ "$DRY_RUN" = "yes" ] && return 0
  [ "$LOCK_ACQUIRED" -eq 1 ] || return
  rmdir "$LOCK_PATH" 2>/dev/null || :
  LOCK_ACQUIRED=0
}

cleanup_on_exit() {
    # Remove per-execution change log file
    [ -f "$CHANGE_LOG" ] && rm -f "$CHANGE_LOG"
    release_script_lock
}
trap cleanup_on_exit EXIT INT TERM

# track_change — Log configuration changes with timestamp for audit trail
# Args: $1=change_description (string)
# Returns: none (appends to $CHANGE_LOG)
track_change() {
  # Skip writing change-log in dry-run mode
  [ "$DRY_RUN" = "yes" ] && return 0
  [ -n "$CHANGE_LOG" ] || return 0
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
# Returns: 0 if interface exists, 1 if timeout after ~63 seconds
# Explanation: Exponential backoff prevents busy-waiting. Useful for VAPs that appear after wireless restart.
wait_for_interface() {
  local iface="$1" max_attempts=6 attempt=0
  # Poll up to 6 times with exponential sleep: 1s, 2s, 4s, 8s, 16s, 32s (~63s total)
  while [ $attempt -lt $max_attempts ]; do
    # Check if interface exists in /sys/class/net
    iface_exists "$iface" && return 0
    # Exponential backoff: 1<<attempt seconds (BusyBox-safe)
    sleep $((1 << attempt))
    attempt=$((attempt + 1))
  done
  # Timeout: interface never appeared
  warn -c cli,vlan "Interface $iface did not appear within ~63s (skipping)"
  return 1
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

# ssid_configured_for_iface — true if nvram has a non-empty SSID for this wl iface
# Args: $1=iface_name like wl0.1
# Returns: 0 if configured, 1 otherwise
ssid_configured_for_iface() {
  local ifn ssid
  ifn="$1"

  ssid="$(nvram get "${ifn}_ssid" 2>/dev/null)"
  ssid="$(printf '%s' "$ssid" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//')"

  [ -n "$ssid" ] || return 1
  case "$ssid" in
    ''|0|null|NULL) return 1 ;;
  esac

  return 0
}

# is_internal_vap — Detect VAPs that are not user SSIDs
# Rule: wlX.Y is internal only if nvram key wlX.Y_ssid is missing/empty.
# Never block wlX base radios or eth*.
is_internal_vap() {
  local ifn
  ifn="$1"

  [ -n "$ifn" ] || return 1

  case "$ifn" in
    eth*) return 1 ;;
    wl[0-9]) return 1 ;;
    wl[0-9].[0-9]*)
      ssid_configured_for_iface "$ifn" && return 1
      return 0
      ;;
  esac

  # Unknown interface types: treat as non-internal by default
  return 1
}

# is_wl_iface — Check if interface is a Broadcom wireless interface usable by wl
# Args: $1=interface_name
# Returns: 0 if wl -i IF status succeeds, 1 otherwise
is_wl_iface() {
  local ifn
  ifn="$1"
  [ -n "$ifn" ] || return 1
  iface_exists "$ifn" || return 1
  wl -i "$ifn" status >/dev/null 2>&1
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
  local iface br
  iface="$1"

  [ "$DRY_RUN" = "yes" ] && {
    info -c cli,vlan "[DRY-RUN] would detach $iface from all bridges"
    return 0
  }

  brctl show 2>/dev/null \
    | awk 'NR>1 && $1!="" {print $1}' \
    | sort -u \
    | while read -r br; do
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
  if [ "$VID" = "none" ] || [ "$VID" = "trunk" ]; then
    return 0
  fi

  # ---- Uplink VLAN sub-interface (needed by every path below) ----
  if ! iface_exists "${UPLINK_PORT}.${VID}"; then
    if [ "$DRY_RUN" = "yes" ]; then
      echo "[DRY-RUN] ip link add link $UPLINK_PORT name ${UPLINK_PORT}.${VID} type vlan id $VID"
      echo "[DRY-RUN] ip link set ${UPLINK_PORT}.${VID} up"
    else
      ip link add link "$UPLINK_PORT" name "${UPLINK_PORT}.${VID}" type vlan id "$VID" 2>/dev/null || \
      iface_exists "${UPLINK_PORT}.${VID}" || {
        error -c cli,vlan "Failed to create VLAN interface ${UPLINK_PORT}.${VID}"
        return 1
      }
      ip link set "${UPLINK_PORT}.${VID}" up 2>/dev/null
      info -c cli,vlan "Created VLAN interface ${UPLINK_PORT}.${VID}"
      track_change "Created VLAN interface ${UPLINK_PORT}.${VID}"
    fi
  fi

  # ---- Bridge (sysfs-first detection) ----
  if ! iface_exists "br${VID}"; then
    # --- New bridge ---
    if [ "$DRY_RUN" = "yes" ]; then
      echo "[DRY-RUN] brctl addbr br${VID}"
      stp_set_bridge_mac "$VID" "$DRY_RUN"
      echo "[DRY-RUN] brctl addif br${VID} ${UPLINK_PORT}.${VID}"
      echo "[DRY-RUN] ip link set br${VID} up"
      stp_apply_policy "$VID" "$DRY_RUN" "${ENABLE_STP:-0}"
    else
      # 1. Create bridge
      brctl addbr "br${VID}" 2>/dev/null || {
        error -c cli,vlan "Failed to create bridge br${VID}"
        return 1
      }
      # 2. Set deterministic MAC while bridge is still empty/down
      if ! stp_set_bridge_mac "$VID" "$DRY_RUN"; then
        if [ "${ENABLE_STP:-0}" -eq 1 ] 2>/dev/null; then
          error -c cli,vlan "ensure_vlan_bridge: FATAL — MAC set failed on new br${VID} with STP enabled; removing bridge"
          brctl delbr "br${VID}" 2>/dev/null
          return 1
        fi
        warn -c cli,vlan "ensure_vlan_bridge: MAC set failed on new br${VID} (STP off, continuing)"
      fi
      # 3. Add uplink VLAN interface
      brctl addif "br${VID}" "${UPLINK_PORT}.${VID}" 2>/dev/null || {
        error -c cli,vlan "Failed to attach uplink ${UPLINK_PORT}.${VID} to br${VID}"
        brctl delbr "br${VID}" 2>/dev/null
        return 1
      }
      # 4. Bring bridge up
      ip link set "br${VID}" up 2>/dev/null
      # 5. STP policy
      stp_apply_policy "$VID" "$DRY_RUN" "${ENABLE_STP:-0}"
      info -c cli,vlan "Created bridge br${VID}"
      track_change "Created bridge br${VID}"
    fi
  else
    # --- Existing bridge: enforce MAC + policy ---
    if [ "${ENABLE_STP:-0}" -eq 1 ] 2>/dev/null; then
      if ! stp_force_bridge_mac "$VID" "$DRY_RUN"; then
        error -c cli,vlan "ensure_vlan_bridge: FATAL — failed to enforce bridge MAC on br${VID} with STP enabled"
        return 1
      fi
    else
      stp_set_bridge_mac "$VID" "$DRY_RUN"
    fi
    # Ensure uplink VLAN iface is a member (force-mac may have detached it)
    if [ "$DRY_RUN" = "yes" ]; then
      echo "[DRY-RUN] ensure ${UPLINK_PORT}.${VID} is member of br${VID}"
    else
      if ! member_of_bridge "br${VID}" "${UPLINK_PORT}.${VID}"; then
        brctl addif "br${VID}" "${UPLINK_PORT}.${VID}" 2>/dev/null || {
          error -c cli,vlan "ensure_vlan_bridge: FATAL — could not attach uplink ${UPLINK_PORT}.${VID} to br${VID}"
          return 1
        }
        info -c cli,vlan "ensure_vlan_bridge: re-attached uplink ${UPLINK_PORT}.${VID} to br${VID}"
      fi
      # Best-effort: make sure bridge is up
      ip link set "br${VID}" up 2>/dev/null
      # Post-enforcement verification (STP only — log mismatch for diagnostics)
      if [ "${ENABLE_STP:-0}" -eq 1 ] 2>/dev/null; then
        stp_verify_bridge_mac "$VID" || {
          error -c cli,vlan "ensure_vlan_bridge: FATAL — bridge MAC verification failed on br${VID}"
          return 1
        }
      fi
    fi
    stp_apply_policy "$VID" "$DRY_RUN" "${ENABLE_STP:-0}"
  fi
}

member_of_bridge_brctl_fallback() {
  br="$1"
  iface="$2"
  [ -n "$br" ] && [ -n "$iface" ] || return 1
  brctl show 2>/dev/null | awk -v BR="$br" -v IF="$iface" '
    NR==1 { next }
    {
      if ($1 != "") cur=$1
      for (i=1; i<=NF; i++) {
        gsub(/\r/, "", $i)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
      }
      if (cur==BR) {
        for (i=1; i<=NF; i++) {
          if ($i == IF) { found=1; exit }
        }
      }
    }
    END { exit(found?0:1) }
  ' >/dev/null 2>&1
}

member_of_bridge_sysfs() {
  br="$1"
  iface="$2"
  [ -n "$br" ] && [ -n "$iface" ] || return 1
  [ -d "/sys/class/net/$br" ] || return 1
  [ -e "/sys/class/net/$br/brif/$iface" ]
}

member_of_bridge() {
  br="$1"
  iface="$2"
  member_of_bridge_sysfs "$br" "$iface" && return 0
  member_of_bridge_brctl_fallback "$br" "$iface"
}

verify_interface_binding() {
  iface="$1"
  vid="$2"
  case "$vid" in
    none|trunk) return 0 ;;
  esac
  member_of_bridge "br${vid}" "$iface"
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

  # Skip VAPs flagged as internal (those without a configured SSID)
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
      note_bound_iface "$IF"
      ;;
    trunk)
      # Trunk mode: leave unconfigured (passthrough, no bridge)
      info -c cli,vlan "$LABEL set as trunk (no bridge)"
      note_bound_iface "$IF"
      ;;
    *)
      # Attach to VLAN bridge (e.g., br100 for VLAN 100)
      ensure_vlan_bridge "$VID" || return 1
      if [ "$DRY_RUN" = "yes" ]; then
        echo "[DRY-RUN] brctl addif br${VID} $IF"
        note_bound_iface "$IF"
      else
        brctl addif "br${VID}" "$IF" 2>/dev/null || {
          error -c cli,vlan "Failed to attach $IF to br${VID}"
          return 1
        }
        info -c cli,vlan "$LABEL -> br${VID} (VLAN $VID)"
        track_change "Attached $IF to br${VID} (VLAN $VID)"
        if ! verify_interface_binding "$IF" "$VID"; then
          sleep 2
          brctl addif "br${VID}" "$IF" 2>/dev/null || true
          verify_interface_binding "$IF" "$VID" >/dev/null 2>&1 || :
        fi
        note_bound_iface "$IF"
        queue_watch "$IF,$VID"
      fi
      ;;
  esac
}

note_bound_iface() {
  local iface
  iface=$(normalize_iface "$1")
  [ -n "$iface" ] || return 0
  case " $BOUND_IFACES " in
    *" $iface "*) return 0 ;;
  esac
  BOUND_IFACES="$BOUND_IFACES $iface"
}

queue_watch() {
  raw="$1"
  iface_part=$(normalize_iface "${raw%,*}")
  vid_part="${raw#*,}"
  [ -n "$iface_part" ] || return 0
  kv="${iface_part},${vid_part}"
  in_list=0
  case " $WATCH_IFACES " in
    *" $kv "*) in_list=1 ;;
  esac
  [ $in_list -eq 0 ] && WATCH_IFACES="$WATCH_IFACES $kv"

  # Log on second pass even if already queued previously
  if [ "${WATCHDOG_QUEUE_LOG:-0}" = "1" ]; then
    info -c cli,vlan "staging ${iface_part} -> br${vid_part} for watchdog verification"
  fi
}

iface_bound() {
  local iface
  iface=$(normalize_iface "$1")
  [ -n "$iface" ] || return 1
  case " $BOUND_IFACES " in
    *" $iface "*) return 0 ;;
  esac
  return 1
}

# ========================================================================== #
# SSID RESOLUTION — Find wireless interfaces by SSID name                    #
# ========================================================================== #

# find_if_by_ssid — Locate interface on specific band by SSID name
# Args: $1=band (0|1|2), $2=ssid_name
# Returns: stdout interface_name (e.g., wl0, wl0.1), or empty if not found
# Explanation: Tries base radio first (main SSID), then guest slots 1-9
find_if_by_ssid() {
  BAND="$1"
  TARGET="$2"

  TARGET_NORM=$(normalize_ssid "$TARGET")
  [ -z "$TARGET_NORM" ] && return 1
  [ "$TARGET_NORM" = "unused-placeholder" ] && return 1
  TARGET_LOWER=$(to_lower "$TARGET_NORM")

  FALLBACK_IFACE=""
  FALLBACK_LABEL=""
  FALLBACK_COUNT=0

  SSID_BASE="$(nvram get wl${BAND}_ssid 2>/dev/null)"
  IF_BASE="$(nvram get wl${BAND}_ifname 2>/dev/null)"
  IF_BASE=$(normalize_iface "$IF_BASE")
  if [ -n "$IF_BASE" ] && iface_exists "$IF_BASE"; then
    BASE_NORM=$(normalize_ssid "$SSID_BASE")
    if [ "$BASE_NORM" = "$TARGET_NORM" ]; then
      echo "$IF_BASE"
      return 0
    fi
    if [ -n "$BASE_NORM" ] && [ "$(to_lower "$BASE_NORM")" = "$TARGET_LOWER" ]; then
      FALLBACK_IFACE="$IF_BASE"
      FALLBACK_LABEL="$BASE_NORM -> $IF_BASE"
      FALLBACK_COUNT=1
    fi
  fi

  for slot in 1 2 3 4 5 6 7 8 9; do
    SSID="$(nvram get wl${BAND}.${slot}_ssid 2>/dev/null)"
    IFN="$(nvram get wl${BAND}.${slot}_ifname 2>/dev/null)"
    IFN=$(normalize_iface "$IFN")
    [ -n "$IFN" ] || continue
    iface_exists "$IFN" || continue
    SSID_NORM=$(normalize_ssid "$SSID")
    if [ "$SSID_NORM" = "$TARGET_NORM" ]; then
      echo "$IFN"
      return 0
    fi
    if [ -n "$SSID_NORM" ] && [ "$(to_lower "$SSID_NORM")" = "$TARGET_LOWER" ]; then
      if [ "$FALLBACK_COUNT" -eq 0 ]; then
        FALLBACK_IFACE="$IFN"
        FALLBACK_LABEL="$SSID_NORM -> $IFN"
      else
        FALLBACK_LABEL="$FALLBACK_LABEL, $SSID_NORM -> $IFN"
      fi
      FALLBACK_COUNT=$((FALLBACK_COUNT + 1))
    fi
  done

  if [ "$FALLBACK_COUNT" -eq 1 ]; then
    warn -c cli,vlan "Case-insensitive match for '$TARGET_NORM' -> $FALLBACK_IFACE"
    echo "$FALLBACK_IFACE"
    return 0
  fi

  if [ "$FALLBACK_COUNT" -gt 1 ]; then
    warn -c cli,vlan "Ambiguous case-insensitive matches for '$TARGET_NORM': $FALLBACK_LABEL"
  fi

  return 1
}

# find_if_by_ssid_any — Robust SSID lookup across all bands/slots (fallback)
# Args: $1=ssid_name
# Returns: stdout interface_name, or empty if not found
# Explanation: Scans all NVRAM *_ssid entries, finds first matching interface
# Use case: Fallback when band/slot unknown, or user moves SSID between bands
find_if_by_ssid_any() {
  ssid="$1"
  TARGET_NORM=$(normalize_ssid "$ssid")
  [ -z "$TARGET_NORM" ] && return 1
  [ "$TARGET_NORM" = "unused-placeholder" ] && return 1
  TARGET_LOWER=$(to_lower "$TARGET_NORM")

  EXACT_MATCHES=""
  EXACT_COUNT=0
  FALLBACK_IFACE=""
  FALLBACK_LABELS=""
  FALLBACK_COUNT=0

  while IFS= read -r entry; do
    case "$entry" in
      wl*_ssid=*)
        key=${entry%%=*}      # e.g. wl0_ssid or wl2.1_ssid
        raw=${entry#*=}       # SSID string
        base=${key%_ssid}     # e.g. wl0 or wl2.1

        case "$base" in
          wl[0-9]*) : ;;
          *) continue ;;
        esac

        iface=$(nvram get "${base}_ifname" 2>/dev/null)
        iface=$(normalize_iface "$iface")
        [ -n "$iface" ] || continue
        is_internal_vap "$iface" && continue
        case "$iface" in
          eth*) is_wl_iface "$iface" || continue ;;
        esac

        ssid_norm=$(normalize_ssid "$raw")

        if [ "$ssid_norm" = "$TARGET_NORM" ]; then
          # Collect exact match (don't return early — there may be more bands)
          EXACT_MATCHES="${EXACT_MATCHES}${EXACT_MATCHES:+
}${iface}"
          EXACT_COUNT=$((EXACT_COUNT + 1))
        elif [ -n "$ssid_norm" ] && [ "$(to_lower "$ssid_norm")" = "$TARGET_LOWER" ]; then
          if [ "$FALLBACK_COUNT" -eq 0 ]; then
            FALLBACK_IFACE="$iface"
            FALLBACK_LABELS="$ssid_norm -> $iface"
          else
            FALLBACK_LABELS="$FALLBACK_LABELS, $ssid_norm -> $iface"
          fi
          FALLBACK_COUNT=$((FALLBACK_COUNT + 1))
        fi
        ;;
    esac
  done <<EOF
$(nvram show 2>/dev/null | grep -E '^wl[0-9](\.[0-9]+)?_ssid=')
EOF

  # Return all exact matches (one per line) if any were found
  if [ "$EXACT_COUNT" -ge 1 ]; then
    printf '%s\n' "$EXACT_MATCHES"
    return 0
  fi

  if [ "$FALLBACK_COUNT" -eq 1 ]; then
    warn -c cli,vlan "Case-insensitive match for '$TARGET_NORM' -> $FALLBACK_IFACE"
    echo "$FALLBACK_IFACE"
    return 0
  fi

  if [ "$FALLBACK_COUNT" -gt 1 ]; then
    warn -c cli,vlan "Ambiguous case-insensitive matches for '$TARGET_NORM': $FALLBACK_LABELS"
  fi

  return 1
}

# ========================================================================== #
# BOOT SSID READINESS GATE — Wait for configured SSIDs during boot mode      #
# ========================================================================== #

# ssid_in_nvram — Check if an SSID exists anywhere in nvram
# Args: $1=ssid_name
# Returns: 0 if found, 1 if not found
ssid_in_nvram() {
  _needle="$1"
  [ -n "$_needle" ] || return 1
  # Cache nvram output for efficiency (only fetch once)
  [ -n "${_NVRAM_SSID_CACHE:-}" ] || _NVRAM_SSID_CACHE="$(nvram show 2>/dev/null | grep '_ssid=')"
  printf '%s\n' "$_NVRAM_SSID_CACHE" | grep -Fq "_ssid=$_needle"
}

# boot_wait_for_configured_ssids — Block until configured SSIDs are ready (boot mode only)
# Args: $1=timeout_seconds (default 30)
# Returns: 0 always (logs warnings on timeout/missing SSIDs, continues anyway)
# Purpose: Reduce boot race conditions by waiting for WLAN interfaces to appear
boot_wait_for_configured_ssids() {
  [ "$MERV_MANAGER_MODE" = "boot" ] || return 0

  timeout="${1:-30}"
  case "$timeout" in ''|*[!0-9]*) timeout=30 ;; esac

  # Build list of configured SSIDs from settings.json (filtered by node assignment)
  cfg=""
  i=1
  while [ "$i" -le "${MAX_SSIDS:-12}" ]; do
    ssid="$(get_ssid_slot_value "$i" "$SETTINGS_FILE")"
    # Check for fatal filter condition (hardware profile not ready)
    if [ "${SSID_FILTER_FATAL:-0}" = "1" ]; then
      error -c cli,vlan "Boot SSID wait: aborting due to SSID filter fatal condition (MAX_SSIDS not set)"
      return 1
    fi
    [ -z "$ssid" ] && ssid="unused-placeholder"
    if [ "$ssid" != "unused-placeholder" ]; then
      cfg="${cfg}
$i|$ssid"
    fi
    i=$((i+1))
  done
  cfg="$(printf '%s\n' "$cfg" | sed '/^$/d')"

  [ -n "$cfg" ] || {
    info -c cli,vlan "Boot SSID wait: no SSIDs configured"
    return 0
  }

  info -c cli,vlan "Boot SSID wait: validating configured SSIDs vs nvram, then waiting up to ${timeout}s for interfaces..."

  # Partition SSIDs: in nvram (wait for interface) vs missing (likely typo)
  missing_nvram=""
  waitlist=""
  while IFS='|' read -r idx ssid; do
    [ -n "$idx" ] || continue
    if ssid_in_nvram "$ssid"; then
      waitlist="${waitlist}
$idx|$ssid"
    else
      missing_nvram="${missing_nvram}
SSID_$(printf '%02d' "$idx")='$ssid'"
    fi
  done <<EOF
$cfg
EOF

  if [ -n "$missing_nvram" ]; then
    warn -c cli,vlan "Boot SSID wait: SSID(s) not found in nvram (likely typo or not configured in Wireless GUI):"
    printf '%s\n' "$missing_nvram" | sed '/^$/d' | while IFS= read -r line; do
      warn -c cli,vlan "  $line"
    done
  fi

  waitlist="$(printf '%s\n' "$waitlist" | sed '/^$/d')"
  [ -n "$waitlist" ] || return 0

  start="$(date +%s 2>/dev/null || echo 0)"
  case "$start" in ''|*[!0-9]*) start=1 ;; esac

  # Wait until all SSIDs in waitlist resolve to present interfaces, or timeout
  pending="$waitlist"
  ready_count=0
  total_count="$(printf '%s\n' "$waitlist" | wc -l | tr -d ' ')"

  while :; do
    new_pending=""

    while IFS='|' read -r idx ssid; do
      [ -n "$idx" ] || continue

      ifn="$(find_if_by_ssid_any "$ssid")"
      if [ -n "$ifn" ] && iface_exists "$ifn"; then
        ready_count=$((ready_count + 1))
      else
        new_pending="${new_pending}
$idx|$ssid"
      fi
    done <<EOF
$pending
EOF

    pending="$(printf '%s\n' "$new_pending" | sed '/^$/d')"
    [ -z "$pending" ] && {
      info -c cli,vlan "Boot SSID wait: all $total_count configured SSID interfaces are present"
      return 0
    }

    now="$(date +%s 2>/dev/null || echo 0)"
    case "$now" in ''|*[!0-9]*) now=$((start + timeout + 1)) ;; esac

    if [ $((now - start)) -ge "$timeout" ]; then
      warn -c cli,vlan "Boot SSID wait: timed out after ${timeout}s ($ready_count/$total_count ready)"
      warn -c cli,vlan "Boot SSID wait: still missing interface(s) for:"
      printf '%s\n' "$pending" | while IFS='|' read -r idx ssid; do
        [ -n "$idx" ] || continue
        warn -c cli,vlan "  SSID_$(printf '%02d' "$idx")='$ssid'"
      done
      return 0
    fi

    sleep 1
  done
}

# ========================================================================== #
# AP ISOLATION & SSID BINDING — Wireless policy and bridge attachment        #
# ========================================================================== #

# set_ap_isolation — Enable/disable AP isolation (privacy between clients on same SSID)
# Args: $1=interface, $2=value (0=off, 1=on)
# Returns: none (logs errors on failure, continues)
# Explanation: Uses wl command for immediate effect; persists via NVRAM if requested
nvram_base_for_ifname() {
  local ifn line key val base
  ifn="$1"
  [ -n "$ifn" ] || return 1

  while IFS= read -r line; do
    key=${line%%=*}
    val=${line#*=}
    [ "$val" = "$ifn" ] || continue
    base=${key%_ifname}
    echo "$base"
    return 0
  done <<EOF
$(nvram show 2>/dev/null | grep -E '^wl[0-9](\.[0-9]+)?_ifname=')
EOF

  return 1
}

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
        if [ "$PERSISTENT" = "yes" ]; then
          base="$(nvram_base_for_ifname "$IFN")"
          if [ -n "$base" ]; then
            nvram set "${base}_ap_isolate=$VAL"
            nvram commit
          else
            warn -c cli,vlan "Persistent AP isolation: could not map ifname '$IFN' to nvram wl base; skipping nvram set"
          fi
        fi
        track_change "Set AP isolation=$VAL for $IFN"
      fi
      ;;
  esac
}

# bind_configured_ssids — Dynamically bind all configured SSIDs to VLAN bridges
# Args: none (reads SETTINGS_FILE)
# Returns: none (logs all actions)
# Explanation: SSID_01-SSID_MAX_SSIDS, each with corresponding VLAN_01-VLAN_MAX_SSIDS
# Initial pass is immediate; the post-restart second pass acts as the VAP safety net.
# Also restores unconfigured SSIDs to br0 (prevents orphaning on VLAN changes)
bind_configured_ssids() {
  # Build a quick summary of which SSID slots pass the filter
  _filter_allowed=""
  _filter_denied=""
  _fi=1
  while [ "$_fi" -le "$MAX_SSIDS" ]; do
    if is_ssid_slot_allowed "$_fi" "$SETTINGS_FILE"; then
      _fs=$(get_ssid_slot_value "$_fi" "$SETTINGS_FILE")
      [ "$_fs" != "unused-placeholder" ] && [ -n "$_fs" ] && \
        _filter_allowed="${_filter_allowed} $(printf '%02d' "$_fi"):${_fs}"
    else
      _filter_denied="${_filter_denied} $(printf '%02d' "$_fi")"
    fi
    _fi=$((_fi+1))
  done
  if [ -n "$_filter_allowed" ]; then
    info -c cli,vlan "SSID filter [${_SSID_FILTER_TOKEN}] active:${_filter_allowed}"
  else
    info -c cli,vlan "SSID filter [${_SSID_FILTER_TOKEN}]: no active SSIDs for this node"
  fi
  [ -z "$_filter_denied" ] || info -c vlan "SSID filter [${_SSID_FILTER_TOKEN}] denied slots:${_filter_denied}"

  i=1
  # Loop through all SSID slots (SSID_01, SSID_02, etc. up to MAX_SSIDS)
  while [ $i -le "$MAX_SSIDS" ]; do
    # Read SSID and VLAN settings via filter (respects node assignment)
    ssid=$(get_ssid_slot_value "$i" "$SETTINGS_FILE")
    vlan=$(get_vlan_slot_value "$i" "$SETTINGS_FILE")
    # Check for fatal filter condition after first accessor call
    if [ "$i" -eq 1 ] && [ "${SSID_FILTER_FATAL:-0}" = "1" ]; then
      error -c cli,vlan "bind_configured_ssids: aborting due to SSID filter fatal condition"
      return 1
    fi
    # Apply defaults: empty SSID = placeholder, empty VLAN = untagged (none)
    [ -z "$ssid" ] && ssid="unused-placeholder"
    [ -z "$vlan" ] && vlan="none"

    if [ "$ssid" != "unused-placeholder" ]; then
      validate_vlan_id "$vlan" || { i=$((i+1)); continue; }
      # Find ALL interfaces for this SSID (handles dual-band identical SSIDs)
      IFN="$(find_if_by_ssid_any "$ssid")"
      if [ -n "$IFN" ]; then
        while IFS= read -r _ifn; do
          [ -n "$_ifn" ] || continue
          info -c cli,vlan "Resolved SSID '$ssid' -> $_ifn"
          if ! wait_for_interface "$_ifn"; then
            warn -c cli,vlan "$_ifn did not appear within timeout"
            continue
          fi
          attach_to_bridge "$_ifn" "$vlan" "SSID_$(printf "%02d" $i)"
        done <<_SSID_EOF_
$IFN
_SSID_EOF_
      else
        warn -c cli,vlan "SSID_$(printf "%02d" $i) '$ssid' not found on any band"
      fi
    else
      info -c cli,vlan "SSID_$(printf "%02d" $i) skipped"
    fi
    i=$((i+1))
  done

  BOUND_SET=" $BOUND_IFACES "
  for iface in $(nvram show 2>/dev/null | grep -E '^wl[0-9](\.[0-9]+)?_ifname=' | awk -F= '{print $2}' | sort -u); do
        iface=$(normalize_iface "$iface")
        [ -n "$iface" ] || continue
        iface_exists "$iface" || continue
        is_internal_vap "$iface" && continue
        is_wl_iface "$iface" || continue

        case "$BOUND_SET" in
          *" $iface "*) continue ;;
        esac

        attach_to_bridge "$iface" "none" "Unconfigured IF $iface"
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
      IFN="$(find_if_by_ssid_any "$SSID")"
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

  while IFS= read -r _ifn; do
    [ -n "$_ifn" ] || continue
    attach_to_bridge "$_ifn" "$VLAN" "$LABEL ($SSID)"
  done <<_RAA_EOF_
$IFN
_RAA_EOF_
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

  if [ "$TRUNK_APPLIED" -eq 1 ]; then
    info -c cli,vlan "Trunk summary: trunk script applied successfully"
  elif detect_trunks_configured; then
    info -c cli,vlan "Trunk summary: trunk config detected but script was not applied"
  fi

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

# ebt_cleanup_all_trunk_rules — Remove all MerVLAN ebtables trunk chains/jumps
# Must run before any bridge/VLAN changes to prevent stale ebtables rules from
# blocking traffic after config changes. Safe to call even if ebtables is absent
# or no MerVLAN rules exist.
ebt_cleanup_all_trunk_rules() {
  # Skip if ebtables binary is not available
  type ebtables >/dev/null 2>&1 || return 0

  local port chain proto="802_1Q" idx=0

  if [ "$DRY_RUN" = "yes" ]; then
    info -c cli,vlan "[DRY-RUN] would clean up ebtables trunk rules for eth0-eth9"
    return 0
  fi

  info -c cli,vlan "Cleaning up stale ebtables trunk rules..."

  # Enumerate eth0-eth9 (covers all supported trunk ports)
  while [ $idx -le 9 ]; do
    port="eth${idx}"
    chain="MERV_TRUNK_${port}"

    # Delete ingress jump rules from FORWARD
    while ebtables -t filter -D FORWARD -p "$proto" -i "$port" -j "$chain" 2>/dev/null; do :; done
    # Delete egress jump rules from FORWARD
    while ebtables -t filter -D FORWARD -p "$proto" -o "$port" -j "$chain" 2>/dev/null; do :; done
    # Flush and delete the per-port chain (ignore errors if nonexistent)
    ebtables -t filter -F "$chain" 2>/dev/null
    ebtables -t filter -X "$chain" 2>/dev/null

    idx=$((idx + 1))
  done

  # Clean up plan file directory from previous runs
  rm -f /tmp/mervlan_tmp/ebtables/trunk.rules 2>/dev/null || :
}

# cleanup_existing_config — Remove VLAN infrastructure from previous runs
# Args: none
# Returns: none (logs all actions)
# Explanation: Removes all VLAN bridges (br1+) and VLAN interfaces (eth0.VID+)
# Preserves br0 (default LAN bridge)
cleanup_existing_config() {
  info -c cli,vlan "Cleaning up existing VLAN config..."

  # --- ebtables: remove all MerVLAN trunk filter rules FIRST ---
  # Must run before bridge/VLAN teardown to prevent stale rules that reference
  # chains on interfaces we are about to delete.
  ebt_cleanup_all_trunk_rules

  # Remove VLAN bridges (except br0 - the default LAN bridge)
  # Iterate through all bridges, remove those numbered br1+ (custom VLANs)
  for br in $(brctl show 2>/dev/null | awk 'NR>1 {print $1}' | grep -E '^br[1-9][0-9]*$'); do
    if [ "$DRY_RUN" = "yes" ]; then
      echo "[DRY-RUN] detach all ports from $br; ip link set $br down; brctl delbr $br"
    else
      # Detach any member interfaces so delbr succeeds
      # Reuse lib_stp's robust sysfs-first + brctl-fallback enumerator
      for port in $(stp_list_bridge_members "$br"); do
        brctl delif "$br" "$port" 2>/dev/null
      done
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

# --- rc/queue helpers --------------------------------------------------------

rc_queue_has() {
  # true if rc has a pending/active matching token in the queue file
  pattern="$1"
  [ -n "$pattern" ] || return 1
  [ -f /tmp/rc_service ] || return 1
  grep -E "$pattern" /tmp/rc_service 2>/dev/null | grep -qv '^$'
}

rc_proc_busy() {
  # best-effort: see if a service/rc job referencing our token is running
  # Tokens intentionally allow partial matches (e.g., "switch") so compound
  # subcommands like "switch restart" are still detected in process args.
  pattern="$1"
  [ -n "$pattern" ] || return 1
  ps w 2>/dev/null | grep -E "[s]ervice" | grep -E "$pattern" >/dev/null 2>&1
}

run_service_with_timeout() {
  # $1 = literal 'service' subcommand string (e.g., 'restart_wireless' or 'switch restart')
  # $2 = timeout seconds
  cmd_string="$1"
  tmax="${2:-60}"

  [ -n "$cmd_string" ] || return 1

  if [ "$DRY_RUN" = "yes" ]; then
    info -c cli,vlan "[DRY-RUN] service $cmd_string"
    return 0
  fi

  set -- $cmd_string
  /sbin/service "$@" 2>/dev/null &
  spid=$!

  elapsed=0
  while kill -0 "$spid" 2>/dev/null; do
    if [ "$elapsed" -ge "$tmax" ]; then
      warn -c cli,vlan "service $cmd_string exceeded ${tmax}s; continuing without waiting"
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  rc=0
  wait "$spid" 2>/dev/null || rc=$?
  return $rc
}

safe_service_restart() {
  # $1 = subcommand string, $2 = token(s) to detect in rc queue (ERE), $3 = timeout seconds
  subcmd="$1"
  tokens="${2:-$1}"
  timeout_sec="${3:-60}"

  [ -n "$subcmd" ] || return 1

  if rc_queue_has "$tokens" || rc_proc_busy "$tokens"; then
    warn -c cli,vlan "rc busy with ($tokens); skipping 'service $subcmd'"
    return 0
  fi

  run_service_with_timeout "$subcmd" "$timeout_sec"
}

wait_for_rc_quiet() {
  quiet=0
  need=6
  while :; do
    if rc_queue_has 'restart_wireless|start_lan|stop_lan|switch|httpd' || \
       rc_proc_busy  'restart_wireless|wlconf|start_lan|switch|httpd'; then
      quiet=0
      sleep 1
      continue
    fi
    quiet=$((quiet + 1))
    [ "$quiet" -ge "$need" ] && break
    sleep 1
  done
}

# restart_services — Restart WiFi, bridge, and web server after configuration
# Args: none
# Returns: none (logs all actions)
# Explanation: Restarts wireless to pick up new VAP configuration, then resets
# bridge and HTTP services. Handles optional eapd (EAP daemon) if present.
is_ap_mode() {
  [ "$(nvram get sw_mode 2>/dev/null)" = "3" ]
}

restart_services() {
  info -c cli,vlan "Restarting WiFi & bridge services..."
  # Skip if dry-run mode
  [ "$DRY_RUN" = "yes" ] && return

  # Create self-restart marker with expiry timestamp to prevent heal_event.sh from
  # triggering event loops when our service restarts fire service-event callbacks.
  # We write the expiry time (now + window) so heal_event.sh can check: now < expiry.
  SELF_RESTART_MARKER="$LOCKDIR/self_restart.marker"
  SELF_RESTART_WINDOW="${MERV_SELF_RESTART_WINDOW:-45}"
  now=$(date +%s)
  printf '%s\n' $((now + SELF_RESTART_WINDOW)) > "$SELF_RESTART_MARKER" 2>/dev/null || :

  if is_ap_mode; then
    # Prefer a lighter touch in AP mode to avoid rc race conditions
    safe_service_restart "switch restart" "switch" 30
    # REMOVED restart_httpd: causes GUI logouts. User must refresh browser after changes.
    info -c cli,vlan "VLAN changes applied. Refresh your browser to see UI updates."
  else
    safe_service_restart "restart_wireless" "restart_wireless|wireless" 90
    sleep 2
    safe_service_restart "switch restart" "switch" 30
    # REMOVED restart_httpd: causes GUI logouts. User must refresh browser after changes.
    info -c cli,vlan "VLAN changes applied. Refresh your browser to see UI updates."
  fi

  if type eapd >/dev/null 2>&1 && [ -x /usr/sbin/eapd ]; then
    killall eapd 2>/dev/null
    /usr/sbin/eapd 2>/dev/null
  fi

  # Optional per-VAP bounce could be added here when specific VAPs changed.
}

post_rc_watchdog() {
  if [ "$DRY_RUN" = "yes" ]; then
    info -c cli,vlan "watchdog: dry-run mode; skipping verification"
    return 0
  fi
  case "$WATCH_IFACES" in
    "" )
      info -c cli,vlan "watchdog: no interfaces queued; skipping"
      return 0
      ;;
  esac
  (
    sleep "${WATCHDOG_DELAY_SEC:-25}"
    info -c cli,vlan "watchdog: starting verification for: $WATCH_IFACES"
    for pair in $WATCH_IFACES; do
      iface="${pair%,*}"
      vid="${pair#*,}"
      [ -n "$iface" ] || continue
      [ "$vid" = "none" ] && continue
      [ "$vid" = "trunk" ] && continue
      if [ ! -d "/sys/class/net/$iface" ]; then
        info -c cli,vlan "watchdog: ${iface} no longer exists, skipping"
        continue
      fi
      if member_of_bridge "br${vid}" "$iface"; then
        info -c cli,vlan "watchdog: ${iface} already on br${vid}, no action"
      elif member_of_bridge "br0" "$iface"; then
        info -c cli,vlan "watchdog: ${iface} on br0, moving to br${vid}"
        brctl delif br0 "$iface" 2>/dev/null
        if ! ensure_vlan_bridge "$vid"; then
          warn -c cli,vlan "watchdog: ensure_vlan_bridge br${vid} failed; cannot move ${iface}"
          continue
        fi
        if brctl addif "br${vid}" "$iface" 2>/dev/null; then
          info -c cli,vlan "watchdog: moved ${iface} -> br${vid}"
        else
          warn -c cli,vlan "watchdog: failed to move ${iface} -> br${vid}"
        fi
      else
        info -c cli,vlan "watchdog: ${iface} not found on br0 or br${vid} (likely settled elsewhere), no action"
      fi
    done
    info -c cli,vlan "watchdog: verification complete"
  ) &
}

# ========================================================================== #
# MAIN EXECUTION — Orchestrate VLAN configuration application flow           #
# ========================================================================== #

# main — Entry point: validate, cleanup, configure, and verify
# Args: none (reads all global configuration)
# Returns: none (exit code via mervlan_manager.sh script)
main() {
  acquire_script_lock

  # Clean up stale self-restart markers (older than 60s past expiry)
  # These markers prevent heal_event.sh loops but should not persist forever
  _stale_marker="$LOCKDIR/self_restart.marker"
  if [ -f "$_stale_marker" ]; then
    _expiry=$(cat "$_stale_marker" 2>/dev/null || echo 0)
    case "$_expiry" in ''|*[!0-9]*) _expiry=0 ;; esac
    _now=$(date +%s)
    if [ $((_now - 60)) -gt "$_expiry" ]; then
      rm -f "$_stale_marker" 2>/dev/null || :
    fi
  fi

  # Pre-flight validation: verify required files and settings exist
  validate_configuration

  # Boot mode: wait for configured SSID interfaces to appear (reduces boot race conditions)
  # This only runs when invoked with "boot" argument from services-start
  boot_wait_for_configured_ssids 30
  
  # Log startup information
  info -c cli,vlan "Starting VLAN manager on $MODEL ($PRODUCTID)"
  info -c cli,vlan "WAN: $WAN_IF, Topology: $TOPOLOGY"
  info -c cli,vlan "Dry Run: $DRY_RUN, Persistent: $PERSISTENT"
  
  # Log NODE_ID mode
  case "$NODE_ID" in
    1|2|3|4|5)
      info -c cli,vlan "Node Mode: Using NODE${NODE_ID} Ethernet port overrides"
      ;;
    *)
      info -c cli,vlan "Node Mode: Using main Ethernet port configuration"
      ;;
  esac

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

  # Validate SSID VLAN assignments (VLAN_01-VLAN_MAX_SSIDS, filtered by node assignment)
  i=1
  while [ $i -le "$MAX_SSIDS" ]; do
    ssid=$(get_ssid_slot_value "$i" "$SETTINGS_FILE")
    vlan=$(get_vlan_slot_value "$i" "$SETTINGS_FILE")
    # Only validate if SSID is configured (not empty or placeholder)
    [ -n "$ssid" ] && [ "$ssid" != "unused-placeholder" ] && validate_vlan_id "$vlan"
    i=$((i+1))
  done

  # Cleanup phase: remove old VLAN infrastructure from previous runs
  cleanup_existing_config

  # Configuration phase 1: Attach Ethernet LAN ports to appropriate bridges
  if [ -n "$ETH_PORTS" ]; then
    idx=1
    for eth in $ETH_PORTS; do
      vlan=$(read_json "ETH${idx}_VLAN" "$SETTINGS_FILE")
      [ -z "$vlan" ] && vlan="none"
      # Attach Ethernet port to br0 (untagged) or brVID (tagged)
      attach_to_bridge "$eth" "$vlan" "LAN Port $idx"
      idx=$((idx+1))
    done
  fi

  # Configuration phase 2: Bind all configured SSIDs dynamically (1..MAX_SSIDS)
  # This includes restoring unconfigured SSIDs to br0
  WATCHDOG_QUEUE_LOG=0
  export WATCHDOG_QUEUE_LOG
  bind_configured_ssids

  # Configuration phase 3: Apply AP isolation policies across all SSIDs
  # Iterate through configured SSIDs and apply APISO settings (filtered by node assignment)
  i=1
  while [ $i -le "$MAX_SSIDS" ]; do
    ssid=$(get_ssid_slot_value "$i" "$SETTINGS_FILE")
    apiso=$(get_apiso_slot_value "$i" "$SETTINGS_FILE")
    # Apply AP isolation if SSID is configured and APISO value is set
    if [ -n "$ssid" ] && [ "$ssid" != "unused-placeholder" ] && [ -n "$apiso" ]; then
      _apiso_iflist=$(find_if_by_ssid_any "$ssid")
      if [ -n "$_apiso_iflist" ]; then
        printf '%s\n' "$_apiso_iflist" | while IFS= read -r _apiso_ifn; do
          [ -n "$_apiso_ifn" ] || continue
          set_ap_isolation "$_apiso_ifn" "$apiso"
        done
      fi
    fi
    i=$((i+1))
  done

  # Service restart phase: only if not in dry-run mode
  [ "$DRY_RUN" = "yes" ] || {
    # Restart WiFi services to pick up new VAP configuration
    restart_services

    info -c cli,vlan "Waiting for rc/wlconf to go quiet..."
    wait_for_rc_quiet
    sleep 2

    # Second pass for new VAPs that appear after wireless restart
  info -c cli,vlan "Second pass for new VAPs..."
  WATCHDOG_QUEUE_LOG=1
  export WATCHDOG_QUEUE_LOG
    bind_configured_ssids

    post_rc_watchdog
  }

  run_trunk_if_configured

  # Summary: display final configuration status
  show_configuration_summary

  info -c cli,vlan "VLAN manager run completed at $(date '+%H:%M:%S')"

  # On nodes: write completion marker for main router to verify
  if [ "$MERV_IS_NODE" = "1" ]; then
    mkdir -p "$MERV_COMPLETION_DIR" 2>/dev/null
    echo "$(date +%s) NODE$MERV_NODE_ID" > "$MERV_COMPLETION_MARKER"
    info -c cli,vlan "Node execution complete - marker written"
  fi

  if [ "$DRY_RUN" = "yes" ]; then
    info -c cli,vlan "Dry-run mode; skipping VLAN client list refresh (collect_clients.sh)"
  elif [ "$MERV_IS_NODE" = "1" ]; then
    info -c cli,vlan "Running on node; skipping client refresh (handled by main router)"
  elif [ "$SKIP_COLLECT" = "yes" ]; then
    info -c cli,vlan "Parallel mode; skipping client refresh (will be run after node verification)"
  elif [ -x "$FUNCDIR/collect_clients.sh" ]; then
    info -c cli,vlan "Waiting 5 seconds before refreshing VLAN client list..."
    sleep 5
    info -c cli,vlan "Refreshing VLAN client list via collect_clients.sh"
    if "$FUNCDIR/collect_clients.sh"; then
      info -c cli,vlan "✓ VLAN client list refresh completed"
    else
      rc=$?
      warn -c cli,vlan "✗ collect_clients.sh failed (rc=$rc)"
    fi
  else
    info -c cli,vlan "collect_clients.sh not available; skipping client refresh"
  fi
}

# Entry point: call main with command-line arguments
main "$@"