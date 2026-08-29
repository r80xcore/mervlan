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
#          - File: service-event-handler.sh || version="0.65"                  #
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
MERV_HEAL_EVENT_DEBOUNCE="${MERV_HEAL_EVENT_DEBOUNCE:-5}"
MERV_HEAL_DELAY="${MERV_HEAL_DELAY:-3}"

if [ -z "${LIB_ACTION_LOCK_LOADED:-}" ] && [ -f "$MERV_BASE/settings/lib_action_lock.sh" ]; then
  . "$MERV_BASE/settings/lib_action_lock.sh" 2>/dev/null || exit 1
fi
if [ -z "${LIB_ACTION_ACK_LOADED:-}" ] && [ -f "$MERV_BASE/settings/lib_action_ack.sh" ]; then
  . "$MERV_BASE/settings/lib_action_ack.sh" 2>/dev/null || exit 1
fi
if [ -z "${LIB_ACTION_PROGRESS_LOADED:-}" ] && [ -f "$MERV_BASE/settings/lib_action_progress.sh" ]; then
  . "$MERV_BASE/settings/lib_action_progress.sh" 2>/dev/null || :
fi

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
case "$RAW_NORM" in
  ''|*[!A-Za-z0-9._-]*)
    logger -t "VLANMgr" "handler: rejected unsafe action name"
    exit 1
    ;;
esac
RAW="$RAW_NORM"

# ========================================================================== #
# EVENT PARSING — Extract TYPE and EVENT components from action string       #
# ========================================================================== #

# Parse TYPE and EVENT from RAW action using pattern: TYPE_EVENT
# Two formats supported:
#   1. ACTION already contains underscore: TYPE_EVENT (e.g., "save_vlanmgr")
#   2. ACTION is single word: use TYPE=$1, EVENT=$2 (e.g., "restart" + "$2")
# After parsing, reconstruct RAW as TYPE_EVENT for consistency
case "${RAW_NORM:-$RAW}" in
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

# The event router consumes only this sanitized spelling.  Normalize the
# second argument as well for the legacy TYPE EVENT calling convention.
TYPE_NORM=$(printf '%s' "$TYPE" | tr 'A-Z' 'a-z' | tr '-' '_')
EVENT_NORM=$(printf '%s' "$EVENT" | tr 'A-Z' 'a-z' | tr '-' '_')
case "$TYPE_NORM" in ''|*[!A-Za-z0-9_.-]*) exit 1 ;; esac
case "$EVENT_NORM" in *[!A-Za-z0-9_.-]*) exit 1 ;; esac
TYPE="$TYPE_NORM"
EVENT="$EVENT_NORM"
RAW="${TYPE}_${EVENT}"

# Build combined normalized name for downstream heal handlers
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
CUSTOM_SETTINGS_FILE="/jffs/addons/custom_settings.txt"

get_action_request_token() {
  grep '^vlanmgr_action_request_token=' "$CUSTOM_SETTINGS_FILE" 2>/dev/null | \
    tail -n1 | cut -d'=' -f2- | \
    tr -cd 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-'
}

get_progress_request_token() {
  grep '^vlanmgr_progress_token=' "$CUSTOM_SETTINGS_FILE" 2>/dev/null | \
    tail -n1 | cut -d'=' -f2- | \
    tr -cd 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-'
}

decode_hex_ascii() {
  _dha_hex="$1"
  case "$_dha_hex" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ $(( ${#_dha_hex} % 2 )) -eq 0 ] || return 1
  _dha_escaped=""
  while [ -n "$_dha_hex" ]; do
    _dha_pair="${_dha_hex%${_dha_hex#??}}"
    _dha_hex="${_dha_hex#??}"
    _dha_oct=$(printf '%03o' "$((0x$_dha_pair))") || return 1
    _dha_escaped="${_dha_escaped}\\${_dha_oct}"
  done
  printf '%b' "$_dha_escaped"
}

get_verified_action_token() {
  _vat_action="$1"
  _vat_base="$2"
  _vat_hex="${_vat_action#${_vat_base}_vrt_}"
  [ "$_vat_hex" != "$_vat_action" ] || return 1
  _vat_token=$(decode_hex_ascii "$_vat_hex") || return 1
  _vat_clean=$(printf '%s' "$_vat_token" | tr -cd 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-')
  [ -n "$_vat_token" ] && [ "$_vat_clean" = "$_vat_token" ] || return 1
  printf '%s\n' "$_vat_token"
}

get_progress_action_token() {
  _pat_action="${1:-}"
  case "$_pat_action" in
    sshtrustprobe_vlanmgr_pgt_*_nsl_*)
      _pat_tail="${_pat_action#sshtrustprobe_vlanmgr_pgt_}"
      _pat_hex="${_pat_tail%%_nsl_*}"
      ;;
    *_pgt_*) _pat_hex="${_pat_action#*_pgt_}" ;;
    *) return 1 ;;
  esac
  _pat_token=$(decode_hex_ascii "$_pat_hex") || return 1
  _pat_clean=$(printf '%s' "$_pat_token" | tr -cd 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-')
  [ -n "$_pat_token" ] && [ "$_pat_clean" = "$_pat_token" ] || return 1
  printf '%s\n' "$_pat_token"
}

get_ssh_trust_probe_node_slots() {
  _stps_action="${1:-}"
  _stps_tail="${_stps_action#sshtrustprobe_vlanmgr_pgt_}"
  [ "$_stps_tail" != "$_stps_action" ] || return 1
  case "$_stps_tail" in
    *_nsl_*) _stps_slots="${_stps_tail#*_nsl_}" ;;
    *) return 1 ;;
  esac
  case "$_stps_slots" in
    ''|*[!0-9.]*|.*|*..*|*.) return 1 ;;
  esac
  _stps_seen=" "
  _stps_max=10
  for _stps_slot in $(printf '%s' "$_stps_slots" | tr '.' ' '); do
    case "$_stps_slot" in
      ''|0|0[0-9]*) return 1 ;;
    esac
    [ "$_stps_slot" -ge 1 ] 2>/dev/null && [ "$_stps_slot" -le "$_stps_max" ] 2>/dev/null || return 1
    case "$_stps_seen" in *" $_stps_slot "*) return 1 ;; esac
    _stps_seen="${_stps_seen}${_stps_slot} "
  done
  printf '%s\n' "$_stps_slots"
}

