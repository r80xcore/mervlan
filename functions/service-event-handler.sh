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
#          - File: service-event-handler.sh || version="0.57"                  #
# ============================================================================ #
# - Purpose:    Event handler for http and service events                      #
# ============================================================================ #

# ========================================================================== #
# BASIC INITIALIZATION                                                       #
# ========================================================================== #

: "${MERV_BASE:=/jffs/addons/mervlan}"

# ========================================================================== #
# HANDLER TUNABLES (self-contained)                                          #
# ========================================================================== #
# All timing knobs for this handler live here so they can be found and tuned
# in one place. These are deliberately NOT sourced from settings/var_settings.sh:
# the handler runs in the DHCP-sensitive hot path and must stay dependency-free
# and lightweight. Each uses ${VAR:-default} so an env override still wins for
# testing.
#
#   LOCKDIR              — shared lock/stamp directory (matches var_settings.sh)
#   DEBOUNCE_SECONDS     — reject the same event re-firing within this window
#   STALE_LOCK_SECONDS   — reclaim a held .lock left behind by a crashed script.
#                          Must exceed the longest script this handler launches.
#   MERV_HEAL_EVENT_DEBOUNCE — handler-level debounce for heal storms (rc floods)
#   MERV_HEAL_DELAY      — fire-and-forget delay before launching heal_event.sh
#                          for non-wireless system events
LOCKDIR="${LOCKDIR:-/tmp/mervlan_tmp/locks}"
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-3}"
STALE_LOCK_SECONDS="${STALE_LOCK_SECONDS:-300}"
MERV_HEAL_EVENT_DEBOUNCE="${MERV_HEAL_EVENT_DEBOUNCE:-5}"
MERV_HEAL_DELAY="${MERV_HEAL_DELAY:-3}"

# ========================================================================== #
# PARAMETER EXTRACTION & VALIDATION — Parse event action from arguments      #
# ========================================================================== #

# Extract primary action name from arguments ($1 preferred, $2 fallback)
# Example: "save_vlanmgr" from first argument, or from second if first empty
RAW="$1"
SECOND="$2"

# Fallback logic: if RAW is empty but SECOND is provided, use SECOND as action
# Handles cases where first arg is empty/missing but second contains the event
if [ -z "${RAW}" ] && [ -n "${SECOND}" ]; then
  RAW="${SECOND}"
fi

# Exit early if no action was provided in any argument position
# Log the missing action for diagnostic purposes before exit
if [ -z "${RAW}" ]; then
  logger -t "VLANMgr" "handler: no action provided (args: '$1' '$2' '$3')"
  exit 0
fi

# Normalize action format: convert dashes to underscores for case matching
# Example: "save-vlanmgr" becomes "save_vlanmgr" (case statement uses underscores)
RAW_NORM="$(printf '%s' "$RAW" | tr '-' '_')"

# ========================================================================== #
# EVENT PARSING — Extract TYPE and EVENT components from action string       #
# ========================================================================== #

# Parse TYPE and EVENT from RAW action using pattern: TYPE_EVENT
# Two formats supported:
#   1. ACTION already contains underscore: TYPE_EVENT (e.g., "save_vlanmgr")
#   2. ACTION is single word: use TYPE=$1, EVENT=$2 (e.g., "restart" + "$2")
# After parsing, reconstruct RAW as TYPE_EVENT for consistency
case "${RAW}" in
  *_*)
    # Format 1: action already contains underscore (TYPE_EVENT pattern)
    # Extract TYPE as everything before first underscore (${RAW%%_*})
    # Extract EVENT as everything after first underscore (${RAW#*_})
    TYPE="${RAW%%_*}"
    EVENT="${RAW#*_}"
    ;;
  *)
    # Format 2: single-word action, EVENT is separate argument
    # Set TYPE to the action, EVENT to second argument, reconstruct RAW
    TYPE="${RAW}"
    EVENT="${SECOND}"
    RAW="${TYPE}_${EVENT}"
    ;;
esac

