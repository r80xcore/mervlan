#!/bin/sh
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
#         - File: templates/mervlan_templates.sh || version="0.49"             #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Provide unified template lookup utilities for MerVLAN.         #
#               Each template is stored inline and can be materialized via     #
#               tpl_path for injection/removal helpers.                        #
# ──────────────────────────────────────────────────────────────────────────── #

[ -n "${MERV_TEMPLATE_LIB_LOADED:-}" ] && return 0 2>/dev/null

read_only_templates=$(cat <<'EOF'
%%TEMPLATE service-event 1
# MerVLAN auto-redirect events to service-event-handler.sh
MERV_BASE_PLACEHOLDER/functions/service-event-handler.sh "$@"
%%END

%%TEMPLATE service-event 2
# MerVLAN auto-redirect events to service-event-handler.sh
MERV_BASE_PLACEHOLDER/functions/service-event-handler.sh "$@"
%%END

%%TEMPLATE services-start 1
# MerVLAN auto-enable VLAN on boot
sleep 10
MERV_BASE_PLACEHOLDER/functions/mervlan_manager.sh
sleep 10
MERV_BASE_PLACEHOLDER/functions/mervlan_boot.sh cronenable
%%END

%%TEMPLATE services-start 2
# MerVLAN auto-enable VLAN on boot
sleep 10
MERV_BASE_PLACEHOLDER/functions/mervlan_manager.sh
sleep 10
MERV_BASE_PLACEHOLDER/functions/mervlan_boot.sh cronenable
%%END

%%TEMPLATE services-start-addon 1
# MerVLAN mount addon on boot
sleep 5
MERV_BASE_PLACEHOLDER/install.sh
%%END

%%TEMPLATE services-start-addon 2
# MerVLAN mount addon on boot
sleep 5
MERV_BASE_PLACEHOLDER/install.sh
%%END

%%TEMPLATE service-event-nodes 1
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
#          - File: service-event-handler.sh || version="0.48"                  #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Event handler for http and service events                      #
# ──────────────────────────────────────────────────────────────────────────── #

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
# DEBOUNCE & LOCK SETUP — Initialize locking for concurrent execution        #
# ========================================================================== #

# Lightweight debounce/lock mechanism prevents concurrent execution of same event
# Uses directory creation as atomic lock (mkdir fails if dir exists = already locked)
# Lockdir stores both lock dirs (.lock) and timestamp files (.last) for debounce
LOCKDIR="/tmp/mervlan_tmp/locks"
DEBOUNCE_SECONDS=3
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
  local key lock_root lock_dir stamp now last window
  key="${RAW:-${SCRIPT_PATH##*/}}"
  lock_root="${LOCKDIR%/}"
  lock_dir="${lock_root}/${key}.lock"
  stamp="${lock_root}/${key}.last"
  window="${DEBOUNCE_SECONDS:-0}"

  # Attempt to acquire lock by creating lock directory (atomic operation)
  # If mkdir fails, lock already exists (concurrent execution or recent invocation)
  if ! mkdir "$lock_dir" 2>/dev/null; then
    # Lock acquisition failed: check if stale or within debounce window
    # Allow stale lock cleanup if outside debounce window (prevents permanent lock)
    if [ "$window" -gt 0 ] 2>/dev/null && [ -f "$stamp" ]; then
      # Get current timestamp and last execution timestamp
      now="$(date +%s 2>/dev/null || echo 0)"
      last="$(cat "$stamp" 2>/dev/null || echo 0)"
      # Validate last timestamp is numeric (protect against garbage in file)
      case "$last" in ''|*[!0-9]*) last=0 ;; esac
      # If last execution is outside debounce window, allow lock cleanup and retry
      if [ $((now - last)) -ge "$window" ]; then
        rmdir "$lock_dir" 2>/dev/null || :
        mkdir "$lock_dir" 2>/dev/null || {
          logger -t "VLANMgr" "handler: ${key} already running; skipping";
          return 0;
        }
      else
        # Still within debounce window: log skip and return
        logger -t "VLANMgr" "handler: ${key} already running; skipping"
        return 0
      fi
    else
      # No timestamp tracking or no recent timestamp: lock is current
      logger -t "VLANMgr" "handler: ${key} already running; skipping"
      return 0
    fi
  fi

  # Lock acquired: register cleanup trap to remove lock on exit
  trap 'rmdir "$lock_dir" 2>/dev/null' EXIT INT TERM

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

  # Execute script: try direct execution first (if +x bit set), fallback to sh
  if [ -x "$SCRIPT_PATH" ]; then
    "$SCRIPT_PATH" "$@"
  elif [ -f "$SCRIPT_PATH" ]; then
    sh "$SCRIPT_PATH" "$@"
  else
    logger -t "VLANMgr" "handler: missing script ${SCRIPT_PATH}"
  fi

  # Cleanup: remove lock directory and trap handlers
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
  # System event handlers (triggered by Asuswrt-Merlin events)
  # Wildcard patterns catch restart_* and service events (httpd, wireless, WAN, LAN, NET, FW, NAT, DNS)
  *restart*|*wireless*|*httpd*|*wan*|*lan*|*net*|*firewall*|*nat*|*reload*|*dnsmasq*)
    # Fire-and-forget heal so rc can continue applying its own changes
    logger -t "VLANMgr" "handler: queued heal_event ${COMBINED_NORM} (async)"
    (
      sleep "${MERV_HEAL_DELAY:-3}"
      /jffs/addons/mervlan/functions/heal_event.sh "$COMBINED_NORM"
    ) >/dev/null 2>&1 &
    ;;
  *)
    # Unknown event: no matching handler found
    logger -t "VLANMgr" "handler: no match for ${TYPE}_${EVENT}, ignoring"
    ;;