decode_update_ref_action() {
  _ura_encoded="${1#updateref_vlanmgr_}"
  [ "$_ura_encoded" != "$1" ] || return 1
  [ -n "$_ura_encoded" ] && [ "${#_ura_encoded}" -le 260 ] || return 1
  case "$_ura_encoded" in *[!0-9a-f_kcht_]* ) return 1 ;; esac
  _ura_policy=keep
  _ura_kind="${_ura_encoded%%_*}"
  _ura_hex="${_ura_encoded#*_}"
  [ "$_ura_hex" != "$_ura_encoded" ] || return 1
  case "$_ura_kind" in
    k|c)
      [ "$_ura_kind" = "c" ] && _ura_policy=clear
      _ura_encoded="$_ura_hex"
      _ura_kind="${_ura_encoded%%_*}"
      _ura_hex="${_ura_encoded#*_}"
      [ "$_ura_hex" != "$_ura_encoded" ] || return 1
      ;;
  esac
  case "$_ura_kind" in h|t) ;; *) return 1 ;; esac
  _ura_name=$(decode_hex_ascii "$_ura_hex") || return 1
  [ "${#_ura_name}" -le 120 ] || return 1
  _ura_clean=$(printf '%s' "$_ura_name" | tr -cd 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-')
  [ -n "$_ura_name" ] && [ "$_ura_clean" = "$_ura_name" ] || return 1
  case "$_ura_name" in *..*|*//*|/*|*/|.*|*.lock) return 1 ;; esac

  case "$_ura_kind" in
    h) printf 'refs/heads/%s|%s\n' "$_ura_name" "$_ura_policy" ;;
    t) case "$_ura_name" in v[0-9]*) printf 'refs/tags/%s|%s\n' "$_ura_name" "$_ura_policy" ;; *) return 1 ;; esac ;;
  esac
}

decode_maintenance_action() {
  _dma_action="$1"
  _dma_base="$2"
  _dma_payload_required="$3"
  _dma_encoded="${_dma_action#${_dma_base}_}"
  [ "$_dma_encoded" != "$_dma_action" ] || return 1
  _dma_token_hex="${_dma_encoded%%_*}"
  if [ "$_dma_encoded" = "$_dma_token_hex" ]; then
    _dma_payload_hex=""
  else
    _dma_payload_hex="${_dma_encoded#*_}"
  fi
  [ -n "$_dma_token_hex" ] && [ "${#_dma_token_hex}" -le 64 ] || return 1
  _dma_token=$(decode_hex_ascii "$_dma_token_hex") || return 1
  _dma_token_clean=$(printf '%s' "$_dma_token" | tr -cd 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-')
  [ -n "$_dma_token" ] && [ "$_dma_token" = "$_dma_token_clean" ] || return 1
  if [ "$_dma_payload_required" = "1" ]; then
    [ -n "$_dma_payload_hex" ] && [ "${#_dma_payload_hex}" -le 320 ] || return 1
    _dma_payload=$(decode_hex_ascii "$_dma_payload_hex") || return 1
  else
    [ -z "$_dma_payload_hex" ] || return 1
    _dma_payload=""
  fi
  printf '%s|%s\n' "$_dma_token" "$_dma_payload"
}

decode_maintenance_archive_action() {
  _dmaa_action="$1"
  _dmaa_base="$2"
  _dmaa_encoded="${_dmaa_action#${_dmaa_base}_}"
  [ "$_dmaa_encoded" != "$_dmaa_action" ] || return 1
  _dmaa_token_hex="${_dmaa_encoded%%_*}"
  _dmaa_archive_key="${_dmaa_encoded#*_}"
  [ "$_dmaa_archive_key" != "$_dmaa_encoded" ] || return 1
  [ -n "$_dmaa_token_hex" ] && [ "${#_dmaa_token_hex}" -le 64 ] || return 1
  _dmaa_token=$(decode_hex_ascii "$_dmaa_token_hex") || return 1
  _dmaa_token_clean=$(printf '%s' "$_dmaa_token" | tr -cd 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-')
  [ -n "$_dmaa_token" ] && [ "$_dmaa_token" = "$_dmaa_token_clean" ] || return 1

  case "$_dmaa_archive_key" in
    a.*)
      _dmaa_archive_tail=${_dmaa_archive_key#a.}
      printf '%s\n' "$_dmaa_archive_tail" | grep -Eq '^[0-9]{8}-[0-9]{6}(-[0-9]+)?$' || return 1
      _dmaa_archive_id="mervlan.backup.${_dmaa_archive_tail}.tar.gz"
      ;;
    m.*)
      printf '%s\n' "$_dmaa_archive_key" | grep -Eq '^m\.[0-9]{8}-[0-9]{6}\.[A-Za-z0-9][A-Za-z0-9_-]{0,23}$' || return 1
      _dmaa_archive_tail=${_dmaa_archive_key#m.}
      _dmaa_timestamp=${_dmaa_archive_tail%%.*}
      _dmaa_tag=${_dmaa_archive_tail#*.}
      _dmaa_archive_id="mervlan.manual.backup.${_dmaa_timestamp}.${_dmaa_tag}.tar.gz"
      ;;
    *) return 1 ;;
  esac
  maintenance_archive_valid "$_dmaa_archive_id" || return 1
  printf '%s|%s\n' "$_dmaa_token" "$_dmaa_archive_id"
}

maintenance_tag_valid() {
  printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]{0,23}$'
}

maintenance_archive_valid() {
  _mav_id="$1"
  [ "${_mav_id##*/}" = "$_mav_id" ] || return 1
  case "$_mav_id" in *..*|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*) return 1 ;; esac
  printf '%s\n' "$_mav_id" | grep -Eq '^mervlan\.backup\.[A-Za-z0-9_-]+\.tar\.gz$|^mervlan\.manual\.backup\.[0-9]{8}-[0-9]{6}\.[A-Za-z0-9][A-Za-z0-9_-]{0,23}\.tar\.gz$'
}

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
  save_vlanmgr|save_vlanmgr_pgt_*|apply_vlanmgr|apply_vlanmgr_pgt_*|sync_vlanmgr|sync_vlanmgr_pgt_*|syncsettings_vlanmgr|syncsettings_vlanmgr_pgt_*|executenodes_vlanmgr|executenodes_vlanmgr_pgt_*|\
  executenodesonly_vlanmgr|executenodesonly_vlanmgr_pgt_*|genkey_vlanmgr|genkey_vlanmgr_pgt_*|enableservice_vlanmgr|\
  disableservice_vlanmgr|enableservice_vlanmgr_vrt_*|disableservice_vlanmgr_vrt_*|checkservice_vlanmgr|collectclients_vlanmgr|collectclients_vlanmgr_pgt_*|\
  clearclilog_vlanmgr|update_vlanmgr|updatedev_vlanmgr|updaterelease_vlanmgr|updateref_vlanmgr_*|\
  backupinventory_vlanmgr_*|manualbackup_vlanmgr_*|deletebackup_vlanmgr_*|deleteallbackups_vlanmgr_*|restorebackup_vlanmgr_*|\
  undorestore_vlanmgr_*|undoupdate_vlanmgr_*|\
  hwprobe_vlanmgr|hwprobe_vlanmgr_vrt_*|macrefresh_vlanmgr|macrefresh_vlanmgr_pgt_*|\
  sshtrustprobe_vlanmgr|sshtrustprobe_vlanmgr_pgt_*|sshtrustprobe_vlanmgr_vrt_*|sshtrustenroll_vlanmgr_vrt_*|sshtrustresume_vlanmgr_vrt_*|\
  sshtruststatus_vlanmgr|sshtruststatus_vlanmgr_pgt_*|sshtruststatus_vlanmgr_vrt_*|sshtrustrevoke_vlanmgr_vrt_*|sshtrustabort_vlanmgr_vrt_*|\
  macclientmeta_vlanmgr|macclientmeta_vlanmgr_pgt_*)
    APP_EVENT=1
    ;;
