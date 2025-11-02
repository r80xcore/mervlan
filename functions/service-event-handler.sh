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
#          - File: service-event-handler.sh || version="0.45"                  #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Event handler for http and service events                      #
# ──────────────────────────────────────────────────────────────────────────── #

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

# Lightweight debounce/lock setup (static defaults)
LOCKDIR="/tmp/mervlan_tmp/locks"
DEBOUNCE_SECONDS=3
mkdir -p "$LOCKDIR" 2>/dev/null || :

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
    # Allow stale lock cleanup if outside debounce window
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

case "${TYPE}_${EVENT}" in
  save_vlanmgr) 
    dispatch_if_executable "/jffs/addons/mervlan/functions/save_settings.sh"
    ;;
  apply_vlanmgr)
    dispatch_if_executable "/jffs/addons/mervlan/functions/apply_vlans.sh"
    ;;
  sync_vlanmgr)
    dispatch_if_executable "/jffs/addons/mervlan/functions/sync_nodes.sh"
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