esac
%%END

%%TEMPLATE service-event-nodes 2
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
#          - File: service-event-handler.sh || version="0.46a"                  #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Event handler for http and service events                      #
# ──────────────────────────────────────────────────────────────────────────── #

# ========================================================================== #
# PARAMETER EXTRACTION & VALIDATION — Parse event action from arguments      #
# ========================================================================== #

RAW="$1"
SECOND="$2"

if [ -z "${RAW}" ] && [ -n "${SECOND}" ]; then
  RAW="${SECOND}"
fi

if [ -z "${RAW}" ]; then
  logger -t "VLANMgr" "handler: no action provided (args: '$1' '$2' '$3')"
  exit 0
fi

RAW_NORM="$(printf '%s' "$RAW" | tr '-' '_')"

# ========================================================================== #
# EVENT PARSING — Extract TYPE and EVENT components from action string       #
# ========================================================================== #

case "${RAW}" in
  *_*)
    TYPE="${RAW%%_*}"
    EVENT="${RAW#*_}"
    ;;
  *)
    TYPE="${RAW}"
    EVENT="${SECOND}"
    RAW="${TYPE}_${EVENT}"
    ;;
esac

logger -t "VLANMgr" "handler: RAW='${RAW}' TYPE='${TYPE}' EVENT='${EVENT}' (args: '$1' '$2' '$3')"

# ========================================================================== #
# DEBOUNCE & LOCK SETUP — Initialize locking for concurrent execution        #
# ========================================================================== #

LOCKDIR="/tmp/mervlan_tmp/locks"
DEBOUNCE_SECONDS=3
mkdir -p "$LOCKDIR" 2>/dev/null || :

# ========================================================================== #
# DISPATCH HELPER FUNCTION — Execute scripts with debounce and locking       #
# ========================================================================== #

dispatch_if_executable() {
  local SCRIPT_PATH="$1"
  shift

  local key lock_root lock_dir stamp now last window
  key="${RAW:-${SCRIPT_PATH##*/}}"
  lock_root="${LOCKDIR%/}"
  lock_dir="${lock_root}/${key}.lock"
  stamp="${lock_root}/${key}.last"
  window="${DEBOUNCE_SECONDS:-0}"

  if ! mkdir "$lock_dir" 2>/dev/null; then
    if [ "$window" -gt 0 ] 2>/dev/null && [ -f "$stamp" ]; then
      now="$(date +%s 2>/dev/null || echo 0)"
      last="$(cat "$stamp" 2>/dev/null || echo 0)"
      case "$last" in ''|*[!0-9]*) last=0 ;; esac
      if [ $((now - last)) -ge "$window" ]; then
        rmdir "$lock_dir" 2>/dev/null || :
        mkdir "$lock_dir" 2>/dev/null || {
          logger -t "VLANMgr" "handler: ${key} already running; skipping";
          return 0;
        }
      else
        logger -t "VLANMgr" "handler: ${key} already running; skipping"
        return 0
      fi
    else
      logger -t "VLANMgr" "handler: ${key} already running; skipping"
      return 0
    fi
  fi

  trap 'rmdir "$lock_dir" 2>/dev/null' EXIT INT TERM

  if [ "$window" -gt 0 ] 2>/dev/null; then
    now="$(date +%s 2>/dev/null || echo 0)"
    if [ -f "$stamp" ]; then
      last="$(cat "$stamp" 2>/dev/null || echo 0)"
    else
      last=0
    fi
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((now - last)) -lt "$window" ]; then
      logger -t "VLANMgr" "handler: debounced ${key} (window=${window}s); skipping"
      rmdir "$lock_dir" 2>/dev/null
      trap - EXIT INT TERM
      return 0
    fi
    printf '%s' "$now" >"$stamp" 2>/dev/null || :
  fi

  if [ -x "$SCRIPT_PATH" ]; then
    "$SCRIPT_PATH" "$@"
  elif [ -f "$SCRIPT_PATH" ]; then
    sh "$SCRIPT_PATH" "$@"
  else
    logger -t "VLANMgr" "handler: missing script ${SCRIPT_PATH}"
  fi

  rmdir "$lock_dir" 2>/dev/null
  trap - EXIT INT TERM
}