# Build combined normalized name for downstream heal handlers
TYPE_NORM=$(printf '%s' "$TYPE" | tr 'A-Z' 'a-z' | tr '-' '_')
EVENT_NORM=$(printf '%s' "$EVENT" | tr 'A-Z' 'a-z' | tr '-' '_')
if [ -n "$EVENT_NORM" ]; then
  COMBINED_NORM="${TYPE_NORM}_${EVENT_NORM}"
else
  COMBINED_NORM="$TYPE_NORM"
fi
COMBINED_NORM=$(printf '%s' "$COMBINED_NORM" | tr -s '_' '_' | sed 's/^_//; s/_$//')

# Log parsed event details for audit trail (helps with debugging)
logger -t "VLANMgr" "handler: RAW='${RAW}' TYPE='${TYPE}' EVENT='${EVENT}' (args: '$1' '$2' '$3')"

# ========================================================================== #
# NODE GUARD — Block MerVLAN UI/API events on nodes                          #
# ========================================================================== #

SETTINGS_FILE="/jffs/addons/mervlan/settings/settings.json"

json_get_flag() {
    key="$1"
    def="$2"
    file="${3:-$SETTINGS_FILE}"

    [ -n "$key" ] || { printf '%s\n' "$def"; return 0; }
    [ -s "$file" ] || { printf '%s\n' "$def"; return 0; }

    # Very simple: grab VALUE from "KEY": "VALUE"
    val="$(sed -n "s/^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -n 1)"

    [ -n "$val" ] || val="$def"
    printf '%s\n' "$val"
}

IS_NODE_FLAG=0
if [ -s "$SETTINGS_FILE" ]; then
  case "$(json_get_flag IS_NODE 0 "$SETTINGS_FILE" 2>/dev/null)" in
    1|yes|on|true)
      IS_NODE_FLAG=1
      ;;
  esac
fi

APP_EVENT=0
case "${TYPE}_${EVENT}" in
  save_vlanmgr|apply_vlanmgr|sync_vlanmgr|executenodes_vlanmgr|\
  executenodesonly_vlanmgr|genkey_vlanmgr|enableservice_vlanmgr|\
  disableservice_vlanmgr|checkservice_vlanmgr|collectclients_vlanmgr|\
  clearclilog_vlanmgr|update_vlanmgr|updatedev_vlanmgr|hwprobe_vlanmgr|macrefresh_vlanmgr)
    APP_EVENT=1
    ;;
esac

if [ "$IS_NODE_FLAG" -eq 1 ] && [ "$APP_EVENT" -eq 1 ]; then
  logger -t "VLANMgr" "handler: ignoring ${TYPE}_${EVENT} on node (IS_NODE=1)"
  exit 0
fi

# ========================================================================== #
# DEBOUNCE & LOCK SETUP — Initialize locking for concurrent execution        #
# ========================================================================== #

# Lightweight debounce/lock mechanism prevents concurrent execution of same event
# Uses directory creation as atomic lock (mkdir fails if dir exists = already locked)
# Lockdir stores both lock dirs (.lock) and timestamp files (.last) for debounce.
# Timing knobs (LOCKDIR, DEBOUNCE_SECONDS, STALE_LOCK_SECONDS) are defined in the
# HANDLER TUNABLES block at the top of this file.
# Create lock directory structure (ignore errors if it already exists)
mkdir -p "$LOCKDIR" 2>/dev/null || :

# ========================================================================== #
# DISPATCH HELPER FUNCTION — Execute scripts with debounce and locking       #
# ========================================================================== #