esac

if [ "$IS_NODE_FLAG" -eq 1 ] && [ "$APP_EVENT" -eq 1 ]; then
  logger -t "VLANMgr" "handler: ignoring ${TYPE}_${EVENT} on node (IS_NODE=1)"
  exit 0
fi

# ========================================================================== #
# PAUSE GUARD — Suppress router-triggered events when PAUSE is active        #
# ========================================================================== #
# APP_EVENT=1 (UI buttons) always pass through so the UI remains responsive.
# APP_EVENT=0 (router-native events like wifi/eth changes) are suppressed.
if [ "$APP_EVENT" = "0" ] && [ -s "$SETTINGS_FILE" ]; then
  _pause_flag=$(json_get_flag PAUSE off "$SETTINGS_FILE" 2>/dev/null)
  if [ "$_pause_flag" = "on" ]; then
    logger -t "VLANMgr" "handler: PAUSED — suppressed router event '${RAW}'"
    exit 0
  fi
fi

# ========================================================================== #
# DEBOUNCE & LOCK SETUP — Initialize locking for concurrent execution        #
# ========================================================================== #

# Prepare the durable lock parent. The action lock library owns all lock state;
# this handler does not reclaim locks by age or by raw directory presence.
mkdir -p "$LOCKDIR" 2>/dev/null || {
  logger -t "VLANMgr" "handler: lock directory could not be created; refusing dispatch"
  exit 1
}

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
  logger -t "VLANMgr" "handler: dispatch raw=${RAW:-} script=${SCRIPT_PATH##*/}"

  # Only explicitly progress-enabled actions receive a progress token. This
  # prevents a stale custom-settings value from leaking into unrelated actions.
  MERV_PROGRESS_TOKEN=""
  case "${RAW:-}" in
    sync_vlanmgr|syncsettings_vlanmgr|apply_vlanmgr)
      MERV_PROGRESS_TOKEN="$(get_progress_request_token)"
      ;;
    save_vlanmgr_pgt_*|sync_vlanmgr_pgt_*|syncsettings_vlanmgr_pgt_*|apply_vlanmgr_pgt_*|executenodes_vlanmgr_pgt_*|executenodesonly_vlanmgr_pgt_*|genkey_vlanmgr_pgt_*|macrefresh_vlanmgr_pgt_*|macclientmeta_vlanmgr_pgt_*|collectclients_vlanmgr_pgt_*|repairmain_vlanmgr_pgt_*|repairdev_vlanmgr_pgt_*|sshtrustprobe_vlanmgr_pgt_*|sshtruststatus_vlanmgr_pgt_*|sshtrustrevoke_vlanmgr_pgt_*)
      MERV_PROGRESS_TOKEN="$(get_progress_action_token "${RAW:-}")"
      ;;
    sshtrustprobe_vlanmgr_vrt_*) MERV_PROGRESS_TOKEN="$(get_verified_action_token "${TYPE}_${EVENT}" sshtrustprobe_vlanmgr)" ;;
    sshtrustenroll_vlanmgr_vrt_*) MERV_PROGRESS_TOKEN="$(get_verified_action_token "${TYPE}_${EVENT}" sshtrustenroll_vlanmgr)" ;;
    sshtrustresume_vlanmgr_vrt_*) MERV_PROGRESS_TOKEN="$(get_verified_action_token "${TYPE}_${EVENT}" sshtrustresume_vlanmgr)" ;;
    sshtruststatus_vlanmgr_vrt_*) MERV_PROGRESS_TOKEN="$(get_verified_action_token "${TYPE}_${EVENT}" sshtruststatus_vlanmgr)" ;;
    sshtrustrevoke_vlanmgr_vrt_*) MERV_PROGRESS_TOKEN="$(get_verified_action_token "${TYPE}_${EVENT}" sshtrustrevoke_vlanmgr)" ;;
    sshtrustabort_vlanmgr_vrt_*) MERV_PROGRESS_TOKEN="$(get_verified_action_token "${TYPE}_${EVENT}" sshtrustabort_vlanmgr)" ;;
  esac
  case "$MERV_PROGRESS_TOKEN" in
    ''|*[!A-Za-z0-9._-]*) MERV_PROGRESS_TOKEN="" ;;
  esac
  export MERV_PROGRESS_TOKEN

  # Every dispatched script receives a parent-owned identity lock. Unknown or
  # malformed owner metadata is treated as busy and is never reclaimed by age.
  _se_key=$(printf '%s' "${RAW:-${SCRIPT_PATH##*/}}" | tr -cd 'A-Za-z0-9._-')
  [ -n "$_se_key" ] || return 1
  # Progress-token actions carry the token in their dispatch spelling, but the
  # correlated acknowledgement is a public action contract.  Keep lock
  # refusals observable by the browser under the same base action it requested.
  # (For example, save_vlanmgr_pgt_<token> acknowledges as save_vlanmgr.)
  case "$_se_key" in
    *_pgt_*) _se_ack_action="${_se_key%%_pgt_*}" ;;
    *) _se_ack_action="$_se_key" ;;
  esac
  _se_event_lock="${LOCKDIR%/}/${_se_key}.lock"
  merv_action_lock_enter "$_se_event_lock"
  _se_event_rc=$?
  if [ "$_se_event_rc" -ne 0 ]; then
    merv_action_progress_init "${MERV_PROGRESS_TOKEN:-}" "$_se_key" "$_se_key" "Preparing action..."
    if [ "$_se_event_rc" -eq 3 ]; then
      merv_action_progress_fail "Another action is already running; this event was not started."
    else
      merv_action_progress_fail "The event action owner could not be verified; no work was started."
    fi
    if [ -n "${MERV_PROGRESS_TOKEN:-}" ] && type action_ack_lock_failure >/dev/null 2>&1; then
      action_ack_lock_failure "$MERV_PROGRESS_TOKEN" "$_se_ack_action" "$_se_event_rc" event >/dev/null 2>&1 || \
        logger -t "VLANMgr" "handler: lock-failure acknowledgement failed for $_se_key"
    fi
    logger -t "VLANMgr" "handler: $_se_key owner lock unavailable (rc=$_se_event_rc); refusing dispatch"
    return 75
  fi
  _se_event_nonce="$MERV_ACTION_LOCK_NONCE"; _se_event_start="$MERV_ACTION_LOCK_START"
  _se_event_mode="${MERV_ACTION_LOCK_MODE:-none}"
  logger -t "VLANMgr" "handler: event lock acquired action=$_se_key token=${MERV_PROGRESS_TOKEN:-none}"
  _se_global_needed=0
  case "$SCRIPT_PATH" in
    */mervlan_manager.sh|*/execute_nodes.sh|*/sync_nodes.sh|*/save_settings.sh|*/hw_probe.sh|*/update_mervlan.sh|*/update_mervlan_repair.sh|*/backup_mervlan.sh|*/mervlan_recover.sh|*/mac_refresh.sh|*/mervlan_boot.sh|*/ssh_trust_action.sh|*/mac_client_meta.sh|*/dropbear_sshkey_gen.sh) _se_global_needed=1 ;;
  esac
  _se_global_nonce=""; _se_global_start=""
  if [ "$_se_global_needed" -eq 1 ]; then
    merv_action_lock_enter "${MERV_ACTION_LOCK_PATH:-$LOCKDIR/mervlan_action.lock}"
    _se_global_rc=$?
    if [ "$_se_global_rc" -ne 0 ]; then
      _se_event_release_rc=0
      merv_action_lock_leave "$_se_event_lock" "$_se_event_nonce" "$_se_event_start" "$_se_event_mode" >/dev/null 2>&1 || _se_event_release_rc=1
      if [ "$_se_event_release_rc" -ne 0 ]; then
        logger -t "VLANMgr" "handler: event lock cleanup failed after global lock contention; retained for recovery"
        merv_action_progress_init "${MERV_PROGRESS_TOKEN:-}" "$_se_key" "$_se_key" "Preparing action..."
        merv_action_progress_fail "The action lock could not be reconciled; recovery is required."
        if [ -n "${MERV_PROGRESS_TOKEN:-}" ] && type action_ack_error >/dev/null 2>&1; then
          action_ack_error "$MERV_PROGRESS_TOKEN" "$_se_ack_action" \
            '{"reason":"cleanup-failed","lock":"event"}' \
            "The event action lock could not be cleaned up; recovery is required." \
            '["action-lock-cleanup-failed"]' action-lock-cleanup-failed >/dev/null 2>&1 || :
        fi
        return 75
      fi
      merv_action_progress_init "${MERV_PROGRESS_TOKEN:-}" "$_se_key" "$_se_key" "Preparing action..."
      if [ "$_se_global_rc" -eq 3 ]; then
        merv_action_progress_fail "Another configuration action is already running; this action was not started."
      else
        merv_action_progress_fail "The global action owner could not be verified; no work was started."
      fi
      if [ -n "${MERV_PROGRESS_TOKEN:-}" ] && type action_ack_lock_failure >/dev/null 2>&1; then
        action_ack_lock_failure "$MERV_PROGRESS_TOKEN" "$_se_ack_action" "$_se_global_rc" global >/dev/null 2>&1 || \
          logger -t "VLANMgr" "handler: global lock-failure acknowledgement failed for $_se_key"
      fi
      logger -t "VLANMgr" "handler: global action lock unavailable (rc=$_se_global_rc); refusing $_se_key"
      return 75
    fi
    _se_global_nonce="$MERV_ACTION_LOCK_NONCE"; _se_global_start="$MERV_ACTION_LOCK_START"
    _se_global_mode="${MERV_ACTION_LOCK_MODE:-none}"
    logger -t "VLANMgr" "handler: global lock acquired action=$_se_key token=${MERV_PROGRESS_TOKEN:-none}"
  fi
  _se_ack_stage=0
  case "$SCRIPT_PATH" in
    */save_settings.sh)
      [ -n "${MERV_PROGRESS_TOKEN:-}" ] && _se_ack_stage=1
      ;;
  esac
  _se_release_owner_locks() {
    [ "${_se_cleanup_done:-0}" -eq 0 ] || return "${_se_release_rc:-0}"
    _se_cleanup_done=1
    _se_release_rc=0
    if ! merv_action_lock_leave "$_se_event_lock" "$_se_event_nonce" "$_se_event_start" "$_se_event_mode" >/dev/null 2>&1; then
      _se_release_rc=1
      logger -t "VLANMgr" "handler: event lock cleanup failed; ownership was not proven"
    fi
    if [ -n "$_se_global_nonce" ]; then
      if ! merv_action_lock_leave "${MERV_ACTION_LOCK_PATH:-$LOCKDIR/mervlan_action.lock}" "$_se_global_nonce" "$_se_global_start" "$_se_global_mode" >/dev/null 2>&1; then
        _se_release_rc=1
        logger -t "VLANMgr" "handler: global action-lock cleanup failed; ownership was not proven"
      fi
    fi
    return "$_se_release_rc"
  }
  _se_cleanup_done=0
  _se_worker_pid=""
  _se_worker_start=""
  _se_reconcile_worker() {
    [ -n "${_se_worker_pid:-}" ] || return 0
    # A published worker PID without its authenticated start identity is an
    # unknown lifecycle state; never signal by PID alone.  Because the
    # dispatcher launched this direct child, waiting is a safe way to reap it
    # and establish termination before any lock cleanup is attempted.
    if [ -z "${_se_worker_start:-}" ]; then
      wait "$_se_worker_pid" 2>/dev/null
      _se_worker_pid=""
      return 0
    fi
    if merv_identity_matches "$_se_worker_pid" "$_se_worker_start" 2>/dev/null; then
      kill -TERM "$_se_worker_pid" 2>/dev/null || :
      _se_n=0
      while [ "$_se_n" -lt 5 ] && merv_identity_matches "$_se_worker_pid" "$_se_worker_start" 2>/dev/null; do
        sleep 1
        _se_n=$((_se_n + 1))
      done
      if merv_identity_matches "$_se_worker_pid" "$_se_worker_start" 2>/dev/null; then
        kill -KILL "$_se_worker_pid" 2>/dev/null || :
        sleep 1
      fi
    fi
    if merv_identity_matches "$_se_worker_pid" "$_se_worker_start" 2>/dev/null; then
      return 1
    fi
    wait "$_se_worker_pid" 2>/dev/null || :
    _se_worker_pid=""
    _se_worker_start=""
    return 0
  }
  _se_signal_handling=0
  _se_signal_status=0
  _se_handle_signal() {
    _se_signal_status="$1"
    [ "${_se_signal_handling:-0}" -eq 0 ] || exit "$_se_signal_status"
    _se_signal_handling=1
    trap - INT TERM
    logger -t "VLANMgr" "handler: action=$_se_key interrupted (rc=$_se_signal_status); stopping before normal completion"
    _se_reconcile_worker
    _se_worker_rc=$?
    if [ "$_se_worker_rc" -ne 0 ]; then
      logger -t "VLANMgr" "handler: supervised worker identity could not be reconciled; retaining dispatcher locks"
      trap - EXIT
      exit 75
    fi
    _se_release_owner_locks
    _se_release_rc=$?
    if [ "${_se_ack_stage:-0}" -eq 1 ] && [ -n "${MERV_PROGRESS_TOKEN:-}" ] && type action_ack_discard_staged >/dev/null 2>&1; then
      action_ack_discard_staged "$MERV_PROGRESS_TOKEN" >/dev/null 2>&1 || :
      action_ack_error "$MERV_PROGRESS_TOKEN" "save_vlanmgr" \
        '{"local_saved":"unknown","node_sync":"unknown"}' \
        "Settings save interrupted; no success result was published." \
        '["interrupted"]' interrupted >/dev/null 2>&1 || \
        logger -t "VLANMgr" "handler: interruption acknowledgement could not be published"
    fi
    [ "$_se_release_rc" -eq 0 ] || logger -t "VLANMgr" "handler: interrupted action cleanup failed; ownership retained for recovery"
    exit "$_se_signal_status"
  }
  trap '_se_release_owner_locks' EXIT
  trap '_se_handle_signal 130' INT
  trap '_se_handle_signal 143' TERM
  # ASUSWRT may mount the JFFS tree with execution disabled even when the
  # executable bit is present.  Invoke the shell workers through BusyBox sh so
  # an action cannot disappear with a bare 126 before it publishes its ack.
  if [ -f "$SCRIPT_PATH" ]; then
    # Only workers whose dispatcher actually owns the global lock may inherit
    # the parent-held marker. Observation requests do not own that lock and
    # must let a nested SSH trust probe acquire it itself.
    _se_export_rc=0
    if [ "$_se_global_needed" -eq 1 ]; then
      merv_action_lock_export_child_context || _se_export_rc=1
    else
      merv_action_lock_clear_child_context
    fi
    if [ "$_se_export_rc" -ne 0 ]; then
      # An authenticated child context is part of the launch precondition.
      # Refuse to start any worker when export fails.
      logger -t "VLANMgr" "handler: could not export authenticated global lock context; worker was not launched"
      merv_action_progress_init "${MERV_PROGRESS_TOKEN:-}" "$_se_key" "$_se_key" "Preparing action..."
      merv_action_progress_fail "The action owner context was invalid; no work was started."
      if [ -n "${MERV_PROGRESS_TOKEN:-}" ] && type action_ack_error >/dev/null 2>&1; then
        action_ack_error "$MERV_PROGRESS_TOKEN" "$_se_ack_action" \
          '{"reason":"child-context-export-failed"}' \
          "The action owner context was invalid; no work was started." \
          '["child-context-export-failed"]' child-context-export-failed >/dev/null 2>&1 || :
      fi
      _se_script_rc=75
    else
      MERV_ACTION_ACK_STAGE="$_se_ack_stage"
      export MERV_ACTION_LOCK_PARENT_HELD MERV_ACTION_LOCK_PARENT_PID \
        MERV_ACTION_LOCK_PARENT_START MERV_ACTION_LOCK_PARENT_NONCE \
        MERV_ACTION_ACK_STAGE
      logger -t "VLANMgr" "handler: worker start action=$_se_key token=${MERV_PROGRESS_TOKEN:-none} global=$_se_global_needed"
      # Execute the script as the supervised child itself.  The dispatcher
      # records its authenticated PID/start identity before waiting, allowing
      # signal reconciliation without descendant-wide kills.
      sh "$SCRIPT_PATH" "$@" &
      _se_worker_pid=$!
      # lib_action_lock loads lib_identity; use that lightweight, authoritative
      # identity API directly.  merv_proc_start_time is a lib_mervqt wrapper
      # and is intentionally not loaded by this DHCP-sensitive dispatcher.
      _se_worker_start=$(merv_identity_proc_start "$_se_worker_pid" 2>/dev/null || printf '')
      case "$_se_worker_start" in
        ''|*[!0-9]*)
          # Never issue an unauthenticated PID kill.  The direct child is
          # reaped by wait; until that completes the dispatcher retains its
          # locks and cannot publish terminal success.
          wait "$_se_worker_pid" 2>/dev/null
          _se_script_rc=75
          _se_worker_pid=""
          _se_worker_start=""
          ;;
        *)
          wait "$_se_worker_pid" 2>/dev/null
          _se_script_rc=$?
          _se_worker_pid=""
          _se_worker_start=""
          ;;
      esac
    fi
  else
    logger -t "VLANMgr" "handler: missing script ${SCRIPT_PATH##*/}"
    _se_script_rc=1
  fi
  _se_script_rc=${_se_script_rc:-$?}
  [ "$_se_script_rc" -eq 0 ] || logger -t "VLANMgr" "handler: $_se_key script failed (rc=$_se_script_rc)"
  logger -t "VLANMgr" "handler: worker return action=$_se_key token=${MERV_PROGRESS_TOKEN:-none} rc=$_se_script_rc"
  _se_release_owner_locks
  _se_release_rc=$?
  trap - EXIT INT TERM
  logger -t "VLANMgr" "handler: locks released action=$_se_key token=${MERV_PROGRESS_TOKEN:-none} rc=$_se_release_rc"
  _se_ack_finalized=0
  if [ "$_se_ack_stage" -eq 1 ] && [ -n "${MERV_PROGRESS_TOKEN:-}" ]; then
    if [ "$_se_release_rc" -ne 0 ]; then
      action_ack_discard_staged "$MERV_PROGRESS_TOKEN" >/dev/null 2>&1 || :
      action_ack_error "$MERV_PROGRESS_TOKEN" "save_vlanmgr" \
        '{"local_saved":"1","node_sync":"unknown"}' \
        "Settings were saved, but backend lock cleanup failed; recovery is required." \
        '["action-lock-cleanup-failed"]' cleanup-failed >/dev/null 2>&1 || \
        logger -t "VLANMgr" "handler: cleanup-failure acknowledgement could not be published"
      _se_ack_finalized=1
    elif [ "$_se_script_rc" -ne 0 ]; then
      action_ack_discard_staged "$MERV_PROGRESS_TOKEN" >/dev/null 2>&1 || :
      action_ack_error "$MERV_PROGRESS_TOKEN" "save_vlanmgr" \
        '{"local_saved":"0","node_sync":"unknown"}' \
        "Settings save worker failed before a terminal result was available." \
        '["save-worker-failed"]' worker-failed >/dev/null 2>&1 || \
        logger -t "VLANMgr" "handler: worker-failure acknowledgement could not be published"
      _se_ack_finalized=1
    elif action_ack_publish_staged "$MERV_PROGRESS_TOKEN" >/dev/null 2>&1; then
      logger -t "VLANMgr" "handler: acknowledgement published action=save_vlanmgr token=${MERV_PROGRESS_TOKEN}"
      _se_ack_finalized=1
    else
      action_ack_error "$MERV_PROGRESS_TOKEN" "save_vlanmgr" \
        '{"local_saved":"1","node_sync":"unknown"}' \
        "Settings were saved, but the correlated acknowledgement could not be published." \
        '["ack-publication-failed"]' ack-publication-failed >/dev/null 2>&1 || \
        logger -t "VLANMgr" "handler: staged Save acknowledgement publication failed"
      _se_ack_finalized=1
    fi
  fi
  if [ "$_se_release_rc" -ne 0 ]; then
    logger -t "VLANMgr" "handler: $_se_key completed with cleanup failure; refusing success"
    if [ "$_se_script_rc" -eq 0 ]; then
      _se_script_rc=75
      if [ "$_se_ack_finalized" -eq 0 ] && type action_ack_error >/dev/null 2>&1 && [ -n "${MERV_PROGRESS_TOKEN:-}" ]; then
        action_ack_error "$MERV_PROGRESS_TOKEN" "$_se_ack_action" '{"reason":"cleanup-failed"}' "Action completed but backend ownership cleanup failed; recovery is required." '[]' cleanup-failed >/dev/null 2>&1 || logger -t "VLANMgr" "handler: cleanup-failure acknowledgement could not be published"
      fi
    fi
  fi
  # A successful WebUI Save may have published a durable node-settings
  # generation.  The browser can accelerate it, but browser transport must
  # never be the only way convergence starts.  Kick the existing due worker
  # only after this dispatcher has conclusively released its event/global
  # ownership.  The worker rechecks AUTO_SYNC, Update eligibility, marker
  # state, and the normal global owner lock before it launches SSH work.
  case "${RAW:-}" in
    save_vlanmgr|save_vlanmgr_pgt_*) _se_successful_save=1 ;;
    *) _se_successful_save=0 ;;
  esac
  if [ "$_se_successful_save" -eq 1 ] && [ "$_se_script_rc" -eq 0 ] && [ "$_se_release_rc" -eq 0 ] && \
     [ -f "$MERV_BASE/functions/settings_reconcile.sh" ]; then
    (
      unset MERV_ACTION_LOCK_PARENT_HELD MERV_ACTION_LOCK_PARENT_PID \
        MERV_ACTION_LOCK_PARENT_START MERV_ACTION_LOCK_PARENT_NONCE \
        MERV_PROGRESS_TOKEN MERV_ACTION_ACK_STAGE
      exec </dev/null
      exec >/dev/null 2>&1
      sh "$MERV_BASE/functions/settings_reconcile.sh" due
    ) &
    logger -t "VLANMgr" "handler: settings reconciliation kick scheduled after save"
  fi
  return "$_se_script_rc"

        # Still within debounce window — rapid re-fire; skip
        # Outside debounce but within stale threshold — script is still running; skip
        # Older than stale threshold — lock was abandoned by a crashed script; reclaim
      # No stamp file — fall back to pid + created metadata written at acquire
        # window — on a busy router a crashed holder's PID is quickly recycled
        # PID dead or absent — decide purely on lock age.
  # Lock acquired (fresh, or reclaimed above) — record ownership metadata before
}