# ========================================================================== #
# EVENT ROUTER — Dispatch events to appropriate handler functions            #
# ========================================================================== #

case "${TYPE}_${EVENT}" in
  save_vlanmgr)
    dispatch_if_executable "/jffs/addons/mervlan/functions/save_settings.sh"
    ;;
  apply_vlanmgr)
    dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_manager.sh"
    ;;
  sync_vlanmgr)
    dispatch_if_executable "/jffs/addons/mervlan/functions/sync_nodes.sh"
    ;;
  executenodes_vlanmgr)
    dispatch_if_executable "/jffs/addons/mervlan/functions/execute_nodes.sh"
    ;;
  executenodesonly_vlanmgr)
    dispatch_if_executable "/jffs/addons/mervlan/functions/execute_nodes.sh" nodesonly
    ;;
  genkey_vlanmgr)
    dispatch_if_executable "/jffs/addons/mervlan/functions/dropbear_sshkey_gen.sh"
    ;;
  enableservice_vlanmgr)
    dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_boot.sh" enable
    ;;
  disableservice_vlanmgr)
    dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_boot.sh" disable
    ;;
  checkservice_vlanmgr)
    dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_boot.sh" status
    ;;
  collectclients_vlanmgr)
    dispatch_if_executable "/jffs/addons/mervlan/functions/collect_clients.sh"
    ;;
  *restart*|*wireless*|*httpd*|*wan-start*|*wan-restart*|*wan_start*|*wan_restart*)
    dispatch_if_executable "/jffs/addons/mervlan/functions/heal_event.sh" "$RAW_NORM"
    ;;
  *)
    logger -t "VLANMgr" "handler: no match for ${TYPE}_${EVENT}, ignoring"
    ;;
esac
%%END
EOF
)

_tpl_registry_dir="${TMPDIR:-/tmp}/mervlan_tpls"
[ -d "$_tpl_registry_dir" ] || mkdir -p "$_tpl_registry_dir" 2>/dev/null || :

# tpl_path — materialize template <name> variant <variant> into stable temp file
# Args: $1=name, $2=variant (optional), $3=dest file for variant sniffing (optional)
# Echoes path to rendered template or 'ERR' on failure.
tpl_path() {
  local name="$1" variant="$2" sniff_dest="$3" tmp tmp_raw target inj status
  [ -n "$name" ] || { echo "ERR"; return 1; }

  if [ -z "$variant" ]; then
    if [ -n "$sniff_dest" ] && [ -s "$sniff_dest" ] && head -n 1 "$sniff_dest" 2>/dev/null | grep -q '^#!'; then
      variant="2"
    else
      variant="1"
    fi
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/merv_tpl.${name}.${variant}.XXXXXX" 2>/dev/null || printf '%s/merv_tpl.%s.%s.%s' "${TMPDIR:-/tmp}" "$name" "$variant" "$$")"
  tmp_raw="${tmp}.raw"

  printf '%s
' "$read_only_templates" | awk -v n="$name" -v v="$variant" '
    BEGIN { capture = 0; found = 0 }
    /^%%TEMPLATE[[:space:]]+/ {
      split($0, parts, /[[:space:]]+/)
      tmpl = parts[2]
      ver = parts[3]
      capture = (tmpl == n && ver == v)
      if (capture) {
        found = 1
      }
      next
    }
    /^%%END$/ {
      capture = 0
      next
    }
    capture { print }
    END {
      if (!found) exit 2
    }
  ' > "$tmp_raw" 2>/dev/null
  status=$?
  if [ $status -ne 0 ]; then
    rm -f "$tmp" "$tmp_raw" 2>/dev/null || :
    echo "ERR"
    return 1
  fi

  inj="${MERV_BASE%/}"
  if ! sed "s|MERV_BASE_PLACEHOLDER|$inj|g" "$tmp_raw" > "$tmp" 2>/dev/null; then
    rm -f "$tmp" "$tmp_raw" 2>/dev/null || :
    echo "ERR"
    return 1
  fi

  rm -f "$tmp_raw" 2>/dev/null || :

  target="${_tpl_registry_dir%/}/${name}.v${variant}.tpl"
  mv -f "$tmp" "$target" 2>/dev/null || {
    rm -f "$tmp" "$target" "$tmp_raw" 2>/dev/null || :
    echo "ERR"
    return 1
  }

  echo "$target"
  return 0
}

MERV_TEMPLATE_LIB_LOADED=1