# dispatch_if_executable — Execute script with atomic locking and debounce
# Args: $1=script_path, $@=remaining_args (passed to script)
# Returns: 0 on successful execution or skip, 1+ from script execution errors
# Explanation: Uses mkdir atomic lock to prevent concurrent execution. Debounce
#   window (3s by default) prevents rapid re-execution of same event. Cleans up
#   locks on exit or signal (EXIT, INT, TERM). Logs all actions for audit.
dispatch_if_executable() {
  local SCRIPT_PATH="$1"
  shift

  # Initialize lock and timestamp tracking variables
  # key: unique identifier for this event (action name or script name)
  # lock_dir/lock_root: where filesystem locks are stored
  # stamp: where last execution timestamp is recorded (for debounce window)
  # window: debounce interval in seconds (skip re-execution within this time)
  # stale: seconds after which a held lock is considered orphaned (crashed script)
  local key lock_root lock_dir stamp now last window stale elapsed
  key="${RAW:-${SCRIPT_PATH##*/}}"
  lock_root="${LOCKDIR%/}"
  lock_dir="${lock_root}/${key}.lock"
  stamp="${lock_root}/${key}.last"
  window="${DEBOUNCE_SECONDS:-0}"
  stale="${STALE_LOCK_SECONDS:-300}"

  # Attempt to acquire lock by creating lock directory (atomic operation)
  # If mkdir fails, lock already exists (concurrent execution or recent invocation)
  if ! mkdir "$lock_dir" 2>/dev/null; then
    # Lock acquisition failed: determine whether to skip or reclaim a stale lock.
    # Two independent checks with different thresholds:
    #   DEBOUNCE (window): reject rapid re-fires (e.g. firmware double-calling hook)
    #   STALE   (stale):  reclaim locks abandoned by crashed scripts
    if [ -f "$stamp" ]; then
      now="$(date +%s 2>/dev/null || echo 0)"
      last="$(cat "$stamp" 2>/dev/null || echo 0)"
      case "$last" in ''|*[!0-9]*) last=0 ;; esac
      elapsed=$((now - last))
      if [ "$window" -gt 0 ] 2>/dev/null && [ "$elapsed" -lt "$window" ]; then
        # Still within debounce window — rapid re-fire; skip
        logger -t "VLANMgr" "handler: ${key} debounced (${elapsed}s < ${window}s); skipping"
        return 0
      elif [ "$elapsed" -lt "$stale" ]; then
        # Outside debounce but within stale threshold — script is still running; skip
        logger -t "VLANMgr" "handler: ${key} already running (${elapsed}s < stale ${stale}s); skipping"
        return 0
      else
        # Older than stale threshold — lock was abandoned by a crashed script; reclaim
        logger -t "VLANMgr" "handler: ${key} lock stale (${elapsed}s >= ${stale}s); reclaiming"
        rmdir "$lock_dir" 2>/dev/null || :
        mkdir "$lock_dir" 2>/dev/null || {
          logger -t "VLANMgr" "handler: ${key} already running; skipping";
          return 0;
        }
      fi
    else
      # No stamp file — lock is current (script just started or stamp write failed); skip
      logger -t "VLANMgr" "handler: ${key} already running (no stamp); skipping"
      return 0
    fi
  fi

  # Lock acquired: register cleanup trap to remove lock on exit
  trap 'logger -t "VLANMgr" "handler: ${key} lock released (trap)"; rmdir "$lock_dir" 2>/dev/null' EXIT INT TERM

  # Debounce check: if within window, skip execution (prevent rapid re-invocation)
  if [ "$window" -gt 0 ] 2>/dev/null; then
    # Get current timestamp
    now="$(date +%s 2>/dev/null || echo 0)"
    # Get last execution timestamp from file (or 0 if missing)
    if [ -f "$stamp" ]; then
      last="$(cat "$stamp" 2>/dev/null || echo 0)"
    else
      last=0
    fi
    # Validate last timestamp is numeric
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    # If within debounce window, skip execution
    if [ $((now - last)) -lt "$window" ]; then
      logger -t "VLANMgr" "handler: debounced ${key} (window=${window}s); skipping"
      rmdir "$lock_dir" 2>/dev/null
      trap - EXIT INT TERM
      return 0
    fi
    # Update timestamp to current time (record this execution)
    printf '%s' "$now" >"$stamp" 2>/dev/null || :
  fi

  logger -t "VLANMgr" "handler: ${key} lock acquired; launching ${SCRIPT_PATH##*/}"

  # Execute script: try direct execution first (if +x bit set), fallback to sh
  if [ -x "$SCRIPT_PATH" ]; then
    "$SCRIPT_PATH" "$@"
  elif [ -f "$SCRIPT_PATH" ]; then
    sh "$SCRIPT_PATH" "$@"
  else
    logger -t "VLANMgr" "handler: missing script ${SCRIPT_PATH}"
  fi

  # Cleanup: remove lock directory and trap handlers
  logger -t "VLANMgr" "handler: ${key} lock released"
  rmdir "$lock_dir" 2>/dev/null
  trap - EXIT INT TERM
}