# ========================================================================== #
# EVENT ROUTER — Dispatch events to appropriate handler functions            #
# ========================================================================== #

# Main event dispatch table: maps TYPE_EVENT patterns to handler scripts
# Each case calls dispatch_if_executable with script path and optional args
# Patterns support wildcards (*) for pattern matching on TYPE or EVENT
case "${TYPE}_${EVENT}" in
  # MerVLAN application handlers (explicit handlers for UI/API calls)
  save_vlanmgr|save_vlanmgr_pgt_*)
    # Save VLAN settings to JSON file (triggered by web form submission)
    dispatch_if_executable "/jffs/addons/mervlan/functions/save_settings.sh"
    ;;
  apply_vlanmgr)
    # Apply configured VLAN settings to system (triggered by "Apply" button)
    dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_manager.sh"
    ;;
  apply_vlanmgr_pgt_*)
    # Progress-token variant; the dispatch helper decodes and exports the
    # token before mervlan_manager.sh is launched.
    dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_manager.sh"
    ;;
  sync_vlanmgr)
    # Sync VLAN configuration to remote nodes (triggered manually)
    dispatch_if_executable "/jffs/addons/mervlan/functions/sync_nodes.sh"
    ;;
  sync_vlanmgr_pgt_*)
    # Progress-token variant; the dispatch helper decodes and exports the
    # token before sync_nodes.sh is launched.
    dispatch_if_executable "/jffs/addons/mervlan/functions/sync_nodes.sh"
    ;;
  syncsettings_vlanmgr)
    # Sync settings only to remote nodes
    dispatch_if_executable "/jffs/addons/mervlan/functions/sync_nodes.sh" --settings-only
    ;;
  syncsettings_vlanmgr_pgt_*)
    # Progress-token variant for settings-only sync
    dispatch_if_executable "/jffs/addons/mervlan/functions/sync_nodes.sh" --settings-only
    ;;
  executenodes_vlanmgr)
    # Execute VLAN Manager workflow on configured nodes (runs execute_nodes.sh)
    dispatch_if_executable "/jffs/addons/mervlan/functions/execute_nodes.sh"
    ;;
  executenodes_vlanmgr_pgt_*)
    # Progress-token variant; execute_nodes.sh owns the aggregate status.
    dispatch_if_executable "/jffs/addons/mervlan/functions/execute_nodes.sh"
    ;;
  executenodesonly_vlanmgr)
    # Execute VLAN Manager workflow on configured nodes (runs execute_nodes.sh)
    dispatch_if_executable "/jffs/addons/mervlan/functions/execute_nodes.sh" nodesonly
    ;;
  executenodesonly_vlanmgr_pgt_*)
    # Progress-token variant; execute_nodes.sh owns the aggregate status.
    dispatch_if_executable "/jffs/addons/mervlan/functions/execute_nodes.sh" nodesonly
    ;;
  genkey_vlanmgr)
    # Generate SSH keys for node communication (triggered during setup)
    dispatch_if_executable "/jffs/addons/mervlan/functions/dropbear_sshkey_gen.sh"
    ;;
  genkey_vlanmgr_pgt_*)
    # Progress-token variant; the key generator owns the status lifecycle.
    dispatch_if_executable "/jffs/addons/mervlan/functions/dropbear_sshkey_gen.sh"
    ;;
  enableservice_vlanmgr)
    # Enable MerVLAN auto-start on boot (triggered by service toggle)
    _action_token="$(get_action_request_token)"
    dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_boot.sh" enable "$_action_token"
    ;;
  enableservice_vlanmgr_vrt_*)
    _action_token="$(get_verified_action_token "${TYPE}_${EVENT}" enableservice_vlanmgr)"
    if [ -n "$_action_token" ]; then
      dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_boot.sh" enable "$_action_token"
    else
      logger -t "VLANMgr" "handler: rejected enable action with invalid verification token"
    fi
    ;;
  disableservice_vlanmgr)
    # Disable MerVLAN auto-start on boot (triggered by service toggle)
    _action_token="$(get_action_request_token)"
    dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_boot.sh" disable "$_action_token"
    ;;
  disableservice_vlanmgr_vrt_*)
    _action_token="$(get_verified_action_token "${TYPE}_${EVENT}" disableservice_vlanmgr)"
    if [ -n "$_action_token" ]; then
      dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_boot.sh" disable "$_action_token"
    else
      logger -t "VLANMgr" "handler: rejected disable action with invalid verification token"
    fi
    ;;
  checkservice_vlanmgr)
    # Check MerVLAN service status (triggered by status query)
    dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_boot.sh" status
    ;;
  collectclients_vlanmgr)
    # Collect client list from router and nodes (triggered by refresh request)
    dispatch_if_executable "/jffs/addons/mervlan/functions/post_apply_worker.sh" request collect
    ;;
  collectclients_vlanmgr_pgt_*)
    # Progress-token variant lets collection publish the SSH trust challenge
    # before any local or node inventory work starts.
    dispatch_if_executable "/jffs/addons/mervlan/functions/post_apply_worker.sh" request collect
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
  repairmain_vlanmgr|repairmain_vlanmgr_pgt_*)
    # Repair only the main-branch update/runtime components before a separate update.
    dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan_repair.sh" main
    ;;
  repairdev_vlanmgr|repairdev_vlanmgr_pgt_*)
    # Repair only the dev-branch update/runtime components before a separate update.
    dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan_repair.sh" dev
    ;;
  updateref_vlanmgr_*)
    _encoded_update_request="$(decode_update_ref_action "${TYPE}_${EVENT}")"
    _encoded_update_ref=${_encoded_update_request%%|*}
    _encoded_update_policy=${_encoded_update_request#*|}
    case "$_encoded_update_ref|$_encoded_update_policy" in
      refs/heads/?*'|'keep|refs/heads/?*'|'clear|refs/tags/v[0-9]*'|'keep|refs/tags/v[0-9]*'|'clear)
        logger -t "VLANMgr" "handler: decoded explicit update ref '$_encoded_update_ref' (logs=$_encoded_update_policy)"
        dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" update "$_encoded_update_ref" "--logs=$_encoded_update_policy"
        ;;
      *)
        logger -t "VLANMgr" "handler: rejected invalid encoded update ref from '${TYPE}_${EVENT}'"
        ;;
    esac
    ;;
  updaterelease_vlanmgr)
    # Legacy transport: the update worker may consult custom_settings.txt only
    # after owning the maintenance lock. Canonical ref actions use the encoded
    # updateref_vlanmgr_* path above and never depend on this fallback.
    dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" update legacy
    ;;
  backupinventory_vlanmgr_*)
    _maint_decoded=$(decode_maintenance_action "${TYPE}_${EVENT}" backupinventory_vlanmgr 0)
    _maint_token=${_maint_decoded%%|*}
    if [ -n "$_maint_decoded" ] && [ -n "$_maint_token" ]; then
      dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" inventory "$_maint_token"
    else
      logger -t "VLANMgr" "handler: rejected malformed backup inventory action"
    fi
    ;;
  manualbackup_vlanmgr_*)
    _maint_decoded=$(decode_maintenance_action "${TYPE}_${EVENT}" manualbackup_vlanmgr 1)
    _maint_token=${_maint_decoded%%|*}
    _maint_payload=${_maint_decoded#*|}
    if [ -n "$_maint_decoded" ] && maintenance_tag_valid "$_maint_payload"; then
      dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" backup create "$_maint_payload" yes "$_maint_token"
    else
      logger -t "VLANMgr" "handler: rejected malformed manual backup action"
    fi
    ;;
  deletebackup_vlanmgr_*)
    _maint_decoded=$(decode_maintenance_archive_action "${TYPE}_${EVENT}" deletebackup_vlanmgr)
    _maint_token=${_maint_decoded%%|*}
    _maint_payload=${_maint_decoded#*|}
    if [ -n "$_maint_decoded" ] && maintenance_archive_valid "$_maint_payload"; then
      dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" backup delete "$_maint_payload" yes "$_maint_token"
    else
      logger -t "VLANMgr" "handler: rejected malformed backup deletion action"
    fi
    ;;
  deleteallbackups_vlanmgr_*)
    _maint_decoded=$(decode_maintenance_action "${TYPE}_${EVENT}" deleteallbackups_vlanmgr 0)
    _maint_token=${_maint_decoded%%|*}
    if [ -n "$_maint_decoded" ] && [ -n "$_maint_token" ]; then
      dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" backup delete-all yes "$_maint_token"
    else
      logger -t "VLANMgr" "handler: rejected malformed delete-all action"
    fi
    ;;
  restorebackup_vlanmgr_*)
    _maint_decoded=$(decode_maintenance_archive_action "${TYPE}_${EVENT}" restorebackup_vlanmgr)
    _maint_token=${_maint_decoded%%|*}
    _maint_payload=${_maint_decoded#*|}
    if [ -n "$_maint_decoded" ] && maintenance_archive_valid "$_maint_payload"; then
      dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" restore "$_maint_payload" yes "$_maint_token"
    else
      logger -t "VLANMgr" "handler: rejected malformed restore action"
    fi
    ;;
  undorestore_vlanmgr_*)
    _maint_decoded=$(decode_maintenance_action "${TYPE}_${EVENT}" undorestore_vlanmgr 0)
    _maint_token=${_maint_decoded%%|*}
    if [ -n "$_maint_decoded" ] && [ -n "$_maint_token" ]; then
      dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" undo restore yes "$_maint_token"
    else
      logger -t "VLANMgr" "handler: rejected malformed Undo Restore action"
    fi
    ;;
  undoupdate_vlanmgr_*)
    _maint_decoded=$(decode_maintenance_action "${TYPE}_${EVENT}" undoupdate_vlanmgr 0)
    _maint_token=${_maint_decoded%%|*}
    if [ -n "$_maint_decoded" ] && [ -n "$_maint_token" ]; then
      dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" undo update yes "$_maint_token"
    else
      logger -t "VLANMgr" "handler: rejected malformed Undo Update action"
    fi
    ;;
  hwprobe_vlanmgr)
    # Re-run hardware probe to refresh the Hardware profile in settings.json
    _action_token="$(get_action_request_token)"
    dispatch_if_executable "/jffs/addons/mervlan/functions/hw_probe.sh" "$_action_token"
    ;;
  hwprobe_vlanmgr_vrt_*)
    _action_token="$(get_verified_action_token "${TYPE}_${EVENT}" hwprobe_vlanmgr)"
    if [ -n "$_action_token" ]; then
      # Correlated APMO requests receive an explicit action acknowledgement.
      dispatch_if_executable "/jffs/addons/mervlan/functions/hw_probe.sh" "$_action_token"
    else
      logger -t "VLANMgr" "handler: rejected HW probe with invalid verification token"
    fi
    ;;
  macrefresh_vlanmgr)
    # Clear and rebuild the MERV_MAC per-client shield db from a fresh snapshot
    dispatch_if_executable "/jffs/addons/mervlan/functions/mac_refresh.sh"
    ;;
  macrefresh_vlanmgr_pgt_*)
    # Progress-token variant; mac_refresh.sh owns terminal action status.
    dispatch_if_executable "/jffs/addons/mervlan/functions/mac_refresh.sh"
    ;;
  macclientmeta_vlanmgr)
    # Materialize MAC override + client name DBs, re-enforce shield, refresh inventory
    dispatch_if_executable "/jffs/addons/mervlan/functions/mac_client_meta.sh"
    ;;
  macclientmeta_vlanmgr_pgt_*)
    # Progress-token variant; mac_client_meta.sh owns terminal action status.
    dispatch_if_executable "/jffs/addons/mervlan/functions/mac_client_meta.sh"
    ;;
  sshtrustprobe_vlanmgr)
    _trust_action_token="$(get_action_request_token)"
    dispatch_if_executable "/jffs/addons/mervlan/functions/ssh_trust_action.sh" probe "$_trust_action_token"
    ;;
  sshtrustprobe_vlanmgr_pgt_*_nsl_*)
    _trust_node_slots="$(get_ssh_trust_probe_node_slots "${TYPE}_${EVENT}")"
    _trust_action_token="$(get_progress_action_token "${TYPE}_${EVENT}")"
    if [ -n "$_trust_node_slots" ]; then
      MERV_SSH_TRUST_NODE_SLOTS="$_trust_node_slots"
      export MERV_SSH_TRUST_NODE_SLOTS
      dispatch_if_executable "/jffs/addons/mervlan/functions/ssh_trust_action.sh" probe
      unset MERV_SSH_TRUST_NODE_SLOTS
    elif [ -n "$_trust_action_token" ]; then
      action_ack_error "$_trust_action_token" sshtrustprobe_vlanmgr '{"reason":"invalid-node-selection"}' "The SSH trust probe rejected the selected node list." '[]' ssh-trust-invalid >/dev/null 2>&1 || logger -t "VLANMgr" "handler: invalid SSH trust node selection acknowledgement failed"
    else
      logger -t "VLANMgr" "handler: rejected SSH trust probe with invalid selected-node transport"
    fi
    ;;
  sshtrustprobe_vlanmgr_pgt_*)
    dispatch_if_executable "/jffs/addons/mervlan/functions/ssh_trust_action.sh" probe
    ;;
  sshtrustprobe_vlanmgr_vrt_*)
    _trust_action_token="$(get_verified_action_token "${TYPE}_${EVENT}" sshtrustprobe_vlanmgr)"
    [ -n "$_trust_action_token" ] && dispatch_if_executable "/jffs/addons/mervlan/functions/ssh_trust_action.sh" probe "$_trust_action_token" || logger -t "VLANMgr" "handler: rejected SSH trust probe with invalid verification token"
    ;;
  sshtruststatus_vlanmgr)
    _trust_action_token="$(get_action_request_token)"
    dispatch_if_executable "/jffs/addons/mervlan/functions/ssh_trust_action.sh" status "$_trust_action_token"
    ;;
  sshtruststatus_vlanmgr_pgt_*)
    dispatch_if_executable "/jffs/addons/mervlan/functions/ssh_trust_action.sh" status
    ;;
  sshtruststatus_vlanmgr_vrt_*)
    _trust_action_token="$(get_verified_action_token "${TYPE}_${EVENT}" sshtruststatus_vlanmgr)"
    [ -n "$_trust_action_token" ] && dispatch_if_executable "/jffs/addons/mervlan/functions/ssh_trust_action.sh" status "$_trust_action_token" || logger -t "VLANMgr" "handler: rejected SSH trust status request with invalid verification token"
    ;;
  sshtrustenroll_vlanmgr_vrt_*)
    _trust_action_token="$(get_verified_action_token "${TYPE}_${EVENT}" sshtrustenroll_vlanmgr)"
    [ -n "$_trust_action_token" ] && dispatch_if_executable "/jffs/addons/mervlan/functions/ssh_trust_action.sh" enroll "$_trust_action_token" || logger -t "VLANMgr" "handler: rejected SSH trust enrollment with invalid verification token"
    ;;
  sshtrustresume_vlanmgr_vrt_*)
    _trust_action_token="$(get_verified_action_token "${TYPE}_${EVENT}" sshtrustresume_vlanmgr)"
    [ -n "$_trust_action_token" ] && dispatch_if_executable "/jffs/addons/mervlan/functions/ssh_trust_action.sh" resume "$_trust_action_token" || logger -t "VLANMgr" "handler: rejected SSH trust resume with invalid verification token"
    ;;
  sshtrustrevoke_vlanmgr_vrt_*)
    _trust_action_token="$(get_verified_action_token "${TYPE}_${EVENT}" sshtrustrevoke_vlanmgr)"
    [ -n "$_trust_action_token" ] && dispatch_if_executable "/jffs/addons/mervlan/functions/ssh_trust_action.sh" revoke "$_trust_action_token" || logger -t "VLANMgr" "handler: rejected SSH trust revocation with invalid verification token"
    ;;
  sshtrustabort_vlanmgr_vrt_*)
    _trust_action_token="$(get_verified_action_token "${TYPE}_${EVENT}" sshtrustabort_vlanmgr)"
    [ -n "$_trust_action_token" ] && dispatch_if_executable "/jffs/addons/mervlan/functions/ssh_trust_action.sh" abort "$_trust_action_token" || logger -t "VLANMgr" "handler: rejected SSH trust abort with invalid verification token"
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