# ========================================================================== #
# EVENT ROUTER — Dispatch events to appropriate handler functions            #
# ========================================================================== #

# Main event dispatch table: maps TYPE_EVENT patterns to handler scripts
# Each case calls dispatch_if_executable with script path and optional args
# Patterns support wildcards (*) for pattern matching on TYPE or EVENT
case "${TYPE}_${EVENT}" in
  # MerVLAN application handlers (explicit handlers for UI/API calls)
  save_vlanmgr) 
    # Save VLAN settings to JSON file (triggered by web form submission)
    dispatch_if_executable "/jffs/addons/mervlan/functions/save_settings.sh"
    ;;
  apply_vlanmgr)
    # Apply configured VLAN settings to system (triggered by "Apply" button)
    dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_manager.sh"
    ;;
  sync_vlanmgr)
    # Sync VLAN configuration to remote nodes (triggered manually)
    dispatch_if_executable "/jffs/addons/mervlan/functions/sync_nodes.sh"
    ;;
  executenodes_vlanmgr)
    # Execute VLAN Manager workflow on configured nodes (runs execute_nodes.sh)
    dispatch_if_executable "/jffs/addons/mervlan/functions/execute_nodes.sh"
    ;;
  executenodesonly_vlanmgr)
    # Execute VLAN Manager workflow on configured nodes (runs execute_nodes.sh)
    dispatch_if_executable "/jffs/addons/mervlan/functions/execute_nodes.sh" nodesonly
    ;;
  genkey_vlanmgr)
    # Generate SSH keys for node communication (triggered during setup)
    dispatch_if_executable "/jffs/addons/mervlan/functions/dropbear_sshkey_gen.sh"
    ;;
  enableservice_vlanmgr)
    # Enable MerVLAN auto-start on boot (triggered by service toggle)
    dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_boot.sh" enable
    ;;
  disableservice_vlanmgr)
    # Disable MerVLAN auto-start on boot (triggered by service toggle)
    dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_boot.sh" disable
    ;;
  checkservice_vlanmgr)
    # Check MerVLAN service status (triggered by status query)
    dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_boot.sh" status
    ;;
  collectclients_vlanmgr)
    # Collect client list from router and nodes (triggered by refresh request)
    dispatch_if_executable "/jffs/addons/mervlan/functions/collect_clients.sh"
    ;;
  clearclilog_vlanmgr)
    # Clear CLI output log file (triggered by Clear button in UI)
    # Uses : to truncate file in place; no script needed
    : > /tmp/mervlan_tmp/logs/cli_output.log 2>/dev/null || :
    logger -t "VLANMgr" "handler: clearclilog_vlanmgr - CLI log truncated"
    ;;
  update_vlanmgr)
    # Update MerVLAN addon from stable channel (triggered by update request)
    dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" update main
    ;;
  updatedev_vlanmgr)
    # Update MerVLAN addon from development channel (triggered by update request)
    dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" update dev
    ;;
  hwprobe_vlanmgr)
    # Re-run hardware probe to refresh the Hardware profile in settings.json
    dispatch_if_executable "/jffs/addons/mervlan/functions/hw_probe.sh"
    ;;
  macrefresh_vlanmgr)
    # Clear and rebuild the MERV_MAC per-client shield db from a fresh snapshot
    dispatch_if_executable "/jffs/addons/mervlan/functions/mac_refresh.sh"
    ;;
  # System event handlers (triggered by Asuswrt-Merlin events)
  # Wildcard patterns catch restart_* and service events (wireless, WAN, LAN, NET, FW, NAT, DNS)
  # NOTE: httpd intentionally excluded — httpd restarts don't affect VLANs and cause event floods
  *restart*|*wireless*|*wan*|*lan*|*net*|*firewall*|*nat*|*reload*|*dnsmasq*)
    # Skip httpd events that slip through via *restart* pattern
    case "$COMBINED_NORM" in
      *httpd*) 
        logger -t "VLANMgr" "handler: skipping httpd event ${COMBINED_NORM} (excluded)"
        exit 0
        ;;
    esac

    # Handler-level debounce for system events (prevents heal storms from rc event floods)
    HEAL_STAMP="$LOCKDIR/heal_event.last"
    HEAL_WINDOW="$MERV_HEAL_EVENT_DEBOUNCE"
    now="$(date +%s 2>/dev/null || echo 0)"
    last="$(cat "$HEAL_STAMP" 2>/dev/null || echo 0)"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((now - last)) -lt "$HEAL_WINDOW" ]; then
      logger -t "VLANMgr" "handler: heal_event debounced (window=${HEAL_WINDOW}s) for ${COMBINED_NORM}"
      exit 0
    fi
    printf '%s\n' "$now" >"$HEAL_STAMP" 2>/dev/null || :

    # Inline shield re-link: runs synchronously in the event handler (~50ms)
    # BEFORE the fire-and-forget sleep delay. Closes the ~3-8s unprotected
    # window between rc flushing ebtables and heal_event.sh's first tick.
    # Only re-links jump rules for existing chains — never creates chains
    # (chain creation and DROP rule rebuild remain heal_event.sh's job).
    # BusyBox-safe: chain name patterns don't start with '-', no grep flag clash.
    if type ebtables >/dev/null 2>&1; then
      # Proactive DHCP gate: block DHCP DISCOVER/REQUEST in br0 while
      # re-linking MERV_QT/MERV_MAC jump rules. Closes the ~2ms re-link
      # window where FORWARD has no chain jump but per-interface DROP rules
      # are intact (orphan state). Transient — removed after re-link.
      # Remove any stale gate first so duplicate rules never accumulate.
      ebtables -t filter -D FORWARD -p IPv4 --ip-proto udp --ip-dport 67 \
        --logical-in br0 -j DROP 2>/dev/null || true
      ebtables -t filter -D INPUT -p IPv4 --ip-proto udp --ip-dport 67 \
        --logical-in br0 -j DROP 2>/dev/null || true
      ebtables -t filter -I FORWARD -p IPv4 --ip-proto udp --ip-dport 67 \
        --logical-in br0 -j DROP 2>/dev/null || true
      ebtables -t filter -I INPUT -p IPv4 --ip-proto udp --ip-dport 67 \
        --logical-in br0 -j DROP 2>/dev/null || true
      for _se_chain in MERV_QT MERV_MAC; do
        if ebtables -t filter -L "$_se_chain" >/dev/null 2>&1; then
          ebtables -t filter -L FORWARD 2>/dev/null | grep -qF "$_se_chain" || \
            ebtables -t filter -I FORWARD -j "$_se_chain" 2>/dev/null || true
          ebtables -t filter -L INPUT 2>/dev/null | grep -qF "$_se_chain" || \
            ebtables -t filter -I INPUT -j "$_se_chain" 2>/dev/null || true
        fi
      done
      ebtables -t filter -D FORWARD -p IPv4 --ip-proto udp --ip-dport 67 \
        --logical-in br0 -j DROP 2>/dev/null || true
      ebtables -t filter -D INPUT -p IPv4 --ip-proto udp --ip-dport 67 \
        --logical-in br0 -j DROP 2>/dev/null || true
    fi

    # Fire-and-forget heal so rc can continue applying its own changes.
    # Wireless events use delay=0: heal_event.sh has a pre-entry wait loop
    # that actively polls for restart activity instead of a blind sleep.
    # All other system events keep the default delay so they fire after the
    # relevant service has had time to begin its work.
    case "$COMBINED_NORM" in
      *wireless*|*restart_wl*|*wl_restart*|*wl_start*|*wl_stop*)
        _se_heal_delay=0
        ;;
      *)
        _se_heal_delay="$MERV_HEAL_DELAY"
        ;;
    esac
    logger -t "VLANMgr" "handler: queued heal_event ${COMBINED_NORM} (async, delay=${_se_heal_delay}s)"
    (
      sleep "$_se_heal_delay"
      /jffs/addons/mervlan/functions/heal_event.sh "$COMBINED_NORM"
    ) >/dev/null 2>&1 &
    ;;
  *)
    # Unknown event: no matching handler found
    logger -t "VLANMgr" "handler: no match for ${TYPE}_${EVENT}, ignoring"
    ;;
esac